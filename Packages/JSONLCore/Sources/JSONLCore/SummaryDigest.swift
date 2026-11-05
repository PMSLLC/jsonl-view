import Foundation

public enum SummaryDigest {
    public static let limit = 6_000
    static let maxPrompts = 12, promptChars = 400, maxReplies = 2, replyChars = 700
    static let headerChars = 1_000, fileChars = 1_200

    /// Built inside `limit` so the most useful parts always survive: the header, the last
    /// replies and the edited files are sized first, and the prompts get what is left.
    public static func text(facts: SessionFacts, model: SessionModel) -> String {
        var header = "Title: \(facts.title)\n"
        if let m = facts.model { header += "Model: \(m)\n" }
        if let c = facts.cwd { header += "Directory: \(c)\n" }
        if let b = facts.branch { header += "Branch: \(b)\n" }
        header += "Prompts: \(facts.promptCount), tool calls: \(facts.toolCallCount), "
            + "subagents: \(facts.subagentCount), files edited: \(facts.filesEdited)\n"
        header = String(header.prefix(headerChars))

        var prompts: [String] = [], replies: [String] = []
        for item in model.items {
            switch item.kind {
            case .userPrompt(let p) where prompts.count < maxPrompts: prompts.append(String(p.prefix(promptChars)))
            case .assistantText(let t): replies.append(t)
            default: break
            }
        }
        let replyBlock = "\nLast replies:\n" + replies.suffix(maxReplies).map { "- \($0.prefix(replyChars))" }.joined(separator: "\n") + "\n"
        let files = SessionFacts.editedPaths(model.toolCalls).map { ($0 as NSString).lastPathComponent }
        let fileBlock = "\nEdited files: " + fileList(files) + "\n"

        var budget = limit - header.count - replyBlock.count - fileBlock.count
        var promptBlock = "\nPrompts:\n"
        budget -= promptBlock.count
        for p in prompts where budget > 2 {
            let line = String("- \(p)".prefix(budget - 1)) + "\n"
            promptBlock += line
            budget -= line.count
        }
        return String((header + promptBlock + replyBlock + fileBlock).prefix(limit))
    }

    /// Names joined with ", " up to `fileChars`, then "and N more".
    static func fileList(_ names: [String]) -> String {
        var out = ""
        for (i, name) in names.enumerated() {
            let piece = (out.isEmpty ? "" : ", ") + name
            if out.count + piece.count > fileChars - 20 {
                return out.isEmpty ? "\(names.count) files" : out + ", and \(names.count - i) more"
            }
            out += piece
        }
        return out
    }
}
