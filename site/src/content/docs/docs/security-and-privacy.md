---
title: Security and privacy
description: "What Next Term shares, and with whom: local-only agent links and MCP socket, no telemetry, background git fetch, the installer, databases, remote tabs."
---

A terminal sees everything you type, and an agent link exposes your editor to programs. Next Term is built so that both stay on your Mac and under your control. The source is public under the MIT licence, so every claim on this page can be checked.

## What leaves your Mac

- **No account, no telemetry, no analytics.** Next Term has no sign-in and sends no usage data.
- **Two kinds of request of its own, each with an off switch:**
  - the daily update check to GitHub (see [Updates](/docs/updates/#what-the-check-sends));
  - `git fetch` from your projects’ own remotes, on a schedule (see [Background fetch](#background-fetch) below).
- **Everything else only when you ask.** A fetch, update or push you choose in the branch popup talks to your git remote. A remote tab connects only to the server you opened it on, through your own ssh; a tmux or herdr tab reconnects to it by itself, and reopens at launch. **Open in TablePlus** hands a database to TablePlus, and **Open in Vercel** runs Vercel’s own command line in a new tab. Nothing else starts by itself.
- **No AI of its own.** Next Term runs the agents you install. What those agents send to their providers is between you and them.

## The agent links

Claude Code, Gemini CLI and Qwen Code connect to Next Term as their IDE. That link is built to be safe by default:

- **Local only:** the servers listen on `127.0.0.1`, never on the network.
- **A fresh token per launch:** a new 256-bit secret every time Next Term starts, compared in constant time. The lock file that tells Claude Code where to connect is readable only by you (`0600` in a `0700` folder) and is removed on quit. Lock files left by other editors are never touched.
- **Browsers refused:** any request with an `Origin` header, as web pages send, is rejected.
- **Read-only for agents:** nothing an agent sends writes a file. Proposed edits are shown to you; the agent writes after you accept.
- **Secrets stay out:** selections and open files from `.env`, `.env.*` (except `.env.example`), `*.env`, `.flaskenv`, `*.pem`, `*.key`, `id_rsa`, `id_ed25519`, `.npmrc` and `.netrc` are never shared.
- **Off switch:** **Settings › Editor › Agents** turns the link off entirely.

Next Term turns on Gemini CLI’s and Qwen Code’s IDE mode by changing exactly one setting in their settings files, and never rewrites a file with comments. See [Gemini CLI and Qwen Code](/docs/agents/#gemini-cli-and-qwen-code).

## The MCP server

Agents can drive Next Term through its MCP server ([Orchestrate agents](/docs/orchestration/)). It is built to the same standard:

- **No network port.** The app listens on a Unix socket, `~/Library/Application Support/Next Term/mcp.sock`, with mode `0600`, and checks that every connection comes from your own user. That is the reach your own shell already has.
- **Honest tool descriptions:** typing into a tab, pressing keys, answering an agent’s question, opening and closing tabs are marked destructive, so agents ask before they use them.
- **Questions are answered once:** an answer names the question it is for, and is refused if the agent has moved on to another one.
- **Project files stay inside, and secrets stay out:** the file, search and git tools (`read_file`, `find_in_files`, `git_status`, `get_diff`) read only inside the projects open in Next Term, with symlinks resolved first. `.env` files, keys and certificates, ssh keys, credentials files and `.git` are refused, and secret-looking values in what they return are masked as `•••`. Nothing is written.
- **The editor’s selection too:** in a `.env`, key or credentials file, `get_editor_selection` says the text is withheld instead of returning it.
- **Servers only over your own logins:** `check_host`, `host_sessions` and `host_changes` run over a connection a remote tab already has, and never log in by themselves. `new_remote_tab` opens a tab where your own ssh logs in, and any password or host-key prompt appears there for you. The ones that save a host or run something on a server are marked so that your agent’s client asks you first.
- **No self-control:** an agent cannot type into, or close, the tab it runs in.
- **Busy tabs are protected:** closing a tab that runs something needs an explicit `force`.
- **Your files are respected:** registering in an agent writes only Next Term’s own `next-term` entry, keeps comments and every other server, and never touches an entry it did not write.
- **Off switch:** **Settings › Editor › Agents: “Let agents control Next Term”** closes the socket and removes the entries.

## Tabs start fresh

A new tab is a fresh terminal, not a child of whatever launched Next Term. Variables that agents and editors set for their own child processes are removed: Claude Code’s session markers (so `claude` never thinks it is a sub-agent), other programs’ messaging secrets, IDE links and terminal variables left by another editor, and a git password helper that belonged to an editor. Settings you set on purpose, such as `ANTHROPIC_API_KEY`, `CLAUDE_CONFIG_DIR` or `CODEX_HOME`, stay.

## Screen sharing

**Settings › Editor › Hide values in .env files** draws the values in `.env`, `.env.*`, `*.env` and `.flaskenv` files as dots, so a screen share or a recording does not show them; **View › Hide .env Values** does it for one file. Keys and comments stay visible, the line you are typing in shows its value, and the file itself never changes. The terminal, diffs and Find in Files results still show values as they are. See [Hiding .env values](/docs/editor/#hiding-env-values).

## The terminal

- **Clipboard:** programs can copy to the clipboard (OSC 52) only from the tab you are looking at, and can never read it. A remote host over ssh cannot harvest what you copied.
- **Paste:** <kbd>⌘V</kbd> strips control characters, so text on the clipboard cannot end a bracketed paste early and run the rest as typed input.
- **Screen contents** cannot be read back through terminal queries: DECRQCRA answers are blanked, so a remote program cannot read your screen cell by cell.
- **Status marks** from the shell carry a random per-tab secret that programs never see. Output — a `cat` of a log, a remote host — cannot fake “command finished” and skip the close confirmation.
- **Dropped and inserted paths** are quoted so that no file name can run a command, even one containing control characters, and arrive as a bracketed paste.
- **Send to Agent** removes control and invisible characters from what it types, and never starts with a character an agent treats as a command.

## Opening files and links

Opening a file from the sidebar, or with <kbd>⌘</kbd>-click in the terminal, asks first when the file is an app, a script or an executable — including behind a symlink or a Finder alias — with **Reveal in Finder**, **Open** or **Cancel**. Cloned repositories carry no quarantine flag, so macOS Gatekeeper would not ask; Next Term does.

<kbd>⌘</kbd>-click opens web (`http`, `https`) and mail links and local files. Every other link scheme is refused.

## Files and git

- **Saves are atomic** and keep the file’s permissions, encoding and line endings.
- **Named pipes are never read**, so a pipe in a project cannot freeze the app.
- **The sidebar’s git calls are read-only** and use `--no-optional-locks`, so the sidebar never holds the index lock while your own git commands or your agents’ run.
- **Every change you make through Next Term’s git tools is checked first:** a hunk is staged, unstaged or reverted only if the file still matches the diff you saw. See [Side-by-side diffs](/docs/diffs/#safe-while-agents-keep-working).
- **Replace in Files** re-reads each file and skips anything that changed since the search.
- **The Git Log and blame only read,** with `--no-optional-locks` as well. In a partial clone, the Git Log lists a commit’s files without downloading them.
- **The branch popup asks before it acts behind an agent:** anything that would change files in a folder where an agent is working asks first, and uncommitted changes go into a named stash rather than being overwritten.
- **Nothing in a notebook runs.** Next Term has no kernel; it shows the outputs saved in the file. The head view for large data files never writes to them.
- **Import only reads,** on this Mac. It never writes to the other app, and never opens a file that can hold credentials.

## Databases

The **Databases** group in the project sidebar ([Projects and git](/docs/projects-and-git/#databases)) is built so that a connection string never leaks:

- **Found offline.** Next Term reads the project’s text files and SQLite headers. It never runs the project’s code or `vercel env pull`, and nothing connects until you choose a hand-off.
- **Passwords never leave their file.** They are masked in tooltips, menus and accessibility labels, and never shown, logged, copied, put in a command line or handed to an agent. **Open mysql in New Tab** and **Open psql in New Tab** pass the password in a temporary file only you can read, deleted once the client starts.
- **Remote is treated as production.** Local or remote comes from the host, never the file’s name, and **Open in TablePlus** asks first for a remote host, naming it. mysql and psql tabs are offered for local and development databases only.
- **SQLite files are opened read-only** and only read: no `-wal` or `-shm` file appears beside them. **Send to Agent** types only the file, the table and the rows you selected.
- **Nothing is written** to an env file or a database, and nothing listens on a port.

## Remote tabs

A [remote tab](/docs/remote/) runs the system’s `ssh` with your own configuration, and adds rules of its own (more in [Security](/docs/remote/#security)):

- **Host keys are never accepted silently.** A new key is asked about in the tab, and a changed one is refused, whatever your ssh config says, for jump hosts too.
- **No password is stored,** and your `~/.ssh/config` is never written. ssh does every login.
- **Nothing on a server can reach back to Next Term.** Every port forward is cleared, and the MCP socket and editor links are never forwarded. Agent forwarding is as your ssh config sets it.
- **Nothing is installed.** tmux and herdr are used only if you installed them; a few small files go in `~/.cache/next-term` on the server.
- **Commands are never pieced together from text:** what runs on a server is a fixed script, with every name and folder quoted.

## Background fetch

Next Term talks to your git remotes on a schedule, so the sidebar can say **Pull 3** when someone pushes. This is exactly what it does:

- **When:** every 10 minutes for each repository open in a window, only while Next Term is the active app, and when you open the branch popup if the last fetch is over 5 minutes old.
- **What:** `git fetch --no-write-fetch-head --no-auto-maintenance --no-recurse-submodules <remote>` (with `--porcelain` too on git 2.41 or later), for each remote one of your local branches tracks, and no other. It talks only to the hosts your repository already names, with your own git configuration, credential helper and ssh agent, as `git fetch` in a terminal does. Submodules are not fetched (their remotes are other servers). Nothing is pushed and no other server is contacted.
- **What it changes:** the remote-tracking branches (`origin/main`) and the tags that come with them. Never your branches, your files, the index or `FETCH_HEAD`, and it starts no `git maintenance` or `gc`.
- **No prompts:** it can’t ask for a password, a passphrase or a host key (git’s prompts, its askpass helpers and the Git Credential Manager’s window are all turned off for it). The first time a remote needs one, background fetch stops fetching that remote until a fetch you start succeeds (or until Next Term restarts).
- **It holds back** in Low Power Mode, on expensive or Low Data networks, and offline.
- **You can see it:** **Git › Git Commands** lists the background fetches, exactly as they would be typed, when **Show background fetches** is on.
- **Off switch:** **Settings › Editor › Git › Fetch in the background: Off**. **Only when opening the branch popup** keeps the popup’s fetch and drops the timer.

## Updates

Downloads come only over HTTPS from GitHub, are checked against the release’s published SHA-256, and must be Next Term at the expected version with an intact code signature before they replace anything. See [Updates](/docs/updates/).

## The installer

The one-line installer (`curl -fsSL https://next-term.mishuk.me/install.sh | bash`) downloads the disk image and its checksum from GitHub over HTTPS, and installs only when:

- **the checksum is signed with the Next Term release key.** The key’s private half never leaves the maintainer’s Mac, so a release changed on GitHub is refused;
- **the download matches that checksum;**
- **the disk image holds Next Term at that version,** with an intact code signature, checked again after the copy;
- **“latest” is not older than this site’s version,** so an older signed release cannot be passed off as the newest.

It never uses `sudo` and never replaces a Next Term that is running. Besides the app, it adds at most the `nxtrm` command: a link in a folder already on your `PATH` that you can write (see [The nxtrm command](/docs/command-line/#installing-it)). It never changes your `PATH`, and never replaces anyone else’s `nxtrm`. [Read the script](https://github.com/MishukAdhikari/next-term/blob/main/site/src/install.sh) before you run it, if you like.

## The first launch warning

Next Term is not notarized by Apple, which is why macOS asks you to allow the first launch of a disk image downloaded in a browser. The source is public, and releases are built from it by GitHub Actions. Each release ships a `.sha256` file so you can check the download yourself first; see [Check the download](/docs/getting-started/#check-the-download-optional). With the one-line installer, which checks the signed checksum for you, macOS does not ask.

## Report a problem

Found a security issue? Please report it through the repository’s [Security page on GitHub](https://github.com/MishukAdhikari/next-term/security) rather than in a public issue, so it can be fixed before it is widely known.
