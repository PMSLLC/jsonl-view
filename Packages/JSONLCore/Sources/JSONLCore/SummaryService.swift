import Foundation

public protocol Summarizing: Sendable {
    func summarize(_ digest: String, format: FileFormat) async throws -> String
}

/// What the model is told to do, per file format. Lives here, not in JSONLSummarizer, because
/// `version` is part of the cache key that the Quick Look extension computes too.
public enum SummaryInstructions {
    /// Bump whenever the text below changes, so summaries made with older text are not reused.
    public static let version = 2

    public static func text(for format: FileFormat) -> String {
        switch format {
        case .claudeSession:
            "Summarize this Claude Code session for its owner in 2 to 3 plain sentences: what was asked, what got done. End with 'Outcome: done', 'Outcome: partial' or 'Outcome: abandoned'. No em dashes."
        case .generic:
            "Summarize this JSONL data file for its owner in 2 to 3 plain sentences: what the records are and anything notable. No em dashes."
        }
    }
}

public enum SummaryState: Equatable, Sendable {
    case generating
    case ready(String)
    /// The model cannot run on this Mac right now (thrown as `SummaryUnavailable`).
    case unavailable(String)
    /// The model ran but failed on this file (context overflow, guardrail, any other error).
    case failed(String)
}

/// The model cannot run here; `reason` is shown to the user as is. Only for availability
/// problems: errors about one file's content are thrown as themselves and become `.failed`.
public struct SummaryUnavailable: Error, Equatable, Sendable {
    public let reason: String
    public init(reason: String) { self.reason = reason }
}

public actor SummaryService {
    private let summarizer: Summarizing
    private let cache: SummaryCache
    private var inFlight: [CacheKey: Task<SummaryState, Never>] = [:]

    public init(summarizer: Summarizing, cache: SummaryCache) {
        self.summarizer = summarizer
        self.cache = cache
    }

    /// Cached result if present; otherwise one generation per key, shared by concurrent callers.
    public func summary(for key: CacheKey, digest: @escaping @Sendable () -> String) async -> SummaryState {
        if let hit = cache.get(key) { return .ready(hit) }
        if let running = inFlight[key] { return await running.value }
        let summarizer = summarizer, cache = cache
        let task = Task<SummaryState, Never> {
            do {
                let text = try await summarizer.summarize(digest(), format: key.format)
                cache.put(key, text)
                return .ready(text)
            } catch let e as SummaryUnavailable {
                return .unavailable(e.reason)
            } catch {
                return .failed("Summary unavailable: \(error.localizedDescription)")
            }
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        return result
    }
}
