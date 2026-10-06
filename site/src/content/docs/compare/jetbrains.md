---
title: Next Term vs JetBrains IDEs
description: "IntelliJ IDEA, WebStorm, GoLand and the other JetBrains IDEs next to Next Term: what each does better for AI coding agents, and how to use them together."
sidebar:
  label: JetBrains IDEs
head:
  - tag: title
    content: Next Term vs JetBrains IDEs for AI coding agents
---

JetBrains IDEs (IntelliJ IDEA, WebStorm, GoLand, PhpStorm, PyCharm, Rider, RubyMine, CLion, RustRover and DataGrip) are full IDEs for Windows, macOS and Linux, with code inspections, refactoring, debuggers, a plugin Marketplace and remote development. For AI they offer AI Assistant, with Junie, Claude Agent, Codex and GitHub Copilot in one chat and more agents through the Agent Client Protocol; a terminal that starts Claude Code, Codex or Junie from its toolbar; a built-in MCP server that outside agents can use; and Air, in early access, for running several agents in parallel. Next Term is not an IDE. It is a small, free macOS terminal and editor for running command-line agents side by side, with each agent’s status on its tab and an MCP server through which one agent runs the others. Keep your JetBrains IDE for writing, navigating, refactoring and debugging code, and add Next Term if you run several terminal agents at once. There are dedicated pages for [PhpStorm](/compare/phpstorm/) and [PyCharm](/compare/pycharm/).

## At a glance

| Feature | Next Term | JetBrains IDEs |
|---|---|---|
| Platforms | macOS 13 or later | Windows, macOS, Linux |
| Price | Free, MIT | Subscriptions; WebStorm, Rider, CLion, RustRover, RubyMine and DataGrip are free for non-commercial use; IntelliJ IDEA and PyCharm have free core features |
| Code inspections and refactoring | — | ✓ |
| Debugger | — | ✓ |
| Plugins | — | ✓ The JetBrains Marketplace |
| AI of its own | — Runs the agents you install | ✓ AI Assistant and Junie; AI Free comes with IDE subscriptions, AI Pro and AI Ultimate are paid plans |
| Agents from other vendors | ✓ Any agent that runs in a terminal; 20 recognised by name | ✓ Claude Agent, Codex and Copilot in AI Chat; ACP agents; Claude Code, Codex and Junie from the terminal |
| Several agents at once, with their status | ✓ Tabs and split panes, with status on every tab | Partly: Air, in early access, shows parallel sessions across projects |
| MCP | ✓ An MCP server for orchestration: start, prompt, wait for and read agents | ✓ An MCP server that gives agents the IDE’s tools, and an MCP client in AI Assistant |
| Claude Code’s IDE link | ✓ Built in, also for Gemini CLI and Qwen Code | ✓ Anthropic’s plugin: diffs in the IDE’s viewer, selection, diagnostics |
| Reviewing changes | ✓ Side-by-side diffs; stage, unstage or revert per hunk | ✓ The IDE’s diff viewer; commit chosen chunks and lines |
| Remote development | — | ✓ SSH, dev containers, WSL, JetBrains Gateway |
| Real-time collaboration | — | Partly: Code With Me is being retired; its service ends in the first quarter of 2027 |
| The app | Native Swift and AppKit, about a 3 MB download | Full IDEs |

## Choose a JetBrains IDE if…

- **You want an IDE that understands your code:** inspections, refactoring, navigation and a debugger for your language and framework.
- **You work on Windows or Linux,** on remote machines, in dev containers or in WSL.
- **You want agents inside the IDE.** Junie, Claude Agent, Codex and Copilot share AI Chat, ACP brings in others, and Air, in early access, runs several in parallel with worktrees.
- **Your team already works in JetBrains IDEs** and shares their settings and inspections.

## Choose Next Term if…

- **You run Claude Code, Codex, Gemini CLI or other agents in a terminal** and want them side by side, each with its status on its tab and a notification that quotes its question.
- **You use several IDEs, or none.** Next Term works next to any editor, and its agents work on any project folder.
- **You want one agent to orchestrate the others** across projects, through Next Term’s MCP server.
- **You want something small and free for the agents:** about 3 MB, MIT-licensed, no account and no subscription.

## Use both

For most JetBrains users this is the setup that makes sense: the IDE for code, Next Term for the agents.

- **Open the project in both.** `nxtrm .` in the IDE’s terminal opens the folder as a Next Term project; run your agents there.
- **Give the agents in Next Term the IDE’s tools.** JetBrains IDEs have a built-in MCP server that Claude Code, Codex and other agents can use to build the project, read the problems the IDE found in a file and rename symbols, and the IDE can configure detected agents for you. A configured agent has those tools in a Next Term tab too.
- **Let Junie drive Next Term.** Junie reads `~/.junie/mcp/mcp.json`, in the IDE and in its CLI. Next Term adds its own server there when that file exists or the Junie CLI is installed, so Junie can start agents in Next Term tabs, give them tasks and read the results.
- **Review where you like.** A `claude` started in Next Term connects to Next Term, and proposed edits open in Next Term’s diff view. To use the IDE’s diff viewer for a session instead, run `/ide` in Claude Code and pick your JetBrains IDE (with Anthropic’s plugin installed).

## Questions

### Can’t I run Claude Code in the IDE’s own terminal?

Yes. The IDE’s terminal has a menu that starts Claude Code, Codex or Junie and can split into panes, and Anthropic’s plugin shows Claude’s edits in the IDE’s diff viewer. What Next Term adds is an overview of many agents from different vendors at once: a status mark on every tab, notifications that quote each question, and an MCP server through which one agent runs the others.

### How is Next Term different from JetBrains Air?

Air is JetBrains’ new way to run several agents in parallel inside its IDEs, with every session in one place, across projects, and temporary worktrees; it is in early access as a plugin and in the 2026.3 EAP builds. Next Term is a separate, MIT-licensed Mac app that works next to any editor and runs agents as plain terminal programs.

### Do I need a JetBrains AI subscription to use agents?

Not for every agent. IDE subscriptions include AI Free, AI Pro and AI Ultimate add more, and agents connected through ACP work without a JetBrains AI subscription. Next Term needs no subscription of its own; each agent uses its own sign-in.

## Read more

- [Agent status in every tab](/docs/agent-status/)
- [Agents and the IDE link](/docs/agents/)
- [Orchestrate agents (MCP)](/docs/orchestration/)
- [The nxtrm command](/docs/command-line/)
- [Next Term vs PhpStorm](/compare/phpstorm/) and [Next Term vs PyCharm](/compare/pycharm/)

## Sources

**Checked October 2026** against JetBrains’ own site, help and blog, and Anthropic’s Claude Code documentation. Products change quickly; if something here is out of date, please [open an issue](https://github.com/MishukAdhikari/next-term/issues).

- [IntelliJ IDEA installation guide](https://www.jetbrains.com/help/idea/installation-guide.html) (platforms, unified IntelliJ IDEA)
- [JetBrains store](https://www.jetbrains.com/store/) (subscriptions, free non-commercial licences; checked 6 October 2026)
- [AI plans](https://www.jetbrains.com/ai-ides/buy/), [agents in AI Assistant](https://www.jetbrains.com/help/ai-assistant/agents.html) and [ACP](https://www.jetbrains.com/help/ai-assistant/acp.html)
- [MCP server](https://www.jetbrains.com/help/idea/mcp-server.html) and [terminal](https://www.jetbrains.com/help/idea/terminal-emulator.html)
- [Air in IDEs, early access](https://blog.jetbrains.com/ai/2026/10/air-in-ides-eap/)
- [Sunsetting Code With Me](https://blog.jetbrains.com/platform/2026/03/sunsetting-code-with-me/)
- [Remote development](https://www.jetbrains.com/help/idea/remote-development-overview.html)
- [Junie CLI: MCP configuration](https://junie.jetbrains.com/docs/junie-cli-mcp-configuration.html)
- [Claude Code in JetBrains IDEs](https://code.claude.com/docs/en/jetbrains)
