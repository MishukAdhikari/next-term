# Next Term

**The missing IDE for the terminal.**

A native macOS terminal and editor for the AI era. Run Claude Code, Codex,
Command Code, Junie, a test suite and a dev server side by side, one per tab, and see at a glance which
agents are working, which are done, and which are waiting on your decision.

**[Download for macOS](https://github.com/MishukAdhikari/next-term/releases/latest/download/NextTerm.dmg)** ·
website and documentation: **[nxtrm.mishuk.me](https://nxtrm.mishuk.me)**

- **Agent status, in step with the agent.** A spinner shows while an agent is working, read from the
  agent's own screen ("esc to interrupt") for Claude Code, Codex, Command Code and Gemini CLI, so it stops
  the moment they stop; other agents go by output timing. A green check means done and waiting for your
  next prompt, an amber "!" means it is asking you something. Plain commands show no spinner and end
  with a check or a red cross. Marks clear when you look at the tab.
- **Decisions come to you.** When an agent asks for permission ("Do you want to make this edit…?"),
  a notification says so with the question; click it to land on that tab. Works however you start the
  agent: directly, through an alias or a shell function, `npx`, or `cd app && claude`.
- **Code editor.** Double-click a file (or click once, with a setting), pick a Find in Files result, or
  ⌘-click `src/app.ts:42:7` in any output: the file opens above the terminal at that line, coloured by
  112 TextMate grammars, the kind VS Code uses: PHP and Blade (Laravel, WordPress), Ruby and ERB (Rails),
  Python and Jinja (Django, Flask), JS/TS/TSX (React, Next.js), Vue, Svelte, Astro, Angular, Liquid, Twig,
  Go and templ, Rust, Elixir, YAML, SQL and more. Line numbers, adjustable line height, soft wrap, auto-indent, ⌘/ to comment, ⌘L to go to a line, find, undo. Files keep
  their encoding, line endings and permissions. When an agent changes a file you have open, the editor
  follows; if you have unsaved edits it asks first.
- **Jupyter notebooks, read-only.** A `.ipynb` opens as cells: Markdown laid out, code coloured in the
  kernel's language, and the outputs saved in the file (text, tables as text, images and errors). Nothing
  runs (there is no kernel); Open as JSON shows the file itself.
- **Large data files.** A JSON Lines, CSV or TSV file over 2 MB opens in a read-only head view: its first
  1,000 rows as a table, as fast for a 2 GB file as for a small one, with Load More, search and Copy As.
  Logs and other text files over 32 MB open there too.
- **Send to Agent (⌥⌘K).** Select code in the editor or a diff, or files and folders in the sidebar, and send
  them to the agent in your tab: Next Term types the reference in that agent's own syntax (`@app/User.php#L10-20`
  for Claude, `app/User.php:10-20` for Codex and others) and hands you the prompt to add your instruction. It
  never presses Enter for you.
- **Agents see your editor.** Claude Code, Gemini CLI, Qwen Code, GitHub Copilot CLI and opencode in a Next
  Term tab connect to Next Term as their IDE, the way they connect to VS Code: the lines you select go with
  your next prompt ("⧉ 10 lines selected"), and ⌥⌘K puts `@file#L10-20` into Claude's prompt (`@file:10-20`
  into Copilot's). When Claude, Gemini, Qwen or Copilot wants to edit a file, its change opens as a diff to
  Accept (⌘↩) or Reject, as in VS Code; answering in the terminal works too. Nothing to set up: Next Term turns
  Gemini's and Qwen's IDE mode on for you. Local only, with a fresh secret per launch; `.env` files are never
  shared; Settings turns it off.
- **Orchestrate agents across projects (MCP).** Next Term is an MCP server for any agent: Claude Code and
  the Claude desktop app, Codex and the ChatGPT desktop app, Gemini CLI, Qwen Code, Cursor, opencode,
  Copilot CLI, Amp, Junie and Command Code. One agent can run the others. It sees every project and tab
  with each agent's state (working, done, waiting for a decision and the question), opens projects, starts
  an agent in a new tab, gives it a prompt, waits until it stops, reads its screen, answers its questions
  (only the question it saw, never a newer one), reads the projects' files, searches them and sees their
  git status and diffs (secrets files refused, secret-looking values masked), and uses the editor (the
  selection, open files, opening a file at a line). Next Term adds itself to the agents it finds, with
  nothing to run; Settings turns it off and removes it again (from the Claude desktop app once Claude is
  closed). The tools are marked honestly, so agents ask you before they type into a tab. Local only: a
  private socket, no network port.
- **Secrets.** API and MCP keys sealed on your Mac, used by agents by name after you approve with Touch ID or
  your password. **Secrets › Import From** copies keys in from .env, JSON, TOML, YAML and CSV files and
  password-manager exports, moves them out of your MCP configs, or takes them from your own 1Password and
  Bitwarden CLI in a tab you can see, a ticked row at a time, with Undo. Rotate… opens a key’s page from its
  link and takes the new key in the same sheet; it keeps the old key masked for 30 days and can remind you
  when a key gets old (**Secrets › Keys Due to Rotate**). Each key asks for Touch ID every time it’s used
  until you untick that, and a key set to “Never show this key” is never shown or copied, even to you.
  See [Secrets](https://nxtrm.mishuk.me/docs/secrets/).
- **Pick up any agent's conversation.** The Welcome window lists your projects; choose one and every
  conversation Claude Code, Codex, Command Code, Gemini CLI, Qwen Code, opencode, Cursor Agent and Copilot
  CLI kept for it is there, newest first, with its title, branch and model, including the ones started in
  its subfolders. Resume runs it again in a new tab, in the folder it was started in; Fork continues a copy;
  a session open in a tab offers Go to Tab instead; type to search them by title, agent, branch or model.
  In a project window, ⌥⌘O does the same, and the
  sidebar's Agent Sessions group shows the newest five, marks the running ones and continues an agent's
  latest session. Only titles and dates are read (never whole transcripts), secrets are scrubbed from
  titles, and nothing is written.
- **Remote tabs on your servers.** File › New Remote Tab… (⌥⌘T) opens a tab on your VPS over your own ssh
  and `~/.ssh/config`. With tmux or herdr on the server, agents keep working while the Mac sleeps or is off,
  and the tab reattaches when it reconnects. Host keys are never accepted silently, nothing is installed on
  the server except the Tab hook you allow, and no password is stored. Agents get seven MCP tools to open tabs
  there and read the changes. To find herdr, a herdr tab uses the copy your running herdr server runs, or may
  run your login shell on the server once (no terminal, 3 seconds at most) to read its PATH; when herdr isn't
  there, the tab says where it looked and links herdr's install page.
- **`nxtrm`, like `code`.** `nxtrm .` opens the folder as a project, `nxtrm app/User.php:42` a
  file at a line. It works in every Next Term tab from the first launch, and in other terminals too: the
  first launch links it into a folder on your PATH that needs no password (`~/.local/bin`,
  `/opt/homebrew/bin`), or, when there is none, offers to put it in `/usr/local/bin` with your password.
  It never changes PATH or touches anyone else's `nxtrm`.
- **Your layout.** The terminal below the editor (default), beside it on the right or left, or above it;
  the project sidebar on the left or right; the terminal's tabs on top or in a list down its left or
  right, with split panes as rows under each tab (View › Terminal Tabs). From the ⋯ buttons, the View
  menu or Settings › Terminal. ⌘J folds the terminal away so the editor gets the room, and brings it back
  at its size.
- **Projects.** ⌘O brings up the Welcome window with the keyboard in its search: type a few letters, and
  Return goes to the window of an open project, opens a closed one, or connects to a saved server. Open
  projects come first, each marked with a filled dot and counted (a closed one has a ring), then the ones
  you used last, including those an agent, a worktree window or a restore opened. ⌘1–⌘9 jump to the first
  nine projects, and ⌘Return opens one in a new window. The list keeps your last 50 projects; Open Recent
  shows 10. ⌘O again there (or Open…) opens any folder as a project. Its window keeps the project in the
  sidebar, and new tabs open in it by default. Next Term opens to the Welcome window, reopens your last
  projects, or opens a new terminal, as you choose. Open Recent and Close Project too.
- **Project colours.** Each project's window has a colour of its own, a soft glow along its top row,
  strongest behind the window's buttons and gone 320 points in, so two windows side by side are told
  apart at a glance. It is picked the first time a project opens (the colour the open windows use least)
  and then kept. A worktree's window has its repository's colour, and the Welcome window's dots show it.
  Right-click the top row, or View › Project Color, for nine named colours, Automatic or None for This
  Project; Show Project Colors there, or in Settings › General, turns them all off. Nothing is written
  into the project.
- **A new terminal stays out of your files.** New Terminal (⌘N) opens a shell where new tabs open
  (Settings › Terminal › New tabs: your home folder unless you chose a folder). With no project, its
  sidebar says "No project open" and lists your recent projects, Open Folder…, Connect to Server… and
  Browse Home Folder, and no files; `cd` into a project and its tree appears, with Open as Project
  Window. Browse Home Folder shows your home folder's files in that window, each folder read only when
  you open it. Start an agent in your home folder and Next Term offers once to open a project for it
  instead (Don't Ask Again turns that off); the agent runs either way.
- **Project sidebar with git.** The project as a live file tree: changed files and folders coloured, with
  `+12 −3` line counts like a pull request, and the branch and total changes at the top, with a **Pull 152**
  button when the upstream has commits you don't (Next Term fetches every 10 minutes, so it appears
  without a click).
  Files your agents create or change show up on their own.
- **Databases.** A Databases group in the sidebar lists the databases a project's own files name (Laravel
  and Herd `DB_*` keys, `DATABASE_URL`, Prisma, Drizzle, Supabase, Vercel-linked projects, SQLite files),
  found by reading them, without running project code; local or remote by host, passwords masked. SQLite
  files open in a read-only viewer; other connections open in TablePlus when it is installed (libSQL
  aside), and local and development ones (Docker, OrbStack) in `mysql` or `psql` in a new tab. Each
  provider badge (Neon, Supabase, Vercel, Herd and others) opens that provider's page in the browser.
- **Services.** Below Databases, a Services group lists what else a project's files name: AI model
  providers, vector stores, tracing and evals, agent frameworks, local dev servers, backends and hosting.
  Each row's badge opens its page: a local server on the port the project sets, or the most specific
  dashboard page its files name. Keys are read by name only, and nothing is fetched to find a service.
- **Branches in one popup.** Click the branch (⌥⌘B): search branches and actions, check out, branch,
  update, commit, push, rebase and merge. It asks before changing files under a working agent, keeps
  uncommitted changes in a named stash, and logs every git command exactly as typed (Git › Git Commands).
- **Worktrees.** Open in New Worktree… on a branch, tag or commit in Branches (or when a switch would change
  the files under a working agent) checks it out in a folder of its own, beside the repository or in its
  `.claude/worktrees`, and opens it in its own window, so the checkout an agent works in keeps its branch
  and its changes. What git ignores there (`.env`, `node_modules/`, `vendor/`) the new folder can **copy**
  (APFS clones: independent, taking no space until either side changes), **link** (a link for each
  ignored entry, to the main checkout's: shared, so an install or an edit in either is in both, and
  nothing is copied; a bare repository has none, so Link is off there) or **leave out**, as you choose;
  the choice is remembered per repository. Linked, a workspace package still leads to the worktree's own
  source, and Composer's autoloader is cloned, so the worktree runs its branch's code. Linked entries
  have a link mark in the sidebar, and removing the worktree deletes only the links. Logs,
  Laravel's cached config, virtualenvs and Swift builds stay out either way; `.worktreeinclude` brings
  one back. Remove Worktree… never forces: the branch stays, and a worktree with changes stays too.
- **Git Log.** The commit history as a graph in an editor tab (⌥⌘L): lanes per line of history, branch
  and tag badges, filters by branch, author, date, paths and message or hash, and each commit's changed
  files, with a double-click for a file's diff in that commit. It follows the repository as agents commit.
- **Git blame.** View › Annotate with Git Blame shows who last changed each line, how long ago and the
  commit, beside the line numbers; click to see that commit in the Git Log. View › Current Line Blame
  adds a note after the line with the caret.
- **Changes in the gutter.** A bar beside the line numbers marks the lines added (green) or changed (blue)
  since the last commit, and a red wedge where lines were deleted, as you type or an agent writes. Click a
  mark for the file's changes side by side.
- **Split panes.** Split any tab right (⌘D, outside the editor) or down (⌘⇧D), as often as you like: an
  agent beside its test run, two agents side by side. Move between panes with ⌥⌘ and the arrows, maximize
  one with ⌘⇧↩, close it with ⌘W or the × in its header. The panes without the keyboard are shaded, and
  the tab's mark shows the pane that most needs you.
- **Git Diff (⌃⌘G).** Everything a branch changed, the way a pull request shows it: the changed files as a
  tree with their +/− on the left, the selected file's diff on the right, or every file's on one page with
  long unchanged runs folded. Compare all the branch's changes since it left main, what isn't committed
  yet, or one commit. A click on the sidebar header's +/− opens it too.
- **Changes side by side or unified (⌥⌘G).** A file's diff in the Git Diff tab: the old version beside the
  new, rows aligned, or one column top to bottom (View › Unified Diffs); the changed words marked,
  syntax-coloured. All changes, unstaged or staged; step through them and stage, unstage or revert one
  hunk at a time (⌘Z undoes a revert). Each action first checks the file is still what the diff showed,
  so a change an agent made meanwhile is never overwritten.
- **File operations.** Rename (Return), drag to move (Option to copy), New File / New Folder, Move to Trash,
  all undoable with ⌘Z. Drag a file onto a terminal to type its path.
- **Go to File (⌘P).** Type a few letters of a file's name or path and the list follows every keystroke:
  `usrctl` finds `UserController.php`; a whole file name, the start of a word and runs of letters rank
  first, and files you opened lately come first. `name:42` opens it at line 42. Instant on large
  projects (git's file list, searched off the main thread).
- **Find and Replace in Files** (⌘⇧F / ⌘⇧R) across the project, with regular expressions, file masks and
  a preview of every replacement; a file an agent changed since the search is never overwritten.
- **Dock badge and notifications** for agents that finished, in another app or in a tab you are not
  looking at, and for commands that finished while you were in another app. Settings > Notifications
  chooses which ones notify, after how long, and with or without a sound.
- **Every menu shortcut is yours.** Next Term > Settings (⌘,) > Keyboard Shortcuts lists every menu
  command; click one and press new keys. The shortcuts below are the defaults.
- **Bring your settings over.** Coming from VS Code or an editor built on it (Cursor, Devin Desktop, Trae,
  Kiro, Antigravity, Positron, Qoder…), a JetBrains IDE, Zed, iTerm2, Ghostty, cmux, kitty, Alacritty,
  WezTerm, Kaku or Terminal? Next Term > Import Settings and Shortcuts… (also offered on first launch) brings
  the matching shortcut set, the keys you changed yourself, font size, line height, wrap, clean-up on
  save, hidden files, fonts, the terminal's colours, cursor, scrollback and start folder, and recent
  projects. Nothing changes unless you choose it: the preview shows every item as a
  checkbox, and what it leaves out and why; Undo Import puts it all back. It only reads, on this Mac, and
  never opens files that can hold secrets. Your agent can run it too, through Next Term's import tools:
  the import window opens with its choices ticked, and only your Apply changes anything. See
  [Switching to Next Term](https://nxtrm.mishuk.me/docs/switching/).
- **Updates that keep your tabs.** Next Term checks GitHub Releases once a day, at 11:00 or later in your
  time zone (or Check for Updates). A new version opens a window with what's new, and a blue Update button
  at the top right brings it back. It downloads and is checked against its checksum signed with the Next
  Term release key; the update sheet then says what happens to each tab before anything quits. After the
  update, or after a quit, your windows, tabs, splits and scrollback come back, Claude Code, Codex and Qwen
  Code resume their conversations as you started them, and other agents' resume commands wait on the
  line for Return.
- **Native.** Swift and AppKit, universal (Apple Silicon and Intel): about 27 MB to download, 59 MB
  installed. macOS 13 or later.

## Install

In one line, from the terminal:

```sh
curl -fsSL https://nxtrm.mishuk.me/install.sh | bash
```

It downloads the latest release, checks its SHA-256, the bundle and the signature, and copies it to
Applications. When a folder on your PATH takes `nxtrm` without a password, it links it there too;
otherwise Next Term offers it when it opens. It never uses `sudo`, and macOS doesn't ask you to allow the
first launch ([the script](scripts/install.sh)). Or
download `NextTerm-x.y.z.dmg` from [Releases](../../releases), open it, and drag **Next Term** to
Applications. After that, Next Term updates itself (Next Term > Check for Updates).

Next Term is not notarized by Apple, so with the disk image macOS blocks the first launch. Allow it once:

- **macOS 15 and later:** open Next Term once (it will be blocked), then go to **System Settings →
  Privacy & Security**, scroll down, click **Open Anyway** next to Next Term, and confirm.
- **macOS 13 and 14:** right-click Next Term in Applications, choose **Open**, then **Open** again.

Releases are signed with Next Term's own certificate, so what you allow (a folder, the camera, the microphone) stays
allowed from one update to the next. The first update to a signed release may ask once more, and Full Disk Access, if
you gave it, needs giving again once; see [Release signing](docs/signing.md).

Each release includes `NextTerm-x.y.z.dmg.sha256`. Check the download with `shasum -a 256 -c
NextTerm-x.y.z.dmg.sha256` before allowing it.

## Tab status

| Mark | Meaning |
|---|---|
| none | At the prompt, a plain command running, or an agent working with View › Agent Spinner set to Off |
| spinner | An AI agent is working (View › Agent Spinner: Spinning, Still or Off) |
| green ✓ | An agent stopped and is waiting for your next prompt, or a command finished |
| amber ! | An agent is waiting on your decision (the question is in the tooltip), or a program rang the bell |
| red ✕ | A command exited with an error (the exit code is in the tooltip) |

How it knows, most reliable first:

1. **zsh integration.** Next Term starts zsh with its own `ZDOTDIR` holding a tiny `.zshenv`. That file
   points `ZDOTDIR` back at your real config, loads your `.zshenv`, and adds `preexec`/`precmd` hooks that
   report each command (as typed and with aliases expanded), its exit code, the working directory and any
   suspended jobs. Your `.zprofile`, `.zshrc` and frameworks such as oh-my-zsh load exactly as before. A
   command Next Term or an agent runs by itself (MCP's `new_tab` and `send_to_tab`, a resume) stays out of
   zsh's history, so ↑ and autosuggestions never offer it; a line Next Term only puts on your prompt is yours
   once you press Return.
2. **Agents.** `claude`, `codex`, `commandcode`, `gemini` and other agents stay in the foreground, so
   Next Term reads the agent's own screen, the way you would: "esc to interrupt" means working, a question
   with choices means it is waiting on you, anything else means idle. These hints are checked against
   Claude Code, Codex, Command Code and Gemini CLI. Other agents (Junie, opencode, Qwen Code and the rest)
   go by output timing until their screen shows one of them: printing means working, 2.5 s of silence
   means done. When a command looks plain (a shell function), Next Term also asks the kernel what is
   really running.
3. **Other shells.** For bash and fish, or after `exec bash`, Next Term asks the kernel for the terminal's
   foreground process and working directory twice a second.

Interactive programs (`vim`, `ssh`, `less`, REPLs) are never reported as "done". Closing a tab or quitting
asks first if a program is running or a job is suspended (Ctrl-Z) or in the background, and names it.

## Keyboard

| Action | Keys |
|---|---|
| New tab (in the project, or the current tab's folder) | ⌘T |
| New window (where new tabs open: your home folder unless Settings › Terminal says otherwise) | ⌘N |
| New remote tab (on one of your servers) | ⌥⌘T |
| Switch to or open a project (the Welcome window: ↩ go there, ⌘↩ new window, ⌘1–⌘9 the first nine; ⌘O again there for any folder) / Close project | ⌘O / File menu |
| Go to File (`name` or `name:line`) | ⌘P |
| Resume an agent session (↩ resume or go to its tab, ⌘↩ fork) | ⌥⌘O |
| Close tab (or the focused pane in a split tab) | ⌘W |
| Split right / split down (in the editor, ⌘D duplicates the line) | ⌘D / ⌘⇧D |
| Move between panes | ⌥⌘← ⌥⌘→ ⌥⌘↑ ⌥⌘↓, or ⌥⌘] / ⌥⌘[ in turn |
| Maximize the pane (and back) | ⌘⇧↩ |
| Select tab 1–8 / last tab | ⌘1…⌘8 / ⌘9 |
| Next / previous tab | ⌘⇧] / ⌘⇧[, Ctrl-Tab / Ctrl-Shift-Tab |
| Rename tab | ⌥⌘R, or double-click the tab |
| Project sidebar | ⌘B |
| Fold the terminal away (and back) | ⌘J |
| Find / next / previous | ⌘F / ⌘G / ⌘⇧G |
| Use the selection for Find | ⌘E |
| Replace in the open file | ⌥⌘F |
| Find in Files / Replace in Files | ⌘⇧F / ⌘⇧R |
| Clear | ⌘K |
| Font size | ⌘+ / ⌘- / ⌘0 |
| Option as Meta (for Emacs-style keys) | File menu, off by default |
| Save / Save All | ⌘S / ⌥⌘S |
| Close the file being edited | ⌘W (with the editor focused) |
| Comment line / Go to line | ⌘/ / ⌘L |
| Soft wrap | ⌥⌘W |
| Show a file's changes | ⌥⌘G |
| Git Diff (the changed files and their diffs) | ⌃⌘G |
| Branches (the branch popup) | ⌥⌘B |
| Git Log (the commit graph) | ⌥⌘L |
| Fetch / Update Project / Commit… / Push… / New Branch… | ⌘R / ⌥⌘U / ⇧⌘C / ⌥⌘P / ⇧⌘B |
| Send to Agent | ⌥⌘K |
| Indent / Outdent | ⌘] / ⌘[ (Tab / ⇧Tab on selected lines) |
| Between editor and terminal | ⌃` |
| Keyboard Shortcuts (change any menu shortcut) | ⌘, |

In the sidebar: Return renames, ⌘⌫ moves to the Trash, ⌘↓ or double-click opens (or one click: Settings ›
Editor › Open files with a single click). Right-click for Open in New Tab, Open as Project, Reveal in Finder,
Insert Path in Terminal, Copy Path and Copy Relative Path. Tabs can be dragged to reorder; middle-click
closes; tabs that don't fit go behind the » button.

In a terminal, when a program reads the mouse (herdr, tmux, vim with the mouse on), right and middle clicks go to
it; Shift-right-click or Control-click opens Next Term's menu. A tab Next Term's own tmux keeps on a server keeps
Next Term's menu.

## Security

- **Privacy prompts:** Next Term never reads your Desktop, Documents, Downloads, Pictures, Movies, Music,
  `~/Library` (with iCloud Drive and cloud-storage folders) or other disks on its own. The sidebar's
  scans, git status, Go to File, Find in Files and the checks at launch leave them out, and your home
  folder, `/`, `/Volumes` and `~/Library` are never a project, so opening a terminal asks for nothing.
  A project you open inside one of them, or a folder you open in the tree, works as any other: macOS
  asks once, because you went there. If you said Don't Allow, the folder says macOS hasn't given Next
  Term access, with a button to the System Settings pane that changes it, and nothing asks again.
  Settings › General › Full Disk Access… opens that pane for anyone who wants every folder without
  prompts; Next Term never asks for it. When macOS asks, it says "Next Term, or a command running in
  it, wants to access…": macOS asks in Next Term's name for the programs in its tabs too, and every
  kind of access a program could ask for has a reason given.
- **Clipboard:** programs can copy to the clipboard (OSC 52) only from the tab you are looking at, and can
  never read it, so a remote host over ssh cannot harvest what you copied. ⌘V strips control characters.
- **Screen contents** cannot be read back through terminal queries (DECRQCRA answers are blanked).
- **Status marks** from the shell carry a random per-tab secret that programs never see, so output (a
  `cat` of a log, a remote host) cannot fake "command finished" and skip the close confirmation.
- **Paths you drop or insert** are quoted so that no file name can run a command, even one containing
  control characters, and are sent as a bracketed paste.
- **Opening files** from the sidebar or with ⌘-click asks first when the file is an app, a script or an
  executable, including behind a symlink or a Finder alias (cloned repos carry no quarantine flag, so
  Gatekeeper would not ask). Links other than http, https, mailto and local files are refused.
- **The MCP server** listens on a Unix socket only you can open (0600, and each connection is checked to
  be yours), never on the network. Agents reach it through `nxtrm mcp`, which they start themselves.
  Tabs refuse input from their own agent, and a tab running something closes only when told to force it.
- **Secrets** (the Secrets menu, and Settings › Secrets) keeps API and MCP keys in a vault on your Mac, each
  value sealed on disk, with the key that opens them guarded by the Secure Enclave (on a Mac without one, by
  the login keychain, which Settings calls less protected); the names, what each key is for and the link to
  its page are not encrypted. Agents use a key by name, after Next Term’s own panel shows who asks, which
  keys and the command, and you approve with Touch ID or your password; no MCP tool returns a value. A key’s
  “Ask for Touch ID every time it’s used” is ticked by default (untick it in its Edit… sheet), and while it
  is, a request that uses the key offers only Allow once. A key set to “Never show this key” is never shown
  or copied, even to you, and that can’t be undone; commands you allow still get it. The New keys group in
  Settings › Secrets sets how both start for new keys. Stored keys are masked, best effort, in what agents
  read through Next Term. A command you approve gets the key in its environment, and for as long as it runs,
  any program running as you can read it there (`ps -E` shows it), an agent’s own shell tool included, which
  Next Term’s masks never see. The command can also send the key on, and Secrets can’t stop malware already
  running as you. **Secrets › Import From** leaves a file it copies keys from as it was, and changes an MCP
  config only once you choose the keys to move out of it. For 1Password and Bitwarden, Next Term types the
  CLI’s line into a new tab and never presses Return: you unlock at the CLI’s own prompt, and the keys go by
  pipe, never onto the screen. Next Term doesn’t rotate keys through providers’ APIs: you make the new key,
  and delete or deactivate the old one, on the provider’s page.
  See [Secrets](https://nxtrm.mishuk.me/docs/secrets/).
- **Git:** the sidebar reads status with read-only calls and `--no-optional-locks`, so it never holds the
  index lock while your own git commands run. On its own, Next Term only runs `git fetch`: every 10 minutes
  while it is the active app, and as the branch popup opens if the last fetch is over 5 minutes old. That
  updates remote-tracking branches and tags, never your branches, files or index, and Settings › Editor ›
  Git turns it off. Everything else runs only when you ask: checkout, merge, rebase, commit, push, stash,
  the sidebar's Pull and Push, and staging a hunk. Next Term asks first when an agent is working in the
  folder, puts changes a switch would overwrite in a named stash, and force-pushes only with a lease on the
  commits it showed you, never to `main`, `master`, `release/*` or the default branch `<remote>/HEAD` names.

## Build from source

Needs macOS 13+ and Swift 6 (the Xcode Command Line Tools are enough; full Xcode is not required).

```sh
git clone https://github.com/MishukAdhikari/next-term.git
cd next-term
swift run NextTerm            # run a debug build
scripts/build-dmg.sh          # universal app + DMG + checksum in dist/, and NextTerm.dSYM for crash reports
```

To sign with the release identity, as CI signs releases ([Release signing](docs/signing.md)):
`SIGN_ID=<its SHA-1> scripts/build-dmg.sh`. To sign and notarize for distribution:
`SIGN_ID="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=<notarytool profile> scripts/build-dmg.sh`.

## Tests

```sh
scripts/test.sh                          # unit tests: status, agents, git, files, editor, nxtrm, shortcuts, updates
python3 scripts/zsh-integration-test.py  # the shipped zsh hooks, in a real pty, with your zsh config
scripts/selftest.sh                      # end-to-end: drives the real app (opens a window)
scripts/orphan-check.sh                  # release check: what keeps running after Quit, closing tabs, Force Quit
scripts/perf-budget.sh                   # release check: CPU, drawing, git and memory budgets of a release build
```

The self-test opens real tabs and shells and checks every status transition, agent detection, jobs,
close confirmations, process cleanup, the security protections, projects, the sidebar with git, file
operations and undo, tab overflow, the editor (colours, editing, saving, files changed by agents, long
files), layouts, nxtrm, shortcuts, the agent links and the MCP server (driven through `nxtrm mcp` as an
agent would), then writes a report and screenshots.

## Layout

```
Sources/NextTermCore/   platform-neutral logic, no AppKit: TabStatus, AgentScreen, CommandClassifier,
                        ShellIntegration, Git, CommitLog and CommitGraph, Diff, HunkOps, FileTree and
                        FileOps, ProjectSearch, TextFile and LineIndex, EditorLanguage, CommandLineOpen,
                        KeyChord, Updates, MCPServer, MCPProjectTools, MCPRedaction and MCPRegistrar (the
                        agent-facing MCP server, its file, search and git tools with their path and secrets
                        rules, and its registration in each agent)
Sources/NextTerm/       the macOS app: windows, tabs, sidebar, editor, projects, menus, shortcuts, updates,
                        notifications, self-test
Resources/Highlighting/ the shipped grammars (scripts/update-highlighting.py) and the Next Dark theme
Tests/                  unit tests (swift-testing)
scripts/                build, test, signing and icon scripts
docs/                   release signing (signing.md)
```

`NextTermCore` has no AppKit dependency, so another front end can reuse it. An iPad or iPhone app
(SwiftTerm supports UIKit) could reuse most of it, but not as it is: it runs git with Foundation's
`Process` and finds the home folder with `homeDirectoryForCurrentUser`, and iOS has neither.

## Roadmap

Coming: a server's files in the editor and sidebar next to its remote tabs, then Dev Containers. Later: more
of the diff view and session restore. A Linux build would need a different UI layer (AppKit is macOS-only);
the core logic would carry over.

## Credits

Terminal emulation by [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (MIT). Syntax highlighting by
[shiki-swift](https://github.com/fayazara/shiki-swift) (MIT) with Oniguruma (BSD), using TextMate grammars from
[shikijs/textmate-grammars-themes](https://github.com/shikijs/textmate-grammars-themes), each under its own
permissive licence ([list](Resources/Highlighting/GRAMMARS.md)). File icons from the
[Material Icon Theme](https://github.com/material-extensions/vscode-material-icon-theme) (MIT), whose icons
draw on Pictogrammers' Material Design Icons and Google's Material Symbols (Apache 2.0), rendered with
[SwiftDraw](https://github.com/swhitty/SwiftDraw) (zlib).

## License

MIT. See [LICENSE](LICENSE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
