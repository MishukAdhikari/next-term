# Next Term

A native macOS terminal for the AI era, in the spirit of the PhpStorm terminal.

Run Claude Code, Codex, a test suite and a dev server side by side, one per tab, and see at a glance
which ones are still working, which finished, which failed, and which are waiting for you.

- **Tabs that report status.** Every tab carries a status mark: a spinner while working, a green check
  when done, a red cross when a command failed, an amber "!" when a program asked for attention.
  It clears when you look at the tab.
- **Knows when an agent is waiting for you.** Agents like `claude` and `codex` never exit, so "done"
  means "stopped printing and wants your input". This works however you start them: directly, through an
  alias or a shell function, `npx`, or `cd app && claude`.
- **Projects.** Open a folder as a project (⌘O): its window keeps the project in the sidebar, and new tabs
  open in it by default. Open Recent, Close Project, and a Welcome window, like an IDE.
- **Project sidebar with git.** The project as a live file tree: changed files and folders coloured, with
  `+12 −3` line counts like a pull request, and the branch, total changes and ahead/behind at the top.
  Files your agents create or change show up on their own.
- **File operations.** Rename (Return), drag to move (Option to copy), New File / New Folder, Move to Trash,
  all undoable with ⌘Z. Drag a file onto a terminal to type its path.
- **Dock badge and notifications** for tabs that finished while you were in another app.
- **Native.** Swift and AppKit, universal (Apple Silicon and Intel): a 3 MB download, about 8 MB installed.
  macOS 13 or later.

## Install

Download `NextTerm-x.y.z.dmg` from [Releases](../../releases), open it, and drag **Next Term** to
Applications.

Releases are not notarized yet, so macOS blocks the first launch:

- **macOS 15 and later:** open Next Term once (it will be blocked), then go to **System Settings →
  Privacy & Security**, scroll down, click **Open Anyway** next to Next Term, and confirm.
- **macOS 13 and 14:** right-click Next Term in Applications, choose **Open**, then **Open** again.

Each release includes `NextTerm-x.y.z.dmg.sha256`. Check the download with `shasum -a 256 -c
NextTerm-x.y.z.dmg.sha256` before allowing it.

## Tab status

| Mark | Meaning |
|---|---|
| none | At the prompt, nothing new |
| spinner | A command is running, or an agent is printing |
| green ✓ | Finished successfully, or an agent stopped and is waiting for you |
| red ✕ | Exited with an error (the exit code is in the tooltip) |
| amber ! | The program rang the bell or sent a notification (OSC 9 / OSC 777) |

How it knows, most reliable first:

1. **zsh integration.** Next Term starts zsh with its own `ZDOTDIR` holding a tiny `.zshenv`. That file
   points `ZDOTDIR` back at your real config, loads your `.zshenv`, and adds `preexec`/`precmd` hooks that
   report each command (as typed and with aliases expanded), its exit code, the working directory and any
   suspended jobs. Your `.zprofile`, `.zshrc` and frameworks such as oh-my-zsh load exactly as before.
2. **Agents.** `claude`, `codex`, `gemini`, `aider`, `opencode` and friends stay in the foreground, so
   for them Next Term watches output: printing means working; 2.5 s of silence means waiting for you.
   Your own typing and window resizes don't count as work. When a command looks plain (a shell function),
   Next Term also asks the kernel what is really running.
3. **Other shells.** For bash and fish, or after `exec bash`, Next Term asks the kernel for the terminal's
   foreground process and working directory twice a second.

Interactive programs (`vim`, `ssh`, `less`, REPLs) are never reported as "done". Closing a tab or quitting
asks first if a program is running or a job is suspended (Ctrl-Z) or in the background, and names it.

## Keyboard

| Action | Keys |
|---|---|
| New tab (in the project, or the current tab's folder) | ⌘T |
| New window | ⌘N |
| Open project / Close project | ⌘O / Shell menu |
| Close tab | ⌘W |
| Select tab 1–8 / last tab | ⌘1…⌘8 / ⌘9 |
| Next / previous tab | ⌘⇧] / ⌘⇧[, Ctrl-Tab / Ctrl-Shift-Tab |
| Rename tab | ⌘⇧R, or double-click the tab |
| Project sidebar | ⌘B |
| Find / next / previous | ⌘F / ⌘G / ⌘⇧G |
| Clear | ⌘K |
| Font size | ⌘+ / ⌘- / ⌘0 |
| Option as Meta (for Emacs-style keys) | Shell menu, off by default |

In the sidebar: Return renames, ⌘⌫ moves to the Trash, ⌘↓ or double-click opens. Right-click for Open in
New Tab, Open as Project, Reveal in Finder, Insert Path in Terminal, Copy Path and Copy Relative Path. Tabs
can be dragged to reorder; middle-click closes; tabs that don't fit go behind the » button.

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
- **Git** runs read-only with `--no-optional-locks`, so the sidebar never holds the index lock while your
  own git commands run.

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
scripts/test.sh                          # unit tests: status, agents, git, file operations, quoting
python3 scripts/zsh-integration-test.py  # the shipped zsh hooks, in a real pty, with your zsh config
scripts/selftest.sh                      # end-to-end: drives the real app (opens a window)
```

The self-test opens real tabs and shells and checks every status transition, agent detection, jobs,
close confirmations, process cleanup, the security protections, projects, the sidebar with git, file
operations and undo, tab overflow and more, then writes a report and screenshots.

## Layout

```
Sources/NextTermCore/   platform-neutral logic, no AppKit: TabStatus, CommandClassifier, ShellIntegration,
                        Git (status parser and runner), FileTree and FileOps, ShellQuote, RecentProjects
Sources/NextTerm/       the macOS app: windows, tabs, sidebar, projects, menus, notifications, self-test
Tests/                  unit tests (swift-testing)
scripts/                build, test and icon scripts
```

`NextTermCore` has no AppKit dependency, so an iPad/iPhone app (SwiftTerm supports UIKit) or another
front end can reuse it.

## Roadmap

In progress: a code editor with syntax highlighting for many languages, a side-by-side diff view, find and
replace in files, sending a selection to the agent in a tab, and open-source file icons. Later: split panes,
session restore, settings, notarized releases. A Linux build would need a different UI layer (AppKit is
macOS-only); the core logic would carry over.

## Credits

Terminal emulation by [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (MIT).

## License

MIT. See [LICENSE](LICENSE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
