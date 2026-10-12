import Foundation

// iTerm2's dynamic profiles: JSON or plist files in ~/Library/Application Support/iTerm2/DynamicProfiles, each with a
// "Profiles" list. The default profile can be one of them (its Guid isn't in the preferences' own list), so each is
// merged over its parent as iTerm2 merges it, and the default Guid is matched there. Only the profile keys the import
// uses are kept from a file: commands, triggers, key maps and the rest are dropped as soon as it is parsed. Files
// are read only from that folder, never through a link out of it.

extension ImportITerm2 {
    static func dynamicProfilesFolder(home: String) -> String {
        (home as NSString).appendingPathComponent("Library/Application Support/iTerm2/DynamicProfiles")
    }

    /// The keys kept from a dynamic profile: the ones the import reads, and the ones that name it and its parent.
    static let dynamicKeys: Set<String> = {
        var keys = Set(profileKeys + colourKeys)
        for key in colourKeys { keys.insert(key + " (Dark)") }
        keys.formUnion(["Name", "Dynamic Profile Parent Name", "Dynamic Profile Parent GUID"])
        return keys
    }()

    static let dynamicFileLimit = 64

    /// Every dynamic profile, in iTerm2's load order (files by name, then as listed in each), with only
    /// `dynamicKeys` kept; and what couldn't be read.
    static func dynamicProfiles(home: String) -> (profiles: [[String: Any]], skipped: [SkippedItem]) {
        let folder = dynamicProfilesFolder(home: home)
        guard ImportVSCode.isDirectory(folder) else { return ([], []) }
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        var profiles: [[String: Any]] = []
        var skipped: [SkippedItem] = []
        for name in names.prefix(dynamicFileLimit) {
            let shown = SecretGuard.looksSecret(name) ? "a dynamic profile file" : "DynamicProfiles/\(name)"
            guard let path = ImportVSCode.file(name, inside: folder) else {
                let full = (folder as NSString).appendingPathComponent(name)
                if !ImportVSCode.isDirectory(full) { skipped.append(SkippedItem(shown, "it links outside iTerm2's DynamicProfiles folder, so it isn't read")) }
                continue
            }
            guard let data = ImportFile.data(path), data.count <= 4 << 20, let list = profileList(data) else {
                skipped.append(SkippedItem(shown, "couldn't be read"))
                continue
            }
            for profile in list { profiles.append(profile.filter { dynamicKeys.contains($0.key) }) }
        }
        if names.count > dynamicFileLimit {
            skipped.append(SkippedItem("\(names.count - dynamicFileLimit) more dynamic profile files", "at most \(dynamicFileLimit) are read"))
        }
        return (profiles, skipped)
    }

    /// The "Profiles" list of a dynamic profiles file, JSON or a property list.
    static func profileList(_ data: Data) -> [[String: Any]]? {
        let first = data.first { !(" \t\r\n" as String).utf8.contains($0) }
        let root: Any?
        if first == UInt8(ascii: "{") {
            root = try? JSONSerialization.jsonObject(with: data)
        } else {
            root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        }
        guard let dictionary = root as? [String: Any], let list = dictionary["Profiles"] as? [Any] else { return nil }
        return list.compactMap { $0 as? [String: Any] }
    }

    /// Each dynamic profile merged over its parent, by Guid. The parent is the profile `Dynamic Profile Parent GUID`
    /// names, else the first with the `Dynamic Profile Parent Name` (regular profiles first, then dynamic ones
    /// loaded before it), else the default profile. A dynamic profile whose Guid a regular one has is ignored, as
    /// iTerm2 ignores it. A parent must load first, so a loop can't happen.
    static func mergedDynamic(_ dynamic: [[String: Any]], regular: [[String: Any]], defaultProfile: [String: Any]) -> [String: [String: Any]] {
        let regularGuids = Set(regular.compactMap { $0["Guid"] as? String })
        var loaded: [[String: Any]] = []
        var byGuid: [String: [String: Any]] = [:]
        for profile in dynamic {
            guard let guid = profile["Guid"] as? String, !regularGuids.contains(guid), byGuid[guid] == nil else { continue }
            let candidates = regular + loaded
            var parent = defaultProfile
            if let parentGuid = profile["Dynamic Profile Parent GUID"] as? String,
               let found = candidates.first(where: { $0["Guid"] as? String == parentGuid }) {
                parent = found
            } else if let parentName = profile["Dynamic Profile Parent Name"] as? String,
                      let found = candidates.first(where: { $0["Name"] as? String == parentName }) {
                parent = found
            }
            var merged = parent.merging(profile) { $1 }
            merged["Guid"] = guid
            loaded.append(merged)
            byGuid[guid] = merged
        }
        return byGuid
    }

    /// iTerm2 set to load its settings from a folder or URL: a note, without the place (a URL can hold a token).
    static func customFolderNote(_ root: [String: Any]) -> SkippedItem? {
        guard root["LoadPrefsFromCustomFolder"] as? Bool == true else { return nil }
        return SkippedItem("Load settings from a custom folder or URL",
                           "iTerm2 loads them from there when it starts; the copy on this Mac was read, which may be older")
    }
}
