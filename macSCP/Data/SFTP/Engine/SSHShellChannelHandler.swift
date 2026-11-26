//
//  SSHShellChannelHandler.swift
//  macSCP
//
//  NIO ChannelDuplexHandler for interactive SSH PTY/Shell sessions
//

import Foundation
import NIOCore
@preconcurrency import NIOSSH

/// Thread-safe handle to an active interactive SSH shell child channel.
nonisolated final class SSHShellChannel: @unchecked Sendable {
    private let channel: Channel

    nonisolated init(channel: Channel) {
        self.channel = channel
    }

    nonisolated func write(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        channel.eventLoop.execute { [channel] in
            guard channel.isActive else { return }
            var buffer = channel.allocator.buffer(capacity: bytes.count)
            buffer.writeBytes(bytes)
            channel.writeAndFlush(buffer, promise: nil)
        }
    }

    nonisolated func resize(cols: Int, rows: Int) {
        let clampedCols = max(1, cols)
        let clampedRows = max(1, rows)
        channel.eventLoop.execute { [channel] in
            guard channel.isActive else { return }
            let event = SSHChannelRequestEvent.WindowChangeRequest(
                terminalCharacterWidth: clampedCols,
                terminalRowHeight: clampedRows,
                terminalPixelWidth: 0,
                terminalPixelHeight: 0
            )
            channel.triggerUserOutboundEvent(event, promise: nil)
        }
    }

    nonisolated func close() async {
        try? await channel.close().get()
    }
}

/// Bridges an interactive SSH `.session` child channel to raw byte streams for SwiftTerm.
nonisolated final class SSHShellChannelHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = Never
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    private let onData: @Sendable ([UInt8]) -> Void
    private let onClose: @Sendable (Int?, Error?) -> Void

    nonisolated(unsafe) private var pendingRequestPromise: EventLoopPromise<Void>?
    nonisolated(unsafe) private var pendingRequestName: String = "SSH request"
    nonisolated(unsafe) private var exitStatus: Int?
    nonisolated(unsafe) private var didNotifyClose = false

    nonisolated init(
        onData: @escaping @Sendable ([UInt8]) -> Void,
        onClose: @escaping @Sendable (Int?, Error?) -> Void
    ) {
        self.onData = onData
        self.onClose = onClose
    }

    /// Registers the promise for the next `ChannelSuccessEvent` / `ChannelFailureEvent`.
    /// Must be called on the channel's EventLoop.
    nonisolated func expectRequestReply(_ promise: EventLoopPromise<Void>, name: String) {
        self.pendingRequestPromise = promise
        self.pendingRequestName = name
    }

    nonisolated func handlerRemoved(context: ChannelHandlerContext) {
        failPendingRequest(AppError.connectionFailed("\(pendingRequestName) interrupted before server confirmation."))
    }

    nonisolated func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent:
            pendingRequestPromise?.succeed(())
            pendingRequestPromise = nil
        case is ChannelFailureEvent:
            failPendingRequest(AppError.connectionFailed("\(pendingRequestName) was rejected by the remote SSH server."))
        case let status as SSHChannelRequestEvent.ExitStatus:
            self.exitStatus = Int(status.exitStatus)
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    nonisolated func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = self.unwrapInboundIn(data)

        // Forward both stdout (.channel) and stderr (.stdErr) to the terminal emulator
        switch channelData.type {
        case .channel, .stdErr:
            break
        default:
            return
        }

        guard case .byteBuffer(var buffer) = channelData.data,
              let bytes = buffer.readBytes(length: buffer.readableBytes),
              !bytes.isEmpty else {
            return
        }

        onData(bytes)
    }

    nonisolated func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = self.unwrapOutboundIn(data)
        let sshData = SSHChannelData(type: .channel, data: .byteBuffer(buffer))
        context.write(self.wrapOutboundOut(sshData), promise: promise)
    }

    nonisolated func channelInactive(context: ChannelHandlerContext) {
        failPendingRequest(AppError.connectionFailed("SSH shell channel closed unexpectedly by remote host."))
        notifyCloseOnce(error: nil)
        context.fireChannelInactive()
    }

    nonisolated func errorCaught(context: ChannelHandlerContext, error: Error) {
        failPendingRequest(error)
        notifyCloseOnce(error: error)
        context.fireErrorCaught(error)
    }

    private nonisolated func failPendingRequest(_ error: Error) {
        pendingRequestPromise?.fail(error)
        pendingRequestPromise = nil
    }

    private nonisolated func notifyCloseOnce(error: Error?) {
        guard !didNotifyClose else { return }
        didNotifyClose = true
        onClose(exitStatus, error)
    }
}
