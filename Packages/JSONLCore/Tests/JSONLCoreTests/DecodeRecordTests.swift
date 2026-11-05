import Foundation
import Testing
@testable import JSONLCore

private func dec(_ s: String) -> JSONValue? { decodeRecord(Data(s.utf8)) }

@Test func decodeRecordMapsTypes() {
    #expect(dec("{\"t\":true,\"f\":false}") == .object(["t": .bool(true), "f": .bool(false)]))
    #expect(dec("{\"one\":1,\"zero\":0}") == .object(["one": .number(1), "zero": .number(0)]))
    #expect(dec("{\"n\":null}") == .object(["n": .null]))
    #expect(dec("{\"a\":[1,[true,null],{\"k\":\"v\"}],\"o\":{\"x\":{\"y\":[]}}}") == .object([
        "a": .array([.number(1), .array([.bool(true), .null]), .object(["k": .string("v")])]),
        "o": .object(["x": .object(["y": .array([])])]),
    ]))
    #expect(dec("5") == .number(5))
    #expect(dec("\"x\"") == .string("x"))
    #expect(dec("[1]") == .array([.number(1)]))
}
