# Where tasks go

Tasks › Add Task… (⌃⌘T) and the MCP tool `add_task` turn a prompt into a task. By default it is a Markdown file in
the project's todo folder ([the todo file format](todo-files.md)). Each project can send its tasks somewhere else
instead: an app on this Mac, a tracker's new-issue page in your browser, or your own agent, which posts it with its
own tracker tools.

Next Term makes no request for any of this. An app gets the task on this Mac, a page opens in your browser for you
to submit, and an agent's request is typed into its tab for you to send. Next Term holds no account, token or API
key for any of them.

To end a day, Tasks › Wrap Up… (⌃⌘W) turns your agents' handoffs into tomorrow's tasks, and Tasks › Post Update…
drafts an update from today's work: see [Wrap Up and Post Update](wrap-up.md).

## Choosing where

- **Settings › Tasks**, under Destinations: the default, this project's destination, and each destination's
  details (a Reminders list, a repository, a Linear team key…). A destination with nothing to fill (the todo folder,
  Todoist, OmniFocus, Trello, and Linear with no team) saves as soon as it’s chosen; details you type save on Save.
- **Tasks › Send Tasks To**: the front project's destination, ticked, changed in one click. In a window with no
  project it shows and changes the default. A destination that can't be chosen now stays in the list, greyed, with
  why (not installed, not allowed in Privacy & Security, details missing).
- **The Add Task sheet's Destination**: for one task only. The project's destination stays as it was.

A project's choice is kept in Next Term's own settings, keyed by the project's main checkout, so every worktree of
a project shares it. It is never written into the repository: nothing in a project can send your tasks elsewhere.
A project with no choice of its own uses the default, and the default is the todo folder until you change it.

Under Destination, the sheet says in one line exactly where the task goes, and What's sent shows the exact text or
link that leaves, before you press Add.

## What each destination gets

| Destination | Kind | What is sent | The day | Limit |
|---|---|---|---|---|
| Todo Folder | `todo_folder` | a Markdown file in the project's todo folder | `planned` in the file | none |
| Reminders | `reminders` | title; notes hold the steps as `- [ ]` lines, the notes, then where it was added | an all-day due date | none |
| Things | `things` | `title`, `notes`, `checklist-items` (the steps), `when`, `list` when set | `when`: today, tomorrow or the date | notes 10,000 characters, 100 checklist items |
| Run a Shortcut | `shortcut` | the shortcut's input: the title, then steps, notes and where it was added | a line `Planned: <date>` | none |
| Todoist | `todoist` | Quick Add with `content` and `description` | set it there | link 6,000 bytes |
| OmniFocus | `omnifocus` | Quick Add with `name` and `note` | set it there | link 6,000 bytes |
| GitHub | `github` | the new-issue page with `title` and `body`, steps as task-list lines | none | link 6,000 bytes |
| GitLab | `gitlab` | gitlab.com's new-issue page with its title and description | none | link 6,000 bytes |
| Linear | `linear` | the team's new-issue page (or linear.new with no team) with `title` and `description` | none | link 6,000 bytes |
| Trello | `trello` | the new-card page with `name` only | none | name 300 characters |
| Azure Boards | `azure_boards` | the new work item page of the chosen type with its title and description | none | description 2,000 characters |
| Through Your Agent | `through_agent` | one request typed into an agent tab you pick, with no Return | in the request's text | none |

- **Reminders' due date.** Reminders has no field for the day you plan to do something; its Today and Scheduled
  lists go by the due date. So the planned day becomes an all-day due date, and the sheet's line says "due". No
  alert is set unless you turn on "Alert at 9:00 on the day" in Reminders' details. Tasks go to a list named
  "Next Term" unless you pick another. Next Term asks macOS for Reminders only when you first choose it, after a
  sheet that says why; macOS has no add-only access to reminders.
- **Run a Shortcut** runs `shortcuts run <the shortcut's identifier> --input-path -` with the text as its input, with
  no shell, and stops it after 60 seconds. The shortcut decides where the text goes, with its own permissions.
- **Apps** (Things, Todoist, OmniFocus) get a link opened only in the vendor's own app, never in another app that
  claims the same link. The first link to Things makes Things ask once whether to enable Things URLs.
- **Pages** open in your browser, filled in. Nothing is saved until you press its own Create or Save.
- **Cut to fit.** A text longer than its destination takes is cut at a line end and ends with a line saying so,
  such as "(Cut by Next Term: Things takes 10,000 characters.)". What's sent shows the cut text first.
- **Where it was added.** With "Add where you are to new tasks" on in Settings › Tasks, the apps and the shortcut
  get the project, branch, tab and agent, and the agent's resume command. Team pages and the agent request get the
  branch only: a tab's title or a resume command means nothing to a teammate.

## What never leaves

- **Stored keys.** Every text is masked before it is shown or sent: a value kept in Secrets reads `•••` in the
  sheet, in What's sent, in the approval window and in what the app, page, shortcut or agent gets. A task that
  held `token=•••` arrives as `token=•••`.
- **This Mac's details on team pages.** GitHub, GitLab, Linear, Trello, Azure Boards and the agent request never
  get the tab's title, the agent or its resume command.
- **Logs.** The task's text, its link and where it went are never written to a log or a crash report.

## Through Your Agent

For a tracker with no page Next Term can fill, or one you'd rather post to with your agent's own tools (Jira,
Notion, Asana…), pick Through Your Agent and name the tracker. Add types one request into an agent tab of this
window that you pick:

```text
Add this task to Jira with your Jira tools, exactly as written, then tell me its link.
```

followed by the task. Only agent tabs that are ready are offered: one that is working, or has your own text in its
prompt, is greyed with why. Next Term never presses Return. You read the request in the tab and send it, and your
agent posts it with its own sign-in. Without bracketed paste, the task's lines are joined with " / ".

## The posted record

Each task sent anywhere but the todo folder adds one line to `Tasks.noindex/posted.jsonl` in Next Term's folder in
Application Support, readable only by you: when, the destination's kind and its key (the list or the repository),
the masked title and the project. Lines older than 30 days are dropped. It is used for three things only: the
warning when the same task goes to the same place again within a minute, Reminders' Undo, and what was posted
today. Nothing that leaves the Mac reads it.

## add_task's destination

The MCP tool `add_task` takes an optional `destination`:

- `project` (the default): the project's destination, after you Approve on the Mac. The approval window shows the
  same line and the same masked text the Add Task sheet would.
- `todo_folder`: always the todo folder, for a task meant for tomorrow's agent in this project.

An agent can't name an app, a page or an agent tab: where your tasks go is your choice. A project whose tasks go
Through Your Agent refuses `project` and tells the agent to post it with its own tools or pass `todo_folder`. The
answer names where the task went (`todo_folder`, `reminders`, `things`, `shortcut`, `todoist`, `omnifocus`,
`github`, `gitlab`, `linear`, `trello` or `azure_boards`), and pages and Quick Add say `"waiting_for_user": true`.

## Connect a Tracker to Your Agents

Tasks › Connect a Tracker to Your Agents… (also in Settings › Tasks and beside Through Your Agent's details) lists,
for each tracker, the line each agent's own docs or the tracker's own page print to add the tracker's MCP server.
Claude Code's lines add `--scope user`, so the tracker works in every project. Copy puts a line on the clipboard.
Open in a New Tab, shown when the agent is found on this Mac, types it into a new tab with no Return: Next Term
never runs it, never reads or writes an agent's config, and that tab refuses text typed by an agent. You press
Return, and the agent's own command adds the server; signing in is the agent's (`/mcp` in Claude Code,
`codex mcp login <name>` in Codex).

The lines, as they are typed:

```sh
claude mcp add --transport http --scope user linear-server https://mcp.linear.app/mcp
codex mcp add linear --url https://mcp.linear.app/mcp
codex mcp add github --url https://api.githubcopilot.com/mcp/ --bearer-token-env-var GITHUB_PAT_TOKEN
claude mcp add --transport http --scope user atlassian https://mcp.atlassian.com/v2/mcp
codex mcp add atlassian --url https://mcp.atlassian.com/v2/mcp
claude mcp add --transport http --scope user notion https://mcp.notion.com/mcp
claude mcp add --transport http --scope user plane https://mcp.plane.so/http/mcp
codex mcp add plane --url https://mcp.plane.so/http/mcp
claude mcp add --transport http --scope user shortcut https://mcp.shortcut.com/mcp
claude mcp add --transport http --scope user ticktick https://mcp.ticktick.com
codex mcp add ticktick --url https://mcp.ticktick.com
claude mcp add --transport http --scope user todoist https://ai.todoist.net/mcp
```

Codex reads GitHub's token from `GITHUB_PAT_TOKEN` in its own environment; Next Term doesn't set it or see it.
opencode adds a server by asking its questions one by one, so its row links to opencode's own page instead. A
tracker and agent with no line on either page are not offered: a line is never guessed.

### Not listed yet

- GitHub with Claude Code: GitHub’s line writes your token into Claude Code’s settings file.
- Asana: Asana’s server needs an OAuth app of your own.
- ClickUp: No line from ClickUp’s own page yet.
- Azure DevOps: No line from Azure DevOps’s own page yet.

## Held destinations

These are not offered yet, each until it is checked by hand on a real account:

- **Jira's new-issue page**: Atlassian documents no Cloud link that fills a new issue. Post to Jira Through Your
  Agent instead.
- **TickTick**: its add link is not documented for the Mac app.
- **Self-managed GitLab and GitHub Enterprise**: each needs a host field and its own check. GitLab here is
  gitlab.com, and GitHub is github.com.
