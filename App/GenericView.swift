import JSONLCore
import SwiftUI

/// Any .jsonl that is not a Claude Code session: a table when records share their keys,
/// otherwise a list of collapsible pretty-printed records.
struct GenericView: View {
    let controller: DocumentController
    let search: SearchState
    @Binding var scrollTarget: Int?

    var body: some View {
        let records = controller.records
        let indices = search.matches ?? Array(records.indices)
        let rows = indices.compactMap { $0 < records.count ? GenericRow(id: $0, value: records[$0]) : nil }
        VStack(spacing: 0) {
            HeaderCard(title: controller.title, summary: controller.summary)
                .padding(.horizontal, 14)
                .padding(.top, 6)
            if let error = controller.loadError {
                LoadErrorBanner(message: error).padding(.horizontal, 14).padding(.bottom, 6)
            }
            if controller.invalidCount > 0 {
                let n = controller.invalidCount
                Label(n == 1 ? "1 invalid line skipped" : "\(n) invalid lines skipped", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.yellow.opacity(0.18), in: .rect(cornerRadius: 6))
                    .padding(.horizontal, 14).padding(.bottom, 6)
            }
            switch controller.genericLayout {
            case .table(let columns):
                GenericTable(rows: rows, columns: columns, scrollTarget: $scrollTarget)
            case .records:
                GenericRecordList(rows: rows, query: search.matches == nil ? "" : search.query,
                                  currentID: search.currentID, scrollTarget: $scrollTarget)
            }
        }
    }
}

struct GenericRow: Identifiable {
    let id: Int
    let value: JSONValue
}

private struct GenericTable: View {
    let rows: [GenericRow]
    let columns: [String]
    @Binding var scrollTarget: Int?
    @State private var selection: Int?

    var body: some View {
        ScrollViewReader { proxy in
            Table(rows, selection: $selection) {
                TableColumnForEach(columns, id: \.self) { column in
                    TableColumn(column) { row in
                        Text(row.value[column].map { compactJSON($0, limit: 200) } ?? "")
                            .lineLimit(1)
                            .help(row.value[column].map { compactJSON($0, limit: 2_000) } ?? "")
                    }
                }
            }
            .onChange(of: scrollTarget) {
                guard let t = scrollTarget else { return }
                selection = t
                proxy.scrollTo(t)
                scrollTarget = nil
            }
        }
    }
}

private struct GenericRecordList: View {
    let rows: [GenericRow]
    let query: String
    let currentID: Int?
    @Binding var scrollTarget: Int?

    var body: some View {
        ScrollViewReader { proxy in
            List(rows) { row in
                DisclosureGroup {
                    Text(prettyJSON(row.value))
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Text(highlighted(compactJSON(row.value, limit: 300), query))
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                }
                .listRowBackground(row.id == currentID ? Color.accentColor.opacity(0.18) : nil)
            }
            .onChange(of: scrollTarget) {
                guard let t = scrollTarget else { return }
                proxy.scrollTo(t, anchor: .top)
                scrollTarget = nil
            }
        }
    }
}
