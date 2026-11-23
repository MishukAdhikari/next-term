import Foundation

extension AgentScreen {
    /// Command Code's own shapes (1.9x): the mode line under its prompt, which says it waits for you. Its working hint
    /// ("esc to interrupt") shows whenever it works, and its screen keeps drawing while it waits, so output timing never
    /// says when it stopped; its prompt does (`AgentActivity.waiting`). Its questions (folder trust, "Build Your Coding
    /// Taste") are numbered lists over its own hint, read as every agent's (`AgentScreen.listQuestion`).
    public enum CommandCode {
        /// The mode line under the prompt: "? for shortcuts", or the mode it is in ("» accept edits on (shift+tab to
        /// cycle)", "» permission bypass on", "» don't-ask on", "plan mode"), or "Press Ctrl+C again to exit".
        static let modeLine = try! NSRegularExpression(
            pattern: #"^(?:\? for shortcuts|» (?:permission bypass|accept edits|don['’]t-ask) on\b|plan mode \(|Press Ctrl\+C again to exit)"#)
        /// The mode line is at the bottom: in the last rows, under the prompt.
        static let footerRows = 4

        /// Its prompt's mode line is in the last rows of `lines`.
        static func waits(_ lines: [String]) -> Bool {
            let rows = lines.reversed().lazy.filter { !ScreenText.isBlank($0) }.prefix(footerRows)
            return rows.contains { (line: String) -> Bool in
                let text = line.trimmingCharacters(in: .whitespaces)
                return modeLine.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
            }
        }
    }
}
