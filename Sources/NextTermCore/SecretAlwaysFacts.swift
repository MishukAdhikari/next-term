import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// What Next Term reads to make an Always grant's definition (SecretAlwaysDefinition) and to decide whether one is
/// offered (SecretAlwaysRules): the executable a command's words resolve to, the script an interpreter runs, the git hooks
/// and the files in the run folder that change what it does. Every fact is read here, from the disk, never taken from the
/// requester but its words, its folder and the `PATH` its own wrapper reported.
public enum SecretAlwaysFacts {
    /// What a command's facts come to: its definition, and the facts the rules decide on.
    public struct Made: Sendable {
        public var definition: SecretAlwaysDefinition
        public var command: SecretAlwaysRules.Command
    }

    /// `command` as `path` finds it from `folder`: a path as given (from the folder), else the first executable plain file
    /// of that name in `path`; canonical. Nil when there is none.
    public static func resolve(_ command: String, path: String?, folder: String) -> String? {
        guard !command.isEmpty else { return nil }
        if command.contains("/") {
            let full = command.hasPrefix("/") ? command : (folder as NSString).appendingPathComponent(command)
            return isRunnable(full) ? canonicalPath(full) : nil
        }
        let folders = (path ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        for each in folders where each.hasPrefix("/") {
            let candidate = (each as NSString).appendingPathComponent(command)
            if isRunnable(candidate) { return canonicalPath(candidate) }
        }
        return nil
    }

    static func isRunnable(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && access(path, X_OK) == 0
    }

    /// The script an interpreter's words run: the first word after the program that is not a flag, from the folder,
    /// canonical, when it is a plain file. Nil for `-m module`, `-e code` and the like, where there is no one file.
    public static func script(of words: [String], folder: String) -> String? {
        let (_, rest) = SecretRun.program(of: words)
        for word in rest {
            if ["-m", "-e", "-c", "--eval", "-p", "--print", "-r", "--require", "--import"].contains(word) { return nil }
            if word.hasPrefix("-") { continue }
            let full = word.hasPrefix("/") ? word : (folder as NSString).appendingPathComponent(word)
            var info = stat()
            guard stat(full, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
            return canonicalPath(full)
        }
        return nil
    }

    /// The hooks git runs for a repository at `folder`, from git's own answer (`core.hooksPath` included): whether any
    /// is there, and a digest of each one's name and stamp. No repository, no hooks.
    public static func hooks(folder: String, git: String?) -> (any: Bool, digest: String) {
        guard let git, let data = GitRunner.run(git, ["-C", folder, "rev-parse", "--path-format=absolute", "--git-path", "hooks"], timeout: 5),
              let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), line.hasPrefix("/") else {
            return (false, "none")
        }
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: line)) ?? []).filter { !$0.hasSuffix(".sample") }.sorted()
        let listed = names.map { name -> String in
            let stamp = SecretFileStamp.of((line as NSString).appendingPathComponent(name))
            return "\(name)\u{0}\(stamp.map { "\($0.inode):\($0.size):\($0.changed)" } ?? "-")"
        }
        return (!names.isEmpty, names.isEmpty ? "none" : SecretRun.digest(Data(listed.joined(separator: "\n").utf8)))
    }

    /// A SHA-256 of a plain file's bytes (up to 1 MB), or "none".
    public static func fileDigest(_ path: String) -> String {
        var info = stat()
        guard lstat(path, &info) == 0 else { return "none" }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_size <= 1 << 20, let data = FileManager.default.contents(atPath: path) else {
            return "other"
        }
        return SecretRun.digest(data)
    }

    /// Whether this user (so any agent running as them) can change the file or folder at `path`.
    public static func writable(_ path: String) -> Bool { access(path, W_OK) == 0 }

    /// A command's definition and facts: the words it runs (nil for run_with_secrets' text that uses the shell's own
    /// syntax), the executable they resolve to from `folder` with `path`, its stamp, the script under an interpreter and
    /// its stamp, the keys, the folder, the warned variables, and the files that change what it does: `.env`, `.npmrc`
    /// and the git hooks.
    /// `resolved`: the executable as the wrapper already resolved it with its own `PATH`, in place of resolving here.
    public static func command(door: SecretAlwaysDoor, words: [String]?, keys: [String: String], folder: String, path: String?,
                               resolved: String? = nil, warned: [String: String], warnings: [String], git: String?) -> Made {
        var definition = SecretAlwaysDefinition(door: door, keys: keys)
        definition.folder = folder
        definition.warned = warned
        definition.pathDigest = path.map { SecretRun.digest(Data($0.utf8)) }
        let hooks = hooks(folder: folder, git: git)
        definition.files = [
            ".env": fileDigest((folder as NSString).appendingPathComponent(".env")),
            ".npmrc": fileDigest((folder as NSString).appendingPathComponent(".npmrc")),
            "hooks": hooks.digest,
        ]
        guard let words, let first = words.first else {
            return Made(definition: definition, command: SecretAlwaysRules.Command(words: [], usesShellSyntax: true, warnings: warnings))
        }
        definition.words = words
        // The program the words run, past `env` and the like: its executable and file, and its script under an interpreter.
        let (program, _) = SecretRun.program(of: words)
        let lead = words.first { CommandClassifier.baseName($0) == program } ?? first
        let executable = resolved.flatMap { $0.hasPrefix("/") && isRunnable($0) ? canonicalPath($0) : nil } ?? resolve(lead, path: path, folder: folder)
        definition.executable = executable
        definition.executableStamp = executable.flatMap(SecretFileStamp.of)
        var script: String?
        let base = executable.map { ($0 as NSString).lastPathComponent } ?? program
        if SecretAlwaysRules.interpreters.contains(program) || SecretAlwaysRules.interpreters.contains(base) {
            script = self.script(of: words, folder: folder)
            if let script { definition.files["script"] = SecretFileStamp.of(script).map { "\($0.inode):\($0.size):\($0.changed)" } ?? "none" }
        }
        let command = SecretAlwaysRules.Command(words: words, warnings: warnings, executable: executable, script: script,
                                                hasHooks: hooks.any)
        return Made(definition: definition, command: command)
    }

    /// A hub server's definition: its URL, its header templates as written, its list and that list's digest. The folder
    /// is not in it (the agent never sees the key, so where it asks from is the scope's alone).
    public static func hub(url: String, headers: [String: String], list: String, keys: [String: String]) -> SecretAlwaysDefinition {
        var definition = SecretAlwaysDefinition(door: .hub, keys: keys)
        definition.url = url
        definition.headers = headers
        definition.list = list
        definition.listDigest = fileDigest(list)
        return definition
    }
}
