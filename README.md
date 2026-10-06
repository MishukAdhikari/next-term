# Next Term

**The missing IDE for the terminal.**

A native macOS terminal for the AI era, in the spirit of the PhpStorm terminal. Run Claude Code, Codex,
Command Code, Junie, a test suite and a dev server side by side, one per tab, and see at a glance which
agents are working, which are done, and which are waiting on your decision.

- **Agent status, in step with the agent.** A spinner shows only while an agent is really working, read
  from the agent's own screen ("esc to interrupt"), so it stops the moment Claude or Codex stops. A green
  check means done and waiting for your next prompt, an amber "!" means it is asking you something.
  Plain commands show no spinner and end with a check or a red cross. Marks clear when you look at the tab.
- **Decisions come to you.** When an agent asks for permission ("Do you want to make this edit…?"),
  a notification says so with the question; click it to land on that tab. Works however you start the
  agent: directly, through an alias or a shell function, `npx`, or `cd app && claude`.
- **Code editor.** Double-click a file, pick a Find in Files result, or ⌘-click `src/app.ts:42:7` in any
  output: the file opens above the terminal at that line, coloured by VS Code's TextMate grammars (the
  family Sublime Text uses) for 77 languages, Blade and PHP, TSX, Vue, Svelte, Python, Go, Rust, YAML and SQL
  among them. Line numbers, soft wrap, auto-indent, ⌘/ to comment, ⌘L to go to a line, find, undo. Files keep
  their encoding, line endings and permissions. When an agent changes a file you have open, the editor
  follows; if you have unsaved edits it asks first.
- **`nxtrm`, like `subl` or `code`.** `nxtrm .` opens the folder as a project, `nxtrm app/User.php:42` a
  file at a line. It works in every Next Term tab from the first launch; Next Term > Install Command Line
  Tool adds it to other terminals.
- **Your layout.** The terminal below the editor (default), beside it on the right or left, or above it;
  the project sidebar on the left or right. From the ⋯ buttons or the View menu.
- **Projects.** Open a folder as a project (⌘O): its window keeps the project in the sidebar, and new tabs
  open in it by default. Next Term reopens your last projects at launch (on first launch it asks for a
  folder). Open Recent, Close Project, and a Welcome window, like an IDE.
- **Project sidebar with git.** The project as a live file tree: changed files and folders coloured, with
  `+12 −3` line counts like a pull request, and the branch, total changes and ahead/behind at the top.
  Files your agents create or change show up on their own.
- **File operations.** Rename (Return), drag to move (Option to copy), New File / New Folder, Move to Trash,
  all undoable with ⌘Z. Drag a file onto a terminal to type its path.
- **Find and Replace in Files** (⌘⇧F / ⌘⇧R) across the project, with regular expressions, file masks and
  a preview of every replacement; a file an agent changed since the search is never overwritten.
- **Dock badge and notifications** for agents that finished while you were in another app.
- **Every shortcut is yours.** Next Term > Keyboard Shortcuts (⌘,) lists every command; click one and press
  new keys. The shortcuts below are the defaults.
- **Updates in one click.** Next Term checks GitHub Releases once a day (or Check for Updates). A new
  version downloads, is verified against its published SHA-256, and replaces the app when you relaunch.
- **Native.** Swift and AppKit, universal (Apple Silicon and Intel): a 3 MB download, about 8 MB installed.
  macOS 13 or later.

## Install

Download `NextTerm-x.y.z.dmg` from [Releases](../../releases), open it, and drag **Next Term** to
Applications. After that, Next Term updates itself (Next Term > Check for Updates).

Releases are not notarized yet, so macOS blocks the first launch:

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
2. **Agents.** `claude`, `codex`, `commandcode`, `junie`, `gemini`, `aider`, `opencode` and friends stay
   in the foreground, so Next Term reads the agent's own screen, the way you would: "esc to interrupt"
   means working, a question with choices means it is waiting on you, anything else means idle. For an
   agent whose screen it does not recognise yet, it falls back to output timing (printing means working,
   2.5 s of silence means done). When a command looks plain (a shell function), Next Term also asks the
   kernel what is really running.
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
| Rename tab | ⌥⌘R, or double-click the tab |
| Project sidebar | ⌘B |
| Find / next / previous | ⌘F / ⌘G / ⌘⇧G |
| Find in Files / Replace in Files | ⌘⇧F / ⌘⇧R |
| Clear | ⌘K |
| Font size | ⌘+ / ⌘- / ⌘0 |
| Option as Meta (for Emacs-style keys) | Shell menu, off by default |
| Save / Save All | ⌘S / ⌥⌘S |
| Close the file being edited | ⌘W (with the editor focused) |
| Comment line / Go to line | ⌘/ / ⌘L |
| Indent / Outdent | ⌘] / ⌘[ (Tab / ⇧Tab on selected lines) |
| Between editor and terminal | ⌃` |
| Keyboard Shortcuts (change any of these) | ⌘, |

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
scripts/test.sh                          # unit tests: status, agents, git, files, editor, nxtrm, shortcuts, updates
python3 scripts/zsh-integration-test.py  # the shipped zsh hooks, in a real pty, with your zsh config
scripts/selftest.sh                      # end-to-end: drives the real app (opens a window)
```

The self-test opens real tabs and shells and checks every status transition, agent detection, jobs,
close confirmations, process cleanup, the security protections, projects, the sidebar with git, file
operations and undo, tab overflow, the editor (colours, editing, saving, files changed by agents, long
files), layouts, nxtrm and shortcuts, then writes a report and screenshots.

## Layout

```
Sources/NextTermCore/   platform-neutral logic, no AppKit: TabStatus, AgentScreen, CommandClassifier,
                        ShellIntegration, Git, Diff, HunkOps, FileTree and FileOps, ProjectSearch, TextFile
                        and LineIndex, EditorLanguage, CommandLineOpen, KeyChord, Updates
Sources/NextTerm/       the macOS app: windows, tabs, sidebar, editor, projects, menus, shortcuts, updates,
                        notifications, self-test
Resources/Highlighting/ the shipped grammars (scripts/update-highlighting.py) and the Next Dark theme
Tests/                  unit tests (swift-testing)
scripts/                build, test and icon scripts
```

`NextTermCore` has no AppKit dependency, so an iPad/iPhone app (SwiftTerm supports UIKit) or another
front end can reuse it.

## Roadmap

Next: open-source file icons (with framework icons: Laravel, Next.js and more), a side-by-side diff view
with hunk staging, and sending a selection of code to the agent in a tab. Later: split panes, notarized
releases. A Linux build would need a different UI layer (AppKit is
macOS-only); the core logic would carry over.

## Credits

Terminal emulation by [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (MIT). Syntax highlighting by
[shiki-swift](https://github.com/fayazara/shiki-swift) (MIT) with Oniguruma (BSD), using TextMate grammars from
[shikijs/textmate-grammars-themes](https://github.com/shikijs/textmate-grammars-themes), each under its own
permissive licence ([list](Resources/Highlighting/GRAMMARS.md)).

## License

MIT. See [LICENSE](LICENSE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
