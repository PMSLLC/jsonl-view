import Cocoa
import JSONLCore
import Quartz
import SwiftUI

final class PreviewViewController: NSViewController, QLPreviewingController {
    private let state = PreviewState()
    private var loadTask: Task<Void, Never>?

    override func loadView() {
        view = NSHostingView(rootView: PreviewView(state: state))
        preferredContentSize = NSSize(width: 640, height: 600)
    }

    /// Returns at once with a header built from the file name, folder and size. `loadTask` then
    /// looks up the cached summary and reads the facts.
    func preparePreviewOfFile(at url: URL) async throws {
        loadTask?.cancel()
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        state.url = url
        state.fileBytes = size
        state.snapshot = nil
        state.loadError = nil
        state.summary = .missing
        // A child of `loadTask`, not a detached task, so cancelling `loadTask` stops the parse.
        loadTask = Task(priority: .userInitiated) { [weak self] in
            do {
                let snapshot = try await PreviewLoader.load(url)
                let format: FileFormat
                if case .session = snapshot.content { format = .claudeSession } else { format = .generic }
                let summary = await Self.cachedSummary(url: url, format: format)
                try Task.checkCancellation()
                guard let self else { return }
                self.state.summary = summary
                self.state.snapshot = snapshot
            } catch is CancellationError {
            } catch {
                self?.state.loadError = "Could not read the file: \(error.localizedDescription)"
            }
        }
    }

    /// Cache-only: Apple's on-device model cannot run in the Quick Look sandbox
    /// (ModelManagerError 1008), so summaries come only from the app's App Group cache.
    /// The key is built the same way as the app's (`CacheKey(fileURL:format:)`).
    @concurrent
    nonisolated private static func cachedSummary(url: URL, format: FileFormat) async -> CachedSummary {
        guard let dir = SummaryCache.defaultDirectory(), let key = CacheKey(fileURL: url, format: format) else { return .missing }
        return SummaryCache(directory: dir).get(key).map(CachedSummary.ready) ?? .missing
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        loadTask?.cancel()
    }

    isolated deinit {
        loadTask?.cancel()
    }
}
