---
title: Orchestrate agents (MCP)
description: "Next Term as an MCP server: one agent starts others in tabs, prompts them, reads their screens, answers their questions and reads files. 18 local tools."
head:
  - tag: title
    content: Orchestrate AI coding agents over MCP — Next Term
---

Next Term is an MCP server, so one agent can run the others. An orchestrator — Claude Code, Codex, Gemini CLI or any other agent that speaks MCP — sees every project and tab with the state of the agent in it, opens projects, starts agents in new tabs or panes, gives them prompts, waits until they stop, reads what they said, answers their questions, reads the projects’ files and changes, and uses the editor. You watch it happen in Next Term’s tabs, and can step in at any moment.

## Nothing to set up

**Settings › Editor › Agents: “Let agents control Next Term”** is on by default. While it is on, Next Term adds its server, `nxtrm mcp`, to the agents it finds on your Mac:

| Agent | Where Next Term registers |
|---|---|
| Claude Code | Through `claude mcp add-json --scope user`, so Claude writes its own file |
| Codex | `~/.codex/config.toml` |
| Gemini CLI | `~/.gemini/settings.json` |
| Qwen Code | `~/.qwen/settings.json` |
| Cursor Agent | `~/.cursor/mcp.json` |
| opencode | `~/.config/opencode/opencode.json` (or `.jsonc`, whichever exists) |
| GitHub Copilot CLI | `~/.copilot/mcp-config.json` |
| Amp | `~/.config/amp/settings.json` |
| Junie | `~/.junie/mcp/mcp.json` |
| Command Code | `~/.commandcode/mcp.json` |
| Claude desktop app | `~/Library/Application Support/Claude/claude_desktop_config.json` (`Claude-3p` instead of `Claude` when Claude is set up to use a third-party platform) |

Agents you start after that see Next Term’s tools. The line under the setting says where it is registered, for example “Registered in Claude Code, Codex and Cursor.”

- **Only Next Term’s own entry is written,** named `next-term`, and by text: comments and every other server in the file stay byte for byte as they were.
- **Someone else’s `next-term` entry is never touched;** Settings tells you it is there.
- **Turning the setting off removes Next Term’s entries** and stops the server. The Claude desktop app’s goes once Claude is closed (see below).
- **A file it cannot edit safely is left alone,** for example a read-only one; for the Claude desktop app, the line under the setting says why.
- Only the installed app registers itself, never a copy running from the disk image, so the entries never point at a path that is about to disappear.

### The Claude and ChatGPT desktop apps

- **Claude:** the desktop app reads `claude_desktop_config.json` only when it starts, for its chats and for the local sessions in its Code tab (there this entry is used instead of Claude Code’s). It also saves the whole file from the copy it read, so Next Term changes the file only while Claude is closed. If Claude is open, Next Term adds itself (or, with the setting off, takes itself out) when you quit Claude, or at its own next launch if it was not running then, and the line under the setting says so; open Claude again to load it. Next Term adds only its own server there; the app’s preferences in the same file stay as they were.
- **ChatGPT:** the desktop app reads Codex’s `~/.codex/config.toml`, so the Codex entry covers it, and the line under the setting names both. Next Term writes it when the ChatGPT app or Codex is installed. Restart ChatGPT if it was open when Next Term added itself.

### Any other MCP client

Add a stdio server that runs `nxtrm mcp`. `nxtrm` is on the `PATH` in Next Term’s tabs and, once installed, in your other terminals (see [The nxtrm command](/docs/command-line/#installing-it)):

```json
{
  "mcpServers": {
    "next-term": { "command": "nxtrm", "args": ["mcp"] }
  }
}
```

`nxtrm mcp` answers an agent’s start-up questions itself, so the agent starts at once whether or not Next Term is running. Tool calls need the app: if it is closed, or the setting is off, they say so.

## The tools

| Tool | What it does | Changes anything? |
|---|---|---|
| `list_tabs` | Every window (one per project) and its tabs: id, title, folder, the program running, and its state — `idle`, `working`, `done`, `failed`, or `attention` with the agent’s question, its choices and a `question_id`. A tab running a local dev server also gives its address as `served_url`. The caller’s own tab is marked `"you": true`, and panes that share a tab say so. | No |
| `read_tab` | The last lines of a tab’s screen (80 by default, up to 2,000) and its state, with the question, its choices and `question_id` while its agent asks one. | No |
| `wait_for_tab` | Waits until the tab’s agent stops working, or its command finishes, then returns the state and the end of the screen. | No |
| `list_projects` | The projects open in Next Term and the recently opened ones. | No |
| `get_editor_selection` | The file in front in the editor, the selected text and its lines, unsaved edits included. | No |
| `get_open_files` | The files open in each window, which one is in front, and which have unsaved changes. A [preview tab](/docs/editor/#preview-tabs) is marked `preview`. | No |
| `read_file` | A text file in an open project, as saved on disk: 400 lines by default from `offset`, up to 2,000 per call, with the total and where to read on. Files over 5 MB, binary files and secrets files are refused (see below). | No |
| `find_in_files` | Searches an open project the way Find in Files does (text, or a regular expression with `regex`; `case_sensitive`, `whole_word`, and `glob` masks such as `*.ts, !*.min.js`). Each match comes with its file, line, column and the line’s text; 50 by default, up to 200. | No |
| `git_status` | An open project’s branch, its upstream with commits ahead and behind, and each changed file: its state, whether it has staged and unstaged changes, and lines added and removed. | No |
| `get_diff` | The unified diff of a file, or of every changed file, against the last commit (`which: "head"`), or only what is staged or unstaged. Cut at 60,000 characters by default. | No |
| `open_project` | Opens a folder as a project in its own window, or brings it to the front, and returns its tabs. | Opens a window |
| `new_tab` | Opens a tab in a folder (in that project’s window, opening the project if needed) and can run a command in it, such as `claude` or `codex`. With `split_beside` and `direction` (`right` or `down`) it opens a pane beside another tab instead. Returns the new tab’s id. | Yes: asks first |
| `send_to_tab` | Types text into a tab as a paste, then presses Return (unless `submit` is false): a prompt, an answer, or a shell command. | Yes: asks first |
| `press_keys` | Presses keys in order: `enter`, `escape`, `tab`, `shift+tab`, the arrows, `backspace`, `space`, `ctrl+c`, `ctrl+d`, or a single character such as `1` or `y`. For an agent’s menus and confirmations. | Yes: asks first |
| `answer_agent` | Answers the question an agent is asking: give the tab, the `question_id` that came with the question, and the `choice` (its number) or `answer` (its words). It moves the agent’s own cursor to the choice with the arrow keys and presses Return, or types `y` or `n` for a y/n prompt. If the tab now asks something else, or nothing, it types nothing and says what is on screen. | Yes: asks first |
| `show_tab` | Brings a tab and its window to the front, for you to see. | Brings it forward |
| `close_tab` | Closes a tab. A tab with something running is refused unless `force` is true, which stops it. The last tab in a window with unsaved files in its editor would close the window, so you are asked whether to save them first, and the answer says `closed: false`. | Yes: asks first |
| `open_in_editor` | Opens a file in the editor, at a line and column if given. | Opens a file |
| `list_skills` | Your personal agent skills, and what Claude Code, Codex and Command Code each do with each one (`loads`, `off`, `skipped` or `none`), where it came from, and whether an update was found. | No |
| `install_skill` | Asks you to install a skill from a public GitHub `source`, with the agent’s `reason`. Nothing is fetched until you choose Fetch and Review in Next Term, and nothing is written until you install it from the review. See [Agents asking for skills](#agents-asking-for-skills). | Only if you say so |
| `remove_skill` | Asks you to remove an installed skill by `name`; you see what goes and decide, and Undo puts it back. | Only if you say so |

“Asks first” means the tool is marked as destructive in its MCP description, so agents that ask before risky actions ask you before using it. Every tool is marked honestly: the eleven in this table that only read say so.

Seven more tools work with your servers: `list_hosts`, `add_host`, `remove_host`, `check_host`, `new_remote_tab`, `host_sessions` and `host_changes`. They are described in [Remote tabs: for agents](/docs/remote/#for-agents-mcp). Of these, only `list_hosts` only reads; the others are marked so that your agent’s client asks you first.

### Waiting

`wait_for_tab` waits up to 50 seconds by default, because some clients give up on a tool after a minute; `timeout_seconds` raises it to 300. When it returns with `"timed_out": true`, the agent is still working: call it again to keep waiting. Input that a tool has just sent counts as work, so a wait right after `send_to_tab` waits for the job it started, however quickly it begins.

The orchestrator is the one waiting, so a tab it opened with `new_tab` or gave input to does not notify you when its agent finishes while you are in Next Term; from another app, it does, and its decisions always do. Type in the tab yourself and it notifies you again like any other. See [Notifications and the Dock badge](/docs/agent-status/#notifications-and-the-dock-badge).

### Agents asking for skills

`install_skill` and `remove_skill` are requests, not actions. Each opens a small window naming the tab that asked, or saying the request came from outside Next Term’s tabs, with the agent’s reason shown as its own words. The window does not take the keyboard and has no Return button, so typing meant for a terminal never answers it. One request is open at a time: another one gets `busy`. A source you decline stays declined until Next Term quits. The call answers within about 50 seconds: `installed`, `removed`, `declined`, `failed` with a `note` saying why (for example, the download changed after the review), or `pending` with a `request_id` the agent passes again to keep waiting.

## An example: two projects, two agents

Ask the agent you are talking to (here Claude Code, in any Next Term tab):

> Open ~/Code/api and ~/Code/web in Next Term. Start Claude Code in api and Codex in web. Ask Claude to add rate limiting to the login endpoint with tests, and Codex to show a friendly message on the login page when the limit is hit. Wait for both, answer anything routine, and tell me what each one changed.

What it does with the tools:

1. **`open_project`** with `~/Code/api`, then with `~/Code/web`: two project windows open.
2. **`new_tab`** with `directory: ~/Code/api` and `command: "claude"`, and again with `~/Code/web` and `"codex"`. Each call returns a tab id; both tabs show a spinner once their agent is busy.
3. **`send_to_tab`** gives each agent its task.
4. **`wait_for_tab`** on the Claude tab. It comes back `timed_out`, so the orchestrator calls it again; then it returns `attention` with Claude’s question, “Do you want to make this edit to `routes/api.php`?”, its choices and a `question_id`.
5. **`get_diff`** on that file shows what Claude has changed there so far, and **`read_file`** reads the code around it.
6. **`answer_agent`** with that `question_id` and `choice: 1` answers “Yes” (or the orchestrator asks you, if the question is not routine), and it waits again until the state is `done`.
7. **`wait_for_tab`** on the Codex tab, then **`read_tab`** on both to read their summaries, and **`git_status`** on each project to see which files changed.
8. It reports back to you, and **`show_tab`** puts the tab worth reviewing in front, where <kbd>⌥⌘G</kbd> shows the changes side by side.

To watch a worker next to the agent that started it, the orchestrator can call `new_tab` with `split_beside` set to its own tab: the worker opens as a [split pane](/docs/layouts/#split-panes) beside it.

### Questions are answered once

A question’s `question_id` changes whenever the agent asks a new question, even one in the same words. `answer_agent` checks it against the question on screen before it types anything, so an answer meant for one question never lands on the next. It moves the agent’s cursor with the arrow keys and checks that the cursor reached the choice before it presses Return. It never types the choice’s digit: some agents take a digit as the whole answer, and the Return after it would answer whatever comes next.

### Files, search and changes

`read_file`, `find_in_files`, `git_status` and `get_diff` read only inside the projects open in Next Term:

- **Paths stay inside.** A path is relative to the project, or absolute inside an open project. Symlinks are resolved first, so a link that leads outside is refused.
- **Secrets files are never read.** `.env` files (except `.env.example`), keys and certificates (`*.pem`, `*.key`, `*.p12` and the like), ssh keys (`id_rsa`, `id_ed25519`), credentials files (`.netrc`, `.npmrc`, `credentials…`, `secrets.…`, Terraform state) and git’s own `.git` folder are refused with the reason. Search skips them, and diffs leave them out and say so.
- **Secret-looking values are masked** as `•••` in what the tools return: known token formats (`sk-…`, `ghp_…`, AWS keys and others), private keys, passwords in URLs, the values of settings named like secrets (`api_key`, `password`, `token`), and long random-looking strings. Code, paths and commit ids stay readable.
- **Text only, and capped.** Binary files and files over 5 MB are refused, and one answer carries about 60,000 characters at most.
- **Reading never locks git.** Status and diffs use the same read-only git commands as the sidebar, so they never get in the way of an agent’s own `git commit`.

## Safe by design

- **Local only.** The app listens on a Unix socket, `~/Library/Application Support/Next Term/mcp.sock`, readable and writable only by you (mode `0600`). Every connection is checked to come from your user. There is no network port.
- **The same reach as your own shell.** Anything that can connect can already run commands as you; the server gives an agent no power you have not given it by running it.
- **Agents ask before they act,** because typing into a tab, answering an agent’s question, opening tabs and closing them are marked destructive.
- **Files are read, never written,** only inside the open projects, and never the ones that hold secrets.
- **An agent cannot type into its own tab or close it.**
- **A busy tab closes only with `force`,** and the error says what is running.
- **Text is typed as a paste,** so it is never run before the Return the tool presses.
- **Off switch:** **Settings › Editor › Agents: “Let agents control Next Term”**. Off, the socket closes and Next Term’s entries are removed from your agents.

More in [Security and privacy](/docs/security-and-privacy/#the-mcp-server).

## Coming later

<span class="nt-soon">Coming later</span> **Remote access** for agents that do not run on your Mac, such as ChatGPT and Claude on the web, through a secure link with its own, explicit security model.
