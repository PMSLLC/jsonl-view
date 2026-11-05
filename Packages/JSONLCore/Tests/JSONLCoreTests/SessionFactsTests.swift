import Foundation
import Testing
@testable import JSONLCore

private func rec(_ type: String, _ extra: [String: JSONValue] = [:]) -> JSONValue {
    .object(["type": .string(type)].merging(extra) { $1 })
}
private func prompt(_ text: String) -> JSONValue {
    rec("user", ["message": .object(["content": .string(text)])])
}
private func facts(_ recs: [JSONValue], file: String = "/tmp/my-session.jsonl") -> SessionFacts {
    let m = SessionModel(); m.append(recs)
    return SessionFacts.make(model: m, records: recs, fileURL: URL(fileURLWithPath: file))
}

@Test func titleFromAITitle() {
    let f = facts([prompt("hello"), rec("ai-title", ["aiTitle": .string("Old")]),
                   rec("ai-title", ["aiTitle": .string("Shirt todo app")])])
    #expect(f.title == "Shirt todo app")
}

@Test func titleFromFirstPrompt() throws {
    let f = SessionFacts.make(model: { let m = SessionModel(); m.append(try! fixtureRecords("session-facts")); return m }(),
                              records: try fixtureRecords("session-facts"),
                              fileURL: URL(fileURLWithPath: "/tmp/x.jsonl"))
    #expect(f.title == "I want a quick app that will add shirt ideas to a todo list")
}

@Test func titleFromFilename() {
    #expect(facts([rec("summary")]).title == "my-session")
}

@Test func countsMatchFixture() throws {
    let recs = try fixtureRecords("session-facts")
    let m = SessionModel(); m.append(recs)
    let f = SessionFacts.make(model: m, records: recs, fileURL: URL(fileURLWithPath: "/tmp/x.jsonl"))
    #expect(f.promptCount == 1)
    #expect(f.toolCallCount == 4)
    #expect(f.subagentCount == 1)
    #expect(f.filesEdited == 2)
    #expect(f.model == "Opus")
    #expect(f.cwd == "/work/shirts")
    #expect(f.branch == "main")
    #expect(f.start != nil && f.end != nil && f.start! < f.end!)
    #expect(f.lastReply == "All done, the app is ready.")
}

@Test func modelShortening() {
    #expect(SessionFacts.shortModel("claude-sonnet-5-5") == "Sonnet")
    #expect(SessionFacts.shortModel("claude-haiku-4") == "Haiku")
    #expect(SessionFacts.shortModel("claude-fable-1") == "Fable")
    #expect(SessionFacts.shortModel("gpt-x") == "gpt-x")
}

@Test func digestCappedAt6000() {
    var recs: [JSONValue] = []
    for i in 0..<40 { recs.append(prompt(String(repeating: "p\(i) ", count: 300))) }
    for i in 0..<400 {   // enough edited file names to push the digest past the cap
        recs.append(rec("assistant", ["message": .object(["content": .array([.object([
            "type": .string("tool_use"), "id": .string("e\(i)"), "name": .string("Write"),
            "input": .object(["file_path": .string("/a/some-long-file-name-\(i).swift")])])])])]))
    }
    let f = facts(recs)
    let m = SessionModel(); m.append(recs)
    let d = SummaryDigest.text(facts: f, model: m)
    #expect(d.count <= 6000)
    #expect(d.hasPrefix("Title:"))
    #expect(d.contains("Edited files: some-long-file-name-0.swift"))
}

private func reply(_ text: String) -> JSONValue {
    rec("assistant", ["message": .object(["content": .array([.object(["type": .string("text"), "text": .string(text)])])])])
}
private func write(_ path: String, id: String) -> JSONValue {
    rec("assistant", ["message": .object(["content": .array([.object([
        "type": .string("tool_use"), "id": .string(id), "name": .string("Edit"),
        "input": .object(["file_path": .string(path)])])])])])
}

@Test func digestKeepsLastRepliesAndFilesWithLongPrompts() {
    // A long working directory pushes the old fixed-order digest past the cap.
    var recs: [JSONValue] = [rec("system", ["cwd": .string("/w/" + String(repeating: "deep/", count: 120))])]
    for i in 0..<12 { recs.append(prompt("prompt \(i) " + String(repeating: "long words here ", count: 200))) }
    recs.append(write("/w/Alpha.swift", id: "w1"))
    recs.append(write("/w/Beta.swift", id: "w2"))
    recs.append(reply("SECOND-TO-LAST " + String(repeating: "r", count: 2_000)))
    recs.append(reply("FINAL-REPLY-MARK all done"))
    let f = facts(recs)
    let m = SessionModel(); m.append(recs)
    let d = SummaryDigest.text(facts: f, model: m)
    #expect(d.count <= SummaryDigest.limit)
    #expect(d.contains("FINAL-REPLY-MARK all done"))
    #expect(d.contains("SECOND-TO-LAST"))
    #expect(d.contains("Edited files: Alpha.swift, Beta.swift"))
    #expect(d.contains("- prompt 0 "))
}

@Test func digestCapsHugeFileList() {
    var recs: [JSONValue] = [prompt("go")]
    for i in 0..<2_000 { recs.append(write("/a/file-with-a-long-name-\(i).swift", id: "e\(i)")) }
    recs.append(reply("FINAL-REPLY-MARK"))
    let f = facts(recs)
    let m = SessionModel(); m.append(recs)
    let d = SummaryDigest.text(facts: f, model: m)
    #expect(d.count <= SummaryDigest.limit)
    #expect(d.contains("FINAL-REPLY-MARK"))
    #expect(d.contains("- go"))
    #expect(d.contains("more"))
}

private func writeSyntheticSession(bytes target: Int, lastReply: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("capped-\(UUID().uuidString).jsonl")
    let pad = String(repeating: "lorem ipsum ", count: 150)
    var data = Data()
    data.reserveCapacity(target + 4_096)
    var i = 0
    while data.count < target {
        let line = i % 2 == 0
            ? #"{"type":"user","sessionId":"s1","message":{"role":"user","content":"prompt \#(i) \#(pad)"}}"#
            : #"{"type":"assistant","sessionId":"s1","message":{"model":"claude-opus-5","content":[{"type":"text","text":"reply \#(i) \#(pad)"}]}}"#
        data.append(Data((line + "\n").utf8))
        i += 1
    }
    data.append(Data((#"{"type":"assistant","sessionId":"s1","message":{"model":"claude-opus-5","content":[{"type":"text","text":"\#(lastReply)"}]}}"# + "\n").utf8))
    try data.write(to: url)
    return url
}

@Test func testPreviewFactsCapped() async throws {
    let url = try writeSyntheticSession(bytes: 80 * 1_048_576, lastReply: "the very last reply")
    defer { try? FileManager.default.removeItem(at: url) }
    let began = Date()
    let snap = try await PreviewLoader.load(url)
    let elapsed = Date().timeIntervalSince(began)
    guard case .session(let f) = snap.content else { Issue.record("expected a session"); return }
    #expect(f.approximate)
    #expect(snap.approximate)
    #expect(f.firstPrompt?.hasPrefix("prompt 0 ") == true)
    #expect(f.lastReply == "the very last reply")
    #expect(f.fileBytes > 80 * 1_048_576)
    #expect(elapsed < 1.5, "took \(elapsed) s")
}

@Test func previewSmallFileIsExact() async throws {
    let url = try writeSyntheticSession(bytes: 200_000, lastReply: "done")
    defer { try? FileManager.default.removeItem(at: url) }
    let snap = try await PreviewLoader.load(url)
    guard case .session(let f) = snap.content else { Issue.record("expected a session"); return }
    #expect(!f.approximate)
    #expect(f.lastReply == "done")
    #expect(!snap.digest.isEmpty)
}

@Test func previewTailSkipsPartialLine() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("generic-\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: url) }
    var text = ""
    for i in 0..<1_000 { text += #"{"id":\#(i),"name":"row number \#(i)"}"# + "\n" }
    try Data(text.utf8).write(to: url)
    // 3,000 bytes from each end of a ~33 KB file: the tail starts mid-line and must skip it.
    let snap = try await PreviewLoader.load(url, fullReadLimit: 10_000, edgeBytes: 3_000)
    guard case .generic(let g) = snap.content else { Issue.record("expected generic"); return }
    #expect(snap.approximate)
    #expect(g.invalidCount == 0)
    // 34,780-byte file: the head holds rows 0-90 (91 lines within 3,000 bytes); the tail starts at
    // byte 31,780, mid-row, and skips to the next line, leaving rows 915-999 (85 lines).
    #expect(g.recordCount == 176)
    #expect(g.samples.first?["id"] == .number(0))
}

@Test func previewLoadStopsWhenCancelled() async throws {
    let url = try writeSyntheticSession(bytes: 2_000_000, lastReply: "done")
    defer { try? FileManager.default.removeItem(at: url) }
    let task = Task { () async throws -> PreviewSnapshot in
        withUnsafeCurrentTask { $0?.cancel() }
        return try await PreviewLoader.load(url)
    }
    await #expect(throws: CancellationError.self) { try await task.value }
}

@Test func decodeConcurrentlyStopsWhenCancelled() async throws {
    let lines = (0..<5_000).map { Data(#"{"n":\#($0)}"#.utf8) }
    let task = Task { () async throws -> [JSONValue] in
        withUnsafeCurrentTask { $0?.cancel() }
        return try await PreviewLoader.decodeConcurrently(lines)
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(try await PreviewLoader.decodeConcurrently(lines).count == 5_000)
}
