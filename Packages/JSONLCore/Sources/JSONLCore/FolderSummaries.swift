import Foundation
import Observation
import os

private let log = Logger(subsystem: "com.brahy.jsonl-view", category: "folder-summaries")

/// "Summarizing `current` of `total`": `current` is 1-based, the file being worked on now.
public struct FolderProgress: Equatable, Sendable {
    public let current: Int
    public let total: Int
}

/// Summarizes the sibling `.jsonl` files of open windows in the background, so Quick Look
/// (which cannot run the model) finds their summaries in the shared cache.
///
/// App-wide and main-actor only. There is one queue per folder, shared by every window showing a
/// file in it. A queue works one file at a time in the order it was given, at background
/// priority, and stops when the last window on its folder closes or the model is unavailable.
/// A file that fails is skipped, and not retried this app session unless it changes.
///
/// Model calls are ordered app-wide: a queue starts no call while any window on its folder is
/// waiting for its own summary (up to `pendingTimeout`), and never while another queue's call,
/// including one left running by a cancelled queue, has not finished.
/// Reading and summarizing happen off the main actor; the only writes are `SummaryService`'s
/// cache writes.
@MainActor @Observable
public final class FolderSummaryCoordinator {
    /// Background reads are capped lower than Quick Look's (`PreviewLoader.fullReadLimit`).
    public static let fullReadLimit: UInt64 = 16 * 1_048_576
    public static let edgeBytes = 4 * 1_048_576

    private struct Queue {
        var task: Task<Void, Never>?
        var run = 0                       // which run `task` is (unique across the coordinator)
        var openFiles: Set<String> = []   // files shown in windows; their windows summarize them
        /// Open files whose window is still waiting for its own summary, and since when.
        var pendingOwn: [String: ContinuousClock.Instant] = [:]
        var progress: FolderProgress?
    }

    private enum Prepared: Sendable {
        case job(CacheKey, String)
        case skip([CacheKey])   // keys to remember as done for this session (may be empty)
    }

    @ObservationIgnored private let service: SummaryService
    @ObservationIgnored private let cache: SummaryCache
    @ObservationIgnored private let pendingTimeout: Duration
    private var queues: [String: Queue] = [:]
    @ObservationIgnored private var nextRun = 0
    /// Every run still alive per folder, including cancelled ones that have not exited yet.
    @ObservationIgnored private var runs: [String: [Int: Task<Void, Never>]] = [:]
    @ObservationIgnored private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    /// The model call a queue made last, while it runs. Outlives the queue if that is cancelled.
    @ObservationIgnored private var activeCall: Task<SummaryState, Never>?
    /// Keys that failed or were skipped this session; an edited file gets a new key and retries.
    @ObservationIgnored private var skipped: Set<CacheKey> = []

    public init(service: SummaryService, cache: SummaryCache, pendingTimeout: Duration = .seconds(60)) {
        self.service = service
        self.cache = cache
        self.pendingTimeout = pendingTimeout
    }

    /// Number of folders with a queue still running.
    public var queueCount: Int { queues.values.filter { $0.task != nil }.count }

    public func progress(for file: URL) -> FolderProgress? { queues[Self.folderKey(file)]?.progress }

    func runCount(folderOf file: URL) -> Int { runs[Self.folderKey(file)]?.count ?? 0 }
    func waiterCount(folderOf file: URL) -> Int { waiters[Self.folderKey(file)]?.count ?? 0 }

    /// A window now shows `file` and is waiting for its own summary. Starts its folder's queue
    /// over `siblings` (the sidebar's list, in its order) unless one is already running.
    public func open(_ file: URL, siblings: [URL]) {
        let folder = Self.folderKey(file), key = Self.fileKey(file)
        var q = queues[folder] ?? Queue()
        q.openFiles.insert(key)
        q.pendingOwn[key] = .now
        if q.task == nil {
            nextRun += 1
            let run = nextRun, files = siblings.filter { !q.openFiles.contains(Self.fileKey($0)) }
            let task = Task(priority: .background) { await self.run(folder, run, files) }
            q.task = task
            q.run = run
            runs[folder, default: [:]][run] = task
        }
        queues[folder] = q
    }

    /// The window showing `file` closed. When it was the last one on its folder, the queue is
    /// cancelled: a model call already running finishes (and may land in the cache), but no other
    /// file starts, and the next queue's first call waits for it.
    public func close(_ file: URL) {
        let folder = Self.folderKey(file), key = Self.fileKey(file)
        guard var q = queues[folder] else { return }
        q.openFiles.remove(key)
        q.pendingOwn[key] = nil
        if q.openFiles.isEmpty {
            q.task?.cancel()
            queues[folder] = nil
        } else {
            queues[folder] = q
        }
        wake(folder)
    }

    /// The window showing `file` is waiting (`true`) or no longer waiting for its own summary.
    /// `open` already marks it waiting.
    public func setSummaryPending(_ file: URL, _ pending: Bool) {
        let folder = Self.folderKey(file), key = Self.fileKey(file)
        guard queues[folder]?.openFiles.contains(key) == true else { return }
        queues[folder]?.pendingOwn[key] = pending ? .now : nil
        if !pending { wake(folder) }
    }

    /// Returns once every run of the folder's queue, including cancelled ones, has exited.
    public func finished(folderOf file: URL) async {
        let folder = Self.folderKey(file)
        while let task = runs[folder]?.values.first { await task.value }
    }

    private func run(_ folder: String, _ run: Int, _ siblings: [URL]) async {
        defer {
            runs[folder]?[run] = nil
            if runs[folder]?.isEmpty == true { runs[folder] = nil }
            if queues[folder]?.run == run {
                queues[folder]?.task = nil
                queues[folder]?.progress = nil
            }
        }
        let cache = cache
        let pending = await Self.notDone(siblings, cache: cache, skipped: skipped)
        for (i, url) in pending.enumerated() {
            guard !Task.isCancelled else { return }
            if queues[folder]?.run == run {
                queues[folder]?.progress = FolderProgress(current: i + 1, total: pending.count)
            }
            // A window may have opened this file since the queue started; it summarizes it.
            if queues[folder]?.openFiles.contains(Self.fileKey(url)) == true { continue }
            let job: (key: CacheKey, digest: String)
            switch await Self.prepare(url, cache: cache, skipped: skipped) {
            case .skip(let keys):
                skipped.formUnion(keys)
                continue
            case .job(let key, let digest):
                job = (key, digest)
            }
            guard await waitForTurn(folder) else { return }
            let service = service, name = url.lastPathComponent
            log.info("folder summary start \(name, privacy: .public)")
            let call = Task {
                let state = await service.summary(for: job.key, digest: { job.digest })
                log.info("folder summary end \(name, privacy: .public)")
                return state
            }
            activeCall = call
            let state = await call.value
            if activeCall == call { activeCall = nil }
            switch state {
            case .unavailable(let reason):
                log.info("folder summaries stopped: \(reason, privacy: .public)")
                return
            case .failed(let reason):
                skipped.insert(job.key)
                log.info("folder summaries skipped \(url.lastPathComponent, privacy: .public): \(reason, privacy: .public)")
            case .ready, .generating:
                break
            }
        }
    }

    /// Waits until no queue's model call is running and no window on `folder` is waiting for its
    /// own summary. Returns with no suspension after the last check, so the caller's call starts
    /// before anything else can. False once cancelled.
    private func waitForTurn(_ folder: String) async -> Bool {
        while !Task.isCancelled {
            if let prior = activeCall {
                _ = await prior.value
                if activeCall == prior { activeCall = nil }
            } else if let deadline = pendingDeadline(folder) {
                await waitForWake(folder, until: deadline)
            } else {
                return true
            }
        }
        return false
    }

    /// The earliest time a pending window on `folder` times out, or nil when none is pending.
    /// Windows already past `pendingTimeout` are dropped with a log line.
    private func pendingDeadline(_ folder: String) -> ContinuousClock.Instant? {
        guard let pending = queues[folder]?.pendingOwn, !pending.isEmpty else { return nil }
        let now = ContinuousClock.now
        for (file, since) in pending where since + pendingTimeout <= now {
            log.info("folder summaries stopped waiting for \((file as NSString).lastPathComponent, privacy: .public)")
            queues[folder]?.pendingOwn[file] = nil
        }
        return queues[folder]?.pendingOwn.values.map { $0 + pendingTimeout }.min()
    }

    /// Suspends until `wake(folder)` or `deadline`, whichever comes first.
    private func waitForWake(_ folder: String, until deadline: ContinuousClock.Instant) async {
        let timer = Task { [weak self] in
            do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
            self?.wake(folder)
        }
        await withCheckedContinuation { waiters[folder, default: []].append($0) }
        timer.cancel()
    }

    private func wake(_ folder: String) {
        guard let list = waiters.removeValue(forKey: folder) else { return }
        for c in list { c.resume() }
    }

    /// Files with no cached summary under their current key, in either format, and not skipped
    /// this session. Checking both formats avoids reading the file just to learn its format.
    @concurrent
    nonisolated static func notDone(_ files: [URL], cache: SummaryCache, skipped: Set<CacheKey>) async -> [URL] {
        files.filter { !isDone($0, cache: cache, skipped: skipped) }
    }

    nonisolated static func isDone(_ url: URL, cache: SummaryCache, skipped: Set<CacheKey>) -> Bool {
        keys(url).contains { skipped.contains($0) || cache.get($0) != nil }
    }

    nonisolated static func keys(_ url: URL) -> [CacheKey] {
        [FileFormat.claudeSession, .generic].compactMap { CacheKey(fileURL: url, format: $0) }
    }

    /// Reads `url` with `PreviewLoader` (in full up to `fullReadLimit`, head and tail above it)
    /// and returns the key and digest to summarize. The key is taken when the file is processed,
    /// and the file is skipped if it changed while it was read, so a summary is never stored
    /// under a key that does not match what was read.
    @concurrent
    nonisolated private static func prepare(_ url: URL, cache: SummaryCache, skipped: Set<CacheKey>) async -> Prepared {
        if isDone(url, cache: cache, skipped: skipped) { return .skip([]) }
        guard let before = FileStamp(url) else { return .skip([]) }
        let snapshot: PreviewSnapshot
        do {
            snapshot = try await PreviewLoader.load(url, fullReadLimit: fullReadLimit, edgeBytes: edgeBytes)
        } catch is CancellationError {
            return .skip([])
        } catch {
            log.info("folder summaries skipped \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return .skip(keys(url))
        }
        let format: FileFormat
        if case .session = snapshot.content { format = .claudeSession } else { format = .generic }
        guard let key = CacheKey(fileURL: url, format: format),
              key.size == before.size, key.mtime == before.mtime else {
            // Its key has changed, so nothing is remembered: the next open tries it again.
            log.info("folder summaries skipped \(url.lastPathComponent, privacy: .public): changed while read")
            return .skip([])
        }
        return .job(key, snapshot.digest)
    }

    nonisolated static func fileKey(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }
    nonisolated static func folderKey(_ file: URL) -> String {
        file.standardizedFileURL.resolvingSymlinksInPath().deletingLastPathComponent().path
    }
}
