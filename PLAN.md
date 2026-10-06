# Next Term — plan

A native macOS terminal and editor, built for running AI agents side by side:
every tab shows whether its job is working, finished, failed, or waiting on you.

## Decisions

| Decision | Choice | Why |
|---|---|---|
| Language / UI | Swift + AppKit | Native on macOS; Swift also runs on iOS, so the core can move to iPhone/iPad later |
| Terminal emulation | SwiftTerm (MIT) | Mature native VT emulator for AppKit and UIKit; writing one is a project in itself |
| Build | SwiftPM + Command Line Tools | No Xcode required; CI and contributors need only `swift` |
| Distribution | Universal `.app` in a drag-to-install DMG | Apple Silicon + Intel in one download |
| Platforms | macOS first | Linux would need a non-AppKit UI; `NextTermCore` is portable Foundation code |
| License | MIT, open source on GitHub | Same as SwiftTerm |

## Features (v0.1)

- Tabs: ⌘T (opens in the current tab's folder), ⌘W with confirmation when busy, ⌘1–9, ⌘⇧[ ], Ctrl-Tab,
  rename (double-click or ⌘⇧R), drag to reorder, middle-click to close, ⌘N windows.
- Tab status dots: working, done, failed, attention; cleared when viewed. Dock badge, notifications when
  the app is in the background.
- Project sidebar (⌘B): the active tab's git project as a live file tree (FSEvents), Finder icons,
  double-click to open, drag to the terminal to type the path, context menu.
- Find (⌘F), clear (⌘K), font size (⌘+/-/0), a dark palette.

## Status detection

1. zsh integration via `ZDOTDIR` + `.zshenv` that restores the user's own `ZDOTDIR`, then reports
   preexec/precmd over a private OSC 6973 (command text, exit code, cwd).
2. Agents (`claude`, `codex`, …) stay in the foreground: output in the last 2.5 s = working, silence =
   waiting for you. Keystroke echo and resize redraws are ignored.
3. bash/fish fallback: the pty's foreground process from the kernel (`tcgetpgrp` + `proc_name`), polled.

## Verification

- `scripts/test.sh`: unit tests for the status machine, classifier, OSC parser, quoting, file tree.
- `scripts/zsh-integration-test.py`: the shipped zsh script in a real pty with the user's real config.
- `NextTerm --self-test`: drives the real app end to end and takes real window screenshots.
- Independent code and security reviews before release.

## Not in v0.1

Split panes, session restore, settings UI, bash/fish integration, notarization, Linux, iOS.
