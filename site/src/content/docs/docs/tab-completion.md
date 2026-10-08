---
title: Tab completion
description: "Tab at a zsh prompt opens a list at the cursor: zsh’s own completions, or folders and files. Type to narrow it; ↑ ↓ and Return pick. Nothing runs."
---

Press Tab (<kbd>⇥</kbd>) at a zsh prompt and Next Term lists what can complete the word under the cursor, in a list at the cursor. Type to narrow it, pick with the arrow keys and <kbd>↩︎</kbd>, and the name goes on the line, quoted so the shell reads it back exactly. Nothing runs until you press <kbd>↩︎</kbd> again at the prompt.

Your shell keeps its own line editor: your zsh config, theme and key bindings work as before, and every agent CLI keeps its own input. Next Term only draws the list.

## What it lists

- **zsh’s own completions, when zsh has them.** If your zsh loads its completion system (`compinit`, which oh-my-zsh and prezto run for you), the list is exactly what zsh would offer: git branches, `CDPATH`, your own completions, with zsh’s descriptions beside them. zsh quotes the one you pick.
- **Folders and files, when it doesn’t.** The zsh that comes with macOS doesn’t load its completion system, so Next Term lists the folder itself:
  - after `cd`, `pushd`, `mkdir`, `rmdir` and `chdir`, folders only;
  - after `ls`, `cat`, `less`, `open`, `rm`, `cp`, `mv`, `vim`, `code` and other commands that take files, files and folders;
  - for any word that looks like a path (it has a `/`, or starts with `~` or `.`), after `>` and `<`, and in `--option=` values, files and folders.

  Everything else (a command name, an option, `git checkout `) gets zsh’s own <kbd>⇥</kbd>.
- **Hidden files and folders** only when the name you typed starts with a dot.

Names that start with what you typed come first, in any case and either Unicode form, shortest first; then names that have your letters in order anywhere. One match goes straight onto the line with no list. No match gets zsh’s own <kbd>⇥</kbd>.

A long list shows its best 2,000 and says so (“2,000 of 10,000. Type to narrow.”). A folder that can’t be read within a tenth of a second (a sleeping network volume) gets zsh’s own <kbd>⇥</kbd> instead. A slow zsh completion shows **Loading…** until zsh is done.

## Keys

While the list is open, the terminal keeps the keyboard: letters and <kbd>⌫</kbd> go to the shell, and the list narrows as the word changes.

| Keys | What they do |
|---|---|
| <kbd>↓</kbd> <kbd>↑</kbd>, <kbd>⌃N</kbd> <kbd>⌃P</kbd>, <kbd>⇧⇥</kbd> | Choose a row |
| <kbd>↩︎</kbd> or <kbd>⇥</kbd>, or a click | Put the chosen name on the line |
| <kbd>⎋</kbd> | Close the list. Nothing is sent to the shell. |
| <kbd>→</kbd>, <kbd>⌃C</kbd>, <kbd>⌃J</kbd>, any <kbd>⌘</kbd> shortcut | Close the list, and the key does what it always does |

The list also closes when you click elsewhere, scroll, switch tab, pane or app, resize the window, or paste, and when output moves the cursor’s line.

## When Tab stays the shell’s own

The list opens only at a zsh prompt Next Term’s hook is ready at. <kbd>⇥</kbd> goes to the shell or program untouched:

- while a program runs: Claude Code, Codex and every other agent get <kbd>⇥</kbd> themselves;
- in full-screen programs such as `less` and `vim`;
- while an input method is composing text;
- in vi command mode, during incremental search and in zsh’s own menu selection;
- in bash and fish tabs, and in remote tabs;
- when an agent sends keys to a tab over [MCP](/docs/orchestration/): its <kbd>⇥</kbd> is always the shell’s own.

A tab’s tooltip says who answers its <kbd>⇥</kbd>: Next Term’s list with zsh’s completions, Next Term’s list of folders and files, or the shell’s own.

## Turn it off

**Settings › Terminal › Tab completion**:

| Choice | What <kbd>⇥</kbd> does |
|---|---|
| **Auto** (the default) | Opens Next Term’s list at a zsh prompt. |
| **Next Term** | Opens Next Term’s list at a zsh prompt. |
| **Off** | The shell’s own, as in any terminal. |

**Off** works at once in every tab. Turning it on again reaches the tabs you open from then on: a tab’s zsh loads Next Term’s hook as it starts.

## What it never does

- **It never runs anything.** A name goes on the line; you press <kbd>↩︎</kbd>.
- **It never edits your files.** Your `.zshrc` loads exactly as before; Next Term’s hook loads after it, for that shell only, and leaves your <kbd>⇥</kbd> binding as it is.
- **A file name can’t turn into a command.** Names are quoted from an allowlist, and names with control or invisible characters go in as `$'…'`, so a folder called `x;touch PWNED;` goes in as one word.
- **Nothing is kept.** The line you type and the names listed are never logged or saved.
