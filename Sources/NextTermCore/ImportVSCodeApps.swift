import Foundation

// Which editors built on VS Code are on this Mac, and which keymap extensions they have. Read here, and only
// here: each app bundle's product.json (four keys: nameShort, dataFolderName, sharedDataFolderName and
// version), and the extension ids in <dataFolderName>/extensions/extensions.json. Neither file is ever shown:
// only a fixed label for a known extension, and a count of the rest. A file is read only when its real path
// stays inside the folder it belongs to, so a symlink never leads a read out of it.

extension ImportVSCode {
    /// An editor known by name, found by its settings folder even after the app itself was removed (its
    /// folder stays behind). `folder` is the app's product.json `nameShort`, which names its folder in
    /// ~/Library/Application Support; `dataFolders` its `dataFolderName`, the folder in the home folder that
    /// holds its extensions (none: not checked, so never guessed). Each was checked against the app's own
    /// product.json or the folders its uninstaller removes; an editor whose settings folder couldn't be checked
    /// (Windsurf Next) is found only while it is installed.
    struct Source {
        let kind: ImportSourceKind
        let name: String
        let folder: String
        /// The app bundle's possible names in /Applications or ~/Applications.
        let bundles: [String]
        let dataFolders: [String]
    }

    /// Devin Desktop's bundle has had two names, so both are tried. Windsurf is its old name and folder,
    /// used only when the Devin folder isn't there. VSCodium has used both data folders.
    static let sources: [Source] = [
        Source(kind: .vsCode, name: "VS Code", folder: "Code", bundles: ["Visual Studio Code.app"], dataFolders: [".vscode"]),
        Source(kind: .vsCodeInsiders, name: "VS Code Insiders", folder: "Code - Insiders",
               bundles: ["Visual Studio Code - Insiders.app"], dataFolders: [".vscode-insiders"]),
        Source(kind: .vsCodium, name: "VSCodium", folder: "VSCodium", bundles: ["VSCodium.app"], dataFolders: [".vscode-oss", ".vscodium"]),
        Source(kind: .cursor, name: "Cursor", folder: "Cursor", bundles: ["Cursor.app"], dataFolders: [".cursor"]),
        Source(kind: .devinDesktop, name: "Devin Desktop", folder: "Devin", bundles: ["Devin.app", "Devin Desktop.app"], dataFolders: [".devin"]),
        Source(kind: .devinDesktop, name: "Windsurf", folder: "Windsurf", bundles: ["Windsurf.app"], dataFolders: [".windsurf"]),
        Source(kind: .vsCodeFork, name: "VSCodium Insiders", folder: "VSCodium - Insiders",
               bundles: ["VSCodium - Insiders.app"], dataFolders: [".vscodium-insiders"]),
        Source(kind: .vsCodeFork, name: "Code - OSS", folder: "Code - OSS", bundles: ["Code - OSS.app"], dataFolders: [".vscode-oss"]),
        Source(kind: .vsCodeFork, name: "Trae", folder: "Trae", bundles: ["Trae.app"], dataFolders: [".trae"]),
        Source(kind: .vsCodeFork, name: "Trae CN", folder: "Trae CN", bundles: ["Trae CN.app"], dataFolders: [".trae-cn"]),
        Source(kind: .vsCodeFork, name: "Kiro", folder: "Kiro", bundles: ["Kiro.app"], dataFolders: [".kiro"]),
        Source(kind: .vsCodeFork, name: "Antigravity", folder: "Antigravity", bundles: ["Antigravity.app"], dataFolders: [".antigravity"]),
        Source(kind: .vsCodeFork, name: "Positron", folder: "Positron", bundles: ["Positron.app"], dataFolders: [".positron"]),
        Source(kind: .vsCodeFork, name: "Void", folder: "Void", bundles: ["Void.app"], dataFolders: [".void-editor"]),
        // Qoder's settings folder is checked, its extensions folder isn't (~/.qoder also holds its agents' data),
        // so its keymap extensions are read only while the app is installed and its product.json names the folder.
        Source(kind: .vsCodeFork, name: "Qoder", folder: "Qoder", bundles: ["Qoder.app"], dataFolders: []),
    ]

    static let family: Set<ImportSourceKind> = [.vsCode, .vsCodeInsiders, .vsCodium, .cursor, .devinDesktop, .vsCodeFork]

    /// Where apps are looked for: /Applications and ~/Applications.
    static func applicationFolders(home: String) -> [String] {
        ["/Applications", (home as NSString).appendingPathComponent("Applications")]
    }

    // MARK: product.json

    /// The four keys of an app bundle's product.json this import uses. Every name is a plain folder name (no
    /// `/`, not `.` or `..`, nothing that looks like a credential), or nil.
    struct Product: Equatable {
        /// The .app.
        let bundle: String
        /// The folder in ~/Library/Application Support (its `User` folder holds settings.json).
        let nameShort: String?
        /// The folder in the home folder that holds the extensions.
        let dataFolderName: String?
        let sharedDataFolderName: String?
        let version: String?
    }

    /// The product.json inside `bundle`, if it is a plain file inside it. Only the four keys are converted.
    static func product(bundle: String) -> Product? {
        guard let path = file("Contents/Resources/app/product.json", inside: bundle),
              let text = readText(path, limit: 4 << 20), let document = JSONC(text),
              case .object(let root)? = document.root else { return nil }
        func string(_ key: String) -> String? {
            guard let member = root.members.last(where: { $0.key == key }), case .scalar = member.value else { return nil }
            return member.value.object(in: text) as? String
        }
        return Product(bundle: bundle, nameShort: plainName(string("nameShort")), dataFolderName: plainName(string("dataFolderName")),
                       sharedDataFolderName: plainName(string("sharedDataFolderName")), version: version(string("version")))
    }

    /// Every app in `applications` (top level only) whose product.json names both its settings folder and its
    /// extensions folder: that pair is what makes it an editor built on VS Code, whatever it is called.
    static func installedProducts(applications: [String]) -> [Product] {
        var found: [Product] = []
        for folder in applications {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { continue }
            for name in names.sorted().prefix(2_000) where name.hasSuffix(".app") && !name.hasPrefix(".") {
                guard let product = product(bundle: (folder as NSString).appendingPathComponent(name)),
                      product.nameShort != nil, product.dataFolderName != nil else { continue }
                found.append(product)
            }
        }
        return found
    }

    /// The product.json of the installed app `app` came from: the bundle detection found, else one of the
    /// known bundle names, else any app whose `nameShort` is the app's settings folder.
    static func installedProduct(for app: DetectedApp, applications: [String]) -> Product? {
        if let bundle = app.appPath, let product = product(bundle: bundle) { return product }
        let folder = settingsFolder(of: app)
        for directory in applications {
            for bundle in source(folder: folder)?.bundles ?? [] {
                if let product = product(bundle: (directory as NSString).appendingPathComponent(bundle)) { return product }
            }
        }
        return installedProducts(applications: applications).first { $0.nameShort == folder }
    }

    /// The name of the folder in ~/Library/Application Support that holds `app`'s `User` folder.
    static func settingsFolder(of app: DetectedApp) -> String {
        ((app.configPath as NSString).deletingLastPathComponent as NSString).lastPathComponent
    }

    static func source(folder: String) -> Source? { sources.first { $0.folder == folder } }

    /// A name usable as one folder name, or nil.
    static func plainName(_ name: String?) -> String? {
        guard let name, !name.isEmpty, name.count <= 100, !name.contains("/"), !name.contains("\0"),
              name != ".", name != "..", !SecretGuard.looksSecret(name) else { return nil }
        return name
    }

    /// A version as product.json gives it ("1.105.1"), or nil for anything else.
    static func version(_ text: String?) -> String? {
        guard let text, !text.isEmpty, text.count <= 40 else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-+"))
        return text.unicodeScalars.allSatisfy(allowed.contains) && !SecretGuard.looksSecret(text) ? text : nil
    }

    /// `relative` inside `folder`, as its real path, if that is a plain file that stays inside the folder's real
    /// path (a symlink out of the folder is never followed).
    static func file(_ relative: String, inside folder: String) -> String? {
        let root = canonicalPath(folder)
        let path = canonicalPath((folder as NSString).appendingPathComponent(relative))
        guard path.hasPrefix(root == "/" ? root : root + "/"), isRegularFile(path) else { return nil }
        return path
    }

    // MARK: detection

    /// The editors whose `User` folder exists, most recently used first: every installed app whose
    /// product.json says it is built on VS Code, then the known ones whose app was removed but whose folder
    /// stayed. Only names, existence and modification dates are looked at: no settings file is opened until
    /// the user picks one.
    static func detectApps(home: String, applications: [String]) -> [DetectedApp] {
        var found: [DetectedApp] = []
        var folders = Set<String>()
        func add(folder: String, product: Product?) {
            guard !folders.contains(folder) else { return }
            let user = (home as NSString).appendingPathComponent("Library/Application Support/\(folder)/User")
            guard isDirectory(user) else { return }
            folders.insert(folder)
            let known = source(folder: folder)
            found.append(DetectedApp(kind: known?.kind ?? .vsCodeFork, name: known?.name ?? folder, configPath: user,
                                     lastUsed: lastUsed(user), appPath: product?.bundle, version: product?.version))
        }
        for product in installedProducts(applications: applications) {
            if let folder = product.nameShort { add(folder: folder, product: product) }
        }
        for source in sources {
            add(folder: source.folder, product: installedBundle(source.bundles, applications: applications))
        }
        // Devin Desktop's folder replaces Windsurf's.
        if found.contains(where: { settingsFolder(of: $0) == "Devin" }) {
            found.removeAll { settingsFolder(of: $0) == "Windsurf" }
        }
        return found.sorted { ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast) }
    }

    /// The first of `bundles` installed in `applications` (its product.json, or a bare one when it has none).
    static func installedBundle(_ bundles: [String], applications: [String]) -> Product? {
        for folder in applications {
            for bundle in bundles {
                let path = (folder as NSString).appendingPathComponent(bundle)
                guard isDirectory(path) else { continue }
                return product(bundle: path) ?? Product(bundle: path, nameShort: nil, dataFolderName: nil, sharedDataFolderName: nil, version: nil)
            }
        }
        return nil
    }

    // MARK: keymap extensions

    /// What a keymap extension says about the shortcuts its user expects.
    enum KeymapKind: Equatable {
        /// JetBrains keys: the JetBrains shortcut set fits.
        case jetBrains
        /// Modal editing, which Next Term doesn't have.
        case vim
        case emacs
        /// Another editor's keys that have no shortcut set here (the editor's name).
        case other(String)
    }

    struct KeymapExtension: Equatable {
        /// How the extension is named in the preview (a fixed label, never the id as read).
        let label: String
        let kind: KeymapKind
    }

    /// Known keymap extensions by id (lowercased, as extensions.json may hold any case).
    static let keymapExtensions: [String: KeymapExtension] = [
        "k--kato.intellij-idea-keybindings": KeymapExtension(label: "IntelliJ IDEA Keybindings", kind: .jetBrains),
        "vscodevim.vim": KeymapExtension(label: "Vim", kind: .vim),
        "asvetliakov.vscode-neovim": KeymapExtension(label: "VSCode Neovim", kind: .vim),
        "tuttieee.emacs-mcx": KeymapExtension(label: "Awesome Emacs Keymap", kind: .emacs),
        "lfs.vscode-emacs-friendly": KeymapExtension(label: "Emacs Friendly Keymap", kind: .emacs),
        "hiro-sun.vscode-emacs": KeymapExtension(label: "Emacs Keymap", kind: .emacs),
        "ms-vscode.atom-keybindings": KeymapExtension(label: "Atom Keymap", kind: .other("Atom")),
        "ms-vscode.vs-keybindings": KeymapExtension(label: "Visual Studio Keymap", kind: .other("Visual Studio")),
        "alphabotsec.vscode-eclipse-keybindings": KeymapExtension(label: "Eclipse Keymap", kind: .other("Eclipse")),
        "ms-vscode.notepadplusplus-keybindings": KeymapExtension(label: "Notepad++ keymap", kind: .other("Notepad++")),
    ]

    /// The keymap extension an id is (a known one, or any id naming IntelliJ or JetBrains keys, as each new
    /// editor gets its own copy of that extension), or nil.
    static func keymapExtension(_ id: String) -> KeymapExtension? {
        let id = id.lowercased()
        if let known = keymapExtensions[id] { return known }
        let jetBrains = id.contains("intellij") || id.contains("jetbrains")
        let keys = id.contains("keybinding") || id.contains("keymap")
        return jetBrains && keys ? KeymapExtension(label: "a JetBrains keymap extension", kind: .jetBrains) : nil
    }

    struct Extensions: Equatable {
        /// Every extension extensions.json lists.
        var count = 0
        /// The keymap extensions among them that are turned on, in the order listed.
        var keymaps: [KeymapExtension] = []
    }

    static let disabledKey = "extensionsIdentifiers/disabled"

    /// The extensions in the first of `dataFolders` (in the home folder) that has an extensions.json: only
    /// each entry's `identifier.id` is read, and only the count and the known keymap extensions are kept.
    /// `user`: the app's `User` folder, whose state.vscdb lists the extensions turned off (one keyed read).
    /// Nil when there is no extensions.json.
    static func extensions(home: String, dataFolders: [String], user: String) -> Extensions? {
        for name in dataFolders {
            guard let folder = plainName(name).map({ (home as NSString).appendingPathComponent($0) }),
                  let path = file("extensions/extensions.json", inside: folder),
                  let text = readText(path, limit: 16 << 20), JSONC.isShallow(text),
                  let entries = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [Any] else { continue }
            var ids: [String] = []
            for case let entry as [String: Any] in entries {
                guard let identifier = entry["identifier"] as? [String: Any], let id = identifier["id"] as? String,
                      !id.isEmpty, id.count <= 200, !ids.contains(id.lowercased()) else { continue }
                ids.append(id.lowercased())
            }
            let disabled = disabledExtensions(user: user)
            let keymaps = ids.filter { !disabled.contains($0) }.compactMap(keymapExtension)
            return Extensions(count: ids.count, keymaps: keymaps)
        }
        return nil
    }

    /// The ids of the extensions turned off in the default profile, from one key of
    /// `User/globalStorage/state.vscdb` (only each entry's `id` is read). Empty when it can't be read.
    static func disabledExtensions(user: String) -> Set<String> {
        let database = (user as NSString).appendingPathComponent("globalStorage/state.vscdb")
        guard isRegularFile(database), case .value(let data) = readItem(database, key: disabledKey),
              let entries = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { return [] }
        var ids = Set<String>()
        for case let entry as [String: Any] in entries {
            if let id = entry["id"] as? String { ids.insert(id.lowercased()) }
        }
        return ids
    }

    static let noVimMode = "Next Term has no Vim mode yet"

    /// What the keymap extensions mean for the plan: the JetBrains set for IntelliJ keys (when the app's
    /// own keymap is VS Code's), a note for modal and other editors' keys, and the rest counted.
    /// `vimSettings`: how many `vim.*` keys settings.json has (a Vim user whose extension is gone).
    static func keymapRows(_ extensions: Extensions?, vimSettings: Int, preset: KeymapPreset) -> (preset: KeymapPreset, skipped: [SkippedItem]) {
        var preset = preset
        var skipped: [SkippedItem] = []
        let keymaps = extensions?.keymaps ?? []
        for keymap in keymaps {
            switch keymap.kind {
            case .jetBrains:
                guard preset == .vsCode else { continue }
                preset = .jetBrains
                skipped.append(SkippedItem("\(keymap.label) extension",
                                           "its own keys aren't read; JetBrains (macOS) shortcuts are offered instead of VS Code’s"))
            case .vim:
                skipped.append(SkippedItem("Vim keys (\(keymap.label) extension)", noVimMode))
            case .emacs:
                skipped.append(SkippedItem("Emacs keys (\(keymap.label) extension)", "Next Term has no Emacs shortcut set"))
            case .other(let editor):
                skipped.append(SkippedItem("\(editor) keys (\(keymap.label) extension)", "Next Term has no \(editor) shortcut set"))
            }
        }
        if vimSettings > 0, !keymaps.contains(where: { $0.kind == .vim }) {
            skipped.append(SkippedItem("Vim keys (\(counted(vimSettings, "vim.* setting")))", noVimMode))
        }
        if let extensions {
            let others = extensions.count - keymaps.count
            if others > 0 {
                skipped.append(SkippedItem(counted(others, keymaps.isEmpty ? "extension" : "other extension"), "extensions aren't imported"))
            }
        }
        return (preset, skipped)
    }
}
