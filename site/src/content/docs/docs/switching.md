---
title: Switching from VS Code or JetBrains
description: "Bring shortcuts, settings, fonts, colours and recent projects from VS Code, Cursor, JetBrains, Zed, iTerm2, Ghostty, Warp or Terminal. You see it first."
sidebar:
  label: Switching to Next Term
---

Next Term can use the shortcuts and settings you already have. **Nothing changes unless you choose it:** you see every change first, and one click undoes the whole import.

## Bring your settings over

On first launch, if Next Term finds VS Code, Cursor, Devin Desktop, a JetBrains IDE (PhpStorm, PyCharm, IntelliJ IDEA, WebStorm, Android Studio and the rest), Zed, iTerm2, Ghostty, Warp, or a Terminal profile you chose or changed, it asks **Coming from another app?** The default keeps Next Term’s shortcuts. Any time later: **Next Term › Import Settings and Shortcuts…**, or **Settings › Import**.

Choose an app and the preview lists what it would bring, each item a checkbox with where it came from:

- **Shortcuts:** the matching set of keys (below).
- **Your shortcuts:** the keys you changed yourself, from VS Code’s `keybindings.json` (and Cursor’s, Devin Desktop’s), your JetBrains keymap, or Ghostty’s `keybind` lines that have a Next Term command. A key another command already has, or a Control key without <kbd>⌘</kbd>, comes in unticked with the reason.
- **Settings:** font size, line height, soft wrap, Option as Meta, where the terminal sits and the sidebar’s side, from the values you set in that app.
- **Fonts:** the editor font and the terminal font. A font comes over only when it is installed on this Mac and monospaced; from a list such as VS Code’s `editor.fontFamily`, the first one that is.
- **Terminal colours:** the 16 ANSI colours, text, background, cursor and selection, shown as a row of swatches. A colour the other app doesn’t set keeps Next Term’s.
- **Recent projects:** your recent folders, added to **Open Recent** and the Welcome window after Next Term’s own.
- **Not brought over:** everything else, each with the reason (“not installed on this Mac”, “never imported: can hold secrets”). **Copy List for Your Agent** puts it on the clipboard, so Claude Code or Codex can help with the rest.

**Apply** saves what it is about to change first. **Settings › Import › Undo Import** puts every one of those values back, your shortcuts, fonts and colours included.

## Fonts and colours from each app

| App | Fonts | Terminal colours |
|---|---|---|
| VS Code, Cursor, Devin Desktop | `editor.fontFamily`, and `terminal.integrated.fontFamily` (the terminal uses the editor’s while it is unset, as in VS Code) | The `terminal.*` colours in `workbench.colorCustomizations`, the block for your colour theme winning |
| JetBrains IDEs | The editor font (or your colour scheme’s own) and the console font | Your colour scheme’s console colours, when the scheme is one you saved or edited |
| Zed | `buffer_font_family`, and `terminal.font_family` | — |
| iTerm2 | The default profile’s font | The default profile’s colours, its Dark Mode ones when it keeps both |
| Ghostty | `font-family` | Your `theme` by name, then your own `palette`, `background`, `foreground`, `cursor-color` and `selection-background` |
| Warp | `font_name` | A custom theme in `~/.warp/themes` or a folder inside it; when Warp follows the system’s light and dark, the dark one |
| Terminal | The default profile’s font | The default profile’s colours |

A built-in colour scheme or theme lives inside its app, so it can’t be read; the preview says so. Change either one later in **Settings › Editor › Font**, **Settings › Terminal › Font** and **Settings › Terminal › Colours**, where **Next Term default** goes back to Next Term’s own and imported colours stay in the menu to choose again.

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
- **Only the settings it can use.** Files that can hold credentials, such as license keys, saved logins and terminal environment variables, are never opened, and anything that looks like a secret never enters the preview. In Warp’s settings, the API keys, agent profiles and redaction list are skipped over unread.
- **Nothing runs.** Shell paths, terminal profiles, start-up commands, tasks and launch configurations are listed, never imported. What a Ghostty keybind types into the terminal is never shown, and Terminal’s saved fonts and colours are read as plain data, without decoding them into objects.

## Coming next

<span class="nt-soon">Coming next</span> Zed’s own key changes.
