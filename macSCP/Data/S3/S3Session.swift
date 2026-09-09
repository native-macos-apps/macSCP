//
//  S3Session.swift
//  macSCP
//
//  Actor-based S3 session using AWS SDK for Swift
//

import AWSS3
import AWSSDKIdentity
import Foundation
import Smithy
import SmithyIdentity

actor S3Session: S3SessionProtocol {
    private var s3: S3Client?
    private(set) var isConnected = false
    private(set) var currentPath = "/"
    private(set) var bucketName = ""
    private var configuredBucketName = ""
    private var regionName = "us-east-1"
    private var endpointURL: URL?
    private var usesPathStyleURLs = false

    init() {}

    // MARK: - Logging Helper
    private nonisolated func log(_ message: String, category: LogCategory = .s3) {
        Task { @MainActor in
            logInfo(message, category: category)
        }
    }

    // MARK: - Connection

    func connect(
        accessKeyId: String,
        secretAccessKey: String,
        region: String,
        bucket: String,
        endpoint: String?
    ) async throws {
        let normalizedBucket = bucket.trimmingCharacters(in: .whitespacesAndNewlines)
        log("Connecting to S3 \(normalizedBucket.isEmpty ? "account" : "bucket: \(normalizedBucket)") in region: \(region)")

        do {
            let credentials = AWSCredentialIdentity(
                accessKey: accessKeyId,
                secret: secretAccessKey
            )
            let identityResolver = StaticAWSCredentialIdentityResolver(credentials)
            let normalizedEndpoint = normalizeEndpointURL(endpoint)
            var configuration = try await S3Client.S3ClientConfig(
                awsCredentialIdentityResolver: identityResolver,
                region: region
            )

            if let normalizedEndpoint {
                configuration.endpoint = normalizedEndpoint.absoluteString
                configuration.forcePathStyle = true
            }
            s3 = S3Client(config: configuration)

            if normalizedBucket.isEmpty {
                _ = try await s3!.listBuckets(input: ListBucketsInput())
            } else {
                let headBucketRequest = HeadBucketInput(bucket: normalizedBucket)
                _ = try await s3!.headBucket(input: headBucketRequest)
            }

            configuredBucketName = normalizedBucket
            bucketName = normalizedBucket
            regionName = region
            endpointURL = normalizedEndpoint
            usesPathStyleURLs = normalizedEndpoint != nil
            currentPath = "/"
            isConnected = true

            log("Connected successfully to S3 \(normalizedBucket.isEmpty ? "account" : "bucket: \(normalizedBucket)")")
        } catch {
            try await cleanup()
            throw parseConnectionError(error)
        }
    }

    func disconnect() async {
        log("Disconnecting from S3")
        try? await cleanup()
        isConnected = false
        currentPath = "/"
        bucketName = ""
        configuredBucketName = ""
        regionName = "us-east-1"
        endpointURL = nil
        usesPathStyleURLs = false
    }

    private func cleanup() async throws {
        s3 = nil
    }

    // MARK: - File Operations

    func listFiles(at path: String) async throws -> [RemoteFile] {
        guard let s3 = s3 else {
            throw AppError.notConnected
        }

        let target = try resolveListTarget(for: path)

        if target.bucket.isEmpty {
            let response = try await s3.listBuckets(input: ListBucketsInput())
            currentPath = "/"
            bucketName = ""

            let buckets = (response.buckets ?? []).compactMap { bucket -> RemoteFile? in
                guard let name = bucket.name, !name.isEmpty else { return nil }
                return RemoteFile(
                    name: name,
                    path: "/" + name,
                    isDirectory: true,
                    size: 0,
                    permissions: "brwxr-xr-x",
                    modificationDate: bucket.creationDate
                )
            }

            return RemoteFile.sortedFiles(buckets, by: .name)
        }

        currentPath = target.displayPath
        bucketName = target.bucket

        var files: [RemoteFile] = []
        var isTruncated = true
        var continuationToken: String? = nil

        while isTruncated {
            let request = ListObjectsV2Input(
                bucket: target.bucket,
                continuationToken: continuationToken,
                delimiter: "/",
                prefix: target.prefix.isEmpty ? nil : target.prefix
            )

            let response = try await s3.listObjectsV2(input: request)

            // Add directories (common prefixes)
            if let commonPrefixes = response.commonPrefixes {
                for prefixObj in commonPrefixes {
                    if let prefixKey = prefixObj.prefix {
                        let name = extractName(from: prefixKey, basePrefix: target.prefix)
                        if !name.isEmpty && name != "/" {
                            let file = RemoteFile(
                                name: name,
                                path: buildDisplayPath(bucket: target.bucket, key: prefixKey),
                                isDirectory: true,
                                size: 0,
                                permissions: "drwxr-xr-x",
                                modificationDate: nil
                            )
                            files.append(file)
                        }
                    }
                }
            }

            // Add files (contents)
            if let contents = response.contents {
                for object in contents {
                    if let key = object.key {
                        // Skip the prefix itself if it's a directory marker
                        if key == target.prefix || key.hasSuffix("/") {
                            continue
                        }

                        let name = extractName(from: key, basePrefix: target.prefix)
                        if !name.isEmpty {
                            let file = RemoteFile(
                                name: name,
                                path: buildDisplayPath(bucket: target.bucket, key: key),
                                isDirectory: false,
                                size: Int64(object.size ?? 0),
                                permissions: "-rw-r--r--",
                                modificationDate: object.lastModified
                            )
                            files.append(file)
                        }
                    }
                }
            }

            isTruncated = response.isTruncated ?? false
            continuationToken = response.nextContinuationToken
        }

        return RemoteFile.sortedFiles(files, by: .name)
    }

    func getFileInfo(at path: String) async throws -> RemoteFile {
        guard let s3 = s3 else {
            throw AppError.notConnected
        }

        let target = try resolveObjectTarget(for: path)
        let key = target.key

        let request = HeadObjectInput(bucket: target.bucket, key: key)

        do {
            let response = try await s3.headObject(input: request)

            let fileName = (path as NSString).lastPathComponent
            let isDirectory = key.hasSuffix("/")

            return RemoteFile(
                name: fileName,
                path: path,
                isDirectory: isDirectory,
                size: response.contentLength.map(Int64.init) ?? 0,
                permissions: isDirectory ? "drwxr-xr-x" : "-rw-r--r--",
                modificationDate: response.lastModified
            )
        } catch {
            throw parseS3Error(error)
        }
    }

    func createDirectory(at path: String) async throws {
        guard let s3 = s3 else {
            throw AppError.notConnected
        }

        // In S3, directories are simulated with a zero-byte object ending with /
        let target = try resolveObjectTarget(for: path)
        var key = target.key
        if !key.hasSuffix("/") {
            key += "/"
        }

        let request = PutObjectInput(
            body: ByteStream.data(Data()),
            bucket: target.bucket,
            key: key
        )

        do {
            _ = try await s3.putObject(input: request)
            log("Created directory: \(path)")
        } catch {
            throw parseS3Error(error)
        }
    }

    func createFile(at path: String) async throws {
        guard let s3 = s3 else {
            throw AppError.notConnected
        }

        let target = try resolveObjectTarget(for: path)
        let key = target.key

        let request = PutObjectInput(
            body: ByteStream.data(Data()),
            bucket: target.bucket,
            key: key
        )

        do {
            _ = try await s3.putObject(input: request)
            log("Created file: \(path)")
        } catch {
            throw parseS3Error(error)
        }
    }

    func deleteFile(at path: String) async throws {
        guard let s3 = s3 else {
            throw AppError.notConnected
        }

        let target = try resolveObjectTarget(for: path)
        let key = target.key

        let request = DeleteObjectInput(bucket: target.bucket, key: key)

        do {
            _ = try await s3.deleteObject(input: request)
            log("Deleted file: \(path)")
        } catch {
            throw parseS3Error(error)
        }
    }

    func deleteDirectory(at path: String) async throws {
        guard let s3 = s3 else {
            throw AppError.notConnected
        }

        let target = try resolveObjectTarget(for: path)
        var prefix = target.key
        if !prefix.hasSuffix("/") {
            prefix += "/"
        }

        // List all objects with this prefix (paginated) and delete them in batches
        var isTruncated = true
        var continuationToken: String? = nil

        while isTruncated {
            let listRequest = ListObjectsV2Input(
                bucket: target.bucket,
                continuationToken: continuationToken,
                prefix: prefix
            )
            let response = try await s3.listObjectsV2(input: listRequest)

            if let contents = response.contents, !contents.isEmpty {
                let objectsToDelete = contents.compactMap { object -> S3ClientTypes.ObjectIdentifier? in
                    guard let key = object.key else { return nil }
                    return S3ClientTypes.ObjectIdentifier(key: key)
                }

                if !objectsToDelete.isEmpty {
                    let deleteRequest = DeleteObjectsInput(
                        bucket: target.bucket,
                        delete: S3ClientTypes.Delete(objects: objectsToDelete)
                    )
                    _ = try await s3.deleteObjects(input: deleteRequest)
                }
            }

            isTruncated = response.isTruncated ?? false
            continuationToken = response.nextContinuationToken
        }

        // Also try to delete the directory marker itself
        let dirMarkerRequest = DeleteObjectInput(bucket: target.bucket, key: prefix)
        _ = try? await s3.deleteObject(input: dirMarkerRequest)

        log("Deleted directory: \(path)")
    }

    func rename(from sourcePath: String, to destinationPath: String) async throws {
        // S3 doesn't support rename, so we copy then delete
        let sourceTarget = try resolveObjectTarget(for: sourcePath)
        let destinationTarget = try resolveObjectTarget(for: destinationPath)
        guard sourceTarget.bucket == destinationTarget.bucket else {
            throw AppError.s3OperationFailed("Moving across buckets is not supported")
        }
        let sourceKey = sourceTarget.key

        // Check if this is a directory (ends with "/" or has objects with this prefix)
        if sourceKey.hasSuffix("/") {
            try await copyDirectory(from: sourcePath, to: destinationPath)
            try await deleteDirectory(at: sourcePath)
        } else {
            // Check if it's a folder without trailing slash by listing objects
            guard let s3 = s3 else {
                throw AppError.notConnected
            }

            let listRequest = ListObjectsV2Input(
                bucket: sourceTarget.bucket,
                maxKeys: 1,
                prefix: sourceKey + "/"
            )
            let response = try await s3.listObjectsV2(input: listRequest)

            if let contents = response.contents, !contents.isEmpty {
                // It's a directory - has objects under it
                try await copyDirectory(from: sourcePath + "/", to: destinationPath + "/")
                try await deleteDirectory(at: sourcePath + "/")
            } else {
                // It's a file
                try await copyFile(from: sourcePath, to: destinationPath)
                try await deleteFile(at: sourcePath)
            }
        }
        log("Renamed \(sourcePath) to \(destinationPath)")
    }

    func copyFile(from sourcePath: String, to destinationPath: String) async throws {
        guard let s3 = s3 else {
            throw AppError.notConnected
        }

        let sourceTarget = try resolveObjectTarget(for: sourcePath)
        let destinationTarget = try resolveObjectTarget(for: destinationPath)
        guard sourceTarget.bucket == destinationTarget.bucket else {
            throw AppError.s3OperationFailed("Copying across buckets is not supported")
        }
        let sourceKey = sourceTarget.key
        let destKey = destinationTarget.key

        let request = CopyObjectInput(
            bucket: destinationTarget.bucket,
            copySource: copySource(bucket: sourceTarget.bucket, key: sourceKey),
            key: destKey
        )

        do {
            _ = try await s3.copyObject(input: request)
            log("Copied file: \(sourcePath) to \(destinationPath)")
        } catch {
            throw parseS3Error(error)
        }
    }

    func copyDirectory(from sourcePath: String, to destinationPath: String) async throws {
        guard let s3 = s3 else {
            throw AppError.notConnected
        }

        let sourceTarget = try resolveObjectTarget(for: sourcePath)
        let destinationTarget = try resolveObjectTarget(for: destinationPath)
        guard sourceTarget.bucket == destinationTarget.bucket else {
            throw AppError.s3OperationFailed("Copying across buckets is not supported")
        }

        var sourcePrefix = sourceTarget.key
        if !sourcePrefix.hasSuffix("/") {
            sourcePrefix += "/"
        }

        var destPrefix = destinationTarget.key
        if !destPrefix.hasSuffix("/") {
            destPrefix += "/"
        }

        // List all objects with source prefix (paginated)
        var isTruncated = true
        var continuationToken: String? = nil

        while isTruncated {
            let listRequest = ListObjectsV2Input(
                bucket: sourceTarget.bucket,
                continuationToken: continuationToken,
                prefix: sourcePrefix
            )
            let response = try await s3.listObjectsV2(input: listRequest)

            if let contents = response.contents {
                for object in contents {
                    if let key = object.key {
                        let relativePath = String(key.dropFirst(sourcePrefix.count))
                        let newKey = destPrefix + relativePath

                        let copyRequest = CopyObjectInput(
                            bucket: destinationTarget.bucket,
                            copySource: copySource(bucket: sourceTarget.bucket, key: key),
                            key: newKey
                        )
                        _ = try await s3.copyObject(input: copyRequest)
                    }
                }
            }

            isTruncated = response.isTruncated ?? false
            continuationToken = response.nextContinuationToken
        }

        log("Copied directory: \(sourcePath) to \(destinationPath)")
    }

    func move(from sourcePath: String, to destinationPath: String) async throws {
        let sourceTarget = try resolveObjectTarget(for: sourcePath)
        let destinationTarget = try resolveObjectTarget(for: destinationPath)
        guard sourceTarget.bucket == destinationTarget.bucket else {
            throw AppError.s3OperationFailed("Moving across buckets is not supported")
        }
        let sourceKey = sourceTarget.key

        if sourceKey.hasSuffix("/") {
            // Moving a directory
            try await copyDirectory(from: sourcePath, to: destinationPath)
            try await deleteDirectory(at: sourcePath)
        } else {
            // Moving a file
            try await copyFile(from: sourcePath, to: destinationPath)
            try await deleteFile(at: sourcePath)
        }

        log("Moved: \(sourcePath) to \(destinationPath)")
    }

    func downloadFile(from remotePath: String, to localURL: URL) async throws {
        try await downloadFile(from: remotePath, to: localURL, progress: nil)
    }

    func downloadFile(from remotePath: String, to localURL: URL, progress: TransferProgressHandler?) async throws {
        if remotePath.hasSuffix("/") {
            try await downloadDirectory(from: remotePath, to: localURL, progress: progress)
            return
        }

        do {
            try await downloadSingleFile(from: remotePath, to: localURL, progress: progress)
        } catch {
            // Check if this path represents a directory/prefix in S3
            if let target = try? resolveObjectTarget(for: remotePath) {
                let prefix = target.key.hasSuffix("/") ? target.key : target.key + "/"
                let listReq = ListObjectsV2Input(bucket: target.bucket, maxKeys: 1, prefix: prefix)
                if let resp = try? await s3?.listObjectsV2(input: listReq), let count = resp.contents?.count, count > 0 {
                    try await downloadDirectory(from: remotePath, to: localURL, progress: progress)
                    return
                }
            }
            throw error
        }
    }

    private func downloadSingleFile(from remotePath: String, to localURL: URL, progress: TransferProgressHandler?) async throws {
        guard let s3 = s3 else {
            throw AppError.notConnected
        }

        let target = try resolveObjectTarget(for: remotePath)
        let key = target.key

        let request = GetObjectInput(bucket: target.bucket, key: key)

        do {
            let response = try await s3.getObject(input: request)
            guard let body = response.body else {
                throw AppError.s3OperationFailed("Missing response body")
            }

            // Report initial progress
            progress?(0)

            // Prepare local destination file
            let parentDir = localURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: localURL.path) {
                try? FileManager.default.removeItem(at: localURL)
            }
            FileManager.default.createFile(atPath: localURL.path, contents: nil)

            switch body {
            case .data(let data):
                if let data = data {
                    try data.write(to: localURL)
                    progress?(Int64(data.count))
                }
            case .stream(let stream):
                let fileHandle = try FileHandle(forWritingTo: localURL)
                defer { try? fileHandle.close() }

                var totalBytes: Int64 = 0
                let chunkSize = 64 * 1024

                while let chunk = try await stream.readAsync(upToCount: chunkSize), !chunk.isEmpty {
                    try Task.checkCancellation()
                    try fileHandle.write(contentsOf: chunk)
                    totalBytes += Int64(chunk.count)
                    progress?(totalBytes)
                }
            case .noStream:
                break
            }

            log("Downloaded: \(remotePath) to \(localURL.path)")
        } catch {
            throw parseS3Error(error)
        }
    }

    private func downloadDirectory(from remotePath: String, to localURL: URL, progress: TransferProgressHandler? = nil) async throws {
        guard let s3 = s3 else {
            throw AppError.notConnected
        }

        let target = try resolveObjectTarget(for: remotePath)
        var prefix = target.key
        if !prefix.hasSuffix("/") && !prefix.isEmpty {
            prefix += "/"
        }

        try FileManager.default.createDirectory(at: localURL, withIntermediateDirectories: true)

        var isTruncated = true
        var continuationToken: String? = nil

        while isTruncated {
            let listRequest = ListObjectsV2Input(
                bucket: target.bucket,
                continuationToken: continuationToken,
                prefix: prefix.isEmpty ? nil : prefix
            )
            let response = try await s3.listObjectsV2(input: listRequest)

            if let contents = response.contents {
                for object in contents {
                    try Task.checkCancellation()
                    guard let key = object.key, !key.hasSuffix("/"), key != prefix else { continue }

                    let relativePath = prefix.isEmpty ? key : String(key.dropFirst(prefix.count))
                    let destLocalURL = localURL.appendingPathComponent(relativePath)

                    let objectRemotePath = buildDisplayPath(bucket: target.bucket, key: key)
                    try await downloadSingleFile(from: objectRemotePath, to: destLocalURL, progress: progress)
                }
            }

            isTruncated = response.isTruncated ?? false
            continuationToken = response.nextContinuationToken
        }
    }

    func uploadFile(from localURL: URL, to remotePath: String) async throws {
        try await uploadFile(from: localURL, to: remotePath, progress: nil)
    }

    func uploadFile(from localURL: URL, to remotePath: String, progress: TransferProgressHandler?) async throws {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: localURL.path, isDirectory: &isDir), isDir.boolValue {
            try await uploadDirectory(from: localURL, to: remotePath, progress: progress)
            return
        }

        try await uploadSingleFile(from: localURL, to: remotePath, progress: progress)
    }

    private func uploadSingleFile(from localURL: URL, to remotePath: String, progress: TransferProgressHandler?) async throws {
        guard let s3 = s3 else {
            throw AppError.notConnected
        }

        let target = try resolveObjectTarget(for: remotePath)
        let key = target.key
        let fileSize = try FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? Int64 ?? 0

        // Use multipart upload for files > 5MB (S3 minimum part size)
        let multipartThreshold: Int64 = 5 * 1024 * 1024

        // Report initial progress
        progress?(0)

        do {
            if fileSize <= multipartThreshold {
                // Small file: read Data and upload
                let data = try Data(contentsOf: localURL)
                let request = PutObjectInput(
                    body: ByteStream.data(data),
                    bucket: target.bucket,
                    key: key
                )
                _ = try await s3.putObject(input: request)

                // Report completion for small files
                progress?(fileSize)
            } else {
                // Large file: use multipart upload to avoid memory issues
                try await uploadMultipart(from: localURL, bucket: target.bucket, key: key, fileSize: fileSize, progress: progress)
            }
            log("Uploaded: \(localURL.path) to \(remotePath)")
        } catch {
            throw parseS3Error(error)
        }
    }

    private func uploadDirectory(from localURL: URL, to remotePath: String, progress: TransferProgressHandler? = nil) async throws {
        guard let s3 = s3 else {
            throw AppError.notConnected
        }

        // Create directory marker in S3
        try? await createDirectory(at: remotePath)

        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: localURL,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: []
        ) else { return }

        for case let fileURL as URL in enumerator {
            try Task.checkCancellation()

            let resourceValues = try fileURL.resourceValues(forKeys: [.isDirectoryKey])
            let relativePath = fileURL.path.replacingOccurrences(of: localURL.path, with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let destRemotePath = remotePath.hasSuffix("/") ? "\(remotePath)\(relativePath)" : "\(remotePath)/\(relativePath)"

            if resourceValues.isDirectory == true {
                try? await createDirectory(at: destRemotePath)
            } else {
                try await uploadSingleFile(from: fileURL, to: destRemotePath, progress: progress)
            }
        }
    }


    /// Uploads a large file using S3 multipart upload
    private func uploadMultipart(from localURL: URL, bucket: String, key: String, fileSize: Int64, progress: TransferProgressHandler? = nil) async throws {
        guard let s3 = s3 else {
            throw AppError.notConnected
        }

        // Use 10MB part size for multipart uploads (larger than minimum 5MB for better performance)
        let partSize = 10 * 1024 * 1024
        let fileHandle = try FileHandle(forReadingFrom: localURL)
        defer { try? fileHandle.close() }

        // 1. Initiate multipart upload
        let createRequest = CreateMultipartUploadInput(bucket: bucket, key: key)
        let createResponse = try await s3.createMultipartUpload(input: createRequest)

        guard let uploadId = createResponse.uploadId else {
            throw AppError.s3OperationFailed("Failed to initiate multipart upload")
        }

        var completedParts: [S3ClientTypes.CompletedPart] = []
        var partNumber = 1
        var offset: UInt64 = 0

        do {
            // 2. Upload parts
            while offset < UInt64(fileSize) {
                try fileHandle.seek(toOffset: offset)
                guard let partData = try fileHandle.read(upToCount: partSize), !partData.isEmpty else {
                    break
                }

                let uploadPartRequest = UploadPartInput(
                    body: ByteStream.data(partData),
                    bucket: bucket,
                    key: key,
                    partNumber: partNumber,
                    uploadId: uploadId
                )

                let partResponse = try await s3.uploadPart(input: uploadPartRequest)

                completedParts.append(S3ClientTypes.CompletedPart(eTag: partResponse.eTag, partNumber: partNumber))
                partNumber += 1
                offset += UInt64(partData.count)

                // Report progress after each part
                progress?(Int64(offset))
            }

            // 3. Complete multipart upload
            let completeRequest = CompleteMultipartUploadInput(
                bucket: bucket,
                key: key,
                multipartUpload: S3ClientTypes.CompletedMultipartUpload(parts: completedParts),
                uploadId: uploadId
            )
            _ = try await s3.completeMultipartUpload(input: completeRequest)

        } catch {
            // Abort multipart upload on failure to clean up partial uploads
            let abortRequest = AbortMultipartUploadInput(
                bucket: bucket,
                key: key,
                uploadId: uploadId
            )
            _ = try? await s3.abortMultipartUpload(input: abortRequest)
            throw error
        }
    }

    func readFileContent(at path: String) async throws -> String {
        guard let s3 = s3 else {
            throw AppError.notConnected
        }

        let target = try resolveObjectTarget(for: path)
        let key = target.key

        let request = GetObjectInput(bucket: target.bucket, key: key)

        do {
            let response = try await s3.getObject(input: request)
            guard let body = response.body else {
                throw AppError.s3OperationFailed("Missing response body")
            }

            let data = try await body.readData() ?? Data()
            let content = String(decoding: data, as: UTF8.self)
            return content
        } catch {
            throw parseS3Error(error)
        }
    }

    func writeFileContent(_ content: String, to path: String) async throws {
        guard let s3 = s3 else {
            throw AppError.notConnected
        }

        let target = try resolveObjectTarget(for: path)
        let key = target.key
        let request = PutObjectInput(
            body: ByteStream.data(Data(content.utf8)),
            bucket: target.bucket,
            key: key
        )

        do {
            _ = try await s3.putObject(input: request)
            log("Wrote content to: \(path)")
        } catch {
            throw parseS3Error(error)
        }
    }

    func getRealPath(at path: String) async throws -> String {
        // S3 doesn't have symlinks, just normalize the path
        if path == "~" || path == "." {
            return currentPath
        }
        if path == ".." {
            // Compute parent path manually since we're in an actor
            let components = currentPath.split(separator: "/")
            if components.count > 1 {
                return "/" + components.dropLast().joined(separator: "/")
            }
            return "/"
        }
        if path.hasPrefix("/") {
            return path
        }
        // Append path component manually
        if currentPath.hasSuffix("/") {
            return currentPath + path
        }
        return currentPath + "/" + path
    }

    func publicURL(for path: String) async throws -> URL {
        guard isConnected else {
            throw AppError.notConnected
        }

        let target = try resolveObjectTarget(for: path)
        let key = target.key
        guard !key.isEmpty else {
            throw AppError.invalidPath
        }

        guard let url = buildObjectURL(bucket: target.bucket, forKey: key) else {
            throw AppError.s3OperationFailed("Failed to build object URL")
        }

        return url
    }

    func presignedURL(for path: String, expiresIn: TimeInterval) async throws -> URL {
        guard let s3 = s3 else {
            throw AppError.notConnected
        }

        let target = try resolveObjectTarget(for: path)
        let key = target.key
        guard !key.isEmpty else {
            throw AppError.invalidPath
        }

        let request = GetObjectInput(bucket: target.bucket, key: key)

        do {
            return try await s3.presignedURLForGetObject(input: request, expiration: expiresIn)
        } catch {
            throw parseS3Error(error)
        }
    }

    // MARK: - Private Helpers

    /// Normalizes a path to an S3 key (removes leading /)
    private func normalizeKey(_ path: String) -> String {
        var key = path
        while key.hasPrefix("/") {
            key = String(key.dropFirst())
        }
        return key
    }

    /// Normalizes a path to a prefix for listing (removes leading /, ensures trailing / for directories)
    private func normalizePrefix(_ path: String) -> String {
        var prefix = path
        while prefix.hasPrefix("/") {
            prefix = String(prefix.dropFirst())
        }
        if prefix == "/" || prefix.isEmpty {
            return ""
        }
        
        if !prefix.hasSuffix("/") {
            prefix += "/"
        }
        
        return prefix
    }

    private func resolveListTarget(for path: String) throws -> (bucket: String, prefix: String, displayPath: String) {
        if !configuredBucketName.isEmpty {
            let prefix = normalizePrefix(path)
            let displayPath = prefix.isEmpty ? "/" : "/" + prefix
            return (configuredBucketName, prefix, displayPath)
        }

        let trimmedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmedPath.isEmpty else {
            return ("", "", "/")
        }

        let components = trimmedPath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let bucket = components[0]
        let remainder = components.dropFirst().joined(separator: "/")
        let prefix = remainder.isEmpty ? "" : remainder + "/"
        return (bucket, prefix, "/" + ([bucket] + (remainder.isEmpty ? [] : [remainder])).joined(separator: "/"))
    }

    private func resolveObjectTarget(for path: String) throws -> (bucket: String, key: String) {
        if !configuredBucketName.isEmpty {
            let key = normalizeKey(path)
            guard !key.isEmpty else {
                throw AppError.invalidPath
            }
            return (configuredBucketName, key)
        }

        let trimmedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let components = trimmedPath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let bucket = components.first else {
            throw AppError.invalidPath
        }

        let key = components.dropFirst().joined(separator: "/")
        guard !key.isEmpty else {
            throw AppError.invalidPath
        }

        return (bucket, key)
    }

    /// Extracts the name from a key given a base prefix
    private func extractName(from key: String, basePrefix: String) -> String {
        var name = String(key.dropFirst(basePrefix.count))
        // Remove trailing slash for directories
        if name.hasSuffix("/") {
            name = String(name.dropLast())
        }
        // Remove any remaining slashes (shouldn't happen with delimiter)
        if let slashIndex = name.firstIndex(of: "/") {
            name = String(name[..<slashIndex])
        }
        return name
    }

    private func copySource(bucket: String, key: String) -> String {
        let raw = "\(bucket)/\(key)"
        return raw.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? raw
    }

    private func normalizeEndpointURL(_ endpoint: String?) -> URL? {
        guard let endpoint else { return nil }
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed), url.scheme != nil {
            return url
        }

        return URL(string: "https://\(trimmed)")
    }

    private func buildDisplayPath(bucket: String, key: String) -> String {
        guard !configuredBucketName.isEmpty else {
            return "/" + bucket + (key.isEmpty ? "" : "/" + key)
        }

        return "/" + key
    }

    private func buildObjectURL(bucket: String, forKey key: String) -> URL? {
        if usesPathStyleURLs, let endpointURL {
            return buildPathStyleURL(baseURL: endpointURL, bucket: bucket, key: key)
        }

        return buildAWSHostedStyleURL(bucket: bucket, forKey: key)
    }

    private func buildPathStyleURL(baseURL: URL, bucket: String, key: String) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }

        let basePath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let bucketPath = percentEncodePathComponent(bucket)
        let keyPath = percentEncodeObjectKey(key)
        let joinedPath = [basePath, bucketPath, keyPath]
            .filter { !$0.isEmpty }
            .joined(separator: "/")

        components.percentEncodedPath = "/" + joinedPath
        return components.url
    }

    private func buildAWSHostedStyleURL(bucket: String, forKey key: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "\(bucket).s3.\(regionName).amazonaws.com"
        components.percentEncodedPath = "/" + percentEncodeObjectKey(key)
        return components.url
    }

    private func percentEncodePathComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? value
    }

    private func percentEncodeObjectKey(_ key: String) -> String {
        key.split(separator: "/", omittingEmptySubsequences: false)
            .map { segment in
                String(segment).addingPercentEncoding(
                    withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
                ) ?? String(segment)
            }
            .joined(separator: "/")
    }

    private func parseConnectionError(_ error: Error) -> AppError {
        let description = error.localizedDescription.lowercased()

        if description.contains("invalid access key") || description.contains("signature") {
            return .invalidS3Credentials
        } else if description.contains("bucket") && description.contains("not found") {
            return .s3BucketNotFound
        } else if description.contains("access denied") || description.contains("forbidden") {
            return .s3AccessDenied
        } else if description.contains("timeout") {
            return .connectionTimeout
        }

        return .connectionFailed(error.localizedDescription)
    }

    private func parseS3Error(_ error: Error) -> AppError {
        let description = String(describing: error).lowercased()

        if description.contains("nosuchbucket") || (description.contains("bucket") && description.contains("not found")) {
            return .s3BucketNotFound
        } else if description.contains("nosuchkey") || description.contains("no such key") || description.contains("not found") {
            return .s3ObjectNotFound
        } else if description.contains("accessdenied") || description.contains("access denied") || description.contains("forbidden") {
            return .s3AccessDenied
        } else if description.contains("invalidsignature") || description.contains("credential") {
            return .invalidS3Credentials
        }

        return .s3OperationFailed(error.localizedDescription)
    }
}
