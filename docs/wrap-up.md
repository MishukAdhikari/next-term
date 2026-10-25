# Wrap Up and Post Update

Two commands in the Tasks menu end a day of work with agents. **Tasks › Wrap Up…** (⌃⌘W) asks each agent tab of
the window for a short handoff file, and turns the next steps they write into tomorrow's tasks once you have read
them. **Tasks › Post Update…** drafts a Done / Next / Blocked update from today's handoffs, today's tasks and
today's commits, for you to copy, save or hand to an agent.

Next Term sends neither anywhere. Both work with files in your project, a line typed into a tab you can read, and
the clipboard. Both need a project window in front; with none they are greyed, and the menu's tooltip says why.

## Who is asked

Wrap Up lists the window's tabs that run an agent (Claude Code, Codex, Gemini CLI and the rest), in tab order. A
tab that is ready is ticked. Every other one is greyed and can't be ticked, with why:

- **working**: the agent is busy, or input went in moments ago.
- **asking**: it waits on a decision of yours.
- **has your text in its prompt**: you typed something there and haven't sent it.
- **on a server**, **locked**, **exited**, **can’t see its prompt**: Next Term can't type there safely.
- **not in this project’s top folder**: the handoff's path is relative to the project, so it would land
  somewhere else.
- **today’s handoff names are used up**: 99 handoffs from that tab today already.

A tab that becomes ready while the sheet is open stays unticked: only you add it. A ticked tab that starts working
is unticked with its reason. At Ask each tab is checked once more, and a tab that stopped being ready is skipped
and gets nothing.

## The request

Ask types one fixed line into each ticked tab and presses Return, so the agent starts at once. For a tab titled
“API tab” on 18 October 2026 it reads:

```text
Write a short handoff for this session to docs/handoffs/2026-10-18-api-tab.md (create the folder if needed) with exactly these sections: ## Done, ## Next (one "- " line per next step, each a task someone can start tomorrow), ## Open questions, ## How to resume. Write only that file; change nothing else and don't commit it.
```

It holds no task text, no project name and no stored key, and the path is relative, so no home folder or user name
is typed. A handoff in that shape looks like this:

```markdown
## Done
- Moved the acme/shop cart total into one function
- [x] Fixed the rounding of discounts

## Next
- Add a test for a cart with only free items
- Show the total with tax on the checkout page
- Ask the payments team about refunds over 30 days

## Open questions
- Should a voucher apply before tax?

## How to resume
Open cart/total.ts and run the cart tests.
```

Its three Next items become three tasks:

- Add a test for a cart with only free items
- Show the total with tax on the checkout page
- Ask the payments team about refunds over 30 days

## The file and its folder

The file is named for the day and the tab: `2026-10-18-api-tab.md`, then `-2` up to `-99` when the name is taken by
a file already there or by another tab in the same Wrap Up. The tab's title is masked before it becomes a name, and
only letters, digits and `-` are kept.

The folder is `docs/handoffs` in the project unless the project has its own: **Settings › Tasks › Handoff folder**,
under This project, with Choose… and Use Default. It must be a folder inside the project. One outside it, one
reached through a linked folder, or one with `..` is refused with “Choose a folder inside the project”, and nothing
is saved. The choice is kept in Next Term's settings, never in the repository, and every worktree of the project
shares it.

Wrap Up looks for each named file once a second. A row reads Asked until the file is there, Writing… while it still
grows or the agent still works, then Ready to review. After 5 minutes it reads Still writing, with Skip and Keep
Waiting. Only the file named in the request is read, and never through a link.

## How odd files are read

Agents don't always follow the shape, so the reader is lenient:

- A heading is a `#` heading of any level, a line in bold alone (`**Next**`), or a line ending in `:` (`Next
  steps:`). “Next steps”, “To do” and “Follow-ups” all count as Next; “Blocked” and “Questions” as Open questions.
- Next items are list lines (`-`, `*`, `+`, `1.`, `1)`), with or without a box. An item ticked `[x]` is shown
  unticked. A wrapped line joins its item; prose under Next with no list becomes one item per line.
- An item is cut to 200 characters at a word, and repeats are dropped.
- A file over 256 KB is read only to 256 KB, and the review says so. A file that isn't text isn't read.

## The review and Add

Review shows one section per tab, with the file's path, Show File (the masked text) and Reveal (the file in the
Finder). Each Next item is a ticked, editable task for tomorrow, going to the project's destination ([where tasks
go](task-destinations.md)). A handoff with no Next items, or a tab skipped, shows why and one empty row, and Add
Row adds more by hand.

Nothing is posted until you press **Add N Tasks**. It sends the ticked tasks through the same path as Add Task:
the one-minute duplicate warning, What's sent, Undo, and Through Your Agent typed with no Return. Cancel posts
nothing, and the handoff files stay in the project.

## Post Update

Post Update opens with “Gathering today’s work…” and fills one editable draft: a heading such as `## Update: shop,
18 October 2026`, then `### Done`, `### Next` and `### Blocked`, each with `- ` items, or `- None`. It comes from
three places, all local:

- **Today's handoffs** in the project's handoff folder: their Done, Next and Open questions (as Blocked). An item
  ticked under Next counts as Done.
- **Today's tasks** sent from this project, under Next, with where each went (Reminders, acme/shop). A task that
  opened a page says “page opened”, since Next Term can't know you created it.
- **Today's commits** under Done: git runs once, read-only, in the project's main checkout, across every branch
  and worktree, and only for commits whose author is your own `git config user.email`. With no email set there are
  no commit lines, and the sheet says “No commits: git has no user.email in this project.” Never everyone's
  commits.

Every character can be changed, and Start Over builds it again. Then:

- **Copy** puts it on the clipboard as plain text.
- **Save to Project** writes `docs/updates/2026-10-18.md` in the checkout the window shows, then `-2` and on. It
  never writes over a file, refuses a linked folder, and never stages or commits it.
- **Send Through an Agent Tab…** types `Post this update to <where>, exactly as written:` and the update into a
  ready agent tab you pick, with no Return. A draft over 4,000 characters is refused: copy it instead.

## What never leaves

- **Stored keys** show as `•••` in the handoff, the review, every task, the draft, and in what Copy, Save and Send
  give out, a key you pasted into the draft included.
- **No request.** Next Term makes no network request for Wrap Up or Post Update. A task goes where its
  destination says, as Add Task's do.
- **No log.** Handoff text, task text and the draft are never written to a log or a crash report.
