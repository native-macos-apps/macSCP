//
//  AppLockManager.swift
//  macSCP
//
//  Manages app lock state and biometric authentication preferences
//

import AppKit
import Foundation
import SwiftUI

enum InactivityTimeout: Int, CaseIterable, Sendable, Identifiable {
    case oneMinute = 60
    case fiveMinutes = 300
    case fifteenMinutes = 900
    case thirtyMinutes = 1800
    case oneHour = 3600

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .oneMinute: return "1 minute"
        case .fiveMinutes: return "5 minutes"
        case .fifteenMinutes: return "15 minutes"
        case .thirtyMinutes: return "30 minutes"
        case .oneHour: return "1 hour"
        }
    }
}

@MainActor
@Observable
final class AppLockManager {
    static let shared = AppLockManager()

    // MARK: - State

    private(set) var isLocked = false
    private(set) var isAuthenticating = false
    private(set) var authenticationError: String?

    // MARK: - Preferences (stored, synced to UserDefaults)

    private(set) var isBiometricLockEnabled: Bool = false {
        didSet {
            userDefaults.set(isBiometricLockEnabled, forKey: Keys.biometricLockEnabled)
            if !isBiometricLockEnabled {
                isLocked = false
                authenticationError = nil
                cancelInactivityTimer()
            } else {
                resetInactivityTimer()
            }
        }
    }

    var lockOnAppResume: Bool = false {
        didSet { userDefaults.set(lockOnAppResume, forKey: Keys.lockOnAppResume) }
    }

    var lockBeforeConnection: Bool = false {
        didSet { userDefaults.set(lockBeforeConnection, forKey: Keys.lockBeforeConnection) }
    }

    var lockAfterInactivity: Bool = false {
        didSet {
            userDefaults.set(lockAfterInactivity, forKey: Keys.lockAfterInactivity)
            if lockAfterInactivity {
                resetInactivityTimer()
            } else {
                cancelInactivityTimer()
            }
        }
    }

    var inactivityTimeout: InactivityTimeout = .fiveMinutes {
        didSet {
            userDefaults.set(inactivityTimeout.rawValue, forKey: Keys.inactivityTimeout)
            resetInactivityTimer()
        }
    }

    // MARK: - Dependencies

    private let biometricService: BiometricAuthServiceProtocol
    private let userDefaults: UserDefaults
    private let activityThrottleInterval: TimeInterval
    @ObservationIgnored private var backgroundObserver: Any?
    @ObservationIgnored private var activityObserver: Any?
    @ObservationIgnored private var eventMonitor: Any?
    @ObservationIgnored private var inactivityTimer: Timer?
    @ObservationIgnored private(set) var lastActivityDate: Date?
    @ObservationIgnored private(set) var inactivityResetCount: Int = 0

    // MARK: - Constants

    private enum Keys {
        static let biometricLockEnabled = "com.macSCP.biometricLockEnabled"
        static let lockOnAppResume = "com.macSCP.lockOnAppResume"
        static let lockBeforeConnection = "com.macSCP.lockBeforeConnection"
        static let lockAfterInactivity = "com.macSCP.lockAfterInactivity"
        static let inactivityTimeout = "com.macSCP.inactivityTimeout"
    }

    // MARK: - Initialization

    init(
        biometricService: BiometricAuthServiceProtocol? = nil,
        userDefaults: UserDefaults = .standard,
        activityThrottleInterval: TimeInterval = 5.0,
        installObservers: Bool = true
    ) {
        self.biometricService = biometricService ?? BiometricAuthService.shared
        self.userDefaults = userDefaults
        self.activityThrottleInterval = activityThrottleInterval

        // Load persisted preferences (didSet not called during init)
        self.isBiometricLockEnabled = userDefaults.bool(forKey: Keys.biometricLockEnabled)
        self.lockOnAppResume = userDefaults.bool(forKey: Keys.lockOnAppResume)
        self.lockBeforeConnection = userDefaults.bool(forKey: Keys.lockBeforeConnection)
        self.lockAfterInactivity = userDefaults.bool(forKey: Keys.lockAfterInactivity)
        let rawTimeout = userDefaults.integer(forKey: Keys.inactivityTimeout)
        self.inactivityTimeout = InactivityTimeout(rawValue: rawTimeout) ?? .fiveMinutes

        if installObservers {
            setupObservers()
        }
    }

    deinit {
        inactivityTimer?.invalidate()
        if let backgroundObserver {
            NotificationCenter.default.removeObserver(backgroundObserver)
        }
        if let activityObserver {
            NotificationCenter.default.removeObserver(activityObserver)
        }
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
    }

    // MARK: - Public Methods

    /// Called on app launch to lock if enabled
    func lockIfNeeded() {
        guard isBiometricLockEnabled else { return }
        isLocked = true
        authenticationError = nil
        logInfo("App locked on launch", category: .auth)
    }

    /// Attempt to unlock the app
    func unlock() {
        Task { @MainActor in
            let success = await performAuthentication(reason: "Unlock macSCP")
            if success {
                resetInactivityTimer()
            }
        }
    }

    /// Authenticate before a connection attempt. Returns true if allowed.
    func authenticateForConnection() async -> Bool {
        guard isBiometricLockEnabled, lockBeforeConnection else {
            return true
        }

        logInfo("Authenticating for connection", category: .auth)
        let success = await performAuthentication(reason: "Authenticate to connect")
        if success {
            resetInactivityTimer()
        }
        return success
    }

    /// Enable biometric lock (no auth needed to enable)
    func enableBiometricLock() {
        isBiometricLockEnabled = true
        AnalyticsService.trackBiometricToggled(enabled: true)
        logInfo("Biometric lock enabled", category: .auth)
    }

    /// Disable biometric lock (requires authentication first)
    /// Returns true if the lock was successfully disabled.
    @discardableResult
    func disableBiometricLock() async -> Bool {
        let success = await performAuthentication(reason: "Authenticate to disable Touch ID lock")
        guard success else {
            logInfo("Biometric lock disable denied: auth failed", category: .auth)
            return false
        }
        isBiometricLockEnabled = false
        AnalyticsService.trackBiometricToggled(enabled: false)
        logInfo("Biometric lock disabled after authentication", category: .auth)
        return true
    }

    /// Record user activity to reset the inactivity timer
    func recordActivity(now: Date = Date()) {
        guard isBiometricLockEnabled, lockAfterInactivity, !isLocked else { return }
        lastActivityDate = now
        resetInactivityTimer()
    }

    /// Throttled handler for high-frequency local input events (keyboard, mouse, scroll)
    func handleUserInteraction(now: Date = Date()) {
        guard isBiometricLockEnabled, lockAfterInactivity, !isLocked else { return }
        if let lastActivityDate, now.timeIntervalSince(lastActivityDate) < activityThrottleInterval {
            return
        }
        recordActivity(now: now)
    }

    // MARK: - Private Methods

    @discardableResult
    private func performAuthentication(reason: String) async -> Bool {
        guard !isAuthenticating else { return false }

        isAuthenticating = true
        authenticationError = nil

        let result = await biometricService.authenticate(reason: reason)

        isAuthenticating = false

        switch result {
        case .success:
            isLocked = false
            authenticationError = nil
            logInfo("Authentication succeeded", category: .auth)
            AnalyticsService.trackBiometricResult(success: true)
            return true

        case .failure(let error):
            switch error {
            case .userCancelled:
                logInfo("Authentication cancelled by user", category: .auth)
            default:
                authenticationError = error.localizedDescription
                logWarning("Authentication failed: \(error.localizedDescription)", category: .auth)
            }
            AnalyticsService.trackBiometricResult(success: false)
            return false
        }
    }

    private func lock(reason: String) {
        guard isBiometricLockEnabled, !isLocked else { return }
        isLocked = true
        authenticationError = nil
        cancelInactivityTimer()
        logInfo("App locked: \(reason)", category: .auth)
    }

    // MARK: - Inactivity Timer

    private func resetInactivityTimer() {
        cancelInactivityTimer()
        guard isBiometricLockEnabled, lockAfterInactivity, !isLocked else { return }

        inactivityResetCount += 1
        let seconds = TimeInterval(inactivityTimeout.rawValue)
        inactivityTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.lock(reason: "inactivity timeout")
            }
        }
    }

    private func cancelInactivityTimer() {
        inactivityTimer?.invalidate()
        inactivityTimer = nil
    }

    // MARK: - Observers

    private func setupObservers() {
        // Lock when app goes to background (if enabled)
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                if self.lockOnAppResume {
                    self.lock(reason: "app went to background")
                }
            }
        }

        // Reset inactivity timer when app becomes active
        activityObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.recordActivity()
            }
        }

        // Monitor keyboard, mouse, and scroll interactions to keep active sessions unlocked
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]
        ) { [weak self] event in
            self?.handleUserInteraction()
            return event
        }
    }
}
