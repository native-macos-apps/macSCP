//
//  TerminalViewModelTests.swift
//  macSCPTests
//
//  Unit tests for integrated SSH TerminalViewModel and SSHTerminalSession escaping helpers.
//

import Observation
import XCTest
@testable import macSCP

actor MockSSHTerminalSession: SSHTerminalSessionProtocol {
    private(set) var isConnected = false
    private(set) var connectPasswordCalled = false
    private(set) var connectPrivateKeyCalled = false
    private(set) var lastHost: String?
    private(set) var lastPort: Int?
    private(set) var lastUsername: String?
    private(set) var lastPassword: String?
    private(set) var lastPrivateKeyContent: String?
    private(set) var sentChunks: [[UInt8]] = []
    private(set) var resizeHistory: [(cols: Int, rows: Int)] = []
    private(set) var disconnectCount = 0

    var errorToThrow: Error?
    private var onDataCallback: (@Sendable ([UInt8]) -> Void)?
    private var onCloseCallback: (@Sendable (Int?, Error?) -> Void)?

    func setErrorToThrow(_ error: Error?) {
        self.errorToThrow = error
    }

    func connect(
        host: String,
        port: Int,
        username: String,
        password: String,
        cols: Int,
        rows: Int,
        onData: @escaping @Sendable ([UInt8]) -> Void,
        onClose: @escaping @Sendable (Int?, Error?) -> Void
    ) async throws {
        connectPasswordCalled = true
        lastHost = host
        lastPort = port
        lastUsername = username
        lastPassword = password
        onDataCallback = onData
        onCloseCallback = onClose

        if let errorToThrow {
            throw errorToThrow
        }
        isConnected = true
    }

    func connect(
        host: String,
        port: Int,
        username: String,
        privateKeyContent: String,
        passphrase: String?,
        cols: Int,
        rows: Int,
        onData: @escaping @Sendable ([UInt8]) -> Void,
        onClose: @escaping @Sendable (Int?, Error?) -> Void
    ) async throws {
        connectPrivateKeyCalled = true
        lastHost = host
        lastPort = port
        lastUsername = username
        lastPrivateKeyContent = privateKeyContent
        onDataCallback = onData
        onCloseCallback = onClose

        if let errorToThrow {
            throw errorToThrow
        }
        isConnected = true
    }

    func send(_ bytes: [UInt8]) async {
        sentChunks.append(bytes)
    }

    func resize(cols: Int, rows: Int) async {
        resizeHistory.append((cols, rows))
    }

    func disconnect() async {
        isConnected = false
        disconnectCount += 1
    }

    func simulateIncomingData(_ text: String) {
        onDataCallback?(Array(text.utf8))
    }

    func simulateClose(exitCode: Int? = 0, error: Error? = nil) {
        isConnected = false
        onCloseCallback?(exitCode, error)
    }
}

@MainActor
final class TerminalViewModelTests: XCTestCase {

    // MARK: - POSIX Initial Directory Escaping Tests (Command Injection Prevention)

    func testInitialDirectoryCommandIgnoresNilEmptyRootAndHome() {
        XCTAssertNil(SSHTerminalSession.makeInitialDirectoryCommand(for: nil))
        XCTAssertNil(SSHTerminalSession.makeInitialDirectoryCommand(for: ""))
        XCTAssertNil(SSHTerminalSession.makeInitialDirectoryCommand(for: "   "))
        XCTAssertNil(SSHTerminalSession.makeInitialDirectoryCommand(for: "/"))
        XCTAssertNil(SSHTerminalSession.makeInitialDirectoryCommand(for: "~"))
    }

    func testInitialDirectoryCommandRejectsControlCharacters() {
        XCTAssertNil(SSHTerminalSession.makeInitialDirectoryCommand(for: "/tmp\nrm -rf /"))
        XCTAssertNil(SSHTerminalSession.makeInitialDirectoryCommand(for: "/tmp\rwhoami"))
        XCTAssertNil(SSHTerminalSession.makeInitialDirectoryCommand(for: "/tmp\0evil"))
    }

    func testInitialDirectoryCommandEscapesShellMetacharacters() {
        let cmd1 = SSHTerminalSession.makeInitialDirectoryCommand(for: "/var/www/my app")
        XCTAssertEqual(cmd1, "cd '/var/www/my app' && clear\n")

        let cmd2 = SSHTerminalSession.makeInitialDirectoryCommand(for: "/tmp/it's $(whoami) `id`; echo hi")
        XCTAssertEqual(cmd2, "cd '/tmp/it'\\''s $(whoami) `id`; echo hi' && clear\n")
    }

    // MARK: - Password Auth Connection & Initial Directory

    func testConnectWithPasswordAndInitialPath() async {
        let mockSession = MockSSHTerminalSession()
        let data = TerminalWindowData(
            connectionId: UUID(),
            connectionName: "Prod Server",
            host: "example.com",
            port: 2222,
            username: "deploy",
            password: "secret",
            authMethod: .password,
            initialPath: "/srv/app"
        )

        let vm = TerminalViewModel(data: data, sessionFactory: { mockSession })
        await vm.connect()

        XCTAssertEqual(vm.connectionState, .connected)
        XCTAssertEqual(vm.endpointDisplay, "deploy@example.com:2222")
        let passwordCalled = await mockSession.connectPasswordCalled
        let sentChunks = await mockSession.sentChunks
        XCTAssertTrue(passwordCalled)
        XCTAssertEqual(sentChunks.count, 1)
        XCTAssertEqual(String(bytes: sentChunks[0], encoding: .utf8), "cd '/srv/app' && clear\n")
    }

    // MARK: - In-Memory Private Key Auth

    func testConnectWithPrivateKeyReadsFromProviderWithoutDiskFiles() async {
        let mockSession = MockSSHTerminalSession()
        let keyId = UUID()
        let fakePEM = "-----BEGIN OPENSSH PRIVATE KEY-----\nTESTKEY\n-----END OPENSSH PRIVATE KEY-----"
        let data = TerminalWindowData(
            connectionId: UUID(),
            connectionName: "Key Server",
            host: "10.0.0.5",
            port: 22,
            username: "ubuntu",
            password: "",
            authMethod: .privateKey,
            sshKeyId: keyId
        )

        let vm = TerminalViewModel(
            data: data,
            sessionFactory: { mockSession },
            keyContentProvider: { requestedId in
                XCTAssertEqual(requestedId, keyId)
                return fakePEM
            }
        )

        await vm.connect()

        XCTAssertEqual(vm.connectionState, .connected)
        XCTAssertEqual(vm.endpointDisplay, "ubuntu@10.0.0.5")
        let keyCalled = await mockSession.connectPrivateKeyCalled
        let passedKey = await mockSession.lastPrivateKeyContent
        XCTAssertTrue(keyCalled)
        XCTAssertEqual(passedKey, fakePEM)
    }

    func testConnectWithMissingPrivateKeyFailsGracefully() async {
        let mockSession = MockSSHTerminalSession()
        let data = TerminalWindowData(
            connectionId: UUID(),
            connectionName: "Missing Key",
            host: "10.0.0.5",
            port: 22,
            username: "ubuntu",
            password: "",
            authMethod: .privateKey,
            sshKeyId: UUID()
        )

        let vm = TerminalViewModel(
            data: data,
            sessionFactory: { mockSession },
            keyContentProvider: { _ in nil }
        )

        await vm.connect()

        if case .failed = vm.connectionState {
            // Expected
        } else {
            XCTFail("Expected .failed state when private key is missing in Keychain")
        }
    }

    // MARK: - Output Buffering & Callbacks

    func testOutputBufferedUntilCallbackAttached() async {
        let mockSession = MockSSHTerminalSession()
        let data = TerminalWindowData(
            connectionId: UUID(),
            connectionName: "Buffer Test",
            host: "example.com",
            port: 22,
            username: "user",
            password: "pw",
            authMethod: .password
        )

        let vm = TerminalViewModel(data: data, sessionFactory: { mockSession })
        await vm.connect()

        await mockSession.simulateIncomingData("Welcome!")
        // Allow MainActor Task to deliver
        try? await Task.sleep(nanoseconds: 30_000_000)

        var received: [String] = []
        vm.onOutput = { bytes in
            if let text = String(bytes: bytes, encoding: .utf8) {
                received.append(text)
            }
        }

        XCTAssertEqual(received, ["Welcome!"])
    }

    // MARK: - Zoom & Title & Disconnect

    func testZoomBoundsAndReset() {
        let data = TerminalWindowData(
            connectionId: UUID(),
            connectionName: "Zoom Test",
            host: "example.com",
            port: 22,
            username: "user",
            password: "",
            authMethod: .password
        )
        let vm = TerminalViewModel(data: data, sessionFactory: { MockSSHTerminalSession() })

        for _ in 0..<50 { vm.zoomIn() }
        XCTAssertEqual(vm.fontSize, TerminalViewModel.maxFontSize)

        for _ in 0..<50 { vm.zoomOut() }
        XCTAssertEqual(vm.fontSize, TerminalViewModel.minFontSize)

        vm.resetZoom()
        XCTAssertEqual(vm.fontSize, TerminalViewModel.defaultFontSize)
    }

    func testDisconnectCallsSessionDisconnect() async {
        let mockSession = MockSSHTerminalSession()
        let data = TerminalWindowData(
            connectionId: UUID(),
            connectionName: "Disconnect Test",
            host: "example.com",
            port: 22,
            username: "user",
            password: "pw",
            authMethod: .password
        )
        let vm = TerminalViewModel(data: data, sessionFactory: { mockSession })
        await vm.connect()
        await vm.disconnect()

        let count = await mockSession.disconnectCount
        XCTAssertEqual(count, 1)
        XCTAssertEqual(vm.connectionState, .disconnected(exitCode: nil))
    }

    func testBindingCallbacksDoesNotTriggerObservationInvalidation() {
        let data = TerminalWindowData(
            connectionId: UUID(),
            connectionName: "Observation Test",
            host: "example.com",
            port: 22,
            username: "user",
            password: "",
            authMethod: .password
        )
        let vm = TerminalViewModel(data: data, sessionFactory: { MockSSHTerminalSession() })

        var invalidated = false
        withObservationTracking {
            // Simulate SwiftTermRepresentable reading fontSize and binding callbacks during updateNSView
            _ = vm.fontSize
            vm.onOutput = { _ in }
            vm.onClearScreen = {}
        } onChange: {
            invalidated = true
        }

        // Re-binding callbacks must NOT trigger @Observable invalidation (prevents infinite SwiftUI updateNSView loop)
        vm.onOutput = { _ in }
        vm.onClearScreen = {}

        XCTAssertFalse(invalidated, "Binding onOutput/onClearScreen must be @ObservationIgnored and never invalidate SwiftUI views")
    }
}
