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

        let clientConfig = SSHClientConfiguration(
            userAuthDelegate: userAuthDelegate,
            serverAuthDelegate: AcceptAllServerAuthDelegate()
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
        self.channel = channel

        // Create child channel of type .session for SFTP
        let promise = channel.eventLoop.makePromise(of: Channel.self)
        let sftpHandler = SFTPChannelHandler()

        sshHandler.createChannel(promise, channelType: .session) { childChannel, _ in
            childChannel.pipeline.addHandler(sftpHandler)
        }

        let childChannel = try await promise.futureResult.get()

        // Request SFTP subsystem
        let subsystemRequest = SSHChannelRequestEvent.SubsystemRequest(subsystem: "sftp", wantReply: true)
        try await childChannel.triggerUserOutboundEvent(subsystemRequest)

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
