# Next Term

A native macOS terminal for the AI era, in the spirit of the PhpStorm terminal.

Run Claude Code, Codex, a test suite and a dev server side by side, one per tab, and see at a glance
which ones are still working, which finished, which failed, and which are waiting for you.

- **Tabs that report status.** Every tab carries a dot: spinning blue while working, green when done,
  red when a command failed, amber when a program rang the bell or asked for attention.
  The dot clears when you look at the tab.
- **Knows when an agent is waiting for you.** Agents like `claude` and `codex` never exit, so "done"
  means "stopped printing and wants your input". Next Term tells the two apart from a long `npm install`.
- **Project sidebar.** The active tab's project (its git root) as a live file tree on the left, like
  PhpStorm's Project view. Files your agents create appear on their own. Drag a file onto the terminal to
  type its path.
- **⌘T opens a tab in the same folder.** ⌘1…⌘9, ⌘⇧[ ⌘⇧], Ctrl-Tab to move between them.
- **Dock badge and notifications** for tabs that finished while you were in another app.
- **Native.** Swift and AppKit, ~2.5 MB universal app (Apple Silicon and Intel), macOS 13 or later.

## Install

Download `NextTerm-x.y.z.dmg` from [Releases](../../releases), open it, and drag **Next Term** to
Applications.

Builds are not notarized yet, so the first launch needs one extra step: right-click **Next Term** in
Applications, choose **Open**, then **Open** again. Each release lists the DMG's SHA-256; check it with
`shasum -a 256 NextTerm-x.y.z.dmg` before you bypass Gatekeeper.

## Tab status

| Dot | Meaning |
|---|---|
| none | At the prompt, nothing new |
| spinning blue | A command is running, or an agent is printing |
| green | Finished successfully, or an agent stopped and is waiting for you |
| red | Exited with an error (the exit code is in the tooltip) |
| amber | The program rang the bell or sent a notification (OSC 9 / OSC 777) |

How it knows, most reliable first:

1. **zsh integration.** Next Term starts zsh with its own `ZDOTDIR` holding a tiny `.zshenv`. That file
   points `ZDOTDIR` back at your real config, loads your `.zshenv`, and adds `preexec`/`precmd` hooks that
   report "command started", "command finished with exit code N" and the working directory over a private
   escape sequence. Your `.zprofile`, `.zshrc` and frameworks such as oh-my-zsh load exactly as before.
2. **Agents.** `claude`, `codex`, `gemini`, `aider`, `opencode` and friends stay in the foreground, so
   for them Next Term watches output: printing means working; 2.5 s of silence means waiting for you.
   Your own typing and window resizes don't count as work.
3. **Other shells.** For bash and fish, Next Term asks the kernel for the terminal's foreground process
   twice a second: the shell in front means idle, anything else means running.

Interactive programs (`vim`, `ssh`, `less`, REPLs) are never reported as "done".

## Keyboard

| Action | Keys |
|---|---|
| New tab (same folder) | ⌘T |
| New window | ⌘N |
| Close tab (asks if something is running) | ⌘W |
| Select tab 1–8 / last tab | ⌘1…⌘8 / ⌘9 |
| Next / previous tab | ⌘⇧] / ⌘⇧[, Ctrl-Tab / Ctrl-Shift-Tab |
| Rename tab | ⌘⇧R, or double-click the tab |
| Project sidebar | ⌘B |
| Find / next / previous | ⌘F / ⌘G / ⌘⇧G |
| Clear | ⌘K |
| Font size | ⌘+ / ⌘- / ⌘0 |

Tabs can be dragged to reorder; middle-click closes. In the sidebar, double-click opens a file in its
default app; right-click for Open in New Tab, Reveal in Finder, Insert Path in Terminal and Copy Path.

## Security

- **Clipboard:** programs can copy to the clipboard (OSC 52) only from the tab you are looking at, and can
  never read it, so a remote host over ssh cannot harvest what you copied.
- **Status marks** from the shell carry a random per-tab secret that programs never see, so output (a
  `cat` of a log, a remote host) cannot fake "command finished" and skip the close confirmation.
- **Paths you drop or insert** are quoted so that no file name can run a command, even one containing
  control characters, and are sent as a bracketed paste.
- **Opening files** from the sidebar or with ⌘-click asks first when the file is an app, a script or an
  executable (cloned repos carry no quarantine flag, so Gatekeeper would not ask). Links other than
  http, https, mailto and local files are refused.

## Build from source

Needs macOS 13+ and Swift 6 (the Xcode Command Line Tools are enough; full Xcode is not required).

```sh
git clone https://github.com/MishukAdhikari/next-term.git
cd next-term
swift run NextTerm            # run a debug build
scripts/build-dmg.sh          # universal app + DMG in dist/
```

To sign for distribution: `SIGN_ID="Developer ID Application: Your Name (TEAMID)" scripts/build-dmg.sh`,
then notarize the DMG with `xcrun notarytool submit dist/NextTerm-*.dmg --wait` and staple it.

## Tests

```sh
scripts/test.sh                          # unit tests: status machine, classifier, quoting, file tree
python3 scripts/zsh-integration-test.py  # the shipped zsh hooks, in a real pty, with your zsh config
.build/debug/NextTerm --self-test out.txt  # end-to-end: drives the real app (opens a window)
```

The self-test opens real tabs and shells and checks every status transition, ⌘T, cwd inheritance,
close confirmations, process cleanup, the project sidebar (including live file updates), rename,
reorder and font size, then writes a report and screenshots next to `out.txt`.

## Layout

```
Sources/NextTermCore/   platform-neutral logic, no AppKit: TabStatus, CommandClassifier,
                        ShellIntegration (zsh script + OSC parser), ShellQuote, FileTree
Sources/NextTerm/       the macOS app: windows, tab bar, sidebar, menus, notifications, self-test
Tests/                  unit tests (swift-testing)
scripts/                build, test and icon scripts
```

`NextTermCore` has no AppKit dependency, so an iPad/iPhone app (SwiftTerm supports UIKit) or another
front end can reuse it.

## Roadmap

Split panes, session restore, settings (themes, fonts, agent list), shell integration for bash and fish,
notarized releases. A Linux build would need a different UI layer (AppKit is macOS-only); the core logic
would carry over.

## Credits

Terminal emulation by [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (MIT). Colours follow the
JetBrains New UI dark theme.

## License

MIT. See [LICENSE](LICENSE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
