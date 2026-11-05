import Foundation

public struct LineChunk: Sendable {
    public let lines: [Data]
    public let nextOffset: UInt64
}

public struct LineReader {
    static let blockSize = 1_048_576

    /// Reads newline-terminated lines starting at `offset`. A trailing partial
    /// line is not consumed: `nextOffset` stops before it. Lines are returned
    /// undecoded; consumers count invalid lines via `decodeRecord` returning nil.
    ///
    /// When `maxBytes` is set, reading stops before the line that would push
    /// the consumed bytes (newlines included) past it. The first line is always
    /// returned, even if it is larger than `maxBytes`, so reading always makes
    /// progress.
    ///
    /// Scanning is linear in the bytes read: each block is searched once, so a
    /// single very long line does not cost quadratic time.
    public static func read(fileAt url: URL, from offset: UInt64, maxBytes: Int? = nil) throws -> LineChunk {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)

        var lines: [Data] = []
        var consumed = 0
        var pending = Data()   // always zero-based; bytes from `lineStart` on are unconsumed
        var lineStart = 0
        var scanPos = 0        // everything before this has been searched for a newline
        var done = false

        while !done {
            guard let block = try handle.read(upToCount: blockSize), !block.isEmpty else { break }
            pending.append(block)
            while let nl = pending[scanPos...].firstIndex(of: 0x0A) {
                let lineBytes = nl - lineStart + 1
                if let maxBytes, !lines.isEmpty, consumed + lineBytes > maxBytes {
                    done = true
                    break
                }
                var end = nl
                if end > lineStart, pending[end - 1] == 0x0D { end -= 1 }
                lines.append(pending.subdata(in: lineStart..<end))
                consumed += lineBytes
                lineStart = nl + 1
                scanPos = lineStart
            }
            if done { break }
            scanPos = pending.count
            if lineStart > 0 {
                pending.removeSubrange(0..<lineStart)
                scanPos -= lineStart
                lineStart = 0
            }
            if let maxBytes, consumed >= maxBytes { done = true }
        }
        return LineChunk(lines: lines, nextOffset: offset + UInt64(consumed))
    }
}
