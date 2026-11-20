import Foundation
import XCTest
@testable import ChronoStream

final class CompatibilityTests: XCTestCase {
    private func writeTempFile(name: String, bytes: [UInt8]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ChronoStreamTests", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    func testStandardMp4Detection() throws {
        let url = try writeTempFile(name: "sample.mp4", bytes: [0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6F, 0x6D])
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(MediaFormatRegistry.inspectCompatibility(for: url), .nativeAVFoundation)
    }

    func testHikvisionMpegPsDetection() throws {
        let url = try writeTempFile(name: "hiv00202.mp4", bytes: [0x00, 0x00, 0x01, 0xBA, 0x55, 0x66, 0x24, 0xAF])
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(MediaFormatRegistry.inspectCompatibility(for: url), .ffmpegRemux)
    }

    func testCorruptedFilesHandledSafely() throws {
        let badVideo = try writeTempFile(name: "corrupt.mp4", bytes: [0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01, 0x02, 0x03])
        let badPdf = try writeTempFile(name: "corrupt.pdf", bytes: [0x00, 0x11, 0x22, 0x33])
        defer {
            try? FileManager.default.removeItem(at: badVideo)
            try? FileManager.default.removeItem(at: badPdf)
        }
        XCTAssertEqual(MediaFormatRegistry.inspectCompatibility(for: badVideo), .unsupported)
        XCTAssertEqual(MediaFormatRegistry.inspectCompatibility(for: badPdf), .unsupported)
    }

    func testValidPdfAndPng() throws {
        let pdf = try writeTempFile(name: "doc.pdf", bytes: [0x25, 0x50, 0x44, 0x46, 0x2D, 0x31, 0x2E, 0x37])
        let png = try writeTempFile(name: "photo.png", bytes: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        defer {
            try? FileManager.default.removeItem(at: pdf)
            try? FileManager.default.removeItem(at: png)
        }
        XCTAssertEqual(MediaFormatRegistry.inspectCompatibility(for: pdf), .nativePDFKit)
        XCTAssertEqual(MediaFormatRegistry.inspectCompatibility(for: png), .nativeImageIO)
    }

    func testSubtitleParsing() throws {
        let srt = """
        1
        00:00:01,500 --> 00:00:04,250
        Hello ChronoStream

        2
        01:02:03,000 --> 01:02:06,000
        Second cue line
        """
        let url = try writeTempFile(name: "test.srt", bytes: Array(srt.utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        let cues = SubtitleParser.parse(url: url)
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].startTime, 1.5)
        XCTAssertEqual(cues[0].text, "Hello ChronoStream")
        XCTAssertEqual(cues[1].startTime, 3723.0)
    }

    func testDuplicatePartialHash() throws {
        let a = try writeTempFile(name: "dupA.bin", bytes: Array(repeating: 0x42, count: 1024))
        let b = try writeTempFile(name: "dupB.bin", bytes: Array(repeating: 0x42, count: 1024))
        let c = try writeTempFile(name: "diff.bin", bytes: Array(repeating: 0x99, count: 1024))
        defer {
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
            try? FileManager.default.removeItem(at: c)
        }
        let ha = SecurityBookmarkStore.fastPartialHash(for: a, fileSize: 1024)
        let hb = SecurityBookmarkStore.fastPartialHash(for: b, fileSize: 1024)
        let hc = SecurityBookmarkStore.fastPartialHash(for: c, fileSize: 1024)
        XCTAssertNotNil(ha)
        XCTAssertEqual(ha, hb)
        XCTAssertNotEqual(ha, hc)
    }
}
