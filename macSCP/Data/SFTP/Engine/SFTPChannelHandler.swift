//
//  SFTPChannelHandler.swift
//  macSCP
//
//  NIO ChannelDuplexHandler bridging SSHChannelData to SFTP packets
//

import Foundation
import NIOCore
@preconcurrency import NIOSSH

nonisolated protocol SFTPChannelHandlerDelegate: AnyObject, Sendable {
    func sftpChannelHandler(_ handler: SFTPChannelHandler, didReceiveResponse response: SFTPResponse)
    func sftpChannelHandler(_ handler: SFTPChannelHandler, didCloseWithError error: Error?)
}

nonisolated final class SFTPChannelHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = Never
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    nonisolated(unsafe) weak var delegate: SFTPChannelHandlerDelegate?
    nonisolated(unsafe) private var accumulator: ByteBuffer
    nonisolated(unsafe) private var context: ChannelHandlerContext?

    nonisolated init(allocator: ByteBufferAllocator = .init()) {
        self.accumulator = allocator.buffer(capacity: 65536)
    }

    nonisolated func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    nonisolated func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
    }

    nonisolated func channelInactive(context: ChannelHandlerContext) {
        delegate?.sftpChannelHandler(self, didCloseWithError: nil)
        context.fireChannelInactive()
    }

    nonisolated func errorCaught(context: ChannelHandlerContext, error: Error) {
        delegate?.sftpChannelHandler(self, didCloseWithError: error)
        context.fireErrorCaught(error)
    }

    nonisolated func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = self.unwrapInboundIn(data)

        guard case .channel = channelData.type else {
            return
        }

        guard case .byteBuffer(var incomingBytes) = channelData.data else {
            return
        }

        accumulator.writeBuffer(&incomingBytes)

        // Parse as many complete SFTP responses as available
        do {
            while let response = try SFTPResponse.parse(from: &accumulator) {
                delegate?.sftpChannelHandler(self, didReceiveResponse: response)
            }
        } catch {
            delegate?.sftpChannelHandler(self, didCloseWithError: error)
            context.close(promise: nil)
            return
        }

        // Compact the accumulator if everything was consumed or discard read bytes to free buffer space
        if accumulator.readableBytes == 0 {
            accumulator.clear()
        } else if accumulator.readerIndex > 32768 {
            accumulator.discardReadBytes()
        }
    }

    nonisolated func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = self.unwrapOutboundIn(data)
        let sshData = SSHChannelData(type: .channel, data: .byteBuffer(buffer))
        context.write(self.wrapOutboundOut(sshData), promise: promise)
    }
}
