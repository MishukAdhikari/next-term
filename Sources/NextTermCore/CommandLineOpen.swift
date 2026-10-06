import Foundation

/// One thing `nxtrm` asks Next Term to open.
public struct OpenRequest: Codable, Equatable, Sendable {
    /// Absolute path.
    public var path: String
    public var line: Int?
    public var column: Int?
    public var isDirectory: Bool
    /// Does not exist yet: the command line tool creates it empty (as `subl new.md` lets you write it).
    public var isNew: Bool

    public init(path: String, line: Int? = nil, column: Int? = nil, isDirectory: Bool = false, isNew: Bool = false) {
        self.path = path
        self.line = line
        self.column = column
        self.isDirectory = isDirectory
        self.isNew = isNew
    }
}

/// What one run of `nxtrm` asks for.
public struct OpenCommand: Codable, Equatable, Sendable {
    public var items: [OpenRequest]
    public var newWindow: Bool
    /// The app the command belongs to, so a development build and the installed app never both answer.
    public var app: String

    public init(items: [OpenRequest], newWindow: Bool = false, app: String = "") {
        self.items = items
        self.newWindow = newWindow
        self.app = app
    }
}

/// `nxtrm`, the command line tool: `nxtrm .`, `nxtrm src/app.ts:42:7`, `nxtrm -n ~/Code/api`.
public enum CommandLineOpen {
    public static let toolName = "nxtrm"
    /// Distributed notification the running app listens for.
    public static let notificationName = "me.mishuk.nextterm.open"

    public enum Parsed: Equatable {
        case open(OpenCommand)
        case help
        case version
        case error(String)
    }

    public static let usage = """
    Usage: nxtrm [options] [path[:line[:column]] ...]

    Opens folders as projects and files in the editor of Next Term.

      nxtrm .                   this folder as a project
      nxtrm ~/Code/api          a folder as a project
      nxtrm src/app.ts:42:7     a file, at line 42, column 7
      nxtrm notes.md            a new file is created empty

    Options:
      -n, --new-window   open in a new window
      -h, --help         show this help
      -v, --version      show the version
    """

    public static func parse(_ arguments: [String], cwd: String, fileManager: FileManager = .default) -> Parsed {
        var items: [OpenRequest] = []
        var newWindow = false
        var optionsEnded = false
        for argument in arguments {
            if !optionsEnded, argument.hasPrefix("-"), argument != "-" {
                switch argument {
                case "--": optionsEnded = true
                case "-n", "--new-window": newWindow = true
                case "-h", "--help": return .help
                case "-v", "--version": return .version
                default: return .error("unknown option \(argument) (see nxtrm --help)")
                }
                continue
            }
            switch request(for: argument, cwd: cwd, fileManager: fileManager) {
            case .success(let item): items.append(item)
            case .failure(let message): return .error(message.text)
            }
        }
        return .open(OpenCommand(items: items, newWindow: newWindow))
    }

    struct Message: Error { let text: String }

    static func request(for argument: String, cwd: String, fileManager: FileManager) -> Result<OpenRequest, Message> {
        func absolute(_ path: String) -> String {
            let expanded = (path as NSString).expandingTildeInPath
            let joined = expanded.hasPrefix("/") ? expanded : (cwd as NSString).appendingPathComponent(expanded)
            return (joined as NSString).standardizingPath
        }
        func existing(_ path: String) -> (exists: Bool, directory: Bool) {
            var isDirectory: ObjCBool = false
            let exists = fileManager.fileExists(atPath: path, isDirectory: &isDirectory)
            return (exists, isDirectory.boolValue)
        }
        let whole = absolute(argument)
        let found = existing(whole)
        if found.exists {
            return .success(OpenRequest(path: canonicalPath(whole), isDirectory: found.directory))
        }
        // "file:42" or "file:42:7", as compilers, linters and agents print them.
        var path = whole
        var line: Int?, column: Int?
        if let range = argument.range(of: #":([0-9]+)(:([0-9]+))?:?$"#, options: .regularExpression) {
            let numbers = argument[range].split(separator: ":").compactMap { Int($0) }
            line = numbers.first
            column = numbers.count > 1 ? numbers[1] : nil
            path = absolute(String(argument[..<range.lowerBound]))
            let stripped = existing(path)
            if stripped.exists {
                if stripped.directory { return .failure(Message(text: "\(argument): a folder has no lines")) }
                return .success(OpenRequest(path: canonicalPath(path), line: line, column: column))
            }
        }
        // A new file, in a folder that exists.
        let parent = (path as NSString).deletingLastPathComponent
        guard existing(parent).directory else { return .failure(Message(text: "\(argument): no such file or folder")) }
        return .success(OpenRequest(path: canonicalPath(parent) + "/" + (path as NSString).lastPathComponent, line: line, column: column, isNew: true))
    }
}
