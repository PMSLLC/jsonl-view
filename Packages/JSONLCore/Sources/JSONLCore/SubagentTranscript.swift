import Foundation

/// Size and modification date of a file, to tell whether it changed since it was read.
public struct FileStamp: Equatable, Sendable {
    public let size: UInt64
    public let mtime: Date

    public init?(_ url: URL) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value,
              let mtime = attrs[.modificationDate] as? Date else { return nil }
        self.size = size
        self.mtime = mtime
    }
}

/// A subagent's own conversation, loaded on demand from its sidecar file.
public struct SubagentTranscript: Sendable {
    public let items: [ConversationItem]
    public let toolCallCount: Int
    /// The subagent's last text reply. Background agents return only a launch notice to the
    /// parent, so this is the real final result for them.
    public let finalText: String?
    /// Set when the transcript file could not be read.
    public var error: String?
    /// The file's size and date when it was read (taken before reading, so a write during the
    /// read still shows up as a change).
    public let stamp: FileStamp?

    static let displayLimit = 400

    /// Subagent records are all `isSidechain: true`, which `SessionModel` hides, so the flag is cleared first.
    public static func load(_ url: URL) -> SubagentTranscript {
        let stamp = FileStamp(url)
        let lines: [Data]
        do {
            lines = try LineReader.read(fileAt: url, from: 0).lines
        } catch {
            return SubagentTranscript(items: [], toolCallCount: 0, finalText: nil,
                                      error: "Could not read the subagent transcript: \(readableReason(error))",
                                      stamp: stamp)
        }
        let records: [JSONValue] = lines.compactMap { line in
            guard case .object(var o)? = decodeRecord(line) else { return nil }
            o["isSidechain"] = .bool(false)
            return .object(o)
        }
        let model = SessionModel()
        model.append(records)
        let last = model.items.last { if case .assistantText = $0.kind { true } else { false } }
        var finalText: String?
        if case .assistantText(let t)? = last?.kind { finalText = t }
        return SubagentTranscript(items: model.items, toolCallCount: model.toolCalls.count,
                                  finalText: finalText, error: nil, stamp: stamp)
    }

    /// True when the file at `url` no longer matches what was read.
    public func isStale(_ url: URL) -> Bool {
        FileStamp(url) != stamp
    }

    /// What a background agent's tool call returns at once; the real result comes later.
    static let launchNoticePrefix = "Async agent launched successfully"

    /// The line shown under a subagent row: the parent's tool result when it has a real one,
    /// else the subagent's last reply, else what the subagent was asked to do.
    public static func displayLine(result: String?, transcript: SubagentTranscript?, description: String) -> String {
        let real = result.flatMap { $0.isEmpty || $0.hasPrefix(launchNoticePrefix) ? nil : $0 }
        return String((real ?? transcript?.finalText ?? description).prefix(displayLimit))
    }
}

/// The handful of records `SessionFacts` reads for title, cwd, branch and model, so a viewer
/// does not have to keep every decoded record of a large file.
public struct MetaRecords: Sendable {
    private var title, cwd, branch, model: JSONValue?

    public init() {}

    public mutating func absorb(_ records: [JSONValue]) {
        for r in records {
            let type = r["type"]?.stringValue
            if type == "ai-title", let t = r["aiTitle"]?.stringValue, !t.isEmpty {
                title = .object(["type": .string("ai-title"), "aiTitle": .string(t)])
            }
            if let c = r["cwd"]?.stringValue, !c.isEmpty { cwd = .object(["cwd": .string(c)]) }
            if let b = r["gitBranch"]?.stringValue, !b.isEmpty { branch = .object(["gitBranch": .string(b)]) }
            if type == "assistant", r["isSidechain"] != .bool(true), let m = r["message"]?["model"]?.stringValue, !m.isEmpty {
                model = .object(["type": .string("assistant"), "message": .object(["model": .string(m)])])
            }
        }
    }

    public var records: [JSONValue] { [title, cwd, branch, model].compactMap { $0 } }
}

/// The underlying POSIX reason ("Permission denied") when there is one. Foundation's own
/// description of a failed read can talk about saving, which is misleading in a viewer.
public func readableReason(_ error: Error) -> String {
    let ns = error as NSError
    if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError { return underlying.localizedDescription }
    return ns.localizedDescription
}
