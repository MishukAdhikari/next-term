---
title: Switching from VS Code or JetBrains
description: "Bring shortcuts, settings, fonts, colours and recent projects from VS Code, Cursor, JetBrains, Zed, iTerm2, Ghostty, Terminal and more. You see it first."
sidebar:
  label: Switching to Next Term
---

Next Term can use the shortcuts and settings you already have. **Nothing changes unless you choose it:** you see every change first, and one click undoes the whole import.

## Bring your settings over

On first launch, if Next Term finds VS Code, Cursor, Devin Desktop, a JetBrains IDE (PhpStorm, PyCharm, IntelliJ IDEA, WebStorm, Android Studio and the rest), Zed, iTerm2, Ghostty, Warp, or a Terminal profile you chose or changed, it asks **Coming from another app?** The default keeps Next Term’s shortcuts. Any time later: **Next Term › Import Settings and Shortcuts…**, or **Settings › Import**.

Choose an app and the preview lists what it would bring, each item a checkbox with where it came from:

- **Shortcuts:** the matching set of keys (below).
- **Your shortcuts:** the keys you changed yourself, from VS Code’s `keybindings.json` (and Cursor’s, Devin Desktop’s), your JetBrains keymap, Zed’s `keymap.json`, or Ghostty’s `keybind` lines that have a Next Term command. A key another command already has, or a Control key without <kbd>⌘</kbd>, comes in unticked with the reason. A key a terminal command has, given to one of the editor’s line commands (a JetBrains keymap’s <kbd>⇧⌘D</kbd> for Duplicate Line, say), comes in ticked and says which has it where: Duplicate Line while the editor has the keyboard, Split Down everywhere else.
- **Settings:** font size, line height, soft wrap, Option as Meta, where the terminal sits and the sidebar’s side, clean-up on save, the files the sidebar hides, and the terminal’s cursor, scrollback and start folder, from the values you set in that app (below).
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

## Editor and terminal settings from each app

| App | Clean-up on save and hidden files | The terminal’s cursor, scrollback and start folder |
|---|---|---|
| VS Code, Cursor, Devin Desktop | `files.trimTrailingWhitespace`, `files.insertFinalNewline`, the patterns `files.exclude` turns on | `terminal.integrated.cursorStyle` (its `line` is a bar), `cursorBlinking`, `scrollback`, `cwd` when it is a full path |
| JetBrains IDEs | Trailing spaces removed on save (all lines; modified lines only comes in unticked, since Next Term trims every line), and **Ensure every saved file ends with a line break** | — |
| Zed | `remove_trailing_whitespace_on_save`, `ensure_final_newline_on_save`, `file_scan_exclusions` | `terminal.cursor_shape`, `blinking`, `max_scroll_history_lines`, `working_directory` |
| iTerm2 | — | The default profile’s cursor and blinking, its scrollback lines when they aren’t iTerm2’s 1,000, and its working directory for new tabs |
| Ghostty | — | `cursor-style`, `cursor-style-blink`, `working-directory` |
| Terminal | — | The default profile’s cursor and blinking, and its row limit when it has one |

From Zed come its `buffer_font_size`, `buffer_line_height`, `soft_wrap`, the terminal’s `option_as_meta`, `font_size` and `dock`, and the project panel’s `dock` too.

- **Hidden files** are added to the patterns you have in **Settings › Editor › Hide**, written the way the sidebar reads them: VS Code’s `**/node_modules` becomes `node_modules`, and `build` (only at the top of the project there) becomes `/build`. The ones the sidebar hides anyway, such as `**/.git`, need nothing.
- **A start folder** that is the folder of the tab in front (Ghostty’s `inherit`, iTerm2’s **Reuse previous session’s directory**) comes in ticked. Your home folder or a folder of your own comes in unticked: ticked, it applies in project windows too, where new tabs otherwise open in the project’s folder. A folder that isn’t on this Mac is named by its setting only.
- **Scrollback** is kept between 1,000 and 100,000 lines; iTerm2’s **Unlimited scrollback** comes in as 100,000. Ghostty’s `scrollback-limit` counts bytes rather than lines, so it is listed, not converted.
- **The cursor style is the terminal’s.** The editor keeps the macOS text caret, so VS Code’s `editor.cursorStyle` and Zed’s `cursor_shape` are listed as not brought over. A hollow block (Ghostty, Zed) comes in filled.

## Keep the keys you know

**Settings › Import › Shortcuts from** chooses the keys, and an import can set it for you. Only the commands whose keys differ change; everything else keeps Next Term’s keys, and your own changes in **Keyboard Shortcuts** always stay on top.

| Command | Next Term | VS Code | JetBrains (macOS) |
|---|---|---|---|
| New Window | <kbd>⌘N</kbd> | <kbd>⇧⌘N</kbd> | <kbd>⌘N</kbd> |
| Go to File | <kbd>⌘P</kbd> | <kbd>⌘P</kbd> | <kbd>⇧⌘O</kbd>, and <kbd>⌘P</kbd> still works |
| Save | <kbd>⌘S</kbd> | <kbd>⌘S</kbd> | <kbd>⌥⌘S</kbd> |
| Save All | <kbd>⌥⌘S</kbd> | <kbd>⌥⌘S</kbd> | <kbd>⌘S</kbd> |
| Split Right | <kbd>⌘D</kbd> | <kbd>⌘&#92;</kbd> | <kbd>⌘&#92;</kbd> |
| Duplicate Line (in the editor) | <kbd>⌘D</kbd> | no key | <kbd>⌘D</kbd> |
| Delete Line (in the editor) | <kbd>⇧⌘K</kbd> | <kbd>⇧⌘K</kbd> | <kbd>⌘⌫</kbd> |
| Replace (in the open file) | <kbd>⌥⌘F</kbd> | <kbd>⌥⌘F</kbd> | <kbd>⌘R</kbd> |
| Replace in Files | <kbd>⇧⌘R</kbd> | <kbd>⇧⌘H</kbd> | <kbd>⇧⌘R</kbd> |
| Indent / Outdent | <kbd>⌘]</kbd> / <kbd>⌘[</kbd> | <kbd>⌘]</kbd> / <kbd>⌘[</kbd> | no key (<kbd>⇥</kbd> and <kbd>⇧⇥</kbd> indent) |

With either set, <kbd>⌘K</kbd> clears only while a terminal has the keyboard, because both editors use <kbd>⌘K</kbd> for other things in their editors. With VS Code’s, Duplicate Line has no key: in VS Code <kbd>⌘D</kbd> selects the next match, which Next Term doesn’t do, and VS Code’s <kbd>⇧⌥↓</kbd> for copying a line down can’t be a shortcut here (a shortcut needs <kbd>⌘</kbd> or <kbd>⌃</kbd>). With JetBrains’, <kbd>⌘⌫</kbd> deletes the line only in the editor; in the project sidebar it still moves a file to the Trash.

Imports bring your own keys for the line commands too: JetBrains’ Duplicate Line or Selection, Delete Line, Move Line Up and Down, VS Code’s Copy Line Down, Duplicate Selection, Delete Line, Move Line Up and Down, and Zed’s Duplicate Line Down, Duplicate Selection, Delete Line, Move Line Up and Down.

Two rules keep the terminal working the way your shell and agents expect: a set never takes a Control key without <kbd>⌘</kbd> (Claude Code and the shell use <kbd>⌃R</kbd>, <kbd>⌃G</kbd> and the rest), and never a key macOS keeps for itself.

### Zed’s own keys

Zed keeps the keys you changed in `keymap.json`, beside its `settings.json`. The ones bound to an action Next Term has come over, read as Zed reads them: a binding further down for the same place (the window, the editor or the terminal) replaces the one above it on that key, and of one action’s keys, the last one left comes over. An editor-only key and a window or terminal key can share: <kbd>⇧⌘L</kbd> for Duplicate Line in the `Editor` context and for Split Right everywhere else both come in, as they work in Zed. Two other actions on one key can’t: the editor’s or the terminal’s binding keeps it, since Zed obeys that one there, and the other comes in unticked.

- **Where a key works.** A key for the whole window (no `context`, or `Workspace` or `Pane`), for the editor (`Editor`) or for the terminal (`Terminal`) comes over. One for a narrower place, such as the project panel or a Vim mode, is listed with its context.
- **What is listed instead.** A key set to `null` turns off one of Zed’s, which changes nothing here, or one of yours further up, which then doesn’t come over. Two-step keys (`cmd-k cmd-s`), the `fn` key, and actions given arguments are listed too; `["pane::ActivateItem", 0]` and the rest, for tabs 1 to 8, come over.
- **Symbols typed with Shift.** `cmd-}` is <kbd>⇧⌘]</kbd> on a U.S. layout. On another layout such a key is listed, since another key may type it.

## What it reads, and what it never touches

- **Only this Mac, only reading.** Next Term never writes to the other app, never copies its databases, and sends nothing anywhere.
- **Only the settings it can use.** Files that can hold credentials, such as license keys, saved logins and terminal environment variables, are never opened, and anything that looks like a secret never enters the preview. In Warp’s settings, the API keys, agent profiles and redaction list are skipped over unread.
- **Nothing runs.** Shell paths, terminal profiles, start-up commands, tasks and launch configurations are listed, never imported. What a Ghostty keybind or a Zed key types into the terminal is never shown, and Terminal’s saved fonts and colours are read as plain data, without decoding them into objects.
