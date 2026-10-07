import Foundation

/// What the review sheet shows about a skill before it is installed: every file, what the skill may do
/// in an agent, and anything risky, found offline from the files themselves. Nothing here decides for
/// the user: refusals are only for what can never be safe (a link out of the skill, a name agents skip).
public struct SkillReview: Sendable {
    public struct File: Equatable, Sendable {
        public let path: String
        public let size: Int
        public let executable: Bool
        public let script: Bool
        /// A compiled program (Mach-O or ELF).
        public let binary: Bool
        /// For a link: where it points.
        public let linkTarget: String?
    }

    public enum Level: Int, Comparable, Sendable {
        case note, warning, refuse
        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    public struct Flag: Equatable, Sendable {
        public let level: Level
        public let file: String
        public let text: String
    }

    public let name: String
    public let frontMatter: SkillFrontMatter?
    /// SKILL.md as written, untouched.
    public let skillText: String
    public let files: [File]
    public let flags: [Flag]
    /// What the skill may do in an agent, in plain words.
    public let capabilities: [String]
    /// Every web address the skill's files mention (fetched at run time, outside the pinned commit).
    public let urls: [String]
    /// The first line of the skill's own licence file (LICENSE, LICENSE.txt, …): "Apache License", say.
    public let licenseFile: String?

    /// The licence as stated: SKILL.md's `license` field, else the skill's licence file.
    public var license: String? {
        if let stated = frontMatter?.license?.trimmingCharacters(in: .whitespaces), !stated.isEmpty { return stated }
        return licenseFile
    }

    /// The licence keeps rights back (Anthropic's document skills are "All rights reserved"): reading it
    /// matters before using or sharing the skill.
    public var licenseIsRestrictive: Bool {
        [frontMatter?.license, licenseFile].compactMap { $0?.lowercased() }.contains { $0.contains("proprietary") || $0.contains("all rights reserved") }
    }

    public var refused: Bool { flags.contains { $0.level == .refuse } }

    /// Reads a skill folder that has been downloaded but not installed. `folderName` is the name it will
    /// be installed under.
    public static func review(folder: String, folderName: String) -> SkillReview {
        let manager = FileManager.default
        var files: [File] = []
        var flags: [Flag] = []
        var urls = Set<String>()
        let skillFile = ["SKILL.md", "skill.md"].first { manager.fileExists(atPath: (folder as NSString).appendingPathComponent($0)) }
        let skillText = skillFile.flatMap { try? String(contentsOfFile: (folder as NSString).appendingPathComponent($0), encoding: .utf8) } ?? ""
        let front = SkillFrontMatter.parse(skillText)
        if skillFile == nil { flags.append(Flag(level: .refuse, file: "SKILL.md", text: "There is no SKILL.md: this folder is not a skill.")) }
        var nameProblem: String?
        if let front { nameProblem = front.problem(folder: folderName) } else if skillFile != nil { nameProblem = "SKILL.md has no front matter (name and description)." }
        if let nameProblem { flags.append(Flag(level: .refuse, file: "SKILL.md", text: nameProblem + " Command Code would skip it.")) }

        let walker = manager.enumerator(atPath: folder)
        var total = 0
        var executables: [String] = []
        while let relative = walker?.nextObject() as? String {
            let full = (folder as NSString).appendingPathComponent(relative)
            var info = stat()
            guard lstat(full, &info) == 0 else { continue }
            let type = info.st_mode & S_IFMT
            if type == S_IFDIR { continue }
            if type == S_IFLNK {
                let target = (try? manager.destinationOfSymbolicLink(atPath: full)) ?? ""
                files.append(File(path: relative, size: 0, executable: false, script: false, binary: false, linkTarget: target))
                if !linkStaysInside(relative: relative, target: target) {
                    flags.append(Flag(level: .refuse, file: relative, text: "A link that points outside the skill (\(target))."))
                }
                continue
            }
            guard type == S_IFREG else {
                flags.append(Flag(level: .refuse, file: relative, text: "Not a regular file."))
                continue
            }
            let size = Int(info.st_size)
            total += size
            let data = manager.contents(atPath: full) ?? Data()
            let executable = info.st_mode & 0o111 != 0
            let binary = isBinaryProgram(data)
            let ext = (relative as NSString).pathExtension.lowercased()
            let script = scriptExtensions.contains(ext) || data.starts(with: Data("#!".utf8))
            files.append(File(path: relative, size: size, executable: executable, script: script, binary: binary, linkTarget: nil))
            if binary { flags.append(Flag(level: .warning, file: relative, text: "A compiled program.")) }
            else if executable { executables.append(relative) }
            if size > 1_000_000 { flags.append(Flag(level: .warning, file: relative, text: "A large file (\(size / 1000) KB).")) }
            if packedExtensions.contains(ext) { flags.append(Flag(level: .warning, file: relative, text: "An archive: its contents are not reviewed here.")) }
            guard !binary, let text = String(data: data, encoding: .utf8) else { continue }
            flags += textFlags(text, file: relative, readByAgents: readByAgentsExtensions.contains(ext))
            for url in findURLs(text) { urls.insert(url) }
        }
        if total > 20_000_000 { flags.append(Flag(level: .warning, file: "", text: "The skill is large (\(total / 1_000_000) MB).")) }
        if !executables.isEmpty {
            // Scripts that are marked executable are usual; listed once, as a note.
            let listed = executables.sorted().prefix(5).joined(separator: ", ") + (executables.count > 5 ? ", …" : "")
            flags.append(Flag(level: .note, file: "", text: "\(executables.count) executable file\(executables.count == 1 ? "" : "s"): \(listed)."))
        }
        let licenseFile = ["LICENSE", "LICENSE.txt", "LICENSE.md", "COPYING"].lazy
            .compactMap { try? String(contentsOfFile: (folder as NSString).appendingPathComponent($0), encoding: .utf8) }
            .compactMap { $0.split(separator: "\n").lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } }
            .first.map { String($0.prefix(100)) }
        return SkillReview(name: folderName, frontMatter: front, skillText: skillText, files: files.sorted { $0.path < $1.path },
                           flags: flags.sorted { $0.level > $1.level }, capabilities: capabilities(front: front, skillText: skillText, files: files),
                           urls: urls.sorted(), licenseFile: licenseFile)
    }

    static let scriptExtensions: Set<String> = ["sh", "bash", "zsh", "fish", "py", "js", "mjs", "cjs", "ts", "rb", "pl", "php", "ps1", "command", "applescript", "scpt"]
    static let packedExtensions: Set<String> = ["zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "jar", "whl", "dmg", "pkg"]
    /// Files an agent reads as instructions (SKILL.md and the notes it points to), where an HTML comment
    /// is text the agent sees and a rendered view hides. In HTML or code, `<!--` is ordinary.
    static let readByAgentsExtensions: Set<String> = ["md", "markdown", "mdx", "txt", ""]

    /// A link is fine when it resolves inside the skill folder.
    static func linkStaysInside(relative: String, target: String) -> Bool {
        if target.hasPrefix("/") { return false }
        var parts = relative.split(separator: "/").dropLast().map(String.init)
        for piece in target.split(separator: "/") {
            if piece == ".." {
                if parts.isEmpty { return false }
                parts.removeLast()
            } else if piece != "." {
                parts.append(String(piece))
            }
        }
        return true
    }

    static func isBinaryProgram(_ data: Data) -> Bool {
        let magic: [[UInt8]] = [[0xCF, 0xFA, 0xED, 0xFE], [0xCE, 0xFA, 0xED, 0xFE], [0xCA, 0xFE, 0xBA, 0xBE], [0x7F, 0x45, 0x4C, 0x46]]
        return magic.contains { data.starts(with: $0) }
    }

    /// Hidden characters, HTML comments, and commands that fetch and run code that the commit does not hold.
    static func textFlags(_ text: String, file: String, readByAgents: Bool = true) -> [Flag] {
        var flags: [Flag] = []
        let hidden = text.unicodeScalars.filter(isHidden)
        if !hidden.isEmpty {
            let kinds = Set(hidden.map(hiddenKind)).sorted().joined(separator: ", ")
            flags.append(Flag(level: .warning, file: file, text: "\(hidden.count) hidden characters (\(kinds)). They are shown in the text below."))
        }
        if readByAgents, text.contains("<!--") { flags.append(Flag(level: .warning, file: file, text: "An HTML comment: text agents read but rendered Markdown hides.")) }
        let lower = text.lowercased()
        let patterns: [(String, String)] = [
            (#"(curl|wget)[^\n|]*\|\s*(sudo\s+)?(sh|bash|zsh|python3?)\b"#, "Downloads a script and runs it (curl … | sh)."),
            // A package name with no @version after it (a scope's leading @ is part of the name).
            (#"\bnpx\s+(-y\s+|--yes\s+)?@?[a-z0-9][a-z0-9/_.-]*(\s|$)"#, "Runs an npm package without a pinned version (npx)."),
            (#"\b(uvx|pipx run)\s+[a-z0-9_.-]+(\s|$)"#, "Runs a Python package without a pinned version."),
            (#"\bpip3?\s+install\s+(?!-r)[a-z0-9_.-]+(\s|$)"#, "Installs a Python package without a pinned version."),
            (#"base64\s+(-d|--decode)[^\n]*\|\s*(sh|bash|eval)"#, "Decodes hidden text and runs it."),
            (#"\beval\s*\(?\s*\$?\(?\s*(atob|base64)"#, "Decodes hidden text and runs it."),
            (#"(~|\$home)/\.(ssh|aws|gnupg|config/gh|netrc|docker/config)"#, "Mentions a folder that holds credentials."),
            // A .env file, not code's `process.env`.
            (#"\b(id_rsa|id_ed25519|keychain)|(?<![\w])\.env\b"#, "Mentions keys or secrets."),
        ]
        for (pattern, message) in patterns where lower.range(of: pattern, options: .regularExpression) != nil {
            flags.append(Flag(level: .warning, file: file, text: message))
        }
        return flags
    }

    /// Unicode Tags (invisible ASCII), zero-width characters, and direction overrides.
    static func isHidden(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        return (0xE0000...0xE007F).contains(v) || (0x200B...0x200F).contains(v) || (0x2060...0x2064).contains(v)
            || v == 0xFEFF || (0x202A...0x202E).contains(v) || (0x2066...0x2069).contains(v)
    }

    static func hiddenKind(_ scalar: Unicode.Scalar) -> String {
        let v = scalar.value
        if (0xE0000...0xE007F).contains(v) { return "invisible tag letters" }
        if (0x202A...0x202E).contains(v) || (0x2066...0x2069).contains(v) { return "direction overrides" }
        return "zero-width"
    }

    /// The text with every hidden character written out, so the user sees it: ⟦U+200B⟧.
    public static func revealHidden(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            if isHidden(scalar) { out += String(format: "⟦U+%04X⟧", scalar.value) } else { out.unicodeScalars.append(scalar) }
        }
        return out
    }

    static func findURLs(_ text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"https?://[^\s"'<>()\[\]`]+"#) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { Range($0.range, in: text).map { String(text[$0]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:")) } }
    }

    /// In plain words, what the skill may do once installed (Claude Code and Command Code honour
    /// most of these).
    static func capabilities(front: SkillFrontMatter?, skillText: String, files: [File]) -> [String] {
        var items: [String] = []
        let keys = Set(front?.keys ?? [])
        if let tools = front?.allowedTools, !tools.isEmpty { items.append("Runs these tools without asking while it is used: \(tools)") }
        if keys.contains("hooks") { items.append("Adds hooks that run commands for the rest of the session (Claude Code).") }
        if skillText.contains("!`") { items.append("Runs shell commands before the agent reads it (!`…` lines).") }
        if keys.contains("disable-model-invocation") { items.append("Is used only when you name it.") } else { items.append("The agent may use it on its own when the task fits its description.") }
        if keys.contains("context") || keys.contains("agent") { items.append("Runs in a separate agent context.") }
        if keys.contains("mcpServers") { items.append("Asks for MCP servers.") }
        let scripts = files.filter { $0.script || $0.executable || $0.binary }.count
        if scripts > 0 { items.append("Brings \(scripts) file\(scripts == 1 ? "" : "s") that can run (scripts or programs); the agent runs them only through its own tools.") }
        return items
    }
}
