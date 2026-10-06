---
title: Projects and git
description: "Projects that reopen at launch, and git at a glance: coloured files, +12 −3 line counts, branch and ahead/behind, and file operations with undo."
---

A project is a folder that a window is about. Its files stay in the sidebar, new tabs start in it, and Next Term brings it back the next time you launch. The sidebar is also where you see, at a glance, what your agents have changed.

![The project sidebar: branch main with +3 −1 at the top, the folder src marked +3 −1, the changed file app.txt in blue with +3 −1, and AGENTS.md and README.md with their file icons.](../../../assets/screenshots/sidebar-git.webp)

## Projects

- **Open a project:** **Shell › Open Project…** (<kbd>⌘O</kbd>) and choose a folder. Agents can open projects too, through [MCP](/docs/orchestration/). From another terminal, run `nxtrm .` (see [The nxtrm command](/docs/command-line/)). You can also drop a folder on Next Term’s Dock icon, or run `open -a "Next Term" ~/Code/app`.
- **New tabs open in the project** by default. You can still `cd` anywhere.
- **Reopen at launch:** Next Term reopens the project windows that were open when you quit. On the very first launch it asks for a folder.
- **Open Recent** (in the Shell menu) lists your recent projects, with **Clear Menu**. The Dock icon’s menu lists them too, with **New Window**.
- **Close Project** (in the Shell menu) closes the window, asking first if something is still running in it. When the last project closes, the **Welcome** window appears. Open it any time from **Window › Welcome to Next Term**.

### The Welcome window and agent sessions

The **Welcome** window lists your projects on the left, with a search field, each project’s branch, and which ones are open. Choose one and the right side shows every conversation **Claude Code**, **Codex** and **Command Code** kept for it, newest first, including the ones started in its subfolders: the title (in bold when you named it), the agent, when, the branch and the model, and a mark when an agent has it open right now. Filter by agent at the top.

- **Resume** runs the agent’s own resume command (`claude --resume …`, `codex resume …`) in a new tab, in the folder the session was started in.
- **Fork** continues a copy and leaves the original as it was: the safe choice while the session is open in another terminal.
- In a project window, **Shell › Resume Agent Session…** (<kbd>⌥⌘O</kbd>) shows the same list as a panel: type to filter, <kbd>↩</kbd> resumes, <kbd>⌘↩</kbd> forks.

Next Term reads only titles, dates, branches and models from each agent’s own files, never whole conversations, removes anything that looks like a secret from titles, and writes nothing. Claude Code deletes conversations after 30 days unless you change its `cleanupPeriodDays` setting.

### Where a project opens

A window nobody has used yet simply becomes the project’s window. Otherwise Next Term asks whether to open the project in a **New Window** or in **This Window** (in place of its tabs), with **Remember my choice**. Change the choice later in **Shell › Open Projects In**: **Ask Each Time**, **This Window** or **New Window**. Replacing tabs that are still running something asks first and names what would stop.

A window without a project is a plain terminal window. Its sidebar follows the active tab: the tab’s git work tree, or its folder outside one.

## The project sidebar

**It follows the file you are editing.** Open a file with <kbd>⌘P</kbd>, a search result or a link, or switch editor tabs, and the sidebar opens its folders and selects it, while the keyboard stays in the editor. The scope button at the right of the editor’s tabs (**View › Show File in Project Sidebar**) does it on demand, and brings the sidebar back if it was hidden.

Toggle it with <kbd>⌘B</kbd> (**View › Hide Project Sidebar**). Put it on the left or the right with the sidebar’s ⋯ button or **View › Project Sidebar on the Right**, and drag its edge to resize it.

- **It is live.** Files your agents create, change or delete show up on their own, and commits and checkouts refresh the git state.
- **It stays fast on big projects.** Folders are read in the background, and a folder too big to list in full ends with “… 12,345 more items”.
- **It remembers.** Switching between tabs in different projects keeps what you had expanded and where you had scrolled.
- **Hover a row** for its full path, git state and line counts.

## Git at a glance

**Colours** show each file’s state, and a folder takes the colour of what changed inside it:

| Colour | State |
|---|---|
| Blue | Modified or renamed (a folder that lost a file, too) |
| Green | Added |
| Orange | Untracked |
| Red | Conflicted |
| Olive | Ignored |
| Dimmed | Unchanged files and folders whose names start with a dot |
| Red, struck through | Deleted, not yet committed |

**Line counts** sit at the right of each row, like a pull request: `+12 −3` for the lines added and removed in a file, or in everything below a folder.

**Deleted files keep their rows** until the deletion is committed: struck through, where they were, with the lines they had (`−10`). A folder’s count always adds up to the rows inside it, and a folder deleted whole opens to show what was in it. Double-click a deleted file (or press <kbd>⌥⌘G</kbd>) to see what was removed.

**The header** shows the branch, the total lines added and removed, and how far you are ahead of or behind the upstream: `main +41 −10 ↑2 ↓1`. Hover it for the full story, such as “Branch main, tracking origin/main: 2 ahead, 1 behind. 3 modified, 1 added, 2 untracked.”

Next Term runs git read-only, with `--no-optional-locks`, so the sidebar never holds the index lock while your own git commands, or your agents’, are running. To see a file’s changes in full, press <kbd>⌥⌘G</kbd>: see [Side-by-side diffs](/docs/diffs/).

## File operations

Everything here can be undone with <kbd>⌘Z</kbd>.

| Action | How |
|---|---|
| Rename | <kbd>↩︎</kbd>, or right-click › **Rename…** |
| Move | Drag onto a folder |
| Copy | Drag with <kbd>⌥</kbd> held |
| New file, new folder | Right-click › **New File** or **New Folder** |
| Move to the Trash | <kbd>⌘⌫</kbd> (asks first), or right-click › **Move to Trash** |
| Open a file | Double-click, or <kbd>⌘↓</kbd>; from anywhere, <kbd>⌘P</kbd> ([Go to File](/docs/editor/#go-to-file)) |

Rename selects the name without its extension, as Finder does. Open files follow a rename or a move.

**Drag a file onto a terminal** to type its path there. The path is quoted so that no file name can run a command, and it arrives as a bracketed paste.

### The right-click menu

**Open**, **Show Changes** (for a changed file), **Open in New Tab** (**Open Folder in New Tab** for a file), **Open as Project**, **Reveal in Finder**, **New File**, **New Folder**, **Rename…**, **Move to Trash**, **Send to Agent**, **Insert Path in Terminal**, **Copy Path**, **Copy Relative Path** and **Refresh**. With several rows selected, the menu acts on all of them.

## File icons

Files and folders get open-source icons from the Material Icon Theme (MIT), including framework icons: Laravel, Next.js, Vite, Tailwind, Docker, GitHub Actions and more. Configuration folders such as `.github`, `.claude` and `.idea` stay plain and quiet by default; **Settings › Editor › Sidebar** gives them their icons.
