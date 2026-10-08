---
title: Keyboard shortcuts
description: "Every default keyboard shortcut in Next Term, menu by menu, the keys outside the menus, and how to change any of them in Settings › Keyboard Shortcuts."
head:
  - tag: title
    content: Keyboard shortcuts for Next Term on macOS
---

These are the defaults. Every menu command’s shortcut can be changed, removed or given one it does not have, and so can the keys of the project sidebar, the Git lists, a proposed edit and the branch popup: see [Change any shortcut](#change-any-shortcut). Shortcuts are written the way macOS menus show them: <kbd>⌃</kbd> Control, <kbd>⌥</kbd> Option, <kbd>⇧</kbd> Shift, <kbd>⌘</kbd> Command.

## The ones you will use most

| Action | Keys |
|---|---|
| New tab (in the project, or the current tab’s folder) | <kbd>⌘T</kbd> |
| Reopen the tab you closed last | <kbd>⇧⌘T</kbd> |
| Open a project | <kbd>⌘O</kbd> |
| Go to File: a file in the project by name | <kbd>⌘P</kbd> |
| Split the tab right, or down | <kbd>⌘D</kbd> (outside the editor), <kbd>⇧⌘D</kbd> |
| Duplicate the line in the editor | <kbd>⌘D</kbd> |
| Move between panes | <kbd>⌥⌘←</kbd> <kbd>⌥⌘→</kbd> <kbd>⌥⌘↑</kbd> <kbd>⌥⌘↓</kbd> |
| Send the selection to the agent in your tab | <kbd>⌥⌘K</kbd> |
| Show a file’s changes, with the other changed files beside it | <kbd>⌥⌘G</kbd> |
| Git Diff: every change on the branch | <kbd>⌃⌘G</kbd> |
| Accept an agent’s proposed edit | <kbd>⌘↩︎</kbd> |
| Find in Files, Replace in Files | <kbd>⇧⌘F</kbd>, <kbd>⇧⌘R</kbd> |
| Between the editor and the terminal | <kbd>⌃&#96;</kbd> |
| Project sidebar | <kbd>⌘B</kbd> |
| Settings, including every menu shortcut | <kbd>⌘,</kbd> |

## Next Term menu

| Command | Keys |
|---|---|
| Settings… | <kbd>⌘,</kbd> |
| Check for Updates… | — |
| Check for Updates Automatically | — |
| Install Command Line Tool (nxtrm)… | — |
| Import Settings and Shortcuts… (from another editor or terminal) | — |
| Hide Next Term | <kbd>⌘H</kbd> |
| Hide Others | <kbd>⌥⌘H</kbd> |
| Quit Next Term | <kbd>⌘Q</kbd> |

## File menu

| Command | Keys |
|---|---|
| New Tab | <kbd>⌘T</kbd> |
| New Window | <kbd>⌘N</kbd> |
| New Remote Tab… (a tab on one of your servers) | <kbd>⌥⌘T</kbd> |
| Duplicate Tab (a new tab in the folder of the one in front) | — |
| Reopen Closed Tab (in its folder, with its name, in a fresh shell) | <kbd>⇧⌘T</kbd> |
| Open Project… | <kbd>⌘O</kbd> |
| Go to File… | <kbd>⌘P</kbd> |
| Resume Agent Session… | <kbd>⌥⌘O</kbd> |
| Open Served URL (the address a dev server in the tab printed) | — |
| Open Recent, Open Projects In | — |
| Close Project | — |
| Save | <kbd>⌘S</kbd> |
| Save All | <kbd>⌥⌘S</kbd> |
| Reveal in Finder, Copy Path, Copy Relative Path (the file in front in the editor) | — |
| Split Right (while the editor has the keyboard, <kbd>⌘D</kbd> is Duplicate Line) | <kbd>⌘D</kbd> |
| Split Down | <kbd>⇧⌘D</kbd> |
| Rename Tab… | <kbd>⌥⌘R</kbd> |
| Use Option as Meta Key (off by default; for Emacs-style keys) | — |
| Close Tab (Close Pane in a split tab; the file being edited when the editor has the keyboard) | <kbd>⌘W</kbd> |
| Close Other Tabs, Close Tabs to the Right (the editor’s tabs when it has the keyboard) | — |
| Close Window | <kbd>⇧⌘W</kbd> |

## Edit menu

| Command | Keys |
|---|---|
| Undo, Redo | <kbd>⌘Z</kbd>, <kbd>⇧⌘Z</kbd> |
| Cut, Copy, Paste (in the editor with nothing selected, Cut and Copy take the whole line) | <kbd>⌘X</kbd>, <kbd>⌘C</kbd>, <kbd>⌘V</kbd> |
| Select All | <kbd>⌘A</kbd> |
| Find › Find… | <kbd>⌘F</kbd> |
| Find › Replace… (in the file you are editing) | <kbd>⌥⌘F</kbd> |
| Find › Find Next | <kbd>⌘G</kbd> |
| Find › Find Previous | <kbd>⇧⌘G</kbd> |
| Find › Use Selection for Find | <kbd>⌘E</kbd> |
| Find › Find in Files… | <kbd>⇧⌘F</kbd> |
| Find › Replace in Files… | <kbd>⇧⌘R</kbd> |
| Send to Agent (the editor’s selection, the sidebar’s files, or the text selected in the terminal) | <kbd>⌥⌘K</kbd> |
| Go to Line… | <kbd>⌘L</kbd> |
| Comment Line | <kbd>⌘/</kbd> |
| Indent | <kbd>⌘]</kbd> |
| Outdent | <kbd>⌘[</kbd> |
| Line › Duplicate Line (while the editor has the keyboard) | <kbd>⌘D</kbd> |
| Line › Delete Line | <kbd>⇧⌘K</kbd> |
| Line › Move Line Up, Move Line Down | <kbd>⌃⌘↑</kbd>, <kbd>⌃⌘↓</kbd> |
| Line › Copy Path with Line (`src/app.ts:42`) | — |
| Clear Buffer (the terminal’s screen and scrollback) | <kbd>⌘K</kbd> |

## View menu

| Command | Keys |
|---|---|
| Hide or Show Project Sidebar | <kbd>⌘B</kbd> |
| Focus Editor or Focus Terminal | <kbd>⌃&#96;</kbd> |
| Collapse Terminal or Expand Terminal (to its tab bar, or beside the editor to a rail with each tab’s mark) | <kbd>⌘J</kbd> |
| Show File in Project Sidebar (the file in front in the editor) | — |
| Terminal Position › Bottom, Right, Left, Top | — |
| Show Changes (the file’s, in the Git Diff tab) | <kbd>⌥⌘G</kbd> |
| Unified Diffs (every diff in one column instead of side by side; off by default) | — |
| Annotate with Git Blame (who last changed each line, beside the numbers) | — |
| Current Line Blame (a note after the caret line; off by default) | — |
| Soft Wrap | — |
| Hide .env Values (the file in front; checked while its values are hidden) | — |
| Line Height › 1.0 to 2.0 | — |
| Project Sidebar on the Right | — |
| Bigger | <kbd>⌘+</kbd> (also <kbd>⌘=</kbd>) |
| Smaller | <kbd>⌘-</kbd> |
| Actual Size | <kbd>⌘0</kbd> |
| Enter Full Screen | <kbd>⌃⌘F</kbd> |

## Git menu

| Command | Keys |
|---|---|
| Branches… (the branch popup) | <kbd>⌥⌘B</kbd> |
| Fetch, Update Project, Commit…, Push…, New Branch… | — |
| Git Log (the commit history) | <kbd>⌥⌘L</kbd> |
| Git Diff (the changed files and their diffs) | <kbd>⌃⌘G</kbd> |
| Git Commands (what Next Term ran) | — |

In the branch popup: <kbd>↩</kbd> checks out, <kbd>⌥↩</kbd> checks out and updates a branch that is behind its upstream, <kbd>→</kbd> opens the branch’s menu, <kbd>⌘R</kbd> fetches, <kbd>⌘↩</kbd> makes a new branch from the selected branch or tag, <kbd>⌘⌫</kbd> deletes the branch (one on a remote after asking), <kbd>⌘C</kbd> copies its name (a worktree’s path). The last four can be changed: see [Keys outside the menus](#keys-outside-the-menus).

In the Git Diff tab’s file list: <kbd>↑</kbd> and <kbd>↓</kbd> move from file to file, <kbd>↩</kbd> goes to the diff. <kbd>↩</kbd> can be changed.

In the Git Log: <kbd>↑</kbd> and <kbd>↓</kbd> move through the commits, <kbd>⌘F</kbd> goes to the search field, <kbd>↩</kbd> moves to the selected commit’s changed files (and <kbd>↩</kbd> there opens a file’s diff), <kbd>⌘C</kbd> copies the commit’s hash. <kbd>↩</kbd> can be changed.

## Window menu

| Command | Keys |
|---|---|
| Minimize | <kbd>⌘M</kbd> |
| Show Next Tab | <kbd>⇧⌘]</kbd> |
| Show Previous Tab | <kbd>⇧⌘[</kbd> |
| Select Pane on the Left, on the Right | <kbd>⌥⌘←</kbd>, <kbd>⌥⌘→</kbd> |
| Select Pane Above, Below | <kbd>⌥⌘↑</kbd>, <kbd>⌥⌘↓</kbd> |
| Select Next Pane, Previous Pane | <kbd>⌥⌘]</kbd>, <kbd>⌥⌘[</kbd> |
| Maximize Pane (again to restore) | <kbd>⇧⌘↩︎</kbd> |
| Make Panes Equal | — |
| Select Tab 1 to 8 | <kbd>⌘1</kbd> to <kbd>⌘8</kbd> |
| Select Last Tab | <kbd>⌘9</kbd> |
| Welcome to Next Term | — |

## Keys outside the menus

Each of these belongs to one part of the window and works only there. **Settings › Keyboard Shortcuts** lists them after the menu commands, with the part each belongs to, and changes them as it changes a menu command’s; a tooltip that names one, such as **Accept**’s on a proposed edit, follows it. In the project sidebar and the Git lists, where nothing is typed, a key needs no <kbd>⌘</kbd> or <kbd>⌃</kbd>: <kbd>↩︎</kbd> will do on its own, and <kbd>↩︎</kbd>, <kbd>⌫</kbd> or <kbd>⌦</kbd> with <kbd>⇧</kbd> or <kbd>⌥</kbd>.

| Part of the window | Command | Default |
|---|---|---|
| Project Sidebar | Open | <kbd>⌘↓</kbd> |
| Project Sidebar | Rename | <kbd>↩︎</kbd> (Enter too) |
| Project Sidebar | Move to Trash | <kbd>⌘⌫</kbd> |
| Git Log, Git Diff and Compare lists | Open Commit or File: from a commit to its changed files, a file’s diff, or from the Git Diff tab’s file list to the diff | <kbd>↩︎</kbd> |
| Proposed Edit | Accept an agent’s proposed edit | <kbd>⌘↩︎</kbd> |
| Branch Popup | Fetch | <kbd>⌘R</kbd> |
| Branch Popup | New Branch from Selected (a branch or a tag) | <kbd>⌘↩︎</kbd> |
| Branch Popup | Delete Branch (one on a remote after asking) | <kbd>⌘⌫</kbd> |
| Branch Popup | Copy Name (a worktree’s path) | <kbd>⌘C</kbd> |

These are fixed:

| Where | Action | Keys |
|---|---|---|
| Tabs | Next tab, previous tab | <kbd>⌃⇥</kbd>, <kbd>⌃⇧⇥</kbd> |
| Tabs | Rename a terminal tab | Double-click the tab |
| Tabs | Keep a preview tab | Double-click the tab |
| Tabs | Close | Middle-click the tab |
| Tabs | Rename, split, duplicate, close it or the others | Right-click the tab |
| Terminal | Copy, Paste, Clear, Find, Split, Send Selection to Agent; open or reveal a link or path | Right-click |
| Terminal | Open a path such as `src/app.ts:42:7`, or a link | <kbd>⌘</kbd>-click |
| Terminal | Suspend the running program | <kbd>⌃Z</kbd> |
| Editor | Indent or outdent the selected lines | <kbd>⇥</kbd>, <kbd>⇧⇥</kbd> |
| Sidebar | Open | Double-click (one click, with **Open files with a single click** on) |
| Sidebar | Copy instead of move while dragging | Hold <kbd>⌥</kbd> |
| Branch popup | Check out, check out and update, the branch’s menu | <kbd>↩︎</kbd>, <kbd>⌥↩︎</kbd>, <kbd>→</kbd> |
| Go to File | Open at a line | Type `name:42` |

## Change any shortcut

Open **Next Term › Settings…** (<kbd>⌘,</kbd>) and choose **Keyboard Shortcuts**. Every menu command is listed with where it lives in the menus, and after them the [keys outside the menus](#keys-outside-the-menus), each with the part of the window it belongs to.

1. Search by command name, menu, part of the window or shortcut.
2. Click a command’s shortcut and press the new keys. <kbd>⌫</kbd> removes the shortcut; <kbd>⎋</kbd> cancels.
3. If the keys already belong to another command, Next Term says which and offers **Use It Here**; the other command is then left without a shortcut.

A key can belong to one command in each part of the window. **Edit › Line**’s commands work only while the editor has the keyboard, so one of them can share a key with a command for the terminal (Split Right, Split Down, Clear Buffer, Rename Tab, New Remote Tab and the pane commands): the editor’s command has it while the editor has the keyboard, the terminal’s everywhere else. That is how <kbd>⌘D</kbd> duplicates a line in the editor and splits the terminal elsewhere. In the same way the sidebar’s Move to Trash and the editor’s Delete Line can both be <kbd>⌘⌫</kbd>, and Rename in the sidebar and Open in the Git Log are both <kbd>↩︎</kbd>. The branch popup has the keyboard while it is open, so its keys can be any other command’s too: its <kbd>⌘C</kbd> copies a branch’s name, and Edit › Copy is <kbd>⌘C</kbd> everywhere else. Settings lists all of them on the key and does not call that a clash; point at a shortcut to see which part has it. **Accept** on a proposed edit is the exception: it works wherever the keyboard is in the window while the proposed edit is shown, and the project sidebar can be beside it, so it can’t share a key with the sidebar’s commands. While the menus are open over the editor, the shared key shows on the editor’s command.

A shortcut needs <kbd>⌘</kbd> or <kbd>⌃</kbd> (or a function key), so it can never swallow ordinary typing. A changed command shows a **Default** button that puts its shortcut back, and **Restore All Defaults** resets everything. Changes apply at once, in every menu, including the ⋯ menus and the right-click menus, and in the tooltips that name a key, such as the **+** button’s “New tab (⌘T)”. A command left without a shortcut shows none.

The window’s icon buttons show their key in dim text just before the icon, as each tab shows <kbd>⌘1</kbd>: <kbd>⌘B</kbd> by the sidebar icon, <kbd>⌘T</kbd> by the **+**, <kbd>⌘J</kbd> by the terminal’s fold arrow (on the folded rail, under it), <kbd>⌘R</kbd> by the branch popup’s fetch button. These follow your keys too, and the scope button by the editor’s tabs shows one once you give **View › Show File in Project Sidebar** a key. When room is short they go first: in the sidebar’s header the hide button’s key shows only while the branch name, its icon, the line counts and the **Pull** or **Push** button all fit in full, and in a tab bar a key goes before the tabs narrow. A key that gave way still shows the moment the pointer is on its button, beside the icon (on the folded rail, under the arrow), over whatever is there, and goes as soon as the pointer leaves. Nothing moves for it, a key too long for its place doesn’t show, and a click there still reaches what is under it.
