import Foundation
import JSONLCore
import os

let searchLog = Logger(subsystem: "com.brahy.jsonl-view", category: "search")

/// Search state shared by the conversation and generic views.
struct SearchState: Equatable {
    var query = ""
    /// Matching item ids (or record indices), nil when no search is active.
    var matches: [Int]?
    /// Index into `matches` that Return last moved to.
    var current: Int?

    /// The query `matches` belongs to, and how many items or records it has covered.
    var scannedQuery = ""
    var scannedCount = 0
    /// Tool calls that had no result when scanned; rescanned when the file grows.
    var pending: [Int] = []

    var currentID: Int? { current.flatMap { matches?[$0] } }
    var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }
}

/// Cancellable scans that run off the main actor. Cancellation is checked between items,
/// so a superseded query stops promptly.
enum SearchScan {
    private static let checkEvery = 64

    struct Result: Sendable {
        let matches: [Int]
        let pending: [Int]
    }

    /// Scans `items[range]` plus the items with ids in `extra`.
    @concurrent
    static func items(_ items: [ConversationItem], range: Range<Int>, extra: [Int], query: String) async throws -> Result {
        var matches: [Int] = [], pending: [Int] = []
        let ids = extra.filter { $0 < range.lowerBound } + Array(range)
        for (n, id) in ids.enumerated() {
            if n % checkEvery == 0 { try Task.checkCancellation() }
            let item = items[id]
            if item.matches(query) { matches.append(id) }
            if case .toolCall(let c) = item.kind, c.result == nil { pending.append(id) }
        }
        return Result(matches: matches, pending: pending)
    }

    @concurrent
    static func records(_ records: [JSONValue], range: Range<Int>, query: String) async throws -> [Int] {
        var matches: [Int] = []
        for i in range {
            if (i - range.lowerBound) % checkEvery == 0 { try Task.checkCancellation() }
            if compactJSON(records[i], limit: .max).range(of: query, options: .caseInsensitive) != nil {
                matches.append(i)
            }
        }
        return matches
    }
}

/// One serialized search pipeline per window. Steps never overlap: a query change cancels the
/// running pipeline and starts a fresh one; new data only marks it dirty, and the running
/// pipeline keeps stepping until a pass ends with nothing new. So it always ends caught up,
/// and each item is scanned once per query (no duplicate ids).
@MainActor @Observable
final class SearchModel {
    var state = SearchState()

    @ObservationIgnored weak var controller: DocumentController?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var dirty = false
    /// `DocumentController.loadCount` the scanned state belongs to; a reload forces a full scan.
    @ObservationIgnored private var scannedLoad = -1

    func queryChanged() {
        task?.cancel()
        task = nil
        guard !state.trimmedQuery.isEmpty else {
            state = SearchState(query: state.query)
            return
        }
        dirty = true
        run(debounce: true)
    }

    func dataChanged() {
        guard !state.trimmedQuery.isEmpty else { return }
        if let c = controller, c.loadCount != scannedLoad, state.matches != nil {
            // Reloaded (truncated, replaced or switched format): old ids point at other items.
            state.matches = []
            state.current = nil
        }
        dirty = true
        if task == nil { run(debounce: false) }
    }

    func nextMatch() -> Int? {
        guard let m = state.matches, !m.isEmpty else { return nil }
        let next = state.current.map { ($0 + 1) % m.count } ?? 0
        state.current = next
        return m[next]
    }

    private func run(debounce: Bool) {
        task = Task { [weak self] in
            if debounce {
                try? await Task.sleep(for: .milliseconds(200))
            }
            while !Task.isCancelled, let self, self.dirty {
                self.dirty = false
                do { try await self.step() } catch { return }   // cancelled by a newer query
            }
            if !Task.isCancelled { self?.task = nil }
        }
    }

    /// One pass: a full scan for a new query or a reloaded file, otherwise only what is new.
    private func step() async throws {
        guard let c = controller else { return }
        let q = state.trimmedQuery
        let load = c.loadCount
        let began = Date()
        let isSession = c.format == .claudeSession
        let total = isSession ? c.items.count : c.records.count
        let full = q != state.scannedQuery || load != scannedLoad || total < state.scannedCount
        let from = full ? 0 : state.scannedCount
        var matches: [Int], pending: [Int] = []
        if isSession {
            let items = c.items
            let extra = full ? [] : state.pending
            let r = try await SearchScan.items(items, range: from..<items.count, extra: extra, query: q)
            try Task.checkCancellation()
            let rescanned = Set(extra)
            let kept = full ? [] : (state.matches ?? []).filter { !rescanned.contains($0) }
            matches = (kept + r.matches).sorted()
            pending = r.pending
        } else {
            let records = c.records
            let m = try await SearchScan.records(records, range: from..<records.count, query: q)
            try Task.checkCancellation()
            matches = (full ? [] : state.matches ?? []) + m
        }
        let currentID = full ? nil : state.currentID
        state.matches = matches
        state.current = currentID.flatMap { matches.firstIndex(of: $0) }
        state.scannedQuery = q
        state.scannedCount = total
        state.pending = pending
        scannedLoad = load
        searchLog.info("search \(full ? "full" : "incremental", privacy: .public) \(q.count) chars over \(total) items: \(matches.count) matches in \(Int(Date().timeIntervalSince(began) * 1000)) ms")
    }
}
