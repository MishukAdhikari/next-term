# Alacritty fixture

Written by hand from Alacritty's docs (alacritty(5), alacritty-bindings(5)); nothing here came from a real Mac. It
is a home folder: tests copy it to a temp folder and pass that as `home`.

- `.config/alacritty/alacritty.toml` uses 0.14's spelling (`[general]`). It imports a theme by a relative path and a
  key file by `~/`, and names three imports that must not be read: one outside Alacritty's folder (`~/outside.toml`),
  a symlink out of it (`escape.toml`) and one that isn't valid TOML (`broken.toml`), plus a missing one.
- It sets the font, its size, the cursor, the scrollback, left Option as Alt, a start folder (`~/Projects`), colours
  over the theme's, and key bindings: ones with a Next Term command, one that sends text, one that runs a command,
  one only in search mode, a Control-only key, a scan code and an action with no command.
- Planted fake secrets that must never appear in anything an import returns (ImportFixtures.plantedSecrets): in
  `[env]`, the shell's arguments, the bell's command, a binding's `chars` and `command`, and `outside.toml`.
