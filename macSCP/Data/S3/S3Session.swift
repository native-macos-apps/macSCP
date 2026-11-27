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
    var s3: S3Client?
    private(set) var isConnected = false
    private(set) var currentPath = "/"
    private(set) var bucketName = ""
    var pathResolver = S3PathResolver()

    init() {}

    func requireClient() throws -> S3Client {
        guard let client = s3 else {
            throw AppError.notConnected
        }
        return client
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
        logInfo("Connecting to S3 \(normalizedBucket.isEmpty ? "account" : "bucket: \(normalizedBucket)") in region: \(region)", category: .s3)

        do {
            let credentials = AWSCredentialIdentity(
                accessKey: accessKeyId,
                secret: secretAccessKey
            )
            let identityResolver = StaticAWSCredentialIdentityResolver(credentials)
            let normalizedEndpoint = S3PathResolver.normalizeEndpointURL(endpoint)
            var configuration = try await S3Client.S3ClientConfig(
                awsCredentialIdentityResolver: identityResolver,
                region: region
            )

            if let normalizedEndpoint {
                configuration.endpoint = normalizedEndpoint.absoluteString
                configuration.forcePathStyle = true
            }
            let client = S3Client(config: configuration)
            s3 = client

            if normalizedBucket.isEmpty {
                _ = try await client.listBuckets(input: ListBucketsInput())
            } else {
                _ = try await client.headBucket(input: HeadBucketInput(bucket: normalizedBucket))
            }

            bucketName = normalizedBucket
            pathResolver = S3PathResolver(
                configuredBucketName: normalizedBucket,
                regionName: region,
                endpointURL: normalizedEndpoint,
                usesPathStyleURLs: normalizedEndpoint != nil
            )
            currentPath = "/"
            isConnected = true

            logInfo("Connected successfully to S3 \(normalizedBucket.isEmpty ? "account" : "bucket: \(normalizedBucket)")", category: .s3)
        } catch {
            s3 = nil
            throw S3ErrorMapper.mapConnectionError(error)
        }
    }

    func disconnect() async {
        logInfo("Disconnecting from S3", category: .s3)
        s3 = nil
        isConnected = false
        currentPath = "/"
        bucketName = ""
        pathResolver = S3PathResolver()
    }

    // MARK: - Listing & Metadata

    func listFiles(at path: String) async throws -> [RemoteFile] {
        let client = try requireClient()
        let target = try pathResolver.resolveListTarget(for: path)

        if target.bucket.isEmpty {
            let response = try await client.listBuckets(input: ListBucketsInput())
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
            let response = try await client.listObjectsV2(input: ListObjectsV2Input(
                bucket: target.bucket,
                continuationToken: continuationToken,
                delimiter: "/",
                prefix: target.prefix.isEmpty ? nil : target.prefix
            ))

            if let commonPrefixes = response.commonPrefixes {
                for prefixObj in commonPrefixes {
                    guard let prefixKey = prefixObj.prefix else { continue }
                    let name = pathResolver.extractName(from: prefixKey, basePrefix: target.prefix)
                    guard !name.isEmpty && name != "/" else { continue }
                    files.append(RemoteFile(
                        name: name,
                        path: pathResolver.buildDisplayPath(bucket: target.bucket, key: prefixKey),
                        isDirectory: true,
                        size: 0,
                        permissions: "drwxr-xr-x",
                        modificationDate: nil
                    ))
                }
            }

            if let contents = response.contents {
                for object in contents {
                    guard let key = object.key, key != target.prefix, !key.hasSuffix("/") else { continue }
                    let name = pathResolver.extractName(from: key, basePrefix: target.prefix)
                    guard !name.isEmpty else { continue }
                    files.append(RemoteFile(
                        name: name,
                        path: pathResolver.buildDisplayPath(bucket: target.bucket, key: key),
                        isDirectory: false,
                        size: Int64(object.size ?? 0),
                        permissions: "-rw-r--r--",
                        modificationDate: object.lastModified
                    ))
                }
            }

            isTruncated = response.isTruncated ?? false
            continuationToken = response.nextContinuationToken
        }

        return RemoteFile.sortedFiles(files, by: .name)
    }

    func getFileInfo(at path: String) async throws -> RemoteFile {
        let client = try requireClient()
        let target = try pathResolver.resolveObjectTarget(for: path)

        do {
            let response = try await client.headObject(input: HeadObjectInput(bucket: target.bucket, key: target.key))
            let fileName = (path as NSString).lastPathComponent
            let isDirectory = target.key.hasSuffix("/")

            return RemoteFile(
                name: fileName,
                path: path,
                isDirectory: isDirectory,
                size: response.contentLength.map(Int64.init) ?? 0,
                permissions: isDirectory ? "drwxr-xr-x" : "-rw-r--r--",
                modificationDate: response.lastModified
            )
        } catch {
            throw S3ErrorMapper.mapOperationError(error)
        }
    }

    // MARK: - Object & Directory CRUD

    func createDirectory(at path: String) async throws {
        let client = try requireClient()
        let target = try pathResolver.resolveObjectTarget(for: path)
        let key = target.key.hasSuffix("/") ? target.key : target.key + "/"

        do {
            _ = try await client.putObject(input: PutObjectInput(
                body: ByteStream.data(Data()),
                bucket: target.bucket,
                key: key
            ))
            logInfo("Created directory: \(path)", category: .s3)
        } catch {
            throw S3ErrorMapper.mapOperationError(error)
        }
    }

    func createFile(at path: String) async throws {
        let client = try requireClient()
        let target = try pathResolver.resolveObjectTarget(for: path)

        do {
            _ = try await client.putObject(input: PutObjectInput(
                body: ByteStream.data(Data()),
                bucket: target.bucket,
                key: target.key
            ))
            logInfo("Created file: \(path)", category: .s3)
        } catch {
            throw S3ErrorMapper.mapOperationError(error)
        }
    }

    func deleteFile(at path: String) async throws {
        let client = try requireClient()
        let target = try pathResolver.resolveObjectTarget(for: path)

        do {
            _ = try await client.deleteObject(input: DeleteObjectInput(bucket: target.bucket, key: target.key))
            logInfo("Deleted file: \(path)", category: .s3)
        } catch {
            throw S3ErrorMapper.mapOperationError(error)
        }
    }

    func deleteDirectory(at path: String) async throws {
        let client = try requireClient()
        let target = try pathResolver.resolveObjectTarget(for: path)
        let prefix = target.key.hasSuffix("/") ? target.key : target.key + "/"
        try await Self.deleteDirectoryObjects(
            bucket: target.bucket,
            prefix: prefix,
            list: { try await client.listObjectsV2(input: $0) },
            delete: { try await client.deleteObjects(input: $0) }
        )
        logInfo("Deleted directory: \(path)", category: .s3)
    }

    nonisolated static func deleteDirectoryObjects(
        bucket: String,
        prefix: String,
        list: @Sendable (ListObjectsV2Input) async throws -> ListObjectsV2Output,
        delete: @Sendable (DeleteObjectsInput) async throws -> DeleteObjectsOutput
    ) async throws {
        var continuationToken: String? = nil
        var failureCount = 0
        var failureDetails: [String] = []

        repeat {
            try Task.checkCancellation()
            let response = try await list(ListObjectsV2Input(
                bucket: bucket,
                continuationToken: continuationToken,
                prefix: prefix
            ))

            // The prefix marker itself is included in this listing when it exists.
            let objects = try (response.contents ?? []).map { object in
                guard let key = object.key else {
                    throw AppError.s3OperationFailed("An object under '\(prefix)' was listed without a key.")
                }
                return S3ClientTypes.ObjectIdentifier(key: key)
            }
            if !objects.isEmpty {
                try Task.checkCancellation()
                let result = try await delete(DeleteObjectsInput(
                    bucket: bucket,
                    delete: S3ClientTypes.Delete(objects: objects)
                ))
                let errors = result.errors ?? []
                failureCount += errors.count
                for error in errors.prefix(max(0, 5 - failureDetails.count)) {
                    failureDetails.append("\(error.key ?? "<unknown key>"): \(error.message ?? error.code ?? "Delete failed")")
                }
            }

            guard response.isTruncated == true else { break }
            guard let next = response.nextContinuationToken, next != continuationToken else {
                throw AppError.s3OperationFailed("Incomplete listing while deleting '\(prefix)'.")
            }
            continuationToken = next
        } while true

        if failureCount > 0 {
            let details = failureDetails.joined(separator: "\n")
            throw AppError.s3OperationFailed("Could not delete \(failureCount) object(s) under '\(prefix)'.\n\(details)")
        }
    }

    func rename(from sourcePath: String, to destinationPath: String) async throws {
        let sourceTarget = try pathResolver.resolveObjectTarget(for: sourcePath)
        let destinationTarget = try pathResolver.resolveObjectTarget(for: destinationPath)
        guard sourceTarget.bucket == destinationTarget.bucket else {
            throw AppError.s3OperationFailed("Moving across buckets is not supported")
        }

        if sourcePath.hasSuffix("/") {
            try await copyDirectory(from: sourcePath, to: destinationPath)
            try await deleteDirectory(at: sourcePath)
        } else {
            let client = try requireClient()
            let response = try await client.listObjectsV2(input: ListObjectsV2Input(
                bucket: sourceTarget.bucket,
                maxKeys: 1,
                prefix: sourceTarget.key + "/"
            ))

            if let contents = response.contents, !contents.isEmpty {
                try await copyDirectory(from: sourcePath + "/", to: destinationPath + "/")
                try await deleteDirectory(at: sourcePath + "/")
            } else {
                try await copyFile(from: sourcePath, to: destinationPath)
                try await deleteFile(at: sourcePath)
            }
        }
        logInfo("Renamed \(sourcePath) to \(destinationPath)", category: .s3)
    }

    func copyFile(from sourcePath: String, to destinationPath: String) async throws {
        let sourceTarget = try pathResolver.resolveObjectTarget(for: sourcePath)
        let destinationTarget = try pathResolver.resolveObjectTarget(for: destinationPath)
        guard sourceTarget.bucket == destinationTarget.bucket else {
            throw AppError.s3OperationFailed("Copying across buckets is not supported")
        }
        guard !sourceTarget.key.utf8.elementsEqual(destinationTarget.key.utf8) else {
            throw AppError.s3OperationFailed("The source and destination are the same object.")
        }
        let client = try requireClient()

        do {
            _ = try await client.copyObject(input: CopyObjectInput(
                bucket: destinationTarget.bucket,
                copySource: pathResolver.copySource(bucket: sourceTarget.bucket, key: sourceTarget.key),
                key: destinationTarget.key
            ))
            logInfo("Copied file: \(sourcePath) to \(destinationPath)", category: .s3)
        } catch {
            throw S3ErrorMapper.mapOperationError(error)
        }
    }

    func copyDirectory(from sourcePath: String, to destinationPath: String) async throws {
        let sourceTarget = try pathResolver.resolveObjectTarget(for: sourcePath)
        let destinationTarget = try pathResolver.resolveObjectTarget(for: destinationPath)
        guard sourceTarget.bucket == destinationTarget.bucket else {
            throw AppError.s3OperationFailed("Copying across buckets is not supported")
        }

        let sourcePrefix = sourceTarget.key.hasSuffix("/") ? sourceTarget.key : sourceTarget.key + "/"
        let destPrefix = destinationTarget.key.hasSuffix("/") ? destinationTarget.key : destinationTarget.key + "/"
        guard !destPrefix.utf8.starts(with: sourcePrefix.utf8),
              !sourcePrefix.utf8.starts(with: destPrefix.utf8) else {
            throw AppError.s3OperationFailed("The source and destination folders overlap.")
        }

        let client = try requireClient()
        var isTruncated = true
        var continuationToken: String? = nil

        while isTruncated {
            let response = try await client.listObjectsV2(input: ListObjectsV2Input(
                bucket: sourceTarget.bucket,
                continuationToken: continuationToken,
                prefix: sourcePrefix
            ))

            if let contents = response.contents {
                for object in contents {
                    guard let key = object.key else { continue }
                    let relativePath = String(key.dropFirst(sourcePrefix.count))
                    let newKey = destPrefix + relativePath
                    _ = try await client.copyObject(input: CopyObjectInput(
                        bucket: destinationTarget.bucket,
                        copySource: pathResolver.copySource(bucket: sourceTarget.bucket, key: key),
                        key: newKey
                    ))
                }
            }

            isTruncated = response.isTruncated ?? false
            continuationToken = response.nextContinuationToken
        }

        logInfo("Copied directory: \(sourcePath) to \(destinationPath)", category: .s3)
    }

    func move(from sourcePath: String, to destinationPath: String) async throws {
        let sourceTarget = try pathResolver.resolveObjectTarget(for: sourcePath)
        let destinationTarget = try pathResolver.resolveObjectTarget(for: destinationPath)
        guard sourceTarget.bucket == destinationTarget.bucket else {
            throw AppError.s3OperationFailed("Moving across buckets is not supported")
        }

        if sourcePath.hasSuffix("/") {
            try await copyDirectory(from: sourcePath, to: destinationPath)
            try await deleteDirectory(at: sourcePath)
        } else {
            try await copyFile(from: sourcePath, to: destinationPath)
            try await deleteFile(at: sourcePath)
        }
        logInfo("Moved: \(sourcePath) to \(destinationPath)", category: .s3)
    }

    // MARK: - File Content & Paths

    func readFileContent(at path: String) async throws -> String {
        let client = try requireClient()
        let target = try pathResolver.resolveObjectTarget(for: path)

        do {
            let response = try await client.getObject(input: GetObjectInput(bucket: target.bucket, key: target.key))
            guard let body = response.body else {
                throw AppError.s3OperationFailed("Missing response body")
            }

            let data = try await body.readData() ?? Data()
            guard let content = String(data: data, encoding: .utf8) else {
                throw AppError.invalidFileEncoding
            }
            return content
        } catch let appError as AppError {
            throw appError
        } catch {
            throw S3ErrorMapper.mapOperationError(error)
        }
    }

    func writeFileContent(_ content: String, to path: String) async throws {
        let client = try requireClient()
        let target = try pathResolver.resolveObjectTarget(for: path)

        do {
            _ = try await client.putObject(input: PutObjectInput(
                body: ByteStream.data(Data(content.utf8)),
                bucket: target.bucket,
                key: target.key
            ))
            logInfo("Wrote content to: \(path)", category: .s3)
        } catch {
            throw S3ErrorMapper.mapOperationError(error)
        }
    }

    func getRealPath(at path: String) async throws -> String {
        if path == "~" || path == "." {
            return currentPath
        }
        if path == ".." {
            let components = currentPath.split(separator: "/")
            if components.count > 1 {
                return "/" + components.dropLast().joined(separator: "/")
            }
            return "/"
        }
        if path.hasPrefix("/") {
            return path
        }
        return currentPath.hasSuffix("/") ? currentPath + path : currentPath + "/" + path
    }

    // MARK: - Object URLs

    func publicURL(for path: String) async throws -> URL {
        guard isConnected else {
            throw AppError.notConnected
        }

        let target = try pathResolver.resolveObjectTarget(for: path)
        guard !target.key.isEmpty else {
            throw AppError.invalidPath
        }

        guard let url = pathResolver.buildObjectURL(bucket: target.bucket, forKey: target.key) else {
            throw AppError.s3OperationFailed("Failed to build object URL")
        }

        return url
    }

    func presignedURL(for path: String, expiresIn: TimeInterval) async throws -> URL {
        let client = try requireClient()
        let target = try pathResolver.resolveObjectTarget(for: path)
        guard !target.key.isEmpty else {
            throw AppError.invalidPath
        }

        do {
            return try await client.presignedURLForGetObject(
                input: GetObjectInput(bucket: target.bucket, key: target.key),
                expiration: expiresIn
            )
        } catch {
            throw S3ErrorMapper.mapOperationError(error)
        }
    }
}
