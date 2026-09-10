//
//  CommanderViewModelTests.swift
//  macSCPTests
//
//  Unit tests for CommanderViewModel (Transmit 5 style Dual-Pane Commander View)
//

import XCTest
@testable import macSCP

@MainActor
final class CommanderViewModelTests: XCTestCase {
    var sut: CommanderViewModel!
    var container: DependencyContainer!

    override func setUp() async throws {
        try await super.setUp()
        container = DependencyContainer.shared
        sut = CommanderViewModel(container: container)
    }

    override func tearDown() async throws {
        sut = nil
        container = nil
        try await super.tearDown()
    }

    // MARK: - Initial State Tests

    func testInitialState() {
        XCTAssertTrue(sut.isDualPane, "Should default to dual-pane view")
        XCTAssertEqual(sut.leftPane.contentType, .local, "Left pane should default to local")
        XCTAssertEqual(sut.rightPane.contentType, .servers, "Right pane should default to servers")
        XCTAssertEqual(sut.activePanePosition, .left, "Active pane should default to left")
        XCTAssertNotNil(sut.leftPane.browserViewModel, "Left pane should have browser ViewModel")
        XCTAssertTrue(sut.leftPane.browserViewModel?.isLocal ?? false, "Left pane should be marked local")
        XCTAssertNil(sut.rightPane.browserViewModel, "Right pane should not have browser ViewModel in servers mode")
    }

    // MARK: - Symmetry Tests (User requirement: both panes can be local, both remote, or any combination)

    func testBothPanesCanBeLocal() async {
        sut.switchToLocal(in: .right)

        XCTAssertEqual(sut.leftPane.contentType, .local, "Left pane should be local")
        XCTAssertEqual(sut.rightPane.contentType, .local, "Right pane should be local")
        XCTAssertNotNil(sut.rightPane.browserViewModel, "Right pane should have a browser ViewModel")
        XCTAssertTrue(sut.rightPane.browserViewModel?.isLocal ?? false, "Right pane should be local")
    }

    func testBothPanesCanBeServers() {
        sut.switchToServers(in: .left)

        XCTAssertEqual(sut.leftPane.contentType, .servers, "Left pane should be servers")
        XCTAssertEqual(sut.rightPane.contentType, .servers, "Right pane should be servers")
        XCTAssertNil(sut.leftPane.browserViewModel)
        XCTAssertNil(sut.rightPane.browserViewModel)
    }

    func testSwitchLeftToServersAndRightToLocal() {
        sut.switchToServers(in: .left)
        sut.switchToLocal(in: .right)

        XCTAssertEqual(sut.leftPane.contentType, .servers)
        XCTAssertEqual(sut.rightPane.contentType, .local)
        XCTAssertNil(sut.leftPane.browserViewModel)
        XCTAssertNotNil(sut.rightPane.browserViewModel)
    }

    // MARK: - Dual Pane Toggle

    func testToggleDualPane() {
        XCTAssertTrue(sut.isDualPane)
        sut.isDualPane = false
        XCTAssertFalse(sut.isDualPane)
        sut.isDualPane = true
        XCTAssertTrue(sut.isDualPane)
    }

    // MARK: - Active Pane Switching

    func testActivePaneSwitching() {
        XCTAssertEqual(sut.activePanePosition, .left)
        XCTAssertEqual(sut.activePane.position, .left)
        XCTAssertEqual(sut.inactivePane.position, .right)

        sut.activePanePosition = .right
        XCTAssertEqual(sut.activePane.position, .right)
        XCTAssertEqual(sut.inactivePane.position, .left)
    }
}
