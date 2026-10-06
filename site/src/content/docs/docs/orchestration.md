---
title: Orchestrate agents (MCP)
description: "Next Term is an MCP server: one agent opens projects, starts other agents in tabs, sends them prompts, waits and reads their screens. 13 tools, local only."
head:
  - tag: title
    content: Orchestrate AI coding agents over MCP — Next Term
---

Next Term is an MCP server, so one agent can run the others. An orchestrator — Claude Code, Codex, Gemini CLI or any other agent that speaks MCP — sees every project and tab with the state of the agent in it, opens projects, starts agents in new tabs or panes, gives them prompts, waits until they stop, reads what they said, answers their questions, and uses the editor. You watch it happen in Next Term’s tabs, and can step in at any moment.

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

Agents you start after that see Next Term’s tools. The line under the setting says where it is registered, for example “Registered in Claude Code, Codex and Cursor.”

- **Only Next Term’s own entry is written,** named `next-term`, and by text: comments and every other server in the file stay byte for byte as they were.
- **Someone else’s `next-term` entry is never touched;** Settings tells you it is there.
- **Turning the setting off removes Next Term’s entries** and stops the server.
- Only the installed app registers itself, never a copy running from the disk image, so the entries never point at a path that is about to disappear.

### Any other MCP client

Add a stdio server that runs `nxtrm mcp`. `nxtrm` is on the `PATH` in Next Term’s tabs and, once installed, in `/usr/local/bin` (see [The nxtrm command](/docs/command-line/)):

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
| `list_tabs` | Every window (one per project) and its tabs: id, title, folder, the program running, and its state — `idle`, `working`, `done`, `failed`, or `attention` with the agent’s question. The caller’s own tab is marked `"you": true`, and panes that share a tab say so. | No |
| `read_tab` | The last lines of a tab’s screen (80 by default, up to 2,000) and its state. | No |
| `wait_for_tab` | Waits until the tab’s agent stops working, or its command finishes, then returns the state and the end of the screen. | No |
| `list_projects` | The projects open in Next Term and the recently opened ones. | No |
| `get_editor_selection` | The file in front in the editor, the selected text and its lines, unsaved edits included. | No |
| `get_open_files` | The files open in each window, which one is in front, and which have unsaved changes. | No |
| `open_project` | Opens a folder as a project in its own window, or brings it to the front, and returns its tabs. | Opens a window |
| `new_tab` | Opens a tab in a folder (in that project’s window, opening the project if needed) and can run a command in it, such as `claude` or `codex`. With `split_beside` and `direction` (`right` or `down`) it opens a pane beside another tab instead. Returns the new tab’s id. | Yes: asks first |
| `send_to_tab` | Types text into a tab as a paste, then presses Return (unless `submit` is false): a prompt, an answer, or a shell command. | Yes: asks first |
| `press_keys` | Presses keys in order: `enter`, `escape`, `tab`, `shift+tab`, the arrows, `backspace`, `space`, `ctrl+c`, `ctrl+d`, or a single character such as `1` or `y`. For an agent’s menus and confirmations. | Yes: asks first |
| `show_tab` | Brings a tab and its window to the front, for you to see. | Brings it forward |
| `close_tab` | Closes a tab. A tab with something running is refused unless `force` is true, which stops it. | Yes: asks first |
| `open_in_editor` | Opens a file in the editor, at a line and column if given. | Opens a file |

“Asks first” means the tool is marked as destructive in its MCP description, so agents that ask before risky actions ask you before using it. Every tool is marked honestly: the six that only read say so.

### Waiting

`wait_for_tab` waits up to 50 seconds by default, because some clients give up on a tool after a minute; `timeout_seconds` raises it to 300. When it returns with `"timed_out": true`, the agent is still working: call it again to keep waiting. Input that a tool has just sent counts as work, so a wait right after `send_to_tab` waits for the job it started, however quickly it begins.

## An example: two projects, two agents

Ask the agent you are talking to (here Claude Code, in any Next Term tab):

> Open ~/Code/api and ~/Code/web in Next Term. Start Claude Code in api and Codex in web. Ask Claude to add rate limiting to the login endpoint with tests, and Codex to show a friendly message on the login page when the limit is hit. Wait for both, answer anything routine, and tell me what each one changed.

What it does with the tools:

1. **`open_project`** with `~/Code/api`, then with `~/Code/web`: two project windows open.
2. **`new_tab`** with `directory: ~/Code/api` and `command: "claude"`, and again with `~/Code/web` and `"codex"`. Each call returns a tab id; both tabs show a spinner once their agent is busy.
3. **`send_to_tab`** gives each agent its task.
4. **`wait_for_tab`** on the Claude tab. It comes back `timed_out`, so the orchestrator calls it again; then it returns `attention` with Claude’s question, “Do you want to make this edit to `routes/api.php`?”
5. **`press_keys`** with `["1"]` answers “Yes” (or the orchestrator asks you, if the question is not routine), and it waits again until the state is `done`.
6. **`wait_for_tab`** on the Codex tab, then **`read_tab`** on both to read their summaries.
7. It reports back to you, and **`show_tab`** puts the tab worth reviewing in front, where <kbd>⌥⌘G</kbd> shows the changes side by side.

To watch a worker next to the agent that started it, the orchestrator can call `new_tab` with `split_beside` set to its own tab: the worker opens as a [split pane](/docs/layouts/#split-panes) beside it.

## Safe by design

- **Local only.** The app listens on a Unix socket, `~/Library/Application Support/Next Term/mcp.sock`, readable and writable only by you (mode `0600`). Every connection is checked to come from your user. There is no network port.
- **The same reach as your own shell.** Anything that can connect can already run commands as you; the server gives an agent no power you have not given it by running it.
- **Agents ask before they act,** because typing into a tab, opening tabs and closing them are marked destructive.
- **An agent cannot type into its own tab or close it.**
- **A busy tab closes only with `force`,** and the error says what is running.
- **Text is typed as a paste,** so it is never run before the Return the tool presses.
- **Off switch:** **Settings › Editor › Agents: “Let agents control Next Term”**. Off, the socket closes and Next Term’s entries are removed from your agents.

More in [Security and privacy](/docs/security-and-privacy/#the-mcp-server).

## Coming later

<span class="nt-soon">Coming later</span> **Remote access** for agents that do not run on your Mac, such as ChatGPT and Claude on the web, through a secure link with its own, explicit security model.
