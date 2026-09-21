//
//  LocalBookmarkService.swift
//  macSCP
//
//  Service to persist and restore Security-Scoped Bookmarks for local directories
//  enabling App Sandboxed file browsing.
//

import Foundation

final class LocalBookmarkService: @unchecked Sendable {
    static let shared = LocalBookmarkService()

    private let bookmarkKey = "macscp.local.homeBookmarkData"
    private let lock = NSLock()
    private var activeSecurityScopedURL: URL?

    private init() {}

    /// Checks if a bookmark is stored in UserDefaults.
    var hasBookmark: Bool {
        UserDefaults.standard.data(forKey: bookmarkKey) != nil
    }

    /// Restores access to previously saved security-scoped bookmark for the local directory.
    /// Returns the resolved URL if access was successfully restored.
    @discardableResult
    func restoreAccess() -> URL? {
        lock.lock()
        defer { lock.unlock() }

        guard let bookmarkData = UserDefaults.standard.data(forKey: bookmarkKey) else {
            return nil
        }

        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )

            if isStale {
                if let refreshedData = try? url.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                ) {
                    UserDefaults.standard.set(refreshedData, forKey: bookmarkKey)
                }
            }

            if url.startAccessingSecurityScopedResource() {
                if let oldURL = activeSecurityScopedURL, oldURL != url {
                    oldURL.stopAccessingSecurityScopedResource()
                }
                activeSecurityScopedURL = url
                logInfo("Restored security-scoped bookmark for \(url.path)", category: .app)
                return url
            } else {
                logWarning("Failed to start accessing security-scoped resource for \(url.path)", category: .app)
            }
        } catch {
            logError("Failed to resolve security-scoped bookmark: \(error)", category: .app)
        }
        return nil
    }

    /// Creates and saves a security-scoped bookmark for a directory chosen by the user (via NSOpenPanel).
    /// Immediately activates security-scoped access for this session.
    func saveBookmark(for url: URL) throws {
        lock.lock()
        defer { lock.unlock() }

        let bookmarkData = try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        UserDefaults.standard.set(bookmarkData, forKey: bookmarkKey)

        if url.startAccessingSecurityScopedResource() {
            if let oldURL = activeSecurityScopedURL, oldURL != url {
                oldURL.stopAccessingSecurityScopedResource()
            }
            activeSecurityScopedURL = url
            logInfo("Saved and activated security-scoped bookmark for \(url.path)", category: .app)
        }
    }

    /// Stops accessing any currently active security-scoped resource.
    func stopAccess() {
        lock.lock()
        defer { lock.unlock() }
        activeSecurityScopedURL?.stopAccessingSecurityScopedResource()
        activeSecurityScopedURL = nil
    }
}
