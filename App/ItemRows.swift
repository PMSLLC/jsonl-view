import JSONLCore
import SwiftUI

private let bubbleLimit = 20_000
private let subagentAccent = Color(red: 0.85, green: 0.47, blue: 0.34)

/// One conversation item. `controller` is nil inside a nested subagent view.
struct ItemRow: View {
    let item: ConversationItem
    let query: String
    let isCurrent: Bool
    let controller: DocumentController?

    var body: some View {
        content
            .overlay {
                if isCurrent {
                    RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 2)
                }
            }
    }

    @ViewBuilder private var content: some View {
        switch item.kind {
        case .userPrompt(let t):
            Bubble(text: t, isUser: true, timestamp: item.timestamp, query: query)
        case .assistantText(let t):
            Bubble(text: t, isUser: false, timestamp: item.timestamp, query: query)
        case .thinking(let t):
            FoldRow(label: "Thinking", query: query) {
                Text(highlighted(capped(t), query))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        case .notification(let summary, let body):
            FoldRow(label: "Notification: \(summary)", query: query) {
                Text(highlighted(capped(body), query))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        case .compaction(let text):
            FoldRow(label: "Context summary (from compaction)", query: query) {
                Text(highlighted(capped(text), query))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        case .toolCall(let call):
            if let controller, call.name == "Agent" || call.name == "Task", let ref = controller.subagents[call.id] {
                SubagentRow(call: call, ref: ref, controller: controller, query: query)
            } else {
                ToolRow(call: call, query: query)
            }
        }
    }
}

private struct Bubble: View {
    let text: String
    let isUser: Bool
    let timestamp: Date?
    let query: String
    @State private var showAll = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if isUser { Spacer(minLength: 60) }
            VStack(alignment: .leading, spacing: 3) {
                Text(who).font(.caption2).foregroundStyle(.secondary)
                Text(attributed)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if !showAll, isCapped(text) {
                    Button("Show all") { showAll = true }.buttonStyle(.link).font(.caption)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(isUser ? Color.blue.opacity(0.22) : Color.secondary.opacity(0.13), in: .rect(cornerRadius: 9))
            if !isUser { Spacer(minLength: 60) }
        }
    }

    private var who: String {
        let name = isUser ? "You" : "Claude"
        guard let timestamp else { return name }
        return "\(name) \u{00B7} \(timestamp.formatted(date: .omitted, time: .shortened))"
    }

    private var attributed: AttributedString {
        let shown = showAll ? text : capped(text)
        if !query.isEmpty { return highlighted(shown, query) }
        if !isUser, let md = try? AttributedString(
            markdown: shown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return md
        }
        return AttributedString(shown)
    }
}

/// A single monospace line that expands to show `detail`.
struct FoldRow<Detail: View>: View {
    let label: String
    var isError = false
    let query: String
    @ViewBuilder let detail: () -> Detail
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text(highlighted(label, query))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if isError { Text("error").foregroundStyle(.red) }
                    Spacer(minLength: 0)
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if expanded {
                detail().padding(.leading, 14)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.06), in: .rect(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.18)))
        .padding(.trailing, 60)
    }
}

private struct ToolRow: View {
    let call: ToolCall
    let query: String

    var body: some View {
        FoldRow(label: label(call), isError: call.resultIsError, query: query) {
            ToolDetail(call: call)
        }
    }
}

private func label(_ call: ToolCall) -> String {
    call.inputSummary.isEmpty ? call.name : "\(call.name): \(call.inputSummary)"
}

/// Input JSON and the result preview, with "Show all" for results over the preview limit.
private struct ToolDetail: View {
    let call: ToolCall
    @State private var showAll = false
    /// Encoded once, off the main actor: inputs and results can be several MB.
    @State private var inputText: String?
    @State private var preview: (text: String, truncated: Bool)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Input").font(.caption.bold()).foregroundStyle(.secondary)
            if let inputText { MonoBlock(text: inputText) } else { ProgressView().controlSize(.small) }
            if let result = call.result {
                Text(call.resultIsError ? "Result (error)" : "Result").font(.caption.bold()).foregroundStyle(.secondary)
                if showAll {
                    LongText(text: result).frame(height: 420)
                } else if let preview {
                    MonoBlock(text: preview.text)
                    if preview.truncated {
                        Button("Show all (\(ByteCountFormatter.string(fromByteCount: Int64(result.utf8.count), countStyle: .file)))") {
                            showAll = true
                        }
                        .buttonStyle(.link).font(.caption)
                    }
                }
            } else {
                Text("No result yet").font(.caption).foregroundStyle(.secondary)
            }
        }
        .task(id: call.result?.utf8.count) {
            let input = call.input, result = call.result
            let (text, p) = await Task.detached(priority: .userInitiated) {
                (prettyJSON(input), result.map(SessionModel.resultPreview))
            }.value
            inputText = text
            preview = p
        }
    }
}

/// Monospace text in a height-capped scroll area.
private struct MonoBlock: View {
    let text: String

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: min(260, CGFloat(lineCount) * 14 + 4))
    }

    private var lineCount: Int { text.utf8.reduce(1) { $1 == 0x0A ? $0 + 1 : $0 } }
}

private struct SubagentRow: View {
    let call: ToolCall
    let ref: SubagentRef
    let controller: DocumentController
    let query: String
    @State private var expanded = false

    var body: some View {
        let transcript = controller.subagentTranscripts[call.id]
        HStack(alignment: .top, spacing: 8) {
            Rectangle().fill(subagentAccent).frame(width: 3)
            VStack(alignment: .leading, spacing: 4) {
                Button { expanded.toggle() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                        Text(header(transcript)).font(.caption.bold()).foregroundStyle(subagentAccent)
                        Spacer(minLength: 0)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                Text(highlighted(SubagentTranscript.displayLine(result: call.result, transcript: transcript,
                                                                description: ref.description), query))
                    .font(.callout)
                    .lineLimit(2)
                    .foregroundStyle(.secondary)
                if expanded {
                    if let error = transcript?.error {
                        Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
                    } else if let transcript {
                        NestedConversationView(items: transcript.items, query: query)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
            }
        }
        .padding(.vertical, 3)
        .padding(.leading, 10)
        .padding(.trailing, 60)
        .onAppear { controller.loadSubagent(call.id) }
    }

    private func header(_ t: SubagentTranscript?) -> String {
        let type = ref.agentType.isEmpty ? "agent" : ref.agentType
        guard let t else { return "Subagent: \(type)" }
        if t.error != nil { return "Subagent: \(type) (transcript unreadable)" }
        return "Subagent: \(type) (\(t.toolCallCount) tool call\(t.toolCallCount == 1 ? "" : "s"))"
    }
}

/// True when `capped` would cut `s`. The cheap byte count goes first; the character count
/// (which walks the whole string) only runs for long text.
private func isCapped(_ s: String) -> Bool {
    s.utf8.count > bubbleLimit && s.count > bubbleLimit
}

private func capped(_ s: String) -> String {
    isCapped(s) ? String(s.prefix(bubbleLimit)) + "..." : s
}

/// `s` with every case-insensitive occurrence of `query` highlighted.
func highlighted(_ s: String, _ query: String) -> AttributedString {
    var a = AttributedString(s)
    guard !query.isEmpty else { return a }
    var from = s.startIndex
    while from < s.endIndex, let r = s.range(of: query, options: .caseInsensitive, range: from..<s.endIndex) {
        if let ar = Range(r, in: a) {
            a[ar].backgroundColor = Color.yellow.opacity(0.45)
        }
        from = r.upperBound
    }
    return a
}
