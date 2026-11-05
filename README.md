# JSONLView

A native macOS viewer for `.jsonl` files, built mainly for Claude Code session transcripts.

- **Conversation view.** A Claude Code session reads as the conversation it was. Your prompts and
  Claude's replies are chat bubbles. Thinking blocks and tool calls fold to one line each and expand
  on click. Subagent work nests under the tool call that started it.
- **Sidebar.** The other `.jsonl` files in the same folder, and an outline of your prompts in this
  session.
- **Live sessions.** If the file is still being written by a running session, new messages appear as
  they are written.
- **Quick Look.** Press Space on a `.jsonl` file in Finder for a summary card: title, project, time
  span, counts of prompts, tool calls, subagents and edited files, the first prompt, the last reply,
  and a short written summary.
- **On-device summaries.** Summaries come from Apple's on-device model. Transcript content never
  leaves your Mac.
- **Any JSONL.** Files that are not Claude Code sessions show as a sortable table when the records
  share their keys, or as a list of collapsible records when they do not.
- **Read-only.** The app never writes to the files it opens.

## Requirements

- macOS 27 on Apple Silicon
- Apple Intelligence turned on, for the written summaries. Everything else works without it.

## Install

1. Download `JSONLView-<version>.zip` from the
   [latest release](https://github.com/PMSLLC/jsonl-view/releases/latest).
2. Unzip it and drag `JSONLView.app` into `/Applications`.
3. Open it once. It asks macOS to make it the default app for `.jsonl` files; accept the dialog if
   macOS shows one.

The app is signed with a Developer ID and notarized by Apple, so it opens without a Gatekeeper
warning.

If Space in Finder still shows plain text afterwards, run `qlmanage -r` in Terminal, or log out and
back in.

## Summaries

Opening a file summarizes it, and also summarizes the other `.jsonl` files in the same folder that
have no summary yet, one at a time at low priority ("Summarizing 3 of 12" under "This folder" in the
sidebar). It stops when you close the last window on that folder.

Quick Look shows a summary only after the app has made one. Apple's on-device model is not available
inside Quick Look extensions, so the preview reads the summaries the app has cached. A file that was
never summarized shows "No summary yet. Open this file in JSONLView to generate one."

Summaries are cached in
`~/Library/Group Containers/997DW79YCR.com.brahy.jsonl-view/Summaries/`. Delete that folder to
clear them.

## Build from source

Needs Xcode 27 and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

The project is set up for the author's signing team, `997DW79YCR`. To build under your own team,
replace `997DW79YCR` with your team ID in:

- `project.yml` (`DEVELOPMENT_TEAM`)
- `App/JSONLView.entitlements` and `Preview/JSONLPreview.entitlements` (the App Group)
- `Packages/JSONLCore/Sources/JSONLCore/SummaryCache.swift` (`appGroup`)
- `scripts/build-local.sh`

Then:

```
scripts/install.sh
```

This generates the Xcode project, builds Release with your "Apple Development" certificate, replaces
`/Applications/JSONLView.app`, registers the Quick Look extension and opens the app.

`scripts/release.sh` builds the notarized download. It needs a "Developer ID Application"
certificate and an App Store Connect API key, as described at the top of the script.

## Tests

```
swift test --package-path Packages/JSONLCore
```

## License

MIT. See [LICENSE](LICENSE).
