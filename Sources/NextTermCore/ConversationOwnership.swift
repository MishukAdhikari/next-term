import Foundation

/// One place per conversation (plan 037 KTD11): a Claude Code or Codex conversation is live in at most one tab, since
/// both agents append to one transcript or rollout file per conversation and two live processes writing one would
/// interleave its turns. These are the rules alone; ConversationOwners, in the app, gathers the tabs that may hold one.
public enum ConversationOwnership {
    /// A tab that may hold a conversation now, and how it is known.
    public struct Holder: Equatable, Sendable {
        public var tab: UUID
        /// The tab's title, as the refusal names it.
        public var title: String
        /// The session catalog's agent id (`claude`, `codex`).
        public var agent: String
        /// The conversation's id: a chat host's reported id, or a terminal agent's evidence.
        public var sessionID: String?
        /// How the id is known: a chat host's own report, or a terminal agent's own record of the conversation it has
        /// open (Claude Code's session file, Codex's open rollout). An id from the typed line or a guess is the one it
        /// started with or none at all, so it holds nothing here.
        public var exact: Bool
        /// The agent runs now: a chat that ended or waits for Resume, or a terminal whose agent quit, holds nothing.
        public var live: Bool

        public init(tab: UUID, title: String, agent: String, sessionID: String?, exact: Bool, live: Bool) {
            self.tab = tab
            self.title = title
            self.agent = agent
            self.sessionID = sessionID
            self.exact = exact
            self.live = live
        }
    }

    /// The tab where `agent`'s conversation `sessionID` is live, other than `excluding`, or nil. Ids match whatever
    /// their case. Holders are looked at in the order given, so the caller lists chat hosts first, which are cheap.
    public static func owner(agent: String, sessionID: String, excluding: UUID? = nil, among holders: [Holder]) -> Holder? {
        let wanted = sessionID.lowercased()
        guard !wanted.isEmpty else { return nil }
        return holders.first { (holder: Holder) -> Bool in
            holder.tab != excluding && holder.live && holder.exact && holder.agent == agent
                && holder.sessionID?.lowercased() == wanted
        }
    }

    /// The id sources that say which conversation a terminal agent has open now: its own record of it.
    public static func isExact(_ source: SessionSnapshot.IDSource?) -> Bool {
        source.map(ConversationHandoff.ownRecord.contains) ?? false
    }
}
