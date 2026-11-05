import Foundation
import Testing
@testable import JSONLCore

private func tempFile(_ contents: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("linereader-\(UUID().uuidString).jsonl")
    try Data(contents.utf8).write(to: url)
    return url
}

@Test func readsCompleteLinesOnly() throws {
    let url = try tempFile("{\"a\":1}\n{\"b\":2}\n{\"c\"")
    defer { try? FileManager.default.removeItem(at: url) }
    let c = try LineReader.read(fileAt: url, from: 0)
    #expect(c.lines.count == 2)
    #expect(c.nextOffset == 16)
}

@Test func resumesFromOffset() throws {
    let url = try tempFile("{\"a\":1}\n{\"b\":2}\n{\"c\"")
    defer { try? FileManager.default.removeItem(at: url) }
    let h = try FileHandle(forWritingTo: url)
    try h.seekToEnd()
    try h.write(contentsOf: Data(":3}\n".utf8))
    try h.close()
    let c = try LineReader.read(fileAt: url, from: 16)
    #expect(c.lines.count == 1)
    #expect(decodeRecord(c.lines[0])?["c"] == .number(3))
    #expect(c.nextOffset == 24)
}

@Test func skipsInvalidLines() {
    #expect(decodeRecord(Data("not json".utf8)) == nil)
}

@Test func emptyFile() throws {
    let url = try tempFile("")
    defer { try? FileManager.default.removeItem(at: url) }
    let c = try LineReader.read(fileAt: url, from: 0)
    #expect(c.lines.isEmpty)
    #expect(c.nextOffset == 0)
}

@Test func handlesCRLF() throws {
    let url = try tempFile("{\"a\":1}\r\n")
    defer { try? FileManager.default.removeItem(at: url) }
    let c = try LineReader.read(fileAt: url, from: 0)
    #expect(c.lines.count == 1)
    #expect(decodeRecord(c.lines[0])?["a"] == .number(1))
    #expect(c.nextOffset == 9)
}

@Test func countsInvalidLinesAndHonorsMaxBytes() throws {
    let url = try tempFile("{\"a\":1}\nnope\n{\"b\":2}\n")
    defer { try? FileManager.default.removeItem(at: url) }
    let all = try LineReader.read(fileAt: url, from: 0)
    #expect(all.lines.count == 3)
    #expect(all.lines.compactMap(decodeRecord).count == 2)
    let part = try LineReader.read(fileAt: url, from: 0, maxBytes: 10)
    #expect(part.lines.count == 1)
    #expect(part.nextOffset == 8)
}

@Test func linesSpanningBlockBoundary() throws {
    let big = String(repeating: "x", count: 1_500_000)
    let url = try tempFile("\"\(big)\"\n{\"a\":1}\n")
    defer { try? FileManager.default.removeItem(at: url) }
    let c = try LineReader.read(fileAt: url, from: 0)
    #expect(c.lines.count == 2)
    #expect(c.lines[0].count == 1_500_002)
}

@Test func firstLineLargerThanMaxBytesIsStillReturned() throws {
    let url = try tempFile("{\"a\":\"0123456789\"}\n{\"b\":2}\n")
    defer { try? FileManager.default.removeItem(at: url) }
    let c = try LineReader.read(fileAt: url, from: 0, maxBytes: 5)
    #expect(c.lines.count == 1)
    #expect(c.nextOffset == 19)
}

@Test func singleHugeLineStaysLinear() throws {
    let big = String(repeating: "x", count: 25_000_000)
    let url = try tempFile("\"\(big)\"\n")
    defer { try? FileManager.default.removeItem(at: url) }
    let clock = ContinuousClock()
    var chunk: LineChunk?
    let elapsed = try clock.measure { chunk = try LineReader.read(fileAt: url, from: 0) }
    #expect(chunk?.lines.count == 1)
    #expect(chunk?.lines[0].count == 25_000_002)
    #expect(elapsed < .seconds(1))
}
