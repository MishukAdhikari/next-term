# Todo files

Tasks › Add Task… (⌃⌘T) and the MCP tool `add_task` turn a prompt into a task: one Markdown file in the project's
todo folder, so tomorrow's agent session in that project can read it with its own file tools. This is the format of
those files. It is open: any program, agent or person can read and write it. A project can send its tasks to an app,
a tracker's page or your agent instead: see [where tasks go](task-destinations.md).

## Where

- `<project>/todo/`, or the folder Settings › Tasks names: a path inside each project, or one absolute folder.
- In a linked worktree, the folder is in the main checkout; for a bare repository, in the worktree itself.
- Every `.md` file in that folder is a todo file, a hand-written one included.

## Name

`<created yyyy-mm-dd>-<slug>.md`.

- The slug is the title in lower case, with letters of any script kept. `/ : \ * ? " < > |` and control characters
  are dropped, and runs of spaces become one `-`.
- It is cut at a word to at most 50 characters. An empty slug becomes `task`. A name that exists gets `-2`, `-3` and
  so on.
- The name never changes after it is made.

## Text

UTF-8, LF line endings, a final newline.

## Front matter

Optional; flat `key: value` lines between `---` lines. Readers ignore keys they don't know. Writers add keys and
never rename them.

- Dates are bare (`2026-10-16`) and times are ISO 8601 with offset. Words from a fixed set are bare (agent kinds).
  Every other value is double-quoted, with `\\`, `\"` and `\uXXXX` escapes.
- The keys, in this order; empty ones are left out:

| Key | Meaning |
|---|---|
| `created` | when the task was added |
| `scheduled` | the day it is planned for; never a deadline |
| `due` | a deadline, only when the user sets one (later slice) |
| `project`, `path` | only in a folder outside the project |
| `branch` | the branch at the time |
| `tab` | the tab's title |
| `agent` | the agent's kind, such as `claude` or `codex` |
| `resume` | the command that resumes that agent's session |
| `added_by` | `you`, or who asked: an agent in a tab, or a connection |

## Body

- The task is the first top-level `- [ ]` (open) or `- [x]` / `- [X]` (done) line outside code fences. Its text is
  the title.
- Box lines nested under it are its steps. Anything after the checklist is notes, in Markdown.
- A file may hold more than one top-level task; Next Term writes one.

## Example

```markdown
---
created: 2026-10-15T18:42:07+06:00
scheduled: 2026-10-16
branch: "fix/login"
tab: "api"
agent: claude
resume: "claude --resume 7f3c2a"
added_by: "Claude Code in tab “api”"
---
- [ ] Finish the login fix
  - [ ] Write the test for expired tokens
  - [ ] Ask Sam about the refresh endpoint

Branch is fix/login, see PR 512.
```

## Reading it tomorrow

An agent lists `todo/*.md` and reads the open boxes, with `scheduled:` for the day. Ticking a task changes the one
character between its brackets.

## Keeping tasks out of git, or sharing them

Next Term never edits `.gitignore`, and the todo folder shows in `git status` like any other new folder. To keep your
tasks to yourself, add the folder to the project's `.gitignore`:

```
todo/
```

or, to leave the shared `.gitignore` as it is, to `.git/info/exclude`, which only your checkout reads. To share them
with your team, commit the folder: each task is its own file, so adding one never changes another.
