//
//  SFTPEngineTests.swift
//  macSCPTests
//
//  Unit and in-process loopback integration tests for SFTPMessages,
//  SFTPFileAttributes, SFTPChannelHandler, SFTPClient, SFTPTransferEngine,
//  and SFTPSession.
//

import XCTest
import NIOCore
import NIOPosix
import NIOFoundationCompat
@preconcurrency import NIOSSH
@testable import macSCP

// MARK: - Pure In-Memory NIOCore Channel (sandbox-safe, zero sockets)

private nonisolated final class InMemorySFTPOutboundHandler: ChannelOutboundHandler, @unchecked Sendable {
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let fs: MockSFTPFilesystem
    private let sftpHandler: SFTPChannelHandler
    nonisolated(unsafe) weak var delegate: SFTPChannelHandlerDelegate?

    nonisolated init(fs: MockSFTPFilesystem, sftpHandler: SFTPChannelHandler) {
        self.fs = fs
        self.sftpHandler = sftpHandler
    }

    nonisolated func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        var packet = unwrapOutboundIn(data)
        promise?.succeed(())

        let allocator = context.channel.allocator
        context.eventLoop.execute { [weak self] in
            guard let self else { return }
            guard let length = packet.readInteger(as: UInt32.self),
                  packet.readableBytes >= Int(length),
                  let typeRaw = packet.readInteger(as: UInt8.self),
                  var payload = packet.readSlice(length: Int(length) - 1),
                  let type = SFTPMessageType(rawValue: typeRaw) else {
                return
            }

            var responseBuffer = self.fs.handlePacket(type: type, payload: &payload, allocator: allocator)
            do {
                while let response = try SFTPResponse.parse(from: &responseBuffer) {
                    self.delegate?.sftpChannelHandler(self.sftpHandler, didReceiveResponse: response)
                }
            } catch {
                self.delegate?.sftpChannelHandler(self.sftpHandler, didCloseWithError: error)
            }
        }
    }
}

private nonisolated final class InMemorySFTPChannel: Channel, ChannelCore, @unchecked Sendable {
    let allocator = ByteBufferAllocator()
    let eventLoop: EventLoop
    let sftpHandler = SFTPChannelHandler()
    let outboundHandler: InMemorySFTPOutboundHandler
    nonisolated(unsafe) var _pipeline: ChannelPipeline!

    private let closePromise: EventLoopPromise<Void>
    private let lock = NSLock()
    private var _isActive = true

    nonisolated init(eventLoop: EventLoop, fs: MockSFTPFilesystem) {
        self.eventLoop = eventLoop
        self.outboundHandler = InMemorySFTPOutboundHandler(fs: fs, sftpHandler: sftpHandler)
        self.closePromise = eventLoop.makePromise(of: Void.self)
        self._pipeline = ChannelPipeline(channel: self)
    }

    var delegate: SFTPChannelHandlerDelegate? {
        get { outboundHandler.delegate }
        set { outboundHandler.delegate = newValue }
    }

    func installHandler() async throws {
        try await _pipeline.addHandler(outboundHandler).get()
    }

    var closeFuture: EventLoopFuture<Void> { closePromise.futureResult }
    var pipeline: ChannelPipeline { _pipeline }
    var localAddress: SocketAddress? { nil }
    var remoteAddress: SocketAddress? { nil }
    var parent: Channel? { nil }
    var _channelCore: ChannelCore { self }
    var isWritable: Bool { true }
    var isActive: Bool { lock.withLock { _isActive } }

    func setOption<Option: ChannelOption>(_ option: Option, value: Option.Value) -> EventLoopFuture<Void> {
        eventLoop.makeSucceededVoidFuture()
    }

    func getOption<Option: ChannelOption>(_ option: Option) -> EventLoopFuture<Option.Value> {
        eventLoop.makeFailedFuture(SFTPClientError.channelError("Unsupported option"))
    }

    // MARK: - ChannelCore

    func localAddress0() throws -> SocketAddress { try SocketAddress(ipAddress: "127.0.0.1", port: 0) }
    func remoteAddress0() throws -> SocketAddress { try SocketAddress(ipAddress: "127.0.0.1", port: 0) }
    func register0(promise: EventLoopPromise<Void>?) { promise?.succeed(()) }
    func registerAlreadyConfigured0(promise: EventLoopPromise<Void>?) { promise?.succeed(()) }
    func bind0(to address: SocketAddress, promise: EventLoopPromise<Void>?) { promise?.succeed(()) }
    func connect0(to address: SocketAddress, promise: EventLoopPromise<Void>?) { promise?.succeed(()) }
    func write0(_ data: NIOAny, promise: EventLoopPromise<Void>?) { promise?.succeed(()) }
    func flush0() {}
    func read0() {}
    func triggerUserOutboundEvent0(_ event: Any, promise: EventLoopPromise<Void>?) { promise?.succeed(()) }
    func channelRead0(_ data: NIOAny) {}
    func errorCaught0(error: Error) {}

    func close0(error: Error, mode: CloseMode, promise: EventLoopPromise<Void>?) {
        let shouldClose = lock.withLock { () -> Bool in
            guard _isActive else { return false }
            _isActive = false
            return true
        }
        if shouldClose {
            closePromise.succeed(())
            outboundHandler.delegate?.sftpChannelHandler(sftpHandler, didCloseWithError: nil)
        }
        promise?.succeed(())
    }
}

// MARK: - In-Memory Mock SFTP v3 Server

private nonisolated final class MockSFTPFilesystem: @unchecked Sendable {
    private let lock = NSLock()
    private var directories: Set<String> = ["/", "/home", "/home/user"]
    private var files: [String: Data] = [:]
    private var openFileHandles: [UInt32: String] = [:]
    private var openDirHandles: [UInt32: (path: String, sent: Bool)] = [:]
    private var nextHandleId: UInt32 = 1
    var homePath: String = "/home/user"
    var permissionDeniedPaths: Set<String> = []

    func seedFile(path: String, data: Data) {
        lock.withLock {
            ensureParentDirsLocked(for: path)
            files[normalize(path)] = data
        }
    }

    func seedDirectory(path: String) {
        lock.withLock {
            directories.insert(normalize(path))
        }
    }

    func fileData(at path: String) -> Data? {
        lock.withLock { files[normalize(path)] }
    }

    func directoryExists(at path: String) -> Bool {
        lock.withLock { directories.contains(normalize(path)) }
    }

    private func normalize(_ path: String) -> String {
        if path == "." || path == "~" { return homePath }
        var p = path
        while p.count > 1 && p.hasSuffix("/") {
            p.removeLast()
        }
        return p.isEmpty ? "/" : p
    }

    private func ensureParentDirsLocked(for path: String) {
        var current = (normalize(path) as NSString).deletingLastPathComponent
        while !current.isEmpty && current != "/" {
            directories.insert(current)
            current = (current as NSString).deletingLastPathComponent
        }
        directories.insert("/")
    }

    func handlePacket(type: SFTPMessageType, payload: inout ByteBuffer, allocator: ByteBufferAllocator) -> ByteBuffer {
        lock.lock()
        defer { lock.unlock() }

        switch type {
        case .initialize:
            return buildVersion(version: 3, allocator: allocator)

        case .realpath:
            let reqId = payload.readInteger(as: UInt32.self) ?? 0
            let rawPath = payload.readSSHString() ?? "."
            let resolved = normalize(rawPath)
            let attrs = SFTPFileAttributes(permissions: 0o040755)
            return buildName(requestId: reqId, entries: [(resolved, resolved, attrs)], allocator: allocator)

        case .stat, .lstat:
            let reqId = payload.readInteger(as: UInt32.self) ?? 0
            let path = normalize(payload.readSSHString() ?? "")
            if permissionDeniedPaths.contains(path) {
                return buildStatus(requestId: reqId, code: .permissionDenied, message: "Permission denied", allocator: allocator)
            }
            if directories.contains(path) {
                return buildAttrs(requestId: reqId, attrs: SFTPFileAttributes(size: 0, permissions: 0o040755), allocator: allocator)
            }
            if let data = files[path] {
                return buildAttrs(requestId: reqId, attrs: SFTPFileAttributes(size: UInt64(data.count), permissions: 0o100644), allocator: allocator)
            }
            return buildStatus(requestId: reqId, code: .noSuchFile, message: "No such file", allocator: allocator)

        case .open:
            let reqId = payload.readInteger(as: UInt32.self) ?? 0
            let path = normalize(payload.readSSHString() ?? "")
            let flagsRaw = payload.readInteger(as: UInt32.self) ?? 0
            let flags = SFTPOpenFlags(rawValue: flagsRaw)
            _ = payload.readSFTPFileAttributes()

            if permissionDeniedPaths.contains(path) {
                return buildStatus(requestId: reqId, code: .permissionDenied, message: "Permission denied", allocator: allocator)
            }

            if flags.contains(.write) {
                if flags.contains(.trunc) || files[path] == nil {
                    ensureParentDirsLocked(for: path)
                    files[path] = Data()
                }
            } else if files[path] == nil {
                return buildStatus(requestId: reqId, code: .noSuchFile, message: "No such file", allocator: allocator)
            }

            let hid = nextHandleId
            nextHandleId += 1
            openFileHandles[hid] = path
            return buildHandle(requestId: reqId, handleId: hid, allocator: allocator)

        case .read:
            let reqId = payload.readInteger(as: UInt32.self) ?? 0
            guard var handleBuf = payload.readSSHBuffer(),
                  let hid = handleBuf.readInteger(as: UInt32.self),
                  let offset = payload.readInteger(as: UInt64.self),
                  let length = payload.readInteger(as: UInt32.self),
                  let path = openFileHandles[hid],
                  let data = files[path] else {
                return buildStatus(requestId: reqId, code: .failure, message: "Invalid handle", allocator: allocator)
            }
            if offset >= UInt64(data.count) {
                return buildStatus(requestId: reqId, code: .eof, message: "EOF", allocator: allocator)
            }
            let start = Int(offset)
            let end = min(data.count, start + Int(length))
            let slice = data[start..<end]
            return buildData(requestId: reqId, data: Data(slice), allocator: allocator)

        case .write:
            let reqId = payload.readInteger(as: UInt32.self) ?? 0
            guard var handleBuf = payload.readSSHBuffer(),
                  let hid = handleBuf.readInteger(as: UInt32.self),
                  let offset = payload.readInteger(as: UInt64.self),
                  let chunkBuf = payload.readSSHBuffer(),
                  let path = openFileHandles[hid] else {
                return buildStatus(requestId: reqId, code: .failure, message: "Invalid handle", allocator: allocator)
            }
            let chunk = Data(buffer: chunkBuf)
            var current = files[path] ?? Data()
            let start = Int(offset)
            let needed = start + chunk.count
            if current.count < needed {
                current.append(Data(repeating: 0, count: needed - current.count))
            }
            current.replaceSubrange(start..<needed, with: chunk)
            files[path] = current
            return buildStatus(requestId: reqId, code: .ok, message: "", allocator: allocator)

        case .close:
            let reqId = payload.readInteger(as: UInt32.self) ?? 0
            if var handleBuf = payload.readSSHBuffer(), let hid = handleBuf.readInteger(as: UInt32.self) {
                openFileHandles.removeValue(forKey: hid)
                openDirHandles.removeValue(forKey: hid)
            }
            return buildStatus(requestId: reqId, code: .ok, message: "", allocator: allocator)

        case .opendir:
            let reqId = payload.readInteger(as: UInt32.self) ?? 0
            let path = normalize(payload.readSSHString() ?? "")
            guard directories.contains(path) else {
                return buildStatus(requestId: reqId, code: .noSuchFile, message: "No such directory", allocator: allocator)
            }
            let hid = nextHandleId
            nextHandleId += 1
            openDirHandles[hid] = (path: path, sent: false)
            return buildHandle(requestId: reqId, handleId: hid, allocator: allocator)

        case .readdir:
            let reqId = payload.readInteger(as: UInt32.self) ?? 0
            guard var handleBuf = payload.readSSHBuffer(),
                  let hid = handleBuf.readInteger(as: UInt32.self),
                  let state = openDirHandles[hid] else {
                return buildStatus(requestId: reqId, code: .failure, message: "Invalid dir handle", allocator: allocator)
            }
            if state.sent {
                return buildStatus(requestId: reqId, code: .eof, message: "EOF", allocator: allocator)
            }
            openDirHandles[hid] = (path: state.path, sent: true)

            var entries: [(String, String, SFTPFileAttributes)] = [
                (".", "drwxr-xr-x .", SFTPFileAttributes(permissions: 0o040755)),
                ("..", "drwxr-xr-x ..", SFTPFileAttributes(permissions: 0o040755))
            ]

            for dir in directories where dir != state.path {
                if (dir as NSString).deletingLastPathComponent == state.path {
                    let name = (dir as NSString).lastPathComponent
                    entries.append((name, "drwxr-xr-x \(name)", SFTPFileAttributes(size: 0, permissions: 0o040755)))
                }
            }
            for (filePath, data) in files {
                if (filePath as NSString).deletingLastPathComponent == state.path {
                    let name = (filePath as NSString).lastPathComponent
                    entries.append((name, "-rw-r--r-- \(name)", SFTPFileAttributes(size: UInt64(data.count), permissions: 0o100644)))
                }
            }
            return buildName(requestId: reqId, entries: entries, allocator: allocator)

        case .mkdir:
            let reqId = payload.readInteger(as: UInt32.self) ?? 0
            let path = normalize(payload.readSSHString() ?? "")
            directories.insert(path)
            return buildStatus(requestId: reqId, code: .ok, message: "", allocator: allocator)

        case .remove:
            let reqId = payload.readInteger(as: UInt32.self) ?? 0
            let path = normalize(payload.readSSHString() ?? "")
            guard files.removeValue(forKey: path) != nil else {
                return buildStatus(requestId: reqId, code: .noSuchFile, message: "No such file", allocator: allocator)
            }
            return buildStatus(requestId: reqId, code: .ok, message: "", allocator: allocator)

        case .rmdir:
            let reqId = payload.readInteger(as: UInt32.self) ?? 0
            let path = normalize(payload.readSSHString() ?? "")
            guard directories.remove(path) != nil else {
                return buildStatus(requestId: reqId, code: .noSuchFile, message: "No such directory", allocator: allocator)
            }
            return buildStatus(requestId: reqId, code: .ok, message: "", allocator: allocator)

        case .rename:
            let reqId = payload.readInteger(as: UInt32.self) ?? 0
            let oldPath = normalize(payload.readSSHString() ?? "")
            let newPath = normalize(payload.readSSHString() ?? "")
            if let data = files.removeValue(forKey: oldPath) {
                ensureParentDirsLocked(for: newPath)
                files[newPath] = data
                return buildStatus(requestId: reqId, code: .ok, message: "", allocator: allocator)
            }
            return buildStatus(requestId: reqId, code: .noSuchFile, message: "No such file", allocator: allocator)

        default:
            let reqId = payload.readInteger(as: UInt32.self) ?? 0
            return buildStatus(requestId: reqId, code: .opUnsupported, message: "Unsupported", allocator: allocator)
        }
    }

    // MARK: - Response Builders

    private func wrap(_ payload: inout ByteBuffer, allocator: ByteBufferAllocator) -> ByteBuffer {
        var packet = allocator.buffer(capacity: 4 + payload.readableBytes)
        packet.writeInteger(UInt32(payload.readableBytes))
        packet.writeBuffer(&payload)
        return packet
    }

    private func buildVersion(version: UInt32, allocator: ByteBufferAllocator) -> ByteBuffer {
        var payload = allocator.buffer(capacity: 16)
        payload.writeInteger(SFTPMessageType.version.rawValue)
        payload.writeInteger(version)
        return wrap(&payload, allocator: allocator)
    }

    private func buildStatus(requestId: UInt32, code: SFTPStatusCode, message: String, allocator: ByteBufferAllocator) -> ByteBuffer {
        var payload = allocator.buffer(capacity: 64)
        payload.writeInteger(SFTPMessageType.status.rawValue)
        payload.writeInteger(requestId)
        payload.writeInteger(code.rawValue)
        payload.writeSSHString(message)
        payload.writeSSHString("en")
        return wrap(&payload, allocator: allocator)
    }

    private func buildHandle(requestId: UInt32, handleId: UInt32, allocator: ByteBufferAllocator) -> ByteBuffer {
        var handleBuf = allocator.buffer(capacity: 4)
        handleBuf.writeInteger(handleId)
        var payload = allocator.buffer(capacity: 32)
        payload.writeInteger(SFTPMessageType.handle.rawValue)
        payload.writeInteger(requestId)
        payload.writeSSHBuffer(handleBuf)
        return wrap(&payload, allocator: allocator)
    }

    private func buildData(requestId: UInt32, data: Data, allocator: ByteBufferAllocator) -> ByteBuffer {
        var dataBuf = allocator.buffer(capacity: data.count)
        dataBuf.writeBytes(data)
        var payload = allocator.buffer(capacity: 16 + data.count)
        payload.writeInteger(SFTPMessageType.data.rawValue)
        payload.writeInteger(requestId)
        payload.writeSSHBuffer(dataBuf)
        return wrap(&payload, allocator: allocator)
    }

    private func buildAttrs(requestId: UInt32, attrs: SFTPFileAttributes, allocator: ByteBufferAllocator) -> ByteBuffer {
        var payload = allocator.buffer(capacity: 64)
        payload.writeInteger(SFTPMessageType.attrs.rawValue)
        payload.writeInteger(requestId)
        payload.writeSFTPFileAttributes(attrs)
        return wrap(&payload, allocator: allocator)
    }

    private func buildName(requestId: UInt32, entries: [(String, String, SFTPFileAttributes)], allocator: ByteBufferAllocator) -> ByteBuffer {
        var payload = allocator.buffer(capacity: 128)
        payload.writeInteger(SFTPMessageType.name.rawValue)
        payload.writeInteger(requestId)
        payload.writeInteger(UInt32(entries.count))
        for (name, longname, attrs) in entries {
            payload.writeSSHString(name)
            payload.writeSSHString(longname)
            payload.writeSFTPFileAttributes(attrs)
        }
        return wrap(&payload, allocator: allocator)
    }
}

// MARK: - SFTPEngineTests

@MainActor
final class SFTPEngineTests: XCTestCase {
    private var group: MultiThreadedEventLoopGroup!
    private var clientChannel: InMemorySFTPChannel?
    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SFTPEngineTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let clientChannel {
            try? await clientChannel.close().get()
        }
        clientChannel = nil
        try? await group.shutdownGracefully()
        group = nil
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        try await super.tearDown()
    }

    private func makeLoopbackClient(fs: MockSFTPFilesystem) async throws -> SFTPClient {
        let channel = InMemorySFTPChannel(eventLoop: group.next(), fs: fs)
        try await channel.installHandler()
        self.clientChannel = channel

        let client = SFTPClient(channel: channel)
        channel.delegate = client
        try await client.initialize()
        return client
    }

    // MARK: - SFTPFileAttributes & SFTPMessages Unit Tests

    func testSFTPFileAttributes_SerializationAndPermissions() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let original = SFTPFileAttributes(
            size: 4096,
            uid: 501,
            gid: 20,
            permissions: 0o040755,
            accessTime: now,
            modificationTime: now,
            extended: [("ext@test", "value")]
        )

        var buffer = ByteBufferAllocator().buffer(capacity: 128)
        buffer.writeSFTPFileAttributes(original)

        let decoded = buffer.readSFTPFileAttributes()
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.size, 4096)
        XCTAssertEqual(decoded?.uid, 501)
        XCTAssertEqual(decoded?.gid, 20)
        XCTAssertEqual(decoded?.permissions, 0o040755)
        XCTAssertTrue(decoded?.isDirectory == true)
        XCTAssertFalse(decoded?.isRegularFile == true)
        XCTAssertEqual(decoded?.formatPermissions(), "drwxr-xr-x")
        XCTAssertEqual(decoded?.extended.first?.type, "ext@test")
        XCTAssertEqual(decoded?.extended.first?.data, "value")

        let symlink = SFTPFileAttributes(permissions: 0o120777)
        XCTAssertTrue(symlink.isSymlink)
        XCTAssertEqual(symlink.formatPermissions(), "lrwxrwxrwx")

        let noPerms = SFTPFileAttributes()
        XCTAssertEqual(noPerms.formatPermissions(), "----------")
    }

    func testSFTPResponseParse_PartialAndMalformedPackets() throws {
        // Partial packet leaves readerIndex unchanged and returns nil
        var partial = ByteBufferAllocator().buffer(capacity: 16)
        partial.writeInteger(UInt32(20))
        partial.writeInteger(SFTPMessageType.version.rawValue)
        XCTAssertNil(try SFTPResponse.parse(from: &partial))
        XCTAssertEqual(partial.readerIndex, 0)

        // Malformed unknown message type throws invalidPacket
        var invalid = ByteBufferAllocator().buffer(capacity: 16)
        invalid.writeInteger(UInt32(5))
        invalid.writeInteger(UInt8(250))
        invalid.writeInteger(UInt32(0))
        XCTAssertThrowsError(try SFTPResponse.parse(from: &invalid))
    }

    func testSFTPRequestBuilder_PacketFraming() {
        var initPkt = SFTPRequestBuilder.buildInit(version: 3)
        XCTAssertEqual(initPkt.readInteger(as: UInt32.self), 5)
        XCTAssertEqual(initPkt.readInteger(as: UInt8.self), SFTPMessageType.initialize.rawValue)
        XCTAssertEqual(initPkt.readInteger(as: UInt32.self), 3)

        var renamePkt = SFTPRequestBuilder.buildRename(requestId: 42, oldPath: "/a", newPath: "/b")
        let len = renamePkt.readInteger(as: UInt32.self)
        XCTAssertEqual(Int(len ?? 0), renamePkt.readableBytes)
        XCTAssertEqual(renamePkt.readInteger(as: UInt8.self), SFTPMessageType.rename.rawValue)
        XCTAssertEqual(renamePkt.readInteger(as: UInt32.self), 42)
        XCTAssertEqual(renamePkt.readSSHString(), "/a")
        XCTAssertEqual(renamePkt.readSSHString(), "/b")
    }

    // MARK: - SFTPClient Loopback Integration Tests

    func testSFTPClient_CoreOperationsAndRecursiveDelete() async throws {
        let fs = MockSFTPFilesystem()
        fs.seedFile(path: "/home/user/readme.txt", data: Data("hello".utf8))
        fs.seedFile(path: "/home/user/sub/nested.txt", data: Data("nested".utf8))
        fs.permissionDeniedPaths.insert("/root/secret")

        let client = try await makeLoopbackClient(fs: fs)

        let real = try await client.realPath(at: ".")
        XCTAssertEqual(real, "/home/user")

        let entries = try await client.listDirectory(at: "/home/user")
        XCTAssertEqual(Set(entries.map(\.filename)), Set(["readme.txt", "sub"]))

        let fileAttrs = try await client.stat(at: "/home/user/readme.txt")
        XCTAssertTrue(fileAttrs.isRegularFile)
        XCTAssertEqual(fileAttrs.size, 5)

        try await client.rename(from: "/home/user/readme.txt", to: "/home/user/renamed.txt")
        XCTAssertEqual(fs.fileData(at: "/home/user/renamed.txt"), Data("hello".utf8))

        // Permission denied error mapping
        do {
            _ = try await client.stat(at: "/root/secret")
            XCTFail("Expected SFTPClientError.failure(.permissionDenied)")
        } catch let error as SFTPClientError {
            if case .failure(let code, _) = error {
                XCTAssertEqual(code, .permissionDenied)
            } else {
                XCTFail("Unexpected SFTPClientError: \(error)")
            }
        }

        // Recursive delete removes nested file and folder
        try await client.removeDirectoryRecursive(at: "/home/user/sub")
        XCTAssertNil(fs.fileData(at: "/home/user/sub/nested.txt"))
        XCTAssertFalse(fs.directoryExists(at: "/home/user/sub"))

        await client.close()
    }

    // MARK: - SFTPTransferEngine Loopback Tests (Empty, Small Fast-Path, Sliding Window, Directory)

    func testSFTPTransferEngine_UploadAndDownloadAllPaths() async throws {
        let fs = MockSFTPFilesystem()
        let client = try await makeLoopbackClient(fs: fs)

        // 1. Empty file
        let emptyLocal = tempDir.appendingPathComponent("empty.bin")
        try Data().write(to: emptyLocal)
        try await SFTPTransferEngine.upload(client: client, localURL: emptyLocal, remotePath: "/home/user/empty.bin", chunkSize: 1024, windowSize: 4, progress: nil)
        XCTAssertEqual(fs.fileData(at: "/home/user/empty.bin"), Data())

        let emptyOut = tempDir.appendingPathComponent("empty_out.bin")
        try await SFTPTransferEngine.download(client: client, remotePath: "/home/user/empty.bin", localURL: emptyOut, chunkSize: 1024, windowSize: 4, progress: nil)
        XCTAssertEqual(try Data(contentsOf: emptyOut), Data())

        // 2. Small file fast-path (<= chunkSize)
        let smallData = Data("Small SFTP payload".utf8)
        let smallLocal = tempDir.appendingPathComponent("small.txt")
        try smallData.write(to: smallLocal)
        try await SFTPTransferEngine.upload(client: client, localURL: smallLocal, remotePath: "/home/user/small.txt", chunkSize: 1024, windowSize: 4, progress: nil)
        XCTAssertEqual(fs.fileData(at: "/home/user/small.txt"), smallData)

        let smallOut = tempDir.appendingPathComponent("small_out.txt")
        try await SFTPTransferEngine.download(client: client, remotePath: "/home/user/small.txt", localURL: smallOut, chunkSize: 1024, windowSize: 4, progress: nil)
        XCTAssertEqual(try Data(contentsOf: smallOut), smallData)

        // 3. Large multi-chunk sliding window (> chunkSize * windowSize)
        var largeData = Data(capacity: 25_000)
        for i in 0..<25_000 {
            largeData.append(UInt8(i % 251))
        }
        let largeLocal = tempDir.appendingPathComponent("large.bin")
        try largeData.write(to: largeLocal)

        var uploadLastProgress: Int64 = 0
        try await SFTPTransferEngine.upload(
            client: client,
            localURL: largeLocal,
            remotePath: "/home/user/large.bin",
            chunkSize: 1024,
            windowSize: 4
        ) { bytes in
            uploadLastProgress = bytes
        }
        XCTAssertEqual(uploadLastProgress, Int64(largeData.count))
        XCTAssertEqual(fs.fileData(at: "/home/user/large.bin"), largeData)

        let largeOut = tempDir.appendingPathComponent("large_out.bin")
        var downloadLastProgress: Int64 = 0
        try await SFTPTransferEngine.download(
            client: client,
            remotePath: "/home/user/large.bin",
            localURL: largeOut,
            chunkSize: 1024,
            windowSize: 4
        ) { bytes in
            downloadLastProgress = bytes
        }
        XCTAssertEqual(downloadLastProgress, Int64(largeData.count))
        XCTAssertEqual(try Data(contentsOf: largeOut), largeData)

        // 4. Recursive directory upload & download
        let localDir = tempDir.appendingPathComponent("tree", isDirectory: true)
        let nestedDir = localDir.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDir, withIntermediateDirectories: true)
        try Data("root-file".utf8).write(to: localDir.appendingPathComponent("a.txt"))
        try Data("sub-file".utf8).write(to: nestedDir.appendingPathComponent("b.txt"))

        try await SFTPTransferEngine.upload(
            client: client,
            localURL: localDir,
            remotePath: "/home/user/tree",
            chunkSize: 1024,
            windowSize: 2,
            progress: nil
        )
        XCTAssertEqual(fs.fileData(at: "/home/user/tree/a.txt"), Data("root-file".utf8))
        XCTAssertEqual(fs.fileData(at: "/home/user/tree/sub/b.txt"), Data("sub-file".utf8))

        let downloadedDir = tempDir.appendingPathComponent("tree_out", isDirectory: true)
        try await SFTPTransferEngine.download(
            client: client,
            remotePath: "/home/user/tree",
            localURL: downloadedDir,
            chunkSize: 1024,
            windowSize: 2,
            progress: nil
        )
        XCTAssertEqual(try Data(contentsOf: downloadedDir.appendingPathComponent("a.txt")), Data("root-file".utf8))
        XCTAssertEqual(try Data(contentsOf: downloadedDir.appendingPathComponent("sub/b.txt")), Data("sub-file".utf8))

        await client.close()
    }

    // MARK: - SFTPSession Integration & Error Mapping Tests

    func testSFTPSession_CRUDStreamingUTF8AndErrorMapping() async throws {
        let fs = MockSFTPFilesystem()
        let client = try await makeLoopbackClient(fs: fs)
        let session = SFTPSession(client: client, currentPath: "/home/user")

        try await session.createDirectory(at: "/home/user/work")
        try await session.createFile(at: "/home/user/work/notes.txt")
        try await session.writeFileContent("Hello SFTPSession!", to: "/home/user/work/notes.txt")

        let text = try await session.readFileContent(at: "/home/user/work/notes.txt")
        XCTAssertEqual(text, "Hello SFTPSession!")

        // Non-UTF-8 file must throw AppError.invalidFileEncoding
        fs.seedFile(path: "/home/user/work/binary.bin", data: Data([0xFF, 0xFE, 0x80]))
        do {
            _ = try await session.readFileContent(at: "/home/user/work/binary.bin")
            XCTFail("Expected AppError.invalidFileEncoding")
        } catch let error as AppError {
            XCTAssertEqual(error, .invalidFileEncoding)
        }

        let listed = try await session.listFiles(at: "/home/user/work")
        XCTAssertEqual(Set(listed.map(\.name)), Set(["notes.txt", "binary.bin"]))

        // Stream write + stream read via SFTPStreamReader
        let streamPayload = Data(repeating: 0x5A, count: 100_000)
        let memReader = MemoryStreamReader(data: streamPayload, chunkSize: 16_384)
        var lastWritten: Int64 = 0
        try await session.writeStream(from: memReader, to: "/home/user/work/streamed.bin", totalSize: Int64(streamPayload.count)) { bytes in
            lastWritten = bytes
        }
        XCTAssertEqual(lastWritten, Int64(streamPayload.count))

        let sftpReader = try await session.openStreamReader(at: "/home/user/work/streamed.bin")
        var readBack = Data()
        while let chunk = try await sftpReader.readNextChunk() {
            readBack.append(chunk)
        }
        await sftpReader.close()
        XCTAssertEqual(readBack, streamPayload)

        // Error mapping verification
        let mappedNotFound = await session.parseError(SFTPClientError.failure(code: .noSuchFile, message: "missing"))
        let mappedDenied = await session.parseError(SFTPClientError.failure(code: .permissionDenied, message: "denied"))
        let mappedLost = await session.parseError(SFTPClientError.connectionClosed)
        let mappedTimeout = await session.parseError(ChannelError.connectTimeout(.seconds(5)))
        let mappedUnreachable = await session.parseError(ChannelError.writeHostUnreachable)

        XCTAssertEqual(mappedNotFound, .fileNotFound)
        XCTAssertEqual(mappedDenied, .permissionDenied)
        XCTAssertEqual(mappedLost, .connectionLost)
        XCTAssertEqual(mappedTimeout, .connectionTimeout)
        XCTAssertEqual(mappedUnreachable, .hostUnreachable)

        await session.disconnect()
        let connected = await session.isConnected
        XCTAssertFalse(connected)
    }
}
