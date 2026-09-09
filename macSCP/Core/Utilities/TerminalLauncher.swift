//
//  TerminalLauncher.swift
//  macSCP
//
//  Utility to launch the macOS native Terminal app with an SSH command using AppleScript.
//

import Foundation
import AppKit

enum TerminalLauncherError: LocalizedError {
    case appleScriptInitializationFailed
    case executionFailed(String)
    case automationNotAuthorized
    
    var errorDescription: String? {
        switch self {
        case .appleScriptInitializationFailed:
            return "Failed to initialize AppleScript."
        case .executionFailed(let message):
            return "Terminal error: \(message)"
        case .automationNotAuthorized:
            return "Terminal automation not authorized. Please check System Settings > Privacy & Security > Automation."
        }
    }
}

enum TerminalLauncher {
    private static let terminalBundleIdentifier = "com.apple.Terminal"
    private static let terminalLaunchTimeout: TimeInterval = 5

    /// Launches the macOS Terminal app and executes an SSH command using AppleScript asynchronously.
    @discardableResult
    static func launchTerminal(
        host: String,
        port: Int,
        username: String,
        privateKeyPath: String? = nil,
        initialPath: String? = nil
    ) async -> Result<Void, Error> {
        logInfo("Launching native terminal (AppleScript) for \(username)@\(host):\(port)", category: .ui)
        
        var sshCommand = "ssh -p \(port)"
        
        if let keyPath = privateKeyPath, !keyPath.isEmpty {
            let escapedKeyPath = keyPath.replacingOccurrences(of: " ", with: "\\ ")
            sshCommand += " -i \(escapedKeyPath)"
        }
        
        sshCommand += " \(username)@\(host)"
        
        if let path = initialPath, path != "/", path != "~", !path.isEmpty {
            let escapedPath = path.replacingOccurrences(of: "\"", with: "\\\"")
            sshCommand += " -t \"cd \\\"\(escapedPath)\\\" ; exec $SHELL -l\""
        }

        switch await ensureTerminalIsRunning() {
        case .success:
            break
        case .failure(let error):
            return .failure(error)
        }

        let activateScript = """
        tell application id "\(terminalBundleIdentifier)"
            activate
        end tell
        """

        switch executeAppleScript(activateScript) {
        case .success:
            break
        case .failure(let error):
            return .failure(error)
        }

        let commandScript = """
        tell application id "\(terminalBundleIdentifier)"
            do script "\(escapeForAppleScript(sshCommand))"
        end tell
        """

        let firstAttempt = executeAppleScript(commandScript)
        if case .failure(TerminalLauncherError.executionFailed(let message)) = firstAttempt,
           isTerminalNotRunningError(message) {
            try? await Task.sleep(nanoseconds: 250_000_000)
            return executeAppleScript(commandScript)
        }

        return firstAttempt
    }

    private static func executeAppleScript(_ source: String) -> Result<Void, Error> {
        guard let script = NSAppleScript(source: source) else {
            return .failure(TerminalLauncherError.appleScriptInitializationFailed)
        }

        var error: NSDictionary?
        script.executeAndReturnError(&error)

        if let err = error {
            let message = err["NSAppleScriptErrorMessage"] as? String ?? "Unknown AppleScript error"
            logError("AppleScript execution failed: \(message)", category: .ui)

            if message.contains("not allowed") || message.contains("authorized") {
                return .failure(TerminalLauncherError.automationNotAuthorized)
            }

            return .failure(TerminalLauncherError.executionFailed(message))
        }

        return .success(())
    }

    private static func ensureTerminalIsRunning() async -> Result<Void, Error> {
        if isTerminalRunning() {
            return .success(())
        }

        guard let terminalURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: terminalBundleIdentifier) else {
            return .failure(TerminalLauncherError.executionFailed("Terminal app could not be located."))
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        do {
            _ = try await NSWorkspace.shared.openApplication(at: terminalURL, configuration: configuration)
        } catch {
            return .failure(TerminalLauncherError.executionFailed(error.localizedDescription))
        }

        let deadline = Date().addingTimeInterval(terminalLaunchTimeout)
        while Date() < deadline {
            if isTerminalRunning() {
                return .success(())
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        return .failure(TerminalLauncherError.executionFailed("Terminal app did not finish launching in time."))
    }

    private static func isTerminalRunning() -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: terminalBundleIdentifier).isEmpty == false
    }

    private static func isTerminalNotRunningError(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("application isn’t running") || normalized.contains("application isn't running")
    }

    private static func escapeForAppleScript(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
