//
//  RemoteDirectoryManager.swift
//  macSCP
//
//  Depth-ordered remote directory creation with bounded concurrency and dependency validation
//

import Foundation

actor RemoteDirectoryManager {
    private let repository: FileRepositoryProtocol
    private let maxConcurrency: Int

    private var createdDirectories: Set<String> = []
    private var failedDirectories: [String: String] = [:]

    init(repository: FileRepositoryProtocol, maxConcurrency: Int = 3) {
        self.repository = repository
        self.maxConcurrency = max(1, min(6, maxConcurrency))
    }

    /// Normalizes path for directory hierarchy checking
    private func normalizePath(_ path: String) -> String {
        var p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while p.contains("//") {
            p = p.replacingOccurrences(of: "//", with: "/")
        }
        if p.hasSuffix("/") && p.count > 1 {
            p.removeLast()
        }
        return p
    }

    /// Checks if any ancestor directory failed to create
    func failureForAncestor(of path: String) -> String? {
        let normalized = normalizePath(path)
        let components = normalized.split(separator: "/").map(String.init)
        guard components.count > 1 else { return nil }

        var current = ""
        // Check all ancestor prefixes up to the immediate parent
        for i in 0..<(components.count - 1) {
            current += "/" + components[i]
            if let error = failedDirectories[current] {
                return "Parent directory '\(current)' creation failed: \(error)"
            }
        }
        return nil
    }

    /// Retrieves all recorded directory creation errors
    func allErrors() -> [String: String] {
        failedDirectories
    }

    /// Creates a list of directories in strict depth order with bounded concurrency.
    /// Returns dictionary of any directory creation failures.
    func createDirectories(_ directories: [String]) async -> [String: String] {
        guard !directories.isEmpty else { return failedDirectories }

        // Clean & deduplicate
        var uniqueSet = Set<String>()
        var cleanedDirs: [String] = []
        for dir in directories {
            let norm = normalizePath(dir)
            if !norm.isEmpty && norm != "/" && !uniqueSet.contains(norm) {
                uniqueSet.insert(norm)
                cleanedDirs.append(norm)
            }
        }

        // Group by depth (count of path components)
        let groupedByDepth = Dictionary(grouping: cleanedDirs) { path -> Int in
            path.split(separator: "/").count
        }
        let sortedDepths = groupedByDepth.keys.sorted()

        // Process depth-by-depth so parents ALWAYS precede children
        for depth in sortedDepths {
            if Task.isCancelled { break }
            guard let dirsAtDepth = groupedByDepth[depth] else { continue }

            // Bounded concurrency within this depth level
            await withTaskGroup(of: (String, Result<Void, Error>).self) { group in
                var index = 0
                let total = dirsAtDepth.count
                let initialCount = min(maxConcurrency, total)

                while index < initialCount {
                    let dir = dirsAtDepth[index]
                    index += 1
                    group.addTask {
                        await self.createSingleDirectory(dir)
                    }
                }

                for await (dir, result) in group {
                    switch result {
                    case .success:
                        self.createdDirectories.insert(dir)
                    case .failure(let error):
                        self.failedDirectories[dir] = error.localizedDescription
                    }

                    if !Task.isCancelled && index < total {
                        let nextDir = dirsAtDepth[index]
                        index += 1
                        group.addTask {
                            await self.createSingleDirectory(nextDir)
                        }
                    }
                }
            }
        }

        return failedDirectories
    }

    private func createSingleDirectory(_ path: String) async -> (String, Result<Void, Error>) {
        if Task.isCancelled {
            return (path, .failure(CancellationError()))
        }

        // Check if an ancestor already failed
        if let ancestorError = failureForAncestor(of: path) {
            let error = NSError(
                domain: "com.macSCP.directoryCreation",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: ancestorError]
            )
            return (path, .failure(error))
        }

        // If already created, skip
        if createdDirectories.contains(path) {
            return (path, .success(()))
        }

        do {
            try await repository.createDirectory(at: path)
            return (path, .success(()))
        } catch {
            // Some servers return error if directory already exists; treat as success if directory exists
            let errString = error.localizedDescription.lowercased()
            if errString.contains("file exists") || errString.contains("already exists") {
                return (path, .success(()))
            }
            return (path, .failure(error))
        }
    }
}
