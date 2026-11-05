import Foundation

public enum GenericLayout: Equatable, Sendable {
    case table(columns: [String])
    case records
}

public struct GenericFacts: Sendable {
    public let recordCount: Int
    public let invalidCount: Int
    public let topKeys: [(key: String, share: Double)]
    public let samples: [JSONValue]
}

/// Model for any `.jsonl` that is not a Claude Code transcript.
public final class GenericModel {
    static let maxColumns = 12, maxTopKeys = 12, sampleCount = 3
    static let tableThreshold = 0.8
    public static let digestLimit = 6_000

    public private(set) var records: [JSONValue] = []
    public private(set) var invalidCount = 0

    /// Top-level keys of each record in `records`, in file order (empty for non-objects).
    private var recordKeys: [[String]] = []
    private var keyOrder: [String] = []        // union, first appearance
    private var keyCounts: [String: Int] = [:] // object records containing the key
    private var objectCount = 0

    public init() {}

    public func append(_ chunk: LineChunk) {
        for line in chunk.lines {
            if isBlank(line) { continue }   // blank lines are not records, and not errors either
            guard let value = decodeRecord(line) else { invalidCount += 1; continue }
            var keys: [String] = []
            if case .object = value {
                var seen = Set<String>()
                keys = topLevelKeysInOrder(line).filter { seen.insert($0).inserted }
                objectCount += 1
                for k in keys {
                    if keyCounts[k] == nil { keyOrder.append(k) }
                    keyCounts[k, default: 0] += 1
                }
            }
            records.append(value)
            recordKeys.append(keys)
        }
    }

    /// Table when at least 80% of all valid records (invalid lines excluded) are
    /// objects that each contain at least 80% of the union of top-level keys.
    /// Non-object records stay in the denominator, so they count against uniformity.
    public var layout: GenericLayout {
        guard objectCount > 0, !keyOrder.isEmpty else { return .records }
        let needed = Double(keyOrder.count) * Self.tableThreshold
        let uniform = recordKeys.filter { !$0.isEmpty && Double($0.count) >= needed }.count
        guard Double(uniform) >= Double(records.count) * Self.tableThreshold else { return .records }
        return .table(columns: Array(keyOrder.prefix(Self.maxColumns)))
    }

    public func facts() -> GenericFacts {
        let ranked = keyOrder.enumerated()
            .map { (idx: $0.offset, key: $0.element, share: Double(keyCounts[$0.element] ?? 0) / Double(max(objectCount, 1))) }
            .sorted { $0.share != $1.share ? $0.share > $1.share : $0.idx < $1.idx }
            .prefix(Self.maxTopKeys)
            .map { (key: $0.key, share: $0.share) }
        return GenericFacts(recordCount: records.count, invalidCount: invalidCount,
                            topKeys: Array(ranked), samples: Array(records.prefix(Self.sampleCount)))
    }

    public func digest() -> String {
        let f = facts()
        var out = "Records: \(f.recordCount), invalid lines: \(f.invalidCount)\n"
        switch layout {
        case .table(let cols): out += "Layout: table, columns: \(cols.joined(separator: ", "))\n"
        case .records: out += "Layout: records\n"
        }
        if !f.topKeys.isEmpty {
            out += "Common keys: " + f.topKeys.map { "\($0.key) (\(Int(($0.share * 100).rounded()))%)" }.joined(separator: ", ") + "\n"
        }
        out += "\nSamples:\n"
        for s in f.samples {
            let text = (try? JSONEncoder().encode(s)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            out += "- " + text.prefix(1_000) + "\n"
        }
        return String(out.prefix(Self.digestLimit))
    }
}

/// True for an empty line or one of only spaces, tabs and carriage returns.
func isBlank(_ line: Data) -> Bool {
    line.allSatisfy { $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }
}

/// Top-level keys of one JSON object line in file order. `JSONValue.object` is
/// unordered, so first-appearance order has to come from the raw bytes.
func topLevelKeysInOrder(_ line: Data) -> [String] {
    var keys: [String] = []
    var depth = 0
    var i = line.startIndex
    let end = line.endIndex
    while i < end {
        let b = line[i]
        switch b {
        case UInt8(ascii: "{"), UInt8(ascii: "["): depth += 1; i += 1
        case UInt8(ascii: "}"), UInt8(ascii: "]"): depth -= 1; i += 1
        case UInt8(ascii: "\""):
            let start = i
            i += 1
            while i < end, line[i] != UInt8(ascii: "\"") { i += line[i] == UInt8(ascii: "\\") ? 2 : 1 }
            let stop = min(i + 1, end)   // one past closing quote
            i = stop
            guard depth == 1 else { continue }
            var j = i
            while j < end, line[j] == 0x20 || line[j] == 0x09 || line[j] == 0x0A || line[j] == 0x0D { j += 1 }
            if j < end, line[j] == UInt8(ascii: ":"),
               case .string(let k)? = decodeRecord(line.subdata(in: start..<stop)) {
                keys.append(k)
            }
        default: i += 1
        }
    }
    return keys
}
