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
        /// A compiled program, not named as text or a script: reviewed as a program.
        public let binary: Bool
        /// A compiled program by its header, whatever its name.
        public let program: Bool
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
    /// The plugin or extension the folder also is, with what its Claude Code plugin would start; nil for
    /// a plain skill.
    public let package: SkillPackage?
    /// The MCP servers each agent would use: Claude Code's plugin, Codex's agents/openai.yaml, Amp's
    /// front matter or mcp.json.
    public let servers: SkillServers

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
    /// be installed under; `home` expands `~` in a plugin manifest's paths (without it they count as
    /// outside the folder).
    public static func review(folder: String, folderName: String, home: String? = nil) -> SkillReview {
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
        // Read before the walk: the files a row lists as declaring servers get no second warning for them.
        let package = SkillPackage.read(folder: folder, folderName: folderName, home: home)
        let servers = SkillServers.read(folder: folder, skillText: skillText, skillFile: skillFile ?? "SKILL.md", package: package)
        let listed = serverFiles(folder: folder, package: package, servers: servers)
        let skillFileKey = (skillFile ?? "SKILL.md").lowercased()

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
                files.append(File(path: relative, size: 0, executable: false, script: false, binary: false, program: false, linkTarget: target))
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
            let data = readable ? (manager.contents(atPath: full) ?? Data()) : (FileHandle(forReadingAtPath: full)?.readData(ofLength: 4096) ?? Data())
            let executable = info.st_mode & 0o111 != 0
            // The header decides what a file is: a program is one whose whole header holds together
            // (magic bytes in front of text, which zsh still runs line by line, don't make one). The name
            // decides only how its text is checked: one named as text or a script keeps every text check.
            let looksBinary = isBinaryProgram(data)
            let program = looksBinary && isProgramHeader(data, size: size)
            let binary = program && !textExtensions.contains(ext)
            let script = scriptExtensions.contains(ext) || data.starts(with: Data("#!".utf8))
            files.append(File(path: relative, size: size, executable: executable, script: script, binary: binary, program: program, linkTarget: nil))
            if program {
                let named = "A compiled program, though named like text or a script: run directly, it runs as a program. It is checked as text below."
                flags.append(Flag(level: .warning, file: relative, text: binary ? "A compiled program." : named))
            } else if executable {
                executables.append(relative)
            }
            if looksBinary, !program {
                flags.append(Flag(level: .warning, file: relative, text: "Starts like a compiled program but is text: it is shown below."))
            }
            // Named by its extension, so a packed file too large to read is still called one (bundles often are).
            if packedExtensions.contains(ext) {
                let packed = bundleExtensions.contains(ext) ? bundleText : "An archive: its contents are not reviewed here."
                flags.append(Flag(level: .warning, file: relative, text: packed))
            }
            if !readable {
                let text = "A large file (\(size / 1_000_000) MB): too large to check here, so no command or server setting in it was checked."
                flags.append(Flag(level: .warning, file: relative, text: text))
                continue
            }
            if size > 1_000_000 { flags.append(Flag(level: .warning, file: relative, text: "A large file (\(size / 1000) KB).")) }
            // Checked even when not valid UTF-8 (one bad byte must not hide a script's lines from the checks).
            let text = String(decoding: data, as: UTF8.self)
            guard !binary else {
                // A shell may still run lines after a program's header, and an agent may read them: the
                // command checks run on its printable runs (what `strings` shows), and the hidden-character
                // check on its text runs. Decoding a whole program is slow, and its bytes read as hidden
                // characters.
                flags += commandFlags(printableRuns(data).lowercased(), file: relative)
                flags += hiddenFlags(textRuns(data), file: relative)
                continue
            }
            if String(data: data, encoding: .utf8) == nil {
                flags.append(Flag(level: .warning, file: relative, text: "Not valid UTF-8: shown with replacement characters."))
            }
            // A JSON file Next Term reads is checked for its servers; any other falls back to the prose patterns.
            let serverJSON = ext == "json" ? serverJSONFlags(data, file: relative) : nil
            let frontMatterRead = relative.lowercased() == skillFileKey && servers.frontMatterServersRead
            flags += textFlags(text, file: relative, readByAgents: readByAgentsExtensions.contains(ext), listed: listed,
                               frontMatterRead: frontMatterRead, quotedJSON: serverJSON == nil)
            flags += serverJSON ?? []
            // A program's addresses from its text runs: decoded whole, its code signature reads as junk, and
            // printable ASCII alone would cut an address at its first non-ASCII letter (a look-alike host).
            let found = findURLs(program ? textRuns(data, minimum: 4) : text)
            for url in found { urls.insert(url) }
            if found.contains(where: isBundleAddress) { flags.append(Flag(level: .warning, file: relative, text: bundleLinkText)) }
        }
        if total > 20_000_000 { flags.append(Flag(level: .warning, file: "", text: "The skill is large (\(total / 1_000_000) MB).")) }
        if !executables.isEmpty {
            // Scripts that are marked executable are usual; listed once, as a note.
            let listed = executables.sorted().prefix(5).joined(separator: ", ") + (executables.count > 5 ? ", …" : "")
            flags.append(Flag(level: .note, file: "", text: "\(executables.count) executable file\(executables.count == 1 ? "" : "s"): \(listed)."))
        }
        // The license file's first line. Step by step: as one chain this is slow for Swift 6.1's type checker.
        var licenseFile: String?
        for name in ["LICENSE", "LICENSE.txt", "LICENSE.md", "COPYING"] where licenseFile == nil {
            guard let text = try? String(contentsOfFile: (folder as NSString).appendingPathComponent(name), encoding: .utf8) else { continue }
            let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            if let first = lines.first(where: { !$0.isEmpty }) { licenseFile = String(first.prefix(100)) }
        }
        flags += package?.flags ?? []
        flags += servers.flags
        // One server file can be read for two agents (Amp's mcp.json is also Cursor's): each flag once.
        var seen = Set<String>()
        flags = flags.filter { seen.insert("\($0.level.rawValue)\u{0}\($0.file)\u{0}\($0.text)").inserted }
        let said = capabilities(front: front, skillText: skillText, files: files, package: package, servers: servers)
        return SkillReview(name: folderName, frontMatter: front, skillText: skillText, files: files.sorted { $0.path < $1.path },
                           flags: flags.sorted { $0.level > $1.level }, capabilities: said,
                           urls: urls.sorted(), licenseFile: licenseFile, package: package, servers: servers)
    }

    static let scriptExtensions: Set<String> = ["sh", "bash", "zsh", "fish", "py", "js", "mjs", "cjs", "ts", "rb", "pl", "php", "ps1", "command", "applescript", "scpt"]
    static let packedExtensions: Set<String> = ["zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "jar", "whl", "dmg", "pkg", "mcpb", "dxt"]
    /// MCP bundles: packed servers that Claude Code unpacks and runs (`.dxt` is the older name).
    static let bundleExtensions: Set<String> = ["mcpb", "dxt"]
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

    /// Names that are text or scripts: reviewed as text whatever their first bytes.
    static let textExtensions: Set<String> = scriptExtensions.union(["md", "markdown", "mdx", "txt", "json", "yaml", "yml", "toml",
                                                                    "html", "htm", "css", "xml", "csv", "ini", "cfg"])

    /// Whether the header after the magic number holds together as a Mach-O (thin or fat), ELF,
    /// WebAssembly or Java class file of `size` bytes. Four magic bytes followed by text don't.
    static func isProgramHeader(_ data: Data, size: Int) -> Bool {
        let bytes = Array(data.prefix(4096))
        func little(_ at: Int) -> Int {
            guard at + 4 <= bytes.count else { return -1 }
            return Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24
        }
        func big(_ at: Int) -> Int {
            guard at + 4 <= bytes.count else { return -1 }
            return Int(bytes[at]) << 24 | Int(bytes[at + 1]) << 16 | Int(bytes[at + 2]) << 8 | Int(bytes[at + 3])
        }
        let cpus: Set<Int> = [7, 0x0100_0007, 12, 0x0100_000C, 0x0200_000C, 18, 0x0100_0012]
        switch Array(bytes.prefix(4)) {
        case [0xCF, 0xFA, 0xED, 0xFE], [0xCE, 0xFA, 0xED, 0xFE]:
            // Mach-O: a known CPU, a known file type, and load commands that fit in the file.
            let header = bytes[0] == 0xCF ? 32 : 28
            let commands = little(16), commandBytes = little(20)
            return cpus.contains(little(4)) && (1...12).contains(little(12)) && commands > 0 && commandBytes > 0
                && header + commandBytes <= size
        case [0xCA, 0xFE, 0xBA, 0xBE]:
            let count = big(4)
            if (1...16).contains(count) {
                // Fat: every slice is a known CPU, inside the file.
                return (0..<count).allSatisfy { index in
                    let at = 8 + index * 20
                    return cpus.contains(big(at)) && big(at + 8) > 0 && big(at + 8) + big(at + 12) <= size
                }
            }
            // A Java class file shares the magic: a version from Java 1.1 on.
            guard bytes.count >= 8 else { return false }
            let major = Int(bytes[6]) << 8 | Int(bytes[7])
            return (45...100).contains(major)
        case [0x7F, 0x45, 0x4C, 0x46]:
            // ELF: 32 or 64 bits, either byte order, version 1, a known file type.
            guard bytes.count >= 24, [1, 2].contains(bytes[4]), [1, 2].contains(bytes[5]), bytes[6] == 1 else { return false }
            let type = bytes[5] == 1 ? Int(bytes[16]) | Int(bytes[17]) << 8 : Int(bytes[16]) << 8 | Int(bytes[17])
            let version = bytes[5] == 1 ? little(20) : big(20)
            return (1...4).contains(type) && version == 1
        case [0x00, 0x61, 0x73, 0x6D]:
            return little(4) == 1 // WebAssembly version 1
        default:
            return false
        }
    }

    /// Mach-O, fat, ELF and WebAssembly.
    static func isBinaryProgram(_ data: Data) -> Bool {
        let magic: [[UInt8]] = [[0xCF, 0xFA, 0xED, 0xFE], [0xCE, 0xFA, 0xED, 0xFE], [0xCA, 0xFE, 0xBA, 0xBE], [0x7F, 0x45, 0x4C, 0x46], [0x00, 0x61, 0x73, 0x6D]]
        return magic.contains { data.starts(with: $0) }
    }

    /// Hidden characters, HTML comments, commands that fetch and run code that the commit does not hold or
    /// add MCP servers, and MCP server settings in a file that no row of the review lists.
    /// - `listed`: the lowercased paths a row lists as declaring servers (`serverFiles`).
    /// - `frontMatterRead`: the file is SKILL.md, and the Amp row shows its front matter's `mcpServers`, so
    ///   only the text after the front matter is checked for server settings.
    /// - `quotedJSON`: check server JSON quoted in the text; off for a JSON file the server check read.
    static func textFlags(_ text: String, file: String, readByAgents: Bool = true, listed: Set<String> = [],
                          frontMatterRead: Bool = false, quotedJSON: Bool = true) -> [Flag] {
        var flags = hiddenFlags(text, file: file)
        if readByAgents, text.contains("<!--") { flags.append(Flag(level: .warning, file: file, text: "An HTML comment: text agents read but rendered Markdown hides.")) }
        let lower = text.lowercased()
        flags += commandFlags(lower, file: file, quotedJSON: quotedJSON)
        if !listed.contains(file.lowercased()) {
            flags += settingsFlags(frontMatterRead ? afterFrontMatter(lower) : lower, file: file)
        }
        return flags
    }

    /// Characters that draw as nothing, counted by kind.
    static func hiddenFlags(_ text: String, file: String) -> [Flag] {
        let scalars = Array(text.unicodeScalars)
        let mask = hiddenMask(scalars)
        let hidden = scalars.indices.filter { mask[$0] }.map { scalars[$0] }
        guard !hidden.isEmpty else { return [] }
        let kinds = Set(hidden.map(hiddenKind)).sorted().joined(separator: ", ")
        return [Flag(level: .warning, file: file, text: "\(hidden.count) hidden characters (\(kinds)). They are shown in the text below.")]
    }

    /// Runs of at least `minimum` printable ASCII bytes (and tabs), one per line: what `strings` shows.
    static func printableRuns(_ data: Data, minimum: Int = 4) -> String {
        var out: [UInt8] = []
        var run: [UInt8] = []
        for byte in data {
            if (0x20...0x7E).contains(byte) || byte == 0x09 {
                run.append(byte)
                continue
            }
            if run.count >= minimum { out += run + [0x0A] }
            run.removeAll(keepingCapacity: true)
        }
        if run.count >= minimum { out += run }
        return String(decoding: out, as: UTF8.self)
    }

    /// A program's text runs: at least `minimum` scalars with no control character (C0 but tab and line
    /// breaks, DEL, C1) and no replacement character: what an agent reads, or zsh runs, after a header.
    /// Line breaks don't end a run, so text cut into short lines is still checked. Tag letters and the
    /// variation selectors supplement from runs too short to keep are kept once a program holds at least
    /// four of them: machine code forms one now and then (F3 A0 80 86 in an ARM program), hidden words more.
    static func textRuns(_ data: Data, minimum: Int = 16) -> String {
        var out = String.UnicodeScalarView()
        var run: [Unicode.Scalar] = []
        var carriers = 0
        var stray = String.UnicodeScalarView()
        func close() {
            if run.count >= minimum {
                out.append(contentsOf: run)
                out.append("\n")
            } else if carriers > 0 {
                stray.append(contentsOf: run.filter { (0xE0000...0xE01EF).contains($0.value) })
            }
            run.removeAll(keepingCapacity: true)
            carriers = 0
        }
        for scalar in String(decoding: data, as: UTF8.self).unicodeScalars {
            let v = scalar.value
            let printable = (v >= 0x20 && v < 0x7F) || v == 0x09 || v == 0x0A || v == 0x0D
            if printable || (v > 0x9F && v != 0xFFFD) {
                run.append(scalar)
                if (0xE0000...0xE01EF).contains(v) { carriers += 1 }
                continue
            }
            close()
        }
        close()
        if stray.count >= 4 {
            out.append(contentsOf: stray)
            out.append("\n")
        }
        return String(out)
    }

    /// Commands that fetch and run code the commit does not hold, add MCP servers or plugins, or reach for
    /// credentials. `quotedJSON`: also server JSON quoted in the text (`"command": "npx", "args": […]`).
    static func commandFlags(_ lower: String, file: String, quotedJSON: Bool = true) -> [Flag] {
        var flags: [Flag] = []
        var patterns: [(String, String)] = [
            (#"(curl|wget)[^\n|]*\|\s*(sudo\s+)?(sh|bash|zsh|python3?)\b"#, "Downloads a script and runs it (curl … | sh)."),
            (unpinnedNPX, "Runs an npm package without a pinned version (npx)."),
            (unpinnedPython, "Runs a Python package without a pinned version."),
            (#"\bpip3?\s+install\s+(?!-r)[a-z0-9_.-]+(\s|$)"#, "Installs a Python package without a pinned version."),
            (#"base64\s+(-d|--decode)[^\n]*\|\s*(sh|bash|eval)"#, "Decodes hidden text and runs it."),
            (#"\beval\s*\(?\s*\$?\(?\s*(atob|base64)"#, "Decodes hidden text and runs it."),
            (#"(~|\$home)/\.(ssh|aws|gnupg|config/gh|netrc|docker/config)"#, "Mentions a folder that holds credentials."),
            // A .env file, not code's `process.env`.
            (#"\b(id_rsa|id_ed25519|keychain)|(?<![\w])\.env\b"#, "Mentions keys or secrets."),
            (mcpAdd, "Adds an MCP server to an agent's settings (… mcp add)."),
            (pluginInstall, "Installs a plugin or extension, which can bring its own MCP servers and hooks."),
        ]
        if quotedJSON {
            for quoted in quotedServerPatterns where quoted.words.contains(where: { lower.contains($0) }) {
                patterns.append((quoted.pattern, unpinnedServerText))
            }
        }
        for (pattern, message) in patterns where lower.range(of: pattern, options: .regularExpression) != nil {
            // One flag per message: two quoted server forms say the same thing.
            if !flags.contains(where: { $0.text == message }) { flags.append(Flag(level: .warning, file: file, text: message)) }
        }
        return flags
    }

    /// Characters that draw as nothing, or reorder what is drawn: Unicode Tags (invisible ASCII),
    /// zero-width characters, direction overrides, the variation selectors' supplement (which can carry
    /// hidden bytes), and invisible fillers.
    static let hiddenRanges: [ClosedRange<UInt32>] = [
        0xE0000...0xE007F, 0x200B...0x200F, 0x2060...0x2064, 0xFEFF...0xFEFF, 0x202A...0x202E, 0x2066...0x2069,
        0xE0100...0xE01EF, 0x00AD...0x00AD, 0x034F...0x034F, 0x115F...0x1160, 0x180B...0x180F, 0x3164...0x3164,
        0xFFA0...0xFFA0, 0x061C...0x061C, 0xFE00...0xFE0D, 0xFFF9...0xFFFB, 0x1D173...0x1D17A,
    ]

    /// The ranges above, and anything else Unicode says is drawn as nothing (the rest of the tag block,
    /// for one, can carry a hidden byte per character). U+FE0E and U+FE0F are left to hiddenMask.
    static func isHidden(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        if hiddenRanges.contains(where: { $0.contains(v) }) { return true }
        // Control characters draw as nothing too; tab and line breaks are ordinary.
        if scalar.properties.generalCategory == .control { return !ordinaryControls.contains(v) }
        guard v != 0xFE0E, v != 0xFE0F else { return false }
        return scalar.properties.isDefaultIgnorableCodePoint
    }

    /// Which scalars are hidden. Only U+FE0E and U+FE0F (text or emoji style) are ordinary, and only
    /// right after an emoji, or in a keycap (1️⃣) after a digit, # or *; the other variation selectors
    /// are hidden everywhere.
    static func hiddenMask(_ scalars: [Unicode.Scalar]) -> [Bool] {
        scalars.indices.map { index in
            let scalar = scalars[index]
            if isHidden(scalar) { return true }
            guard scalar.value == 0xFE0E || scalar.value == 0xFE0F else { return false }
            guard index > 0 else { return true }
            let previous = scalars[index - 1]
            if keycapBases.contains(previous) {
                let next = index + 1 < scalars.count ? scalars[index + 1].value : 0
                return next != 0x20E3
            }
            return (0xFE00...0xFE0F).contains(previous.value) || !previous.properties.isEmoji
        }
    }

    static let keycapBases = Set("0123456789#*".unicodeScalars)
    static let ordinaryControls: Set<UInt32> = [0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x85]

    static func hiddenKind(_ scalar: Unicode.Scalar) -> String {
        let v = scalar.value
        if scalar.properties.generalCategory == .control { return "control characters" }
        if (0xE0000...0xE007F).contains(v) { return "invisible tag letters" }
        if (0x202A...0x202E).contains(v) || (0x2066...0x2069).contains(v) || v == 0x061C { return "direction overrides" }
        if (0xFFF9...0xFFFB).contains(v) || (0x1D173...0x1D17A).contains(v) { return "invisible format characters" }
        if (0xE0100...0xE01EF).contains(v) || (0xFE00...0xFE0F).contains(v) || (0x180B...0x180F).contains(v) { return "variation selectors" }
        if v == 0x00AD || v == 0x034F || v == 0x115F || v == 0x1160 || v == 0x3164 || v == 0xFFA0 { return "invisible fillers" }
        if (0x200B...0x200F).contains(v) || (0x2060...0x2064).contains(v) || v == 0xFEFF { return "zero-width" }
        return "invisible format characters"
    }

    /// A program's text with its control characters (but newline and tab) shown as dots.
    public static func dottingControls(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            let control = scalar.properties.generalCategory == .control && scalar != "\n" && scalar != "\t"
            out.append(control ? "·" : scalar)
        }
        return String(out)
    }

    /// Text from a skill's files on one line, for a row: hidden characters and line breaks written out
    /// (⟦U+000A⟧), and cut at `limit` characters with "…", never inside a written-out character.
    public static func oneLine(_ text: String, limit: Int = 200) -> String {
        var out = String.UnicodeScalarView()
        for scalar in revealHidden(text).unicodeScalars {
            if lineBreaks.contains(scalar.value) {
                out.append(contentsOf: String(format: "⟦U+%04X⟧", scalar.value).unicodeScalars)
            } else {
                out.append(scalar)
            }
        }
        let line = String(out)
        guard line.count > limit else { return line }
        var cut = String(line.prefix(limit))
        if let open = cut.range(of: "⟦", options: .backwards), !cut[open.upperBound...].contains("⟧") {
            cut = String(cut[..<open.lowerBound])
        }
        return cut + "…"
    }

    /// Characters that break a line (revealHidden leaves them, as text needs them).
    static let lineBreaks: Set<UInt32> = [0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029]

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
    /// most of these), and which agent runs its parts by itself when it is also a package, or when Amp
    /// starts its servers.
    static func capabilities(front: SkillFrontMatter?, skillText: String, files: [File], package: SkillPackage? = nil,
                             servers: SkillServers? = nil) -> [String] {
        var items: [String] = []
        let keys = Set(front?.keys ?? [])
        if let tools = front?.allowedTools, !tools.isEmpty { items.append("Runs these tools without asking while it is used: \(tools)") }
        if keys.contains("hooks") { items.append("Adds hooks that run commands for the rest of the session (Claude Code).") }
        if runsShellLines(skillText) { items.append("Runs shell commands before the agent reads it (!`…` lines or ```! blocks).") }
        if keys.contains("disable-model-invocation") { items.append("Is used only when you name it.") } else { items.append("The agent may use it on its own when the task fits its description.") }
        if keys.contains("context") || keys.contains("agent") { items.append("Runs in a separate agent context.") }
        if let plugin = package?.claude, plugin.startsPrograms { items.append(claudeStartsLine(plugin)) }
        // Of the agents checked, only Amp starts a skill's own servers: Claude Code ignores mcpServers in SKILL.md.
        if servers?.hasAmp == true { items.append(ampLine) }
        let scripts = files.filter { $0.script || $0.executable || $0.binary }.count
        if scripts > 0 {
            let counted = "Brings \(scripts) file\(scripts == 1 ? "" : "s") that can run (scripts or programs)"
            // Only the agent's own tools run them, unless a package's parts, or Amp's servers, run by themselves.
            let byItself = package?.runsPartsByItself == true || servers?.ampRunsPrograms == true
            items.append(byItself ? counted + "." : counted + "; the agent runs them only through its own tools.")
        }
        return items
    }

    static let ampLine = "Amp connects to the MCP servers it declares, and starts any program among them, when it finds the skill."

    /// Claude Code runs a skill's `` !`…` `` lines and ```` ```! ```` blocks in its shell before the agent
    /// reads the skill.
    static func runsShellLines(_ text: String) -> Bool {
        if text.contains("!`") { return true }
        return text.split(whereSeparator: \.isNewline).contains { line in
            line.drop { $0 == " " || $0 == "\t" }.hasPrefix("```!")
        }
    }

    /// Who starts what in a Claude Code plugin: "Claude Code starts its MCP servers and hooks by itself …".
    static func claudeStartsLine(_ plugin: SkillPackage.ClaudePlugin) -> String {
        var started: [String] = []
        if plugin.serverCount > 0 { started.append("MCP servers") }
        if plugin.partCounts[.hook] != nil { started.append("hooks") }
        if plugin.partCounts[.monitor] != nil { started.append("monitors") }
        if plugin.partCounts[.lspServer] != nil { started.append("LSP servers") }
        guard !started.isEmpty else {
            // bin/ is not started: Claude Code puts it on its shell's PATH (hand check H6).
            if plugin.programCount > 0 {
                return "Claude Code puts the programs in its bin/ folder on its shell's PATH once it is added, so they run by name."
            }
            return "Claude Code loads its plugin parts by itself once it is added, without the agent asking you first."
        }
        return "Claude Code starts its \(SkillPackage.list(started)) by itself once it is added, without the agent asking you first."
    }
}

// MARK: - MCP servers in text and files

// Text and files that add MCP servers or fetch server code outside the commit: commands that add a server
// or install a plugin, servers that run a package with no exact version (in a JSON file, in JSON quoted in
// prose, or as a command), server settings outside the files the review already lists, and MCP bundles.
// Patterns run on lowercased text, as the other command checks do.
extension SkillReview {
    static let unpinnedServerText = "An MCP server runs a package without a pinned version (npx, bunx, pnpm dlx, yarn dlx or uvx). "
        + "MCP clients start it with no question, fetching whatever version npm or PyPI has then."
    static let settingsText = "Holds MCP server settings (mcpServers or [mcp_servers]). An agent may copy them into its own settings."
    static let bundleText = "An MCP bundle (.mcpb or .dxt): a packed server that Claude Code unpacks and runs. Its contents are not reviewed here."
    static let bundleLinkText = "A link to an MCP bundle: a server fetched from the web, outside this commit."

    /// An exact version, as npm writes one: 1.2.3, 1.2.3-beta.1, 1.2.3+build.5. `@latest`, `@next`, `@^1`,
    /// `@1` and other ranges are not one.
    static let exactVersion = #"\d+\.\d+\.\d+(?:-[0-9a-z-]+(?:\.[0-9a-z-]+)*)?(?:\+[0-9a-z-]+(?:\.[0-9a-z-]+)*)?"#
    /// Where a package name ends in prose: a space, a quote, a backtick, a closing bracket, or the end.
    static let wordEnd = #"(?:[\s`'")\]]|$)"#
    /// `@` and anything but an exact version (a sentence's full stop may follow one), or nothing.
    static let unpinnedVersion = #"(?:@(?!"# + exactVersion + #"[.,;:]*"# + wordEnd + #")[^\s`'")\]]*)?"#
    /// npx and a package name, a scope's leading @ included, with no exact version after it.
    static let unpinnedNPX = #"\bnpx\s+(?:-y\s+|--yes\s+)?@?[a-z0-9][a-z0-9/_.-]*"# + unpinnedVersion + wordEnd
    static let unpinnedPython = #"\b(?:uvx|pipx run)\s+[a-z0-9_.-]+"# + unpinnedVersion + wordEnd
    // The regular expression engine skips ahead to the words the two patterns below start with. With `\b`
    // in front of the words, or the look-behind for the program's name in front of `mcp`, it tried every
    // position: about a second per MB. And `\b[a-z][a-z0-9_-]*\s+mcp` read a run such as `a-a-a-…` again
    // from each part, in time that grew with the square of its length.
    /// A slash command has no word boundary before it.
    static let pluginInstall = #"(?:(?<!\w)(?:claude\s+plugins?\s+install|gemini\s+extensions?\s+install|codex\s+plugins?\s+add)|/plugin\s+install)\b"#
    /// `codex mcp add`, `claude mcp add-json`, `gemini mcp add`, …: a program's name, up to 40 characters of
    /// it, before `mcp`.
    static let mcpAdd = #"mcp(?<=[a-z][a-z0-9_-]{0,40}\s{1,20}mcp)\s+add(?:-json)?\b"#

    /// Server JSON quoted in prose, in one array or one `{…}` that holds no other brace: npx, bunx or uvx
    /// (or pnpm or yarn with dlx first), maybe `-y`, then a quoted package with no exact version. Each comes
    /// with the quoted words one of which the text must hold, a quick test that most files fail.
    static let quotedServerPatterns: [(words: [String], pattern: String)] = {
        let package = ##""@?[a-z0-9][a-z0-9/_.-]*(?:@(?!"## + exactVersion + ##"")[^"]*)?""##
        let flag = ##"(?:"(?:-y|--yes)"\s*,\s*)?"##
        // Both parts, in either order, between one `{` and the next brace. Each is looked for after the `{`,
        // up to 2,000 characters, so a crafted file can't make the check slow.
        func within(_ part: String) -> String { #"(?=[^{}]{0,2000}?"# + part + ")" }
        let runner = ##""command"\s*:\s*"(?:npx|bunx|uvx)""##
        let dlxRunner = ##""command"\s*:\s*"(?:pnpm|yarn)""##
        let args = ##""args"\s*:\s*\[\s*"## + flag + package
        let dlxArgs = ##""args"\s*:\s*\[\s*"dlx"\s*,\s*"## + flag + package
        // As an array's first word: `"command": "npx", "args": …` is the forms below.
        let array = ##"\[\s*"npx"\s*,\s*"## + flag + package
        let server = #"\{"# + within(runner) + within(args)
        let dlxServer = #"\{"# + within(dlxRunner) + within(dlxArgs)
        return [(words: [#""npx""#], pattern: array),
                (words: [#""npx""#, #""bunx""#, #""uvx""#], pattern: server),
                (words: [#""pnpm""#, #""yarn""#], pattern: dlxServer)]
    }()

    /// `"mcpServers": …`, a YAML `mcpServers:` line, and Codex's `[mcp_servers.…]` tables.
    static let settingsPatterns = [#""mcpservers"\s*:"#, #"(?m)^[ \t]*mcpservers[ \t]*:"#, #"\[mcp_servers[.\]]"#]

    static func settingsFlags(_ lower: String, file: String) -> [Flag] {
        guard settingsPatterns.contains(where: { lower.range(of: $0, options: .regularExpression) != nil }) else { return [] }
        return [Flag(level: .warning, file: file, text: settingsText)]
    }

    /// The text after SKILL.md's front matter (the lines between its first two `---` lines, as
    /// SkillFrontMatter reads them); all of it when there is none.
    static func afterFrontMatter(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        func fence(_ line: String) -> Bool {
            let bare = line.hasSuffix("\r") ? String(line.dropLast()) : line
            return bare.trimmingCharacters(in: .whitespaces) == "---"
        }
        guard let first = lines.first, fence(first), let end = lines.dropFirst().firstIndex(where: fence) else { return text }
        return lines[(end + 1)...].joined(separator: "\n")
    }

    /// The servers in a JSON file that run a package with no exact version: every object with a string
    /// `command` (or a list of words, as opencode writes one) is a server. Nil when the file is not JSON
    /// that every reader takes the same way (comments, a trailing comma, a key twice): the prose
    /// patterns check it then.
    static func serverJSONFlags(_ data: Data, file: String) -> [Flag]? {
        guard case .success(let root) = SkillJSONText.parse(data), SkillJSONText.duplicateKey(in: root) == nil else { return nil }
        var pending = [root]
        while let node = pending.popLast() {
            if node.kind == .object, runsUnpinned(node) { return [Flag(level: .warning, file: file, text: unpinnedServerText)] }
            pending += node.members.map(\.value)
            pending += node.items
        }
        return []
    }

    static func runsUnpinned(_ object: SkillJSONText.Node) -> Bool {
        guard let command = object.member("command").first?.value else { return false }
        let args = strings(object.member("args").first?.value)
        switch command.kind {
        case .string: return unpinnedPackage([command.string ?? ""] + args)
        case .array: return unpinnedPackage(strings(command) + args)
        default: return false
        }
    }

    static func strings(_ node: SkillJSONText.Node?) -> [String] {
        guard let node, node.kind == .array else { return [] }
        return node.items.compactMap { $0.kind == .string ? $0.string : nil }
    }

    /// A command's words run a package with no exact version: npx, bunx or uvx, or pnpm or yarn with dlx
    /// first. The package is the first word after them that is not a flag.
    static func unpinnedPackage(_ words: [String]) -> Bool {
        guard let first = words.first else { return false }
        var program = (first as NSString).lastPathComponent.lowercased()
        for suffix in [".cmd", ".exe"] where program.hasSuffix(suffix) { program.removeLast(suffix.count) }
        var rest = words.dropFirst()
        switch program {
        case "npx", "bunx", "uvx": break
        case "pnpm", "yarn":
            guard rest.first?.lowercased() == "dlx" else { return false }
            rest = rest.dropFirst()
        default: return false
        }
        guard let package = rest.first(where: { !$0.hasPrefix("-") }) else { return false }
        return !isPinned(package, python: program == "uvx")
    }

    /// `name@1.2.3` (`@scope/name@1.2.3`), or for uvx also `name==1.2.3`. A path is the folder's own code,
    /// not a package fetched by name.
    static func isPinned(_ package: String, python: Bool) -> Bool {
        if package.hasPrefix(".") || package.hasPrefix("/") || package.hasPrefix("~") { return true }
        var name = Substring(package.lowercased())
        if name.hasPrefix("@") { name = name.dropFirst() }
        if let at = name.firstIndex(of: "@") { return isExactVersion(name[name.index(after: at)...]) }
        if python, let equals = name.range(of: "==") { return isExactVersion(name[equals.upperBound...]) }
        return false
    }

    static func isExactVersion(_ text: Substring) -> Bool {
        String(text).range(of: "^" + exactVersion + "$", options: .regularExpression) != nil
    }

    /// A web address whose path ends in .mcpb or .dxt.
    static func isBundleAddress(_ url: String) -> Bool {
        guard let path = URL(string: url)?.path else { return PackageReader.isBundle(url, address: true) }
        return PackageReader.isBundle(path, address: false)
    }

    /// The files a row of the review lists as declaring MCP servers, lowercased, with where their links
    /// inside the folder lead: the Needs MCP servers row's files, and each package manifest with its
    /// server files and the files it could not read. They get no server settings warning. SKILL.md is
    /// never one: only its front matter is skipped, and only when the Amp row shows it.
    static func serverFiles(folder: String, package: SkillPackage?, servers: SkillServers) -> Set<String> {
        var files = servers.files
        for manifest in package?.manifests ?? [] {
            files.append(manifest.file)
            files += manifest.servers.map(\.file)
            files += manifest.unread.map(\.file)
        }
        files += package?.claude?.unread.map(\.file) ?? []
        let realFolder = realPath(folder)
        var listed = Set<String>()
        for file in files where file.lowercased() != servers.skillFile.lowercased() {
            listed.insert(file.lowercased())
            let real = realPath((folder as NSString).appendingPathComponent(file))
            if real.hasPrefix(realFolder + "/") { listed.insert(String(real.dropFirst(realFolder.count + 1)).lowercased()) }
        }
        return listed
    }
}
