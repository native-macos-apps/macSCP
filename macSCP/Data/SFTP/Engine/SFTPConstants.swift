//
//  SFTPConstants.swift
//  macSCP
//
//  SFTP v3 Protocol Constants and Enums
//

import Foundation

// MARK: - SFTP Message Types (OpCodes)

enum SFTPMessageType: UInt8, Sendable {
    // Client to Server
    case initialize     = 1   // SSH_FXP_INIT
    case open           = 3   // SSH_FXP_OPEN
    case close          = 4   // SSH_FXP_CLOSE
    case read           = 5   // SSH_FXP_READ
    case write          = 6   // SSH_FXP_WRITE
    case lstat          = 7   // SSH_FXP_LSTAT
    case fstat          = 8   // SSH_FXP_FSTAT
    case setstat        = 9   // SSH_FXP_SETSTAT
    case fsetstat       = 10  // SSH_FXP_FSETSTAT
    case opendir        = 11  // SSH_FXP_OPENDIR
    case readdir        = 12  // SSH_FXP_READDIR
    case remove         = 13  // SSH_FXP_REMOVE
    case mkdir          = 14  // SSH_FXP_MKDIR
    case rmdir          = 15  // SSH_FXP_RMDIR
    case realpath       = 16  // SSH_FXP_REALPATH
    case stat           = 17  // SSH_FXP_STAT
    case rename         = 18  // SSH_FXP_RENAME
    case readlink       = 19  // SSH_FXP_READLINK
    case symlink        = 20  // SSH_FXP_SYMLINK
    case extended       = 200 // SSH_FXP_EXTENDED

    // Server to Client
    case version        = 2   // SSH_FXP_VERSION
    case status         = 101 // SSH_FXP_STATUS
    case handle         = 102 // SSH_FXP_HANDLE
    case data           = 103 // SSH_FXP_DATA
    case name           = 104 // SSH_FXP_NAME
    case attrs          = 105 // SSH_FXP_ATTRS
    case extendedReply  = 201 // SSH_FXP_EXTENDED_REPLY
}

// MARK: - SFTP Status Codes

enum SFTPStatusCode: UInt32, Sendable {
    case ok                 = 0 // SSH_FX_OK
    case eof                = 1 // SSH_FX_EOF
    case noSuchFile         = 2 // SSH_FX_NO_SUCH_FILE
    case permissionDenied   = 3 // SSH_FX_PERMISSION_DENIED
    case failure            = 4 // SSH_FX_FAILURE
    case badMessage         = 5 // SSH_FX_BAD_MESSAGE
    case noConnection       = 6 // SSH_FX_NO_CONNECTION
    case connectionLost     = 7 // SSH_FX_CONNECTION_LOST
    case opUnsupported      = 8 // SSH_FX_OP_UNSUPPORTED
}

// MARK: - SFTP Open Flags

struct SFTPOpenFlags: OptionSet, Sendable {
    let rawValue: UInt32

    static let read   = SFTPOpenFlags(rawValue: 0x00000001) // SSH_FXF_READ
    static let write  = SFTPOpenFlags(rawValue: 0x00000002) // SSH_FXF_WRITE
    static let append = SFTPOpenFlags(rawValue: 0x00000004) // SSH_FXF_APPEND
    static let creat  = SFTPOpenFlags(rawValue: 0x00000008) // SSH_FXF_CREAT
    static let trunc  = SFTPOpenFlags(rawValue: 0x00000010) // SSH_FXF_TRUNC
    static let excl   = SFTPOpenFlags(rawValue: 0x00000020) // SSH_FXF_EXCL
}

// MARK: - SFTP Attribute Flags

struct SFTPAttributeFlags: OptionSet, Sendable {
    let rawValue: UInt32

    static let size        = SFTPAttributeFlags(rawValue: 0x00000001) // SSH_FILEXFER_ATTR_SIZE
    static let uidgid      = SFTPAttributeFlags(rawValue: 0x00000002) // SSH_FILEXFER_ATTR_UIDGID
    static let permissions = SFTPAttributeFlags(rawValue: 0x00000004) // SSH_FILEXFER_ATTR_PERMISSIONS
    static let acmodtime   = SFTPAttributeFlags(rawValue: 0x00000008) // SSH_FILEXFER_ATTR_ACMODTIME
    static let extended    = SFTPAttributeFlags(rawValue: 0x80000000) // SSH_FILEXFER_ATTR_EXTENDED
}
