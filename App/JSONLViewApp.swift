import SwiftUI
import UniformTypeIdentifiers

@main
struct JSONLViewApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        DocumentGroup(viewing: JSONLDocument.self) { file in
            if let url = file.fileURL {
                DocumentWindow(url: url)
            } else {
                Text("This file has no location on disk.")
                    .frame(minWidth: 480, minHeight: 320)
            }
        }
        .commands {
            // Read-only viewer: no New, Save, Duplicate, Rename, Move or Revert. Replacing
            // .newItem also drops Open Recent, so it is rebuilt here (Open... stays).
            CommandGroup(replacing: .newItem) { OpenCommands() }
            CommandGroup(replacing: .saveItem) {
                Button("Close") { NSApp.keyWindow?.performClose(nil) }.keyboardShortcut("w")
            }
            CommandGroup(after: .pasteboard) { FindCommand() }
            CommandGroup(after: .appInfo) {
                Button("Make Default for .jsonl Files") { DefaultHandler.makeDefaultShowingErrors() }
            }
        }
    }
}

/// Read-only document. It never reads the contents itself: `DocumentWindow` streams the file
/// from its URL so large files are not loaded whole, and writing always fails.
struct JSONLDocument: FileDocument {
    static let readableContentTypes = [UTType(importedAs: "org.jsonlines.jsonl")]
    static let writableContentTypes: [UTType] = []

    init(configuration: ReadConfiguration) throws {}

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        throw CocoaError(.fileWriteNoPermission)
    }
}

extension FocusedValues {
    @Entry var findAction: (() -> Void)?
}

private struct FindCommand: View {
    @FocusedValue(\.findAction) private var findAction

    var body: some View {
        Button("Find in File") { findAction?() }
            .keyboardShortcut("f")
            .disabled(findAction == nil)
    }
}

/// The Open Recent submenu backed by NSDocumentController's recent documents.
private struct OpenCommands: View {
    @State private var recents = RecentDocuments.shared

    var body: some View {
        Menu("Open Recent") {
            ForEach(recents.urls, id: \.self) { url in
                Button(url.lastPathComponent) {
                    NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
                }
            }
            Divider()
            Button("Clear Menu") { recents.clear() }
                .disabled(recents.urls.isEmpty)
        }
    }
}

/// Observable copy of the recent-documents list, refreshed whenever a document window appears
/// (opening a document is what adds to the list).
@MainActor @Observable
final class RecentDocuments {
    static let shared = RecentDocuments()
    /// Starts empty: touching NSDocumentController.shared while menus are first built would create
    /// it before SwiftUI installs its own subclass, which crashes at launch.
    private(set) var urls: [URL] = []

    func refresh() { urls = NSDocumentController.shared.recentDocumentURLs }

    func clear() {
        NSDocumentController.shared.clearRecentDocuments(nil)
        refresh()
    }
}
