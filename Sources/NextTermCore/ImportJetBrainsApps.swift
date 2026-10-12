import Foundation

// Which JetBrains IDEs are installed, and where an IDE keeps its settings when they were moved. Read here, and
// only here: each app bundle's product-info.json (four keys: name, version, productVendor and dataDirectoryName),
// and the `idea.config.path` line of an idea.properties (the IDE's own, in its usual settings folder, else the
// one in its bundle). A file is read only when its real path stays inside its folder, so a symlink never leads a
// read out of it, and a moved settings folder is taken only from a full path or one that starts with
// ${user.home}: no other variable is expanded and nothing is run.

extension ImportJetBrains {
    /// An installed IDE, as its product-info.json names it.
    struct Installed: Equatable {
        let bundle: String
        /// "PhpStorm", "IntelliJ IDEA", "Android Studio".
        let name: String
        /// "2026.1.1".
        let version: String?
        /// "JetBrains" or "Google": the folder in ~/Library/Application Support that holds its settings folder.
        let vendor: String
        /// "PhpStorm2026.1": its settings folder there.
        let dataDirectoryName: String

        /// "PhpStorm": the settings folder's name without its version.
        var product: String { ImportJetBrains.splitVersion(dataDirectoryName)?.product ?? dataDirectoryName }
    }

    /// The folders in ~/Library/Application Support an IDE's settings folder can be in, with the prefix its
    /// name has there.
    static let vendors: [(vendor: String, prefix: String)] = [("JetBrains", ""), ("Google", "AndroidStudio")]

    /// The IDEs in `applications` (top level only), and in the folder older JetBrains Toolbox releases install
    /// into, by their product-info.json.
    static func installedIDEs(applications: [String], home: String) -> [Installed] {
        var bundles: [String] = []
        for folder in applications {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { continue }
            for name in names.sorted().prefix(2_000) where name.hasSuffix(".app") && !name.hasPrefix(".") {
                bundles.append((folder as NSString).appendingPathComponent(name))
            }
        }
        bundles += toolboxBundles(home: home)
        return bundles.compactMap(installedIDE(bundle:))
    }

    /// `~/Library/Application Support/JetBrains/Toolbox/apps/<tool>/<channel>/<build>/<App>.app`, a few of each.
    static func toolboxBundles(home: String) -> [String] {
        let apps = (home as NSString).appendingPathComponent("Library/Application Support/JetBrains/Toolbox/apps")
        func children(_ folder: String) -> [String] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
            return names.sorted().filter { !$0.hasPrefix(".") }.prefix(50).map { (folder as NSString).appendingPathComponent($0) }
        }
        var bundles: [String] = []
        for tool in children(apps) {
            for channel in children(tool) {
                for build in children(channel) {
                    bundles += children(build).filter { $0.hasSuffix(".app") }
                }
            }
        }
        return bundles
    }

    /// The bundle's product-info.json, if it is a plain file inside it and names a JetBrains or Android Studio
    /// settings folder. Only the four keys are converted; its launch commands and the rest are never looked at.
    static func installedIDE(bundle: String) -> Installed? {
        guard let path = ImportVSCode.file("Contents/Resources/product-info.json", inside: bundle),
              let text = ImportVSCode.readText(path, limit: 1 << 20), let document = JSONC(text),
              case .object(let root)? = document.root else { return nil }
        func string(_ key: String) -> String? {
            guard let member = root.members.last(where: { $0.key == key }), case .scalar = member.value else { return nil }
            return member.value.object(in: text) as? String
        }
        guard let vendor = string("productVendor"), let prefix = vendors.first(where: { $0.vendor == vendor })?.prefix,
              let folder = ImportVSCode.plainName(string("dataDirectoryName")), let parsed = splitVersion(folder),
              parsed.product.hasPrefix(prefix), let name = productName(string("name")) else { return nil }
        return Installed(bundle: bundle, name: name, version: ImportVSCode.version(string("version")), vendor: vendor,
                         dataDirectoryName: folder)
    }

    /// A product's name as product-info.json gives it ("PhpStorm"), or nil for anything that doesn't look like one.
    static func productName(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), (1...60).contains(text.count) else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " .-+()"))
        return text.unicodeScalars.allSatisfy(allowed.contains) && !SecretGuard.looksSecret(text) ? text : nil
    }

    // MARK: idea.config.path

    /// What an idea.properties says about `idea.config.path`.
    enum ConfigPathSetting: Equatable {
        case unset
        /// A full path, canonical, with `${user.home}` expanded.
        case path(String)
        /// Set, but to something this import doesn't follow, with why.
        case unusable(String)
    }

    static let configPathKey = "idea.config.path"

    /// The last `idea.config.path` line of a properties file's text, as Java reads the last one. A value with a
    /// backslash (an escape, or a line that goes on) or any variable but a leading `${user.home}` is not followed.
    static func configPathSetting(_ text: String, home: String) -> ConfigPathSetting {
        var result = ConfigPathSetting.unset
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix(configPathKey) else { continue }
            var rest = Substring(line).dropFirst(configPathKey.count)
            // The key ends at "=", ":" or a space ("idea.config.path.extra" is another key).
            guard let first = rest.first, first == "=" || first == ":" || first == " " || first == "\t" else { continue }
            rest = rest.drop { $0 == " " || $0 == "\t" }
            if rest.first == "=" || rest.first == ":" { rest = rest.dropFirst() }
            result = configPath(String(rest).trimmingCharacters(in: .whitespaces), home: home)
        }
        return result
    }

    static func configPath(_ value: String, home: String) -> ConfigPathSetting {
        guard !value.isEmpty else { return .unset }
        var path = value
        let homeVariable = "${user.home}"
        if path.hasPrefix(homeVariable) { path = home + String(path.dropFirst(homeVariable.count)) }
        guard !path.contains("$"), !path.contains("\\") else { return .unusable("uses a variable; only a full path or ${user.home} is read") }
        guard path.hasPrefix("/") else { return .unusable("only a full path is read") }
        guard !pathLooksSecret(path) else { return .unusable("looked like a credential") }
        return .path(canonicalPath(path))
    }

    /// The setting in the idea.properties at `relative` inside `folder` (nil: no such plain file there).
    static func configPathSetting(file relative: String, inside folder: String, home: String) -> ConfigPathSetting? {
        guard let path = ImportVSCode.file(relative, inside: folder), let text = ImportVSCode.readText(path, limit: 64 << 10) else { return nil }
        return configPathSetting(text, home: home)
    }

    /// Where an IDE keeps its settings when its idea.properties moves them: its own (in the usual settings
    /// folder) decides first, then the one in its bundle. Nil when neither moves them, or to a folder that holds
    /// no settings: then the usual folder is used.
    static func movedConfig(usual: String, bundle: String?, home: String) -> String? {
        var settings = [configPathSetting(file: "idea.properties", inside: usual, home: home)]
        if let bundle { settings.append(configPathSetting(file: "Contents/bin/idea.properties", inside: bundle, home: home)) }
        for case let setting? in settings where setting != .unset {
            guard case .path(let folder) = setting, isDirectory((folder as NSString).appendingPathComponent("options")) else { return nil }
            return folder
        }
        return nil
    }

    /// The usual settings folder's idea.properties sets a path that isn't followed: named in the plan, with why.
    static func unusableConfigPath(config: String, home: String) -> SkippedItem? {
        guard case .unusable(let reason)? = configPathSetting(file: "idea.properties", inside: config, home: home) else { return nil }
        return SkippedItem("\(configPathKey) in idea.properties", reason + ", so the settings here were read")
    }
}
