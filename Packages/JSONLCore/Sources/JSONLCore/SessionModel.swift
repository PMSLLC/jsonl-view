import Foundation

public struct ToolCall: Sendable, Equatable {
    public let id: String
    public let name: String
    public let inputSummary: String
    public let input: JSONValue
    public var result: String?
    public var resultIsError: Bool
}

public enum ItemKind: Sendable, Equatable {
    case userPrompt(String)
    case assistantText(String)
    case thinking(String)
    case toolCall(ToolCall)
    /// Harness-injected `<task-notification>` user record. `summary` is its `<summary>` when
    /// present; `body` is the whole notification text.
    case notification(summary: String, body: String)
    /// The summary Claude Code writes when it compacts the context (`isCompactSummary`).
    case compaction(String)
}

public struct ConversationItem: Identifiable, Sendable, Equatable {
    public let id: Int
    public let timestamp: Date?
    public let kind: ItemKind

    public var kindName: String {
        switch kind {
        case .userPrompt: "userPrompt"
        case .assistantText: "assistantText"
        case .thinking: "thinking"
        case .toolCall: "toolCall"
        case .notification: "notification"
        case .compaction: "compaction"
        }
    }

    /// Case-insensitive match against everything the row can show.
    public func matches(_ query: String) -> Bool {
        func has(_ s: String) -> Bool { s.range(of: query, options: .caseInsensitive) != nil }
        switch kind {
        case .userPrompt(let t), .assistantText(let t), .thinking(let t), .compaction(let t): return has(t)
        case .notification(let summary, let body): return has(summary) || has(body)
        case .toolCall(let c): return has(c.name) || has(c.inputSummary) || (c.result.map(has) ?? false)
        }
    }
}

public final class SessionModel {
    public static let resultPreviewLimit = 20_000

    public private(set) var items: [ConversationItem] = []
    private var callIndex: [String: Int] = [:]   // tool_use id -> index in items

    public init() {}

    public var outline: [ConversationItem] {
        items.filter { if case .userPrompt = $0.kind { true } else { false } }
    }

    public var toolCalls: [ToolCall] {
        items.compactMap { if case .toolCall(let c) = $0.kind { c } else { nil } }
    }

    public static func resultPreview(_ s: String) -> (text: String, truncated: Bool) {
        guard s.utf8.count > Self.resultPreviewLimit, s.count > Self.resultPreviewLimit else { return (s, false) }
        return (String(s.prefix(Self.resultPreviewLimit)), true)
    }

    private static let tagRegex = try! NSRegularExpression(
        pattern: "<(system-reminder|command-[a-z]+|local-command-[a-z]+)>.*?</\\1>",
        options: [.dotMatchesLineSeparators])

    static func stripTags(_ text: String) -> String {
        var out = text
        let hasTag = text.utf8.withContiguousStorageIfAvailable { memchr($0.baseAddress, 0x3C, $0.count) != nil }
            ?? text.utf8.contains(0x3C)
        if hasTag {   // "<": skip the regex for the common tag-free case
            let range = NSRange(text.startIndex..., in: text)
            out = tagRegex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        }
        // Trim only when needed: Foundation's trim is slow on large strings.
        if let f = out.unicodeScalars.first, let l = out.unicodeScalars.last,
           !(CharacterSet.whitespacesAndNewlines.contains(f) || CharacterSet.whitespacesAndNewlines.contains(l)) {
            return out
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func append(_ records: [JSONValue]) {
        for r in records {
            guard r["isSidechain"] != .bool(true), let type = r["type"]?.stringValue else { continue }
            let ts = r["timestamp"]?.stringValue.flatMap(Self.parseDate)
            switch type {
            case "user":
                if r["isMeta"] == .bool(true) { continue }
                if r["isCompactSummary"] == .bool(true) {
                    appendCompaction(r["message"]?["content"], ts)
                    continue
                }
                appendUser(r["message"]?["content"], ts)
            case "assistant":
                appendAssistant(r["message"]?["content"], ts)
            default:
                continue
            }
        }
    }

    private func appendUser(_ content: JSONValue?, _ ts: Date?) {
        switch content {
        case .string(let s):
            addPrompt(s, ts)
        case .array(let blocks):
            for b in blocks {
                switch b["type"]?.stringValue {
                case "text": if let t = b["text"]?.stringValue { addPrompt(t, ts) }
                case "tool_result": fillResult(b)
                default: break
                }
            }
        default: break
        }
    }

    /// Kept out of the prompts: Claude Code wrote it, the user did not type it.
    private func appendCompaction(_ content: JSONValue?, _ ts: Date?) {
        let text: String
        switch content {
        case .string(let s): text = s
        case .array(let blocks): text = blocks.compactMap { $0["type"]?.stringValue == "text" ? $0["text"]?.stringValue : nil }
            .joined(separator: "\n")
        default: text = ""
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { add(.compaction(trimmed), ts) }
    }

    private func addPrompt(_ raw: String, _ ts: Date?) {
        if let note = Self.notificationText(raw) {
            add(.notification(summary: note, body: raw.trimmingCharacters(in: .whitespacesAndNewlines)), ts)
            return
        }
        let text = Self.stripTags(raw)
        if !text.isEmpty { add(.userPrompt(text), ts) }
    }

    private func appendAssistant(_ content: JSONValue?, _ ts: Date?) {
        if case .string(let s) = content {
            if !s.isEmpty { add(.assistantText(s), ts) }
            return
        }
        guard let blocks = content?.arrayValue else { return }
        for b in blocks {
            switch b["type"]?.stringValue {
            case "text":
                if let t = b["text"]?.stringValue, !t.isEmpty { add(.assistantText(t), ts) }
            case "thinking":
                if let t = b["thinking"]?.stringValue, !t.isEmpty { add(.thinking(t), ts) }
            case "tool_use":
                let name = b["name"]?.stringValue ?? "?"
                let id = b["id"]?.stringValue ?? ""
                let input = b["input"] ?? .null
                let call = ToolCall(id: id, name: name, inputSummary: Self.summarize(name, input),
                                    input: input, result: nil, resultIsError: false)
                callIndex[id] = items.count
                add(.toolCall(call), ts)
            default: break
            }
        }
    }

    private func fillResult(_ block: JSONValue) {
        guard let id = block["tool_use_id"]?.stringValue, let idx = callIndex[id],
              case .toolCall(var call) = items[idx].kind else { return }
        call.result = Self.resultText(block["content"])
        call.resultIsError = block["is_error"] == .bool(true)
        items[idx] = ConversationItem(id: items[idx].id, timestamp: items[idx].timestamp, kind: .toolCall(call))
    }

    private func add(_ kind: ItemKind, _ ts: Date?) {
        items.append(ConversationItem(id: items.count, timestamp: ts, kind: kind))
    }

    private static let summaryRegex = try! NSRegularExpression(
        pattern: "<summary>(.*?)</summary>", options: [.dotMatchesLineSeparators])

    /// For text that starts with `<task-notification>`: its `<summary>`, else the tag-stripped text.
    /// nil for anything else.
    static func notificationText(_ raw: String) -> String? {
        let head = raw.prefix(64).drop(while: \.isWhitespace)
        guard head.hasPrefix("<task-notification>") else { return nil }
        let range = NSRange(raw.startIndex..., in: raw)
        if let m = summaryRegex.firstMatch(in: raw, range: range), let r = Range(m.range(at: 1), in: raw) {
            let s = raw[r].trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { return s }
        }
        let stripped = raw.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return stripped.isEmpty ? "task notification" : String(stripped.prefix(500))
    }

    static func resultText(_ content: JSONValue?) -> String {
        switch content {
        case .string(let s): return s
        case .array(let blocks):
            return blocks.map { b in
                switch b["type"]?.stringValue {
                case "text": b["text"]?.stringValue ?? ""
                case "image": "[image]"
                default: "[\(b["type"]?.stringValue ?? "unknown")]"
                }
            }.joined(separator: "\n")
        default: return ""
        }
    }

    static func summarize(_ name: String, _ input: JSONValue) -> String {
        let key: String?
        switch name {
        case "Bash": key = "command"
        case "Read", "Edit", "Write": key = "file_path"
        case "Grep", "Glob": key = "pattern"
        case "Agent", "Task": key = "description"
        default: key = nil
        }
        var s = key.flatMap { input[$0]?.stringValue }
        if s == nil {
            s = input.objectValue?.sorted { $0.key < $1.key }.lazy.compactMap { $0.value.stringValue }.first
        }
        // Cut to 120 characters first: grapheme-walking a whole large command is slow.
        let head = String((s ?? "").prefix(120))
        return head.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    }

    private nonisolated(unsafe) static let fracFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private nonisolated(unsafe) static let plainFormatter = ISO8601DateFormatter()

    static func parseDate(_ s: String) -> Date? {
        fracFormatter.date(from: s) ?? plainFormatter.date(from: s)
    }
}
