# Zed fixture

Written by hand from Zed's docs (settings.json, keymap.json) and its database schema (`persistence.rs`); nothing
here came from a real Mac. It is a home folder: tests copy it to a temp folder and pass that as `home`.

- settings.json sets the editor's and the terminal's font sizes, nothing to reopen at launch (`restore_on_startup`)
  and Zed's inline blame, beside a terminal `env`, a context server and a language model that must never be read.
- keymap.json gives keys to Copy Path, Commit, Push, Branches and Reopen Closed Tab, beside a terminal key that
  sends text, which is never read.
- workspaces.sql is the recent projects database the tests build (git can't hold a database as text): local
  workspaces, a two-folder one, a remote one, a folder that no longer exists, a repeat and an empty row, beside an
  editor's unsaved text and a key-value row that are never read.

Planted fake secrets that must never appear in anything an import returns (ImportFixtures.plantedSecrets): in
settings.json, keymap.json, a recent project's folder name and the database's other tables.
