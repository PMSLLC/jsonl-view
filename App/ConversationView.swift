import JSONLCore
import SwiftUI

/// The open session as a conversation: header card, then one row per item.
struct ConversationView: View {
    let controller: DocumentController
    let search: SearchState
    @Binding var scrollTarget: Int?
    @State private var atBottom = false

    var body: some View {
        let items = controller.items
        let shown = search.matches.map { ids in ids.compactMap { $0 < items.count ? items[$0] : nil } } ?? items
        ScrollViewReader { proxy in
            List {
                HeaderCard(title: controller.title, summary: controller.summary)
                    .id(-1)
                    .listRowSeparator(.hidden)
                if let error = controller.loadError {
                    LoadErrorBanner(message: error).listRowSeparator(.hidden)
                }
                if search.matches != nil {
                    Text(shown.count == 1 ? "1 match" : "\(shown.count) matches")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .listRowSeparator(.hidden)
                }
                ForEach(shown) { item in
                    ItemRow(item: item, query: search.matches == nil ? "" : search.query,
                            isCurrent: item.id == search.currentID, controller: controller)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 3, leading: 14, bottom: 3, trailing: 14))
                }
                if controller.isLoading {
                    ProgressView().controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .onScrollGeometryChange(for: Bool.self) { g in
                g.contentOffset.y + g.containerSize.height >= g.contentSize.height - 40
            } action: { _, bottom in
                atBottom = bottom
            }
            .onChange(of: items.count) {
                // Live updates only: during the initial background load the user stays where they are.
                guard atBottom, !controller.isLoading, search.matches == nil, let last = items.last else { return }
                proxy.scrollTo(last.id, anchor: .bottom)
            }
            .onChange(of: scrollTarget) {
                guard let t = scrollTarget else { return }
                proxy.scrollTo(t, anchor: .top)
                scrollTarget = nil
                // List estimates the heights of rows it has not laid out yet, so the first jump
                // can land short. A second pass after layout corrects it.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { proxy.scrollTo(t, anchor: .top) }
            }
        }
    }
}

/// Title and the first sentence of the summary.
struct HeaderCard: View {
    let title: String
    let summary: SummaryState

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.headline)
            Text(line)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.accentColor.opacity(0.12), in: .rect(cornerRadius: 8))
        .padding(.vertical, 4)
    }

    private var line: String {
        switch summary {
        case .generating: return "Generating summary text..."
        case .ready(let s): return firstSentence(s)
        case .unavailable(let r), .failed(let r): return r.hasPrefix("Summary unavailable") ? r : "Summary unavailable: \(r)"
        }
    }

    private func firstSentence(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        var out = ""
        t.enumerateSubstrings(in: t.startIndex..., options: .bySentences) { sub, _, _, stop in
            out = (sub ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            stop = true
        }
        return out.isEmpty ? t : out
    }
}

/// A subagent's conversation rendered inside its tool call row. Not lazy: it sits inside
/// one row of the outer list, and folded rows are cheap.
struct NestedConversationView: View {
    let items: [ConversationItem]
    let query: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if items.isEmpty {
                Text("No messages in this subagent transcript.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                ItemRow(item: item, query: query, isCurrent: false, controller: nil)
            }
        }
    }
}

/// Shown when part of the file could not be read, so partial content is not mistaken for all of it.
struct LoadErrorBanner: View {
    let message: String

    var body: some View {
        Label {
            Text(message)
        } icon: {
            Image(systemName: "exclamationmark.octagon").foregroundStyle(.red)
        }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.red.opacity(0.15), in: .rect(cornerRadius: 6))
    }
}
