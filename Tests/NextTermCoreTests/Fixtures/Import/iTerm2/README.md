# iTerm2 dynamic profiles fixture

Written by hand from iTerm2's docs (Dynamic Profiles) and its preferences' key names; nothing here came from a real
Mac. It is a home folder: tests copy it to a temp folder and pass that as `home`.

- The preferences plist has two regular profiles and names `DYN-WORK`, a dynamic profile, as the default. It also
  loads its settings from a custom URL (whose address holds a planted secret).
- `DynamicProfiles/10-base.json` (JSON) sets a font and the Option keys; `20-work.plist` (a property list) is the
  default, a child of Base by name, and sets the cursor and a colour. Base has no parent, so it is merged over the
  first regular profile (the default Guid isn't a regular one).
- `30-orphan.json` names its parent by Guid; `40-collide.json` reuses a regular profile's Guid and is ignored, as
  iTerm2 ignores it; `.hidden.json` is hidden; `50-broken.json` isn't valid; `05-escape.json` is a symlink out of
  the folder (to `outside.json`), which must never be read.
- Planted fake secrets that must never appear in anything an import returns (ImportFixtures.plantedSecrets): in
  commands, a trigger, initial text, a token in the preferences, the custom URL and `outside.json`.
