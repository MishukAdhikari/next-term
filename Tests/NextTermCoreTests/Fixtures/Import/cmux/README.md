# cmux fixture

Written by hand from cmux's docs (configuration, keyboard shortcuts, Ghostty keybindings) and its config parser
(`StoredShortcut+ConfigParsing.swift`, `CmuxGhosttyConfigPathResolver.swift`); nothing here came from a real Mac. It
is a home folder: tests copy it to a temp folder, pass that as `home` and its `Applications` as the only folder apps
are looked for in.

- `Applications/cmux.app` gives its version and ships Ghostty's themes (`Night Owl`); `Escape` there is a symlink out
  of its themes folder, which must never be followed. `Other Term.app` is another app that ships them (`Dracula`).
- `.config/ghostty/config` is Ghostty's config, which cmux reads: a font, a size, the theme by name and a keybind.
- cmux's own Ghostty config (`Library/Application Support/com.cmuxterm.app/config.ghostty`) is read after it and
  wins; the older `config` beside it is ignored, as cmux ignores it when `config.ghostty` has something in it.
- `.config/cmux/cmux.json` (JSON with comments and trailing commas) rebinds cmux's own shortcuts: ones with a Next
  Term command, one removed, two-step chords, cmux's numbered-surface key, and actions Next Term doesn't have.
  Its other sections (an agent chat start command, actions) are never read.
- Planted fake secrets that must never appear in anything an import returns (ImportFixtures.plantedSecrets): in
  cmux's own Ghostty config `command`, and cmux.json's start command and an action's command.
