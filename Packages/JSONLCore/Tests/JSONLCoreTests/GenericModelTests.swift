import Foundation
import Testing
@testable import JSONLCore

private func genericModel(_ name: String) throws -> GenericModel {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/\(name).jsonl")
    let chunk = try LineReader.read(fileAt: url, from: 0)
    let m = GenericModel(); m.append(chunk); return m
}

@Test func uniformIsTable() throws {
    let m = try genericModel("uniform")
    #expect(m.layout == .table(columns: ["id", "name", "score"]))
    #expect(m.records.count == 3)
    #expect(m.invalidCount == 0)
}

@Test func mixedIsRecords() throws {
    let m = try genericModel("mixed")
    #expect(m.layout == .records)
    #expect(m.records.count == 5)
}

@Test func testNonJSONFileIsGeneric() throws {
    let m = try genericModel("notjson")
    #expect(m.layout == .records)
    #expect(m.invalidCount == 3)
    #expect(m.records.isEmpty)
    #expect(m.facts().topKeys.isEmpty)
    #expect(m.digest().count <= 6000)
}

@Test func factsTopKeys() throws {
    let m = try genericModel("mixed")
    let f = m.facts()
    #expect(f.recordCount == 5)
    #expect(f.invalidCount == 0)
    #expect(f.topKeys.map(\.key) == ["id", "name", "event", "ts", "other"])
    #expect(abs(f.topKeys[0].share - 1.0 / 3.0) < 1e-9)
    #expect(f.samples.count == 3)
}

@Test func keyOrderIgnoresNestedKeys() {
    let line = Data(#"{"z":{"inner":1,"x":2},"a":"{\"fake\":1}","m":[{"q":1}]}"#.utf8)
    #expect(topLevelKeysInOrder(line) == ["z", "a", "m"])
}

@Test func digestIsCapped() {
    let big = String(repeating: "x", count: 20_000)
    let m = GenericModel()
    let line = Data(#"{"k":"\#(big)"}"#.utf8)
    m.append(LineChunk(lines: [line], nextOffset: UInt64(line.count)))
    #expect(m.digest().count <= 6000)
}

private func inlineModel(_ lines: [String]) -> GenericModel {
    let m = GenericModel()
    m.append(LineChunk(lines: lines.map { Data($0.utf8) }, nextOffset: 0))
    return m
}

private let uniformObject = #"{"id":1,"name":"a"}"#

@Test func scalarsBreakTable() {
    let m = inlineModel(Array(repeating: uniformObject, count: 8) + Array(repeating: "5", count: 4))
    #expect(m.layout == .records)
}

@Test func fewScalarsKeepTable() {
    let m = inlineModel(Array(repeating: uniformObject, count: 9) + ["5"])
    #expect(m.layout == .table(columns: ["id", "name"]))
}

@Test func duplicateKeysCountOnce() {
    let m = inlineModel([#"{"a":1,"a":2}"#, #"{"b":1}"#])
    let f = m.facts()
    #expect(f.topKeys.first(where: { $0.key == "a" })?.share == 0.5)
}

@Test func higherShareOutranksEarlierKey() {
    let m = inlineModel([#"{"rare":1,"common":1}"#, #"{"common":2}"#, #"{"common":3}"#])
    let f = m.facts()
    #expect(f.topKeys.map(\.key) == ["common", "rare"])
}

@Test func blankLinesAreSkippedNotInvalid() {
    let m = inlineModel([#"{"id":1}"#, "", "   ", "\t", #"{"id":2}"#, "nope"])
    #expect(m.records.count == 2)
    #expect(m.invalidCount == 1)
}
