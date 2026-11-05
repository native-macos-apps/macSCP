//
//  SSHConnection.swift
//  macSCP
//
//  SSH Connection Manager handling TCP connection, NIOSSH handshake, and Channel Multiplexing
//

import Foundation
import NIOCore
import NIOPosix
@preconcurrency import NIOSSH

/// Records the first error raised on the parent channel so the real cause of a
/// handshake failure (host key mismatch, auth rejected, ...) is not masked by the
/// generic "channel closed" error that follows it.
nonisolated final class ParentChannelErrorRecorder: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Any

    private let lock = NSLock()
    nonisolated(unsafe) private var firstError: Error?

    var recordedError: Error? {
        lock.lock()
        defer { lock.unlock() }
        return firstError
    }

    nonisolated func errorCaught(context: ChannelHandlerContext, error: Error) {
        record(error)
        context.fireErrorCaught(error)
    }

    /// Records an error out-of-band (e.g. from a handshake delegate) if none was recorded yet.
    nonisolated func record(_ error: Error) {
        lock.lock()
        if firstError == nil { firstError = error }
        lock.unlock()
    }
}

actor SSHConnection {
    private var group: MultiThreadedEventLoopGroup?
    private var channel: Channel?
    private var sshHandler: NIOSSHHandler?

    init() {}

    func connect(
        host: String,
        port: Int,
        userAuthDelegate: NIOSSHClientUserAuthenticationDelegate
    ) async throws -> SFTPClient {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = group

        let errorRecorder = ParentChannelErrorRecorder()
        let clientConfig = SSHClientConfiguration(
            userAuthDelegate: userAuthDelegate,
            serverAuthDelegate: KnownHostsServerAuthDelegate(host: host, port: port, failureRecorder: errorRecorder)
        )

        let sshHandler = NIOSSHHandler(
            role: .client(clientConfig),
            allocator: ByteBufferAllocator(),
            inboundChildChannelInitializer: nil
        )
        self.sshHandler = sshHandler

        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelOption(ChannelOptions.connectTimeout, value: .seconds(15))

        let channel = try await bootstrap.connect(host: host, port: port).get()
        nonisolated(unsafe) let handlerToAdd = sshHandler as (any ChannelHandler)
        try await channel.pipeline.addHandler(handlerToAdd).get()
        try await channel.pipeline.addHandler(errorRecorder).get()
        self.channel = channel

        do {
            return try await establishSFTP(channel: channel, sshHandler: sshHandler)
        } catch {
            // Surface the real handshake error (e.g. host key mismatch) instead of
            // the generic "channel closed" that follows it.
            if let recorded = errorRecorder.recordedError {
                throw recorded
            }
            throw error
        }
    }

    private func establishSFTP(channel: Channel, sshHandler: NIOSSHHandler) async throws -> SFTPClient {
        // Create child channel of type .session for SFTP
        let promise = channel.eventLoop.makePromise(of: Channel.self)
        let sftpHandler = SFTPChannelHandler()

        sshHandler.createChannel(promise, channelType: .session) { childChannel, _ in
            childChannel.pipeline.addHandler(sftpHandler)
        }

        let childChannel = try await promise.futureResult.get()

        // Request SFTP subsystem and wait for server ChannelSuccessEvent (RFC 4254)
        let subsystemPromise = childChannel.eventLoop.makePromise(of: Void.self)
        sftpHandler.setSubsystemPromise(subsystemPromise)

        let timeoutTask = childChannel.eventLoop.scheduleTask(in: .seconds(15)) {
            subsystemPromise.fail(AppError.connectionTimeout)
        }
        subsystemPromise.futureResult.whenComplete { _ in
            timeoutTask.cancel()
        }

        let subsystemRequest = SSHChannelRequestEvent.SubsystemRequest(subsystem: "sftp", wantReply: true)
        try await childChannel.triggerUserOutboundEvent(subsystemRequest)

        // Await confirmation that the server has successfully launched the SFTP subsystem
        try await subsystemPromise.futureResult.get()

        let client = SFTPClient(channel: childChannel)
        sftpHandler.delegate = client
        try await client.initialize()

        return client
    }

    func executeCommand(_ command: String) async throws -> String {
        guard let channel = channel, let sshHandler = sshHandler else {
            throw AppError.notConnected
        }

        let promise = channel.eventLoop.makePromise(of: Channel.self)
        let execHandler = SSHExecHandler(eventLoop: channel.eventLoop)

        sshHandler.createChannel(promise, channelType: .session) { childChannel, _ in
            childChannel.pipeline.addHandler(execHandler)
        }

        let childChannel = try await promise.futureResult.get()
        let request = SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)
        try await childChannel.triggerUserOutboundEvent(request)

        return try await execHandler.resultPromise.futureResult.get()
    }

    func disconnect() async {
        try? await channel?.close()
        try? await group?.shutdownGracefully()
        channel = nil
        sshHandler = nil
        group = nil
    }
}
