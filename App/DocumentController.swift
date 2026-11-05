import Foundation
import JSONLCore
import Observation
import os

private let headBytes = 2_000_000          // parsed on the main actor so the first screen paints fast
private let sessionChunkBytes = 4_000_000  // background chunks, decoded off the main actor
private let genericChunkBytes = 1_000_000  // GenericModel decodes on append, so keep main-actor work small
private let log = Logger(subsystem: "com.brahy.jsonl-view", category: "load")

/// Everything the window shows for one open file. Main-actor only; the heavy reading and
/// decoding happens in detached tasks that hand back Sendable values.
@MainActor @Observable
final class DocumentController {
    let url: URL
    var format: FileFormat = .generic
    var session: SessionModel?
    var generic: GenericModel?
    var facts: SessionFacts?
    var summary: SummaryState = .generating
    var siblings: [(url: URL, title: String)] = []

    /// Snapshots of the models, republished after every append so views observe them.
    private(set) var items: [ConversationItem] = []
    private(set) var outline: [ConversationItem] = []
    private(set) var records: [JSONValue] = []
    private(set) var genericLayout: GenericLayout = .records
    private(set) var invalidCount = 0
    private(set) var subagents: [String: SubagentRef] = [:]
    private(set) var subagentTranscripts: [String: SubagentTranscript] = [:]
    private(set) var isLoading = true
    /// A summary request is running and its result will be shown.
    private(set) var summaryInFlight = false
    /// Loading, or waiting for the summary: the folder's background summaries hold off meanwhile.
    var ownSummaryPending: Bool { isLoading || summaryInFlight }
    /// Set when a read fails; the content shown is then incomplete and live updates stop.
    private(set) var loadError: String?
    /// Bumped on every publish, including tool results filled into existing items.
    private(set) var revision = 0
    /// Bumped whenever the shown content is rebuilt from scratch (load, reload, format switch).
    private(set) var loadCount = 0

    @ObservationIgnored private var meta = MetaRecords()
    @ObservationIgnored private var tailer: FileTailer?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var summaryToken = 0   // only the latest summary request may land
    @ObservationIgnored private var subagentsInFlight = Set<String>()
    @ObservationIgnored private static var titleCache: [URL: String] = [:]

    init(url: URL) { self.url = url }

    var title: String {
        if format == .claudeSession, let facts { return facts.title }
        return url.deletingPathExtension().lastPathComponent
    }

    // MARK: Loading

    /// Loads (or reloads) from byte 0: head on the main actor, the rest in the background,
    /// then tails the file for live updates.
    func start() {
        stop()
        generation += 1
        let gen = generation
        let began = Date()
        meta = MetaRecords()
        loadCount += 1
        session = nil; generic = nil; facts = nil
        items = []; outline = []; records = []; invalidCount = 0
        isLoading = true
        loadError = nil
        summary = .generating

        let head: LineChunk
        do {
            head = try LineReader.read(fileAt: url, from: 0, maxBytes: headBytes)
        } catch {
            fail(error, gen: gen)
            if siblings.isEmpty { loadSiblings() }
            return
        }
        let lines = head.lines
        let decoded = lines.compactMap(decodeRecord)
        format = FormatDetector.detect(decoded)
        switch format {
        case .claudeSession:
            session = SessionModel()
            ingest(decoded)
            subagents = SubagentIndex.load(for: url)
        case .generic:
            generic = GenericModel()
            generic?.append(head)
        }
        publish()
        log.info("head: \(lines.count) lines in \(Int(Date().timeIntervalSince(began) * 1000)) ms")

        loadRest(from: head.nextOffset, gen: gen, began: began)
        if siblings.isEmpty { loadSiblings() }
    }

    func stop() {
        generation += 1   // drops any in-flight background chunk or finishLoad
        summaryToken += 1
        summaryInFlight = false
        loadTask?.cancel()
        loadTask = nil
        tailer?.stop()
        tailer = nil
    }

    private func loadRest(from offset: UInt64, gen: Int, began: Date) {
        let url = url, isSession = format == .claudeSession
        let chunkBytes = isSession ? sessionChunkBytes : genericChunkBytes
        loadTask = Task.detached(priority: .userInitiated) { [weak self] in
            var offset = offset
            while !Task.isCancelled {
                let chunk: LineChunk
                do {
                    chunk = try LineReader.read(fileAt: url, from: offset, maxBytes: chunkBytes)
                } catch {
                    await self?.fail(error, gen: gen)
                    return
                }
                guard !chunk.lines.isEmpty else { break }
                offset = chunk.nextOffset
                let decoded = isSession ? chunk.lines.compactMap(decodeRecord) : []
                await self?.applyBackground(chunk, decoded, gen: gen)
            }
            guard !Task.isCancelled else { return }
            await self?.finishLoad(at: offset, gen: gen, began: began)
        }
    }

    /// A read failed: say so, keep what was read, and do not start (or keep) tailing.
    private func fail(_ error: Error, gen: Int) {
        guard gen == generation else { return }
        loadError = "Could not read the whole file: \(readableReason(error))"
        isLoading = false
        summary = .unavailable("Summary unavailable: the file could not be read in full")
        tailer?.stop()
        tailer = nil
        log.error("read failed: \(error.localizedDescription, privacy: .public)")
    }

    private func applyBackground(_ chunk: LineChunk, _ decoded: [JSONValue], gen: Int) {
        guard gen == generation else { return }
        if format == .claudeSession { ingest(decoded) } else { generic?.append(chunk) }
        publish()
    }

    private func finishLoad(at offset: UInt64, gen: Int, began: Date) {
        guard gen == generation else { return }
        isLoading = false
        refreshFacts()
        log.info("full load: \(self.items.count) items, \(self.outline.count) prompts, \(self.facts?.toolCallCount ?? 0) tool calls, \(self.subagents.count) subagents in \(Int(Date().timeIntervalSince(began) * 1000)) ms")
        requestSummary()
        let t = FileTailer(url: url, startOffset: offset) { [weak self] chunk in
            // Main queue, not a Task: keeps chunks in file order.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.applyTail(chunk, gen: gen) } }
        }
        tailer = t
        t.start()
    }

    private func applyTail(_ chunk: LineChunk, gen: Int) {
        guard gen == generation else { return }
        if chunk.lines.isEmpty && chunk.nextOffset == 0 {   // truncated or replaced
            start()
            return
        }
        if becomesSession(chunk) { return }
        switch format {
        case .claudeSession:
            ingest(chunk.lines.compactMap(decodeRecord))
            if session?.toolCalls.contains(where: { ($0.name == "Agent" || $0.name == "Task") && subagents[$0.id] == nil }) == true {
                subagents = SubagentIndex.load(for: url)
            }
            reloadChangedSubagents()
        case .generic:
            generic?.append(chunk)
        }
        publish()
        refreshFacts()
    }

    /// A file that was empty at open is shown as generic. When its first lines turn out to be a
    /// Claude session (a brand-new live session), switch to the session view.
    private func becomesSession(_ chunk: LineChunk) -> Bool {
        guard format == .generic, let g = generic, g.records.isEmpty, g.invalidCount == 0 else { return false }
        let decoded = chunk.lines.compactMap(decodeRecord)
        guard FormatDetector.detect(decoded) == .claudeSession else { return false }
        generic = nil
        records = []
        loadCount += 1
        format = .claudeSession
        session = SessionModel()
        ingest(decoded)
        subagents = SubagentIndex.load(for: url)
        publish()
        refreshFacts()
        requestSummary()
        return true
    }

    private func ingest(_ decoded: [JSONValue]) {
        session?.append(decoded)
        meta.absorb(decoded)
    }

    private func publish() {
        revision += 1
        if let session {
            items = session.items
            outline = session.outline
            if facts == nil { refreshFacts() }
        } else if let generic {
            records = generic.records
            invalidCount = generic.invalidCount
            genericLayout = generic.layout
        }
    }

    private func refreshFacts() {
        guard let session else { return }
        facts = SessionFacts.make(model: session, records: meta.records, fileURL: url)
    }

    // MARK: Summary

    private func requestSummary() {
        guard let key = CacheKey(fileURL: url, format: format) else {
            summary = .unavailable("Summary unavailable: file attributes could not be read")
            return
        }
        let digest: String
        if let session, let facts { digest = SummaryDigest.text(facts: facts, model: session) }
        else { digest = generic?.digest() ?? "" }
        summaryToken += 1
        let token = summaryToken
        summary = .generating
        summaryInFlight = true
        Task {
            let state = await Summaries.service.summary(for: key) { digest }
            if token == self.summaryToken { self.summary = state; self.summaryInFlight = false }
        }
    }

    // MARK: Siblings

    private func loadSiblings() {
        let dir = url.deletingLastPathComponent()
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        siblings = files.map { ($0, Self.titleCache[$0] ?? $0.deletingPathExtension().lastPathComponent) }
        let missing = files.filter { Self.titleCache[$0] == nil }
        guard !missing.isEmpty else { return }
        Task.detached(priority: .utility) { [weak self] in
            for f in missing {
                guard !Task.isCancelled else { return }
                let t = siblingTitle(f)
                await self?.setSiblingTitle(f, t)
            }
        }
    }

    private func setSiblingTitle(_ url: URL, _ title: String) {
        Self.titleCache[url] = title
        if let i = siblings.firstIndex(where: { $0.url == url }) { siblings[i].title = title }
    }

    // MARK: Subagents

    func loadSubagent(_ toolUseId: String) {
        guard subagentTranscripts[toolUseId] == nil, !subagentsInFlight.contains(toolUseId),
              let ref = subagents[toolUseId] else { return }
        subagentsInFlight.insert(toolUseId)
        Task.detached(priority: .userInitiated) { [weak self] in
            let t = SubagentTranscript.load(ref.fileURL)
            await self?.setTranscript(toolUseId, t)
        }
    }

    private func setTranscript(_ id: String, _ t: SubagentTranscript?) {
        subagentsInFlight.remove(id)
        if let t { subagentTranscripts[id] = t }
    }

    /// A live session's subagents keep writing after their row first loaded them, so on each
    /// parent update re-read any loaded transcript whose file size or date changed.
    private func reloadChangedSubagents() {
        let loaded = subagentTranscripts.compactMap { id, t -> (String, URL, SubagentTranscript)? in
            guard !subagentsInFlight.contains(id), let ref = subagents[id] else { return nil }
            return (id, ref.fileURL, t)
        }
        guard !loaded.isEmpty else { return }
        for (id, _, _) in loaded { subagentsInFlight.insert(id) }
        Task.detached(priority: .utility) { [weak self] in
            for (id, url, old) in loaded {
                let fresh = old.isStale(url) ? SubagentTranscript.load(url) : nil
                await self?.setTranscript(id, fresh)
            }
        }
    }
}
