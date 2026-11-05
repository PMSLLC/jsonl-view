import Foundation
import Testing
@testable import JSONLCore

func fixtureRecords(_ name: String) throws -> [JSONValue] {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/\(name).jsonl")
    return try LineReader.read(fileAt: url, from: 0).lines.compactMap(decodeRecord)
}

@Test func detectsClaude() throws {
    #expect(FormatDetector.detect(try fixtureRecords("session-basic")) == .claudeSession)
}

@Test func genericWhenNoClaudeShape() {
    let recs: [JSONValue] = [.object(["id": .number(1)]), .object(["type": .string("user")])]
    #expect(FormatDetector.detect(recs) == .generic)
}
