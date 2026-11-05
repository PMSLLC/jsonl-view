import Foundation
import Synchronization

/// What the Quick Look preview shows before the summary: facts plus the digest to summarize.
public struct PreviewSnapshot: Sendable {
    public enum Content: Sendable {
        case session(SessionFacts)
        case generic(GenericFacts)
    }
    public let content: Content
    /// True when only the first and last `edgeBytes` of the file were read.
    public let approximate: Bool
    public let fileBytes: UInt64
    public let digest: String
}

public enum PreviewLoader {
    public static let fullReadLimit: UInt64 = 64 * 1_048_576
    public static let edgeBytes = 8 * 1_048_576

    /// Lines handed to `GenericModel` (or decoded by one concurrent slice) between cancellation checks.
    static let linesPerStep = 2_048

    /// Reads the file (in full up to `fullReadLimit`, else its first and last `edgeBytes`)
    /// and builds the preview facts. Runs off the caller's actor and throws `CancellationError`
    /// soon after the calling task is cancelled: it checks between stages and per decode slice.
    @concurrent
    public static func load(_ url: URL, fullReadLimit: UInt64 = fullReadLimit, edgeBytes: Int = edgeBytes) async throws -> PreviewSnapshot {
        try Task.checkCancellation()
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64 ?? 0
        let approximate = size > fullReadLimit
        let lines: [Data]
        if approximate {
            let head = try LineReader.read(fileAt: url, from: 0, maxBytes: edgeBytes)
            let tail = try tailLines(url, size: size, edgeBytes: edgeBytes, after: head.nextOffset)
            lines = head.lines + tail
        } else {
            lines = try LineReader.read(fileAt: url, from: 0).lines
        }
        try Task.checkCancellation()

        // Detect from the leading records only, so each line is decoded once on either path
        // (GenericModel decodes the lines it is given, since it also needs their raw key order).
        var probe: [JSONValue] = [], probed = 0
        while probe.count < FormatDetector.probeCount, probed < lines.count {
            if let r = decodeRecord(lines[probed]) { probe.append(r) }
            probed += 1
        }
        switch FormatDetector.detect(probe) {
        case .claudeSession:
            let records = probe + (try await decodeConcurrently(Array(lines[probed...])))
            try Task.checkCancellation()
            let model = SessionModel()
            model.append(records)
            var facts = SessionFacts.make(model: model, records: records, fileURL: url)
            facts.approximate = approximate
            return PreviewSnapshot(content: .session(facts), approximate: approximate, fileBytes: size,
                                   digest: SummaryDigest.text(facts: facts, model: model))
        case .generic:
            let model = GenericModel()
            for start in stride(from: 0, to: lines.count, by: linesPerStep) {
                try Task.checkCancellation()
                model.append(LineChunk(lines: Array(lines[start..<min(start + linesPerStep, lines.count)]), nextOffset: 0))
            }
            return PreviewSnapshot(content: .generic(model.facts()), approximate: approximate,
                                   fileBytes: size, digest: model.digest())
        }
    }

    /// `decodeRecord` over all lines, split across cores; invalid lines are dropped, order is kept.
    /// Slices of `linesPerStep` lines each check a flag set by the task's cancellation handler,
    /// since `concurrentPerform` threads cannot see the task.
    static func decodeConcurrently(_ lines: [Data]) async throws -> [JSONValue] {
        let slices = max(1, (lines.count + linesPerStep - 1) / linesPerStep)
        let per = (lines.count + slices - 1) / slices
        let cancelled = CancelFlag()
        let parts = await withTaskCancellationHandler {
            var parts = [[JSONValue]](repeating: [], count: slices)
            parts.withUnsafeMutableBufferPointer { out in
                nonisolated(unsafe) let out = out
                DispatchQueue.concurrentPerform(iterations: slices) { i in
                    guard !cancelled.isSet else { return }
                    let lo = i * per, hi = min(lo + per, lines.count)
                    if lo < hi { out[i] = lines[lo..<hi].compactMap(decodeRecord) }
                }
            }
            return parts
        } onCancel: {
            cancelled.set()
        }
        try Task.checkCancellation()
        return parts.flatMap { $0 }
    }

    /// Complete lines in the last `edgeBytes` of the file. The read starts at `size - edgeBytes`
    /// and skips to just after the first newline, so a partial line is never decoded. Nothing
    /// before `after` (already read as the head) is returned twice.
    static func tailLines(_ url: URL, size: UInt64, edgeBytes: Int, after headEnd: UInt64) throws -> [Data] {
        let start = max(size > UInt64(edgeBytes) ? size - UInt64(edgeBytes) : 0, headEnd)
        guard start < size else { return [] }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var offset = start
        if start > 0 {
            // The byte before `start` tells whether `start` already begins a line.
            try handle.seek(toOffset: start - 1)
            var pos = start - 1
            var found = false
            while !found, let block = try handle.read(upToCount: 65_536), !block.isEmpty {
                if let nl = block.firstIndex(of: 0x0A) {
                    offset = pos + UInt64(nl - block.startIndex) + 1
                    found = true
                } else {
                    pos += UInt64(block.count)
                }
            }
            guard found else { return [] }
        }
        return try LineReader.read(fileAt: url, from: offset).lines
    }
}

private final class CancelFlag: Sendable {
    private let value = Atomic<Bool>(false)
    var isSet: Bool { value.load(ordering: .relaxed) }
    func set() { value.store(true, ordering: .relaxed) }
}
