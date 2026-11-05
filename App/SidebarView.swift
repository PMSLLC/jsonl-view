import JSONLCore
import SwiftUI

/// "This folder" (sibling .jsonl files by title) and "Outline" (numbered prompts).
struct SidebarView: View {
    let controller: DocumentController
    let open: (URL) -> Void
    let jump: (Int) -> Void

    var body: some View {
        List {
            Section("This folder") {
                if let p = Summaries.folders.progress(for: controller.url) {
                    Text("Summarizing \(p.current) of \(p.total)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                }
                ForEach(controller.siblings, id: \.url) { sibling in
                    let current = sibling.url == controller.url
                    Button { open(sibling.url) } label: {
                        Text(sibling.title)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 3)
                            .padding(.horizontal, 6)
                            .foregroundStyle(current ? Color.white : Color.primary)
                            .background(current ? Color.accentColor : Color.clear, in: .rect(cornerRadius: 5))
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help(sibling.url.lastPathComponent)
                }
            }
            if controller.format == .claudeSession {
                Section("Outline") {
                    ForEach(Array(controller.outline.enumerated()), id: \.element.id) { n, item in
                        Button { jump(item.id) } label: {
                            Text("\(n + 1). \(promptLine(item))")
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 6)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func promptLine(_ item: ConversationItem) -> String {
        guard case .userPrompt(let p) = item.kind else { return "" }
        let head = p.prefix(200)
        return head.split(whereSeparator: \.isNewline).first.map(String.init) ?? String(head)
    }
}
