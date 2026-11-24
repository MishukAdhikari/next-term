# Next Term from Raycast, Alfred and Shortcuts

Next Term can be reached three ways from outside the app. None of them needs Next Term in front.

## Links

A `nextterm://` link does one thing and needs no typing in Next Term:

| Link | What it does |
| --- | --- |
| `nextterm://open?path=~/Code/app` | Opens that folder as a project. |
| `nextterm://tab?id=<tab id>` | Brings that tab forward, with the keyboard. |
| `nextterm://attention` | Brings forward the tab whose agent waits for you. It beeps when none does. |
| `nextterm://goto` | Opens Go to Anything over the window in front. |
| `nextterm://agent?path=~/Code/app&agent=claude` | Starts an agent in a new tab there, after you say yes. The agent can be `claude`, `codex`, `opencode`, `gemini` or `cmd`. |

A web page can open a link too. So a link never runs a command it spells out, and starting an agent always asks first.

These are good hotkeys:

- **Raycast:** a Quicklink, such as `nextterm://attention` on ⌥⌘A.
- **Alfred:** a Web Search or Open URL action.
- **Shortcuts app:** the Open URLs action.
- **Stream Deck:** a Website action.

## Spotlight and Shortcuts actions

Next Term gives macOS four actions. Find them in Spotlight, or in the Shortcuts app under Next Term:

- **Go to Waiting Agent:** brings forward the tab whose agent waits for you.
- **Go to Anything:** opens Go to Anything over the window in front.
- **Open Project:** opens a folder as a project.
- **Start Agent:** starts Claude Code, Codex, OpenCode, Gemini CLI or Command Code in a folder, after you say yes in Next Term.

Each one opens the link above that does the same thing, so it can do no more than the link. Siri and Spotlight also know "Go to the waiting agent in Next Term" and "Go to anything in Next Term" with no setup. The actions come with releases, which are built with Xcode; a copy built with only the Command Line Tools has none.

## nxtrm call

`nxtrm call TOOL '{json}'` runs one of Next Term's tools and prints its answer, as JSON for most:

```sh
nxtrm call list_tabs
nxtrm call list_projects
nxtrm call new_tab '{"directory": "~/Code/app", "command": "claude"}'
nxtrm call show_tab '{"tab_id": "…"}'
```

`nxtrm call` alone lists the tools.

- It exits 1 when the tool refuses, and 2 when the arguments aren't one JSON object.
- A tool that asks you on the Mac asks here too.
- Use it from a Raycast Script Command, an Alfred Run Script, or the Shortcuts app's Run Shell Script.

## The Raycast extension

`integrations/raycast` is a Raycast extension built on the links and `nxtrm call`:

- **Search Tabs:** every tab, with its project and state. Return brings it forward.
- **Search Projects:** open and recent projects. Return opens one, and ⇧⌘A starts an agent there. Type a name after it (`Search Projects api`) to start filtered, or turn it on as a fallback command in Raycast's settings: typing a project's name in Raycast, when nothing else matches, then offers to search your projects for it.
- **Start Agent:** pick a project and an agent, with an optional first prompt.
- **Agents Waiting:** a menu-bar count of the agents waiting for you. Click one to go to it.
- **Go to Waiting Agent** and **Go to Anything:** give either one a hotkey in Raycast.

To try it before it is in the Store:

```sh
cd integrations/raycast
npm install
npm run dev
```

## Raycast AI, through Next Term's MCP server

Raycast Pro can use MCP servers, and Next Term's server is the one its own agents use:

1. In Raycast, run **Install Server** (MCP).
2. Set the name to `nextterm`.
3. Set the command to `/Applications/Next Term.app/Contents/Resources/bin/nxtrm`.
4. Set the arguments to `mcp`.

Then ask Raycast AI things like "@nextterm which agent is waiting for me?" or "@nextterm start codex in ~/Code/app".

What changes anything asks you on the Mac first, as it does for every agent.
