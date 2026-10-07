---
title: Next Term vs iTerm2
description: "iTerm2 is a mature macOS terminal with tmux integration, triggers and a Python API. Next Term adds agent status, an editor and diffs for running AI agents."
sidebar:
  label: iTerm2
head:
  - tag: title
    content: Next Term vs iTerm2 for AI coding agents
---

iTerm2 is a free, open-source (GPL v2) terminal for macOS with a long list of features: split panes and tab groups, tmux integration, triggers, badges, profiles, a hotkey window, Instant Replay, a Python API and a Metal renderer. Version 3.7 added a Claude Code integration that shows each Claude session as working, waiting or idle, and an optional AI plugin, used with your own API key, adds a chat that can watch and operate your sessions. Next Term is a younger, narrower app: a macOS terminal and code editor built around running several AI coding agents side by side. It reads each agent’s own screen to show its status on the tab, for 20 agents with no hooks to install, and adds an editor, side-by-side diffs, a git-aware project sidebar, and an MCP server through which one agent runs the others. Choose iTerm2 as an all-round terminal; choose Next Term for agent work. Many people keep both.

## At a glance

| Feature | Next Term | iTerm2 |
|---|---|---|
| Platforms | macOS 13 or later | macOS; the current release needs macOS 13 or later |
| Price and licence | Free, MIT | Free, GPL v2 |
| Tabs and split panes | ✓ | ✓ With tab groups |
| Status of each agent | ✓ Read from the agent’s screen for 20 agents, no setup | Partly: Claude Code, through hooks it adds to Claude’s settings; other programs can report status with an escape sequence |
| Notifications | ✓ Quote the agent’s question; Dock badge | ✓ On idle, bell, session end, triggers, or any session’s status change |
| One agent runs the others | ✓ An MCP server any agent can use: start, prompt, wait for and read agents | Partly: an AI chat that can read your sessions and, after asking, type into them; needs your own API key |
| AI of its own | — Runs the agents you install | Partly: an optional AI plugin, with your own API key |
| Code editor | ✓ 112 languages, Go to File (<kbd>⌘P</kbd>) | — |
| Side-by-side diffs, per-hunk staging | ✓ <kbd>⌥⌘G</kbd> | Partly: a diff viewer in the Claude Code workgroup |
| Project sidebar with git status | ✓ | — |
| tmux integration | Partly: remote tabs keep their sessions in tmux or herdr on the server and reattach by themselves; no `tmux -CC` mode | ✓ `tmux -CC` as native windows and tabs |
| Automation | `nxtrm` and the MCP server | ✓ Triggers, a Python API, the `it2` tool |
| Hotkey window, profiles, Instant Replay | — | ✓ |

## Choose iTerm2 if…

- **You want an all-round terminal with a deep set of options:** profiles, triggers, badges, a hotkey window, Instant Replay, inline images and global search.
- **You live in tmux or on remote machines.** iTerm2’s tmux integration shows a remote tmux session as ordinary windows and tabs, and the session keeps running when the connection drops.
- **You script your terminal** with the Python API or triggers.
- **Claude Code is your only agent,** and its status in iTerm2’s Session Status tool is all the overview you need.

## Choose Next Term if…

- **You run several different agents.** Next Term reads each agent’s own screen, so Claude Code, Codex, Gemini CLI, Qwen Code and 16 more show working, done or waiting on their tab, with nothing added to their settings.
- **You want to read and fix what the agents change, in the same window:** an editor for 112 languages, side-by-side diffs with per-hunk stage, unstage and revert, Find and Replace in Files, and a sidebar with `+12 −3` line counts.
- **You want your agents to see your editor.** Claude Code, Gemini CLI and Qwen Code connect to Next Term as their IDE, so your selection goes with the next prompt and proposed edits open as diffs to accept or reject.
- **You want your own agent to orchestrate the others.** Next Term’s MCP server is used by the agents you already have, under their own subscriptions, with no extra API key.

## Use both

- **Keep iTerm2 for tmux integration, scripting and everything else; open agent projects in Next Term.** `nxtrm .` in an iTerm2 tab opens that folder as a Next Term project; Next Term links the command into `/usr/local/bin` at launch, or asks once through **Next Term › Install Command Line Tool (nxtrm)…**.
- **Bring your profile over.** **Next Term › Import Settings and Shortcuts…** reads iTerm2’s default profile (its font, font size, colours and Option keys) and shows each change before it applies it.
- **Agents started in iTerm2 can still use Next Term.** A `claude` started in iTerm2 inside a project open in Next Term can connect to Next Term with `/ide`, and any agent with Next Term’s MCP server registered can start other agents in Next Term tabs.

## Questions

### iTerm2 3.7 shows Claude Code’s status. Why add Next Term?

If Claude Code is the only agent you run, iTerm2 may be enough. Next Term shows status for 20 agents by reading their screens, with no hooks in their settings and no Python API to enable, and adds the editor, diffs, project sidebar, IDE link and MCP server around them.

### Does Next Term support tmux integration, triggers or profiles?

Not tmux’s control mode. Next Term runs tmux like any terminal, and a remote tab can keep its session in Next Term’s own tmux server on the host and reattach when the connection comes back. It has no `tmux -CC` mode, triggers, profiles or scripting API beyond `nxtrm` and its MCP server.

### Is iTerm2 free?

Yes. iTerm2 is free software under GPL v2, supported by donations. Next Term is free under the MIT licence.

## Read more

- [Agent status in every tab](/docs/agent-status/)
- [Code editor](/docs/editor/) and [Side-by-side diffs](/docs/diffs/)
- [The nxtrm command](/docs/command-line/)
- [Orchestrate agents (MCP)](/docs/orchestration/)
- [Next Term compared with other tools](/compare/)

## Sources

**Checked October 2026** against iTerm2’s own site and documentation. Products change quickly; if something here is out of date, please [open an issue](https://github.com/MishukAdhikari/next-term/issues).

- [iTerm2](https://iterm2.com/) (licence, cost) and [downloads](https://iterm2.com/downloads.html) (iTerm2 3.7.3, macOS 13 or later)
- [Features](https://iterm2.com/features.html) and [news](https://iterm2.com/news.html) (3.7, Metal renderer)
- [Claude Code integration](https://iterm2.com/claude-code-integration.html) and [Session Status](https://iterm2.com/documentation-session-status.html)
- [AI Chat](https://iterm2.com/documentation-ai-chat.html) and [the AI plugin](https://iterm2.com/ai-plugin.html)
- [Profiles › Terminal](https://iterm2.com/documentation-preferences-profiles-terminal.html) (notifications) and [triggers](https://iterm2.com/documentation-triggers.html)
- [tmux integration](https://iterm2.com/documentation-tmux-integration.html) and [Python API](https://iterm2.com/python-api/)
