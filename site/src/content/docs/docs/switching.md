---
title: Switching from VS Code or JetBrains
description: "Bring your shortcuts, settings and recent projects from VS Code, Cursor, PhpStorm and other JetBrains IDEs, Zed or iTerm2. Nothing changes until you apply."
sidebar:
  label: Switching to Next Term
---

Next Term can use the shortcuts and settings you already have. **Nothing changes unless you choose it:** you see every change first, and one click undoes the whole import.

## Bring your settings over

On first launch, if Next Term finds VS Code, Cursor, Devin Desktop, a JetBrains IDE (PhpStorm, PyCharm, IntelliJ IDEA, WebStorm, Android Studio and the rest), Zed or iTerm2, it asks **Coming from another app?** The default keeps Next Term’s shortcuts. Any time later: **Next Term › Import Settings and Shortcuts…**, or **Settings › Import**.

Choose an app and the preview lists what it would bring, each item a checkbox with where it came from:

- **Shortcuts:** the matching set of keys (below).
- **Settings:** font size, line height, soft wrap, Option as Meta, where the terminal sits and the sidebar’s side, from the values you set in that app.
- **Recent projects:** your recent folders, added to **Open Recent** and the Welcome window after Next Term’s own.
- **Not brought over:** everything else, each with the reason (“font choice is coming”, “never imported: can hold secrets”). **Copy List for Your Agent** puts it on the clipboard, so Claude Code or Codex can help with the rest.

**Apply** saves what it is about to change first. **Settings › Import › Undo Import** puts every one of those values back.

## Keep the keys you know

**Settings › Import › Shortcuts from** chooses the keys, and an import can set it for you. Only the commands whose keys differ change; everything else keeps Next Term’s keys, and your own changes in **Keyboard Shortcuts** always stay on top.

| Command | Next Term | VS Code | JetBrains (macOS) |
|---|---|---|---|
| New Window | <kbd>⌘N</kbd> | <kbd>⇧⌘N</kbd> | <kbd>⌘N</kbd> |
| Go to File | <kbd>⌘P</kbd> | <kbd>⌘P</kbd> | <kbd>⇧⌘O</kbd> |
| Save | <kbd>⌘S</kbd> | <kbd>⌘S</kbd> | <kbd>⌥⌘S</kbd> |
| Save All | <kbd>⌥⌘S</kbd> | <kbd>⌥⌘S</kbd> | <kbd>⌘S</kbd> |
| Split Right | <kbd>⌘D</kbd> | <kbd>⌘&#92;</kbd> | <kbd>⌘&#92;</kbd> |
| Replace in Files | <kbd>⇧⌘R</kbd> | <kbd>⇧⌘H</kbd> | <kbd>⇧⌘R</kbd> |
| Indent / Outdent | <kbd>⌘]</kbd> / <kbd>⌘[</kbd> | <kbd>⌘]</kbd> / <kbd>⌘[</kbd> | no key (<kbd>⇥</kbd> and <kbd>⇧⇥</kbd> indent) |

With either set, <kbd>⌘K</kbd> clears only while a terminal has the keyboard, because both editors use <kbd>⌘K</kbd> for other things in their editors.

Two rules keep the terminal working the way your shell and agents expect: a set never takes a Control key without <kbd>⌘</kbd> (Claude Code and the shell use <kbd>⌃R</kbd>, <kbd>⌃G</kbd> and the rest), and never a key macOS keeps for itself.

## What it reads, and what it never touches

- **Only this Mac, only reading.** Next Term never writes to the other app, never copies its databases, and sends nothing anywhere.
- **Only the settings it can use.** Files that can hold credentials, such as license keys, saved logins and terminal environment variables, are never opened, and anything that looks like a secret never enters the preview.
- **Nothing runs.** Shell paths, terminal profiles, tasks and launch configurations are listed, never imported.

## Coming next

<span class="nt-soon">Coming next</span> Your own key changes from VS Code and JetBrains keymaps, font choice and terminal colours, and more terminals (Ghostty, Warp, Terminal.app).
