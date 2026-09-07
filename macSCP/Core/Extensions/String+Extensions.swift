//
//  String+Extensions.swift
//  macSCP
//
//  String utility extensions
//

import Foundation

extension String {
    /// Returns the string with leading and trailing whitespace removed
    nonisolated var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Returns true if the string is empty or contains only whitespace
    nonisolated var isBlank: Bool {
        trimmed.isEmpty
    }

    /// Returns the file name component from a path
    nonisolated var fileName: String {
        (self as NSString).lastPathComponent
    }

    /// Returns the directory path without the file name
    nonisolated var directoryPath: String {
        (self as NSString).deletingLastPathComponent
    }

    /// Returns the file extension
    nonisolated var fileExtension: String {
        (self as NSString).pathExtension
    }

    /// Returns the file name without extension
    nonisolated var fileNameWithoutExtension: String {
        (self as NSString).deletingPathExtension.fileName
    }

    /// Appends a path component
    nonisolated func appendingPathComponent(_ component: String) -> String {
        (self as NSString).appendingPathComponent(component)
    }

    /// Returns the parent directory path
    nonisolated var parentPath: String {
        let components = split(separator: "/")
        if components.count <= 1 {
            return "/"
        }
        return "/" + components.dropLast().joined(separator: "/")
    }

    /// Normalizes a path by resolving . and ..
    nonisolated var normalizedPath: String {
        var components: [String] = []
        for component in split(separator: "/") {
            let part = String(component)
            if part == "." {
                continue
            } else if part == ".." {
                if !components.isEmpty {
                    components.removeLast()
                }
            } else if !part.isEmpty {
                components.append(part)
            }
        }
        return "/" + components.joined(separator: "/")
    }

    /// Returns true if this path is a child of the given parent path
    nonisolated func isChildOf(_ parentPath: String) -> Bool {
        let normalizedSelf = self.normalizedPath
        let normalizedParent = parentPath.normalizedPath
        return normalizedSelf.hasPrefix(normalizedParent + "/")
    }

    /// Returns relative path from a base path
    nonisolated func relativePath(from basePath: String) -> String {
        let normalizedSelf = self.normalizedPath
        let normalizedBase = basePath.normalizedPath

        if normalizedSelf.hasPrefix(normalizedBase) {
            var result = String(normalizedSelf.dropFirst(normalizedBase.count))
            if result.hasPrefix("/") {
                result = String(result.dropFirst())
            }
            return result.isEmpty ? "." : result
        }
        return normalizedSelf
    }
}

// MARK: - Path Building
extension String {
    /// Builds an absolute path from the current directory and a relative or absolute path
    nonisolated func resolvingPath(_ path: String) -> String {
        if path.hasPrefix("/") {
            return path.normalizedPath
        }

        if path == "~" {
            return self // Will be resolved by SFTP
        }

        return self.appendingPathComponent(path).normalizedPath
    }
}
