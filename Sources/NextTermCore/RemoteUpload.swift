import Foundation

/// A drop on a remote tab, or an image pasted into one, copied to the host before anything is pasted: the dropped
/// items go over the tab's own ssh connection as one tar stream on the script's stdin, into a new folder only the user
/// can read (`umask 077`, `mktemp -d` under `$TMPDIR`, else /tmp), and the paths there are what gets pasted, quoted, as
/// a drop on a local tab pastes this Mac's. Nothing but the items' contents and names leaves this Mac, and the names
/// travel inside the stream, never in the script. Next Term never deletes the folder: the host's own temp cleanup does,
/// and the note names it.
public enum RemoteUpload {
    /// The most items one drop copies, and the most bytes in all.
    public static let maxItems = 32
    public static let maxBytes = 64 * 1024 * 1024

    /// Why a drop of `items` items (each one dropped, a folder counting once) holding `bytes` in all copies nothing; nil
    /// when it goes.
    public static func refusal(items: Int, bytes: Int, names: [String] = []) -> String? {
        if items == 0 { return "Nothing to copy." }
        if items > maxItems { return "That is \(items) items; a drop on a server copies \(maxItems) at most. Nothing was pasted." }
        if bytes > maxBytes {
            let shown = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            return "That is \(shown); a drop on a server copies 64 MB at most. Nothing was pasted."
        }
        if Set(names).count < names.count { return "Two of the dropped items have the same name; drop them one at a time. Nothing was pasted." }
        return nil
    }

    /// The host's side: the folder, the stream unpacked into it, and what came of it after RemoteShell.marker: `dir<TAB>`
    /// and the folder, or `fail<TAB>` and why, then `end`.
    public static let script = #"""
        printf '\n%s\n' \#(RemoteShell.quote(RemoteShell.marker))
        umask 077
        nt_d=$(mktemp -d "${TMPDIR:-/tmp}/next-term-drop.XXXXXX" 2>/dev/null) || nt_d=
        if [ -z "$nt_d" ] || [ ! -d "$nt_d" ]; then
          printf 'fail\t%s\n' 'no private folder could be made on the host'
          printf 'end\n'
          exit 0
        fi
        nt_e=$(tar -xf - -C "$nt_d" 2>&1); nt_x=$?
        if [ "$nt_x" -eq 0 ]; then
          printf 'dir\t%s\n' "$nt_d"
        else
          printf 'fail\t%s\n' "$(printf '%s' "$nt_e" | tr '\n\t' '  ' | tr -d '\000-\037\177' | head -c 300)"
        fi
        printf 'end\n'
        """#

    /// The folder the script made and unpacked into, or why it did not; a cut answer (no `end`) is a failure, and
    /// nothing is pasted.
    public static func folder(_ output: String) -> Result<String, UploadError> {
        guard let lines = RemoteShell.payload(output) else { return .failure(UploadError("The host did not answer.")) }
        var folder: String?
        var why: String?
        var ended = false
        for line in lines {
            if line == "end" {
                ended = true
                break
            }
            let fields = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 2 else { continue }
            if fields[0] == "dir", fields[1].hasPrefix("/") { folder = fields[1] }
            if fields[0] == "fail" { why = fields[1] }
        }
        guard ended else { return .failure(UploadError("The copy was cut off; nothing was pasted.")) }
        if let folder { return .success(folder) }
        return .failure(UploadError("The copy failed on the host: " + (why ?? "it said nothing") + ". Nothing was pasted."))
    }

    /// What is pasted: the copied items' paths on the host, quoted for its shell, with a space after the last, as a
    /// local drop pastes.
    public static func pasted(folder: String, names: [String]) -> String {
        names.map { RemoteShell.quote(folder + "/" + $0) }.joined(separator: " ") + " "
    }

    /// The name a pasted image gets: `pasted-<yyyyMMdd-HHmmss>.png`, in this Mac's time.
    public static func imageName(at date: Date) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyyMMdd-HHmmss"
        return "pasted-\(format.string(from: date)).png"
    }

    public struct UploadError: Error, Equatable {
        public let text: String
        public init(_ text: String) { self.text = text }
    }
}
