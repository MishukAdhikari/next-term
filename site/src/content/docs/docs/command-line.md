---
title: The nxtrm command
description: "Open folders as projects and files at a line from any terminal with nxtrm, Next Term’s command-line tool. nxtrm mcp is the MCP server agents start."
head:
  - tag: title
    content: nxtrm, the command-line tool for Next Term
---

`nxtrm` opens folders and files in Next Term from any terminal: a project with `nxtrm .`, a file at a line with `nxtrm src/app.ts:42`.

## Usage

```sh
nxtrm .                   # this folder as a project
nxtrm ~/Code/api          # a folder as a project
nxtrm src/app.ts:42:7     # a file, at line 42, column 7
nxtrm notes.md            # a file that does not exist yet is created empty
nxtrm -n ~/Code/api       # in a new window
```

| Option | Does |
|---|---|
| `-n`, `--new-window` | Open in a new window |
| `-h`, `--help` | Show the help |
| `-v`, `--version` | Show the version |
| `--` | Treat everything after it as a path, even if it starts with `-` |

`nxtrm mcp` is different: it is Next Term’s MCP server, which agents start themselves. See [Orchestrate agents (MCP)](/docs/orchestration/).

## What it opens where

- **A folder** opens as a project: in its own window if that project is already open, in an unused window if there is one, or in a new window.
- **A file** opens in the window whose project contains it, or the front window. With `-n`, or when no window is open, it opens in a new window on the file’s project (its git root, or its folder).
- **`path:line` and `path:line:column`**, the form compilers, linters and agents print, open the file at that spot. A folder has no lines, so `nxtrm src:12` is an error.
- **A new file** in an existing folder is created empty and opened, so you can write it.

If Next Term is not running, `nxtrm` starts it with your request instead of reopening your last session. If it is running, the request goes to it and the app comes to the front.

## Installing it

**In Next Term tabs, `nxtrm` works from the first launch**: it is on the `PATH` of every tab.

**For other terminals**, Next Term adds it at launch when it can do so without a password. It reads your `PATH` from your login shell, as your other terminals get it, and links `nxtrm` to the copy inside the app in the first of these folders on it that you can write:

- `~/.local/bin` or `~/bin`, when your shell puts them on `PATH`
- `/opt/homebrew/bin`, Homebrew’s folder on Apple silicon
- `/usr/local/bin`, when Homebrew has made it yours

Your `PATH` order decides between them. Next Term never adds a folder to `PATH` or edits your shell’s startup files, and never adds a link to any other folder on `PATH`, such as a version manager’s.

**When none of them will do**, as on a Mac without Homebrew, where `/usr/local/bin` belongs to the system, the first launch asks **Install the “nxtrm” command?**

- **Install…** links `/usr/local/bin/nxtrm` and asks for your administrator password once, as other editors do for their commands.
- **Not Now** asks again after the next update.
- **Don’t Ask Again** stops asking.

**Next Term › Install Command Line Tool (nxtrm)…** does the same at any time. It also uses a folder that needs no password when there is one.

**The one-line installer** links it the same way, right after it installs the app, and says where. If no folder qualifies, it tells you that Next Term will offer it.

- Next Term only ever replaces a link it made itself. It never touches someone else’s `nxtrm`, and when another `nxtrm` comes first on your `PATH`, it adds none of its own.
- It links only a copy in a permanent place such as Applications. A copy running from the disk image would leave the link pointing at nothing once the image is ejected, so Next Term asks you to move it first.
- If you move the app, the next launch points the link at the new place, when it can do so without a password.
- The link is the only file it adds. Delete it to remove the command from your other terminals: Next Term leaves it out from then on, and **Next Term › Install Command Line Tool (nxtrm)…** puts it back.
