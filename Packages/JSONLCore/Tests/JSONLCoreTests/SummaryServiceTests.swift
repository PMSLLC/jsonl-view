import Foundation
import Testing
@testable import JSONLCore
import JSONLSummarizer

private actor Counter {
    var n = 0
    func bump() { n += 1 }
}

private actor FormatLog {
    var seen: [FileFormat] = []
    func add(_ f: FileFormat) { seen.append(f) }
}

private struct FakeSummarizer: Summarizing {
    let counter = Counter()
    let formats = FormatLog()
    var delay: Duration = .zero
    var fail: String? = nil
    func summarize(_ digest: String, format: FileFormat) async throws -> String {
        await counter.bump()
        await formats.add(format)
        if delay > .zero { try await Task.sleep(for: delay) }
        if let fail { throw NSError(domain: "t", code: 1, userInfo: [NSLocalizedDescriptionKey: fail]) }
        return "sum:" + digest
    }
}

private func tempDir() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("summ-" + UUID().uuidString)
}

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

@Suite struct SummaryServiceTests {
    @Test func cachesResult() async {
        let fake = FakeSummarizer()
        let svc = SummaryService(summarizer: fake, cache: SummaryCache(directory: tempDir()))
        let k = CacheKey(path: "/a.jsonl", size: 10, mtime: t0, format: .claudeSession)
        let a = await svc.summary(for: k) { "d" }
        let b = await svc.summary(for: k) { "d" }
        #expect(a == .ready("sum:d"))
        #expect(b == .ready("sum:d"))
        #expect(await fake.counter.n == 1)
    }

    @Test func cacheSurvivesNewInstanceSameDirectory() {
        let dir = tempDir()
        let k = CacheKey(path: "/a.jsonl", size: 10, mtime: t0, format: .claudeSession)
        SummaryCache(directory: dir).put(k, "hello")
        #expect(SummaryCache(directory: dir).get(k) == "hello")
    }

    @Test func cacheKeyChangesWithMtime() {
        let dir = tempDir()
        let cache = SummaryCache(directory: dir)
        let k1 = CacheKey(path: "/a.jsonl", size: 10, mtime: t0, format: .claudeSession)
        let k2 = CacheKey(path: "/a.jsonl", size: 10, mtime: t0.addingTimeInterval(1), format: .claudeSession)
        cache.put(k1, "one")
        #expect(cache.get(k2) == nil)
        #expect(k1.fileName != k2.fileName)
        #expect(CacheKey(path: "/a.jsonl", size: 11, mtime: t0, format: .claudeSession).fileName != k1.fileName)
    }

    @Test func fileNameIsStableSHA256() {
        let k = CacheKey(path: "/a.jsonl", size: 10, mtime: t0, format: .claudeSession)
        #expect(k.fileName == k.fileName)
        #expect(k.fileName.count == 64 + ".json".count)
        #expect(k.fileName.hasSuffix(".json"))
    }

    @Test func otherErrorIsPerFileFailure() async {
        let svc = SummaryService(summarizer: FakeSummarizer(fail: "boom"), cache: SummaryCache(directory: tempDir()))
        let s = await svc.summary(for: CacheKey(path: "/a", size: 1, mtime: t0, format: .claudeSession)) { "d" }
        #expect(s == .failed("Summary unavailable: boom"))
    }

    @Test func failureIsNotCached() async {
        let fake = FakeSummarizer(fail: "boom")
        let svc = SummaryService(summarizer: fake, cache: SummaryCache(directory: tempDir()))
        let k = CacheKey(path: "/a", size: 1, mtime: t0, format: .claudeSession)
        _ = await svc.summary(for: k) { "d" }
        _ = await svc.summary(for: k) { "d" }
        #expect(await fake.counter.n == 2)
    }

    @Test func modelUnavailableErrorKeepsItsPhrase() async {
        struct Off: Summarizing {
            func summarize(_ digest: String, format: FileFormat) async throws -> String { throw SummaryUnavailable(reason: "Apple Intelligence is off") }
        }
        let svc = SummaryService(summarizer: Off(), cache: SummaryCache(directory: tempDir()))
        let s = await svc.summary(for: CacheKey(path: "/a", size: 1, mtime: t0, format: .claudeSession)) { "d" }
        #expect(s == .unavailable("Apple Intelligence is off"))
    }

    @Test func concurrentRequestsCoalesce() async {
        let fake = FakeSummarizer(delay: .milliseconds(200))
        let svc = SummaryService(summarizer: fake, cache: SummaryCache(directory: tempDir()))
        let k = CacheKey(path: "/a", size: 1, mtime: t0, format: .claudeSession)
        let results = await withTaskGroup(of: SummaryState.self) { g in
            for _ in 0..<5 { g.addTask { await svc.summary(for: k) { "d" } } }
            return await g.reduce(into: []) { $0.append($1) }
        }
        #expect(results.count == 5)
        #expect(results.allSatisfy { $0 == .ready("sum:d") })
        #expect(await fake.counter.n == 1)
    }

    @Test func summarizerReceivesKeyFormat() async {
        let fake = FakeSummarizer()
        let svc = SummaryService(summarizer: fake, cache: SummaryCache(directory: tempDir()))
        _ = await svc.summary(for: CacheKey(path: "/g.jsonl", size: 1, mtime: t0, format: .generic)) { "d" }
        _ = await svc.summary(for: CacheKey(path: "/s.jsonl", size: 1, mtime: t0, format: .claudeSession)) { "d" }
        #expect(await fake.formats.seen == [.generic, .claudeSession])
    }

    @Test func cacheKeyIncludesFormatAndInstructionsVersion() {
        let base = CacheKey(path: "/a.jsonl", size: 10, mtime: t0, format: .claudeSession)
        #expect(base.instructionsVersion == SummaryInstructions.version)
        #expect(CacheKey(path: "/a.jsonl", size: 10, mtime: t0, format: .generic).fileName != base.fileName)
        let older = CacheKey(path: "/a.jsonl", size: 10, mtime: t0, format: .claudeSession,
                             instructionsVersion: SummaryInstructions.version - 1)
        #expect(older.fileName != base.fileName)
    }

    @Test func perFormatInstructions() {
        #expect(SummaryInstructions.text(for: .generic) == "Summarize this JSONL data file for its owner in 2 to 3 plain sentences: what the records are and anything notable. No em dashes.")
        #expect(SummaryInstructions.text(for: .claudeSession).contains("Claude Code session"))
        #expect(SummaryInstructions.text(for: .claudeSession).contains("Outcome: done"))
    }

    @Test func cacheKeyFromURLResolvesSymlinks() throws {
        let name = "cachekey-\(UUID().uuidString).jsonl"
        let real = URL(fileURLWithPath: "/private/tmp/\(name)")
        try Data("{}\n".utf8).write(to: real)
        defer { try? FileManager.default.removeItem(at: real) }
        let a = try #require(CacheKey(fileURL: URL(fileURLWithPath: "/tmp/\(name)"), format: .generic))
        let b = try #require(CacheKey(fileURL: real, format: .generic))
        let c = try #require(CacheKey(fileURL: URL(fileURLWithPath: "/tmp/./x/../\(name)"), format: .generic))
        #expect(a == b)
        #expect(a == c)
        #expect(a.fileName == b.fileName)
        #expect(a.size == 3)
        #expect(CacheKey(fileURL: URL(fileURLWithPath: "/tmp/missing-\(UUID().uuidString)"), format: .generic) == nil)
    }

    @Test func defaultDirectoryIsSummariesInGroupContainerOrNil() {
        // Unsandboxed macOS processes may get a path; sandboxed-without-entitlement ones get nil.
        if let dir = SummaryCache.defaultDirectory() {
            #expect(dir.lastPathComponent == "Summaries")
            #expect(dir.path.contains(SummaryCache.appGroup))
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["JSONLVIEW_FM_SMOKE"] == "1"))
    func foundationModelsSmoke() async throws {
        let digest = """
        Title: Fix login bug
        Prompts:
        - The login form crashes when the password is empty. Please fix it.
        Last replies:
        - I added an empty-password check in LoginForm.swift and a test; all tests pass.
        Edited files: LoginForm.swift, LoginFormTests.swift
        """
        do {
            let out = try await FoundationModelsSummarizer().summarize(digest, format: .claudeSession)
            print("FM_SMOKE_RESULT: \(out)")
        } catch let e as SummaryUnavailable {
            print("FM_SMOKE_UNAVAILABLE: \(e.reason)")
        }
    }
}
