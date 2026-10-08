---
title: Settings
description: "Next Term’s Settings (⌘,): fonts, wrap, clean-up on save, hidden files, git fetch, terminal colours, cursor, scrollback, agents, notifications, imports."
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
| **On save: Trim trailing spaces** | Off | Removes the spaces and tabs at the end of every line as you save. Markdown and patch files keep theirs. One step for <kbd>⌘Z</kbd>. See [Clean-up on save](/docs/editor/#clean-up-on-save). |
| **On save: End files with a newline** | Off | Adds a line break after the last line as you save, when that line has something on it. |
| **Sidebar: Open files with a single click** | Off | One click on a file in the project sidebar opens it in a preview tab, with its name in italics; the next file you click takes its place. Editing the file, double-clicking its tab or opening it any other way keeps it. The keyboard stays in the sidebar, and folders still open with their arrow or a double-click. Off, a click selects and a double-click opens, as in Finder. Also in the sidebar’s ⋯ menu. See [Preview tabs](/docs/editor/#preview-tabs). |
| **Sidebar: Icons on configuration folders (.github, .claude, .idea…)** | Off | Gives configuration folders their brand icons. Off, they stay plain and quiet. |
| **Sidebar: Hide** | Empty | Files and folders the project sidebar leaves out, by pattern, between commas, read as `.gitignore` reads them: `node_modules` or `*.log` in every folder, `/build` only at the top of the folder the sidebar shows, `out/` only folders. Applied when you press Return or leave the field. See [The project sidebar](/docs/projects-and-git/#the-project-sidebar). |
| **Git: Fetch in the background** | Every 10 minutes | How often Next Term fetches the remotes your branches track, so the sidebar can say **Pull 3** by itself: every 5, 10 or 30 minutes, **Only when opening the branch popup** (when the last fetch is over 5 minutes old), or **Off**. It never asks for a password and leaves `FETCH_HEAD` alone. See [Background fetch](/docs/projects-and-git/#background-fetch). |
| **Agents: Agents in a tab see the editor (Claude Code, Gemini CLI, Qwen Code, opencode)** | On | The IDE link. Agents started in a new tab see your selected lines, and Gemini and Qwen your open files too (never from `.env` files). Their proposed edits open as diffs. Next Term keeps Gemini’s and Qwen’s IDE mode on while this is on. Off stops sharing. |
| **GitHub Copilot CLI in a tab sees the editor** | On | Copilot CLI’s IDE link. A `copilot` started in a tab’s folder or an open project sees your selected lines (never from `.env` files), <kbd>⌥⌘K</kbd> puts an @-mention in its prompt, and its proposed edits open as diffs. Off stops the link and removes its lock file from `~/.copilot/ide`. |
| **Let agents control Next Term (MCP: projects, tabs, prompts, the editor)** | On | Registers Next Term’s MCP server in your agents, so one can drive the others. The line below it says where it is registered. Off closes the server and removes Next Term’s entries (the Claude desktop app’s once Claude is closed). See [Orchestrate agents](/docs/orchestration/). |

More about the editor in [Code editor](/docs/editor/), and about the agent link in [Agents and the IDE link](/docs/agents/).

## Terminal

| Setting | Default | What it does |
|---|---|---|
| **Font** | Next Term default | The terminal’s font, from the monospaced fonts installed on this Mac. Its size is the editor’s. |
| **Colours** | Next Term default | Your own terminal colours: the 16 ANSI colours, text, background, cursor and selection, shown as a row of swatches. An import brings them over; colours it doesn’t set keep Next Term’s. **Next Term default** goes back, and your colours stay in the menu to choose again. |
| **Cursor** | Block, **Blink** on | **Block**, **Bar** or **Underline**, blinking or not, in every open terminal at once. A program can set its own cursor (vim’s bar while you type); when it puts the cursor back, or asks for a blinking block, which reads the same, yours returns. |
| **Scrollback** | 10,000 lines | The lines each terminal keeps above the screen: 1,000, 5,000, 10,000, 25,000, 50,000 or 100,000, or the number an import brought. Open terminals change at once, and fewer lines drops the oldest. |
| **New tabs** | In the project’s folder | Where <kbd>⌘T</kbd> opens a tab: **In the project’s folder** (in a window without a project, the current tab’s folder), **In the current tab’s folder**, **In your home folder**, or a folder you choose with **Choose Folder…**. A chosen folder that is gone falls back to the first. A split opens in the folder of the pane it splits from. |

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
