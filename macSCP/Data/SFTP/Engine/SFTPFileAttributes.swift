//
//  SFTPFileAttributes.swift
//  macSCP
//
//  SFTP v3 File Attributes representation and parser
//

import Foundation
import NIOCore

struct SFTPFileAttributes: Sendable {
    var flags: SFTPAttributeFlags
    var size: UInt64?
    var uid: UInt32?
    var gid: UInt32?
    var permissions: UInt32?
    var accessTime: Date?
    var modificationTime: Date?
    var extended: [(type: String, data: String)]

    nonisolated init(
        flags: SFTPAttributeFlags = [],
        size: UInt64? = nil,
        uid: UInt32? = nil,
        gid: UInt32? = nil,
        permissions: UInt32? = nil,
        accessTime: Date? = nil,
        modificationTime: Date? = nil,
        extended: [(type: String, data: String)] = []
    ) {
        self.flags = flags
        self.size = size
        self.uid = uid
        self.gid = gid
        self.permissions = permissions
        self.accessTime = accessTime
        self.modificationTime = modificationTime
        self.extended = extended
    }

    var isDirectory: Bool {
        guard let permissions = permissions else { return false }
        return (permissions & 0o170000) == 0o040000
    }

    var isSymlink: Bool {
        guard let permissions = permissions else { return false }
        return (permissions & 0o170000) == 0o120000
    }

    var isRegularFile: Bool {
        guard let permissions = permissions else { return false }
        return (permissions & 0o170000) == 0o100000
    }

    func formatPermissions() -> String {
        guard let permissions = permissions else {
            return "----------"
        }

        var result = ""
        let fileType = permissions & 0o170000
        switch fileType {
        case 0o040000: result += "d"
        case 0o120000: result += "l"
        case 0o100000: result += "-"
        case 0o060000: result += "b"
        case 0o020000: result += "c"
        case 0o010000: result += "p"
        case 0o140000: result += "s"
        default: result += "-"
        }

        result += (permissions & 0o400) != 0 ? "r" : "-"
        result += (permissions & 0o200) != 0 ? "w" : "-"
        result += (permissions & 0o100) != 0 ? "x" : "-"
        result += (permissions & 0o040) != 0 ? "r" : "-"
        result += (permissions & 0o020) != 0 ? "w" : "-"
        result += (permissions & 0o010) != 0 ? "x" : "-"
        result += (permissions & 0o004) != 0 ? "r" : "-"
        result += (permissions & 0o002) != 0 ? "w" : "-"
        result += (permissions & 0o001) != 0 ? "x" : "-"

        return result
    }
}

// MARK: - Serialization

extension ByteBuffer {
    mutating func readSFTPFileAttributes() -> SFTPFileAttributes? {
        guard let flagsRaw = self.readInteger(as: UInt32.self) else {
            return nil
        }

        let flags = SFTPAttributeFlags(rawValue: flagsRaw)
        var size: UInt64?
        var uid: UInt32?
        var gid: UInt32?
        var permissions: UInt32?
        var accessTime: Date?
        var modificationTime: Date?
        var extended: [(type: String, data: String)] = []

        if flags.contains(.size) {
            guard let s = self.readInteger(as: UInt64.self) else { return nil }
            size = s
        }

        if flags.contains(.uidgid) {
            guard let u = self.readInteger(as: UInt32.self),
                  let g = self.readInteger(as: UInt32.self) else { return nil }
            uid = u
            gid = g
        }

        if flags.contains(.permissions) {
            guard let p = self.readInteger(as: UInt32.self) else { return nil }
            permissions = p
        }

        if flags.contains(.acmodtime) {
            guard let atimeSec = self.readInteger(as: UInt32.self),
                  let mtimeSec = self.readInteger(as: UInt32.self) else { return nil }
            accessTime = Date(timeIntervalSince1970: TimeInterval(atimeSec))
            modificationTime = Date(timeIntervalSince1970: TimeInterval(mtimeSec))
        }

        if flags.contains(.extended) {
            guard let count = self.readInteger(as: UInt32.self) else { return nil }
            for _ in 0..<count {
                guard let extType = self.readSSHString(),
                      let extData = self.readSSHString() else { return nil }
                extended.append((type: extType, data: extData))
            }
        }

        return SFTPFileAttributes(
            flags: flags,
            size: size,
            uid: uid,
            gid: gid,
            permissions: permissions,
            accessTime: accessTime,
            modificationTime: modificationTime,
            extended: extended
        )
    }

    mutating func writeSFTPFileAttributes(_ attributes: SFTPFileAttributes) {
        var computedFlags = attributes.flags
        if attributes.size != nil { computedFlags.insert(.size) }
        if attributes.uid != nil && attributes.gid != nil { computedFlags.insert(.uidgid) }
        if attributes.permissions != nil { computedFlags.insert(.permissions) }
        if attributes.accessTime != nil && attributes.modificationTime != nil { computedFlags.insert(.acmodtime) }
        if !attributes.extended.isEmpty { computedFlags.insert(.extended) }

        self.writeInteger(computedFlags.rawValue)

        if computedFlags.contains(.size), let size = attributes.size {
            self.writeInteger(size)
        }

        if computedFlags.contains(.uidgid), let uid = attributes.uid, let gid = attributes.gid {
            self.writeInteger(uid)
            self.writeInteger(gid)
        }

        if computedFlags.contains(.permissions), let permissions = attributes.permissions {
            self.writeInteger(permissions)
        }

        if computedFlags.contains(.acmodtime),
           let atime = attributes.accessTime,
           let mtime = attributes.modificationTime {
            self.writeInteger(UInt32(atime.timeIntervalSince1970))
            self.writeInteger(UInt32(mtime.timeIntervalSince1970))
        }

        if computedFlags.contains(.extended) {
            self.writeInteger(UInt32(attributes.extended.count))
            for item in attributes.extended {
                self.writeSSHString(item.type)
                self.writeSSHString(item.data)
            }
        }
    }
}
