---
title: Next Term vs PhpStorm
description: "PhpStorm is the PHP IDE for Laravel, Symfony and WordPress, with Xdebug and tests. Next Term runs your AI coding agents side by side on a Mac, next to it."
sidebar:
  label: PhpStorm
head:
  - tag: title
    content: Next Term vs PhpStorm for AI coding agents
---

PhpStorm is JetBrains’ IDE for PHP, on Windows, macOS and Linux. It understands PHP and its frameworks (Laravel support is now built in and free, alongside Symfony, WordPress and Drupal), debugs with Xdebug or Zend Debugger, runs PHPUnit, Pest, Behat, Codeception and phpspec tests, and includes database tools. For AI it offers Junie, Claude Agent and Codex in its AI Chat, more agents through the Agent Client Protocol, a terminal that starts Claude Code, Codex or Junie, and a built-in MCP server that agents can use. Next Term is not a PHP IDE: it has no PHP code intelligence, debugger or test runner. It is a free macOS terminal and editor for running agents such as Claude Code and Codex side by side, with each agent’s status on its tab, and its editor colours PHP, Blade and Twig. For PHP work, keep PhpStorm and run your agents in Next Term next to it.

## At a glance

| Feature | Next Term | PhpStorm |
|---|---|---|
| Platforms | macOS 13 or later | Windows, macOS, Linux |
| Price | Free, MIT | A subscription, with a 30-day trial; free for students and for non-commercial open-source work |
| PHP code intelligence | — Highlighting only: PHP, Blade, Twig and 109 more languages | ✓ Inspections, navigation, refactoring |
| Laravel, Symfony, WordPress, Drupal | — | ✓ Laravel support built in and free |
| Debugging | — | ✓ Xdebug and Zend Debugger |
| Tests | Run them in a tab or split pane | ✓ PHPUnit, Pest, Behat, Codeception, phpspec |
| Database tools | Partly: the databases a project names (Laravel’s `DB_*` keys too) in the sidebar, a read-only SQLite viewer, and hand-offs to TablePlus, mysql or psql | ✓ Bundled |
| AI of its own | — Runs the agents you install | ✓ Junie and AI Assistant; AI Free comes with the subscription |
| Agents from other vendors | ✓ Any agent that runs in a terminal; 20 recognised by name | ✓ Claude Agent and Codex in AI Chat; Copilot, Cursor and others through ACP |
| Several agents at once, with their status | ✓ Tabs and split panes, with status on every tab | Partly: Air, in early access, shows parallel sessions |
| MCP | ✓ An MCP server for orchestration: start, prompt, wait for and read agents | ✓ An MCP server that gives agents the IDE’s tools |
| Claude Code’s IDE link | ✓ Built in, also for Gemini CLI and Qwen Code | ✓ Anthropic’s plugin supports PhpStorm |
| Reviewing changes | ✓ Side-by-side diffs; stage, unstage or revert per hunk; the Git Log and blame | ✓ The IDE’s diff viewer; commit chosen chunks and lines |
| Remote development | Partly: terminal tabs on your servers over ssh, kept running in tmux or herdr; the editor opens your Mac’s files | ✓ SSH, dev containers, JetBrains Gateway |

## Choose PhpStorm if…

- **You write PHP for a living.** Inspections, refactoring and navigation that understand your code, and framework support for Laravel, Symfony, WordPress and Drupal.
- **You debug with Xdebug** or run PHPUnit and Pest tests from the editor.
- **You query and change databases** from the same window.
- **You want agents inside the IDE,** in AI Chat or, in early access, in Air.

## Choose Next Term if…

- **You hand more of the typing to agents.** Run Claude Code on the back end, Codex on the front end and `php artisan test` in a split pane, each with its status on its tab, and a notification that quotes any agent’s question.
- **You want to read every change before it lands.** Claude Code’s proposed edits open as diffs to accept or reject, and <kbd>⌥⌘G</kbd> shows any file’s changes side by side, with per-hunk stage, unstage and revert.
- **You want one agent to coordinate the others** across your projects, say an API and a theme, through Next Term’s MCP server.
- **You want a light window for agent work** that opens next to PhpStorm and costs nothing.

## Use both

This is the setup Next Term is made for in a PHP shop: PhpStorm for code, Next Term for agents.

- **Open the project in both.** `nxtrm .` in PhpStorm’s terminal opens the folder as a Next Term project. Run your agents, test watchers and `php artisan serve` in Next Term tabs.
- **Debug in PhpStorm.** When an agent’s change breaks something, set a breakpoint and step through it with Xdebug in PhpStorm.
- **Find the database in either.** Next Term lists the database your `.env` names (Herd projects included) in the sidebar, password masked, and opens it in TablePlus, or in mysql in a tab when it is local. PhpStorm’s database tools query and change it.
- **Give the agents PhpStorm’s tools.** PhpStorm’s built-in MCP server lets Claude Code, Codex and other agents use the IDE’s tools, and PhpStorm 2026.2 made setting it up for terminal agent sessions faster. A configured agent has those tools in a Next Term tab too.
- **Send code to an agent from either side.** In Next Term, <kbd>⌥⌘K</kbd> types `@app/Http/Controllers/UserController.php#L10-20` into Claude’s prompt. In PhpStorm, Anthropic’s plugin shares your selection when Claude is connected to the IDE.

## Questions

### Does Next Term understand Laravel or WordPress?

No. It colours PHP (with the HTML around `<?php … ?>`), Blade, Twig and the rest, finds files with <kbd>⌘P</kbd>, and searches and replaces across the project, but it has no PHP language intelligence or framework support. Your agents bring the understanding; PhpStorm brings the IDE.

### Can I debug PHP in Next Term?

No. Next Term has no debugger. Use PhpStorm with Xdebug, and keep Next Term for the agents.

### Is PhpStorm free?

No. PhpStorm is a subscription with a 30-day trial. JetBrains offers it free to students and for non-commercial open-source work, and its Laravel support is included at no extra cost. Next Term is free under the MIT licence.

### Can Claude Code connect to PhpStorm and Next Term?

To one at a time. A `claude` started in a Next Term tab connects to Next Term. Run `/ide` in Claude Code to connect it to PhpStorm instead, with Anthropic’s plugin installed there.

## Read more

- [Agents and the IDE link](/docs/agents/)
- [Code editor](/docs/editor/) (the languages, including PHP and Blade)
- [Layouts and split panes](/docs/layouts/)
- [Orchestrate agents (MCP)](/docs/orchestration/)
- [Next Term vs JetBrains IDEs](/compare/jetbrains/)

## Sources

**Checked October 2026** against JetBrains’ own site and help, and Anthropic’s Claude Code documentation. Products change quickly; if something here is out of date, please [open an issue](https://github.com/MishukAdhikari/next-term/issues).

- [PhpStorm](https://www.jetbrains.com/phpstorm/) and [features](https://www.jetbrains.com/phpstorm/features/) (frameworks, Xdebug, tests)
- [What’s New in PhpStorm 2026.2](https://www.jetbrains.com/phpstorm/whatsnew/)
- [Laravel in PhpStorm](https://www.jetbrains.com/phpstorm/laravel/) and [Drupal support](https://www.jetbrains.com/help/phpstorm/drupal-support.html)
- [Buy PhpStorm](https://www.jetbrains.com/phpstorm/buy/) (checked 6 October 2026) and [free licences for open source](https://www.jetbrains.com/community/opensource/)
- [Databases in PhpStorm](https://www.jetbrains.com/help/phpstorm/relational-databases.html)
- [PhpStorm’s MCP server](https://www.jetbrains.com/help/phpstorm/mcp-server.html)
- [Claude Code in JetBrains IDEs](https://code.claude.com/docs/en/jetbrains)
