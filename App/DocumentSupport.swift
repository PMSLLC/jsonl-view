import Foundation
import JSONLCore
import JSONLSummarizer
import os

private let siblingHeadBytes = 262_144
private let summaryLog = Logger(subsystem: "com.brahy.jsonl-view", category: "summary")

/// Title of a sibling file from its first 256 KB, or the file name for non-sessions.
nonisolated func siblingTitle(_ url: URL) -> String {
    let fallback = url.deletingPathExtension().lastPathComponent
    guard let chunk = try? LineReader.read(fileAt: url, from: 0, maxBytes: siblingHeadBytes) else { return fallback }
    let records = chunk.lines.compactMap(decodeRecord)
    guard FormatDetector.detect(records) == .claudeSession else { return fallback }
    let model = SessionModel()
    model.append(records)
    return SessionFacts.make(model: model, records: records, fileURL: url).title
}

/// One-line JSON for table cells, row labels and search.
nonisolated func compactJSON(_ v: JSONValue, limit: Int = 300) -> String {
    let s: String
    switch v {
    case .string(let x): s = x
    case .number(let n): s = n == n.rounded() && abs(n) < 1e15 ? String(Int64(n)) : String(n)
    case .bool(let b): s = b ? "true" : "false"
    case .null: s = "null"
    case .array, .object:
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        s = (try? enc.encode(v)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
    guard s.utf8.count > limit, s.count > limit else { return s }
    return String(s.prefix(limit)) + "..."
}

nonisolated func prettyJSON(_ v: JSONValue, limit: Int = 20_000) -> String {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let s = (try? enc.encode(v)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    return s.utf8.count > limit ? String(s.prefix(limit)) + "\n..." : s
}

@MainActor
enum Summaries {
    static let service = SummaryService(summarizer: FoundationModelsSummarizer(), cache: cache)
    /// Background summaries for the sibling files of open windows, so Quick Look can show them.
    static let folders = FolderSummaryCoordinator(service: service, cache: cache)

    private static let cache: SummaryCache = {
        // The App Group container is unusable when the app is unsigned, so check it can be created.
        let fm = FileManager.default
        var dir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/com.brahy.jsonl-view/Summaries", isDirectory: true)
        if let group = SummaryCache.defaultDirectory(),
           (try? fm.createDirectory(at: group, withIntermediateDirectories: true)) != nil {
            dir = group
        } else {
            summaryLog.warning("App Group container unavailable; summaries go to ~/Library/Caches, which Quick Look cannot read")
        }
        summaryLog.info("summary cache: \(dir.path)")
        return SummaryCache(directory: dir)
    }()
}
