---
title: Settings
description: "Next Term’s Settings (⌘,): line height, font size, soft wrap, sidebar icons, the agent link and MCP switches, every shortcut, and menu preferences."
---

Open **Next Term › Settings…** (<kbd>⌘,</kbd>). Settings has two tabs, **Editor** and **Keyboard Shortcuts**. Every change applies at once, to every window.

## Editor

| Setting | Default | What it does |
|---|---|---|
| **Line height** | 1.35× | A multiple of the font’s own line height, from 1.0 to 2.0 in steps of 0.05. 1.35 reads well for code. |
| **Font size** | 13 pt | From 8 to 32 pt. Shared with the terminal, so <kbd>⌘+</kbd> and <kbd>⌘-</kbd> change both. |
| **Wrap long lines at the edge** | On | Soft wrap, with a hanging indent. Also **View › Soft Wrap**. |
| **Sidebar: Icons on configuration folders (.github, .claude, .idea…)** | Off | Gives configuration folders their brand icons. Off, they stay plain and quiet. |
| **Agents: Agents in a tab see the editor (Claude Code, Gemini CLI, Qwen Code)** | On | The IDE link. Agents started in a tab see your open files and selected lines (never from `.env` files), and their proposed edits open as diffs. Next Term keeps Gemini’s and Qwen’s IDE mode on while this is on. Off stops sharing. |
| **Let agents control Next Term (MCP: projects, tabs, prompts, the editor)** | On | Registers Next Term’s MCP server in your agents, so one can drive the others. The line below it says where it is registered. Off closes the server and removes Next Term’s entries. See [Orchestrate agents](/docs/orchestration/). |

More about the editor in [Code editor](/docs/editor/), and about the agent link in [Agents and the IDE link](/docs/agents/).

## Keyboard Shortcuts

Every menu command, with its shortcut and where it lives in the menus. Search by command or by shortcut, click a shortcut and press new keys, <kbd>⌫</kbd> to remove it, <kbd>⎋</kbd> to cancel. **Default** puts one command back; **Restore All Defaults** puts them all back. See [Keyboard shortcuts](/docs/keyboard-shortcuts/) for the full default list.

## Preferences in the menus

Some choices live where you use them. The View and Shell menus show a checkmark next to the choice in effect:

| Preference | Where | Default |
|---|---|---|
| Terminal position: bottom, right, left or top | **View › Terminal Position**, or the terminal’s ⋯ button | Bottom |
| Project sidebar on the right | **View › Project Sidebar on the Right**, or a ⋯ button | Left |
| Line height presets | **View › Line Height** | 1.35 |
| Soft wrap | **View › Soft Wrap** | On |
| Where projects open | **Shell › Open Projects In**: Ask Each Time, This Window, New Window | Ask Each Time |
| Option as Meta (for Emacs-style keys in the terminal) | **Shell › Use Option as Meta Key** | Off |
| Daily update check | **Next Term › Check for Updates Automatically** | On |

Next Term remembers the window layout, the split between editor and terminal, the sidebar’s width, and the project windows that were open when you quit.
