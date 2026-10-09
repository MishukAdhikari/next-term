---
title: Security and privacy
description: "What Next Term shares, and with whom: local agent links and MCP socket, no telemetry, git fetch, how files are written, databases, remote tabs."
---

A terminal sees everything you type, and an agent link exposes your editor to programs. Next Term is built so that both stay on your Mac and under your control. The source is public under the MIT licence, so every claim on this page can be checked.

## What leaves your Mac

- **No account, no telemetry, no analytics.** Next Term has no sign-in and sends no usage data.
- **Two kinds of request of its own, each with an off switch:**
  - the daily update check to GitHub (see [Updates](/docs/updates/#what-the-check-sends));
  - `git fetch` from your projects’ own remotes, on a schedule (see [Background fetch](#background-fetch) below).
- **Everything else only when you ask.** A fetch, update or push you choose in the branch popup talks to your git remote. A remote tab connects only to the server you opened it on, through your own ssh; a tmux or herdr tab reconnects to it by itself, and reopens once the first window opens after a launch, in its project’s window if that is open, else in the first window. **Open in TablePlus** hands a database to TablePlus, and **Open in Vercel** runs Vercel’s own command line in a new tab. Nothing else starts by itself.
- **The Skills library asks GitHub only when you do:** when you review a skill, install or update one, or click Check for Updates in Settings › Skills. Opening Window › Skills also checks your installed skills for updates, at most once an hour, unless you turn that off in Settings › Skills. Each request names a public repository and a commit; nothing about you or your other skills is sent. See [Skills from GitHub](#skills-from-github).
- **No AI of its own.** Next Term runs the agents you install. What those agents send to their providers is between you and them.
- **Suggest a command is off until you turn it on,** and then sends only when you press <kbd>⌃⌘K</kbd> and submit a sentence. It goes to the agent you chose (Claude Code) or to Apple’s on-device model, which keeps it on this Mac. With your sentence go the folder, the shell’s name and the last command, secrets masked; recent output only when you include it, each time, after seeing it as it would be sent. The agent runs with no tools and no MCP, in an empty folder, without Next Term’s variables, and is stopped after 60 seconds. What comes back is put on the line and never run. See [Suggest a command](/docs/tab-completion/#suggest-a-command).

## The agent links

Claude Code, opencode, Gemini CLI, Qwen Code and GitHub Copilot CLI connect to Next Term as their IDE. What each link shares, and with whom:

| Link | Who can connect | What it is sent | What it can ask for |
|---|---|---|---|
| Claude Code | A program with the token from Next Term’s lock file in `~/.claude/ide` | The selected lines, or which file is open; <kbd>⌥⌘K</kbd>’s @-mentions | To show a proposed edit |
| opencode | From a Next Term tab: opencode itself, with no token. Elsewhere: with the token, as Claude Code | The selected lines; <kbd>⌥⌘K</kbd>’s @-mentions | Nothing from a tab |
| Gemini CLI, Qwen Code | A program with the token from the tab’s environment or Next Term’s discovery file | Up to 10 open files, the caret and the selection | To show a proposed edit |
| Copilot CLI | A program with the nonce from Next Term’s lock file in `~/.copilot/ide`. A `copilot` started in another terminal in a folder Next Term has open connects by itself | The selected lines, or which file is open, in the window of its tab (started elsewhere: the window that has its folder open, or nothing); <kbd>⌥⌘K</kbd>’s @-mentions | To show a proposed edit; the last selection it was sent |

The lock and discovery files are readable only by you, so the secrets keep out other users of this Mac and web pages. They do not keep out programs you run yourself, which can read your files anyway.

- **Local only:** the servers for Claude Code, opencode, Gemini CLI and Qwen Code listen on `127.0.0.1`, never on the network. Copilot CLI’s has no network port: it is a Unix socket in a folder that only you can open, new at every launch.
- **A fresh secret per launch:** new 256-bit secrets every time Next Term starts, compared in constant time. The lock files that tell Claude Code and Copilot CLI where to connect are readable only by you (`0600` in a `0700` folder) and are removed on quit. Lock files left by other editors are never touched.
- **opencode, checked instead of trusted:** opencode connects from a Next Term tab without the token. Next Term finds the process behind the connection by its ports and keeps the connection only if that process is opencode running in one of its own tabs. Any other connection without the token is closed before a message is read.
- **Browsers refused:** any request with an `Origin` header, as web pages send, is rejected.
- **Read-only for agents:** nothing an agent sends writes a file. Proposed edits are shown to you; the agent writes after you accept.
- **Secrets stay out:** selections and open files from `.env`, `.env.*` (except `.env.example`), `*.env`, `.flaskenv`, `*.pem`, `*.key`, `id_rsa`, `id_ed25519`, `.npmrc` and `.netrc` are never shared.
- **Copilot’s own trust question stays:** Next Term’s lock file does not call any folder trusted, so Copilot CLI still asks before it works in a folder for the first time.
- **Off switches:** **Settings › Editor › Agents** has one for Claude Code, opencode, Gemini CLI and Qwen Code, and one for Copilot CLI.

Next Term turns on Gemini CLI’s and Qwen Code’s IDE mode by changing exactly one setting in their settings files, and never rewrites a file with comments. It changes nothing of Copilot CLI’s: it only adds its own lock file. See [Agents and the IDE link](/docs/agents/#gemini-cli-and-qwen-code).

## The MCP server

Agents can drive Next Term through its MCP server ([Orchestrate agents](/docs/orchestration/)). It is built to the same standard:

- **No network port.** The app listens on a Unix socket, `~/Library/Application Support/Next Term/mcp.sock`, with mode `0600`, and checks that every connection comes from your own user. That is the reach your own shell already has.
- **Honest tool descriptions:** typing into a tab, pressing keys, answering an agent’s question, opening and closing tabs are marked destructive, so agents ask before they use them. Every tool is also tagged `read` or `write`.
- **Changes wait for you:** `write_file`, `create_file`, `stage`, `commit`, the pane and layout tools and `settings_set` change nothing until you click **Approve** in a window on your Mac that shows what would change and who asks. Decline, closing it or no answer in about 50 seconds changes nothing. The window never takes the keyboard and has no Return button. `propose_edit` only shows a diff for you to accept or reject; it never writes. See [Approving changes](/docs/orchestration/#approving-changes).
- **Questions are answered once:** an answer names the question it is for, and is refused if the agent has moved on to another one.
- **Project files stay inside, and secrets stay out:** the file, search and git tools (`read_file`, `find_in_files`, `git_status`, `get_diff`) read only inside the projects open in Next Term, with symlinks resolved first. `.env` files, keys and certificates, ssh keys, credentials files and `.git` are refused, and secret-looking values in what they return are masked as `•••`.
- **Writes follow the same rules:** `write_file`, `create_file` and `propose_edit` work only inside the open projects, never on files that hold secrets, binary files or files over 5 MB, and never on git hooks (the hooks folder, `.husky`, pre-commit’s and lefthook’s settings), which `commit` would run. `write_file` never writes under unsaved edits in the editor, nor a file that changed while you were asked; it writes atomically and keeps the file’s permissions, encoding and line endings. `create_file` never writes over a file.
- **A change can be code that runs:** a file an agent writes may be one that runs later, such as a script, a test or an agent’s settings file with hooks, and `commit` runs the repository’s hooks, which often run the project’s own scripts and tests. Approve such a change as you would a command typed in your shell.
- **Commits take only what was named:** `commit` refuses when other changes are staged, unless the agent says to include them and the approval window lists them; it never pushes or amends. It runs as the branch popup’s commands do, with the repository’s hooks, and is listed in **Git › Git Commands**.
- **Settings agents can’t touch:** `settings_set` changes only the font size, line height, soft wrap, terminal position and the notification switches. Never “Let agents control Next Term”, the IDE links, updates or keyboard shortcuts, so no agent can turn off its own guards.
- **The editor’s selection too:** in a `.env`, key or credentials file, `get_editor_selection` says the text is withheld instead of returning it.
- **Servers only over your own logins:** `check_host`, `host_sessions` and `host_changes` run over a connection a remote tab already has, and never log in by themselves. `new_remote_tab` opens a tab where your own ssh logs in, and any password or host-key prompt appears there for you. The ones that save a host or run something on a server are marked so that your agent’s client asks you first.
- **No self-control:** an agent cannot type into, or close, the tab or pane it runs in.
- **Busy tabs are protected:** closing a tab that runs something needs an explicit `force`.
- **Your files are respected:** registering in an agent writes only Next Term’s own `next-term` entry, keeps comments and every other server, and never touches an entry it did not write. The edit is written as [every file Next Term writes](#how-files-are-written): to a temporary file only you can read, then put in place in one step with the file’s own permissions, so a private file such as Codex’s `config.toml` is never readable by others along the way. Just before putting its edit in place, Next Term checks that the agent has not saved the file since Next Term read it, and if it has, leaves the agent’s version. The agents offer no lock, so a save made at that very moment can still be lost.
- **Off switch:** **Settings › Editor › Agents: “Let agents control Next Term”** closes the socket and removes the entries (the Claude desktop app’s once Claude is closed).

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

- **Saves are atomic and private,** and keep the file’s permissions, encoding and line endings (see [How files are written](#how-files-are-written)).
- **Named pipes are never read**, so a pipe in a project cannot freeze the app.
- **The sidebar’s git calls are read-only** and use `--no-optional-locks`, so the sidebar never holds the index lock while your own git commands or your agents’ run.
- **Every change you make through Next Term’s git tools is checked first:** a hunk is staged, unstaged or reverted only if the file still matches the diff you saw. See [Diffs and Git Diff](/docs/diffs/#safe-while-agents-keep-working).
- **Replace in Files** re-reads each file and skips anything that changed since the search.
- **The Git Log and blame only read,** with `--no-optional-locks` as well. In a partial clone, the Git Log lists a commit’s files without downloading them.
- **Write with Agent sends the changes, not their secrets:** the commit sheet’s agent runs in an empty folder of its own, without the repository’s settings or hooks, and only when you press the button. `.env` files, keys and certificates, ssh keys and credentials files are named but not sent, and secret-looking values in the rest are masked as `•••`, as the MCP tools do. See [Branches](/docs/projects-and-git/#branches).
- **The branch popup asks before it acts behind an agent:** anything that would change files in a folder where an agent is working asks first, and uncommitted changes go into a named stash rather than being overwritten.
- **Nothing in a notebook runs.** Next Term has no kernel; it shows the outputs saved in the file. The head view for large data files never writes to them.
- **Import only reads,** on this Mac. It never writes to the other app, and never opens a file that can hold credentials.

## How files are written

Every file Next Term writes for you is written the same way: an editor save, <kbd>⌘Z</kbd> after reverting a change in a diff (git itself does the revert), Replace in Files and its undo, Gemini CLI’s and Qwen Code’s IDE setting, Next Term’s entry in your agents’ MCP settings, and the Skills library’s lock file. Each write:

- **Goes to a temporary file first,** beside the file. Next Term makes it new, readable only by you, so nothing already there (a file, or a link someone left) is used, and another account on your Mac never sees the new text of a file it could not read. Once the text is in, it gets the file’s permissions, is flushed to disk and replaces the file in one step. A program reading the file sees the old text or the new, never part of either.
- **Keeps the file’s permissions,** so a script stays executable and a `.env` only you can read stays that way, and its group and extended attributes, such as Finder tags. A new file is readable only by you, except a file the editor saves again after it was deleted on disk and a new Skills lock file, which are made as you make files: readable by others under the usual umask (022), only by you under 077. No new file is ever more open than your umask.
- **Writes through links:** the file a symlink points at is replaced, and the link stays a link. A link to a file that is not there is left alone.
- **Leaves a read-only file alone.** The folder would let Next Term replace it, but the file says not to change it; the save says it is read-only. A file locked in the Finder (**Locked** in its Get Info window) is left alone too, and the save says it is locked.
- **Keeps a save made meanwhile:** Replace in Files and its undo, the agents’ settings and the Skills lock file read the file again just before the new one goes in, and if another program saved it since they read or wrote it, its version stays. An editor save first checks that the file is still the one the editor last read or saved; if another program saved it since, nothing is written, and the editor asks which version to keep (see [Files your agents change](/docs/editor/#files-your-agents-change)).
- **Leaves nothing behind.** When anything fails (a full disk, a folder you can’t write in), the temporary file is removed and the file is as it was.

What this does not do: it is not a lock. macOS has none that other programs respect, so a save made at the very moment the file is replaced can still be lost. And the file written is a new file under the old name: a program that has the file open keeps reading the old text, a hard link to it keeps the old text, and a file that belongs to another account (one you can write through its group) becomes yours.

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
- **Nothing is installed, except the Tab hook you allow.** tmux and herdr are used only if you installed them; a few small files go in `~/.cache/next-term` on the server. Tab completion lists a server’s folders and files with a script that writes nothing. Its hook for zsh goes in `~/.cache/next-term/completion` only after you allow it for that server; it sends only Tab completion’s marks, under a secret that never appears on a command line, and **Remove** deletes it. See [Tab completion on your servers](/docs/tab-completion/#on-your-servers).
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

The app’s own updater checks a release as [the installer](#the-installer) does. Downloads come only over HTTPS from GitHub. The release’s SHA-256 checksum must be signed with the Next Term release key and name that version’s disk image, and the download must match it. The app inside must be Next Term at the expected version, with an intact code signature, before it replaces anything. A release changed on GitHub is refused. See [Updates](/docs/updates/).

## The installer

The one-line installer (`curl -fsSL https://nxtrm.mishuk.me/install.sh | bash`) downloads the disk image and its checksum from GitHub over HTTPS, and installs only when:

- **the checksum is signed with the Next Term release key.** The key’s private half never leaves the maintainer’s Mac, so a release changed on GitHub is refused;
- **the download matches that checksum;**
- **the disk image holds Next Term at that version,** with an intact code signature, checked again after the copy;
- **“latest” is not older than this site’s version,** so an older signed release cannot be passed off as the newest.

It never uses `sudo` and never replaces a Next Term that is running. Besides the app, it adds at most the `nxtrm` command: a link in a folder already on your `PATH` that you can write (see [The nxtrm command](/docs/command-line/#installing-it)). It never changes your `PATH`, and never replaces anyone else’s `nxtrm`. [Read the script](https://github.com/MishukAdhikari/next-term/blob/main/site/src/install.sh) before you run it, if you like.

## Skills from GitHub

Window › Skills installs agent skills from public GitHub repositories. A skill is instructions and sometimes scripts that your agents follow, so nothing is written until you have seen it:

- **One commit, checked.** Next Term fetches one commit and compares every skill folder with the git tree hash GitHub lists for it. Files that differ are refused.
- **A review before anything is written.** You see every file as written, with hidden characters spelled out and HTML comments shown, plus what the skill may do (pre-approved tools, hooks, shell lines, the MCP servers it names, and what a plugin starts by itself) and anything that looks risky. Install has no Return key, so a keystroke meant for a terminal never installs anything.
- **Plugins and extensions are named.** A skill folder can also be a plugin or extension for Claude Code, Codex, Cursor, Copilot, Gemini CLI, Qwen Code, Junie or Kiro, or an Agent Plugins package. The review says so. For a Claude Code plugin, it says what Claude Code would start by itself, without asking you, once the folder is linked into `~/.claude/skills`: MCP servers, hooks, monitors and language servers. It also counts the programs in the plugin’s `bin/` folder, which Claude Code’s shell can run by name, and flags one named like a common command such as `git`: it runs wherever that command is not installed. A file Next Term can’t read counts as one that runs. For other agents, the review lists the MCP servers and hooks a manifest declares, and says it did not check them. (In a test in October 2026, Codex did not start the servers a skill folder’s Codex plugin declares.) Next Term only reads these files: it never runs them, or an agent, to find out.
- **A Claude Code plugin that brings more than its skill is left out of Claude Code.** By default, such a skill folder is installed without its link in `~/.claude/skills`, so Claude Code does not load it. Codex and the other agents that read `~/.agents/skills` still find its skill.
  - **The choice.** In place of the checkbox for Claude Code’s link, the review offers “Leave it out of Claude Code” or “Add it to Claude Code as a plugin”. Before you click Install, the line beside that choice says what each plugin would start every time Claude Code opens. The review lists those parts, each with what it is: MCP servers, hooks, monitors, language servers and the programs in `bin/`, then the commands, agents and skills it also brings.
  - **What is linked as before.** A plugin that brings nothing beyond its own skill (only the manifest keys Next Term allows, and no other parts) is linked as before, unless its name meets a plugin you have.
  - **Updates.** An update keeps an existing link while the plugin declares the same parts as the copy you have, byte for byte, its MCP bundles and the programs in `bin/` included. When they change, the review picks “Remove it from Claude Code”, so the new parts start only if you add the plugin again. Undo puts the link back.
  - **Settings › Skills.** Link for Claude Code asks the same question before it links such a folder, with what it would start (or what else it brings), “Add with Its Programs” or “Add as Plugin”, and Cancel. Unify offers the same choice when the copy it keeps is such a plugin, and says Claude Code loses the skill if you leave it out. If the folder or your Claude Code plugins change before the link is made, nothing is linked.
  - **Plugins you already have.** The review names a plugin you have under the same name, or one that looks like it. One synced from claude.ai would be replaced by the folder in Claude Code sessions. One installed from a marketplace for you is the one Claude Code keeps, so the folder’s parts don’t start. One installed for a project is kept in that project only, and elsewhere Claude Code loads the folder as a plugin. Another skill folder with the same plugin name is named too.
  - **A linked `~/.claude/skills`.** If your `~/.claude/skills` is a link to `~/.agents/skills`, Claude Code reads every shared skill there itself, so Next Term can’t leave a plugin out. The review says so, with what the plugin starts.
  - **Settings.** Next Term changes no agent’s settings for a skill, `~/.claude/settings.json` included. Of Claude Code’s settings files it reads only that one, so a project’s or your organization’s Claude Code settings can turn a plugin on or off without the review knowing. To keep a plugin off, turn it off in Claude Code’s `/plugin`: Claude Code then loads nothing from the folder, not even its skill, and Settings › Skills shows Claude Code as “off”.
  - **`npx skills update`** links a skill for Claude Code again, so a plugin left out here can come back that way.
- **MCP servers a skill brings.** The review’s “Needs MCP servers” row names the MCP servers a skill brings for Claude Code, Codex and Amp, and when each of them adds or starts them, as of October 2026. Claude Code starts its plugin’s servers every time it opens, once you add the plugin, unless a plugin of the same name installed for you takes its place. Codex offers to add the servers in a skill’s `agents/openai.yaml` to `~/.codex/config.toml` when you name the skill (`$name`) in Codex itself (its CLI, IDE extension or app), and adds them without asking if you let Codex work without asking and with full access. The review shows the table Codex would add, or says the server is in your Codex config already, or that Codex would keep your own server of that name. Amp connects to the MCP servers in a skill’s front matter, or in an `mcp.json` beside its `SKILL.md`, as soon as it finds the skill, and starts any program among them; the review warns about each server that runs a program. A server entry Next Term can’t read is flagged, and so is YAML in the front matter that could hold keys the review doesn’t show. Next Term adds, starts, registers and removes none of these servers.
- **Commands and files that add MCP servers are flagged.** The review warns about a command that adds an MCP server to an agent, such as `codex mcp add` or `claude mcp add`, or installs a plugin or extension. It warns about MCP server settings (`mcpServers`, or `[mcp_servers]` for Codex) in a file the review doesn’t already list as declaring servers, since an agent may copy them into its own settings. A server that runs a package through `npx`, `bunx`, `pnpm dlx`, `yarn dlx` or `uvx` without an exact version is flagged, in a JSON file or in JSON quoted in the text: `@latest`, `@next` and ranges such as `@^1` count as no version, because the agent fetches whatever version is current each time it starts the server. An MCP bundle (`.mcpb` or `.dxt`) in the folder is flagged as a packed server whose contents the review can’t show, and a link to one as a server fetched from outside the commit.
- **Never updated on its own.** An update is a new commit, reviewed like an install, with the changes shown.
- **One shared copy, with Undo.** A skill goes to `~/.agents/skills`, linked for Claude Code if you want. Copies it replaces go to the Trash, and Undo puts them back. Undo refuses, changing nothing, if anything changed since.
- **Every agent that loads it is named.** The review lists the agents that load a skill from `~/.agents/skills` if you use them, as of October 2026. Codex, Command Code, Gemini CLI, Qwen Code, Cursor, opencode, Copilot CLI, Amp, Junie and goose read that folder themselves, and Claude Code reads the skill through its link in `~/.claude/skills`. Amp, Cursor, opencode and goose read `~/.claude/skills` too, so they also find the skill through that link. Leaving a skill out of Claude Code doesn’t keep it from the others.
- **Removing a skill names what may stay.** Remove takes the skill’s shared copy and the links to it. It also names what may outlive the skill in other apps, and changes none of it. Codex offers to add the MCP servers named in a skill’s `agents/openai.yaml` to `~/.codex/config.toml`, so a server there with the same address is named as one Codex may have added for the skill. It stays, since you may use it for other things: remove it there if you don’t. The MCP servers, hooks and monitors its Claude Code plugin started, and Amp’s servers for it, keep running in sessions that are open now, until they restart. A `"<name>@skills-dir": false` you set in Claude Code’s `/plugin` stays in `~/.claude/settings.json`, and keeps any later folder with that plugin name off. Next Term reads `~/.claude` and `~/.codex` in your home folder: a `CLAUDE_CONFIG_DIR` or `CODEX_HOME` set elsewhere is not followed.
- **Projects are never changed.** Settings › Skills shows a project's skills without writing to them.
- **No skill ships with Next Term.** The Featured list holds only names, places and the commit that was looked at.

## The first launch warning

Next Term is not notarized by Apple, which is why macOS asks you to allow the first launch of a disk image downloaded in a browser. The source is public, and releases are built from it by GitHub Actions. Each release ships a `.sha256` file so you can check the download yourself first; see [Check the download](/docs/getting-started/#check-the-download-optional). With the one-line installer, which checks the signed checksum for you, macOS does not ask.

## Report a problem

Found a security issue? Please report it through the repository’s [Security page on GitHub](https://github.com/MishukAdhikari/next-term/security) rather than in a public issue, so it can be fixed before it is widely known.
