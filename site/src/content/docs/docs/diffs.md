---
title: Diffs and Git Diff
description: "See everything a branch changed in the Git Diff tab (⌃⌘G), a file’s changes side by side or unified with ⌥⌘G, and stage, unstage or revert one hunk at a time, without overwriting an agent’s concurrent edit."
head:
  - tag: title
    content: Git diffs side by side or unified, with hunk staging — Next Term
---

An agent just touched twelve files. Before you commit, you want to see each change the way a pull request shows it, keep the good parts and throw out the rest. The **Git Diff** tab does that next to the terminal where the agent is still running: the changed files on the left, their diff on the right.

![A diff tab “diff.txt ↔ HEAD”: All Changes, Unstaged and Staged at the top, +2 −2, “1 of 2” with arrows, and Revert Hunk. The old version on the left and the new on the right, with the changed words marked in red and green.](../../../assets/screenshots/diff.webp)

## Git Diff

**Git › Git Diff** (<kbd>⌃⌘G</kbd>) opens the repository’s changes in one tab. **Git Diff** in the [branch popup](/docs/projects-and-git/#branches) opens it too, and so does a click on the `+41 −10` at the top of the project sidebar.

- **The changed files**, on the left, as a tree of only the folders that hold changes, all open. Each file has its icon, its `+12 −3`, and **A**, **D** or **R** when it was added, deleted or renamed. <kbd>↑</kbd> and <kbd>↓</kbd> move from file to file; <kbd>↩</kbd> goes to the diff.
- **A file’s diff**, on the right, is the one described below, with everything it has: All Changes, Unstaged and Staged, the hunk buttons, Send to Agent. Past its last change, the arrow goes on to the next file’s first one (and back the other way), and the list follows.
- **All files**, above the files, shows every file’s diff on one page: a header row for each (its name and folder, `+/−`, a chevron that folds it away, and buttons to open the file or show it side by side), then its lines, unified. Long unchanged runs are folded into rows like “67 unmodified lines”: click one to see them. **Collapse All** folds every file away. A file with a very large diff says so, with **Show anyway**. The page is laid out as you scroll, so a large change stays quick.

### What it compares

Under the files, choose what to compare:

- **All changes:** everything your branch changed since it parted from its base, committed or not, together. The base is the default branch of your upstream’s remote (`origin/main`), else `main` or `master`. It is named at the top of the tab, `main → feat/login`: click it to count from another branch, which Next Term remembers for the repository. On the base branch itself, All changes is what isn’t committed yet.
- **Uncommitted:** the files on disk and the index against the last commit. It is listed while there is something uncommitted.
- **A commit:** your branch’s commits since its base, newest first, with the hash, author and date, 100 at a time as you scroll (on the base branch, its history). Select one for the files it changed, each against the commit before.

### It keeps up

The tab reads the repository again when it changes: an agent’s next edit, a commit, a stage. The file you were on stays selected, scrolled where it was, with the folds you opened still open. A file that is no longer changed leaves the list, and the selection moves to the one after it.

The button at the top left hides the file list, and brings it back; drag its edge to resize it. Next Term remembers both. Git Diff only reads, with `--no-optional-locks`, so it never holds the index lock while your git commands, or your agents’, run. An agent’s proposed edits and the Git Log’s commit diffs still open in tabs of their own.

## Open a file’s diff

- Press <kbd>⌥⌘G</kbd> (**View › Show Changes**) to see the changes of the file you are editing. The Git Diff tab opens on it, under Uncommitted, with the other changed files beside it.
- In the project sidebar, select a changed file and press <kbd>⌥⌘G</kbd>, or right-click it and choose **Show Changes**.
- In the editor, click a change mark in the gutter.

The file has to be in a git repository: changes are shown against the last commit.

## Side by side or unified

The switch at the top of every diff, **Side by Side | Unified**, chooses how it shows; **View › Unified Diffs** does the same. One choice holds for every diff, an agent’s proposed edit and a past commit’s included, and Next Term remembers it.

- **Side by Side:** the old version on the left, the new on the right, rows aligned.
- **Unified:** one column, top to bottom. Removed lines are on red with `−` and their number in the old file, the lines that replace them on green with `+` and their number in the new one, with the unchanged lines between. Long unchanged runs are folded into rows like “26 unmodified lines”, and a click shows them.

In Unified, the hunk buttons act on the current change, the one “2 of 3” names and the gutter marks: selecting lines or clicking a row makes their change the current one, and so do the arrows and scrolling. Right-click a row for **Stage Hunk**, **Unstage Hunk** or **Revert Hunk…** on that row’s change, whatever else is selected, **Send to Agent** and **Copy**.

## Read it

- **Old on the left, new on the right** (side by side), rows aligned so a changed line sits next to its old self.
- **Removed lines are tinted red, added lines green**, and the words that changed within a line are marked more strongly, in both views.
- **Syntax-coloured** with the editor’s grammars; side by side, both sides scroll together.
- The header shows the file, its folder, and the `+` and `−` line counts.
- **Step through the changes** with the arrows (“1 of 2”). Scrolling also picks the change at the top of the view, and clicking a row picks its change.
- The diff **refreshes by itself** when the file or the git index changes: an agent’s next edit, a commit, a stage.

## All changes, unstaged or staged

The switch at the top chooses what to compare:

| View | Compares | Tab title |
|---|---|---|
| All Changes | The file on disk against the last commit | `file ↔ HEAD` |
| Unstaged | The file on disk against the index | `file ↔ Index` |
| Staged | The index against the last commit | `file ↔ HEAD` |

In the Git Diff tab, a file under All changes is read-only: the file on disk against where your branch parted from its base, titled like `app.txt ↔ main`. A branch’s diffs open from the branch popup, read-only too: `file @ feat/x` is what that branch changed since it parted from yours, and `file ↔ feat/x` is the file on disk against that branch. See [Compare a branch](/docs/projects-and-git/#compare-a-branch).

## Stage, unstage or revert one hunk

Act on the current change (the hunk) with the buttons on the right:

- **Stage Hunk** (in Unstaged) adds just those lines to the index, like `git add -p`.
- **Unstage Hunk** (in Staged) takes them out again.
- **Revert Hunk** (in All Changes and Unstaged) puts those lines back the way they were. Next Term asks first, and <kbd>⌘Z</kbd> undoes it.

You build a clean commit out of an agent’s work one hunk at a time, without leaving the window and without remembering `git add -p`’s keys.

## Send lines to your agent

Select lines on the new side (the right), or in the Unified column, and press <kbd>⌥⌘K</kbd> (**Edit › Send to Agent**): the agent in your tab gets the file at those lines, in its own syntax, as from the editor (`@app/User.php#L10-20` for Claude Code, `app/User.php:10-20` for Codex). A selection on the old side picks the same rows, and the new side’s lines in them are sent. With nothing selected, the file is sent. See [Send to Agent](/docs/agents/#send-to-agent-k).

- **Staged:** the index isn’t the file on disk, so the reference says “(as staged)” and the selected lines are pasted after it.
- **A past commit:** the reference says “(as of commit 4cc062d)”, with the selected lines pasted after it.
- **Removed lines only:** select red lines on the old side and they are pasted after the reference, which says “(lines removed)”: the file no longer has them.
- **A deleted file** is sent as “(deleted)”, with any lines you select pasted after it.
- **An agent’s proposed edit:** nothing is sent. The agent is waiting for your answer in its terminal; accept or reject first.

Lines pasted from two changes at once have a `⋯` line where the diff skips the unchanged lines between them. More than 200 lines (or 16 KB) are not pasted: the reference goes alone, and a selection of removed lines that large sends nothing.

## Safe while agents keep working

Agents keep editing while you review. Each hunk action first checks that the file, or the index, is exactly what the diff was made from, by its full git blob id. If anything changed in the meantime, nothing is touched: Next Term tells you, refreshes the diff, and you try again on what is really there. (Plain `git apply` would place a stale hunk at an offset instead of failing.)

Other guards:

- **Unsaved edits:** reverting a change in a file with unsaved edits in the editor is refused until you save or close it.
- **Git is busy:** if another git command holds the index lock (an agent committing, say), Next Term says so; try again in a moment.
- **Undo is careful too:** <kbd>⌘Z</kbd> after a revert restores the file only if nothing changed it since.

## Proposed edits from agents

When Claude Code, Gemini CLI or Qwen Code proposes an edit, it opens in the same kind of diff tab with **Accept** (<kbd>⌘↩︎</kbd>) and **Reject** instead of the hunk buttons. See [Proposed edits open as a diff](/docs/agents/#proposed-edits-open-as-a-diff).

## A file in a past commit

In the [Git Log](/docs/projects-and-git/#git-log), double-click a file in a commit’s changed files to see what that commit did to it, against the commit before. The tab is titled like `app.txt @ 4cc062d` and is read-only: a commit never changes, so there is nothing to stage or revert.

## Coming next

<span class="nt-soon">Coming soon</span> Staging selected lines, and editing the proposed side of an agent’s change before you accept it.
