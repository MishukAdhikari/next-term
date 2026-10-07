---
title: Next Term vs Ghostty
description: "Ghostty is a fast, GPU-rendered terminal for macOS and Linux. Next Term is a macOS terminal and editor built for running AI coding agents side by side."
sidebar:
  label: Ghostty
head:
  - tag: title
    content: Next Term vs Ghostty for AI coding agents
---

Ghostty is a free, MIT-licensed terminal emulator for macOS and Linux, developed as non-profit work. It renders with the GPU (Metal on macOS), uses native tabs and splits, and offers a quick terminal, hundreds of built-in themes, the Kitty graphics protocol, AppleScript on macOS, and configuration in a text file. Programs in Ghostty can post desktop notifications and show progress bars, which Claude Code does by default. Next Term is also native, MIT-licensed and free, but it does a different job: it is a macOS terminal and code editor built around running several AI coding agents side by side. It shows each agent’s status on its tab (read from the screen for Claude Code, Codex, Command Code and Gemini CLI), quotes its questions in notifications, adds an editor, side-by-side diffs and a git-aware sidebar, and is an MCP server through which one agent runs the others. Choose Ghostty for a fast, general-purpose terminal on the Mac and Linux. Choose Next Term for agent work. They sit well side by side.

## At a glance

| Feature | Next Term | Ghostty |
|---|---|---|
| Platforms | macOS 13 or later | macOS 13 or later, Linux; Windows planned |
| Price and licence | Free, MIT | Free, MIT; a non-profit project |
| Native interface | ✓ Swift and AppKit | ✓ Swift, AppKit and SwiftUI on macOS; GTK on Linux |
| Tabs and split panes | ✓ | ✓ |
| Status of each agent | ✓ For the 20 agents it recognises, with no setup: working, done, waiting (with the question), failed. Read from the screen for Claude Code, Codex, Command Code and Gemini CLI, and from output timing for the rest | Partly: programs can show a progress bar, as Claude Code does |
| Notifications | ✓ Quote the agent’s question; Dock badge | ✓ Programs can post notifications; command-finished notifications, off by default |
| One agent runs the others | ✓ An MCP server: start, prompt, wait for and read agents | Partly: AppleScript can open tabs and splits, type text and send keys |
| Code editor | ✓ 112 grammars, Go to File (<kbd>⌘P</kbd>) | — |
| Side-by-side diffs, per-hunk staging | ✓ <kbd>⌥⌘G</kbd> | — |
| Project sidebar with git status | ✓ | — |
| Quick terminal, hundreds of themes | — | ✓ |
| Configuration | A Settings window; every menu shortcut can be changed | A text file; no settings window yet |

## Choose Ghostty if…

- **You want a fast, general-purpose terminal** that renders on the GPU, with hundreds of themes and a quick terminal that drops down from the menu bar.
- **You use Linux as well as macOS** and want the same terminal on both.
- **You like configuring in a text file** and keeping it in your dotfiles, or scripting windows, tabs and splits with AppleScript.

## Choose Next Term if…

- **You run several AI agents at once** and need to see which one is working, which is done and which is waiting on you, on every tab, without configuring anything.
- **You want your agents to see your editor.** Claude Code, Gemini CLI and Qwen Code connect to Next Term as their IDE: your selection goes with the next prompt, and proposed edits open as diffs to accept or reject.
- **You want the question in the notification.** When an agent asks for permission, Next Term’s notification quotes it and takes you to the tab.
- **You want to review agents’ work next to them:** an editor, side-by-side diffs with per-hunk stage, unstage and revert, Find and Replace in Files, and a project sidebar with git status and line counts.
- **You want one agent to orchestrate the others** over MCP, across projects.

## Use both

- **Keep Ghostty as your everyday terminal; open agent projects in Next Term.** `nxtrm .` in a Ghostty tab opens that folder as a Next Term project. Next Term links the command into a folder on your `PATH` at launch, or offers to install it with your password ([how](/docs/command-line/#installing-it)).
- **Bring your Ghostty setup.** **Next Term › Import Settings and Shortcuts…** reads your Ghostty configuration, included files too: its font, your theme’s colours, and the keybinds that have a Next Term command. You see each change before it applies.
- **Agents started in Ghostty can still use Next Term.** A `claude` started in Ghostty inside a project open in Next Term can connect to Next Term with `/ide`, and any agent with Next Term’s MCP server registered can start other agents in Next Term tabs.

## Questions

### Claude Code already sends notifications in Ghostty. What does Next Term add?

Claude Code sends desktop notifications in Ghostty by default. Next Term sends its own for every agent it recognises, quoting the question when one waits on you, and adds a status mark on each tab, a Dock badge, the editor and diffs, Claude Code’s IDE link, and an MCP server through which one agent can run the others.

### Is Next Term faster than Ghostty?

Next Term makes no speed claims. Ghostty is built for speed, with GPU rendering; if raw terminal performance is what you need, use Ghostty.

### Can Ghostty be scripted like Next Term’s MCP server?

Partly. Ghostty on macOS has an AppleScript dictionary that can open tabs and splits, type text and send keys. Next Term’s MCP server is made for agents: it reports each tab’s agent state, waits until an agent stops, and reads its screen.

## Read more

- [Agent status in every tab](/docs/agent-status/)
- [Layouts and split panes](/docs/layouts/)
- [The nxtrm command](/docs/command-line/)
- [Orchestrate agents (MCP)](/docs/orchestration/)
- [Next Term compared with other tools](/compare/)

## Sources

**Checked October 2026** against Ghostty’s own site, documentation and repository, and Anthropic’s Claude Code documentation. Products change quickly; if something here is out of date, please [open an issue](https://github.com/MishukAdhikari/next-term/issues).

- [Ghostty](https://ghostty.org/) and [download](https://ghostty.org/download) (macOS 13 or later, universal)
- [Features](https://ghostty.org/docs/features) (platforms, GPU rendering, native tabs and splits, Kitty graphics, quick terminal)
- [About](https://ghostty.org/docs/about) (Swift and AppKit on macOS, GTK on Linux) and [sponsorship](https://ghostty.org/docs/sponsor) (non-profit)
- [Configuration](https://ghostty.org/docs/config) and [configuration reference](https://ghostty.org/docs/config/reference) (notifications, progress bars)
- [AppleScript](https://ghostty.org/docs/features/applescript) and [themes](https://ghostty.org/docs/features/theme)
- [Ghostty on GitHub](https://github.com/ghostty-org/ghostty) (MIT licence)
- [Claude Code: terminal configuration](https://code.claude.com/docs/en/terminal-config) (notifications in Ghostty)
