import Foundation
import Testing
@testable import JSONLCore

/// Records how many summaries run at once and in what order, with an optional delay and failure.
private actor Probe {
    var active = 0, maxActive = 0, calls = 0
    var digests: [String] = []
    func begin(_ d: String) { active += 1; calls += 1; maxActive = max(maxActive, active); digests.append(d) }
    func end() { active -= 1 }
}

private struct ProbeSummarizer: Summarizing {
    let probe = Probe()
    var delay: Duration = .milliseconds(20)
    var unavailable: String? = nil
    var failOn: String? = nil   // digests containing this fail as a per-file error
    func summarize(_ digest: String, format: FileFormat) async throws -> String {
        await probe.begin(digest)
        try? await Task.sleep(for: delay)
        await probe.end()
        if let unavailable { throw SummaryUnavailable(reason: unavailable) }
        if let failOn, digest.contains(failOn) { throw NSError(domain: "t", code: 1) }
        return "sum"
    }
}

/// A temp folder of small synthetic session files named a.jsonl, b.jsonl, ...
private func makeFolder(_ names: [String]) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("folder-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for n in names {
        let line = #"{"type":"user","sessionId":"s","timestamp":"2026-01-01T10:00:00.000Z","message":{"role":"user","content":"prompt \#(n)"}}"#
        try Data((line + "\n").utf8).write(to: dir.appendingPathComponent(n + ".jsonl"))
    }
    return dir
}

private func files(_ dir: URL, _ names: [String]) -> [URL] { names.map { dir.appendingPathComponent($0 + ".jsonl") } }

private func cacheDir() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("fcache-" + UUID().uuidString)
}

@MainActor
private func coordinator(_ s: ProbeSummarizer, cache: SummaryCache,
                         pendingTimeout: Duration = .seconds(60)) -> FolderSummaryCoordinator {
    FolderSummaryCoordinator(service: SummaryService(summarizer: s, cache: cache), cache: cache,
                             pendingTimeout: pendingTimeout)
}

/// Polls until `cond` holds or about ten seconds pass (the queue runs at background priority).
@MainActor private func eventually(_ cond: @MainActor () async -> Bool) async {
    for _ in 0..<1_000 where !(await cond()) { try? await Task.sleep(for: .milliseconds(10)) }
}

@MainActor @Suite struct FolderSummaryTests {
    @Test func queuesOnlyUncachedSiblings() async throws {
        let names = ["a", "b", "c", "d"]
        let dir = try makeFolder(names)
        let all = files(dir, names)
        let cache = SummaryCache(directory: cacheDir())
        cache.put(try #require(CacheKey(fileURL: all[1], format: .claudeSession)), "old")
        let s = ProbeSummarizer()
        let c = coordinator(s, cache: cache)
        c.open(all[0], siblings: all)   // a is the window's own file, b is cached
        c.setSummaryPending(all[0], false)
        await c.finished(folderOf: all[0])
        #expect(await s.probe.calls == 2)
        let digests = await s.probe.digests
        #expect(digests.count == 2 && digests[0].contains("prompt c") && digests[1].contains("prompt d"))
        for f in all[1...] { #expect(cache.get(try #require(CacheKey(fileURL: f, format: .claudeSession))) != nil) }
        #expect(cache.get(try #require(CacheKey(fileURL: all[0], format: .claudeSession))) == nil)
        #expect(c.progress(for: all[0]) == nil)
    }

    @Test func processesSequentially() async throws {
        let names = ["a", "b", "c", "d", "e"]
        let dir = try makeFolder(names)
        let all = files(dir, names)
        let s = ProbeSummarizer(delay: .milliseconds(50))
        let c = coordinator(s, cache: SummaryCache(directory: cacheDir()))
        c.open(all[0], siblings: all)
        c.setSummaryPending(all[0], false)
        await eventually { c.progress(for: all[0]) != nil }
        #expect(c.progress(for: all[0])?.total == 4)
        await c.finished(folderOf: all[0])
        #expect(await s.probe.calls == 4)
        #expect(await s.probe.maxActive == 1)
        let order = await s.probe.digests.map { d in names.firstIndex { d.contains("prompt \($0)") } ?? -1 }
        #expect(order == [1, 2, 3, 4])
    }

    @Test func stopsOnCancel() async throws {
        let names = ["a", "b", "c", "d"]
        let dir = try makeFolder(names)
        let all = files(dir, names)
        let cache = SummaryCache(directory: cacheDir())
        let s = ProbeSummarizer(delay: .milliseconds(200))
        let c = coordinator(s, cache: cache)
        c.open(all[0], siblings: all)
        c.setSummaryPending(all[0], false)
        await eventually { await s.probe.calls == 1 }
        c.close(all[0])
        await c.finished(folderOf: all[0])   // includes the cancelled run, which has now exited
        #expect(await s.probe.calls == 1)
        #expect(c.progress(for: all[0]) == nil)
        #expect(cache.get(try #require(CacheKey(fileURL: all[3], format: .claudeSession))) == nil)
    }

    @Test func stopsAfterUnavailable() async throws {
        let names = ["a", "b", "c", "d"]
        let dir = try makeFolder(names)
        let all = files(dir, names)
        let s = ProbeSummarizer(unavailable: "Apple Intelligence is off")
        let c = coordinator(s, cache: SummaryCache(directory: cacheDir()))
        c.open(all[0], siblings: all)
        c.setSummaryPending(all[0], false)
        await c.finished(folderOf: all[0])
        #expect(await s.probe.calls == 1)
        #expect(c.progress(for: all[0]) == nil)
    }

    @Test func oneQueuePerFolder() async throws {
        let names = ["a", "b", "c", "d"]
        let dir = try makeFolder(names)
        let all = files(dir, names)
        let s = ProbeSummarizer(delay: .milliseconds(50))
        let c = coordinator(s, cache: SummaryCache(directory: cacheDir()))
        c.open(all[0], siblings: all)
        c.open(all[1], siblings: all)
        c.setSummaryPending(all[0], false)
        c.setSummaryPending(all[1], false)
        #expect(c.queueCount == 1)
        c.close(all[0])   // another window still shows this folder, so the queue keeps going
        await c.finished(folderOf: all[1])
        // b was open in a window when the queue reached it, so only c and d were summarized.
        #expect(await s.probe.calls == 2)
        #expect(await s.probe.maxActive == 1)
        #expect(c.queueCount == 0)
    }

    @Test func continuesAfterPerFileError() async throws {
        let names = ["a", "b", "c", "d"]
        let dir = try makeFolder(names)
        let all = files(dir, names)
        let cache = SummaryCache(directory: cacheDir())
        let s = ProbeSummarizer(failOn: "prompt b")
        let c = coordinator(s, cache: cache)
        c.open(all[0], siblings: all)
        c.setSummaryPending(all[0], false)
        await c.finished(folderOf: all[0])
        #expect(await s.probe.calls == 3)
        #expect(cache.get(try #require(CacheKey(fileURL: all[1], format: .claudeSession))) == nil)
        for f in all[2...] { #expect(cache.get(try #require(CacheKey(fileURL: f, format: .claudeSession))) != nil) }
    }

    @Test func waitsForOpenWindowSummary() async throws {
        let names = ["a", "b", "c"]
        let dir = try makeFolder(names)
        let all = files(dir, names)
        let s = ProbeSummarizer()
        let c = coordinator(s, cache: SummaryCache(directory: cacheDir()))
        c.open(all[0], siblings: all)   // the window's own summary is pending from open
        await eventually { c.waiterCount(folderOf: all[0]) == 1 }
        #expect(c.waiterCount(folderOf: all[0]) == 1)
        #expect(await s.probe.calls == 0)
        c.setSummaryPending(all[0], false)
        await eventually { await s.probe.calls == 1 }
        c.setSummaryPending(all[0], true)   // the window asks again (reload): siblings wait again
        await eventually { c.waiterCount(folderOf: all[0]) == 1 }
        #expect(c.waiterCount(folderOf: all[0]) == 1)
        #expect(await s.probe.calls == 1)
        c.setSummaryPending(all[0], false)
        await c.finished(folderOf: all[0])
        #expect(await s.probe.calls == 2)
    }

    @Test func proceedsAfterPendingTimeout() async throws {
        let names = ["a", "b", "c"]
        let dir = try makeFolder(names)
        let all = files(dir, names)
        let s = ProbeSummarizer()
        let c = coordinator(s, cache: SummaryCache(directory: cacheDir()), pendingTimeout: .milliseconds(200))
        c.open(all[0], siblings: all)   // the window never reports its summary
        await c.finished(folderOf: all[0])
        #expect(await s.probe.calls == 2)
    }

    @Test func reopenAfterCloseKeepsOneRun() async throws {
        let names = ["a", "b", "c", "d", "e"]
        let dir = try makeFolder(names)
        let all = files(dir, names)
        let s = ProbeSummarizer(delay: .milliseconds(100))
        let c = coordinator(s, cache: SummaryCache(directory: cacheDir()))
        c.open(all[0], siblings: all)
        c.setSummaryPending(all[0], false)
        await eventually { await s.probe.calls == 1 }   // the first run is summarizing b
        c.close(all[0])                                // sidebar: open a sibling, close the old window
        c.open(all[1], siblings: all)
        c.setSummaryPending(all[1], false)
        await eventually { c.runCount(folderOf: all[1]) == 1 }   // the cancelled run has exited
        c.open(all[2], siblings: all)
        c.setSummaryPending(all[2], false)
        #expect(c.runCount(folderOf: all[1]) == 1)
        #expect(c.progress(for: all[1]) != nil)
        await c.finished(folderOf: all[1])
        #expect(await s.probe.maxActive == 1)
        #expect(await s.probe.calls == 4)   // b (first run), then a, d, e; c is open in a window
        #expect(c.progress(for: all[1]) == nil)
    }

    @Test func doesNotRetryFailedFileUntilItChanges() async throws {
        let names = ["a", "b", "c"]
        let dir = try makeFolder(names)
        let all = files(dir, names)
        let s = ProbeSummarizer(failOn: "prompt b")
        let c = coordinator(s, cache: SummaryCache(directory: cacheDir()))
        c.open(all[0], siblings: all)
        c.setSummaryPending(all[0], false)
        await c.finished(folderOf: all[0])
        #expect(await s.probe.calls == 2)
        c.close(all[0])
        c.open(all[0], siblings: all)
        c.setSummaryPending(all[0], false)
        await c.finished(folderOf: all[0])
        #expect(await s.probe.calls == 2)   // b failed this session and has not changed
        let h = try FileHandle(forWritingTo: all[1])
        try h.seekToEnd(); try h.write(contentsOf: Data("{}\n".utf8)); try h.close()
        c.close(all[0])
        c.open(all[0], siblings: all)
        c.setSummaryPending(all[0], false)
        await c.finished(folderOf: all[0])
        #expect(await s.probe.calls == 3)   // edited, so it gets a new key and is tried again
    }

    @Test func backgroundReadsUseSmallerCap() {
        #expect(FolderSummaryCoordinator.fullReadLimit == 16 * 1_048_576)
        #expect(FolderSummaryCoordinator.edgeBytes == 4 * 1_048_576)
        #expect(PreviewLoader.fullReadLimit == 64 * 1_048_576)
    }
}
