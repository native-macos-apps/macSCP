//
//  SSHExecHandler.swift
//  macSCP
//
//  Channel handler for executing SSH commands and capturing output
//

import Foundation
import NIOCore
@preconcurrency import NIOSSH

final class SSHExecHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData

    private var outputBuffer = ByteBufferAllocator().buffer(capacity: 4096)
    let resultPromise: EventLoopPromise<String>
    private var exitStatus: Int?

    nonisolated init(eventLoop: EventLoop) {
        self.resultPromise = eventLoop.makePromise(of: String.self)
    }

    nonisolated func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = self.unwrapInboundIn(data)
        if case .byteBuffer(var bytes) = channelData.data {
            outputBuffer.writeBuffer(&bytes)
        }
    }

    nonisolated func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let status = event as? SSHChannelRequestEvent.ExitStatus {
            self.exitStatus = Int(status.exitStatus)
        }
        context.fireUserInboundEventTriggered(event)
    }

    nonisolated func channelInactive(context: ChannelHandlerContext) {
        var mutableBuffer = outputBuffer
        let output = mutableBuffer.readString(length: mutableBuffer.readableBytes) ?? ""
        resultPromise.succeed(output)
        context.fireChannelInactive()
    }

    nonisolated func errorCaught(context: ChannelHandlerContext, error: Error) {
        resultPromise.fail(error)
        context.fireErrorCaught(error)
    }
}
