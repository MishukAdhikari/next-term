---
title: Tab completion
description: "Tab opens a list at the cursor: zsh’s own completions, or folders and files, on your Mac and your servers. Type to narrow it; Return picks. Nothing runs."
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
- in bash and fish tabs on your Mac (remote tabs list the server’s folders and files: see [On your servers](#on-your-servers));
- when an agent sends keys to a tab over [MCP](/docs/orchestration/): its <kbd>⇥</kbd> is always the shell’s own.

A tab’s tooltip says who answers its <kbd>⇥</kbd>: Next Term’s list with zsh’s completions, Next Term’s list of folders and files (a server’s, over ssh, in a remote tab), a plugin you kept, or the shell’s own.

## On your servers

In a [remote tab](/docs/remote/), <kbd>⇥</kbd> lists the server’s folders and files, read over the tab’s own ssh connection by a short script that writes nothing on the server. For zsh’s own completions there, [allow the hook](#the-hook-for-zsh-on-a-server). Without it, Next Term lists what it lists on your Mac:

- after `cd`, `pushd`, `mkdir`, `rmdir` and `chdir`, folders;
- after `ls`, `cat`, `less`, `vim` and the other commands that take files, files and folders;
- for any word that looks like a path (it has a `/`, or starts with `~/` or `.`), files and folders.

Next Term reads the word off the screen, so it answers only for a plain word: one with a quote, a backslash, `$`, a glob or a brace, or a line with a quote or a backslash anywhere before the word, gets the shell’s own <kbd>⇥</kbd>. The name you pick goes on the line as you would type it, quoted for the server’s shell: bash, zsh, sh or BusyBox’s ash. In fish and tcsh only names that need no quoting are listed.

It answers only when it can be sure what is on the line, and otherwise <kbd>⇥</kbd> is the shell’s own, at once:

- after <kbd>↩︎</kbd>, once the server has twice said its shell is back at the prompt. Next Term asks every two seconds, so that takes up to four;
- once what you typed has come back on the screen;
- when the listing comes within 0.8 seconds. Keys you type while it lists go to the shell after its own <kbd>⇥</kbd>, in order;
- on a connection that carries fewer than 7 tabs. sshd allows about 10 sessions on one connection, and every tab and every check is one, so a crowded connection, or one that refused a session in the last 30 seconds, is left alone.

Outside tmux a listing is kept for ten seconds, and on a Linux server, whose status checks report the shell’s folder, Next Term lists the folder of the tab in front as soon as it changes, so the first <kbd>⇥</kbd> there answers at once. In tmux each <kbd>⇥</kbd> lists afresh, after making sure the pane isn’t in tmux’s copy mode. herdr tabs, and tabs where a program runs, keep the shell’s own <kbd>⇥</kbd>.

### The hook for zsh on a server

For the server’s own completions (git branches, your own completions, zsh’s descriptions), allow a small hook there. In **File › New Remote Tab…**, choose the server: its **Tab completion** line offers **Allow…**. Next Term asks first, with no default button, then, over a tab’s open connection:

- writes a few small files to `~/.cache/next-term/completion/` on the server: the same hook as on your Mac, and a launch command that starts your login shell through it. Your own files stay as they are;
- only where the login shell is zsh. A hook for bash isn’t here yet, so a bash server keeps the folders and files above;
- for new tabs, while Tab completion is on, as on your Mac. A session kept in tmux gets it when its shell restarts.

With the hook, a server tab works as a zsh tab on your Mac does: zsh’s own list, and zsh quotes the name you pick. The hook sends only Tab completion’s marks, never the commands you run, under a secret made for that server, which reaches it on the connection’s input and never on a command line. It runs nothing by itself. Inside a tmux of your own on the server it stays silent.

**Remove**, on the same line, deletes the folder and takes the hook’s key off Next Term’s own tmux on the server; the next tab starts as before. If the folder is deleted on the server, Next Term says the hook was removed there, starts new tabs without it, and never puts it back by itself: **Turn On Again** asks again. **Settings › Terminal** names the servers where the hook is on.

## Plugins that already own Tab

Some zsh plugins answer <kbd>⇥</kbd> themselves: fzf-tab opens fzf, and zsh-autocomplete lists as you type. Where one of them, or any other widget of your own, is bound to <kbd>⇥</kbd>, the first <kbd>⇥</kbd> asks whether to use Next Term’s list or keep the plugin:

- **Use Next Term’s List**: Next Term’s list answers <kbd>⇥</kbd>, with zsh’s completions. With zsh-autocomplete, its list as you type turns off too, in Next Term’s tabs only and for as long as each shell runs; your files stay as they are, and other terminals keep it.
- **Keep fzf-tab** (or whichever it is): <kbd>⇥</kbd> stays the plugin’s.
- **Not Now**, or <kbd>⎋</kbd>: the plugin keeps <kbd>⇥</kbd> until Next Term starts again, and Next Term asks again then. The second time, the plugin keeps it for good.

No button answers <kbd>↩︎</kbd>, so a habitual <kbd>↩︎</kbd> chooses nothing. Next Term remembers the choice on this Mac. **Settings › Terminal** lists each one with **Ask Again**.

zsh’s own <kbd>⇥</kbd>, and the widgets oh-my-zsh and fzf put on it (fzf’s `**` keeps working), are not plugins here: there is nothing to ask.

## Turn it off

**Settings › Terminal › Tab completion**:

| Choice | What <kbd>⇥</kbd> does |
|---|---|
| **Auto** (the default) | Opens Next Term’s list at a zsh prompt. Where a plugin owns <kbd>⇥</kbd>, asks once. |
| **Next Term** | Opens Next Term’s list at every zsh prompt, plugins or not, with no question. |
| **Off** | The shell’s own, as in any terminal. zsh-autocomplete lists as you type again. |

**Off** works at once in every tab. Turning it on again reaches the tabs you open from then on: a tab’s zsh loads Next Term’s hook as it starts.

## Suggest a command

Next Term has no AI of its own. If you want one, it can ask yours: **Settings › Terminal › Suggestions** is **Off** until you choose who answers:

- **Claude Code**, when it is installed. Next Term runs it with no tools and no MCP, in an empty folder made for the request, without Next Term’s variables, and stops it after 60 seconds;
- **Apple’s On-Device Model**, on macOS 26 and later with Apple Intelligence on. Nothing leaves your Mac. Settings says when the model isn’t ready, or the Mac can’t run it.

Codex, Copilot CLI and opencode aren’t offered: each must run with no tools and no MCP, and for them that couldn’t be made sure of.

Then **File › Suggest a Command…** (<kbd>⌃⌘K</kbd>), at a shell prompt (not while a program or an agent runs), opens a box near the cursor. Say what the command should do (“find files over 100 MB here”) and press <kbd>↩︎</kbd>. Before anything is sent, the box says what goes with your words: the folder, the shell’s name and the last command, with secrets masked. **Include Recent Output…** shows the end of the tab’s output as it would be sent, secrets masked, and adds it to that one request only if you say so.

The command comes back and goes on the line. Nothing runs until you press <kbd>↩︎</kbd> at the prompt. It waits in the box instead when:

- you typed in the tab, or a command started, while it was asked: **Replace Line** puts it there (**Put on Line** in a tab where it can only be typed in);
- it does something worth a second look (`sudo`, `rm -r`, `dd`, `mkfs`, a script piped from `curl`, `--force`), with a note saying what: **Put on Line** puts it there;
- it holds invisible or direction-changing characters, shown spelled out;
- it has more than one line, outside a zsh tab on your Mac with Tab completion’s hook: **Copy** takes it.

In a zsh tab opened with Tab completion on, the command replaces the line as one edit, several lines too; on a server with the hook for zsh, one line does. Elsewhere one line is typed in at the cursor, as a paste. <kbd>⎋</kbd> closes the box and stops the request.

## What it never does

- **It never runs anything.** A name goes on the line; you press <kbd>↩︎</kbd>.
- **It never edits your files.** Your `.zshrc` loads exactly as before; Next Term’s hook loads after it, for that shell only, and leaves your <kbd>⇥</kbd> binding as it is. Turning zsh-autocomplete’s list off changes that shell, not a file. On a server, nothing is written but the hook you allow, in its own folder.
- **A file name can’t turn into a command.** Names are quoted from an allowlist, and names with control or invisible characters go in as `$'…'`, so a folder called `x;touch PWNED;` goes in as one word.
- **Nothing is kept.** The line you type, the names listed, and what Suggest a Command sends and gets back are never logged or saved.
