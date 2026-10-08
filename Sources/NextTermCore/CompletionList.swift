import Foundation

/// What Tab completion's popup lists, from Next Term's own engine or from zsh's own matches, narrowed again
/// at each `line` report, and the private key that puts the chosen row on the line. Used from one thread at
/// a time.
public final class CompletionList: @unchecked Sendable {
    public struct Row: Equatable, Sendable {
        /// The name as shown: control and invisible characters as visible escapes.
        public var text: String
        public var description: String
        public var isFolder: Bool
        /// A folder that can't be entered.
        public var dimmed: Bool
        /// Characters of `text` to pick out.
        public var highlights: [Int]
        /// Into the engine's candidates, or zsh's index for the match.
        var source: Int
    }

    public let id: Int
    public private(set) var rows: [Row] = []
    /// How many match in all (more than `rows` when only the best are listed); `exact` false when that is
    /// not known (a folder too big to read whole, zsh's list cut at 2,000 and then narrowed).
    public private(set) var total = 0
    public private(set) var exact = true
    /// The word as the shell last reported it: what a take expects to find on the line.
    public private(set) var word: String

    private enum Source {
        case engine(CompletionContext, PathCompletion.Listing, PathCompletion.Prepared, [PathCompletion.Candidate])
        case zsh(Zsh)
        case screen(Screen)
    }

    /// A server's folders and files, for a word read off the screen (no hook there).
    private struct Screen {
        var word: ScreenWord
        var listing: PathCompletion.Listing
        var prepared: PathCompletion.Prepared
        var candidates: [PathCompletion.Candidate]
        var shell: WordQuote.Shell?
    }

    private struct Zsh {
        var matches: [CompletionProtocol.Match]
        var ranking: CompletionRanking
        var total: Int
        var stem: String
        var stemUnquoted: String
        /// The name typed when zsh listed: for it, every match zsh gave is shown, as zsh would.
        var listedFor: String?
    }

    private var source: Source

    /// Next Term's own list: the `tab` report's context, the folder's listing, and the candidates already
    /// found for the word as reported.
    public init(id: Int, context: CompletionContext, listing: PathCompletion.Listing, prepared: PathCompletion.Prepared,
                result: PathCompletion.Result) {
        self.id = id
        word = context.word
        source = .engine(context, listing, prepared, result.candidates)
        show(result)
    }

    /// zsh's own list (CompAssembler's), with the stem the matches follow. Rows come with the first `line`.
    public init(id: Int, matches: [CompletionProtocol.Match], total: Int, stem: String, stemUnquoted: String) {
        self.id = id
        word = stem
        let ranking = CompletionRanking(names: matches.map(\.text))
        source = .zsh(Zsh(matches: matches, ranking: ranking, total: total, stem: stem, stemUnquoted: stemUnquoted, listedFor: nil))
        self.total = total
        exact = total <= matches.count
    }

    /// A server's folders and files for a word on its screen (RemoteListing): its rows are those the server's
    /// shell can take as typed.
    public init(id: Int, screen word: ScreenWord, listing: PathCompletion.Listing, disk: PathCompletion.Disk, shell: WordQuote.Shell?) {
        self.id = id
        self.word = word.word
        let prepared = PathCompletion.Prepared(listing, foldersOnly: word.kind == .folders, hidden: word.typed.hasPrefix("."), disk: disk)
        let result = Self.typable(prepared.candidates(word.typed), shell: shell)
        source = .screen(Screen(word: word, listing: listing, prepared: prepared, candidates: result.candidates, shell: shell))
        show(result)
    }

    public var isZsh: Bool {
        if case .zsh = source { return true }
        return false
    }

    /// The screen's word now (a key echoed). False when the list no longer fits it: the list closes.
    public func update(screen now: ScreenWord) -> Bool {
        guard case var .screen(screen) = source, now.before == screen.word.before, now.folder == screen.word.folder else { return false }
        if now.typed.hasPrefix(".") != screen.prepared.hidden {
            screen.prepared = PathCompletion.Prepared(screen.listing, foldersOnly: now.kind == .folders, hidden: now.typed.hasPrefix("."),
                                                      disk: screen.prepared.disk)
        }
        let result = Self.typable(screen.prepared.candidates(now.typed), shell: screen.shell)
        screen.word = now
        screen.candidates = result.candidates
        source = .screen(screen)
        word = now.word
        show(result)
        return true
    }

    /// The keys that put row `index` in place of the name typed on screen (`now`): Backspaces for what must go,
    /// then the rest as text. Only appending, or replacing a name typed in plain ASCII. nil: it can't be put on
    /// the line from here.
    public func screenInsertion(_ index: Int, at now: ScreenWord) -> (erase: Int, text: String)? {
        screenCandidate(index).flatMap { screenInsertion($0, at: now) }
    }

    /// Row `index`'s name and kind on a server's list (kept while the keys typed before it echo).
    public func screenCandidate(_ index: Int) -> PathCompletion.Candidate? {
        guard case let .screen(screen) = source, rows.indices.contains(index) else { return nil }
        return screen.candidates[rows[index].source]
    }

    public func screenInsertion(_ candidate: PathCompletion.Candidate, at now: ScreenWord) -> (erase: Int, text: String)? {
        guard case let .screen(screen) = source, now.before == screen.word.before, now.folder == screen.word.folder else { return nil }
        guard let quoted = RemoteListing.typable(candidate.name, shell: screen.shell) else { return nil }
        let whole = quoted + WordQuote.ending(folder: candidate.isFolder, in: .unquoted)
        if whole.utf8.starts(with: now.typed.utf8) { return (0, String(decoding: whole.utf8.dropFirst(now.typed.utf8.count), as: UTF8.self)) }
        guard now.typed.allSatisfy(\.isASCII) else { return nil }
        return (now.typed.utf8.count, whole)
    }

    /// The answer to a Tab on a server's screen: no candidate is the shell's own Tab, one that starts with the
    /// name typed goes in at once (screenInsertion of row 0), anything else opens the list.
    public var screenVerdict: CompletionState.Verdict {
        guard case let .screen(screen) = source, let first = screen.candidates.first else { return .native }
        if total == 1, first.prefix, screenInsertion(0, at: screen.word) != nil { return .insert }
        return .open
    }

    /// The word the list was made for, or last narrowed to, on a server's screen.
    public var screenWord: ScreenWord? {
        if case let .screen(screen) = source { return screen.word }
        return nil
    }

    /// Candidates whose names the server's shell can take as typed.
    private static func typable(_ result: PathCompletion.Result, shell: WordQuote.Shell?) -> PathCompletion.Result {
        var kept = result
        kept.candidates = result.candidates.filter { RemoteListing.typable($0.name, shell: shell) != nil }
        kept.total -= result.candidates.count - kept.candidates.count
        return kept
    }

    /// A `line` report: the word now. False when the list no longer fits it (another folder, a quote closed,
    /// the stem gone): the list closes.
    public func update(word now: String, unquoted: String) -> Bool {
        switch source {
        case let .engine(context, listing, prepared, _):
            guard let next = context.with(word: now) else { return false }
            var narrowed = prepared
            if next.showsHidden != prepared.hidden {
                narrowed = PathCompletion.Prepared(listing, foldersOnly: next.kind == .folders, hidden: next.showsHidden, disk: prepared.disk)
            }
            let result = narrowed.candidates(next.typed)
            source = .engine(next, listing, narrowed, result.candidates)
            word = now
            show(result)
            return true
        case var .zsh(zsh):
            guard unquoted.hasPrefix(zsh.stemUnquoted) else { return false }
            let typed = String(unquoted.dropFirst(zsh.stemUnquoted.count))
            if zsh.listedFor == nil { zsh.listedFor = typed }
            word = now
            // For the name zsh listed, all of zsh's matches; for one typed since, the ones that still match it.
            let ranked = zsh.ranking.rank(typed == zsh.listedFor ? "" : typed)
            rows = ranked.map { item in
                let match = zsh.matches[item.index]
                return Self.row(match.text, description: match.description, isFolder: match.kind == .folder, dimmed: false,
                                highlights: item.highlights, source: match.index)
            }
            let all = typed == zsh.listedFor
            total = all ? zsh.total : rows.count
            exact = zsh.total <= zsh.matches.count
            source = .zsh(zsh)
            return true
        case .screen:
            return false // a server's list narrows from its screen: update(screen:)
        }
    }

    /// The private key that puts row `index` on the line; nil when it can't be written (a name sh can't take).
    public func take(_ index: Int) -> [UInt8]? {
        guard rows.indices.contains(index) else { return nil }
        let row = rows[index]
        switch source {
        case let .engine(context, _, _, candidates):
            let candidate = candidates[row.source]
            guard let replacement = context.replacement(name: candidate.name, folder: candidate.isFolder) else { return nil }
            return CompletionProtocol.takeWord(id: id, old: word, new: replacement)
        case .zsh:
            return CompletionProtocol.takeMatch(id: id, old: word, index: row.source)
        case .screen:
            return nil // keys typed as text: screenInsertion
        }
    }

    private func show(_ result: PathCompletion.Result) {
        rows = result.candidates.enumerated().map { index, candidate in
            Self.row(candidate.display, description: "", isFolder: candidate.isFolder, dimmed: !candidate.enterable,
                     highlights: candidate.highlights, source: index)
        }
        total = result.total
        exact = result.exact
    }

    private static func row(_ name: String, description: String, isFolder: Bool, dimmed: Bool, highlights: [Int], source: Int) -> Row {
        let text = CompletionRanking.visible(name)
        let shown = text == name ? highlights : []
        return Row(text: text, description: CompletionRanking.visible(description), isFolder: isFolder, dimmed: dimmed,
                   highlights: shown, source: source)
    }
}

/// Next Term's own engine's answer to a `tab` report: no candidate is zsh's own Tab, one that starts with the
/// name typed goes in at once, anything else opens the list.
public enum CompletionVerdict: Equatable, Sendable {
    case native
    case insert(String)
    case open

    public static func of(_ result: PathCompletion.Result, context: CompletionContext) -> CompletionVerdict {
        guard let first = result.candidates.first else { return .native }
        if result.total == 1, first.prefix {
            guard let word = context.replacement(name: first.name, folder: first.isFolder) else { return .native }
            return .insert(word)
        }
        return .open
    }
}
