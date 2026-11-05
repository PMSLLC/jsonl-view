import Foundation

public struct SessionFacts: Sendable, Equatable {
    public var title: String
    public var cwd: String?
    public var branch: String?
    public var start: Date?
    public var end: Date?
    public var promptCount: Int
    public var toolCallCount: Int
    public var subagentCount: Int
    public var filesEdited: Int
    public var fileBytes: UInt64
    public var model: String?
    public var firstPrompt: String?
    public var lastReply: String?
    /// True when the facts come from part of the file only (the Quick Look cap), so counts are lower bounds.
    public var approximate: Bool = false

    static let editTools: Set<String> = ["Edit", "Write", "NotebookEdit"]
    static let titleLimit = 60

    public static func make(model: SessionModel, records: [JSONValue], fileURL: URL) -> SessionFacts {
        var aiTitle: String?, cwd: String?, branch: String?, rawModel: String?
        for r in records {
            if r["type"]?.stringValue == "ai-title", let t = r["aiTitle"]?.stringValue, !t.isEmpty { aiTitle = t }
            if let c = r["cwd"]?.stringValue, !c.isEmpty { cwd = c }
            if let b = r["gitBranch"]?.stringValue, !b.isEmpty { branch = b }
            if r["type"]?.stringValue == "assistant", r["isSidechain"] != .bool(true),
               let m = r["message"]?["model"]?.stringValue, !m.isEmpty { rawModel = m }
        }
        var firstPrompt: String?, lastReply: String?, promptCount = 0
        for item in model.items {
            switch item.kind {
            case .userPrompt(let p):
                promptCount += 1
                if firstPrompt == nil { firstPrompt = p }
            case .assistantText(let t): lastReply = t
            default: break
            }
        }
        let calls = model.toolCalls
        let stamps = model.items.compactMap(\.timestamp)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? UInt64) ?? 0

        return SessionFacts(
            title: aiTitle ?? firstPrompt.map(shortTitle) ?? fileURL.deletingPathExtension().lastPathComponent,
            cwd: cwd, branch: branch,
            start: stamps.min(), end: stamps.max(),
            promptCount: promptCount,
            toolCallCount: calls.count,
            subagentCount: calls.filter { $0.name == "Agent" || $0.name == "Task" }.count,
            filesEdited: editedPaths(calls).count,
            fileBytes: bytes,
            model: rawModel.map(shortModel),
            firstPrompt: firstPrompt, lastReply: lastReply)
    }

    /// Distinct `file_path` values of Edit, Write and NotebookEdit calls, in first-seen order.
    static func editedPaths(_ calls: [ToolCall]) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for c in calls where editTools.contains(c.name) {
            if let p = c.input["file_path"]?.stringValue ?? c.input["notebook_path"]?.stringValue, seen.insert(p).inserted {
                out.append(p)
            }
        }
        return out
    }

    /// First line of the prompt, cut to 60 characters at a word boundary.
    static func shortTitle(_ prompt: String) -> String {
        let line = prompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? prompt
        guard line.count > titleLimit else { return line.trimmingCharacters(in: .whitespaces) }
        let head = line.prefix(titleLimit)
        let next = line[line.index(line.startIndex, offsetBy: titleLimit)]
        var cut = Substring(head)
        if !next.isWhitespace, let sp = head.lastIndex(where: \.isWhitespace) { cut = head[..<sp] }
        return cut.trimmingCharacters(in: .whitespaces)
    }

    static func shortModel(_ id: String) -> String {
        for (prefix, name) in [("claude-opus-", "Opus"), ("claude-sonnet-", "Sonnet"),
                               ("claude-haiku-", "Haiku"), ("claude-fable-", "Fable")] where id.hasPrefix(prefix) {
            return name
        }
        return id
    }
}
