import AppKit
import JSONLCore
import SwiftUI

struct DocumentWindow: View {
    @State private var controller: DocumentController
    @State private var searchModel = SearchModel()
    @State private var scrollTarget: Int?
    @FocusState private var searchFocused: Bool

    init(url: URL) {
        _controller = State(initialValue: DocumentController(url: url))
    }

    var body: some View {
        let search = searchModel.state
        NavigationSplitView {
            SidebarView(controller: controller, open: open, jump: { scrollTarget = $0 })
                .navigationSplitViewColumnWidth(min: 180, ideal: 230, max: 360)
        } detail: {
            Group {
                switch controller.format {
                case .claudeSession:
                    ConversationView(controller: controller, search: search, scrollTarget: $scrollTarget)
                case .generic:
                    GenericView(controller: controller, search: search, scrollTarget: $scrollTarget)
                }
            }
            .frame(minWidth: 420)
            // DocumentGroup puts the file name in the title; the subtitle carries the full path.
            .navigationSubtitle((controller.url.path as NSString).abbreviatingWithTildeInPath)
        }
        .frame(minWidth: 720, minHeight: 440)
        .searchable(text: Bindable(searchModel).state.query, placement: .toolbar, prompt: "Search")
        .searchFocused($searchFocused)
        .onSubmit(of: .search) { scrollTarget = searchModel.nextMatch() }
        .focusedSceneValue(\.findAction, { searchFocused = true })
        .onChange(of: search.query) { searchModel.queryChanged() }
        .onChange(of: controller.revision) { searchModel.dataChanged() }
        .onChange(of: controller.ownSummaryPending) {
            Summaries.folders.setSummaryPending(controller.url, controller.ownSummaryPending)
        }
        .onAppear {
            searchModel.controller = controller
            controller.start()
            Summaries.folders.open(controller.url, siblings: controller.siblings.map(\.url))
            RecentDocuments.shared.refresh()
        }
        .onDisappear {
            controller.stop()
            Summaries.folders.close(controller.url)
        }
    }

    /// Opens a sibling as its own document in this window's place, then closes this window,
    /// so the title bar, Open Recent and window restoration all describe the file shown.
    private func open(_ url: URL) {
        guard url != controller.url else { return }
        let old = NSApp.keyWindow
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { doc, _, error in
            guard error == nil, let doc else { return }
            DispatchQueue.main.async {
                guard let old, let new = doc.windowControllers.first?.window, new !== old else { return }
                new.setFrame(old.frame, display: true)
                old.close()
            }
        }
    }
}
