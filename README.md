# Next Term

**The missing IDE for the terminal.**

A native macOS terminal and editor for the AI era. Run Claude Code, Codex,
Command Code, Junie, a test suite and a dev server side by side, one per tab, and see at a glance which
agents are working, which are done, and which are waiting on your decision.

**[Download for macOS](https://github.com/MishukAdhikari/next-term/releases/latest/download/NextTerm.dmg)** ·
website and documentation: **[next-term.mishuk.me](https://next-term.mishuk.me)**

- **Agent status, in step with the agent.** A spinner shows while an agent is working, read from the
  agent's own screen ("esc to interrupt") for Claude Code, Codex, Command Code and Gemini CLI, so it stops
  the moment they stop; other agents go by output timing. A green check means done and waiting for your
  next prompt, an amber "!" means it is asking you something. Plain commands show no spinner and end
  with a check or a red cross. Marks clear when you look at the tab.
- **Decisions come to you.** When an agent asks for permission ("Do you want to make this edit…?"),
  a notification says so with the question; click it to land on that tab. Works however you start the
  agent: directly, through an alias or a shell function, `npx`, or `cd app && claude`.
- **Code editor.** Double-click a file (or click once, with a setting), pick a Find in Files result, or
  ⌘-click `src/app.ts:42:7` in any output: the file opens above the terminal at that line, coloured by
  112 TextMate grammars, the kind VS Code uses: PHP and Blade (Laravel, WordPress), Ruby and ERB (Rails),
  Python and Jinja (Django, Flask), JS/TS/TSX (React, Next.js), Vue, Svelte, Astro, Angular, Liquid, Twig,
  Go and templ, Rust, Elixir, YAML, SQL and more. Line numbers, adjustable line height, soft wrap, auto-indent, ⌘/ to comment, ⌘L to go to a line, find, undo. Files keep
  their encoding, line endings and permissions. When an agent changes a file you have open, the editor
  follows; if you have unsaved edits it asks first.
- **Jupyter notebooks, read-only.** A `.ipynb` opens as cells: Markdown laid out, code coloured in the
  kernel's language, and the outputs saved in the file (text, tables as text, images and errors). Nothing
  runs (there is no kernel); Open as JSON shows the file itself.
- **Large data files.** A JSON Lines, CSV or TSV file over 2 MB opens in a read-only head view: its first
  1,000 rows as a table, as fast for a 2 GB file as for a small one, with Load More, search and Copy As.
  Logs and other text files over 32 MB open there too.
- **Send to Agent (⌥⌘K).** Select code in the editor or a diff, or files and folders in the sidebar, and send
  them to the agent in your tab: Next Term types the reference in that agent's own syntax (`@app/User.php#L10-20`
  for Claude, `app/User.php:10-20` for Codex and others) and hands you the prompt to add your instruction. It
  never presses Enter for you.
- **Agents see your editor.** Claude Code, Gemini CLI and Qwen Code in a Next Term tab connect to Next Term
  as their IDE, the way they connect to VS Code: the lines you select go with your next prompt ("⧉ 10 lines
  selected"), and ⌥⌘K puts `@file#L10-20` into Claude's prompt. When Claude wants to edit a file, its change
  opens as a diff to Accept (⌘↩) or Reject, as in VS Code; answering in the terminal works too. Nothing to set up: Next Term turns Gemini's
  and Qwen's IDE mode on for you. Local only, with a fresh secret per launch; `.env` files are never shared;
  Settings turns it off.
- **Orchestrate agents across projects (MCP).** Next Term is an MCP server for any agent: Claude Code,
  Codex, Gemini CLI, Qwen Code, Cursor, opencode, Copilot CLI, Amp, Junie and Command Code. One agent can
  run the others. It sees every project and tab with each agent's state (working, done, waiting for a
  decision and the question), opens projects, starts an agent in a new tab, gives it a prompt, waits
  until it stops, reads its screen, answers its questions (only the question it saw, never a newer one),
  reads the projects' files, searches them and sees their git status and diffs (secrets files refused,
  secret-looking values masked), and uses the editor (the selection, open files, opening a file at a
  line). Next Term adds itself to the agents it finds, with nothing to run; Settings turns it off and
  removes it again. The tools are marked honestly, so agents ask you before they type into a tab. Local
  only: a private socket, no network port.
- **Pick up any agent's conversation.** The Welcome window lists your projects; choose one and every
  conversation Claude Code, Codex and Command Code kept for it is there, newest first, with its title,
  branch and model, including the ones started in its subfolders. Resume runs it again in a new tab, in
  the folder it was started in; Fork continues a copy. In a project window, ⌥⌘O does the same. Only titles
  and dates are read (never whole transcripts), secrets are scrubbed from titles, and nothing is written.
- **Remote tabs on your servers.** Shell › New Remote Tab… (⌥⌘T) opens a tab on your VPS over your own ssh
  and `~/.ssh/config`. With tmux or herdr on the server, agents keep working while the Mac sleeps or is off,
  and the tab reattaches when it reconnects. Host keys are never accepted silently, nothing is installed on
  the server, and no password is stored. Agents get seven MCP tools to open tabs there and read the changes.
- **`nxtrm`, like `code`.** `nxtrm .` opens the folder as a project, `nxtrm app/User.php:42` a
  file at a line. It works in every Next Term tab from the first launch, and in other terminals too: the
  first launch links it into a folder on your PATH that needs no password (`~/.local/bin`,
  `/opt/homebrew/bin`), or, when there is none, offers to put it in `/usr/local/bin` with your password.
  It never changes PATH or touches anyone else's `nxtrm`.
- **Your layout.** The terminal below the editor (default), beside it on the right or left, or above it;
  the project sidebar on the left or right. From the ⋯ buttons or the View menu. ⌘J folds the terminal
  away so the editor gets the room, and brings it back at its size.
- **Projects.** Open a folder as a project (⌘O): its window keeps the project in the sidebar, and new tabs
  open in it by default. Next Term reopens your last projects at launch (on first launch it asks for a
  folder). Open Recent, Close Project, and a Welcome window, like an IDE.
- **Project sidebar with git.** The project as a live file tree: changed files and folders coloured, with
  `+12 −3` line counts like a pull request, and the branch and total changes at the top, with a **Pull 152**
  button when the upstream has commits you don't (Next Term fetches every 10 minutes, so it appears
  without a click).
  Files your agents create or change show up on their own.
- **Databases.** A Databases group in the sidebar lists the databases a project's own files name (Laravel
  and Herd `DB_*` keys, `DATABASE_URL`, Prisma, Drizzle, Supabase, Vercel-linked projects, SQLite files),
  found by reading them, without running project code; local or remote by host, passwords masked. SQLite
  files open in a read-only viewer; other connections open in TablePlus when it is installed (libSQL
  aside), and local and development ones (Docker, OrbStack) in `mysql` or `psql` in a new tab.
- **Branches in one popup.** Click the branch (⌥⌘B): search branches and actions, check out, branch,
  update, commit, push, rebase and merge. It asks before changing files under a working agent, keeps
  uncommitted changes in a named stash, and logs every git command exactly as typed (Git › Git Commands).
- **Git Log.** The commit history as a graph in an editor tab (⌥⌘L): lanes per line of history, branch
  and tag badges, filters by branch, author, date, paths and message or hash, and each commit's changed
  files, with a double-click for a file's diff in that commit. It follows the repository as agents commit.
- **Git blame.** View › Annotate with Git Blame shows who last changed each line, how long ago and the
  commit, beside the line numbers; click to see that commit in the Git Log. View › Current Line Blame
  adds a note after the line with the caret.
- **Changes in the gutter.** A bar beside the line numbers marks the lines added (green) or changed (blue)
  since the last commit, and a red wedge where lines were deleted, as you type or an agent writes. Click a
  mark for the file's changes side by side.
- **Split panes.** Split any tab right (⌘D) or down (⌘⇧D), as often as you like: an agent beside its
  test run, two agents side by side. Move between panes with ⌥⌘ and the arrows, maximize one with
  ⌘⇧↩, close it with ⌘W. The panes without the keyboard are shaded, and the tab's mark shows the pane
  that most needs you.
- **Changes side by side (⌥⌘G).** A file's diff in a tab: the old version beside the new, rows aligned, the
  changed words marked, syntax-coloured, scrolling together. All changes, unstaged or staged; step through
  them and stage, unstage or revert one hunk at a time (⌘Z undoes a revert). Each action first checks the
  file is still what the diff showed, so a change an agent made meanwhile is never overwritten.
- **File operations.** Rename (Return), drag to move (Option to copy), New File / New Folder, Move to Trash,
  all undoable with ⌘Z. Drag a file onto a terminal to type its path.
- **Go to File (⌘P).** Type a few letters of a file's name or path and the list follows every keystroke:
  `usrctl` finds `UserController.php`; a whole file name, the start of a word and runs of letters rank
  first, and files you opened lately come first. `name:42` opens it at line 42. Instant on large
  projects (git's file list, searched off the main thread).
- **Find and Replace in Files** (⌘⇧F / ⌘⇧R) across the project, with regular expressions, file masks and
  a preview of every replacement; a file an agent changed since the search is never overwritten.
- **Dock badge and notifications** for agents that finished, in another app or in a tab you are not
  looking at, and for commands that finished while you were in another app. Settings > Notifications
  chooses which ones notify, after how long, and with or without a sound.
- **Every menu shortcut is yours.** Next Term > Settings (⌘,) > Keyboard Shortcuts lists every menu
  command; click one and press new keys. The shortcuts below are the defaults.
- **Bring your settings over.** Coming from VS Code, Cursor, Devin Desktop, a JetBrains IDE, Zed, iTerm2,
  Ghostty or Terminal? Next Term > Import Settings and Shortcuts… (also offered on first launch) brings
  the matching shortcut set, the keys you changed yourself, font size, line height, wrap, fonts, terminal
  colours and recent projects. Nothing changes unless you choose it: the preview shows every item as a
  checkbox, and what it leaves out and why; Undo Import puts it all back. It only reads, on this Mac, and
  never opens files that can hold secrets. See
  [Switching to Next Term](https://next-term.mishuk.me/docs/switching/).
- **Updates in one click.** Next Term checks GitHub Releases once a day (or Check for Updates). A new
  version opens a window with what's new (Install, Remind Me Later or Skip This Version), and a blue
  Update button at the top right brings it back. It downloads, is checked against its checksum signed
  with the Next Term release key, and replaces the app when you relaunch.
- **Native.** Swift and AppKit, universal (Apple Silicon and Intel): about 16 MB to download, 43 MB
  installed. macOS 13 or later.

## Install

In one line, from the terminal:

```sh
curl -fsSL https://next-term.mishuk.me/install.sh | bash
```

It downloads the latest release, checks its SHA-256, the bundle and the signature, and copies it to
Applications. When a folder on your PATH takes `nxtrm` without a password, it links it there too;
otherwise Next Term offers it when it opens. It never uses `sudo`, and macOS doesn't ask you to allow the
first launch ([the script](site/src/install.sh)). Or
download `NextTerm-x.y.z.dmg` from [Releases](../../releases), open it, and drag **Next Term** to
Applications. After that, Next Term updates itself (Next Term > Check for Updates).

Next Term is not notarized by Apple, so with the disk image macOS blocks the first launch. Allow it once:

- **macOS 15 and later:** open Next Term once (it will be blocked), then go to **System Settings →
  Privacy & Security**, scroll down, click **Open Anyway** next to Next Term, and confirm.
- **macOS 13 and 14:** right-click Next Term in Applications, choose **Open**, then **Open** again.

Each release includes `NextTerm-x.y.z.dmg.sha256`. Check the download with `shasum -a 256 -c
NextTerm-x.y.z.dmg.sha256` before allowing it.

## Tab status

| Mark | Meaning |
|---|---|
| none | At the prompt, or a plain command running |
| spinner | An AI agent is working |
| green ✓ | An agent stopped and is waiting for your next prompt, or a command finished |
| amber ! | An agent is waiting on your decision (the question is in the tooltip), or a program rang the bell |
| red ✕ | A command exited with an error (the exit code is in the tooltip) |

How it knows, most reliable first:

1. **zsh integration.** Next Term starts zsh with its own `ZDOTDIR` holding a tiny `.zshenv`. That file
   points `ZDOTDIR` back at your real config, loads your `.zshenv`, and adds `preexec`/`precmd` hooks that
   report each command (as typed and with aliases expanded), its exit code, the working directory and any
   suspended jobs. Your `.zprofile`, `.zshrc` and frameworks such as oh-my-zsh load exactly as before.
2. **Agents.** `claude`, `codex`, `commandcode`, `gemini` and other agents stay in the foreground, so
   Next Term reads the agent's own screen, the way you would: "esc to interrupt" means working, a question
   with choices means it is waiting on you, anything else means idle. These hints are checked against
   Claude Code, Codex, Command Code and Gemini CLI. Other agents (Junie, opencode, Qwen Code and the rest)
   go by output timing until their screen shows one of them: printing means working, 2.5 s of silence
   means done. When a command looks plain (a shell function), Next Term also asks the kernel what is
   really running.
3. **Other shells.** For bash and fish, or after `exec bash`, Next Term asks the kernel for the terminal's
   foreground process and working directory twice a second.

Interactive programs (`vim`, `ssh`, `less`, REPLs) are never reported as "done". Closing a tab or quitting
asks first if a program is running or a job is suspended (Ctrl-Z) or in the background, and names it.

## Keyboard

| Action | Keys |
|---|---|
| New tab (in the project, or the current tab's folder) | ⌘T |
| New window | ⌘N |
| New remote tab (on one of your servers) | ⌥⌘T |
| Open project / Close project | ⌘O / Shell menu |
| Go to File (`name` or `name:line`) | ⌘P |
| Resume an agent session (↩ resume, ⌘↩ fork) | ⌥⌘O |
| Close tab (or the focused pane in a split tab) | ⌘W |
| Split right / split down | ⌘D / ⌘⇧D |
| Move between panes | ⌥⌘← ⌥⌘→ ⌥⌘↑ ⌥⌘↓, or ⌥⌘] / ⌥⌘[ in turn |
| Maximize the pane (and back) | ⌘⇧↩ |
| Select tab 1–8 / last tab | ⌘1…⌘8 / ⌘9 |
| Next / previous tab | ⌘⇧] / ⌘⇧[, Ctrl-Tab / Ctrl-Shift-Tab |
| Rename tab | ⌥⌘R, or double-click the tab |
| Project sidebar | ⌘B |
| Fold the terminal away (and back) | ⌘J |
| Find / next / previous | ⌘F / ⌘G / ⌘⇧G |
| Use the selection for Find | ⌘E |
| Replace in the open file | ⌥⌘F |
| Find in Files / Replace in Files | ⌘⇧F / ⌘⇧R |
| Clear | ⌘K |
| Font size | ⌘+ / ⌘- / ⌘0 |
| Option as Meta (for Emacs-style keys) | Shell menu, off by default |
| Save / Save All | ⌘S / ⌥⌘S |
| Close the file being edited | ⌘W (with the editor focused) |
| Comment line / Go to line | ⌘/ / ⌘L |
| Show changes (side by side) | ⌥⌘G |
| Branches (the branch popup) | ⌥⌘B |
| Git Log (the commit graph) | ⌥⌘L |
| Send to Agent | ⌥⌘K |
| Indent / Outdent | ⌘] / ⌘[ (Tab / ⇧Tab on selected lines) |
| Between editor and terminal | ⌃` |
| Keyboard Shortcuts (change any menu shortcut) | ⌘, |

In the sidebar: Return renames, ⌘⌫ moves to the Trash, ⌘↓ or double-click opens (or one click: Settings ›
Editor › Open files with a single click). Right-click for Open in New Tab, Open as Project, Reveal in Finder,
Insert Path in Terminal, Copy Path and Copy Relative Path. Tabs can be dragged to reorder; middle-click
closes; tabs that don't fit go behind the » button.

## Security

- **Clipboard:** programs can copy to the clipboard (OSC 52) only from the tab you are looking at, and can
  never read it, so a remote host over ssh cannot harvest what you copied. ⌘V strips control characters.
- **Screen contents** cannot be read back through terminal queries (DECRQCRA answers are blanked).
- **Status marks** from the shell carry a random per-tab secret that programs never see, so output (a
  `cat` of a log, a remote host) cannot fake "command finished" and skip the close confirmation.
- **Paths you drop or insert** are quoted so that no file name can run a command, even one containing
  control characters, and are sent as a bracketed paste.
- **Opening files** from the sidebar or with ⌘-click asks first when the file is an app, a script or an
  executable, including behind a symlink or a Finder alias (cloned repos carry no quarantine flag, so
  Gatekeeper would not ask). Links other than http, https, mailto and local files are refused.
- **The MCP server** listens on a Unix socket only you can open (0600, and each connection is checked to
  be yours), never on the network. Agents reach it through `nxtrm mcp`, which they start themselves.
  Tabs refuse input from their own agent, and a tab running something closes only when told to force it.
- **Git:** the sidebar reads status with read-only calls and `--no-optional-locks`, so it never holds the
  index lock while your own git commands run. On its own, Next Term only runs `git fetch`: every 10 minutes
  while it is the active app, and as the branch popup opens if the last fetch is over 5 minutes old. That
  updates remote-tracking branches and tags, never your branches, files or index, and Settings › Editor ›
  Git turns it off. Everything else runs only when you ask: checkout, merge, rebase, commit, push, stash,
  the sidebar's Pull and Push, and staging a hunk. Next Term asks first when an agent is working in the
  folder, puts changes a switch would overwrite in a named stash, and force-pushes only with a lease on the
  commits it showed you, never to `main`, `master`, `release/*` or the default branch `<remote>/HEAD` names.

## Build from source

Needs macOS 13+ and Swift 6 (the Xcode Command Line Tools are enough; full Xcode is not required).

```sh
git clone https://github.com/MishukAdhikari/next-term.git
cd next-term
swift run NextTerm            # run a debug build
scripts/build-dmg.sh          # universal app + DMG + checksum in dist/
```

To sign and notarize for distribution:
`SIGN_ID="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=<notarytool profile> scripts/build-dmg.sh`.

## Tests

```sh
scripts/test.sh                          # unit tests: status, agents, git, files, editor, nxtrm, shortcuts, updates
python3 scripts/zsh-integration-test.py  # the shipped zsh hooks, in a real pty, with your zsh config
scripts/selftest.sh                      # end-to-end: drives the real app (opens a window)
```

The self-test opens real tabs and shells and checks every status transition, agent detection, jobs,
close confirmations, process cleanup, the security protections, projects, the sidebar with git, file
operations and undo, tab overflow, the editor (colours, editing, saving, files changed by agents, long
files), layouts, nxtrm, shortcuts, the agent links and the MCP server (driven through `nxtrm mcp` as an
agent would), then writes a report and screenshots.

## Layout

```
Sources/NextTermCore/   platform-neutral logic, no AppKit: TabStatus, AgentScreen, CommandClassifier,
                        ShellIntegration, Git, CommitLog and CommitGraph, Diff, HunkOps, FileTree and
                        FileOps, ProjectSearch, TextFile and LineIndex, EditorLanguage, CommandLineOpen,
                        KeyChord, Updates, MCPServer, MCPProjectTools, MCPRedaction and MCPRegistrar (the
                        agent-facing MCP server, its file, search and git tools with their path and secrets
                        rules, and its registration in each agent)
Sources/NextTerm/       the macOS app: windows, tabs, sidebar, editor, projects, menus, shortcuts, updates,
                        notifications, self-test
Resources/Highlighting/ the shipped grammars (scripts/update-highlighting.py) and the Next Dark theme
Tests/                  unit tests (swift-testing)
scripts/                build, test and icon scripts
```

`NextTermCore` has no AppKit dependency, so another front end can reuse it. An iPad or iPhone app
(SwiftTerm supports UIKit) could reuse most of it, but not as it is: it runs git with Foundation's
`Process` and finds the home folder with `homeDirectoryForCurrentUser`, and iOS has neither.

## Roadmap

Next: sessions from more agents (Gemini CLI, opencode, Copilot CLI, Cursor). Then a server's files in
the editor and sidebar next to its remote tabs, then Dev Containers. Later: more of the diff view, a
Copilot CLI IDE link and session restore. A Linux build would need a different UI layer (AppKit is
macOS-only); the core logic would carry over.

## Credits

Terminal emulation by [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (MIT). Syntax highlighting by
[shiki-swift](https://github.com/fayazara/shiki-swift) (MIT) with Oniguruma (BSD), using TextMate grammars from
[shikijs/textmate-grammars-themes](https://github.com/shikijs/textmate-grammars-themes), each under its own
permissive licence ([list](Resources/Highlighting/GRAMMARS.md)). File icons from the
[Material Icon Theme](https://github.com/material-extensions/vscode-material-icon-theme) (MIT), whose icons
draw on Pictogrammers' Material Design Icons and Google's Material Symbols (Apache 2.0), rendered with
[SwiftDraw](https://github.com/swhitty/SwiftDraw) (zlib).

## License

MIT. See [LICENSE](LICENSE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
