//
//  FileTypeServiceTests.swift
//  macSCPTests
//
//  Unit tests for FileTypeService type descriptions, previewability, MIME types,
//  permission formatting, and grouping/filtering helpers.
//

import XCTest
@testable import macSCP

@MainActor
final class FileTypeServiceTests: XCTestCase {

    func testTypeDescription_SpecialTypes() {
        let bucket = RemoteFile(name: "assets", path: "/assets/", isDirectory: true, size: 0, permissions: "bucket")
        let folder = RemoteFile(name: "docs", path: "/docs/", isDirectory: true, size: 0, permissions: "drwxr-xr-x")
        let symlink = RemoteFile(name: "current", path: "/current", isDirectory: false, size: 0, permissions: "lrwxrwxrwx")

        XCTAssertEqual(FileTypeService.typeDescription(for: bucket), "Bucket")
        XCTAssertEqual(FileTypeService.typeDescription(for: folder), "Folder")
        XCTAssertEqual(FileTypeService.typeDescription(for: symlink), "Alias")
    }

    func testTypeDescription_KnownExtensions() {
        let cases: [(String, String)] = [
            ("App.swift", "Swift Source"),
            ("index.TS", "TypeScript"),
            ("script.py", "Python Script"),
            ("main.cc", "C++ Source"),
            ("page.htm", "HTML Document"),
            ("config.yml", "YAML Document"),
            ("README.markdown", "Markdown Document"),
            ("photo.JPEG", "JPEG Image"),
            ("archive.gzip", "Gzip Archive"),
            ("macSCP.xcodeproj", "Xcode Project"),
            ("macSCP.xcworkspace", "Xcode Workspace")
        ]

        for (name, expected) in cases {
            let file = RemoteFile(name: name, path: "/\(name)", isDirectory: false, size: 128, permissions: "-rw-r--r--")
            XCTAssertEqual(FileTypeService.typeDescription(for: file), expected, "Unexpected description for \(name)")
        }
    }

    func testTypeDescription_FallbackFileTypes() {
        let unknown = RemoteFile(name: "blob.unknownext", path: "/blob.unknownext", isDirectory: false, size: 10, permissions: "-rw-r--r--")
        let noExt = RemoteFile(name: "Makefile", path: "/Makefile", isDirectory: false, size: 10, permissions: "-rw-r--r--")
        let logFile = RemoteFile(name: "app.log", path: "/app.log", isDirectory: false, size: 10, permissions: "-rw-r--r--")

        XCTAssertEqual(FileTypeService.typeDescription(for: unknown), "Document")
        XCTAssertEqual(FileTypeService.typeDescription(for: noExt), "Document")
        XCTAssertEqual(FileTypeService.typeDescription(for: logFile), "Plain Text")
    }

    func testIsPreviewable_RespectsDirectorySizeAndEditability() {
        let smallSwift = RemoteFile(name: "Main.swift", path: "/Main.swift", isDirectory: false, size: 1024, permissions: "-rw-r--r--")
        let hugeSwift = RemoteFile(
            name: "Huge.swift",
            path: "/Huge.swift",
            isDirectory: false,
            size: FileOperationConstants.maxFilePreviewSize + 1,
            permissions: "-rw-r--r--"
        )
        let image = RemoteFile(name: "logo.png", path: "/logo.png", isDirectory: false, size: 512, permissions: "-rw-r--r--")
        let dir = RemoteFile(name: "src", path: "/src", isDirectory: true, size: 0, permissions: "drwxr-xr-x")

        XCTAssertTrue(FileTypeService.isPreviewable(smallSwift))
        XCTAssertFalse(FileTypeService.isPreviewable(hugeSwift))
        XCTAssertFalse(FileTypeService.isPreviewable(image))
        XCTAssertFalse(FileTypeService.isPreviewable(dir))
    }

    func testMimeType_KnownAndUnknownExtensions() {
        let jsonFile = RemoteFile(name: "data.json", path: "/data.json", isDirectory: false, size: 10, permissions: "-rw-r--r--")
        let unknownFile = RemoteFile(name: "mystery.xyz999", path: "/mystery.xyz999", isDirectory: false, size: 10, permissions: "-rw-r--r--")

        XCTAssertEqual(FileTypeService.mimeType(for: jsonFile), "application/json")
        XCTAssertEqual(FileTypeService.mimeType(for: unknownFile), "application/octet-stream")
    }

    func testFormatPermissions_ValidAndInvalidStrings() {
        XCTAssertEqual(
            FileTypeService.formatPermissions("drwxr-x---"),
            "Directory - Owner: Read, Write, Execute, Group: Read, Execute, Others: None"
        )
        XCTAssertEqual(
            FileTypeService.formatPermissions("-rw-r--r--"),
            "File - Owner: Read, Write, Group: Read, Others: Read"
        )
        XCTAssertEqual(
            FileTypeService.formatPermissions("lrwxrwxrwx"),
            "Symbolic Link - Owner: Read, Write, Execute, Group: Read, Write, Execute, Others: Read, Write, Execute"
        )
        XCTAssertEqual(FileTypeService.formatPermissions("invalid"), "invalid")
    }

    func testGroupByTypeAndFilter() {
        let files = [
            RemoteFile(name: "a.swift", path: "/a.swift", isDirectory: false, size: 1, permissions: "-rw-r--r--"),
            RemoteFile(name: "b.py", path: "/b.py", isDirectory: false, size: 1, permissions: "-rw-r--r--"),
            RemoteFile(name: "c.txt", path: "/c.txt", isDirectory: false, size: 1, permissions: "-rw-r--r--"),
            RemoteFile(name: "dir", path: "/dir", isDirectory: true, size: 0, permissions: "drwxr-xr-x")
        ]

        let grouped = FileTypeService.groupByType(files)
        XCTAssertEqual(grouped[.code]?.count, 2)
        XCTAssertEqual(grouped[.text]?.count, 1)
        XCTAssertEqual(grouped[.directory]?.count, 1)

        let codeOnly = FileTypeService.filter(files, byType: .code)
        XCTAssertEqual(codeOnly.map(\.name), ["a.swift", "b.py"])
    }
}
