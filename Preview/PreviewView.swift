import JSONLCore
import Observation
import SwiftUI

/// The extension never generates a summary; it shows one the app has cached, or a hint.
enum CachedSummary: Equatable, Sendable {
    case ready(String)
    case missing
}

@MainActor @Observable
final class PreviewState {
    var url: URL?
    var fileBytes: UInt64 = 0
    var snapshot: PreviewSnapshot?
    var loadError: String?
    var summary: CachedSummary = .missing
}

/// Colors and sizes copied from the approved mockup (quicklook.html).
private enum Palette {
    static let panel = Color(hex: 0x1E1E1E)
    static let text = Color(hex: 0xE8E8E8)
    static let muted = Color(hex: 0x8A8A8A)
    static let label = Color(hex: 0x9A9A9A)
    static let tile = Color(hex: 0x2A2A2A)
    static let box = Color(hex: 0x262626)
    static let promptBar = Color(hex: 0x4A90E2)
    static let replyBar = Color(hex: 0xD97757)
    static let summary = Color(hex: 0x24303D)
    static let generating = Color(hex: 0x8FB3D9)
    static let badgeBG = Color(hex: 0x2F4A2F)
    static let badgeFG = Color(hex: 0x9FD89F)
}

private extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

struct PreviewView: View {
    let state: PreviewState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let snap = state.snapshot, let url = state.url {
                    switch snap.content {
                    case .session(let f): SessionPreview(facts: f, url: url, summary: state.summary)
                    case .generic(let g): GenericPreview(facts: g, snapshot: snap, url: url, summary: state.summary)
                    }
                } else if let url = state.url {
                    ReadingPreview(url: url, fileBytes: state.fileBytes, error: state.loadError)
                }
            }
            .padding(EdgeInsets(top: 18, leading: 20, bottom: 18, trailing: 20))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Palette.panel)
        .foregroundStyle(Palette.text)
        .font(.system(size: 13))
        .environment(\.colorScheme, .dark)
    }
}

// MARK: Session

private struct SessionPreview: View {
    let facts: SessionFacts
    let url: URL
    let summary: CachedSummary

    var body: some View {
        Header(title: facts.title, badge: "Claude Code session", line: pathLine)
        SummaryBlock(state: summary)
        Tiles(tiles: [
            Tile(value: "\(facts.promptCount)", label: "prompts", approx: facts.approximate),
            Tile(value: "\(facts.toolCallCount)", label: "tool calls", approx: facts.approximate),
            Tile(value: "\(facts.subagentCount)", label: "subagents", approx: facts.approximate),
            Tile(value: "\(facts.filesEdited)", label: "files edited", approx: facts.approximate),
            Tile(value: Format.bytes(facts.fileBytes), label: "file size", approx: false),
            Tile(value: facts.model ?? "unknown", label: "model", approx: false),
        ])
        if let p = facts.firstPrompt {
            SectionLabel(text: "First prompt")
            TextBox(text: Format.clip(p), bar: Palette.promptBar)
        }
        if let r = facts.lastReply {
            SectionLabel(text: "Last reply")
            TextBox(text: Format.clip(r), bar: Palette.replyBar)
        }
    }

    private var pathLine: String {
        var parts: [String] = []
        parts.append(Format.tilde(facts.cwd ?? url.deletingLastPathComponent().path))
        if let b = facts.branch { parts.append(b) }
        if let s = facts.start, let e = facts.end { parts.append(Format.span(s, e)) }
        return parts.joined(separator: " \u{00B7} ")
    }
}

// MARK: Reading

/// Shown while the facts are being read: only what the file system already knows.
private struct ReadingPreview: View {
    let url: URL
    let fileBytes: UInt64
    let error: String?

    var body: some View {
        Header(title: url.deletingPathExtension().lastPathComponent, badge: nil,
               line: Format.tilde(url.deletingLastPathComponent().path) + " \u{00B7} " + Format.bytes(fileBytes))
        HStack(spacing: 6) {
            if let error {
                Text(error).foregroundStyle(Palette.label)
            } else {
                PulsingDot()
                Text("Reading file...").italic().foregroundStyle(Palette.generating)
            }
        }
        .padding(.top, 14)
    }
}

// MARK: Generic

private struct GenericPreview: View {
    let facts: GenericFacts
    let snapshot: PreviewSnapshot
    let url: URL
    let summary: CachedSummary

    var body: some View {
        Header(title: url.deletingPathExtension().lastPathComponent, badge: "JSON Lines",
               line: Format.tilde(url.deletingLastPathComponent().path))
        SummaryBlock(state: summary)
        Tiles(tiles: [
            Tile(value: "\(facts.recordCount)", label: "records", approx: snapshot.approximate),
            Tile(value: "\(facts.invalidCount)", label: "invalid lines", approx: snapshot.approximate),
            Tile(value: Format.bytes(snapshot.fileBytes), label: "file size", approx: false),
        ])
        if !facts.topKeys.isEmpty {
            SectionLabel(text: "Top keys")
            Text(facts.topKeys.map { "\($0.key) \(Int(($0.share * 100).rounded()))%" }.joined(separator: "   "))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Palette.text)
                .textSelection(.enabled)
        }
        if !facts.samples.isEmpty {
            SectionLabel(text: "Sample rows")
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(facts.samples.enumerated()), id: \.offset) { _, row in
                    TextBox(text: Format.json(row), bar: Palette.promptBar, mono: true)
                }
            }
        }
    }
}

// MARK: Pieces

private struct Header: View {
    let title: String
    let badge: String?
    let line: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).font(.system(size: 18, weight: .bold)).foregroundStyle(.white).lineLimit(2)
            if let badge {
                Text(badge)
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.badgeFG)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Palette.badgeBG, in: Capsule())
            }
        }
        .padding(.bottom, 2)
        Text(line)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(Palette.muted)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10))
            .kerning(0.6)
            .foregroundStyle(Palette.label)
            .padding(.top, 12).padding(.bottom, 4)
    }
}

private struct SummaryBlock: View {
    let state: CachedSummary

    var body: some View {
        SectionLabel(text: "Summary").padding(.top, 2)
        Group {
            switch state {
            case .ready(let text):
                Text(text).lineSpacing(3).textSelection(.enabled)
            case .missing:
                Text("No summary yet. Open this file in JSONLView to generate one.")
                    .italic().foregroundStyle(Palette.label)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.summary, in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct PulsingDot: View {
    @State private var on = false
    var body: some View {
        Circle()
            .fill(Palette.promptBar)
            .frame(width: 8, height: 8)
            .opacity(on ? 1 : 0.2)
            .animation(.easeInOut(duration: 1).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

private struct Tile: Identifiable {
    let value: String
    let label: String
    /// Count from the head and tail of a capped file only (a lower bound).
    let approx: Bool
    var id: String { label }
}

private struct Tiles: View {
    let tiles: [Tile]

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(tiles) { t in
                VStack(alignment: .leading, spacing: 1) {
                    Text(t.value).font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Text(t.approx ? "\(t.label), sampled" : t.label)
                        .font(.system(size: 11)).foregroundStyle(Palette.label)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.tile, in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.top, 14)
    }
}

private struct TextBox: View {
    let text: String
    let bar: Color
    var mono = false

    var body: some View {
        Text(text)
            .font(mono ? .system(size: 11, design: .monospaced) : .system(size: 13))
            .lineSpacing(3)
            .lineLimit(mono ? 3 : 6)
            .textSelection(.enabled)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.box, in: RoundedRectangle(cornerRadius: 4))
            .overlay(alignment: .leading) {
                UnevenRoundedRectangle(topLeadingRadius: 4, bottomLeadingRadius: 4).fill(bar).frame(width: 3)
            }
    }
}

// MARK: Formatting

private enum Format {
    static func bytes(_ n: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }

    /// Cut long text before layout so a huge prompt cannot stall the preview.
    static func clip(_ s: String, limit: Int = 600) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > limit ? String(t.prefix(limit)) + "..." : t
    }

    /// `/Users/<name>/...` as `~/...`. Done by pattern because the sandbox home is the container.
    static func tilde(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0].isEmpty, parts[1] == "Users" else { return path }
        return (["~"] + parts.dropFirst(3)).joined(separator: "/")
    }

    static func json(_ v: JSONValue) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let s = (try? enc.encode(v)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return clip(s, limit: 400)
    }

    /// "Oct 6, 2026 7:42 to 7:42 AM (37 s)", with the end date repeated only when it differs.
    static func span(_ start: Date, _ end: Date) -> String {
        let cal = Calendar.current
        let startText = start.formatted(date: .abbreviated, time: .shortened)
        let endText = cal.isDate(start, inSameDayAs: end)
            ? end.formatted(date: .omitted, time: .shortened)
            : end.formatted(date: .abbreviated, time: .shortened)
        return "\(startText) to \(endText) (\(duration(end.timeIntervalSince(start))))"
    }

    static func duration(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        if s < 60 { return "\(s) s" }
        if s < 3_600 { return "\(s / 60) min" }
        let h = s / 3_600, m = (s % 3_600) / 60
        if h < 48 { return m == 0 ? "\(h) h" : "\(h) h \(m) min" }
        return "\(h / 24) days"
    }
}
