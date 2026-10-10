# Cursor fixture (the agent tools)

Written by hand from VS Code's docs and Cursor's settings format; nothing here came from a real Mac. It is a home
folder: tests copy it to a temp folder and pass that as `home`, and its `Applications` as the only folder apps are
looked for in. The agent tools' tests (MCPImportTests) preview and plan from it.

- Cursor is installed (its product.json names its folders) and has settings, key bindings and recent folders.
- `globalStorage/state.sql` is the state database's rows: the tests build `state.vscdb` from it in the temp copy,
  with `HOME/` standing for the copied home. Besides the recent folders it holds Cursor's sign-in rows
  (`cursorAuth/*`), which no reader may ever select.
- `Code/api/.vscode/settings.json` is a project's own settings, for preview_import's `path`: it asks to hide files
  and to start new tabs in a folder, which a file an agent names never sets.

Planted fake secrets that must never appear in anything an import or an agent tool returns
(ImportFixtures.plantedSecrets): in `terminal.integrated.env.osx`, `cursor.general.apiKey`, a key binding's
`args`, the `cursorAuth/*` rows, product.json's `crashReporter`, the project's settings and an extension's metadata.
