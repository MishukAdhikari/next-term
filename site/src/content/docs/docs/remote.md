---
title: Remote tabs on your servers
description: "Run agents on your own VPS from a Next Term tab: sessions that keep running while your Mac sleeps, reconnecting, and the host keys and logins left to ssh."
---

A remote tab is a terminal tab on one of your servers. Start Claude Code or Codex there, close the lid, and with tmux or herdr on the server the agent keeps working there; open the Mac again and the tab is back where it was. Next Term connects with the ssh you already use, and installs nothing on the server.

## Open a remote tab

**Shell › New Remote Tab…** (<kbd>⌥⌘T</kbd>) asks where to connect:

- **Host:** a server you saved before, or **New Host…**.
- **Name:** what the tab and Next Term call it, such as `web-1`.
- **SSH destination:** `user@203.0.113.5`, or a `Host` alias from your `~/.ssh/config`. The port has a field of its own.
- **Folder on host:** where the tab starts, absolute or starting with `~`. A folder that is not there opens the tab in your home folder, and the tab says so.
- **Keep agents running:** **Off**, **tmux** or **herdr** (see below).
- **Session:** **New session**, or one still running on the server from a tab you closed, to reattach to it.

**Connect** saves the host and opens the tab. **Remove Host** forgets a saved host; sessions kept on the server keep running there.

### From the Welcome window

With no project open, the **Welcome** window lists the servers you saved under your projects, the one you connected to last first. Click one for a window with a tab on it, in its folder. **Connect to Server…** (or <kbd>⌥⌘T</kbd>) opens the sheet above over the Welcome window: **Connect** opens a window for the tab, **Cancel** leaves everything as it was.

The tab is named after the host and folder, such as “web-1: app”. While it connects, the title says so: **(connecting)**, **(log in)** when ssh is asking you for something in that tab, **(waiting)** when another tab is logging in to the same server, and **(disconnected)**.

## Which tabs are remote

A remote tab has a small server before its title. Tabs on your Mac have none, so the remote ones stand out. The dot on the server’s corner is the connection:

| Mark | Connection |
|---|---|
| Filled green dot | Connected |
| Amber ring | Connecting, logging in, or waiting for another tab’s login to the same server |
| Red dot with a bar, the server faded | Disconnected: <kbd>↩︎</kbd> connects again |
| No dot, the server faded | The shell on the server ended, and the tab says why; <kbd>⌘W</kbd> closes it |

The marks differ in shape as well as colour, so they read without colour too. The agent’s own mark (the spinner, the check, the “!”) keeps its place at the start of the tab, before the server.

- **Hover over a tab** for where it runs, such as “Remote: web-1 (deploy@203.0.113.5), connected”. VoiceOver says the same.
- **A tab too narrow for its whole title** drops “web-1: ” first, then the note, and shows “app”: the mark says the rest. Selecting the tab or pointing at it keeps the same words: its shortcut, such as <kbd>⌘2</kbd>, gives way to them.
- **A split tab** shows the weakest connection among its panes, and its tooltip names that pane’s server.
- **The » menu** of tabs that do not fit shows the same marks.
- **The project sidebar** stays on your Mac’s files while a remote tab is active (the tab’s folder is on the server). A line under its header says “Files on this Mac”, with the server and its name on the other side.
- **The window title** names the host, as in “claude — on web-1 — Next Term” (or “web-1: app — Next Term”, where the tab’s name already says it), for the Window menu, Mission Control and VoiceOver.

## Your ssh, as you have it set up

Next Term runs the system’s `/usr/bin/ssh`, so everything in your `~/.ssh/config` applies: `Host` aliases, keys, `ProxyJump`, `UseKeychain` and agents such as 1Password, Secretive or gpg-agent. ssh gets the `PATH` and `SSH_AUTH_SOCK` your login shell sets, so a remote tab connects the way `ssh web-1` does in a local tab.

If ssh needs a password, a passphrase or a one-time code, it asks in the tab, as it would in any terminal. A tab that is asking for one in the background is marked for attention, and sends a notification while you are in another app.

All the tabs on one server share one connection, so you log in once. Up to 7 tabs share a connection; an 8th tab on the same server opens a second one, and asks you to log in once more.

## Keep agents running

Each host says how its tabs are kept when your Mac disconnects, sleeps or is off:

| Choice | On the server | When the connection drops |
|---|---|---|
| **Off** | A plain shell | What runs in the tab stops. The tab stays; <kbd>↩︎</kbd> opens a new shell there. |
| **tmux** | Next Term’s own tmux server (`tmux -L nextterm`), separate from yours | The session keeps running. The tab reattaches by itself when the connection is back. |
| **herdr** | The [herdr](https://herdr.dev) you installed on the server | herdr keeps its agents running, and the tab shows their state: working, waiting for a decision (and which agent), or idle. |

Next Term never installs tmux or herdr. If the one you chose is not on the server, the tab says so and opens a plain shell instead.

### When the Mac sleeps or the network drops

ssh notices a dead connection within a minute. A kept tab (tmux or herdr) then says “Connection to web-1 lost. Reconnecting in 2 s” and tries again by itself, waiting a little longer each time, up to a minute, for about half an hour. When one tab on a server gets its connection back, the others that lost theirs come back at once. Press <kbd>↩︎</kbd> to try again right away. A kept tab that could not connect at all, say at launch before the Wi-Fi is up, tries a few times, then waits for <kbd>↩︎</kbd>.

A tab never retries by itself when ssh refused the login (a wrong password, a key the server does not accept, a host key that did not verify). It says why and waits for <kbd>↩︎</kbd>, so a login that cannot work is never repeated on its own.

### When Next Term quits, or the server restarts

At quit, the connections close and kept sessions go on running on the server. At the next launch, Next Term opens the tmux and herdr tabs again, in their order, and reattaches them. Split panes come back as separate tabs. A host you pointed somewhere else since (another address or port) is not followed: those tabs stay closed, and Next Term tells you.

If the server itself restarts, tmux sessions are gone. herdr brings its layout back when Next Term reconnects to it, and resumes the agents it supports from their saved conversations.

## Status and agents

Agents in a remote tab get the same marks as local ones: the spinner while they work, the check when they are done, the amber “!” with the question when they need a decision. Every two seconds Next Term asks each server what runs in front of each tab, over the connection the tabs already have. That check never logs in by itself and never asks for anything.

Links in a remote tab’s output open web pages only: a path there names a file on the server, not on your Mac.

## Closing a tab or ending the session

Closing a **tmux** tab only detaches from its session. If something runs in it, Next Term says what keeps running and where (“claude keeps running on web-1, in tmux session nt-app-1a2b3c”) and offers:

- **Close Tab:** the session keeps running. Reattach to it later from **New Remote Tab…**, under **Session**, or with **Shell › Reopen Closed Tab** (<kbd>⇧⌘T</kbd>) right away.
- **End Session:** stops the session and everything in it. The tab closes only once the session has ended.

Closing a window or a split tab names the sessions that keep running too. Closing an **Off** tab warns about what would stop, including jobs suspended or running in the background on the server.

## For agents (MCP)

Agents that use Next Term’s [MCP server](/docs/orchestration/) get seven tools for servers:

| Tool | What it does |
|---|---|
| `list_hosts` | The saved hosts and how each keeps agents running |
| `add_host`, `remove_host` | Save a host, or forget one. A saved host is never pointed at another address. |
| `check_host` | What a server has: OS, shell, tmux and herdr, git, the agents on its `PATH`, kept sessions |
| `new_remote_tab` | Open a tab on a server and run a command in it, such as `claude`, or reattach to a session |
| `host_sessions` | The sessions kept on a server, and herdr’s agents with their state |
| `host_changes` | What changed in a git work tree on a server: files, a diffstat and the diff |

`list_tabs` names each remote tab’s host and session, and whether it is still connecting. Every tool that saves a host or runs something on a server is marked so that your agent’s client asks you first. The checks run over a connection a tab already has; with no tab connected to a server, they say so instead of logging in. An agent never types into a tab while ssh is asking you for a password.

## Security

- **Host keys are never accepted silently.** A new host key is asked about in the tab, and a changed one is refused, whatever your ssh config says, for jump hosts too. Background checks never log in, so they never meet a host key at all.
- **Nothing is installed on a server.** tmux and herdr are used only if you installed them. Next Term keeps a few small files in `~/.cache/next-term` on the server: each tab’s shell process and Next Term’s tmux settings.
- **No passwords are stored.** Saved hosts hold a name, a destination, a port and a folder. ssh does every login.
- **Your ssh config is never written.** Next Term reads it the way ssh does, through its own small config file that adds the host-key rule and includes yours unchanged.
- **No port or socket is forwarded.** Next Term clears every port forward, even ones in your ssh config, and never forwards its own MCP socket or editor links, so nothing on the server can reach back to Next Term. Agent forwarding is as your ssh config sets it.
- **Commands are never pieced together from text.** What Next Term runs on a server is a fixed script, sent encoded, with every name and folder quoted, so a folder or session name cannot become a command.

## Limits

- Split panes come back as separate tabs after a relaunch.
- The **Session** list, and `host_sessions`, need a connection to the server: a tab connected to it, or up to 10 minutes after the last one closed. After that, open a tab on the server to see them.
- An 8th tab on one server asks you to log in once more (see above).
- A jump host written as `ProxyCommand ssh …` instead of `ProxyJump` follows your own ssh config for its host key. The server itself is still asked about.
- In a tmux tab, scroll with the mouse wheel; the history is tmux’s.
- Next Term is tested with tmux 3.2 and later.
