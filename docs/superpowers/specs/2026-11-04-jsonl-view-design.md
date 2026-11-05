# jsonl-view: design

Date: 2026-11-04. Owner: John Brahy.

This is the design document the app was built from, kept as written apart from removing
personal paths and details.

## Intent

The owner has hundreds of Claude Code session transcripts (`.jsonl`, up to about 50 MB each) that
he is copying, renaming and later sanitizing. Raw JSONL is unreadable.
He wants to browse these files in an intelligent view: read a session as the conversation it was,
with the machinery (tool calls, thinking, system records) out of the way until he wants it.

The moment it serves: he is in Finder looking at a folder of renamed sessions, presses Space on one
to see what it was about, and double-clicks the one he wants to read.

## Goals

1. A native macOS app that is the default handler for `.jsonl`. Double-click opens the file.
2. A Quick Look preview extension. Space in Finder shows a preview of the file.
3. Claude Code transcripts render as a readable conversation (detail below).
4. Any other `.jsonl` file is still arranged in an intelligent way for viewing, never shown as a raw
   dump.
5. Live sessions: when the open file is still being written (a running Claude Code session), the main
   window keeps adding new messages as they are written, and the outline, counts and subagents update
   with them (owner, 2026-11-04). The parser is incremental from the start: watch the file, track the
   byte offset, append new records. A partial last line waits until it is complete. Quick Look stays
   a snapshot.
6. The Quick Look preview shows instant facts immediately, plus the written summary when the app has
   already made one. Quick Look's summary is cache-only: the app generates it and writes it to the
   shared App Group cache, and the extension only reads it, because Foundation Models is unavailable
   inside the sandboxed Quick Look extension (ModelManagerError 1008). An uncached file shows "No
   summary yet. Open this file in JSONLView to generate one." (changed during the build, 2026-11-04).

## Non-goals

- Editing. The app is read-only and never writes to the file it opens.
- Redaction or sanitizing. That is a later, separate step in another tool.
- Search across many files or a library of all sessions. Search is within the open file.
- claude.ai web chat exports and Cowork transcripts as first-class formats (they may render via the
  generic view).
- Distribution to other people or the App Store.

## Anti-goals

- Sending transcript content off the Mac. Transcripts contain secrets. The summary must be generated
  on device.
- Using a cloud model for the summary.
- A Quick Look preview that waits on the summary before showing anything.
- Hanging or eating memory on a 50 MB file.

## Constraints

- Swift and SwiftUI, Xcode project. Signed with the owner's Apple Developer team `997DW79YCR`.
- Target the macOS version on the owner's Mac (Darwin 27, i.e. macOS 27). No need to support older.
- Summary model: Apple's on-device Foundation Models framework, run by the app only. It cannot be
  called from the Quick Look extension (ModelManagerError 1008 in its sandbox), so the extension shows
  only summaries the app has cached. If the model is unavailable in the app (Apple Intelligence off or
  model not downloaded), the summary area says so in one line and the rest of the view is unaffected.
- Install target is `/Applications`.
- No secrets in the repo. No network access needed by either target.

## What the owner decided

### Quick Look preview (approved mockup)

Dark panel, top to bottom:

1. Title, plus a badge for the detected format ("Claude Code session").
2. One line: project path, git branch, start and end time, duration.
3. "Summary" block. Starts as a pulsing dot and "Generating summary text...", then is replaced by a
   2 to 3 sentence summary ending with the outcome (done, partial, abandoned).
4. Six fact tiles: prompts, tool calls, subagents, files edited, file size, model.
5. "First prompt" (the user's first real message, truncated).
6. "Last reply" (Claude's last text reply, truncated).

Title source: the file's `ai-title` record if present, else a title derived from the first prompt,
else the filename.

### Main window (layout A, chosen over a single-document layout with filter chips)

- Window title bar shows the file path and has a search field (search within the file).
- **Sidebar**, two sections:
  - "This folder": the other `.jsonl` files in the same folder, by title. Clicking one switches the
    main view to it.
  - "Outline": the user's prompts in this session, numbered. Clicking jumps to that point.
- **Header card** at the top of the conversation: title and the one-line summary.
- **Conversation**:
  - User prompts and Claude's text replies as chat bubbles with timestamps (user on the right in
    blue, Claude on the left in grey).
  - Thinking blocks and each tool call fold to a single line (tool name plus a short form of its
    input, e.g. `Bash: ls docs | head`). Clicking expands it to show the input and its result.
  - Subagent work shows nested under the tool call that started it, with an accent bar, a label
    ("Subagent: <type> (N tool calls)") and its final result. It expands to the subagent's own
    conversation, rendered the same way.

## Format notes for the builder (verified on real session files 2026-11-04)

Claude Code session file: one JSON object per line, top-level key `type`. Seen types: `user`,
`assistant`, `system`, `attachment`, `ai-title` (`aiTitle`), `last-prompt`, `summary`,
`file-history-snapshot`, `permission-mode`, `mode`, `api-request*`, and others. Unknown types must be
tolerated and hidden by default.

- `user` / `assistant` records carry `timestamp`, `cwd`, `gitBranch`, `isSidechain`, `isMeta` and
  `message.content`, which is a string or a list of blocks: `text`, `thinking`, `tool_use`
  (`name`, `input`, `id`), `tool_result` (`tool_use_id`, `content`).
- A `user` record whose content is only `tool_result` blocks is a tool output, not a prompt.
  `isMeta` records and text wrapped in `<system-reminder>`, `<command-*>` and `<local-command-*>`
  tags are system noise, not prompts.
- Subagents: `<session-id>/subagents/agent-<id>.jsonl` next to the session file, each with
  `agent-<id>.meta.json` containing `agentType`, `description`, `model` and `toolUseId`. `toolUseId`
  matches the parent's `tool_use.id`, which is how a subagent attaches to the call that started it.
  Renamed copies of sessions keep this sidecar directory next to the file under the file's
  new base name.
- Lines can be partial or invalid at the end of a file that is still being written. Skip bad lines.
- Detection: treat a file as a Claude Code session if its first few valid records have a `type` of
  `user`/`assistant`/`summary`/`ai-title` plus a `sessionId` or `message` field.

An earlier Python digest script (not in this repo) already computed most of the instant facts
in Python and is a useful reference for the rules above.

## Calls made by Claude (not the owner), open to his correction

- One summary pipeline and one cache, shared by the app and the Quick Look extension (App Group).
  The main window's header card shows the first sentence of that summary and is the only place it is
  generated; Quick Look reads the cache (see Goal 6).
- Background folder summaries (owner approved 2026-11-04). When a window opens a file, the app
  queues the sibling `.jsonl` files in that folder that have no cached summary under their current
  key and summarizes them one at a time, in sidebar order, at background priority, so Space in
  Finder shows a summary for files never opened. One queue per folder, shared by its windows. It
  stops when the last window on the folder closes or when the model is unavailable; a file that
  fails is skipped and not retried in that app session unless it changes. It waits while an open
  window's own summary is pending (up to 60 s), and only one background model call runs at a time.
  Files over 16 MB are read 4 MB from each end (Quick Look keeps its own 64 MB limit). Progress
  shows as "Summarizing N of M" under "This folder". The only writes are to the summary cache.

## Left to the builder

- How non-Claude `.jsonl` is "arranged intelligently". The owner's only requirement is that it is not a
  raw dump. Suggested: if records share most keys, a sortable table with one column per top-level
  key; otherwise a list of collapsible pretty-printed records; plus Quick Look facts of record count,
  keys and a few sample rows, and the same on-device summary.
- Performance approach for large files (streaming parse, lazy rendering, caps on what Quick Look
  reads).
- Whether summaries are cached (e.g. keyed by path, size and modification time) so the second
  preview is instant.
- Light mode. The mockups are dark; following the system appearance is fine.
- What input the summary model gets (a digest like `extract_digests.py` produces is the obvious
  choice, since a full transcript will not fit its context).
