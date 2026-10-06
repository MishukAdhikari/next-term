---
title: Frequently asked questions
description: "Answers about Next Term: supported agents and Macs, Open Anyway, privacy, Claude Code and Codex, orchestration over MCP, split panes, and what comes next."
head:
  - tag: title
    content: Next Term FAQ — AI terminal for macOS
---

## What is Next Term?

Next Term is a native macOS terminal and code editor for running AI coding agents side by side. Each agent gets a tab, and every tab shows whether its agent is working, done, or waiting on your decision. An editor, side-by-side diffs and a git-aware project sidebar sit next to the agents, so you can read and fix what they change without leaving the window.

## Which AI coding agents does it work with?

Any agent that runs in a terminal. Next Term recognises Claude Code, Codex, Gemini CLI, Qwen Code, Command Code, Junie, opencode, Aider, Amp, Cursor Agent, Goose, Crush, GitHub Copilot CLI, Droid, Kiro, Amazon Q, Kimi, Plandex, Cline and Auggie by name and shows their status on the tab. Claude Code, Gemini CLI and Qwen Code also connect to Next Term as their IDE. Every agent gets Send to Agent (<kbd>⌥⌘K</kbd>). See [Agents and the IDE link](/docs/agents/).

## Is Next Term free and open source?

Yes. Next Term is free, and its source code is on [GitHub](https://github.com/MishukAdhikari/next-term) under the MIT licence. Its dependencies are permissively licensed too: SwiftTerm, shiki-swift with Oniguruma, the TextMate grammars, the Material Icon Theme and SwiftDraw.

## Does it include its own AI, or need an API key?

No. Next Term brings no model and no account. It runs the agent command-line tools you already have, signed in the way each of them normally is.

## Which Macs and macOS versions are supported?

macOS 13 Ventura or later, on Apple Silicon and Intel: the app is universal. The download is about 3 MB and the app takes about 8 MB.

## Why does macOS block the first launch?

Releases are not notarized by Apple yet. On macOS 15 and later, open Next Term once, then go to **System Settings → Privacy & Security** and click **Open Anyway**. On macOS 13 and 14, right-click the app, choose **Open**, then **Open** again. You only do this once. Each release includes a SHA-256 checksum so you can verify the download first. See [Install and get started](/docs/getting-started/#the-first-launch-open-anyway).

## How does Next Term know when an agent is done or waiting on me?

It reads the agent’s own screen, the way you would. “esc to interrupt” means working; a question with choices means it is waiting on you; anything else means it is idle. With zsh, a small shell integration also reports each command and its exit code. See [Agent status in every tab](/docs/agent-status/).

## How do I connect Claude Code to Next Term?

Start `claude` in a Next Term tab. It connects by itself: the lines you select go with your prompt, <kbd>⌥⌘K</kbd> adds an @-mention, and Claude’s proposed edits open as a diff to accept (<kbd>⌘↩︎</kbd>) or reject. There is nothing to install or configure. See [Claude Code sees your editor](/docs/agents/#claude-code-sees-your-editor).

## Can I use Codex CLI in Next Term?

Yes. Run `codex` in a tab: its tab shows when it is working, done or asking for approval, and approval questions arrive as notifications. Send to Agent (<kbd>⌥⌘K</kbd>) types references in the form Codex reads, such as `app/User.php:10-20`.

## Does Next Term send my code anywhere?

No. The agent links listen only on your Mac (`127.0.0.1`), with a fresh secret token each launch, and never share `.env` files or keys. The only request Next Term makes on its own is the daily update check to GitHub, which you can turn off. Your agents talk to their own providers as they always do. See [Security and privacy](/docs/security-and-privacy/).

## Is Next Term an alternative to Warp?

For agent work on the Mac, yes. Both are open source now: Warp’s client under AGPL since April 2026, Next Term under MIT. Next Term is the smaller, native one. It is written in Swift and AppKit, needs no account, and has no AI of its own: it runs the agent CLIs you choose, shows each one’s status on its tab, and adds a code editor, side-by-side diffs, a git-aware sidebar and an MCP server through which one agent runs the others. Choose Warp for its built-in agent, cloud agents, team features, or Linux and Windows. See [Next Term vs Warp](/compare/warp/).

## Can one agent control the others?

Yes. Next Term is an MCP server, set up for you in Claude Code, Codex, Gemini CLI, Qwen Code, Cursor Agent, opencode, Copilot CLI, Amp, Junie and Command Code. An orchestrator agent can list every project and tab with each agent’s state, start agents in new tabs, send them prompts, wait for them, read their screens and answer their questions. It works only on your Mac, through a private socket with no network port, and **Settings** turns it off. See [Orchestrate agents (MCP)](/docs/orchestration/).

## Can I split a tab into panes?

Yes. <kbd>⌘D</kbd> splits the tab to the right and <kbd>⇧⌘D</kbd> down, as often as you like; <kbd>⌥⌘</kbd> with the arrows moves between panes. The tab shows the mark of its most urgent pane. See [Split panes](/docs/layouts/#split-panes).

## Is Next Term a full IDE?

No. It is built around the terminal tabs where your agents work: every tab shows its agent’s status, decisions arrive as notifications, and an editor, diffs and a git-aware sidebar sit next to them. There is no debugger, language server or extension system. See [how Next Term compares](/compare/) with VS Code, JetBrains IDEs, Cursor and others.

## Will my zsh configuration and oh-my-zsh still work?

Yes. Next Term loads your `.zshenv`, `.zprofile` and `.zshrc` exactly as before, frameworks included, and edits none of them. bash and fish work too.

## Can I change the keyboard shortcuts?

Every one of them. Open **Settings** (<kbd>⌘,</kbd>) › **Keyboard Shortcuts**, click a shortcut and press the new keys. See [Keyboard shortcuts](/docs/keyboard-shortcuts/).

## How do I update Next Term?

It updates itself. Next Term checks GitHub Releases once a day, and **Next Term › Check for Updates…** checks at once. Updates are verified against the published SHA-256 before they replace anything. See [Updates](/docs/updates/).

## Is there a Linux or Windows version?

Not today. Next Term is built with AppKit, which is macOS-only. Its core logic has no AppKit dependency and would carry over, but another platform would need a different user interface layer.

## What is coming next?

Next: tabs on your servers over SSH, with agents that keep running while your Mac is away. After that: importing your settings and shortcuts from VS Code and JetBrains IDEs, remote access to the MCP server for agents outside your Mac (such as ChatGPT and Claude on the web), more of the diff view, an IDE link for Copilot CLI, session restore and notarized releases. None of these is released yet.
