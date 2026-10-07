---
title: Next Term vs Devin Desktop (formerly Windsurf)
description: "Devin Desktop, formerly Windsurf, is an AI editor with local and cloud agents. Next Term is a free macOS terminal for the agent CLIs you already use."
sidebar:
  label: Devin Desktop (Windsurf)
head:
  - tag: title
    content: Next Term vs Devin Desktop (formerly Windsurf)
---

Devin Desktop is the new name for Windsurf, Cognition’s AI code editor, since June 2026. It is built on VS Code OSS, runs on macOS, Windows and Linux, and centres on an Agent Command Center that shows local and cloud agents on a board grouped by status. Its own local agent, Devin Local, replaced Cascade; Devin cloud agents run on their own virtual machines; and on paid plans it can run Codex, Claude Agent, Gemini CLI and other agents through the Agent Client Protocol. It needs a Devin account, with a free plan and paid plans. Next Term is a free, open-source macOS terminal and editor with no AI of its own: it runs any command-line agent in its own tab, shows each agent’s status, and lets one agent run the others over MCP. Choose Devin Desktop for an editor, models and cloud agents in one subscription. Choose Next Term to run the agent CLIs you already have, as they are, in a small native app.

## At a glance

| Feature | Next Term | Devin Desktop |
|---|---|---|
| Platforms | macOS 13 or later | macOS, Windows, Linux |
| Price | Free | Free plan with a light quota; paid plans |
| Open source | ✓ MIT | — |
| Account | None | A Devin account |
| AI of its own | — Runs the agents you install | ✓ Devin Local, Tab completions, Cognition’s SWE models and models from other providers |
| Agents from other vendors | ✓ Any agent that runs in a terminal; 20 recognised by name | Partly: Codex, Claude Agent, Gemini CLI and other ACP agents, on paid plans |
| Several agents at once | ✓ Tabs and split panes | ✓ The Agent Command Center, with Spaces that share Git worktrees |
| Status of each agent | ✓ On every tab: working, done, waiting (with the question), failed | ✓ A board grouped by status: blocked, ready for review and so on |
| Notifications | ✓ Quote the agent’s question; Dock badge | ✓ When a session finishes or needs input; off by default |
| Cloud agents | — Agents run on your Mac, or on your own servers in remote tabs | ✓ Devin cloud agents, on paid plans |
| MCP | ✓ An MCP server: one agent starts, prompts, waits for and reads the others | ✓ An MCP client for the tools you add |
| Code editor | ✓ 112 languages, Go to File (<kbd>⌘P</kbd>); no language servers | ✓ A full editor on VS Code OSS, with extensions from Open VSX |
| Reviewing agent changes | ✓ Side-by-side diffs, stage, unstage or revert per hunk; the Git Log and blame | ✓ Diff zones with accept and reject for each hunk |
| Remote work | Partly: terminal tabs on your servers over ssh, kept running in tmux or herdr | ✓ Remote-SSH, Dev Containers, WSL (beta) |
| The app | Native Swift and AppKit, about a {{DOWNLOAD_SIZE}} download | Built on VS Code OSS |

## Choose Devin Desktop if…

- **You want agents, models and an editor from one company.** Devin Local, Tab completions and Cognition’s SWE models come with the plan, and the same app manages Devin cloud agents.
- **You want agents in the cloud.** Devin sessions run on their own virtual machines and appear on the same board as your local agents.
- **You like a board view.** The Agent Command Center groups every agent by status, so you see what is blocked and what is ready for review.
- **You work on Windows or Linux,** or over SSH, in dev containers or in WSL.

## Choose Next Term if…

- **You want to run Claude Code, Codex or Gemini CLI as they are,** in a terminal, signed in the way each one normally is, without an editor plan in between. In Devin Desktop, third-party agents need a paid plan.
- **You want every agent in its own terminal tab,** with its status on the tab and a notification that quotes its question, on by default.
- **You want one agent to run the others,** across projects, through Next Term’s MCP server.
- **You want no account and nothing to pay.** Next Term is free, MIT-licensed, about a {{DOWNLOAD_SIZE}} download, and on its own talks only to GitHub, for a daily update check, and to your projects’ own git remotes, to fetch. You can turn off either.

## Use both

- **Keep Devin Desktop for editing, Tab completions and cloud agents,** and run your terminal agents in Next Term on the same folder.
- **Let Devin’s agent drive Next Term.** Devin Desktop is an MCP client: add a stdio server that runs `nxtrm mcp`, and its agent can start Claude Code or Codex in Next Term tabs, send them tasks, wait for them and read the results.
- **Review in either.** Both show agents’ changes per hunk, so you can accept work in one and stage it in the other.

## Questions

### What happened to Windsurf?

Cognition renamed it. “Devin Desktop is the new name for Windsurf,” and existing installs update to it, keeping plans, extensions and settings. The Windsurf plugin for JetBrains IDEs is in maintenance mode.

### Can Devin Desktop run Claude Code?

It runs **Claude Agent**, Codex CLI, Gemini CLI, OpenCode, Junie and other agents through the Agent Client Protocol, on the Pro, Max and Teams plans; billing for those agents is between you and their providers. Next Term runs the `claude` command itself, in a terminal tab, on any setup.

### Does Next Term have cloud agents?

No. Agents run in Next Term’s tabs: on your Mac, or in [remote tabs](/docs/remote/) on servers you reach with your own ssh. Its MCP server listens on a private socket with no network port, and is never forwarded to a server.

## Read more

- [Agent status in every tab](/docs/agent-status/)
- [Orchestrate agents (MCP)](/docs/orchestration/)
- [Side-by-side diffs](/docs/diffs/)
- [Security and privacy](/docs/security-and-privacy/)
- [Next Term compared with other tools](/compare/)

## Sources

**Checked October 2026** against Cognition’s own site and documentation. Products change quickly; if something here is out of date, please [open an issue](https://github.com/MishukAdhikari/next-term/issues).

- [Devin Desktop](https://devin.ai/desktop) and [the rename announcement](https://devin.ai/blog/windsurf-is-now-devin-desktop) (2 June 2026)
- [Devin Desktop FAQ](https://docs.devin.ai/desktop/devin-desktop-faq)
- [Download](https://devin.ai/download) (platforms) and [pricing](https://devin.ai/pricing) (checked 6 October 2026)
- [Agent Command Center](https://docs.devin.ai/desktop/agent-command-center) (status board, notifications)
- [Agent Client Protocol](https://docs.devin.ai/desktop/acp) (third-party agents)
- [Advanced](https://docs.devin.ai/desktop/advanced) (diff zones, Remote-SSH, Dev Containers, WSL) and [recommended extensions](https://docs.devin.ai/desktop/recommended-extensions) (VS Code OSS, Open VSX)
- [MCP](https://docs.devin.ai/desktop/cascade/mcp) and [models](https://docs.devin.ai/desktop/models)
- [Changelog](https://docs.devin.ai/desktop/changelog) (Cascade removed, Devin Local)
