import Foundation

/// Whether a file's last-committed version could have changed, told from git's own files with a few stats and no git
/// run: HEAD, the branch it is on (a loose ref, or packed-refs once git packs it) and a reftable's table list. A commit,
/// a checkout, a reset or a pull rewrites one of them; editing files, staging them or `git status` refreshing the
/// index does not, and none of those changes what the last commit holds. The editor reads the committed version again
/// (two git runs) only when this changes, not on a clock.
public struct GitHeadStamp: Equatable, Sendable {
    /// The file it is for: another file, even in the same repository, has another committed version.
    public let file: String
    /// Each watched file and its stamp, nil while it is not there (a branch only in packed-refs, a repository with no
    /// reftable).
    let files: [String]
    let stamps: [FileStamp?]

    /// Nil when the file is in no repository.
    public init?(file: String) {
        guard let (gitDir, commonDir) = Self.gitDirs(above: (file as NSString).deletingLastPathComponent) else { return nil }
        let head = (try? String(contentsOfFile: gitDir + "/HEAD", encoding: .utf8)) ?? ""
        self.file = file
        files = Self.watchedFiles(gitDir: gitDir, commonDir: commonDir, head: head)
        stamps = files.map { FileStamp(path: $0) }
    }

    /// The files that move when HEAD does. `head` is the text of HEAD: "ref: refs/heads/main", or a commit when
    /// detached (then HEAD itself changes). A linked worktree has its own HEAD in `gitDir`; refs are shared, in
    /// `commonDir`.
    static func watchedFiles(gitDir: String, commonDir: String, head: String) -> [String] {
        var files = [gitDir + "/HEAD"]
        let line = head.split(separator: "\n").first.map(String.init) ?? ""
        if line.hasPrefix("ref:") {
            files.append(commonDir + "/" + line.dropFirst(4).trimmingCharacters(in: .whitespaces))
        }
        files.append(commonDir + "/packed-refs")
        files.append(commonDir + "/reftable/tables.list")
        return files
    }

    /// The repository's git folder and the one its refs live in, found from `folder` up as git finds it: `.git` as a
    /// folder, or as a file naming the folder (a linked worktree, whose commondir names the shared one, or a submodule).
    static func gitDirs(above folder: String) -> (gitDir: String, commonDir: String)? {
        var folder = folder
        while !folder.isEmpty {
            let dotGit = folder == "/" ? "/.git" : folder + "/.git"
            var info = stat()
            if stat(dotGit, &info) == 0 { // followed: a .git linked elsewhere is still the repository
                if info.st_mode & S_IFMT == S_IFDIR { return (dotGit, dotGit) }
                if let text = try? String(contentsOfFile: dotGit, encoding: .utf8),
                   let line = text.split(separator: "\n").first, line.hasPrefix("gitdir:") {
                    let gitDir = absolute(line.dropFirst(7).trimmingCharacters(in: .whitespaces), from: folder)
                    guard let common = try? String(contentsOfFile: gitDir + "/commondir", encoding: .utf8) else { return (gitDir, gitDir) }
                    return (gitDir, absolute(common.trimmingCharacters(in: .whitespacesAndNewlines), from: gitDir))
                }
            }
            if folder == "/" { return nil }
            folder = (folder as NSString).deletingLastPathComponent
        }
        return nil
    }

    private static func absolute(_ path: String, from base: String) -> String {
        path.hasPrefix("/") ? path : URL(fileURLWithPath: base).appendingPathComponent(path).standardized.path
    }
}
