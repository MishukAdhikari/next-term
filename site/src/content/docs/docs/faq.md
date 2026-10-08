---
title: Frequently asked questions
description: "Answers about Next Term: agents and Macs, installing, privacy, MCP, remote tabs, git history, notebooks, databases, importing settings, what comes next."
head:
  - tag: title
    content: Next Term FAQ — AI terminal for macOS
---

## What is Next Term?

Next Term is a native macOS terminal and code editor for running AI coding agents side by side. Each agent gets a tab, and every tab shows whether its agent is working, done, or waiting on your decision. An editor, side-by-side diffs, git from branches to blame and a git-aware project sidebar sit next to the agents, so you can read and fix what they change without leaving the window. Agents can run on your Mac or, in remote tabs, on your own servers.

## Which AI coding agents does it work with?

Any agent that runs in a terminal. Next Term recognises Claude Code, Codex, Gemini CLI, Qwen Code, Command Code, Junie, opencode, Aider, Amp, Cursor Agent, Goose, Crush, GitHub Copilot CLI, Droid, Kiro, Amazon Q, Kimi, Plandex, Cline and Auggie by name and shows their status on the tab. Claude Code, Gemini CLI, Qwen Code, GitHub Copilot CLI and opencode also connect to Next Term as their IDE. Every agent gets Send to Agent (<kbd>⌥⌘K</kbd>). See [Agents and the IDE link](/docs/agents/).

## Is Next Term free and open source?

Yes. Next Term is free, and its source code is on [GitHub](https://github.com/MishukAdhikari/next-term) under the MIT licence. Its dependencies are permissively licensed too: SwiftTerm, shiki-swift with Oniguruma, the TextMate grammars, the Material Icon Theme and SwiftDraw.

## Does it include its own AI, or need an API key?

No. Next Term brings no model and no account. It runs the agent command-line tools you already have, signed in the way each of them normally is.

## Which Macs and macOS versions are supported?

macOS 13 Ventura or later, on Apple Silicon and Intel: the app is universal. The download is about {{DOWNLOAD_SIZE}} and the app takes about {{INSTALLED_SIZE}}.

## How do I install it?

In one line, from the terminal:

```sh
curl -fsSL https://nxtrm.mishuk.me/install.sh | bash
```

It checks that the release’s checksum is signed with the Next Term release key and that the download matches it, then copies Next Term to Applications, with no `sudo`, and macOS doesn’t ask you to allow the first launch. Or download the disk image and drag Next Term to Applications. See [Install and get started](/docs/getting-started/).

## Why does macOS block the first launch?

Next Term is not notarized by Apple, so macOS asks before it opens a copy downloaded in a browser. Installed with the one-line installer, Next Term opens without asking. On macOS 15 and later, open Next Term once, then go to **System Settings → Privacy & Security** and click **Open Anyway**. On macOS 13 and 14, right-click the app, choose **Open**, then **Open** again. You only do this once. Each release includes a SHA-256 checksum so you can verify the download first. See [Install and get started](/docs/getting-started/#the-first-launch-open-anyway).

## How does Next Term know when an agent is done or waiting on me?

It reads the agent’s own screen, the way you would. “esc to interrupt” means working; a question with choices means it is waiting on you; anything else means it is idle. This is checked against Claude Code, Codex, Command Code and Gemini CLI; other agents go by output timing, where 2.5 seconds of silence means done. With zsh, a small shell integration also reports each command and its exit code. See [Agent status in every tab](/docs/agent-status/).

## How do I connect Claude Code to Next Term?

Start `claude` in a Next Term tab. It connects by itself: the lines you select go with your prompt, <kbd>⌥⌘K</kbd> adds an @-mention, and Claude’s proposed edits open as a diff to accept (<kbd>⌘↩︎</kbd>) or reject. There is nothing to install or configure. See [Claude Code sees your editor](/docs/agents/#claude-code-sees-your-editor).

## Can I use Codex CLI in Next Term?

Yes. Run `codex` in a tab: its tab shows when it is working, done or asking for approval, and approval questions arrive as notifications. Send to Agent (<kbd>⌥⌘K</kbd>) types references in the form Codex reads, such as `app/User.php:10-20`.

## Does Next Term send my code anywhere?

No. The agent links listen only on your Mac (`127.0.0.1`), with a fresh secret token each launch, and never share `.env` files or keys. On its own, Next Term makes only the daily update check to GitHub and a background `git fetch` from your projects’ own remotes, and you can turn off either. A project’s databases are found by reading its files, and nothing connects to one until you choose a hand-off; remote tabs connect only to the servers you open them on, through your own ssh. Your agents talk to their own providers as they always do. See [Security and privacy](/docs/security-and-privacy/).

## Can one agent control the others?

Yes. Next Term is an MCP server, set up for you in Claude Code and the Claude desktop app, Codex and the ChatGPT desktop app, Gemini CLI, Qwen Code, Cursor Agent, opencode, Copilot CLI, Amp, Junie and Command Code. An orchestrator agent can list every project and tab with each agent’s state, start agents in new tabs, send them prompts, wait for them, read their screens and answer their questions. It can also read, search and diff the open projects (never their secrets files), and open tabs on your servers. It works only on your Mac, through a private socket with no network port, and **Settings** turns it off. See [Orchestrate agents (MCP)](/docs/orchestration/).

## Can my agents run on a server?

Yes. **File › New Remote Tab…** (<kbd>⌥⌘T</kbd>) opens a tab on any server you reach with ssh, using your `~/.ssh/config`, keys and agent. Choose **tmux** or **herdr**, and the session keeps running while your Mac sleeps or the network drops; the tab reconnects by itself and comes back once a window opens after the next launch. Agents there get the same marks as local ones. Nothing is installed on the server and no password is stored. See [Remote tabs on your servers](/docs/remote/).

## Can I split a tab into panes?

Yes. <kbd>⌘D</kbd> splits the tab to the right (in the editor it duplicates the line) and <kbd>⇧⌘D</kbd> down, as often as you like; <kbd>⌥⌘</kbd> with the arrows moves between panes. The tab shows the mark of its most urgent pane. See [Split panes](/docs/layouts/#split-panes).

## Is Next Term a full IDE?

No. It is built around the terminal tabs where your agents work: every tab shows its agent’s status, decisions arrive as notifications, and an editor, diffs, git tools and a git-aware sidebar sit next to them. There is no debugger, language server or extension system, and notebooks open read-only, without a kernel. See [how Next Term compares](/compare/) with VS Code, JetBrains IDEs, Cursor and others.

## Does it show git history and blame?

Yes. **Git › Git Log** (<kbd>⌥⌘L</kbd>) shows the commit history as a graph in a tab, with text, branch, author, date and path filters, each commit in full and its changes side by side. **View › Annotate with Git Blame** shows who last changed each line beside the line numbers. The branch popup (<kbd>⌥⌘B</kbd>) checks out, updates, commits and pushes, and asks first when an agent is working in the folder. See [Git Log](/docs/projects-and-git/#git-log), [Git blame](/docs/editor/#git-blame) and [Branches](/docs/projects-and-git/#branches).

## Does it open Jupyter notebooks, data files and databases?

Notebooks open read-only, as cells with the outputs saved in the file: nothing runs. JSON Lines, CSV and TSV files over 2 MB, and logs and other text files over 32 MB, open in a read-only head view that reads 1,000 rows at a time. The databases a project names in its own files appear in the sidebar; SQLite files open in a read-only viewer, and other databases hand off to TablePlus, or to mysql or psql in a tab. See [Jupyter notebooks](/docs/editor/#jupyter-notebooks), [Large data files](/docs/editor/#large-data-files) and [Databases](/docs/projects-and-git/#databases).

## Can I bring my settings from VS Code or JetBrains?

Yes. **Next Term › Import Settings and Shortcuts…** reads VS Code, Cursor, Devin Desktop, JetBrains IDEs, Zed, iTerm2, Ghostty and Terminal: the matching shortcut set, the keys you changed yourself, font size and other settings, fonts, terminal colours and recent projects. You see every change first, and one click undoes the import. See [Switching to Next Term](/docs/switching/).

## Will my zsh configuration and oh-my-zsh still work?

Yes. Next Term loads your `.zshenv`, `.zprofile` and `.zshrc` exactly as before, frameworks included, and edits none of them. bash and fish work too.

## Can I change the keyboard shortcuts?

Yes: every menu command’s shortcut, and the keys of the project sidebar, the Git lists, a proposed edit and the branch popup. Open **Settings** (<kbd>⌘,</kbd>) › **Keyboard Shortcuts**, click a shortcut and press the new keys. To keep the keys you know from another editor, choose a set in **Settings › Import › Shortcuts from**. A few keys outside the menus, such as <kbd>⌃⇥</kbd> for the next tab, are fixed. See [Keyboard shortcuts](/docs/keyboard-shortcuts/).

## How do I update Next Term?

It updates itself. Next Term checks GitHub Releases once a day, and **Next Term › Check for Updates…** checks at once. Updates must be signed with the Next Term release key and match their checksum before they replace anything. See [Updates](/docs/updates/).

## Is there a Linux or Windows version?

Not today. Next Term is built with AppKit, which is macOS-only. Its core logic has no AppKit dependency and would carry over, but another platform would need a different user interface layer.

## What is coming next?

Next: a server’s files in the editor and sidebar, then dev containers; remote access to the MCP server for agents outside your Mac (such as ChatGPT and Claude on the web); more of the diff view; session restore. None of these is released yet.
