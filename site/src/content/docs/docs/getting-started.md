---
title: Install and get started
description: "Install Next Term on macOS 13 or later, get past the first-launch warning with Open Anyway, choose a project folder and run your first agents side by side."
---

Next Term is one app: a terminal with tabs, a code editor above it, and a project sidebar with git. This page takes you from the download to two agents running side by side.

## What you need

- **macOS 13 Ventura or later**, on Apple Silicon or Intel. The app is universal.
- About 3 MB to download and 8 MB on disk.
- The agents you want to run, installed as usual: `claude`, `codex`, `gemini` and so on. Next Term brings no AI of its own; it runs the command-line agents you already use.
- zsh, the macOS default shell, gives the most precise tab status. bash and fish work too (see [how detection works](/docs/agent-status/#how-next-term-knows)).

## Download and install

### In one line, from the terminal

```sh
curl -fsSL https://next-term.mishuk.me/install.sh | bash
```

It downloads the latest release from GitHub, checks that its SHA-256 checksum is signed with the Next Term release key and that the download matches it, checks that the app inside is Next Term with an intact signature, and copies it to **Applications** (or `~/Applications` when you can’t write to Applications). When a folder already on your `PATH` takes the [`nxtrm` command](/docs/command-line/#installing-it) without a password, such as `~/.local/bin` or `/opt/homebrew/bin`, it links it there too, so `nxtrm .` works in any terminal; otherwise Next Term offers it when it opens. Nothing else changes: no `sudo`, no change to your `PATH`, and a Next Term that is running is never replaced (use **Check for Updates** in it instead). Because the download comes through `curl` rather than a browser, macOS doesn’t ask you to allow the first launch. [Read the script](https://github.com/MishukAdhikari/next-term/blob/main/site/src/install.sh) before you run it, if you like; it is short.

`NEXTTERM_VERSION=0.7.0` installs a particular version, and `NEXTTERM_DIR=~/Apps` another folder, for example `curl -fsSL https://next-term.mishuk.me/install.sh | NEXTTERM_DIR=~/Apps bash`.

### Or with the disk image

1. [Download NextTerm.dmg](https://github.com/MishukAdhikari/next-term/releases/latest/download/NextTerm.dmg): always the latest version, straight from its [release on GitHub](https://github.com/MishukAdhikari/next-term/releases/latest).
2. Open the disk image and drag **Next Term** to **Applications**.
3. Eject the disk image and open Next Term from Applications.

After this first install, Next Term updates itself. See [Updates](/docs/updates/).

### The first launch: “Open Anyway”

Releases are not notarized by Apple yet, so macOS blocks the first launch. You allow it once:

- **macOS 15 Sequoia and later:** open Next Term (macOS blocks it), then go to **System Settings → Privacy & Security**, scroll down, click **Open Anyway** next to Next Term, and confirm.
- **macOS 13 Ventura and macOS 14 Sonoma:** in Applications, right-click Next Term, choose **Open**, then **Open** again in the dialog.

macOS remembers the choice; later launches open normally. Notarized releases are planned.

### Check the download (optional)

Each release includes a checksum file, [`NextTerm.dmg.sha256`](https://github.com/MishukAdhikari/next-term/releases/latest/download/NextTerm.dmg.sha256). Download it next to the disk image and run this in that folder before you allow the app:

```sh
shasum -a 256 -c NextTerm.dmg.sha256
```

`NextTerm.dmg: OK` means your file matches the checksum published with the release, byte for byte. Releases are built by GitHub Actions from the public source.

## First launch: choose a folder

The first time it starts, Next Term asks which folder to work in. That folder opens as a **project**: the sidebar shows its files, and new tabs start in it. Next time, Next Term reopens it by itself (it reopens every project window that was open when you quit).

If you cancel, you get a plain terminal in your home folder. You can open a project at any time with **Shell › Open Project…** (<kbd>⌘O</kbd>). More in [Projects and git](/docs/projects-and-git/).

If Next Term finds an editor or terminal it can read settings from, such as VS Code, Cursor, a JetBrains IDE, Zed, iTerm2, Ghostty or Terminal, it asks **Coming from another app?** Choose one to see exactly what it would bring over (your shortcuts, fonts, terminal colours and recent projects), or keep Next Term’s own. You can do it later from **Next Term › Import Settings and Shortcuts…**. See [Switching to Next Term](/docs/switching/).

macOS also asks whether Next Term may send notifications. Allow them: that is how an agent waiting on your decision reaches you while you are in another tab or app.

Next Term also adds the `nxtrm` command for your other terminals, in a folder on your `PATH` that needs no password. When there is no such folder, as on a Mac without Homebrew, it asks first: **Install the “nxtrm” command?** **Install…** asks for your administrator password, **Not Now** asks again after the next update, and **Don’t Ask Again** never does. See [Installing it](/docs/command-line/#installing-it).

## Run two agents side by side

1. Press <kbd>⌘T</kbd> for a new tab. In a project window it opens in the project folder.
2. Start an agent, for example `claude`.
3. Press <kbd>⌘T</kbd> again and start another, for example `codex`.
4. Or keep them in one tab: <kbd>⌘D</kbd> splits it, and each pane runs its own agent.
5. Give each a task and switch away. Each tab shows a spinner while its agent works, a green check when it is done, and an amber “!” when it is asking you something. If you are elsewhere, a notification tells you which agent needs a decision; click it to land on that tab.

Read [Agent status in every tab](/docs/agent-status/) for what each mark means.

To run an agent on one of your servers instead, press <kbd>⌥⌘T</kbd> (**Shell › New Remote Tab…**) and give it the ssh destination. With **tmux** or **herdr**, the agent keeps working while your Mac sleeps. See [Remote tabs on your servers](/docs/remote/).

## Open files next to your agents

Files open in the editor above the terminal:

- Double-click a file in the sidebar.
- <kbd>⌘</kbd>-click a path such as `src/app.ts:42:7` anywhere in terminal output, or a Python traceback’s `File "graph.py", line 42`: the file opens at that line.
- Press <kbd>⌘P</kbd> and type part of its name ([Go to File](/docs/editor/#go-to-file)).
- Run `nxtrm app/User.php:42` in a tab. See [The nxtrm command](/docs/command-line/).

Select some lines and press <kbd>⌥⌘K</kbd> to hand them to the agent in your tab, or just ask Claude Code about “the selected lines”: it sees your selection. See [Agents and the IDE link](/docs/agents/).

## Build from source

You need macOS 13 or later and Swift 6. The Xcode Command Line Tools are enough; full Xcode is not required.

```sh
git clone https://github.com/MishukAdhikari/next-term.git
cd next-term
swift run NextTerm            # run a debug build
scripts/build-dmg.sh          # universal app, DMG and checksum in dist/
```

## Next steps

- [Agent status in every tab](/docs/agent-status/): the marks, notifications and the Dock badge.
- [Agents and the IDE link](/docs/agents/): what Claude Code, Gemini CLI and Qwen Code see, and Send to Agent.
- [Orchestrate agents (MCP)](/docs/orchestration/): let one agent start and steer the others.
- [Projects and git](/docs/projects-and-git/): the sidebar, agent sessions, the branch popup and the Git Log.
- [Keyboard shortcuts](/docs/keyboard-shortcuts/): the full list, and how to change any of them.
