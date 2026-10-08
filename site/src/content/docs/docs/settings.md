---
title: Settings
description: "Next Term’s Settings (⌘,): fonts, line height, soft wrap, background git fetch, terminal colours, agent links, MCP, notifications, shortcuts and imports."
---

Open **Next Term › Settings…** (<kbd>⌘,</kbd>). Settings has five tabs: **Editor**, **Terminal**, **Notifications**, **Keyboard Shortcuts** and **Import**. Every change applies at once, to every window.

## Editor

| Setting | Default | What it does |
|---|---|---|
| **Font** | Next Term default | The editor’s font, from the monospaced fonts installed on this Mac. The default is JetBrains Mono when it is installed, else SF Mono. A font removed later falls back to the default. |
| **Font size** | 13 pt | From 8 to 32 pt. Shared with the terminal, so <kbd>⌘+</kbd> and <kbd>⌘-</kbd> change both. |
| **Line height** | 1.35× | A multiple of the font’s own line height, from 1.0 to 2.0 in steps of 0.05. 1.35 reads well for code. |
| **Wrap long lines at the edge** | On | Soft wrap, with a hanging indent. Also **View › Soft Wrap**. |
| **Hide values in .env files** | Off | Draws the values in `.env`, `.env.*`, `*.env` and `.flaskenv` files as dots, for screen sharing; the file itself does not change. **View › Hide .env Values** does it for one file. See [Hiding .env values](/docs/editor/#hiding-env-values). |
| **Sidebar: Open files with a single click** | Off | One click on a file in the project sidebar opens it in a preview tab, with its name in italics; the next file you click takes its place. Editing the file, double-clicking its tab or opening it any other way keeps it. The keyboard stays in the sidebar, and folders still open with their arrow or a double-click. Off, a click selects and a double-click opens, as in Finder. Also in the sidebar’s ⋯ menu. See [Preview tabs](/docs/editor/#preview-tabs). |
| **Sidebar: Icons on configuration folders (.github, .claude, .idea…)** | Off | Gives configuration folders their brand icons. Off, they stay plain and quiet. |
| **Git: Fetch in the background** | Every 10 minutes | How often Next Term fetches the remotes your branches track, so the sidebar can say **Pull 3** by itself: every 5, 10 or 30 minutes, **Only when opening the branch popup** (when the last fetch is over 5 minutes old), or **Off**. It never asks for a password and leaves `FETCH_HEAD` alone. See [Background fetch](/docs/projects-and-git/#background-fetch). |
| **Agents: Agents in a tab see the editor (Claude Code, Gemini CLI, Qwen Code)** | On | The IDE link. Agents started in a tab see your open files and selected lines (never from `.env` files), and their proposed edits open as diffs. Next Term keeps Gemini’s and Qwen’s IDE mode on while this is on. Off stops sharing. |
| **Let agents control Next Term (MCP: projects, tabs, prompts, the editor)** | On | Registers Next Term’s MCP server in your agents, so one can drive the others. The line below it says where it is registered. Off closes the server and removes Next Term’s entries (the Claude desktop app’s once Claude is closed). See [Orchestrate agents](/docs/orchestration/). |

More about the editor in [Code editor](/docs/editor/), and about the agent link in [Agents and the IDE link](/docs/agents/).

## Terminal

| Setting | Default | What it does |
|---|---|---|
| **Font** | Next Term default | The terminal’s font, from the monospaced fonts installed on this Mac. Its size is the editor’s. |
| **Colours** | Next Term default | Your own terminal colours: the 16 ANSI colours, text, background, cursor and selection, shown as a row of swatches. An import brings them over; colours it doesn’t set keep Next Term’s. **Next Term default** goes back, and your colours stay in the menu to choose again. |

## Notifications

Which of a tab’s notices reach Notification Center. None ever comes for the tab you are looking at, and the tab marks, the Dock badge and VoiceOver’s announcements come whatever is chosen here. See [Notifications and the Dock badge](/docs/agent-status/#notifications-and-the-dock-badge).

| Setting | Default | What it does |
|---|---|---|
| **Agents: When an agent needs your decision** | On | An agent asks for permission or for a choice: the notification names the agent and quotes the question. It comes in Next Term too, for a tab you are not looking at. |
| **Agents: When an agent finishes** | On | An agent stopped and is waiting for your next prompt, or exited. It comes in Next Term too, for a tab you are not looking at, unless another agent drives that tab over MCP. |
| **Commands: When one finishes or fails** | Only when I’m in another app | Anything that is not an agent: a build, a test run, a script. **Always, for tabs I’m not looking at** notifies in Next Term too; **Never** turns these off. |
| **Finished work: Only for work that took at least** | 5 seconds | 5 seconds, 30 seconds, 1 minute or 5 minutes, for an agent or a command that finished. A decision or a bell notifies whatever its length. |
| **Programs: A program’s own bell or notification (OSC 9/777)** | On | A program rang the bell, or sent a notification of its own, while you were in another app. Off, its tab still turns amber. |
| **Sound: Play a sound** | On | Off, notifications come without a sound. |

Below them, a line says whether macOS allows Next Term’s notifications: allowed; allowed but with the alert style None, so they go to Notification Center without a banner; off; or not answered yet. When they are off or without banners, **Open Notification Settings…** opens Next Term’s entry in **System Settings → Notifications**. **Send Test Notification** shows one, when macOS allows them, after asking you if you have not answered yet; when macOS does not show it, the line says so.

## Import

Bring your shortcuts, settings, fonts, terminal colours and recent projects from another app, choose which keys the menus use, and undo the last import. See [Switching to Next Term](/docs/switching/).

## Keyboard Shortcuts

Every menu command, with its shortcut and where it lives in the menus. Search by command or by shortcut, click a shortcut and press new keys, <kbd>⌫</kbd> to remove it, <kbd>⎋</kbd> to cancel. **Default** puts one command back; **Restore All Defaults** puts them all back. See [Keyboard shortcuts](/docs/keyboard-shortcuts/) for the full default list.

## Preferences in the menus

Some choices live where you use them. The File and View menus, and the ⋯ buttons, show a checkmark next to the choice in effect:

| Preference | Where | Default |
|---|---|---|
| Terminal position: bottom, right, left or top | **View › Terminal Position**, or the terminal’s ⋯ button | Bottom |
| Project sidebar on the right | **View › Project Sidebar on the Right**, or a ⋯ button | Left |
| Line height presets | **View › Line Height** | 1.35 |
| Open files with a single click | The project sidebar’s ⋯ button, or **Settings › Editor** | Off |
| Soft wrap | **View › Soft Wrap** | On |
| Where projects open | **File › Open Projects In**: Ask Each Time, This Window, New Window | Ask Each Time |
| Option as Meta (for Emacs-style keys in the terminal) | **File › Use Option as Meta Key** | Off |
| Daily update check | **Next Term › Check for Updates Automatically** | On |

Next Term remembers the window layout, the split between editor and terminal, the sidebar’s width, and the project windows that were open when you quit.
