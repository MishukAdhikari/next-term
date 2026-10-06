---
title: Next Term vs Zed
description: "Zed is an open-source code editor with its own agent and external agents. Next Term is a macOS terminal for running CLI agents side by side, with status."
sidebar:
  label: Zed
head:
  - tag: title
    content: Next Term vs Zed for AI coding agents
---

Zed is an open-source code editor written in Rust, for macOS, Linux and Windows, with language servers, a debugger, extensions, real-time collaboration and remote development over SSH. For AI it has its own agent, edit predictions, and two ways to run other agents: External Agents such as Claude, Codex and Gemini CLI through the Agent Client Protocol, and Terminal Threads that run any agent CLI inside Zed, several at once. Next Term is a much smaller macOS terminal and editor with no AI of its own and no language servers. It runs command-line agents in tabs, reads each agent’s own screen to show whether it is working, done or waiting on you, quotes its question in a notification, and lets one agent run the others over MCP. If Zed is your editor, its Terminal Threads may be all you need; Next Term is for people who want a terminal built around agents, with status that needs no setup, next to whatever editor they use.

## At a glance

| Feature | Next Term | Zed |
|---|---|---|
| Platforms | macOS 13 or later | macOS, Linux, Windows |
| Price | Free | Free Personal plan; paid Pro and Business plans for more AI |
| Open source | ✓ MIT | ✓ GPL-3.0-or-later, with Apache-2.0 parts |
| Account | None | Not needed to edit; sign in for collaboration and Zed’s hosted AI |
| AI of its own | — Runs the agents you install | ✓ The Agent Panel and edit predictions, with hosted models or your own API keys |
| Agents from other vendors | ✓ Any agent that runs in a terminal; 20 recognised by name | ✓ External Agents over ACP, and Terminal Threads for any agent CLI |
| Several agents at once | ✓ Tabs and split panes | ✓ Parallel Agents in the Threads Sidebar, optionally in Git worktrees |
| Status of each agent | ✓ Read from the agent’s screen: working, done, waiting (with the question), failed | ✓ A status indicator for each thread in the sidebar |
| Notifications | ✓ Quote the agent’s question, no setup; Dock badge | ✓ When an agent finishes or waits; Terminal Threads notify on the terminal bell |
| MCP | ✓ An MCP server: one agent starts, prompts, waits for and reads the others | ✓ An MCP client, its servers forwarded to External Agents |
| Code editor | ✓ 103 languages, Go to File (<kbd>⌘P</kbd>) | ✓ Language servers, Vim mode, a much fuller editor |
| Debugger | — | ✓ Through the Debug Adapter Protocol |
| Extensions | — | ✓ Languages, themes, debuggers, MCP servers |
| Reviewing agent changes | ✓ Side-by-side diffs; stage, unstage or revert per hunk | ✓ Accept or reject each hunk; checkpoints; stage or unstage hunks in the Git Panel |
| Collaboration | — | ✓ Channels, shared projects, voice chat, screen sharing |
| Remote work | — | ✓ Remote development over SSH |

## Choose Zed if…

- **You want a full, fast editor** with language servers, a debugger and extensions, on macOS, Linux or Windows.
- **You want the agents inside the editor.** Zed’s own agent, External Agents and Terminal Threads all live in one Threads Sidebar, and you review their changes hunk by hunk.
- **You pair with people.** Channels, shared projects and voice chat are built in.
- **You work on remote machines** over SSH.

## Choose Next Term if…

- **You want agent status with nothing to configure.** Next Term reads each agent’s screen, the way you would, so Claude Code, Codex, Gemini CLI and 17 more show working, done or waiting on their tab as soon as they start. In Zed, a Terminal Thread notifies you when the program rings the terminal bell, and Claude Code has to be set to ring it.
- **You want the question in the notification.** When an agent asks for permission, Next Term’s notification quotes it and takes you to the tab.
- **You want one agent to run the others.** Next Term is an MCP server: an orchestrator can list every tab with its agent’s state, start agents, send prompts, wait and read their screens, across projects.
- **You want a small native Mac app,** about 3 MB, with no account and no AI service attached.

## Use both

- **Write and debug in Zed; run your terminal agents in Next Term** on the same folder. Next Term’s side-by-side diffs (<kbd>⌥⌘G</kbd>) and Zed’s Git Panel show the same changes.
- **Let Zed’s agent drive Next Term.** Zed is an MCP client: add a context server that runs `nxtrm mcp`, and Zed’s agent can start Claude Code or Codex in Next Term tabs, send them tasks, wait for them and read the results. Zed forwards its MCP servers to External Agents too.

## Questions

### Zed can already run Claude Code in a Terminal Thread. Why add Next Term?

If Zed is the only app you want open, Terminal Threads cover a lot. Next Term adds status read from each agent’s own screen, with no settings to change, notifications that quote the agent’s question, Claude Code’s, Gemini CLI’s and Qwen Code’s IDE link (your selection, and proposed edits as diffs to accept or reject), and an MCP server through which one agent orchestrates the others.

### Is Zed free?

Zed’s Personal plan is free, including unlimited use of your own API keys and of external agents; Pro and Business plans add hosted AI. The editor is open source. Next Term is free and open source too, with no paid tier.

### Does Next Term have a debugger or language servers?

No. Next Term’s editor colours 103 languages and finds files fast, but it has no debugger, language servers, refactoring or extensions. For those, keep Zed or another IDE next to it.

## Read more

- [Agent status in every tab](/docs/agent-status/)
- [Agents and the IDE link](/docs/agents/)
- [Orchestrate agents (MCP)](/docs/orchestration/)
- [Code editor](/docs/editor/)
- [Next Term compared with other tools](/compare/)

## Sources

**Checked October 2026** against Zed’s own site, documentation and repository. Products change quickly; if something here is out of date, please [open an issue](https://github.com/MishukAdhikari/next-term/issues).

- [Zed](https://zed.dev) (description, platforms) and [pricing](https://zed.dev/pricing) (checked 6 October 2026)
- [Zed on GitHub](https://github.com/zed-industries/zed) (licence)
- [Authentication](https://zed.dev/docs/authentication) (what needs an account)
- [External Agents](https://zed.dev/docs/ai/external-agents), [Terminal Threads](https://zed.dev/docs/ai/terminal-threads) and [Parallel Agents](https://zed.dev/docs/ai/parallel-agents)
- [Agent Panel](https://zed.dev/docs/ai/agent-panel) (reviewing changes, notifications) and [MCP](https://zed.dev/docs/ai/mcp)
- [Debugger](https://zed.dev/docs/debugger), [Git](https://zed.dev/docs/git), [Channels](https://zed.dev/docs/collaboration/channels) and [Remote Development](https://zed.dev/docs/remote-development)
