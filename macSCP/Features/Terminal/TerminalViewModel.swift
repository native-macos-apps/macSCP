//
//  TerminalViewModel.swift
//  macSCP
//
//  ViewModel managing an integrated SSH terminal session backed by swift-nio-ssh and SwiftTerm.
//

import Foundation
import SwiftUI

enum TerminalConnectionState: Equatable, Sendable {
    case connecting
    case connected
    case disconnected(exitCode: Int?)
    case failed(AppError)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var isConnecting: Bool {
        if case .connecting = self { return true }
        return false
    }

    var statusText: String {
        switch self {
        case .connecting:
            return "Connecting…"
        case .connected:
            return "Connected"
        case .disconnected(let code):
            if let code = code {
                return "Disconnected (exit \(code))"
            }
            return "Disconnected"
        case .failed:
            return "Connection Failed"
        }
    }
}

@MainActor
@Observable
final class TerminalViewModel {
    // MARK: - Connection Metadata
    let connectionName: String
    let host: String
    let port: Int
    let username: String
    let authMethod: AuthMethod
    let sshKeyId: UUID?
    let initialPath: String?
    private let password: String

    // MARK: - Observable State
    private(set) var connectionState: TerminalConnectionState = .connecting
    private(set) var terminalTitle: String = ""
    private(set) var cols: Int = 80
    private(set) var rows: Int = 24
    var fontSize: CGFloat = 13

    static let defaultFontSize: CGFloat = 13
    static let minFontSize: CGFloat = 9
    static let maxFontSize: CGFloat = 28

    // MARK: - View Callbacks (SwiftTerm bridge)
    /// Called on MainActor when remote SSH bytes arrive.
    /// Marked `@ObservationIgnored` so binding callbacks from `SwiftTermRepresentable` never triggers SwiftUI update loops.
    @ObservationIgnored var onOutput: (([UInt8]) -> Void)? {
        didSet {
            flushPendingOutputIfNeeded()
        }
    }

    /// Called on MainActor when the user requests clearing the terminal screen/scrollback.
    @ObservationIgnored var onClearScreen: (() -> Void)?

    // MARK: - Private State
    @ObservationIgnored private let sessionFactory: () -> SSHTerminalSessionProtocol
    @ObservationIgnored private let keyContentProvider: (UUID) throws -> String?
    @ObservationIgnored private var session: SSHTerminalSessionProtocol?
    @ObservationIgnored private var pendingOutputBuffer: [[UInt8]] = []
    @ObservationIgnored private var connectGeneration: Int = 0
    @ObservationIgnored private var isDisconnecting = false

    // MARK: - Computed Properties
    var windowTitle: String {
        if !terminalTitle.isEmpty {
            return "\(connectionName) — \(terminalTitle)"
        }
        return "\(connectionName) (\(username)@\(host))"
    }

    var endpointDisplay: String {
        port == AppConstants.defaultSSHPort
            ? "\(username)@\(host)"
            : "\(username)@\(host):\(port)"
    }

    var dimensionsDisplay: String {
        "\(cols)×\(rows)"
    }

    // MARK: - Init
    init(
        data: TerminalWindowData,
        sessionFactory: (() -> SSHTerminalSessionProtocol)? = nil,
        keyContentProvider: ((UUID) throws -> String?)? = nil
    ) {
        self.connectionName = data.connectionName
        self.host = data.host
        self.port = data.port
        self.username = data.username
        self.password = data.password
        self.authMethod = data.authMethod
        self.sshKeyId = data.sshKeyId
        self.initialPath = data.initialPath
        self.sessionFactory = sessionFactory ?? { DependencyContainer.shared.makeSSHTerminalSession() }
        self.keyContentProvider = keyContentProvider ?? { try SSHKeyStorageService.shared.getPrivateKeyContent(for: $0) }
    }

    // MARK: - Lifecycle

    func connect() async {
        connectGeneration += 1
        let generation = connectGeneration
        isDisconnecting = false
        connectionState = .connecting

        if let existing = session {
            await existing.disconnect()
            session = nil
        }

        let newSession = sessionFactory()
        self.session = newSession

        let onData: @Sendable ([UInt8]) -> Void = { [weak self] bytes in
            Task { @MainActor [weak self] in
                guard let self, self.connectGeneration == generation else { return }
                self.deliverOutput(bytes)
            }
        }

        let onClose: @Sendable (Int?, Error?) -> Void = { [weak self] exitCode, error in
            Task { @MainActor [weak self] in
                guard let self, self.connectGeneration == generation else { return }
                if self.isDisconnecting {
                    self.connectionState = .disconnected(exitCode: exitCode)
                    return
                }
                if let error = error {
                    self.connectionState = .failed(AppError.from(error))
                } else {
                    self.connectionState = .disconnected(exitCode: exitCode)
                }
            }
        }

        do {
            switch authMethod {
            case .password:
                try await newSession.connect(
                    host: host,
                    port: port,
                    username: username,
                    password: password,
                    cols: cols,
                    rows: rows,
                    onData: onData,
                    onClose: onClose
                )
            case .privateKey:
                guard let keyId = sshKeyId else {
                    throw AppError.connectionFailed("No SSH key selected for this connection. Please edit the connection and select an SSH key.")
                }
                guard let privateKeyContent = try keyContentProvider(keyId), !privateKeyContent.isEmpty else {
                    throw AppError.connectionFailed("SSH key was not found in Keychain. Please edit the connection and re-select or import an SSH key.")
                }
                try await newSession.connect(
                    host: host,
                    port: port,
                    username: username,
                    privateKeyContent: privateKeyContent,
                    passphrase: password.isEmpty ? nil : password,
                    cols: cols,
                    rows: rows,
                    onData: onData,
                    onClose: onClose
                )
            }

            guard connectGeneration == generation else {
                await newSession.disconnect()
                return
            }

            connectionState = .connected

            if let cdCommand = SSHTerminalSession.makeInitialDirectoryCommand(for: initialPath) {
                await newSession.send(Array(cdCommand.utf8))
            }
        } catch {
            guard connectGeneration == generation else { return }
            logError("Integrated SSH terminal failed to connect: \(error)", category: .sftp)
            connectionState = .failed(AppError.from(error))
        }
    }

    func reconnect() async {
        onClearScreen?()
        pendingOutputBuffer.removeAll()
        terminalTitle = ""
        await connect()
    }

    func disconnect() async {
        isDisconnecting = true
        connectGeneration += 1
        let activeSession = session
        session = nil
        await activeSession?.disconnect()
        if case .connected = connectionState {
            connectionState = .disconnected(exitCode: nil)
        }
    }

    // MARK: - Terminal I/O

    func sendInput(_ bytes: [UInt8]) {
        guard !bytes.isEmpty, let activeSession = session, connectionState.isConnected else { return }
        Task {
            await activeSession.send(bytes)
        }
    }

    func resize(cols newCols: Int, rows newRows: Int) {
        let clampedCols = max(1, newCols)
        let clampedRows = max(1, newRows)
        guard clampedCols != cols || clampedRows != rows else { return }
        cols = clampedCols
        rows = clampedRows

        guard let activeSession = session, connectionState.isConnected else { return }
        Task {
            await activeSession.resize(cols: clampedCols, rows: clampedRows)
        }
    }

    func updateTitle(_ title: String) {
        terminalTitle = title
    }

    // MARK: - Display Actions

    func clearScreen() {
        onClearScreen?()
    }

    func zoomIn() {
        fontSize = min(Self.maxFontSize, fontSize + 1)
    }

    func zoomOut() {
        fontSize = max(Self.minFontSize, fontSize - 1)
    }

    func resetZoom() {
        fontSize = Self.defaultFontSize
    }

    // MARK: - Private Buffering

    private func deliverOutput(_ bytes: [UInt8]) {
        if let onOutput = onOutput {
            onOutput(bytes)
        } else {
            pendingOutputBuffer.append(bytes)
        }
    }

    private func flushPendingOutputIfNeeded() {
        guard let onOutput = onOutput, !pendingOutputBuffer.isEmpty else { return }
        let chunks = pendingOutputBuffer
        pendingOutputBuffer.removeAll()
        for chunk in chunks {
            onOutput(chunk)
        }
    }
}
