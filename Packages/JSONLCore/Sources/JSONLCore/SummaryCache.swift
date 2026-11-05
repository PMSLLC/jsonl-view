import CryptoKit
import Foundation

public struct CacheKey: Hashable, Sendable {
    public let path: String
    public let size: UInt64
    public let mtime: Date
    public let format: FileFormat
    public let instructionsVersion: Int

    public init(path: String, size: UInt64, mtime: Date, format: FileFormat,
                instructionsVersion: Int = SummaryInstructions.version) {
        self.path = path
        self.size = size
        self.mtime = mtime
        self.format = format
        self.instructionsVersion = instructionsVersion
    }

    /// The key for the file as it is now, or nil when its attributes cannot be read. The path is
    /// standardized and symlinks are resolved, so `/tmp/x` and `/private/tmp/x` share a key.
    /// Both the app and the Quick Look extension build keys this way.
    public init?(fileURL: URL, format: FileFormat) {
        let standard = fileURL.standardizedFileURL.path
        let resolved = realpath(standard, nil).map { p in defer { free(p) }; return String(cString: p) } ?? standard
        guard let stamp = FileStamp(URL(fileURLWithPath: resolved)) else { return nil }
        self.init(path: resolved, size: stamp.size, mtime: stamp.mtime, format: format)
    }

    /// Stable across processes (the app and the Quick Look extension share the cache directory).
    var fileName: String {
        let material = "\(path)\n\(size)\n\(mtime.timeIntervalSince1970)\n\(format)\n\(instructionsVersion)"
        return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined() + ".json"
    }
}

/// One JSON file per key. Writes only inside its own directory; never touches viewed files.
public final class SummaryCache: Sendable {
    public static let appGroup = "997DW79YCR.com.brahy.jsonl-view"
    private struct Entry: Codable { let summary: String }
    private let directory: URL

    public init(directory: URL) { self.directory = directory }

    /// `<App Group container>/Summaries`, or nil when the process is not entitled (for example under `swift test`).
    public static func defaultDirectory() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("Summaries", isDirectory: true)
    }

    public func get(_ k: CacheKey) -> String? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(k.fileName)) else { return nil }
        return (try? JSONDecoder().decode(Entry.self, from: data))?.summary
    }

    public func put(_ k: CacheKey, _ s: String) {
        guard let data = try? JSONEncoder().encode(Entry(summary: s)) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent(k.fileName), options: .atomic)
    }
}
