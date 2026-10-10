# kitty fixture

Written by hand from kitty's docs (kitty.conf, the themes kitten); nothing here came from a real Mac. It is a home
folder: tests copy it to a temp folder and pass that as `home`.

- `.config/kitty/kitty.conf` sets the font (kitty's `family="…"` form), its size, the cursor, unlimited scrollback,
  left Option as Alt and colours, includes the themes kitten's `current-theme.conf` and, through `globinclude`,
  `kitty.d/extra/size.conf` (a later font size). It names includes that must not be read: one outside kitty's
  folder, one with an environment variable, a symlink out of the folder (`escape.conf`), a missing one, a
  `geninclude` and an `envinclude`.
- `dark-theme.auto.conf` is the themes kitten's dark theme, whose colours win.
- `map` lines with a Next Term command (`kitty_mod` is ⌘⇧ here), and ones that must not come over: a two-step key, a
  key only for some windows, text to send, a `launch` that runs a program, `new_os_window` and `new_tab_with_cwd`
  followed by a program (ssh, and one with the planted secret), and a key unmapped by a later line.
- Planted fake secrets that must never appear in anything an import returns (ImportFixtures.plantedSecrets): in
  `shell`, `env`, `remote_control_password`, a `send_text` map and `outside.conf`.
