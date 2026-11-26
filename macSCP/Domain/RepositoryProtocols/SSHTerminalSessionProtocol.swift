//
//  SSHTerminalSessionProtocol.swift
//  macSCP
//
//  Protocol defining an interactive SSH terminal (PTY + shell) session.
//

import Foundation

nonisolated protocol SSHTerminalSessionProtocol: Sendable {
    var isConnected: Bool { get async }

    func connect(
        host: String,
        port: Int,
        username: String,
        password: String,
        cols: Int,
        rows: Int,
        onData: @escaping @Sendable ([UInt8]) -> Void,
        onClose: @escaping @Sendable (Int?, Error?) -> Void
    ) async throws

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
    ) async throws

    func send(_ bytes: [UInt8]) async
    func resize(cols: Int, rows: Int) async
    func disconnect() async
}
