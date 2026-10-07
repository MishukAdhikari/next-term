# Next Term — plan

A native macOS terminal and editor, built for running AI agents side by side: the missing IDE for the
terminal. This file is the map of what is built and what comes next; the README describes it for users.

## Decisions

- **Native:** Swift + AppKit, SwiftPM with only the Command Line Tools, macOS 13+, universal. Terminal
  emulation by SwiftTerm; logic that needs no UI lives in `NextTermCore` and is unit-tested.
- **Open, licence-clean dependencies only:** SwiftTerm (MIT), shiki-swift (MIT) with curated TextMate
  grammars (`scripts/update-highlighting.py` ships only MIT/Apache/BSD/MPL/TextMate-permissive ones),
  Material Icon Theme (MIT) drawn with SwiftDraw (zlib). No GPL, nothing without a licence.
- **Agents first:** status follows the agent's own screen where its hints are known, and output timing
  elsewhere; the editor talks to agents through their own protocols where they have one, and through
  Send to Agent everywhere else.
- **Safe by default:** every local server binds 127.0.0.1 with a fresh token per launch and refuses
  browsers; files are written atomically keeping permissions; nothing reads named pipes; git never takes
  the index lock.
- **Its own thing:** not modelled on any one IDE; we pick what works best.
- **Not notarized:** the source is public and releases are built by CI from it. The disk image's first
  launch is allowed once with Open Anyway; the one-line installer checks a signed checksum instead.

## Built

Through 0.9.0, by release.

| Release | What |
|---|---|
| 0.1.0 | Tabs with agent status in step with each agent's screen; decisions as notifications; dock badge; close and quit warnings; zsh integration; terminal security (OSC 52, DECRQCRA, paste, links). Projects and a sidebar with git status and +/− per file and folder; file operations with undo. The editor with syntax highlighting, soft wrap, find; Find/Replace in Files (regex, masks, preview, undo). `nxtrm`, layouts, ⋯ menus, every shortcut changeable, self-update from GitHub Releases (checksum-verified) |
| 0.2.0 | Claude Code IDE link (live selection, @-mentions, proposed edits as diffs to accept or reject); Gemini CLI and Qwen Code IDE link (open files, selection), IDE mode on by default; side-by-side diffs (⌥⌘G) with stage/unstage/revert per hunk; Send to Agent (⌥⌘K) in each agent's syntax; 103 languages; open-source file icons; line height and a Settings window; tabs that start without the launcher's session markers and secrets |
| 0.3.0 | `nxtrm mcp`: projects and tabs with agent state, new tabs and agents, prompts, keys, waiting, reading screens, the editor; registered in Claude Code, Codex, Gemini, Qwen, Cursor, opencode, Copilot, Amp, Junie and Command Code. Split panes (⌘D, ⌘⇧D, ⌥⌘arrows, ⌘⇧↩). Go to File (⌘P). The website |
| 0.4.0 | Claude Code, Codex and Command Code sessions per project (subfolders included) on the Welcome window and ⌥⌘O, resumed or forked in a tab in their folder, titles scrubbed of secrets; change marks in the gutter; the terminal folds away (⌘J); ⌘P starts from the selection |
| 0.5.0 | Import from VS Code, Cursor, Devin Desktop, JetBrains IDEs, Zed and iTerm2, previewed and undone in one click; VS Code and JetBrains shortcut sets; the sidebar follows the open file |
| 0.6.0 | Remote tabs over the system ssh (⌥⌘T), kept in tmux or herdr, with the same status marks and seven MCP tools for hosts; the update window (notes, Remind Me Later, Skip); deleted files keep their rows; each tab shows its shortcut; prompt placeholders, TOML and `.env` keys coloured; RAG platform keys scrubbed from titles and imports |
| 0.7.0 | The branch popup (⌥⌘B): checkout with stash-switch, new/rename/delete with Undo, update, merge, rebase, commit, push, the git command log; read-only Jupyter notebooks; Jinja and Mustache inside Python strings; Prompty, requirements, Mermaid, Cypher, SPARQL, Turtle, reStructuredText and TSV (112 languages); your own VS Code and JetBrains keys in the import; Python traceback and `graph.py:graph` links; tabs that show a dev server's port; ML and agent state folders skipped |
| 0.8.0 | Databases a project names, in the sidebar (Laravel/Herd, `DATABASE_URL` and family, Prisma, Drizzle, Supabase, Vercel, SQLite), passwords masked; a read-only SQLite viewer; hand-offs to TablePlus, mysql and psql. Five more MCP tools (18): `answer_agent`, `read_file`, `find_in_files`, `git_status`, `get_diff`. The one-line installer with a signed checksum |
| 0.9.0 | The Git Log (⌥⌘L): the history as a graph, filters, the selected commit and its diffs. Git blame in the editor. A read-only head view for large JSON Lines, CSV and TSV files. The editor's and terminal's fonts, and terminal colours of your own. Fonts and terminal colours in the import, and imports from more terminals, Ghostty and Terminal among them. Pull and Push in the sidebar header. ⌘P stays Go to File under the JetBrains keys |

## Next

1. **More agents' sessions:** Gemini CLI and opencode first, then Copilot CLI and Cursor (formats in
   claudedocs/research_next-term-agent-sessions); a sessions group in the sidebar, "Continue latest", a
   running badge for Codex, and "go to tab" for a session already open in Next Term.
2. **A server's files in the editor and sidebar,** next to its remote tabs: SFTP over the shared ssh
   connection, then remote git, search and the IDE link; passwords and new host keys in a native sheet
   (an askpass helper, shared with git). Research: claudedocs/research_next-term-remote-dev.
3. **Dev Containers.**
4. **Remote MCP access** for agents outside this Mac (ChatGPT, Claude on the web), through a tunnel with
   an explicit security model (Streamable HTTP, OAuth, a consent sheet). On hold until it is decided.

Also next, in no fixed order:

- **Agents:** an IDE link for Copilot CLI, and opencode's accepted through a peer-process check; tab
  status hints for Junie, opencode, Copilot CLI, Amp and Cursor; Claude Desktop and the ChatGPT desktop
  app on the local MCP server.
- **MCP:** tools that propose edits, change settings, commit and control panes, once there is a consent
  model.
- **Git:** Delete on Remote, Checkout and Update, and Write with Agent in the branch popup; then
  worktrees and Clean Up; Compare with Current and Show Diff with Working Tree; background fetch; a
  match-case toggle in the Git Log.
- **Diffs:** fold long unchanged runs, a Changed only filter, stage selected lines, edit the proposed
  side before accepting, Send to Agent from a diff, and Ask agent… per hunk.
- **Editor:** Replace in the open file from the menu; opening files with a single click (off by default);
  hiding `.env` values on screen; a prompt-text grammar for `prompts/*.txt`; `{var}` placeholders in YAML
  and TypeScript strings; LangGraph Studio links in a Chromium browser when Safari is the default.
- **Settings and import:** the keys Settings cannot change yet (⌘↩ Accept, the sidebar's ↩, ⌘⌫ and ⌘↓,
  ↩ in the Git Log); Zed's own `keymap.json` in the import; a hand-off to an agent for what the import
  leaves out.
- **App:** a mark on each tab that says whether it is remote or local; `nxtrm` linked on first launch on
  a stock Mac; `strip -x` in the DMG build.

Later: session restore, and a Linux build (AppKit is macOS-only; `NextTermCore` would carry over).

## Verification

Every change runs three layers before it is committed:

- `scripts/test.sh`: unit tests (swift-testing) for everything in NextTermCore.
- `python3 scripts/zsh-integration-test.py`: the shipped zsh hooks in a real pty.
- `scripts/selftest.sh`: drives the real app end to end (tabs, shells, agents, editor, search, sidebar,
  layouts, shortcuts, the agent links with test clients), with screenshots. Keys typed on the Mac while
  it runs can land in its window; rerun before blaming the code.

CI (macos-15) runs the unit and zsh tests and builds the DMG; a `v*` tag publishes a GitHub Release.
