# WezTerm and Kaku fixture

Written by hand from WezTerm's docs (config files, keys, colours) and Kaku's (its generated kaku.lua); nothing here
came from a real Mac. It is a home folder: tests copy it to a temp folder and pass that as `home`. The Lua is never
run: the import reads only values written out in it.

- `.config/wezterm/wezterm.lua` writes out a font list, its size, a blinking bar cursor, the scrollback, a colour
  scheme (from `colors/night-owl.toml`) with `colors` over it, and right Option as Alt (left is WezTerm's default).
  Its keys use `act.X`, `act.X 'arg'`, `act.X { … }` and the older `wezterm.action { X = … }`, beside a key after
  the leader key, one that sends text and one whose action is a Lua function.
- It also sets values Lua works out (a variable, inside an `if`, inside a function), calls `os.execute`, and sets
  `default_prog`, `set_environment_variables` and `ssh_domains`, which are named, never read.
- `.config/kaku/kaku.lua` loads Kaku's bundled defaults (code), then overrides the font size, the scheme and left
  Option, and adds a key with `table.insert(config.keys, …)`.
- Planted fake secrets that must never appear in anything an import returns (ImportFixtures.plantedSecrets): in
  `default_prog`, `set_environment_variables`, the `os.execute` call and a `SendString` key.
