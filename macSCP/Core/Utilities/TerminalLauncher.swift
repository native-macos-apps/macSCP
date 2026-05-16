//
//  TerminalLauncher.swift
//  macSCP
//
//  Utility to launch the macOS native Terminal app with an SSH command using AppleScript.
//

import Foundation
import AppKit

enum TerminalLauncher {
    /// Launches the macOS Terminal app and executes an SSH command using AppleScript.
    static func launchTerminal(
        host: String,
        port: Int,
        username: String,
        privateKeyPath: String? = nil,
        initialPath: String? = nil
    ) {
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
        
        // Prepare AppleScript source using bundle identifier for better reliability
        let scriptSource = """
        tell application id "com.apple.Terminal"
            activate
            do script "\(sshCommand.replacingOccurrences(of: "\"", with: "\\\""))"
        end tell
        """
        
        // Execute AppleScript directly
        executeAppleScript(scriptSource)
    }
    
    private static func executeAppleScript(_ source: String) {
        if let script = NSAppleScript(source: source) {
            var error: NSDictionary?
            script.executeAndReturnError(&error)
            
            if let err = error {
                logError("AppleScript execution failed: \(err)", category: .ui)
                if let message = err["NSAppleScriptErrorMessage"] as? String, 
                   message.contains("not allowed") || message.contains("authorized") {
                    logError("Terminal automation not authorized. Please check System Settings > Privacy & Security > Automation.", category: .ui)
                }
            }
        }
    }
}
