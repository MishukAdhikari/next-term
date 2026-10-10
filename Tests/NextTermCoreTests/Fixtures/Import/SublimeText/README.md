# Sublime Text fixture

Written by hand from Sublime Text's docs (revert.html for the data folders, settings.html, key_bindings.html) and the
settings, key bindings and menus its Default package ships; nothing here came from a real Mac. It is a home folder:
tests copy it to a temp folder, pass that as `home` and its `Applications` as the only folder apps are looked for in.

- `Applications/Sublime Text.app` gives its version as Sublime Text writes it ("Build 4200").
- `Library/Application Support/Sublime Text/Packages/User/Preferences.sublime-settings` (JSON with comments and
  trailing commas): settings Next Term has (font, size twice so the last wins, line padding, wrapping, clean-up on
  save, single-click preview, excluded names, some of them Sublime Text's defaults), ones it hasn't yet (tab width,
  rulers, colour scheme, caret), Vintage turned on by an empty `ignored_packages`, and keys that can hold secrets.
- `Default.sublime-keymap` and `Default (OSX).sublime-keymap` beside it: the macOS file is read second, so its ⇧⌘O
  wins. Commands told apart by their arguments (Go to File, Go to Line, Go to Symbol), a two-step key, a key with a
  context, a key turned off, a key bound twice, two keys for one command, a Control key, a keypad key, and a command
  whose arguments hold a secret.
- `Local/Session.sublime_session`: `@HOME@` stands for the copied home folder (tests put it in). `folder_history`
  lists a folder twice, one that doesn't exist, a relative path and one whose name looks like a credential;
  `recent_workspaces` names `Code/beta/beta.sublime-workspace`, whose `.sublime-project` lists two folders, and a
  workspace without a project. The session's unsaved text and find history hold planted secrets.
- `Installed Packages` and `Packages` hold packages to count (NeoVintageous among them); `Packages/User` holds
  other settings files, a snippet and a build system, which are never opened.
- `Sublime Text 3` is an older data folder, used only when it is the newer of the two.
- `outside/Preferences.sublime-settings` is outside the data folder: a test links the settings file to it, and it
  must never be read.
- Planted fake secrets that must never appear in anything an import returns (ImportFixtures.plantedSecrets): in the
  settings (a proxy and a token), an excluded name, a key binding's arguments, the session's unsaved text and find
  history, a folder name, the project's env and build system, the workspace file, Package Control's settings and a
  build system.
