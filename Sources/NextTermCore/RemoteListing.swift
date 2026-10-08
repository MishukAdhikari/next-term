import Foundation

/// Tab completion's folders and files on a server, read over the tab's existing connection (RemoteCompletion
/// runs it through RemoteConnection.run): a /bin/sh script that lists one folder and writes nothing. It prints
/// the marker, the login shell's name (for quoting), the folder, then one entry per NUL with a type letter:
/// `d` a folder, `D` a folder that can't be entered, `f` anything else, `x` a link to nothing. A name that isn't
/// printable ASCII goes as hex (od, which BusyBox has too), so no byte of it is lost on the way.
public enum RemoteListing {
    /// Entries listed at most, and the bytes they take.
    public static let maxEntries = 5000
    public static let maxBytes = 1_048_576

    /// The folder to list: one the word names, relative to the shell's own folder unless it starts with `/` or
    /// `~/`; or one the server's hook already made absolute.
    public enum Folder: Equatable, Sendable {
        case typed(String)
        case absolute(String)
    }

    /// Where the shell's own folder is read, at request time: tmux's pane, `/proc` (or lsof where there is no
    /// `/proc`) for a plain shell, or nowhere (herdr): then only absolute and `~/` words are listed.
    public enum Live: Equatable, Sendable {
        case tmux(session: String)
        case pid(tabKey: String)
        case none
    }

    /// The script for `folder`; `hidden`: list names starting with a dot too.
    public static func script(_ folder: Folder, live: Live, hidden: Bool = true, limit: Int = maxEntries, bytes: Int = maxBytes) -> String {
        var lines = [
            "LC_ALL=C; export LC_ALL",
            "C=\(RemoteShell.cacheDir)",
            "L=",
        ]
        switch live {
        case .tmux(let session):
            let target = RemoteShell.quote("=" + RemoteShell.safeName(session) + ":")
            lines += [RemoteShell.findTmux,
                      "[ -n \"$T\" ] && L=$(\"$T\" -L nextterm display-message -p -t \(target) '#{pane_current_path}' 2>/dev/null)",
                      // A pane in copy mode shows tmux's history, not the shell's line: nothing to complete there.
                      "[ -n \"$T\" ] && [ \"$(\"$T\" -L nextterm display-message -p -t \(target) '#{pane_in_mode}' 2>/dev/null)\" = 1 ] && { echo 'In copy mode.' >&2; exit 5; }"]
        case .pid(let tabKey):
            let id = RemoteShell.safeName(tabKey)
            lines += ["set -- $(cat \"$C/tabs/\(id)\" 2>/dev/null); [ -n \"$1\" ] || { A=/tmp/nt-$(id -u)-tabs; [ -O \"$A\" ] && set -- $(cat \"$A/\(id)\" 2>/dev/null); }",
                      "[ -n \"$1\" ] && L=$(readlink \"/proc/$1/cwd\" 2>/dev/null)",
                      // No /proc (a Mac or BSD host): lsof, where there is one.
                      "if [ -z \"$L\" ] && [ -n \"$1\" ] && command -v lsof >/dev/null 2>&1; then L=$(lsof -a -p \"$1\" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1); fi"]
        case .none:
            break
        }
        switch folder {
        case .absolute(let path):
            lines.append("D=\(RemoteShell.quote(path))")
        case .typed(let word):
            lines += [
                "W=\(RemoteShell.quote(word))",
                "case $W in",
                "  /*) D=$W ;;",
                "  '~/'*) D=$HOME/${W#??} ;;",
                "  *) [ -n \"$L\" ] || { echo 'The shell’s folder is not known.' >&2; exit 3; }; D=$L/$W ;;",
                "esac",
            ]
        }
        lines += [
            "cd \"$D\" 2>/dev/null || { echo 'Not a folder.' >&2; exit 4; }",
            "printf '\\n%s\\n' \(RemoteShell.quote(RemoteShell.marker))",
            "b=; case $(readlink -f \"$SHELL\" 2>/dev/null) in */busybox) b=busybox ;; esac",
            "printf 'shell\\t%s\\t%s\\n' \"$(printf '%s' \"${SHELL##*/}\" | tr -cd 'A-Za-z0-9._-')\" \"$b\"",
            "printf 'dir\\t%s\\n' \"$(pwd | tr -d '\\001-\\037\\177')\"",
            "printf 'list\\t'",
            // Printable ASCII is a space to a tilde; anything else goes as hex.
            "R=' -~'; n=0",
            "for f in *\(hidden ? " .*" : ""); do",
            "  case $f in .|..) continue ;; esac",
            "  [ -e \"$f\" ] || [ -h \"$f\" ] || continue",
            "  n=$((n + 1))",
            "  if [ \"$n\" -gt \(max(0, limit)) ]; then printf '+\\000'; break; fi",
            "  if [ -d \"$f\" ]; then if [ -x \"$f\" ]; then t=d; else t=D; fi",
            "  elif [ -h \"$f\" ] && [ ! -e \"$f\" ]; then t=x",
            "  else t=f; fi",
            "  case $f in",
            "    *[!$R]*) printf '%s#%s\\000' \"$t\" \"$(printf '%s' \"$f\" | od -An -tx1 | tr -d ' \\n')\" ;;",
            "    *) printf '%s:%s\\000' \"$t\" \"$f\" ;;",
            "  esac",
            "done | head -c \(max(0, bytes))",
        ]
        return lines.joined(separator: "\n")
    }

    /// What the script printed.
    public struct Result: Sendable {
        /// The login shell's name ("bash", "zsh", "sh"), and whether it is BusyBox's.
        public var shell: String
        public var busybox: Bool
        /// The folder listed, absolute on the server.
        public var folder: String
        public var listing: PathCompletion.Listing
        /// Folders among the entries that can't be entered, as full paths.
        public var closed: Set<[UInt8]>

        /// How names are quoted for this shell; nil: one Next Term doesn't quote for (fish, tcsh), which gets
        /// only names that need no quoting.
        public var quoting: WordQuote.Shell? { RemoteListing.quoting(shell: shell, busybox: busybox) }

        /// The server's answers for a listing's links and folders: only links to nothing come as links, and
        /// whether a folder can be entered was read there.
        public var disk: PathCompletion.Disk {
            let closed = self.closed
            return PathCompletion.Disk(follow: { _ in .missing }, canEnter: { !closed.contains($0) })
        }
    }

    /// nil: no marker (the folder wasn't there, or the script didn't run).
    public static func parse(_ output: String) -> Result? {
        guard let marker = output.range(of: RemoteShell.marker) else { return nil }
        let rest = output[marker.upperBound...]
        guard let listStart = rest.range(of: "\nlist\t") else { return nil }
        var shell = "", busybox = false, folder = ""
        for line in rest[..<listStart.lowerBound].split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            if fields.first == "shell", fields.count >= 2 {
                shell = String(fields[1])
                busybox = fields.count > 2 && fields[2] == "busybox"
            } else if fields.first == "dir", fields.count >= 2 {
                folder = fields[1...].joined(separator: "\t")
            }
        }
        guard folder.hasPrefix("/") else { return nil }
        let items = rest[listStart.upperBound...].split(separator: "\u{0}", omittingEmptySubsequences: false)
        var entries: [PathCompletion.Entry] = []
        var closed = Set<[UInt8]>()
        var more = false
        let base = Array(folder.utf8) + (folder.hasSuffix("/") ? [] : [UInt8(ascii: "/")])
        // The last item has no NUL after it: cut short by the byte cap, or the empty rest.
        for item in items.dropLast() {
            if item == "+" {
                more = true
                continue
            }
            guard let entry = entry(item) else { continue }
            if entry.closed { closed.insert(base + entry.name) }
            entries.append(PathCompletion.Entry(name: entry.name, kind: entry.kind))
        }
        let cut = !(items.last?.isEmpty ?? true)
        let complete = !more && !cut
        let listing = PathCompletion.Listing(folder: folder, entries: entries, complete: complete, allSeen: complete)
        return Result(shell: shell, busybox: busybox, folder: folder, listing: listing, closed: closed)
    }

    private static func entry(_ item: Substring) -> (name: [UInt8], kind: PathCompletion.Kind, closed: Bool)? {
        guard item.count >= 3, let type = item.first else { return nil }
        let how = item[item.index(after: item.startIndex)]
        let text = item.dropFirst(2)
        let name: [UInt8]
        switch how {
        case ":": name = Array(text.utf8)
        case "#":
            guard let bytes = hexBytes(text) else { return nil }
            name = bytes
        default: return nil
        }
        guard !name.isEmpty, !name.contains(UInt8(ascii: "/")), !name.contains(0) else { return nil }
        switch type {
        case "d": return (name, .folder, false)
        case "D": return (name, .folder, true)
        case "f": return (name, .file, false)
        case "x": return (name, .link, false)
        default: return nil
        }
    }

    static func hexBytes(_ text: Substring) -> [UInt8]? {
        let digits = Array(text.utf8)
        guard digits.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(digits.count / 2)
        var i = 0
        while i < digits.count {
            guard let pair = UInt8(String(decoding: digits[i..<(i + 2)], as: UTF8.self), radix: 16) else { return nil }
            bytes.append(pair)
            i += 2
        }
        return bytes
    }

    /// How a server's login shell takes quoted names. `$'…'` (names with control or invisible characters,
    /// or bytes that aren't UTF-8) only in bash, zsh and BusyBox's ash.
    public static func quoting(shell: String, busybox: Bool) -> WordQuote.Shell? {
        switch shell {
        case "zsh": return .zsh
        case "bash", "ash": return .bash
        case "sh": return busybox ? .bash : .sh
        case "dash", "ksh", "mksh", "posh", "yash", "ksh93": return .sh
        default: return nil
        }
    }

    /// A name as typed unquoted for `shell`; nil when that shell can't take it (Next Term doesn't quote for
    /// fish or tcsh, so they get only names that need no quoting).
    public static func typable(_ name: [UInt8], shell: WordQuote.Shell?) -> String? {
        guard let shell else {
            let plain = WordQuote.quote(name, in: .unquoted, shell: .sh)
            return plain == String(bytes: name, encoding: .utf8) ? plain : nil
        }
        return WordQuote.quote(name, in: .unquoted, shell: shell)
    }
}
