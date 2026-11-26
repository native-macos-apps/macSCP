//
//  S3Session+Transfers.swift
//  macSCP
//
//  S3 file/directory transfer, multipart upload, and streaming operations
//

import AWSS3
import Foundation
import Smithy

extension S3Session {
    // MARK: - Download

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
            if let target = try? pathResolver.resolveObjectTarget(for: remotePath) {
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
        let client = try requireClient()
        let target = try pathResolver.resolveObjectTarget(for: remotePath)
        let request = GetObjectInput(bucket: target.bucket, key: target.key)

        do {
            let response = try await client.getObject(input: request)
            guard let body = response.body else {
                throw AppError.s3OperationFailed("Missing response body")
            }

            progress?(0)

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

            logInfo("Downloaded: \(remotePath) to \(localURL.path)", category: .s3)
        } catch {
            throw S3ErrorMapper.mapOperationError(error)
        }
    }

    private func downloadDirectory(from remotePath: String, to localURL: URL, progress: TransferProgressHandler? = nil) async throws {
        let client = try requireClient()
        let target = try pathResolver.resolveObjectTarget(for: remotePath)
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
            let response = try await client.listObjectsV2(input: listRequest)

            if let contents = response.contents {
                for object in contents {
                    try Task.checkCancellation()
                    guard let key = object.key, !key.hasSuffix("/"), key != prefix else { continue }

                    let relativePath = prefix.isEmpty ? key : String(key.dropFirst(prefix.count))
                    let destLocalURL = localURL.appendingPathComponent(relativePath)

                    let objectRemotePath = pathResolver.buildDisplayPath(bucket: target.bucket, key: key)
                    try await downloadSingleFile(from: objectRemotePath, to: destLocalURL, progress: progress)
                }
            }

            isTruncated = response.isTruncated ?? false
            continuationToken = response.nextContinuationToken
        }
    }

    // MARK: - Upload

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
        let client = try requireClient()
        let target = try pathResolver.resolveObjectTarget(for: remotePath)
        let fileSize = try FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? Int64 ?? 0
        let multipartThreshold: Int64 = 5 * 1024 * 1024

        progress?(0)

        do {
            if fileSize <= multipartThreshold {
                let data = try Data(contentsOf: localURL)
                let request = PutObjectInput(
                    body: ByteStream.data(data),
                    bucket: target.bucket,
                    key: target.key
                )
                _ = try await client.putObject(input: request)
                progress?(fileSize)
            } else {
                try await uploadMultipart(from: localURL, bucket: target.bucket, key: target.key, fileSize: fileSize, progress: progress)
            }
            logInfo("Uploaded: \(localURL.path) to \(remotePath)", category: .s3)
        } catch {
            throw S3ErrorMapper.mapOperationError(error)
        }
    }

    private func uploadDirectory(from localURL: URL, to remotePath: String, progress: TransferProgressHandler? = nil) async throws {
        _ = try requireClient()
        try? await createDirectory(at: remotePath)

        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: localURL,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: []
        ) else { return }

        let activeTracker = CumulativeTransferTracker(progress: progress)

        for case let fileURL as URL in enumerator {
            try Task.checkCancellation()

            let resourceValues = try fileURL.resourceValues(forKeys: [.isDirectoryKey])
            let relativePath = fileURL.path.replacingOccurrences(of: localURL.path, with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let destRemotePath = remotePath.hasSuffix("/") ? "\(remotePath)\(relativePath)" : "\(remotePath)/\(relativePath)"

            if resourceValues.isDirectory == true {
                try? await createDirectory(at: destRemotePath)
            } else {
                let attrs = try fileManager.attributesOfItem(atPath: fileURL.path)
                let itemSize = (attrs[.size] as? Int64) ?? 0
                activeTracker.startFile()
                try await uploadSingleFile(from: fileURL, to: destRemotePath, progress: { bytes in
                    activeTracker.updateCurrentFile(bytes: bytes)
                })
                activeTracker.finishFile(size: itemSize)
            }
        }
    }

    private func uploadMultipart(from localURL: URL, bucket: String, key: String, fileSize: Int64, progress: TransferProgressHandler? = nil) async throws {
        let client = try requireClient()
        let partSize = 10 * 1024 * 1024
        let fileHandle = try FileHandle(forReadingFrom: localURL)
        defer { try? fileHandle.close() }

        let createResponse = try await client.createMultipartUpload(
            input: CreateMultipartUploadInput(bucket: bucket, key: key)
        )
        guard let uploadId = createResponse.uploadId else {
            throw AppError.s3OperationFailed("Failed to initiate multipart upload")
        }

        var completedParts: [S3ClientTypes.CompletedPart] = []
        var partNumber = 1
        var offset: UInt64 = 0

        do {
            while offset < UInt64(fileSize) {
                try fileHandle.seek(toOffset: offset)
                guard let partData = try fileHandle.read(upToCount: partSize), !partData.isEmpty else {
                    break
                }

                let partResponse = try await client.uploadPart(input: UploadPartInput(
                    body: ByteStream.data(partData),
                    bucket: bucket,
                    key: key,
                    partNumber: partNumber,
                    uploadId: uploadId
                ))

                completedParts.append(S3ClientTypes.CompletedPart(eTag: partResponse.eTag, partNumber: partNumber))
                partNumber += 1
                offset += UInt64(partData.count)
                progress?(Int64(offset))
            }

            _ = try await client.completeMultipartUpload(input: CompleteMultipartUploadInput(
                bucket: bucket,
                key: key,
                multipartUpload: S3ClientTypes.CompletedMultipartUpload(parts: completedParts),
                uploadId: uploadId
            ))
        } catch {
            _ = try? await client.abortMultipartUpload(
                input: AbortMultipartUploadInput(bucket: bucket, key: key, uploadId: uploadId)
            )
            throw error
        }
    }

    // MARK: - Streaming

    func openStreamReader(at path: String) async throws -> FileStreamReader {
        let client = try requireClient()
        let target = try pathResolver.resolveObjectTarget(for: path)

        do {
            let response = try await client.getObject(input: GetObjectInput(bucket: target.bucket, key: target.key))
            guard let body = response.body else {
                throw AppError.s3OperationFailed("Missing response body")
            }
            return S3StreamReader(body: body)
        } catch {
            throw S3ErrorMapper.mapOperationError(error)
        }
    }

    func writeStream(from reader: FileStreamReader, to path: String, totalSize: Int64?, progress: TransferProgressHandler?) async throws {
        let client = try requireClient()
        let target = try pathResolver.resolveObjectTarget(for: path)
        let minPartSize = 5 * 1024 * 1024

        let initialBuffer = try await readPartBuffer(from: reader, targetSize: minPartSize)

        // Small stream (<= 5 MB): single PutObject without multipart overhead
        if initialBuffer.count < minPartSize {
            do {
                _ = try await client.putObject(input: PutObjectInput(
                    body: ByteStream.data(initialBuffer),
                    bucket: target.bucket,
                    key: target.key
                ))
                progress?(Int64(initialBuffer.count))
                logInfo("Stream uploaded directly (single part): \(path) (\(initialBuffer.count) bytes)", category: .s3)
                return
            } catch {
                throw S3ErrorMapper.mapOperationError(error)
            }
        }

        try await uploadMultipartStream(
            client: client,
            reader: reader,
            initialPart: initialBuffer,
            bucket: target.bucket,
            key: target.key,
            path: path,
            minPartSize: minPartSize,
            progress: progress
        )
    }

    private func readPartBuffer(from reader: FileStreamReader, targetSize: Int) async throws -> Data {
        var buffer = Data()
        while buffer.count < targetSize {
            try Task.checkCancellation()
            guard let chunk = try await reader.readNextChunk(), !chunk.isEmpty else {
                break
            }
            buffer.append(chunk)
        }
        return buffer
    }

    private func uploadMultipartStream(
        client: S3Client,
        reader: FileStreamReader,
        initialPart: Data,
        bucket: String,
        key: String,
        path: String,
        minPartSize: Int,
        progress: TransferProgressHandler?
    ) async throws {
        let createResponse: CreateMultipartUploadOutput
        do {
            createResponse = try await client.createMultipartUpload(
                input: CreateMultipartUploadInput(bucket: bucket, key: key)
            )
        } catch {
            throw S3ErrorMapper.mapOperationError(error)
        }

        guard let uploadId = createResponse.uploadId else {
            throw AppError.s3OperationFailed("Failed to initiate multipart upload")
        }

        var completedParts: [S3ClientTypes.CompletedPart] = []
        var partNumber = 1
        var totalTransferred: Int64 = 0
        var currentBuffer = initialPart

        do {
            while !currentBuffer.isEmpty {
                let partResp = try await client.uploadPart(input: UploadPartInput(
                    body: ByteStream.data(currentBuffer),
                    bucket: bucket,
                    key: key,
                    partNumber: partNumber,
                    uploadId: uploadId
                ))
                completedParts.append(S3ClientTypes.CompletedPart(eTag: partResp.eTag, partNumber: partNumber))
                totalTransferred += Int64(currentBuffer.count)
                partNumber += 1
                progress?(totalTransferred)

                if currentBuffer.count < minPartSize {
                    break
                }
                currentBuffer = try await readPartBuffer(from: reader, targetSize: minPartSize)
            }

            _ = try await client.completeMultipartUpload(input: CompleteMultipartUploadInput(
                bucket: bucket,
                key: key,
                multipartUpload: S3ClientTypes.CompletedMultipartUpload(parts: completedParts),
                uploadId: uploadId
            ))
            logInfo("Stream uploaded (multipart): \(path) (\(totalTransferred) bytes, \(completedParts.count) parts)", category: .s3)
        } catch {
            _ = try? await client.abortMultipartUpload(
                input: AbortMultipartUploadInput(bucket: bucket, key: key, uploadId: uploadId)
            )
            throw S3ErrorMapper.mapOperationError(error)
        }
    }
}

// MARK: - S3StreamReader

actor S3StreamReader: FileStreamReader {
    private let body: ByteStream
    private var dataOffset: Int = 0
    private let chunkSize: Int
    private var isClosed = false

    init(body: ByteStream, chunkSize: Int = 64 * 1024) {
        self.body = body
        self.chunkSize = chunkSize
    }

    func readNextChunk() async throws -> Data? {
        guard !isClosed else { return nil }

        switch body {
        case .stream(let stream):
            let chunk = try await stream.readAsync(upToCount: chunkSize)
            if let chunk = chunk, !chunk.isEmpty {
                return chunk
            }
            return nil

        case .data(let data):
            guard let data = data, dataOffset < data.count else { return nil }
            let nextOffset = min(dataOffset + chunkSize, data.count)
            let chunk = data.subdata(in: dataOffset..<nextOffset)
            dataOffset = nextOffset
            return chunk

        case .noStream:
            return nil
        }
    }

    func close() async {
        isClosed = true
    }
}
