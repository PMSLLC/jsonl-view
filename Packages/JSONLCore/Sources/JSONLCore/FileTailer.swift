import Foundation

/// Watches a file that is still being appended to and delivers new
/// newline-terminated lines. Read-only: the file is opened with `O_EVTONLY`.
///
/// `onLines` is called on a private serial queue, never the main actor.
/// An empty chunk with `nextOffset == 0` means "reload from scratch": the file
/// was truncated or atomically replaced, and any lines that follow are the new
/// content from the start.
// @unchecked Sendable: all mutable state (`source`, `offset`, `generation`,
// `stopped`) is read and written only on `queue`.
public final class FileTailer: @unchecked Sendable {
    private static let retryCount = 10
    private static let retryInterval: DispatchTimeInterval = .milliseconds(100)

    private let url: URL
    private let onLines: @Sendable (LineChunk) -> Void
    private let queue = DispatchQueue(label: "jsonl-view.FileTailer")
    private let queueKey = DispatchSpecificKey<Void>()

    private var offset: UInt64
    private var source: DispatchSourceFileSystemObject?
    private var generation = 0
    private var stopped = false

    public init(url: URL, startOffset: UInt64, onLines: @escaping @Sendable (LineChunk) -> Void) {
        self.url = url
        self.offset = startOffset
        self.onLines = onLines
        queue.setSpecific(key: queueKey, value: ())
    }

    deinit { stop() }

    /// Begins watching, and delivers anything already past `startOffset`.
    public func start() {
        onQueue {
            guard !stopped, source == nil, install() else { return }
            poll()
        }
    }

    /// Stops watching. Idempotent. After it returns, `onLines` is not called again.
    public func stop() {
        onQueue {
            stopped = true
            generation += 1
            source?.cancel()
            source = nil
        }
    }

    private func onQueue(_ body: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil { body() } else { queue.sync(execute: body) }
    }

    /// Opens the path and installs a watch. Returns false if the file is not there.
    private func install() -> Bool {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return false }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .attrib, .delete, .rename], queue: queue)
        let gen = generation
        src.setEventHandler { [weak self, weak src] in
            guard let self, let src, gen == self.generation else { return }
            if src.data.contains(.delete) || src.data.contains(.rename) {
                self.handleReplace()
            } else {
                self.poll()
            }
        }
        src.setCancelHandler { close(fd) }
        source = src
        src.resume()
        return true
    }

    /// Reads from the stored offset, signalling a reload first if the file shrank.
    private func poll() {
        if let size = fileSize(), size < offset {
            offset = 0
            onLines(LineChunk(lines: [], nextOffset: 0))
        }
        // A failed read (try?) leaves the offset unchanged, so the next event retries it.
        guard let chunk = try? LineReader.read(fileAt: url, from: offset), !chunk.lines.isEmpty else { return }
        offset = chunk.nextOffset
        onLines(chunk)
    }

    private func fileSize() -> UInt64? {
        guard let n = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber else { return nil }
        return n.uint64Value
    }

    /// The watched inode went away (atomic replace). Retry the path for about 1 s.
    private func handleReplace() {
        source?.cancel()
        source = nil
        generation += 1
        retryReopen(remaining: Self.retryCount, generation: generation)
    }

    private func retryReopen(remaining: Int, generation gen: Int) {
        guard !stopped, gen == generation else { return }
        if install() {
            offset = 0
            onLines(LineChunk(lines: [], nextOffset: 0))
            poll()
            return
        }
        guard remaining > 1 else { return }   // gone: stay stopped
        queue.asyncAfter(deadline: .now() + Self.retryInterval) { [weak self] in
            self?.retryReopen(remaining: remaining - 1, generation: gen)
        }
    }
}
