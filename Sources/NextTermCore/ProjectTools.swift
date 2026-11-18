import Foundation

/// Project tools (plan 044): the tools a project's own files say it needs to run, offered one at a time and only when
/// this Mac lacks them. Next Term installs nothing up front: a tool is offered only when the project needs it (`needs`,
/// read by RunTasks.scan) and no copy is found, on the login shell's PATH or in its own installer's folder. The
/// offer is one quiet line in the Run group; Install… types the tool's official installer into a new tab without
/// pressing Return, so the user's Return is the yes, as Settings › Agents' Install… does. Never sudo.
public struct ProjectTool: Sendable, Equatable, Hashable, Identifiable {
    public let id: String
    /// What the offer line names: "uv", "cargo", "Java".
    public let name: String
    /// The program names a copy goes by, looked for along PATH.
    public let programs: [String]
    /// PATH copies that are no copy at all: macOS's `/usr/bin/java` is a stub that only asks for a Java.
    public let stubs: [String]
    /// Folders its own installer writes, `~/` for the home folder, where a copy counts before the shell's PATH has them
    /// (an install made since Next Term started): `~/.cargo/bin`.
    public let ownFolders: [String]
    /// Folders whose entries are installs of it (`/Library/Java/JavaVirtualMachines/*.jdk`), `~/` for the home folder.
    public let installFolders: [String]
    /// The official one-line installer, as its docs give it, typed for the user to read and run.
    public let installer: String
    /// A program the installer needs (Homebrew's `brew`); without it Install… opens `page` instead.
    public let requires: String?
    /// Where to get it by hand.
    public let page: String

    /// uv, for a pyproject.toml with a uv.lock or a `[tool.uv]` table: Astral's installer, into `~/.local/bin`.
    public static let uv = ProjectTool(
        id: "uv", name: "uv", programs: ["uv"], stubs: [], ownFolders: ["~/.local/bin", "~/.cargo/bin"], installFolders: [],
        installer: "curl -LsSf https://astral.sh/uv/install.sh | sh", requires: nil,
        page: "https://docs.astral.sh/uv/getting-started/installation/")

    /// cargo, for a Cargo.toml: rustup's official installer, into `~/.cargo` and `~/.rustup`.
    public static let cargo = ProjectTool(
        id: "cargo", name: "cargo", programs: ["cargo"], stubs: [], ownFolders: ["~/.cargo/bin"], installFolders: [],
        installer: "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh", requires: nil,
        page: "https://rustup.rs/")

    /// A JDK, for a Gradle wrapper: Eclipse Temurin through Homebrew's cask. Any JDK macOS knows counts as one.
    public static let jdk = ProjectTool(
        id: "jdk", name: "Java", programs: ["java"], stubs: ["/usr/bin/java"], ownFolders: [],
        installFolders: ["/Library/Java/JavaVirtualMachines", "~/Library/Java/JavaVirtualMachines"],
        installer: "brew install --cask temurin", requires: "brew", page: "https://adoptium.net/")

    public static let catalog: [ProjectTool] = [uv, cargo, jdk]
}

/// One offer line: the tool, what the line says, and what Install… does.
public struct ToolOffer: Sendable, Equatable, Identifiable {
    public enum Action: Sendable, Equatable {
        /// Type this into a new tab, Return left to the user.
        case type(String)
        /// Open this page: the installer needs a program this Mac lacks.
        case open(String)
    }

    public let tool: ProjectTool
    public let action: Action

    public var id: String { tool.id }
    /// "uv isn’t installed".
    public var text: String { tool.name + " isn’t installed" }
    /// The link after it.
    public static let install = "Install…"
    /// The tab Install… opens: "Install uv".
    public var tabTitle: String { "Install " + tool.name }
}

public enum ProjectTools {
    /// Where to look for a copy, and how: the login shell's PATH, the home folder, and the file system's answers. The
    /// look runs nothing.
    public struct Look {
        public var path: [String]
        public var home: String
        public var isExecutable: (String) -> Bool
        /// The names in a folder; empty when it is none.
        public var entries: (String) -> [String]

        public init(path: [String], home: String = NSHomeDirectory(),
                    isExecutable: @escaping (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
                    entries: @escaping (String) -> [String] = { (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? [] }) {
            self.path = path
            self.home = home
            self.isExecutable = isExecutable
            self.entries = entries
        }

        func expand(_ folder: String) -> String {
            folder.hasPrefix("~/") ? (home as NSString).appendingPathComponent(String(folder.dropFirst(2))) : folder
        }

        /// A program by this name along PATH or in one of `extra`, not one of `stubs`.
        func finds(_ program: String, stubs: [String] = [], extra: [String] = []) -> Bool {
            let folders = path + extra.map(expand)
            return folders.contains { (folder: String) -> Bool in
                guard !folder.isEmpty else { return false }
                let candidate = (folder as NSString).appendingPathComponent(program)
                return !stubs.contains(candidate) && isExecutable(candidate)
            }
        }
    }

    /// Whether this Mac has a copy of `tool`: on PATH (not a stub), in its installer's own folder, or installed where
    /// its installs go.
    public static func isInstalled(_ tool: ProjectTool, _ look: Look) -> Bool {
        if tool.programs.contains(where: { look.finds($0, stubs: tool.stubs, extra: tool.ownFolders) }) { return true }
        return tool.installFolders.contains { (folder: String) -> Bool in
            look.entries(look.expand(folder)).contains { (name: String) -> Bool in !name.hasPrefix(".") }
        }
    }

    /// The offers for a project that needs `needs`: one for each tool this Mac lacks, in the order needed. A tool
    /// whose installer needs a program this Mac lacks too (Homebrew) opens its page instead.
    public static func offers(for needs: [ProjectTool], _ look: Look) -> [ToolOffer] {
        needs.filter { (tool: ProjectTool) -> Bool in !isInstalled(tool, look) }.map { (tool: ProjectTool) -> ToolOffer in
            if let program = tool.requires, !look.finds(program, extra: homebrewFolders(program)) {
                return ToolOffer(tool: tool, action: .open(tool.page))
            }
            return ToolOffer(tool: tool, action: .type(tool.installer))
        }
    }

    /// Homebrew's own places, for `brew` before the shell's PATH has it: none for any other program.
    static func homebrewFolders(_ program: String) -> [String] {
        program == "brew" ? ["/opt/homebrew/bin", "/usr/local/bin"] : []
    }
}
