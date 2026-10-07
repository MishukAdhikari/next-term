---
title: Code editor
description: "The editor above your terminal: Go to File (⌘P), 112 languages, line height, soft wrap, ⌘/ comments, ⌘L, and files that follow your agents’ edits."
head:
  - tag: title
    content: A native macOS terminal with a code editor — Next Term
---

Next Term has a real code editor, not a viewer, and it sits right above the terminal where your agents work. You read what an agent changed, fix a line yourself, and save, without switching apps.

![The editor showing long.ts with syntax colours and line numbers, in a tab next to main.php.](../../../assets/screenshots/editor.webp)

## Opening files

- **Go to File** (<kbd>⌘P</kbd>): type part of a file’s name or path and pick it. See [below](#go-to-file).
- **Double-click** a file in the project sidebar, or select it and press <kbd>⌘↓</kbd>.
- **<kbd>⌘</kbd>-click a path** in terminal output, such as `src/app.ts:42:7` from a compiler, linter or agent: the file opens at that line and column. A Python traceback’s `File "graph.py", line 42` opens at line 42 (at the frame you clicked, when the same file appears twice), and so do pytest’s and ruff’s `path.py:42:` lines. A `graph.py:graph` reference, as `langgraph.json` writes it, opens at the definition of `graph`.
- **Pick a result** in [Find in Files](/docs/search/).
- **Run `nxtrm file:42`** in a tab or any terminal. See [The nxtrm command](/docs/command-line/).
- **Finder:** use **Open With › Next Term**, or drop a file on Next Term’s Dock icon.

Each file opens in its own tab above the terminal; a dot in place of the close button means unsaved changes. Images, binaries and files over 32 MB open in their usual app instead. An app, a script or an executable never opens without asking first, even behind a symlink or a Finder alias (see [Security and privacy](/docs/security-and-privacy/#opening-files-and-links)).

Move between the editor and the terminal with <kbd>⌃&#96;</kbd> (**View › Focus Editor**). <kbd>⌘W</kbd> closes the file you are editing when the editor has the keyboard, and the terminal tab otherwise.

## Go to File

Press <kbd>⌘P</kbd> and type: any file in the project, found by name or path as you type.

- **Fuzzy:** the letters only need to appear in order, so `usrctl` finds `UserController.php`. The path counts too, so a folder name narrows the list.
- **File names first:** a match in the file’s name ranks above a match somewhere in its path.
- **At a line:** add the line number, as in `UserController.php:42`, and the file opens there.
- **From a selection:** with text selected in the editor or the terminal, <kbd>⌘P</kbd> starts with it, as Find does. Select `app/Models/User.php:42` in a stack trace and press <kbd>⌘P</kbd>, then <kbd>↩</kbd>.
- **Recently opened first:** with nothing typed, the list is the files you opened lately, newest first.

## 112 languages

Colours come from open-source TextMate grammars, through shiki-swift. Highlighting is incremental, so long files stay fast. The theme is Next Term’s own, Next Dark.

- **Web:** HTML, CSS, SCSS, Sass, Less, Stylus, PostCSS, JavaScript, TypeScript, JSX, TSX, Vue, Svelte, Astro, Angular templates, Marko, Glimmer, GraphQL, HTTP.
- **Templates:** Blade (Laravel), Twig, Liquid, Handlebars, Jinja (Django, Flask), ERB and Haml (Rails), Pug, Edge, Razor, templ, Prompty.
- **Languages:** PHP, Ruby, Python, Go, Rust, Java, Kotlin, Scala, Groovy, Swift, Objective-C, C, C++, C#, Dart, Elixir, Erlang, Haskell, OCaml, Clojure, Julia, Lua, Perl, R, Zig, CoffeeScript, PowerShell, Shell, Fish, Vim Script.
- **Data and configuration:** JSON, JSON5, JSON with Comments, JSON Lines, YAML, TOML, INI, XML, CSV, TSV, SQL, Cypher, SPARQL, Turtle, Prisma, Protocol Buffers, Terraform and HCL, Nix, dotenv, pip requirements, Dockerfile, Makefile, CMake, Just.
- **Writing and git:** Markdown, MDX, reStructuredText, Mermaid, diffs, commit and rebase messages, log files.

**Prompts read as prompts.** In RAG and agent projects (LangChain, LangGraph, LlamaIndex…), `{context}` placeholders and `{{ question }}` or `{% for %}` templates inside Python strings get their own colours, as they do in `.jinja`, `.j2` and `.prompty` files. A Markdown file’s front matter (a `SKILL.md`, say) and every language in its code fences colour from the moment it opens.

PHP files are coloured with the grammar that also understands the HTML around `<?php … ?>`. Each grammar keeps its upstream licence; the list is in the repository’s `GRAMMARS.md`.

## Editing

| Action | How |
|---|---|
| Comment or uncomment lines, in the file’s language | <kbd>⌘/</kbd> |
| Go to a line | <kbd>⌘L</kbd> |
| Indent, outdent | <kbd>⌘]</kbd>, <kbd>⌘[</kbd>, or <kbd>⇥</kbd>, <kbd>⇧⇥</kbd> on selected lines |
| Find, next, previous | <kbd>⌘F</kbd>, <kbd>⌘G</kbd>, <kbd>⇧⌘G</kbd> |
| Use the selection for Find | <kbd>⌘E</kbd> |
| Undo, redo | <kbd>⌘Z</kbd>, <kbd>⇧⌘Z</kbd> |
| Save, Save All | <kbd>⌘S</kbd>, <kbd>⌥⌘S</kbd> |

- **Auto-indent:** Return keeps the line’s indent. After an opening bracket it indents one more level, and between a pair of brackets it puts the closing one on its own line.
- **Line numbers** run down the left, and the current line is highlighted.
- **Plain text, as code needs it:** the editor never turns your quotes into curly ones.
- **Quitting** with unsaved files asks whether to save them.

## Line height, font size and soft wrap

- **Line height** is a multiple of the font’s own line height: **View › Line Height** offers 1.0, 1.15, 1.25, 1.35 (the default), 1.5, 1.75 and 2.0, and **Settings › Editor** has a slider in steps of 0.05. Every line gets the same height, with the text centred in it.
- **Font size** is shared with the terminal: <kbd>⌘+</kbd> bigger, <kbd>⌘-</kbd> smaller, <kbd>⌘0</kbd> back to 13 pt, anywhere from 8 to 32 pt. The font is JetBrains Mono if you have it installed, and SF Mono otherwise.
- **Soft wrap** (**View › Soft Wrap**, on by default) wraps long lines at the window’s edge. A wrapped line continues under its own indentation plus two columns, so a long statement still reads as one statement at its level. Line numbers stay on each line’s first row.

## Files keep their format

Saving writes the file back the way it was stored:

- **Encoding:** UTF-8, UTF-8 with a byte-order mark, and UTF-16 (little- or big-endian, with a byte-order mark) are kept as they are.
- **Line endings:** LF or CRLF are kept. A file with mixed endings keeps them exactly.
- **Permissions:** a script stays executable.
- **Links:** saving through a symlink writes the file it points at, and the link stays a link.
- **Atomic writes:** a save never leaves a half-written file behind.

## Files your agents change

Agents edit the files you have open. Next Term checks them about once a second:

- **A file without unsaved edits follows the agent.** Only the changed part is replaced, so your caret, the scroll position and the colours of everything else stay put.
- **A file with unsaved edits asks first.** A banner says the file changed on disk while you were editing it: **Keep My Changes** (your version is kept, and saving writes it) or **Reload from Disk**.
- **A file that was deleted or moved** shows a banner too: **Keep My Changes** or **Close**.
- **Renames and moves in the sidebar** carry open files along.

To see exactly what an agent changed, press <kbd>⌥⌘G</kbd>. See [Side-by-side diffs](/docs/diffs/).

## Changes in the gutter

Beside the line numbers, a thin bar marks every line that differs from the last commit, as you type or as an agent writes, unsaved edits included:

- **Green:** an added line.
- **Blue:** a changed line.
- **A red wedge** between two lines: lines were deleted there.

Click a mark to open the file’s changes side by side. After a commit (yours or an agent’s) the marks clear on their own. Files outside git, or not committed yet, show none.
