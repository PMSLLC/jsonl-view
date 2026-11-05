import Foundation
import Testing
@testable import JSONLCore

private func model(_ name: String) throws -> SessionModel {
    let m = SessionModel(); m.append(try fixtureRecords(name)); return m
}

@Test func buildsConversation() throws {
    let m = try model("session-basic")
    #expect(m.items.map(\.kindName) == ["userPrompt", "thinking", "toolCall", "assistantText"])
    #expect(m.toolCalls[0].inputSummary == "ls docs | head")
    #expect(m.toolCalls[0].result == "a.md\nb.md")
    #expect(m.items[0].timestamp != nil)
}

@Test func dropsNoise() throws {
    let m = try model("session-noise")
    #expect(m.outline.count == 1)
    #expect(m.items.count == 1)
}

@Test func stripsReminderTagsFromPrompt() throws {
    let m = try model("session-basic")
    guard case .userPrompt(let p) = m.items[0].kind else { Issue.record("not a prompt"); return }
    #expect(p == "fix the bug")
}

@Test func appendIsIncremental() throws {
    let recs = try fixtureRecords("session-basic")
    let a = SessionModel(); a.append(Array(recs[0..<3])); a.append(Array(recs[3...]))
    let b = SessionModel(); b.append(recs)
    #expect(a.items.map(\.kindName) == b.items.map(\.kindName))
    #expect(a.toolCalls == b.toolCalls)
}

@Test func testToolResultBlockContent() {
    let recs: [JSONValue] = [
        .object(["type": .string("assistant"), "message": .object(["content": .array([
            .object(["type": .string("tool_use"), "id": .string("t9"), "name": .string("Read"),
                     "input": .object(["file_path": .string("/x")])])])])]),
        .object(["type": .string("user"), "message": .object(["content": .array([
            .object(["type": .string("tool_result"), "tool_use_id": .string("t9"), "is_error": .bool(true),
                     "content": .array([
                        .object(["type": .string("text"), "text": .string("line one")]),
                        .object(["type": .string("image")])])])])])]),
    ]
    let m = SessionModel(); m.append(recs)
    let call = m.toolCalls[0]
    #expect(call.result == "line one\n[image]")
    #expect(call.resultIsError)
    #expect(call.inputSummary == "/x")
}

@Test func summaryRules() {
    let long = String(repeating: "a", count: 300)
    #expect(SessionModel.summarize("Bash", .object(["command": .string(long)])).count == 120)
    #expect(SessionModel.summarize("Bash", .object(["command": .string("a\nb")])) == "a")
    #expect(SessionModel.summarize("Grep", .object(["pattern": .string("foo")])) == "foo")
    #expect(SessionModel.summarize("Task", .object(["description": .string("d")])) == "d")
    #expect(SessionModel.summarize("Other", .object(["n": .number(1), "z": .string("zed")])) == "zed")
}

@Test func testToolResultPreviewTruncates() {
    let r = SessionModel.resultPreview(String(repeating: "x", count: 5_000_000))
    #expect(r.text.count == 20_000 && r.truncated)
    #expect(!SessionModel.resultPreview("short").truncated)
}

@Test func testParses50MBWithin3s() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("big-\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: url) }
    let pad = String(repeating: "lorem ipsum ", count: 140)
    var s = ""
    for i in 0..<30_000 {
        if i % 3 == 0 {
            s += "{\"type\":\"user\",\"sessionId\":\"s\",\"message\":{\"content\":\"prompt \(i) \(pad)\"}}\n"
        } else if i % 3 == 1 {
            s += "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"id\":\"t\(i)\",\"name\":\"Bash\",\"input\":{\"command\":\"echo \(pad)\"}}]}}\n"
        } else {
            s += "{\"type\":\"user\",\"message\":{\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"t\(i - 1)\",\"content\":\"\(pad)\"}]}}\n"
        }
    }
    try Data(s.utf8).write(to: url)
    let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int
    #expect(size > 45_000_000)
    let start = Date()
    let m = SessionModel()
    let chunk = try LineReader.read(fileAt: url, from: 0)
    m.append(chunk.lines.compactMap(decodeRecord))
    #expect(Date().timeIntervalSince(start) < 3)
    #expect(m.items.count == 20_000)
    #expect(m.toolCalls.filter { $0.result != nil }.count == 10_000)
}

@Test func taskNotificationIsNotAPrompt() throws {
    let recs = try fixtureRecords("session-notification")
    let m = SessionModel(); m.append(recs)
    #expect(m.items.map(\.kindName) == ["userPrompt", "toolCall", "notification", "notification", "assistantText"])
    #expect(m.outline.count == 1)
    guard case .notification(let summary, let body) = m.items[2].kind,
          case .notification(let bare, _) = m.items[3].kind else {
        Issue.record("not notifications"); return
    }
    #expect(summary == "Agent \"Review Task 5\" finished")
    #expect(body.contains("<result>All good</result>"))
    #expect(body.hasPrefix("<task-notification>"))
    #expect(bare == "def failed")
    let facts = SessionFacts.make(model: m, records: recs, fileURL: URL(fileURLWithPath: "/tmp/none.jsonl"))
    #expect(facts.promptCount == 1)
    #expect(facts.firstPrompt == "start the review")
}

@Test func notificationSearchCoversBody() throws {
    let m = SessionModel(); m.append(try fixtureRecords("session-notification"))
    #expect(m.items[2].matches("all good"))
    #expect(m.items[2].matches("review task 5"))
    #expect(!m.items[2].matches("nowhere"))
}

@Test func compactionSummaryIsFoldedNotAPrompt() throws {
    let recs = try fixtureRecords("session-compaction")
    let m = SessionModel(); m.append(recs)
    #expect(m.items.map(\.kindName) == ["userPrompt", "assistantText", "compaction", "compaction", "userPrompt"])
    #expect(m.outline.count == 2)
    guard case .compaction(let text) = m.items[2].kind, case .compaction(let blocks) = m.items[3].kind else {
        Issue.record("not compactions"); return
    }
    #expect(text.hasPrefix("This session is being continued"))
    #expect(blocks == "Block summary one\nBlock summary two")
    #expect(m.items[2].matches("synthetic widget"))
    let facts = SessionFacts.make(model: m, records: recs, fileURL: URL(fileURLWithPath: "/tmp/c.jsonl"))
    #expect(facts.promptCount == 2)
    let digest = SummaryDigest.text(facts: facts, model: m)
    #expect(!digest.contains("being continued"))
    #expect(digest.contains("- now add tests"))
}
