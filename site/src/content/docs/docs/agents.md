---
title: Agents and the IDE link
description: "Claude Code, Gemini CLI, Qwen Code, Copilot CLI and opencode connect to Next Term as their IDE: live selection, edits as diffs, and Send to Agent (⌥⌘K)."
head:
  - tag: title
    content: Claude Code IDE integration and Send to Agent — Next Term
---

Agents in a terminal work blind: they cannot see what you are looking at, and their edits land in files you have not read yet. Next Term closes that gap. Agents that have an IDE protocol connect to Next Term as their IDE. Every agent gets **Send to Agent**, which types a reference to your selection into its prompt, and Next Term’s **MCP tools**, which let it read the editor’s selection and open files — and drive other agents.

## What each agent gets

| Agent | Tab status | IDE link: live selection, edits as diffs | MCP tools, set up for you | Send to Agent (<kbd>⌥⌘K</kbd>) | Its sessions, to resume |
|---|---|---|---|---|---|
| Claude Code | From its screen | Yes | Yes | Yes, as an @-mention | Yes |
| Gemini CLI | From its screen | Yes, with the open files | Yes | Yes | Yes |
| Qwen Code | From output timing | Yes, with the open files | Yes | Yes | Yes |
| GitHub Copilot CLI | From output timing | Yes | Yes | Yes, as an @-mention | Yes |
| opencode | From output timing | The selection only | Yes | Yes, as an @-mention | Yes |
| Codex, Command Code | From its screen | — | Yes | Yes | Yes |
| Cursor Agent | From output timing | — | Yes | Yes | Yes |
| Amp, Junie | From output timing | — | Yes | Yes | — |
| Other agents | From output timing, for the ones it recognises by name | — | Add `nxtrm mcp` yourself | Yes | — |

- **From its screen:** the spinner follows the agent’s own “esc to interrupt” hint, so it stops the moment the agent stops, and its permission questions turn the tab amber. The hints are checked against that agent’s own screen.
- **From output timing:** printing counts as working and 2.5 seconds of silence as done. An idle agent that keeps redrawing its screen can keep the spinner going, and a question turns the tab amber only if the agent words it the way Claude Code or Codex does, or rings the bell. Next Term reads every agent’s screen the same way, so if one of these agents shows the same hints, its tab follows them.

See [How Next Term knows](/docs/agent-status/#how-next-term-knows).

With the MCP tools, any of these agents can ask for the editor’s selection (`get_editor_selection`) and open files (`get_open_files`), and one of them can run the others. See [Orchestrate agents (MCP)](/docs/orchestration/).

## Claude Code sees your editor

There is nothing to set up. Start `claude` in a Next Term tab and it connects to Next Term as its IDE, through the protocol Claude Code uses for editors. This is verified with Claude Code 2.1.280.

- **The lines you select go with your next prompt.** Claude shows “⧉ 10 lines selected” above its input, so you can ask about “this function” without pasting it. With nothing selected, Claude knows which file you have open.
- **<kbd>⌥⌘K</kbd> puts an @-mention straight into Claude’s prompt**, such as `@app/User.php#L10-20`.
- **A `claude` started in another terminal** inside one of your open projects finds Next Term too.

![The editor with two lines selected in main.php, and Claude Code running in the terminal below, showing “2 lines selected” in its prompt.](../../../assets/screenshots/claude-selection.webp)

## Proposed edits open as a diff

When Claude wants to change a file, its change opens in a diff tab: your file on the left, Claude’s version on the right, the changed words marked. The header reads “Claude proposes changes to `main.php`”.

- **Accept** (<kbd>⌘↩︎</kbd>): Claude writes the file.
- **Reject**: the file stays as it is.
- **Closing the tab** counts as Reject.
- **Answering in the terminal** works too, as it always has.

Next Term never writes the file itself; the agent does, after you accept. You read every change before it lands, in the same window as the agent that made it. Step through the changes in a long proposal with the arrows in the header.

![A diff tab titled “main.php ✻ Claude”: the header says Claude proposes changes to main.php, +1 −1, with Reject and Accept buttons. The left side has “Hello”, the right side “Hi”, with the changed word marked.](../../../assets/screenshots/proposal-window.webp)

## Gemini CLI and Qwen Code

Gemini CLI and Qwen Code use their own IDE companion protocol, and Next Term speaks it. Start `gemini` or `qwen` in a Next Term tab and it connects by itself.

- **What they see:** up to 10 files you have open, most recent first, and in the active one the caret position and your selection.
- **Proposed edits** open as a diff to accept or reject, as with Claude. A new proposal for the same file replaces the old one.
- **Nothing to set up.** Both CLIs connect to an editor only when their IDE mode is on. Next Term turns it on for you by setting `"ide": {"enabled": true}` in `~/.gemini/settings.json` and `~/.qwen/settings.json`. It changes only that setting and leaves the rest of the file byte for byte. It writes nothing if the agent is not installed, and never rewrites a settings file that has comments in it.

## GitHub Copilot CLI

Copilot CLI connects to an editor through the protocol VS Code’s Copilot extension uses, and Next Term speaks it. Start `copilot` in a Next Term tab and it connects by itself.

- **What it sees:** the lines you select go with your next prompt, and Copilot shows which ones. With nothing selected, it knows which file you have open.
- **<kbd>⌥⌘K</kbd> puts an @-mention straight into Copilot’s prompt**, such as `@app/User.php:10-20`.
- **Proposed edits** open as a diff to accept or reject, as with Claude. Copilot asks in the terminal at the same time; answer in either place, and the other closes.
- **Where it connects:** Copilot connects by itself when it starts in a folder Next Term lists for it: an open project, or the folder a tab is in, except your home folder and `/`. It takes the first editor it finds with that folder, so where VS Code has the same folder open, a `copilot` in a Next Term tab may connect to VS Code, and one in VS Code’s own terminal may connect to Next Term. `/ide` in Copilot switches.
- **From another terminal:** a `copilot` started outside Next Term in one of those folders connects too, as does one that picks Next Term in `/ide`. It sees the selection of the Next Term window that has its folder open (the window’s project, a tab’s folder, or a folder inside one of them), and its proposed edits open in that window. If no window has its folder open, it is sent no selection, and its proposed edits open in the front window.
- **Nothing to set up**, and nothing of Copilot’s is changed: Next Term only adds its own lock file to `~/.copilot/ide`, and only when `~/.copilot` exists (Copilot makes it the first time it runs). Copilot still asks its own question about trusting a folder; Next Term never answers it for you.

## opencode

opencode reads Claude Code’s lock files and connects to Next Term the same way. Started in another terminal inside one of your open projects, it presents the token from the lock file. From a Next Term tab it connects without the token, so Next Term checks who is calling instead: the connection is kept only when it comes from opencode running in one of Next Term’s own tabs.

- **What it sees:** the lines you select, which go with your next prompt, and the @-mentions <kbd>⌥⌘K</kbd> sends.
- **No proposals:** opencode does not ask an editor to show its edits, and without the token it could not.
- **Not in tmux or a remote tab:** opencode inside tmux, even tmux started in a Next Term tab, or in a [remote tab](/docs/remote/), is not linked, because Next Term cannot tell it is in one of its tabs.

## Send to Agent (⌥⌘K)

Send to Agent hands your context to the agent in a tab, in that agent’s own syntax, and puts the cursor in its prompt so you can add the instruction.

**What you can send:**

- **Lines in the editor:** select them and press <kbd>⌥⌘K</kbd> (**Edit › Send to Agent**). With nothing selected, the whole file is sent.
- **Lines in a diff:** select them on the new side of a [side-by-side diff](/docs/diffs/#send-lines-to-your-agent) and press <kbd>⌥⌘K</kbd>. With nothing selected, the file is sent.
- **Files and folders in the sidebar:** select them and press <kbd>⌥⌘K</kbd>, or right-click and choose **Send to Agent** (“Send 3 Items to Agent” for several).

**Which agent receives it:** the agent in the front tab if one is running there; otherwise the agent tab you used most recently. An agent in a [remote tab](/docs/remote/) never gets it, because what it types are paths on your Mac. If no agent on your Mac is running in the window, Next Term says so, and says when the only one runs on a server.

**What it types:** a reference relative to the agent’s folder, in the agent’s own syntax.

| Agent | Lines 10–20 of a file | One line | A folder |
|---|---|---|---|
| Claude Code, opencode | `@app/User.php#L10-20` | `@app/User.php#L10` | `@app/` |
| Gemini CLI, Qwen Code | `@app/User.php (lines 10-20)` | `@app/User.php (line 10)` | `app/ (folder)` |
| Copilot CLI | `@app/User.php:10-20` | `@app/User.php:10` | `app/ (folder)` |
| Codex and every other agent | `app/User.php:10-20` | `app/User.php:10` | `app/ (folder)` |

Several items go on one line for agents that use @-mentions; for the others they become a short “Context:” list. A path with spaces is quoted; for Copilot CLI it is typed without the `@` and with the lines in words, because Copilot’s @-mentions end at a space. When Claude, opencode or Copilot CLI is connected through the IDE link, files go in as real @-mentions instead of typed text. A folder, or a reference with a note such as “(unsaved changes in the editor)” or “(as staged)”, is still typed: a mention carries only a file and its lines.

**Unsaved changes:** if the file has edits you have not saved, the reference says “(unsaved changes in the editor)” and the selected code is pasted after it as a fenced code block, so the agent sees what you see.

**It never presses Return.** You read what was typed, add your instruction, and send it yourself. The text arrives as a bracketed paste: code keeps its line breaks and tabs, every other control character is removed, and the text never starts with a character an agent treats as a command (`!`, `/`, `$`, `&`, `?` or `#`).

## Turning the link off

**Settings › Editor › Agents** has two switches, both on by default:

- **“Agents in a tab see the editor (Claude Code, Gemini CLI, Qwen Code, opencode)”**
- **“GitHub Copilot CLI in a tab sees the editor”**

Turn one off and Next Term stops those IDE servers: the agents no longer see your selection or open files, and their proposed edits are answered in the terminal only. Send to Agent keeps working, because it types into the prompt instead.

## How the link stays private

- **Local only.** The servers for Claude Code, opencode, Gemini CLI and Qwen Code listen on `127.0.0.1` and nowhere else. Copilot CLI’s has no network port at all: it is a Unix socket in a new folder that only you can open.
- **A fresh secret every launch.** Each run of Next Term creates new 256-bit secrets; an agent must present one, and the check runs in constant time. The lock files that tell Claude Code and Copilot CLI where to connect are readable only by you (`0600` in a `0700` folder) and are removed when Next Term quits.
- **Without the token, only opencode in your tabs.** A connection without the token is kept only when the process making it is opencode running in a Next Term tab. It then only receives your selection and @-mentions: it cannot propose edits or call anything.
- **Browsers are refused.** Requests that carry an `Origin` header, as requests from web pages do, are rejected. A website cannot reach the link, and would still need the token.
- **Agents cannot write through it.** Nothing an agent sends over the link writes a file. Next Term reports the selection and shows proposals; the agent writes only after you accept, with its own permissions.
- **Secrets are never shared.** Selections and open files from `.env` and `.env.*` (except `.env.example`), `*.pem`, `*.key`, `id_rsa`, `id_ed25519`, `.npmrc` and `.netrc` never leave the editor.

More in [Security and privacy](/docs/security-and-privacy/).

## Pick up any agent’s conversation

Next Term lists the conversations eight agents keep for a folder: Claude Code, Codex, Command Code, Gemini CLI, Qwen Code, opencode, Cursor Agent and Copilot CLI. You find them in three places:

- **The Welcome window**, for each of your projects: every session, newest first, to filter by agent.
- **<kbd>⌥⌘O</kbd>** in a project window: the same list as a panel, to filter by typing.
- **Agent Sessions** at the top of the project sidebar: the folder’s newest five, and **More…** for the rest.

Resume types the agent’s own command into a new tab, in the folder the session was started in. Fork continues a copy and leaves the original as it was; it is offered only for the agents that can fork from the command line.

| Agent | Resume | Fork | Continue latest |
|---|---|---|---|
| Claude Code | `claude --resume <id>` | `--fork-session` | `claude --continue` |
| Codex | `codex resume <id> -C <folder>` | `codex fork <id>` | `codex resume --last` |
| Command Code | `command-code --resume <id>` | `--fork-session` | `command-code --continue` |
| Gemini CLI | `gemini --resume <id>` | — | `gemini --resume latest` |
| Qwen Code | `qwen --resume <id>` | `--fork-session` | `qwen --continue` |
| opencode | `opencode --session <id>` | `--fork` | `opencode --continue` |
| Cursor Agent | `cursor-agent --resume=<id>` | — | `cursor-agent resume` |
| Copilot CLI | `copilot --resume=<id>` | — | `copilot --continue` |

**A session open in a tab says so.** It is marked “open in a tab” in the lists and “running” in the sidebar, and Resume becomes **Go to Tab**: it shows that tab rather than start the session a second time. Claude Code and Copilot CLI record which session each running copy has open (Claude Code’s record follows `/clear` and `/resume`), and Next Term goes by that. For the other agents, a tab is in the session it resumed by id, or, when the agent started there without one, the session that began after it did. When two tabs run the same agent in one folder, a session either of them could have begun is marked in neither, rather than in the wrong one. A Claude Code or Copilot CLI session that the agent has open in another terminal is marked “open in a running agent”; for Claude Code, Fork is the safe way to continue it.

**Continue Latest** is in the ⋯ menu of the sidebar’s Agent Sessions group, for each agent with a session in that folder. It runs the agent’s own command from the last column, which picks up its latest session in the folder.

See [The Welcome window and agent sessions](/docs/projects-and-git/#the-welcome-window-and-agent-sessions) for where Next Term reads them from.

## One agent can run the others

Next Term is also an MCP server. An orchestrator agent can list every project and tab with each agent’s state, start agents in new tabs, send them prompts, wait for them, read their screens and answer their questions. It is set up for you in the agents above. See [Orchestrate agents (MCP)](/docs/orchestration/).

## Agents on your servers

A remote tab (<kbd>⌥⌘T</kbd>) runs an agent on a server you reach with ssh, kept running in tmux or herdr while your Mac sleeps, with the same marks as a local one. Agents can open and check those tabs through MCP too. See [Remote tabs on your servers](/docs/remote/).

## Coming later

<span class="nt-soon">Coming later</span> Remote access to the MCP server for agents outside your Mac.
