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
        let skillText = skillFile.flatMap { FileManager.default.contents(atPath: (folder as NSString).appendingPathComponent($0)) }
            .map { String(decoding: $0, as: UTF8.self) } ?? ""
        let front = SkillFrontMatter.parse(skillText)
        if skillFile == nil { flags.append(Flag(level: .refuse, file: "SKILL.md", text: "There is no SKILL.md: this folder is not a skill.")) }
        var nameProblem: String?
        if let front { nameProblem = front.problem(folder: folderName) } else if skillFile != nil { nameProblem = "SKILL.md has no front matter (name and description)." }
        if let nameProblem { flags.append(Flag(level: .refuse, file: "SKILL.md", text: nameProblem + " Command Code would skip it.")) }

        let walker = manager.enumerator(atPath: folder)
        let realFolder = realPath(folder)
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
                if let problem = linkProblem(full: full, relative: relative, target: target, realFolder: realFolder) {
                    flags.append(Flag(level: .refuse, file: relative, text: problem))
                }
                continue
            }
            guard type == S_IFREG else {
                flags.append(Flag(level: .refuse, file: relative, text: "Not a regular file."))
                continue
            }
            let size = Int(info.st_size)
            total += size
            let ext = (relative as NSString).pathExtension.lowercased()
            // Python runs a cached .pyc instead of the .py beside it, and a .pyc can't be read here: what
            // would run is not what was reviewed. A repository never needs them.
            if relative.split(separator: "/").contains("__pycache__") || ext == "pyc" || ext == "pyo" {
                flags.append(Flag(level: .refuse, file: relative, text: "Compiled Python: Python runs it instead of the reviewed .py next to it, and it can't be shown."))
            }
            // Files too large to read here whole are flagged rather than read.
            let readable = size <= maxReadSize
            let data = readable ? (manager.contents(atPath: full) ?? Data()) : (FileHandle(forReadingAtPath: full)?.readData(ofLength: 4) ?? Data())
            let executable = info.st_mode & 0o111 != 0
            let binary = isBinaryProgram(data)
            let script = scriptExtensions.contains(ext) || data.starts(with: Data("#!".utf8))
            files.append(File(path: relative, size: size, executable: executable, script: script, binary: binary, linkTarget: nil))
            if binary { flags.append(Flag(level: .warning, file: relative, text: "A compiled program.")) }
            else if executable { executables.append(relative) }
            if !readable {
                flags.append(Flag(level: .warning, file: relative, text: "A large file (\(size / 1_000_000) MB): too large to check here."))
                continue
            }
            if size > 1_000_000 { flags.append(Flag(level: .warning, file: relative, text: "A large file (\(size / 1000) KB).")) }
            if packedExtensions.contains(ext) { flags.append(Flag(level: .warning, file: relative, text: "An archive: its contents are not reviewed here.")) }
            guard !binary else { continue }
            // Checked even when not valid UTF-8 (one bad byte must not hide a script's lines from the checks).
            let text = String(decoding: data, as: UTF8.self)
            if String(data: data, encoding: .utf8) == nil, script || executable {
                flags.append(Flag(level: .warning, file: relative, text: "Not valid UTF-8: shown with replacement characters."))
            }
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

    /// Files larger than this are flagged, not read.
    static let maxReadSize = 5_000_000

    static func realPath(_ path: String) -> String {
        guard let real = realpath(path, nil) else { return path }
        defer { free(real) }
        return String(cString: real)
    }

    /// Why a link in the skill is refused, or nil. Checked as written, then on disk: a link may pass
    /// through other links (`up -> self/..`), so only where it really ends counts. Links to links and
    /// links to nothing are refused too: what a link means then depends on where the folder sits.
    static func linkProblem(full: String, relative: String, target: String, realFolder: String) -> String? {
        if !linkStaysInside(relative: relative, target: target) { return "A link that points outside the skill (\(target))." }
        guard let pointer = realpath(full, nil) else { return "A link to nothing (\(target))." }
        let resolved = String(cString: pointer)
        free(pointer)
        if !resolved.hasPrefix(realFolder + "/") { return "A link that points outside the skill (\(target))." }
        let folder = (full as NSString).deletingLastPathComponent
        let first = target.hasPrefix("/") ? target : (folder as NSString).appendingPathComponent(target)
        var info = stat()
        if lstat(first, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK { return "A link to another link (\(target))." }
        // A link to a folder that holds the link itself makes a loop.
        if (realPath(folder) + "/").hasPrefix(resolved + "/") { return "A link to a folder that holds it (\(target))." }
        return nil
    }

    /// A link is fine, as written, when it resolves inside the skill folder.
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

    /// Mach-O, fat, ELF and WebAssembly.
    static func isBinaryProgram(_ data: Data) -> Bool {
        let magic: [[UInt8]] = [[0xCF, 0xFA, 0xED, 0xFE], [0xCE, 0xFA, 0xED, 0xFE], [0xCA, 0xFE, 0xBA, 0xBE], [0x7F, 0x45, 0x4C, 0x46], [0x00, 0x61, 0x73, 0x6D]]
        return magic.contains { data.starts(with: $0) }
    }

    /// Hidden characters, HTML comments, and commands that fetch and run code that the commit does not hold.
    static func textFlags(_ text: String, file: String, readByAgents: Bool = true) -> [Flag] {
        var flags: [Flag] = []
        let scalars = Array(text.unicodeScalars)
        let mask = hiddenMask(scalars)
        let hidden = scalars.indices.filter { mask[$0] }.map { scalars[$0] }
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

    /// Characters that draw as nothing, or reorder what is drawn: Unicode Tags (invisible ASCII),
    /// zero-width characters, direction overrides, the variation selectors' supplement (which can carry
    /// hidden bytes), and invisible fillers.
    static func isHidden(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        return (0xE0000...0xE007F).contains(v) || (0x200B...0x200F).contains(v) || (0x2060...0x2064).contains(v)
            || v == 0xFEFF || (0x202A...0x202E).contains(v) || (0x2066...0x2069).contains(v)
            || (0xE0100...0xE01EF).contains(v) || v == 0x00AD || v == 0x034F || v == 0x115F || v == 0x1160
            || (0x180B...0x180F).contains(v) || v == 0x3164 || v == 0xFFA0
    }

    /// Which scalars are hidden. A variation selector (U+FE00–FE0F) is ordinary right after an emoji
    /// (it picks the emoji's style); anywhere else, or doubled, it is hidden.
    static func hiddenMask(_ scalars: [Unicode.Scalar]) -> [Bool] {
        scalars.indices.map { index in
            let scalar = scalars[index]
            if isHidden(scalar) { return true }
            guard (0xFE00...0xFE0F).contains(scalar.value) else { return false }
            guard index > 0 else { return true }
            let previous = scalars[index - 1]
            return (0xFE00...0xFE0F).contains(previous.value) || !previous.properties.isEmoji
        }
    }

    static func hiddenKind(_ scalar: Unicode.Scalar) -> String {
        let v = scalar.value
        if (0xE0000...0xE007F).contains(v) { return "invisible tag letters" }
        if (0x202A...0x202E).contains(v) || (0x2066...0x2069).contains(v) { return "direction overrides" }
        if (0xE0100...0xE01EF).contains(v) || (0xFE00...0xFE0F).contains(v) || (0x180B...0x180F).contains(v) { return "variation selectors" }
        if v == 0x00AD || v == 0x034F || v == 0x115F || v == 0x1160 || v == 0x3164 || v == 0xFFA0 { return "invisible fillers" }
        return "zero-width"
    }

    /// The text with every hidden character written out, so the user sees it: ⟦U+200B⟧.
    public static func revealHidden(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        let mask = hiddenMask(scalars)
        var out = String.UnicodeScalarView()
        for (index, scalar) in scalars.enumerated() {
            if mask[index] { out.append(contentsOf: String(format: "⟦U+%04X⟧", scalar.value).unicodeScalars) } else { out.append(scalar) }
        }
        return String(out)
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
