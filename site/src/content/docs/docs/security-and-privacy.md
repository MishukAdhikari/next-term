---
title: Security and privacy
description: "What Next Term shares and with whom: local-only agent links and MCP socket, a fresh token per launch, no telemetry, and clipboard and paste safeguards."
---

A terminal sees everything you type, and an agent link exposes your editor to programs. Next Term is built so that both stay on your Mac and under your control. The source is public under the MIT licence, so every claim on this page can be checked.

## What leaves your Mac

- **No account, no telemetry, no analytics.** Next Term has no sign-in and sends no usage data.
- **One network request of its own:** the daily update check to GitHub, which you can turn off. See [Updates](/docs/updates/#what-the-check-sends).
- **No AI of its own.** Next Term runs the agents you install. What those agents send to their providers is between you and them.

## The agent links

Claude Code, Gemini CLI and Qwen Code connect to Next Term as their IDE. That link is built to be safe by default:

- **Local only:** the servers listen on `127.0.0.1`, never on the network.
- **A fresh token per launch:** a new 256-bit secret every time Next Term starts, compared in constant time. The lock file that tells Claude Code where to connect is readable only by you (`0600` in a `0700` folder) and is removed on quit. Lock files left by other editors are never touched.
- **Browsers refused:** any request with an `Origin` header, as web pages send, is rejected.
- **Read-only for agents:** nothing an agent sends writes a file. Proposed edits are shown to you; the agent writes after you accept.
- **Secrets stay out:** selections and open files from `.env` and `.env.*` (except `.env.example`), `*.pem`, `*.key`, `id_rsa`, `id_ed25519`, `.npmrc` and `.netrc` are never shared.
- **Off switch:** **Settings › Editor › Agents** turns the link off entirely.

Next Term turns on Gemini CLI’s and Qwen Code’s IDE mode by changing exactly one setting in their settings files, and never rewrites a file with comments. See [Gemini CLI and Qwen Code](/docs/agents/#gemini-cli-and-qwen-code).

## The MCP server

Agents can drive Next Term through its MCP server ([Orchestrate agents](/docs/orchestration/)). It is built to the same standard:

- **No network port.** The app listens on a Unix socket, `~/Library/Application Support/Next Term/mcp.sock`, with mode `0600`, and checks that every connection comes from your own user. That is the reach your own shell already has.
- **Honest tool descriptions:** typing into a tab, pressing keys, answering an agent’s question, opening and closing tabs are marked destructive, so agents ask before they use them.
- **Questions are answered once:** an answer names the question it is for, and is refused if the agent has moved on to another one.
- **Project files stay inside, and secrets stay out:** the file, search and git tools read only inside the projects open in Next Term, with symlinks resolved first. `.env` files, keys and certificates, ssh keys, credentials files and `.git` are refused, and secret-looking values in what they return are masked as `•••`. Nothing is written.
- **No self-control:** an agent cannot type into, or close, the tab it runs in.
- **Busy tabs are protected:** closing a tab that runs something needs an explicit `force`.
- **Your files are respected:** registering in an agent writes only Next Term’s own `next-term` entry, keeps comments and every other server, and never touches an entry it did not write.
- **Off switch:** **Settings › Editor › Agents: “Let agents control Next Term”** closes the socket and removes the entries.

## Tabs start fresh

A new tab is a fresh terminal, not a child of whatever launched Next Term. Variables that agents and editors set for their own child processes are removed: Claude Code’s session markers (so `claude` never thinks it is a sub-agent), other programs’ messaging secrets, IDE links and terminal variables left by another editor, and a git password helper that belonged to an editor. Settings you set on purpose, such as `ANTHROPIC_API_KEY`, `CLAUDE_CONFIG_DIR` or `CODEX_HOME`, stay.

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

## Updates

Downloads come only over HTTPS from GitHub, are checked against the release’s published SHA-256, and must be Next Term at the expected version with an intact code signature before they replace anything. See [Updates](/docs/updates/).

## The first launch warning

Releases are not notarized by Apple yet, which is why macOS asks you to allow the first launch. Each release ships a `.sha256` file so you can check the download yourself first; see [Check the download](/docs/getting-started/#check-the-download-optional).

## Report a problem

Found a security issue? Please report it through the repository’s [Security page on GitHub](https://github.com/MishukAdhikari/next-term/security) rather than in a public issue, so it can be fixed before it is widely known.
