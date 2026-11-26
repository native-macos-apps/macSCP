//
//  FileTypeService.swift
//  macSCP
//
//  Service for file type detection and categorization
//

import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum FileTypeService {
    static func isBucket(_ file: RemoteFile) -> Bool {
        file.isBucket
    }

    /// Returns the native macOS system icon (NSImage) for a file or directory, matching Finder
    static func systemIcon(for file: RemoteFile) -> NSImage {
        if isBucket(file) {
            if let symbol = NSImage(systemSymbolName: "archivebox.fill", accessibilityDescription: "Bucket") {
                let config = NSImage.SymbolConfiguration(hierarchicalColor: .systemOrange)
                return symbol.withSymbolConfiguration(config) ?? symbol
            }
        }

        if file.isDirectory {
            return NSWorkspace.shared.icon(for: .folder)
        }

        if file.isSymlink {
            return NSWorkspace.shared.icon(for: .symbolicLink)
        }

        if let utType = utType(for: file.fileExtension) {
            return NSWorkspace.shared.icon(for: utType)
        }

        if !file.fileExtension.isEmpty {
            return NSWorkspace.shared.icon(forFileType: file.fileExtension)
        }

        return NSWorkspace.shared.icon(for: .item)
    }

    /// Returns whether a file can be previewed/edited in the app
    static func isPreviewable(_ file: RemoteFile) -> Bool {
        guard file.isFile else { return false }
        guard file.size <= FileOperationConstants.maxFilePreviewSize else { return false }

        return file.fileType.isEditable
    }

    /// Returns the UTType for a file extension
    static func utType(for extension: String) -> UTType? {
        UTType(filenameExtension: `extension`)
    }

    /// Returns the MIME type for a file
    static func mimeType(for file: RemoteFile) -> String {
        guard let utType = utType(for: file.fileExtension) else {
            return "application/octet-stream"
        }
        return utType.preferredMIMEType ?? "application/octet-stream"
    }

    private static let extensionDescriptions: [String: String] = [
        "swift": "Swift Source",
        "js": "JavaScript",
        "ts": "TypeScript",
        "py": "Python Script",
        "rb": "Ruby Script",
        "go": "Go Source",
        "rs": "Rust Source",
        "java": "Java Source",
        "c": "C Source",
        "cpp": "C++ Source",
        "cc": "C++ Source",
        "h": "C Header",
        "hpp": "C++ Header",
        "m": "Objective-C Source",
        "html": "HTML Document",
        "htm": "HTML Document",
        "css": "CSS Stylesheet",
        "json": "JSON",
        "xml": "XML Document",
        "yaml": "YAML Document",
        "yml": "YAML Document",
        "md": "Markdown Document",
        "markdown": "Markdown Document",
        "txt": "Plain Text",
        "pdf": "PDF Document",
        "png": "PNG Image",
        "jpg": "JPEG Image",
        "jpeg": "JPEG Image",
        "gif": "GIF Image",
        "svg": "SVG Image",
        "mp4": "MPEG-4 Movie",
        "mov": "QuickTime Movie",
        "mp3": "MP3 Audio",
        "wav": "WAV Audio",
        "zip": "ZIP Archive",
        "tar": "TAR Archive",
        "gz": "Gzip Archive",
        "gzip": "Gzip Archive",
        "dmg": "Disk Image",
        "app": "Application",
        "xcodeproj": "Xcode Project",
        "xcworkspace": "Xcode Workspace"
    ]

    private static let fileTypeDescriptions: [FileType: String] = [
        .directory: "Folder",
        .text: "Plain Text",
        .code: "Source Code",
        .image: "Image",
        .video: "Movie",
        .audio: "Audio",
        .archive: "Archive",
        .document: "Document",
        .spreadsheet: "Spreadsheet",
        .presentation: "Presentation",
        .pdf: "PDF Document",
        .executable: "Unix Executable",
        .configuration: "Configuration",
        .unknown: "Document"
    ]

    /// Returns a human-readable description of the file type (Finder style)
    static func typeDescription(for file: RemoteFile) -> String {
        if isBucket(file) { return "Bucket" }
        if file.isDirectory { return "Folder" }
        if file.isSymlink { return "Alias" }

        let ext = file.fileExtension.lowercased()
        if let specific = extensionDescriptions[ext] {
            return specific
        }

        return fileTypeDescriptions[file.fileType] ?? "Document"
    }

    /// Groups files by their type
    static func groupByType(_ files: [RemoteFile]) -> [FileType: [RemoteFile]] {
        Dictionary(grouping: files, by: { $0.fileType })
    }

    /// Returns files filtered by type
    static func filter(_ files: [RemoteFile], byType type: FileType) -> [RemoteFile] {
        files.filter { $0.fileType == type }
    }
}

// MARK: - File Size Formatting
extension FileTypeService {
    /// Formats a byte count as a human-readable string
    static func formatSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Formats permissions as a human-readable string
    static func formatPermissions(_ permissions: String) -> String {
        guard permissions.count == 10 else { return permissions }

        let type: String
        switch permissions.first {
        case "d": type = "Directory"
        case "l": type = "Symbolic Link"
        case "-": type = "File"
        case "b": type = "Block Device"
        case "c": type = "Character Device"
        case "p": type = "Named Pipe"
        case "s": type = "Socket"
        default: type = "Unknown"
        }

        let permString = String(permissions.dropFirst())
        let owner = formatPermissionGroup(String(permString.prefix(3)))
        let group = formatPermissionGroup(String(permString.dropFirst(3).prefix(3)))
        let other = formatPermissionGroup(String(permString.suffix(3)))

        return "\(type) - Owner: \(owner), Group: \(group), Others: \(other)"
    }

    private static func formatPermissionGroup(_ perms: String) -> String {
        var result: [String] = []
        if perms.contains("r") { result.append("Read") }
        if perms.contains("w") { result.append("Write") }
        if perms.contains("x") { result.append("Execute") }
        return result.isEmpty ? "None" : result.joined(separator: ", ")
    }
}
