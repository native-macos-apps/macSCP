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

    /// Returns a human-readable description of the file type (Finder style)
    static func typeDescription(for file: RemoteFile) -> String {
        if isBucket(file) {
            return "Bucket"
        }

        if file.isDirectory {
            return "Folder"
        }

        if file.isSymlink {
            return "Alias"
        }

        // Check for specific extensions first
        switch file.fileExtension.lowercased() {
        case "swift":
            return "Swift Source"
        case "js":
            return "JavaScript"
        case "ts":
            return "TypeScript"
        case "py":
            return "Python Script"
        case "rb":
            return "Ruby Script"
        case "go":
            return "Go Source"
        case "rs":
            return "Rust Source"
        case "java":
            return "Java Source"
        case "c":
            return "C Source"
        case "cpp", "cc":
            return "C++ Source"
        case "h":
            return "C Header"
        case "hpp":
            return "C++ Header"
        case "m":
            return "Objective-C Source"
        case "html", "htm":
            return "HTML Document"
        case "css":
            return "CSS Stylesheet"
        case "json":
            return "JSON"
        case "xml":
            return "XML Document"
        case "yaml", "yml":
            return "YAML Document"
        case "md", "markdown":
            return "Markdown Document"
        case "txt":
            return "Plain Text"
        case "pdf":
            return "PDF Document"
        case "png":
            return "PNG Image"
        case "jpg", "jpeg":
            return "JPEG Image"
        case "gif":
            return "GIF Image"
        case "svg":
            return "SVG Image"
        case "mp4":
            return "MPEG-4 Movie"
        case "mov":
            return "QuickTime Movie"
        case "mp3":
            return "MP3 Audio"
        case "wav":
            return "WAV Audio"
        case "zip":
            return "ZIP Archive"
        case "tar":
            return "TAR Archive"
        case "gz", "gzip":
            return "Gzip Archive"
        case "dmg":
            return "Disk Image"
        case "app":
            return "Application"
        case "xcodeproj":
            return "Xcode Project"
        case "xcworkspace":
            return "Xcode Workspace"
        default:
            break
        }

        // Fallback to general type
        switch file.fileType {
        case .directory:
            return "Folder"
        case .text:
            return "Plain Text"
        case .code:
            return "Source Code"
        case .image:
            return "Image"
        case .video:
            return "Movie"
        case .audio:
            return "Audio"
        case .archive:
            return "Archive"
        case .document:
            return "Document"
        case .spreadsheet:
            return "Spreadsheet"
        case .presentation:
            return "Presentation"
        case .pdf:
            return "PDF Document"
        case .executable:
            return "Unix Executable"
        case .configuration:
            return "Configuration"
        case .unknown:
            if file.fileExtension.isEmpty {
                return "Document"
            }
            return "Document"
        }
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
