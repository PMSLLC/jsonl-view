import Foundation
import Testing
@testable import JSONLCore

/// Collects chunks delivered by a tailer. Guarded by a lock because onLines
/// runs on the tailer's private queue while tests read from another context.
private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [LineChunk] = []

    func add(_ chunk: LineChunk) { lock.lock(); chunks.append(chunk); lock.unlock() }
    var all: [LineChunk] { lock.lock(); defer { lock.unlock() }; return chunks }
    var lines: [String] { all.flatMap(\.lines).map { String(decoding: $0, as: UTF8.self) } }
}

private func tempFile(_ contents: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("filetailer-\(UUID().uuidString).jsonl")
    try Data(contents.utf8).write(to: url)
    return url
}

private func append(_ text: String, to url: URL) throws {
    let h = try FileHandle(forWritingTo: url)
    defer { try? h.close() }
    try h.seekToEnd()
    try h.write(contentsOf: Data(text.utf8))
}

/// Polls until `condition` holds or the deadline passes. Returns the final result.
private func waitUntil(timeout: Duration = .seconds(2), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

@Test func deliversAppendedLines() async throws {
    let url = try tempFile("{\"a\":1}\n")
    defer { try? FileManager.default.removeItem(at: url) }
    let got = Collector()
    let tailer = FileTailer(url: url, startOffset: 8) { got.add($0) }
    tailer.start()
    defer { tailer.stop() }

    try append("{\"b\":2}\n{\"c\":3}\n", to: url)
    #expect(await waitUntil { got.lines.count >= 2 })
    #expect(got.lines == ["{\"b\":2}", "{\"c\":3}"])
    #expect(got.all.last?.nextOffset == 24)
}

@Test func holdsPartialLineUntilNewline() async throws {
    let url = try tempFile("")
    defer { try? FileManager.default.removeItem(at: url) }
    let got = Collector()
    let tailer = FileTailer(url: url, startOffset: 0) { got.add($0) }
    tailer.start()
    defer { tailer.stop() }

    try append("{\"a\":", to: url)
    try? await Task.sleep(for: .milliseconds(200))
    #expect(got.lines.isEmpty)

    try append("1}\n", to: url)
    #expect(await waitUntil { got.lines.count == 1 })
    #expect(got.lines == ["{\"a\":1}"])
}

@Test func signalsTruncation() async throws {
    let url = try tempFile("{\"a\":1}\n{\"b\":2}\n")
    defer { try? FileManager.default.removeItem(at: url) }
    let got = Collector()
    let tailer = FileTailer(url: url, startOffset: 16) { got.add($0) }
    tailer.start()
    defer { tailer.stop() }

    let h = try FileHandle(forWritingTo: url)
    try h.truncate(atOffset: 0)
    try h.close()

    #expect(await waitUntil { got.all.contains { $0.lines.isEmpty && $0.nextOffset == 0 } })

    try append("{\"n\":1}\n", to: url)
    #expect(await waitUntil { got.lines == ["{\"n\":1}"] })
    #expect(got.all.last?.nextOffset == 8)
}

@Test func reloadsAfterAtomicReplace() async throws {
    let url = try tempFile("{\"a\":1}\n")
    defer { try? FileManager.default.removeItem(at: url) }
    let got = Collector()
    let tailer = FileTailer(url: url, startOffset: 8) { got.add($0) }
    tailer.start()
    defer { tailer.stop() }

    let replacement = url.deletingLastPathComponent()
        .appendingPathComponent("filetailer-new-\(UUID().uuidString)")
    try Data("{\"z\":9}\n".utf8).write(to: replacement)
    _ = try FileManager.default.replaceItemAt(url, withItemAt: replacement)

    #expect(await waitUntil { got.lines == ["{\"z\":9}"] })
    #expect(got.all.first?.lines.isEmpty == true)
    #expect(got.all.first?.nextOffset == 0)
}

@Test func stopIsIdempotentAndHaltsDelivery() async throws {
    let url = try tempFile("")
    defer { try? FileManager.default.removeItem(at: url) }
    let got = Collector()
    let tailer = FileTailer(url: url, startOffset: 0) { got.add($0) }
    tailer.start()

    try append("{\"a\":1}\n", to: url)
    #expect(await waitUntil { got.lines.count == 1 })

    tailer.stop()
    tailer.stop()
    try append("{\"b\":2}\n", to: url)
    try? await Task.sleep(for: .milliseconds(200))
    #expect(got.lines == ["{\"a\":1}"])
}
