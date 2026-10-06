# Next Term — plan

A native macOS terminal and editor, built for running AI agents side by side: the missing IDE for the
terminal. This file is the map of what is built and what comes next; the README describes it for users.

## Decisions

- **Native:** Swift + AppKit, SwiftPM with only the Command Line Tools, macOS 13+, universal. Terminal
  emulation by SwiftTerm; logic that needs no UI lives in `NextTermCore` and is unit-tested.
- **Open, licence-clean dependencies only:** SwiftTerm (MIT), shiki-swift (MIT) with curated TextMate
  grammars (`scripts/update-highlighting.py` ships only MIT/Apache/BSD/MPL/TextMate-permissive ones),
  Material Icon Theme (MIT) drawn with SwiftDraw (zlib). No GPL, nothing without a licence.
- **Agents first:** status follows the agent's own screen; the editor talks to agents through their own
  protocols where they have one, and through Send to Agent everywhere else.
- **Safe by default:** every local server binds 127.0.0.1 with a fresh token per launch and refuses
  browsers; files are written atomically keeping permissions; nothing reads named pipes; git never takes
  the index lock.
- **Its own thing:** not modelled on any one IDE; we pick what works best.

## Built

| Area | What |
|---|---|
| Terminal | Tabs (⌘T) and split panes (⌘D, ⌘⇧D, ⌥⌘arrows, ⌘⇧↩) with agent status in step with each agent's screen; decisions as notifications; dock badge; close and quit warnings; zsh integration; security (OSC 52, DECRQCRA, paste, links) |
| Projects | Open/close/recent, last projects reopened at launch, first-run folder choice; sidebar with git status and +/− per file and folder; file operations with undo; open-source icons with framework icons |
| Editor | 103 languages, incremental highlighting, line numbers, line height, soft wrap with hanging indent, auto-indent, ⌘/, ⌘L, find, encodings and line endings kept, files changed by agents reloaded |
| Search | Find/Replace in Files (regex, masks, preview, undo), seeded from the selection, same type first |
| Diffs | Side by side (⌥⌘G), word highlights, all/unstaged/staged, stage/unstage/revert per hunk with blob checks, live refresh |
| Agents | Send to Agent (⌥⌘K) in each agent's syntax; Claude Code IDE link (live selection, @-mentions, proposed edits as diffs to accept or reject); Gemini CLI and Qwen Code IDE link (open files, selection), IDE mode on by default |
| MCP | `nxtrm mcp` for any agent: projects and tabs with agent state, new tabs and agents, prompts, keys, waiting, reading screens, the editor; registered in Claude Code, Codex, Gemini, Qwen, Cursor, opencode, Copilot, Amp, Junie and Command Code by default |
| App | `nxtrm` CLI, layouts (terminal on any side, sidebar left/right, ⋯ menus), Settings (editor, every shortcut), self-update from GitHub Releases (checksum-verified) |

## Next

1. **Go to File (⌘P):** fuzzy file search across the project, instant on large repos.
2. **Agent sessions per project** on the Welcome screen and in the sidebar (Claude, Codex, Command Code
   first): resume or fork in one click (research: claudedocs/research_next-term-agent-sessions).
3. **Remote development** over the system ssh (one shared connection per host, SFTP for files, remote
   tabs with the shell integration), then Dev Containers (research: claudedocs/research_next-term-remote-dev).
4. **Remote MCP link** for agents outside this Mac (ChatGPT, Claude), with an explicit security model.
5. **More of the diff view:** fold long unchanged runs, stage selected lines, edit the proposed side
   before accepting. Copilot CLI IDE link. Session restore, notarized releases.

## Verification

Every change runs three layers before it is committed:

- `scripts/test.sh`: unit tests (swift-testing) for everything in NextTermCore.
- `python3 scripts/zsh-integration-test.py`: the shipped zsh hooks in a real pty.
- `scripts/selftest.sh`: drives the real app end to end (tabs, shells, agents, editor, search, sidebar,
  layouts, shortcuts, the agent links with test clients), with screenshots. Keys typed on the Mac while
  it runs can land in its window; rerun before blaming the code.

CI (macos-15) runs the unit and zsh tests and builds the DMG; a `v*` tag publishes a GitHub Release.
