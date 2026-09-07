//
//  SFTPByteBuffer+SSH.swift
//  macSCP
//
//  ByteBuffer extensions for SFTP string and buffer serialization
//

import Foundation
import NIOCore

nonisolated extension ByteBuffer {
    /// Reads an SSH-format string (UInt32 length followed by UTF-8 bytes)
    mutating func readSSHString() -> String? {
        guard let length = self.readInteger(as: UInt32.self) else {
            return nil
        }
        guard let string = self.readString(length: Int(length)) else {
            return nil
        }
        return string
    }

    /// Writes an SSH-format string (UInt32 length followed by UTF-8 bytes)
    mutating func writeSSHString(_ string: String) {
        let utf8 = string.utf8
        self.writeInteger(UInt32(utf8.count))
        self.writeBytes(utf8)
    }

    /// Reads an SSH-format buffer (UInt32 length followed by raw bytes)
    mutating func readSSHBuffer() -> ByteBuffer? {
        guard let length = self.readInteger(as: UInt32.self) else {
            return nil
        }
        return self.readSlice(length: Int(length))
    }

    /// Writes an SSH-format buffer (UInt32 length followed by slice bytes)
    mutating func writeSSHBuffer(_ buffer: ByteBuffer) {
        self.writeInteger(UInt32(buffer.readableBytes))
        var mutableBuffer = buffer
        self.writeBuffer(&mutableBuffer)
    }
}
