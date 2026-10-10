# VS Code family fixture

Written by hand from VS Code's docs and its product.json format; nothing here came from a real Mac. It is a
home folder: tests copy it to a temp folder and pass that as `home`, and its `Applications` as the only
folder apps are looked for in.

- Trae is installed (its product.json names its folders) and has the Vim extension and `vim.*` settings.
- Forky is a made-up editor found only by its product.json. Its extensions.json is a symlink out of `.forky`
  (to `outside/`), which must never be followed.
- Kiro and Positron were removed and left their folders. Kiro has the IntelliJ IDEA Keybindings and an Emacs
  keymap extension. Antigravity left a folder with no `User` folder, so nothing is found.
- Chat, Escape, Hidden Token and Notes are not editors built on VS Code, or name a folder that isn't plain.

Planted fake secrets that must never appear in anything an import returns (ImportFixtures.plantedSecrets):
a JWT-shaped token and a long run of letters, in settings.json, extensions.json metadata and a product.json.
