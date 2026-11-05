import Foundation

public enum FileFormat: Sendable, Equatable {
    case claudeSession, generic
}

public enum FormatDetector {
    static let claudeTypes: Set<String> = ["user", "assistant", "summary", "ai-title"]
    /// How many leading records `detect` looks at.
    public static let probeCount = 20

    /// A Claude Code session if one of the first 20 records has a known `type`
    /// plus a `sessionId` or `message` field.
    public static func detect(_ records: [JSONValue]) -> FileFormat {
        for r in records.prefix(probeCount) {
            guard let type = r["type"]?.stringValue, claudeTypes.contains(type) else { continue }
            if r["sessionId"] != nil || r["message"] != nil { return .claudeSession }
        }
        return .generic
    }
}
