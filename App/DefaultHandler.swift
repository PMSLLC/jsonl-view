import AppKit
import os
import UniformTypeIdentifiers

/// Makes JSONLView the default app for .jsonl files. macOS may show its own confirmation dialog.
enum DefaultHandler {
    static let askedKey = "didRequestDefaultHandler"

    @MainActor
    static func makeDefault() async throws {
        try await NSWorkspace.shared.setDefaultApplication(
            at: Bundle.main.bundleURL, toOpen: UTType(importedAs: "org.jsonlines.jsonl"))
    }

    /// Menu action: runs `makeDefault` and shows an alert if it fails.
    @MainActor
    static func makeDefaultShowingErrors() {
        Task {
            do { try await makeDefault() } catch { NSAlert(error: error).runModal() }
        }
    }

    /// Runs `makeDefault` once. The flag is set only after success, so a failed attempt is
    /// retried on the next launch; the menu item stays available.
    @MainActor
    static func runOnFirstLaunch() {
        guard !UserDefaults.standard.bool(forKey: askedKey) else { return }
        Task {
            do {
                try await makeDefault()
                UserDefaults.standard.set(true, forKey: askedKey)
            } catch {
                Logger(subsystem: "com.brahy.jsonl-view", category: "DefaultHandler")
                    .error("makeDefault failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DefaultHandler.runOnFirstLaunch()
    }
}
