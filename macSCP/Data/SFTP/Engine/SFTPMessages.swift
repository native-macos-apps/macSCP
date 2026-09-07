//
//  SFTPMessages.swift
//  macSCP
//
//  SFTP v3 Message Definitions, Serialization & Deserialization
//

import Foundation
import NIOCore

// MARK: - Directory Name Entry

nonisolated struct SFTPNameEntry: Sendable {
    let filename: String
    let longname: String
    let attributes: SFTPFileAttributes
}

// MARK: - SFTP Error

nonisolated enum SFTPClientError: LocalizedError, Sendable {
    case connectionClosed
    case invalidPacket
    case unsupportedVersion(UInt32)
    case failure(code: SFTPStatusCode, message: String)
    case timeout
    case channelError(String)

    var errorDescription: String? {
        switch self {
        case .connectionClosed:
            return "SFTP connection was closed."
        case .invalidPacket:
            return "Received an invalid or malformed SFTP packet."
        case .unsupportedVersion(let v):
            return "Unsupported SFTP server version: \(v)."
        case .failure(let code, let msg):
            return msg.isEmpty ? "SFTP operation failed (code \(code.rawValue))." : msg
        case .timeout:
            return "SFTP operation timed out."
        case .channelError(let msg):
            return "SSH Channel error: \(msg)"
        }
    }
}

// MARK: - Server Response

nonisolated enum SFTPResponse: Sendable {
    case version(version: UInt32, extensions: [(String, String)])
    case status(requestId: UInt32, code: SFTPStatusCode, message: String)
    case handle(requestId: UInt32, handle: ByteBuffer)
    case data(requestId: UInt32, data: ByteBuffer)
    case name(requestId: UInt32, entries: [SFTPNameEntry])
    case attrs(requestId: UInt32, attributes: SFTPFileAttributes)

    var requestId: UInt32? {
        switch self {
        case .version:
            return nil
        case .status(let reqId, _, _):
            return reqId
        case .handle(let reqId, _):
            return reqId
        case .data(let reqId, _):
            return reqId
        case .name(let reqId, _):
            return reqId
        case .attrs(let reqId, _):
            return reqId
        }
    }

    static func parse(from buffer: inout ByteBuffer) throws -> SFTPResponse? {
        let oldReaderIndex = buffer.readerIndex

        guard let packetLength = buffer.readInteger(as: UInt32.self) else {
            return nil
        }

        guard buffer.readableBytes >= Int(packetLength) else {
            buffer.moveReaderIndex(to: oldReaderIndex)
            return nil
        }

        guard let typeByte = buffer.readInteger(as: UInt8.self),
              var payload = buffer.readSlice(length: Int(packetLength) - 1),
              let type = SFTPMessageType(rawValue: typeByte) else {
            buffer.moveReaderIndex(to: oldReaderIndex)
            throw SFTPClientError.invalidPacket
        }

        switch type {
        case .version:
            guard let version = payload.readInteger(as: UInt32.self) else {
                throw SFTPClientError.invalidPacket
            }
            var extensions: [(String, String)] = []
            while payload.readableBytes > 0 {
                guard let k = payload.readSSHString(), let v = payload.readSSHString() else { break }
                extensions.append((k, v))
            }
            return .version(version: version, extensions: extensions)

        case .status:
            guard let reqId = payload.readInteger(as: UInt32.self),
                  let codeRaw = payload.readInteger(as: UInt32.self) else {
                throw SFTPClientError.invalidPacket
            }
            let code = SFTPStatusCode(rawValue: codeRaw) ?? .failure
            let message = payload.readSSHString() ?? ""
            return .status(requestId: reqId, code: code, message: message)

        case .handle:
            guard let reqId = payload.readInteger(as: UInt32.self),
                  let handle = payload.readSSHBuffer() else {
                throw SFTPClientError.invalidPacket
            }
            return .handle(requestId: reqId, handle: handle)

        case .data:
            guard let reqId = payload.readInteger(as: UInt32.self),
                  let data = payload.readSSHBuffer() else {
                throw SFTPClientError.invalidPacket
            }
            return .data(requestId: reqId, data: data)

        case .name:
            guard let reqId = payload.readInteger(as: UInt32.self),
                  let count = payload.readInteger(as: UInt32.self) else {
                throw SFTPClientError.invalidPacket
            }
            var entries: [SFTPNameEntry] = []
            entries.reserveCapacity(Int(count))
            for _ in 0..<count {
                guard let filename = payload.readSSHString(),
                      let longname = payload.readSSHString(),
                      let attrs = payload.readSFTPFileAttributes() else {
                    throw SFTPClientError.invalidPacket
                }
                entries.append(SFTPNameEntry(filename: filename, longname: longname, attributes: attrs))
            }
            return .name(requestId: reqId, entries: entries)

        case .attrs:
            guard let reqId = payload.readInteger(as: UInt32.self),
                  let attrs = payload.readSFTPFileAttributes() else {
                throw SFTPClientError.invalidPacket
            }
            return .attrs(requestId: reqId, attributes: attrs)

        default:
            throw SFTPClientError.invalidPacket
        }
    }
}

// MARK: - Outbound Request Serializer

nonisolated enum SFTPRequestBuilder {
    /// Builds an SSH_FXP_INIT packet
    static func buildInit(version: UInt32 = 3, allocator: ByteBufferAllocator = .init()) -> ByteBuffer {
        var buffer = allocator.buffer(capacity: 9)
        buffer.writeInteger(UInt32(5)) // length: 1 (type) + 4 (version)
        buffer.writeInteger(SFTPMessageType.initialize.rawValue)
        buffer.writeInteger(version)
        return buffer
    }

    /// Builds an SSH_FXP_OPEN packet
    static func buildOpen(
        requestId: UInt32,
        path: String,
        flags: SFTPOpenFlags,
        attributes: SFTPFileAttributes = .init(),
        allocator: ByteBufferAllocator = .init()
    ) -> ByteBuffer {
        var payload = allocator.buffer(capacity: 128)
        payload.writeInteger(SFTPMessageType.open.rawValue)
        payload.writeInteger(requestId)
        payload.writeSSHString(path)
        payload.writeInteger(flags.rawValue)
        payload.writeSFTPFileAttributes(attributes)

        var packet = allocator.buffer(capacity: 4 + payload.readableBytes)
        packet.writeInteger(UInt32(payload.readableBytes))
        packet.writeBuffer(&payload)
        return packet
    }

    /// Builds an SSH_FXP_CLOSE packet
    static func buildClose(
        requestId: UInt32,
        handle: ByteBuffer,
        allocator: ByteBufferAllocator = .init()
    ) -> ByteBuffer {
        var payload = allocator.buffer(capacity: 32)
        payload.writeInteger(SFTPMessageType.close.rawValue)
        payload.writeInteger(requestId)
        payload.writeSSHBuffer(handle)

        var packet = allocator.buffer(capacity: 4 + payload.readableBytes)
        packet.writeInteger(UInt32(payload.readableBytes))
        packet.writeBuffer(&payload)
        return packet
    }

    /// Builds an SSH_FXP_READ packet
    static func buildRead(
        requestId: UInt32,
        handle: ByteBuffer,
        offset: UInt64,
        length: UInt32,
        allocator: ByteBufferAllocator = .init()
    ) -> ByteBuffer {
        var payload = allocator.buffer(capacity: 64)
        payload.writeInteger(SFTPMessageType.read.rawValue)
        payload.writeInteger(requestId)
        payload.writeSSHBuffer(handle)
        payload.writeInteger(offset)
        payload.writeInteger(length)

        var packet = allocator.buffer(capacity: 4 + payload.readableBytes)
        packet.writeInteger(UInt32(payload.readableBytes))
        packet.writeBuffer(&payload)
        return packet
    }

    /// Builds an SSH_FXP_WRITE packet
    static func buildWrite(
        requestId: UInt32,
        handle: ByteBuffer,
        offset: UInt64,
        data: ByteBuffer,
        allocator: ByteBufferAllocator = .init()
    ) -> ByteBuffer {
        var payload = allocator.buffer(capacity: 64 + data.readableBytes)
        payload.writeInteger(SFTPMessageType.write.rawValue)
        payload.writeInteger(requestId)
        payload.writeSSHBuffer(handle)
        payload.writeInteger(offset)
        payload.writeSSHBuffer(data)

        var packet = allocator.buffer(capacity: 4 + payload.readableBytes)
        packet.writeInteger(UInt32(payload.readableBytes))
        packet.writeBuffer(&payload)
        return packet
    }

    /// Builds an SSH_FXP_OPENDIR packet
    static func buildOpenDir(
        requestId: UInt32,
        path: String,
        allocator: ByteBufferAllocator = .init()
    ) -> ByteBuffer {
        var payload = allocator.buffer(capacity: 64)
        payload.writeInteger(SFTPMessageType.opendir.rawValue)
        payload.writeInteger(requestId)
        payload.writeSSHString(path)

        var packet = allocator.buffer(capacity: 4 + payload.readableBytes)
        packet.writeInteger(UInt32(payload.readableBytes))
        packet.writeBuffer(&payload)
        return packet
    }

    /// Builds an SSH_FXP_READDIR packet
    static func buildReadDir(
        requestId: UInt32,
        handle: ByteBuffer,
        allocator: ByteBufferAllocator = .init()
    ) -> ByteBuffer {
        var payload = allocator.buffer(capacity: 32)
        payload.writeInteger(SFTPMessageType.readdir.rawValue)
        payload.writeInteger(requestId)
        payload.writeSSHBuffer(handle)

        var packet = allocator.buffer(capacity: 4 + payload.readableBytes)
        packet.writeInteger(UInt32(payload.readableBytes))
        packet.writeBuffer(&payload)
        return packet
    }

    /// Builds an SSH_FXP_REMOVE packet (delete file)
    static func buildRemove(
        requestId: UInt32,
        path: String,
        allocator: ByteBufferAllocator = .init()
    ) -> ByteBuffer {
        var payload = allocator.buffer(capacity: 64)
        payload.writeInteger(SFTPMessageType.remove.rawValue)
        payload.writeInteger(requestId)
        payload.writeSSHString(path)

        var packet = allocator.buffer(capacity: 4 + payload.readableBytes)
        packet.writeInteger(UInt32(payload.readableBytes))
        packet.writeBuffer(&payload)
        return packet
    }

    /// Builds an SSH_FXP_MKDIR packet
    static func buildMkDir(
        requestId: UInt32,
        path: String,
        attributes: SFTPFileAttributes = .init(),
        allocator: ByteBufferAllocator = .init()
    ) -> ByteBuffer {
        var payload = allocator.buffer(capacity: 64)
        payload.writeInteger(SFTPMessageType.mkdir.rawValue)
        payload.writeInteger(requestId)
        payload.writeSSHString(path)
        payload.writeSFTPFileAttributes(attributes)

        var packet = allocator.buffer(capacity: 4 + payload.readableBytes)
        packet.writeInteger(UInt32(payload.readableBytes))
        packet.writeBuffer(&payload)
        return packet
    }

    /// Builds an SSH_FXP_RMDIR packet (delete directory)
    static func buildRmDir(
        requestId: UInt32,
        path: String,
        allocator: ByteBufferAllocator = .init()
    ) -> ByteBuffer {
        var payload = allocator.buffer(capacity: 64)
        payload.writeInteger(SFTPMessageType.rmdir.rawValue)
        payload.writeInteger(requestId)
        payload.writeSSHString(path)

        var packet = allocator.buffer(capacity: 4 + payload.readableBytes)
        packet.writeInteger(UInt32(payload.readableBytes))
        packet.writeBuffer(&payload)
        return packet
    }

    /// Builds an SSH_FXP_REALPATH packet
    static func buildRealPath(
        requestId: UInt32,
        path: String,
        allocator: ByteBufferAllocator = .init()
    ) -> ByteBuffer {
        var payload = allocator.buffer(capacity: 64)
        payload.writeInteger(SFTPMessageType.realpath.rawValue)
        payload.writeInteger(requestId)
        payload.writeSSHString(path)

        var packet = allocator.buffer(capacity: 4 + payload.readableBytes)
        packet.writeInteger(UInt32(payload.readableBytes))
        packet.writeBuffer(&payload)
        return packet
    }

    /// Builds an SSH_FXP_STAT packet
    static func buildStat(
        requestId: UInt32,
        path: String,
        allocator: ByteBufferAllocator = .init()
    ) -> ByteBuffer {
        var payload = allocator.buffer(capacity: 64)
        payload.writeInteger(SFTPMessageType.stat.rawValue)
        payload.writeInteger(requestId)
        payload.writeSSHString(path)

        var packet = allocator.buffer(capacity: 4 + payload.readableBytes)
        packet.writeInteger(UInt32(payload.readableBytes))
        packet.writeBuffer(&payload)
        return packet
    }

    /// Builds an SSH_FXP_LSTAT packet (does not follow symlinks)
    static func buildLStat(
        requestId: UInt32,
        path: String,
        allocator: ByteBufferAllocator = .init()
    ) -> ByteBuffer {
        var payload = allocator.buffer(capacity: 64)
        payload.writeInteger(SFTPMessageType.lstat.rawValue)
        payload.writeInteger(requestId)
        payload.writeSSHString(path)

        var packet = allocator.buffer(capacity: 4 + payload.readableBytes)
        packet.writeInteger(UInt32(payload.readableBytes))
        packet.writeBuffer(&payload)
        return packet
    }

    /// Builds an SSH_FXP_FSTAT packet (stat by handle)
    static func buildFStat(
        requestId: UInt32,
        handle: ByteBuffer,
        allocator: ByteBufferAllocator = .init()
    ) -> ByteBuffer {
        var payload = allocator.buffer(capacity: 32)
        payload.writeInteger(SFTPMessageType.fstat.rawValue)
        payload.writeInteger(requestId)
        payload.writeSSHBuffer(handle)

        var packet = allocator.buffer(capacity: 4 + payload.readableBytes)
        packet.writeInteger(UInt32(payload.readableBytes))
        packet.writeBuffer(&payload)
        return packet
    }

    /// Builds an SSH_FXP_RENAME packet
    static func buildRename(
        requestId: UInt32,
        oldPath: String,
        newPath: String,
        allocator: ByteBufferAllocator = .init()
    ) -> ByteBuffer {
        var payload = allocator.buffer(capacity: 128)
        payload.writeInteger(SFTPMessageType.rename.rawValue)
        payload.writeInteger(requestId)
        payload.writeSSHString(oldPath)
        payload.writeSSHString(newPath)

        var packet = allocator.buffer(capacity: 4 + payload.readableBytes)
        packet.writeInteger(UInt32(payload.readableBytes))
        packet.writeBuffer(&payload)
        return packet
    }
}
