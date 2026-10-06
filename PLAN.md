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
| Terminal | Tabs (⌘T) with agent status in step with each agent's screen; decisions as notifications; dock badge; close and quit warnings; zsh integration; security (OSC 52, DECRQCRA, paste, links) |
| Projects | Open/close/recent, last projects reopened at launch, first-run folder choice; sidebar with git status and +/− per file and folder; file operations with undo; open-source icons with framework icons |
| Editor | 103 languages, incremental highlighting, line numbers, line height, soft wrap with hanging indent, auto-indent, ⌘/, ⌘L, find, encodings and line endings kept, files changed by agents reloaded |
| Search | Find/Replace in Files (regex, masks, preview, undo), seeded from the selection, same type first |
| Diffs | Side by side (⌘D), word highlights, all/unstaged/staged, stage/unstage/revert per hunk with blob checks, live refresh |
| Agents | Send to Agent (⌥⌘K) in each agent's syntax; Claude Code IDE link (live selection, @-mentions); Gemini CLI and Qwen Code IDE link (open files, selection), IDE mode on by default |
| App | `nxtrm` CLI, layouts (terminal on any side, sidebar left/right, ⋯ menus), Settings (editor, every shortcut), self-update from GitHub Releases (checksum-verified) |

## Next

1. **MCP tools for every agent** (Codex, Junie, Command Code, Cursor, opencode, Copilot, Amp…): a `next-term`
   MCP server with the editor's selection and open files, registered in each installed agent by default.
2. **Agents' proposed edits in the diff view:** Claude's openDiff and Gemini's openDiff shown there to accept
   or reject; fold long unchanged runs; stage selected lines.
3. **Copilot CLI IDE link** (its protocol is published).
4. Split panes, session restore, notarized releases.

## Verification

Every change runs three layers before it is committed:

- `scripts/test.sh`: unit tests (swift-testing) for everything in NextTermCore.
- `python3 scripts/zsh-integration-test.py`: the shipped zsh hooks in a real pty.
- `scripts/selftest.sh`: drives the real app end to end (tabs, shells, agents, editor, search, sidebar,
  layouts, shortcuts, the agent links with test clients), with screenshots. Keys typed on the Mac while
  it runs can land in its window; rerun before blaming the code.

CI (macos-15) runs the unit and zsh tests and builds the DMG; a `v*` tag publishes a GitHub Release.
