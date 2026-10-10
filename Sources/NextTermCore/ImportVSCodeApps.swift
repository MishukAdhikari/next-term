import Foundation

// Which editors built on VS Code are on this Mac. Read here, and only here: each app bundle's product.json (four
// keys: nameShort, dataFolderName, sharedDataFolderName and version), never shown. A file is read only when its
// real path stays inside the folder it belongs to, so a symlink never leads a read out of it.

extension ImportVSCode {
    /// An editor known by name, found by its settings folder even after the app itself was removed (its
    /// folder stays behind). `folder` is the app's product.json `nameShort`, which names its folder in
    /// ~/Library/Application Support; `dataFolders` its `dataFolderName`, the folder in the home folder that
    /// holds its extensions. Each was checked against the app's own product.json or the folders its
    /// uninstaller removes; an editor whose names couldn't be checked is found only while it is installed.
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
}
