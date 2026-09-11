//
//  FileRepositoryProtocol.swift
//  macSCP
//
//  Protocol for SFTP file operations
//

import Foundation

protocol FileRepositoryProtocol: Sendable {
    /// Lists files in a directory
    func listFiles(at path: String) async throws -> [RemoteFile]

    /// Gets file attributes
    func getFileInfo(at path: String) async throws -> RemoteFile

    /// Creates a directory
    func createDirectory(at path: String) async throws

    /// Creates an empty file
    func createFile(at path: String) async throws

    /// Deletes a file or directory
    func delete(at path: String, isDirectory: Bool) async throws

    /// Renames a file or directory
    func rename(from sourcePath: String, to destinationPath: String) async throws

    /// Copies a file or directory
    func copy(from sourcePath: String, to destinationPath: String, isDirectory: Bool) async throws

    /// Moves a file or directory
    func move(from sourcePath: String, to destinationPath: String) async throws

    /// Downloads a file to local storage
    func download(remotePath: String, to localURL: URL) async throws

    /// Downloads a file to local storage with progress reporting
    func download(remotePath: String, to localURL: URL, progress: TransferProgressHandler?) async throws

    /// Uploads a file from local storage
    func upload(localURL: URL, to remotePath: String) async throws

    /// Uploads a file from local storage with progress reporting
    func upload(localURL: URL, to remotePath: String, progress: TransferProgressHandler?) async throws

    /// Reads file content as string (for text files)
    func readFileContent(at path: String) async throws -> String

    /// Writes string content to a file
    func writeFileContent(_ content: String, to path: String) async throws

    /// Gets the real path (resolves symlinks and ~)
    func getRealPath(at path: String) async throws -> String

    /// Opens a stream reader to read the file chunk-by-chunk without downloading to local disk
    func openStreamReader(at path: String) async throws -> FileStreamReader

    /// Writes data from a stream reader directly to the target path without using an intermediate local file
    func writeStream(from reader: FileStreamReader, to path: String, totalSize: Int64?, progress: TransferProgressHandler?) async throws
}

extension FileRepositoryProtocol {
    func openStreamReader(at path: String) async throws -> FileStreamReader {
        throw AppError.unknown("Streaming not supported")
    }

    func writeStream(from reader: FileStreamReader, to path: String, totalSize: Int64?, progress: TransferProgressHandler?) async throws {
        throw AppError.unknown("Streaming not supported")
    }
}
