# JetBrains fixture

Written by hand from JetBrains' docs (the settings folders, product-info.json and idea.properties); nothing here
came from a real Mac. It is a home folder: tests copy it to a temp folder, pass that as `home` and its
`Applications` as the only folder apps are looked for in, and set each settings file's date (git keeps none).

- PhpStorm is installed (its product-info.json names its folder, `PhpStorm2026.1`). Its settings add ignored
  files, turn off reopening projects and open projects in a new window. Its active keymap's file is a symlink out
  of the settings folder (to `outside/`), which must never be followed. Its idea.properties moves nothing.
- Android Studio is installed, and the idea.properties in its bundle moves its settings to
  `~/.android-studio/config`: its usual folder is missing.
- GoLand's own idea.properties moves its settings to `${user.home}/GoLandSettings/config`. Its app is not
  installed: `Hidden Token.app` names its folder but has a name that looks like a credential.
- RubyMine's idea.properties uses `${idea.home.path}`, which is not followed, so its usual folder is read.
- WebStorm is the IDE not used lately (the tests date its settings 300 days back).
- `Acme.app` has a product-info.json from another vendor.

Planted fake secrets that must never appear in anything an import returns (ImportFixtures.plantedSecrets): in
PhpStorm's product-info.json launch properties, github.xml, ide.general.xml, phpstorm.key, the ignored files
list, the escaped keymap and an app's name.
