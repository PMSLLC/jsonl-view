import Foundation

public struct SubagentRef: Sendable, Equatable {
    public let toolUseId: String
    public let agentType: String
    public let description: String
    public let fileURL: URL
}

/// Finds the subagent transcripts that belong to a session.
/// Layout: `<dir>/<session basename>/subagents/agent-<id>.jsonl` with a sibling `agent-<id>.meta.json`.
public enum SubagentIndex {
    /// Keyed by the parent's `tool_use.id`. A missing sidecar folder gives an empty dictionary.
    /// Meta files that are malformed, lack a `toolUseId`, or have no paired `.jsonl` are skipped.
    public static func load(for sessionURL: URL) -> [String: SubagentRef] {
        let fm = FileManager.default
        let dir = sessionURL.deletingPathExtension().appendingPathComponent("subagents", isDirectory: true)
        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        var index: [String: SubagentRef] = [:]
        for name in names where name.hasSuffix(".meta.json") {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)),
                  let meta = decodeRecord(data)?.objectValue,
                  let toolUseId = meta["toolUseId"]?.stringValue, !toolUseId.isEmpty else { continue }
            let jsonlURL = dir.appendingPathComponent(String(name.dropLast(".meta.json".count)) + ".jsonl")
            guard fm.fileExists(atPath: jsonlURL.path) else { continue }
            index[toolUseId] = SubagentRef(
                toolUseId: toolUseId,
                agentType: meta["agentType"]?.stringValue ?? "",
                description: meta["description"]?.stringValue ?? "",
                fileURL: jsonlURL)
        }
        return index
    }
}
