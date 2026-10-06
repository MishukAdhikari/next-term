---
title: The nxtrm command
description: "Open folders as projects and files at a line from any terminal with nxtrm, Next Term’s command-line tool, as subl and code do for other editors."
head:
  - tag: title
    content: nxtrm, the command-line tool for Next Term
---

`nxtrm` is to Next Term what `subl` is to Sublime Text and `code` is to VS Code: a command that opens folders and files in the app from a terminal.

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

## What it opens where

- **A folder** opens as a project: in its own window if that project is already open, in an unused window if there is one, or in a new window.
- **A file** opens in the window whose project contains it, or the front window. With `-n`, or when no window is open, it opens in a new window on the file’s project (its git root, or its folder).
- **`path:line` and `path:line:column`**, the form compilers, linters and agents print, open the file at that spot. A folder has no lines, so `nxtrm src:12` is an error.
- **A new file** in an existing folder is created empty and opened, so you can write it.

If Next Term is not running, `nxtrm` starts it with your request instead of reopening your last session. If it is running, the request goes to it and the app comes to the front.

## Installing it

**In Next Term tabs, `nxtrm` works from the first launch**: it is on the `PATH` of every tab.

**For other terminals**, Next Term links `/usr/local/bin/nxtrm` to the copy inside the app at launch when that needs no password. Otherwise use **Next Term › Install Command Line Tool (nxtrm)…**, which asks for an administrator password once, as other editors do for their commands.

- Next Term only ever replaces a link it made itself; it never touches someone else’s `nxtrm`.
- It links only a copy in a permanent place such as Applications. A copy running from the disk image would leave the link pointing at nothing once the image is ejected, so Next Term asks you to move it first.
- If you move the app, the next launch points the link at the new place, when it can do so without a password.
