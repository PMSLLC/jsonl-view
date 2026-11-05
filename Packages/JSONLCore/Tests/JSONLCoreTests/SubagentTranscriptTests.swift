import Foundation
import Testing
@testable import JSONLCore

private func fixtureURL(_ rel: String) -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(rel)")
}

private func line(_ s: String) -> Data { Data((s + "\n").utf8) }

private let promptLine = #"{"type":"user","isSidechain":true,"message":{"content":"Check the parser"}}"#
private let toolLine = #"{"type":"assistant","isSidechain":true,"message":{"content":[{"type":"tool_use","id":"s1","name":"Read","input":{"file_path":"/x"}}]}}"#
private let replyLine = #"{"type":"assistant","isSidechain":true,"message":{"content":[{"type":"text","text":"Parser looks fine."}]}}"#

@Test func transcriptClearsSidechainFlag() {
    let t = SubagentTranscript.load(fixtureURL("withsub/subagents/agent-a1.jsonl"))
    #expect(t.error == nil)
    #expect(t.items.map(\.kindName) == ["userPrompt", "toolCall", "assistantText"])
    #expect(t.toolCallCount == 1)
    #expect(t.finalText == "Parser looks fine.")
}

@Test func transcriptMissingFileHasError() {
    let t = SubagentTranscript.load(URL(fileURLWithPath: "/tmp/no-such-\(UUID().uuidString).jsonl"))
    #expect(t.error?.hasPrefix("Could not read the subagent transcript") == true)
    #expect(t.items.isEmpty)
}

@Test func transcriptGoesStaleWhenFileGrows() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("sub-\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: url) }
    try line(promptLine).write(to: url)
    let first = SubagentTranscript.load(url)
    #expect(first.toolCallCount == 0)
    #expect(!first.isStale(url))

    let h = try FileHandle(forWritingTo: url)
    try h.seekToEnd(); try h.write(contentsOf: line(toolLine) + line(replyLine)); try h.close()
    #expect(first.isStale(url))

    let second = SubagentTranscript.load(url)
    #expect(second.toolCallCount == 1)
    #expect(second.finalText == "Parser looks fine.")
    #expect(!second.isStale(url))
}

@Test func displayLinePrefersParentResult() {
    let t = SubagentTranscript.load(fixtureURL("withsub/subagents/agent-a1.jsonl"))
    #expect(SubagentTranscript.displayLine(result: "Real result", transcript: t, description: "d") == "Real result")
    #expect(SubagentTranscript.displayLine(result: nil, transcript: t, description: "d") == "Parser looks fine.")
    #expect(SubagentTranscript.displayLine(result: "", transcript: t, description: "d") == "Parser looks fine.")
    #expect(SubagentTranscript.displayLine(result: nil, transcript: nil, description: "d") == "d")
}

@Test func displayLineSkipsBackgroundLaunchNotice() {
    let t = SubagentTranscript.load(fixtureURL("withsub/subagents/agent-a1.jsonl"))
    let notice = "Async agent launched successfully. (This tool call returns at once.)"
    #expect(SubagentTranscript.displayLine(result: notice, transcript: t, description: "d") == "Parser looks fine.")
    #expect(SubagentTranscript.displayLine(result: notice, transcript: nil, description: "d") == "d")
}

@Test func displayLineIsCapped() {
    let long = String(repeating: "x", count: 1_000)
    #expect(SubagentTranscript.displayLine(result: long, transcript: nil, description: "d").count == 400)
}

@Test func metaRecordsKeepFactsInputs() throws {
    let recs = try fixtureRecords("session-facts")
    var meta = MetaRecords()
    meta.absorb(Array(recs.prefix(2)))
    meta.absorb(Array(recs.dropFirst(2)))
    let m = SessionModel(); m.append(recs)
    let url = URL(fileURLWithPath: "/tmp/x.jsonl")
    #expect(SessionFacts.make(model: m, records: meta.records, fileURL: url)
            == SessionFacts.make(model: m, records: recs, fileURL: url))
    #expect(meta.records.count <= 4)
}

@Test func metaRecordsIgnoreSidechainModel() {
    var meta = MetaRecords()
    meta.absorb([.object(["type": .string("assistant"), "isSidechain": .bool(true),
                          "message": .object(["model": .string("claude-haiku-4")])])])
    #expect(meta.records.isEmpty)
}
