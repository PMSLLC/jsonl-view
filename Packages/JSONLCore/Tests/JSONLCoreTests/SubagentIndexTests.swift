import Foundation
import Testing
@testable import JSONLCore

private func fixtureURL(_ rel: String) -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/\(rel)")
}

@Test func findsSubagentByToolUseId() {
    let index = SubagentIndex.load(for: fixtureURL("withsub.jsonl"))
    let ref = index["toolu_fixture_a1"]
    #expect(ref?.agentType == "general-purpose")
    #expect(ref?.description == "Re-review parser")
    #expect(ref?.fileURL.lastPathComponent == "agent-a1.jsonl")
    #expect(index.count == 1)
}

@Test func missingSidecarIsEmpty() {
    #expect(SubagentIndex.load(for: fixtureURL("session-basic.jsonl")).isEmpty)
}

@Test func worksWithRenamedCopy() throws {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory.appendingPathComponent("subagent-index-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmp) }

    let session = tmp.appendingPathComponent("2026-10-06_x_abcd1234.jsonl")
    try fm.copyItem(at: fixtureURL("withsub.jsonl"), to: session)
    let sidecar = tmp.appendingPathComponent("2026-10-06_x_abcd1234/subagents", isDirectory: true)
    try fm.createDirectory(at: sidecar, withIntermediateDirectories: true)
    for name in ["agent-a1.jsonl", "agent-a1.meta.json"] {
        try fm.copyItem(at: fixtureURL("withsub/subagents/\(name)"), to: sidecar.appendingPathComponent(name))
    }

    let ref = SubagentIndex.load(for: session)["toolu_fixture_a1"]
    #expect(ref?.agentType == "general-purpose")
    #expect(ref?.fileURL.deletingLastPathComponent().standardizedFileURL == sidecar.standardizedFileURL)
}

@Test func skipsMalformedAndUntaggedMetaWithoutThrowing() throws {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory.appendingPathComponent("subagent-bad-\(UUID().uuidString)", isDirectory: true)
    let sidecar = tmp.appendingPathComponent("s/subagents", isDirectory: true)
    try fm.createDirectory(at: sidecar, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmp) }

    try Data("{not json".utf8).write(to: sidecar.appendingPathComponent("agent-bad.meta.json"))
    try Data("{\"agentType\":\"general-purpose\"}".utf8).write(to: sidecar.appendingPathComponent("agent-notag.meta.json"))
    try Data("{\"toolUseId\":\"toolu_ok\"}".utf8).write(to: sidecar.appendingPathComponent("agent-ok.meta.json"))
    try Data("{}\n".utf8).write(to: sidecar.appendingPathComponent("agent-ok.jsonl"))
    try Data("{\"toolUseId\":\"toolu_nojsonl\"}".utf8).write(to: sidecar.appendingPathComponent("agent-nojsonl.meta.json"))

    let index = SubagentIndex.load(for: tmp.appendingPathComponent("s.jsonl"))
    #expect(Set(index.keys) == ["toolu_ok"])
    #expect(index["toolu_ok"]?.agentType == "")
}
