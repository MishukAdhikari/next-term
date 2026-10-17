import Foundation
import Testing
@testable import NextTermCore

/// "Ask for Touch ID every time it's used": while any key a request names asks every time, the panel offers only
/// Allow once, and grants already holding that key end. Every value is made up.
@Suite struct SecretApprovalChoicesTests {
    /// A vault holding `ASKS_KEY`, which asks every time, and `LASTING_KEY`, which the user let approvals outlast.
    static func index() throws -> SecretVault.Index {
        let vault: SecretVault = try SecretVault.create(keyring: SoftwareKeyring()).vault
        _ = try vault.add(name: "ASKS_KEY", purpose: "asks", purposeBy: .user, origin: .settings, writeOnly: false,
                          value: SecretBytes(utf8: "made-up-asks-value-0123456789"))
        _ = try vault.add(name: "LASTING_KEY", purpose: "lasting", purposeBy: .user, origin: .settings, writeOnly: false,
                          value: SecretBytes(utf8: "made-up-lasting-value-0123456789"), asksEveryUse: false)
        return vault.index
    }

    @Test func aKeyThatLetsApprovalsLastOffersWhatTheRequestAllows() {
        let tool: [SecretApprovalChoice] = SecretApprovalChoices.offered(isWrapper: false, isRemote: false, asksEveryUse: false)
        #expect(tool == [.once, .fifteenMinutes])
        let wrapper: [SecretApprovalChoice] = SecretApprovalChoices.offered(isWrapper: true, isRemote: false, asksEveryUse: false)
        #expect(wrapper == [.once, .fifteenMinutes, .untilLock])
    }

    @Test func aKeyThatAsksEveryTimeOffersOnlyAllowOnce() {
        for isWrapper in [false, true] {
            for isRemote in [false, true] {
                let offered = SecretApprovalChoices.offered(isWrapper: isWrapper, isRemote: isRemote, asksEveryUse: true)
                #expect(offered == [.once], "wrapper \(isWrapper), remote \(isRemote)")
            }
        }
    }

    /// A remote connection never gets a lasting approval, whatever the key says.
    @Test func aRemoteRequestOffersOnlyAllowOnce() {
        for isWrapper in [false, true] {
            #expect(SecretApprovalChoices.offered(isWrapper: isWrapper, isRemote: true, asksEveryUse: false) == [.once])
        }
    }

    @Test func oneKeyThatAsksMakesTheWholeRequestAsk() throws {
        let index = try Self.index()
        #expect(SecretApprovalChoices.askingEveryUse(["LASTING_KEY"], in: index).isEmpty)
        #expect(SecretApprovalChoices.askingEveryUse(["ASKS_KEY"], in: index) == ["ASKS_KEY"])
        #expect(SecretApprovalChoices.askingEveryUse(["LASTING_KEY", "ASKS_KEY"], in: index) == ["ASKS_KEY"])
    }

    /// A name the vault doesn't hold, or no vault to read, is never trusted with a lasting approval.
    @Test func aKeyNotFoundAsksEveryTime() throws {
        let index = try Self.index()
        #expect(SecretApprovalChoices.askingEveryUse(["GONE_KEY", "LASTING_KEY"], in: index) == ["GONE_KEY"])
        #expect(SecretApprovalChoices.askingEveryUse(["LASTING_KEY"], in: nil) == ["LASTING_KEY"])
        #expect(SecretApprovalChoices.askingEveryUse([], in: index).isEmpty)
    }

    /// The box ticked while the panel was up: Allow keeps a choice only while it is still offered.
    @Test func aChoiceNoLongerOfferedFallsToAllowOnce() {
        let all: [SecretApprovalChoice] = [.once, .fifteenMinutes, .untilLock]
        for choice in all {
            #expect(SecretApprovalChoices.kept(choice, offered: all) == choice)
            #expect(SecretApprovalChoices.kept(choice, offered: [.once]) == .once)
        }
        #expect(SecretApprovalChoices.kept(.untilLock, offered: [.once, .fifteenMinutes]) == .once)
    }

    @Test func eachChoiceIsItsAuditWordAndGrant() {
        #expect(SecretApprovalChoice.once.approval == .once && SecretApprovalChoice.once.grantKind == nil)
        #expect(SecretApprovalChoice.fifteenMinutes.approval == .fifteenMinutes)
        #expect(SecretApprovalChoice.fifteenMinutes.grantKind == .fifteenMinutes)
        #expect(SecretApprovalChoice.untilLock.approval == .untilLock && SecretApprovalChoice.untilLock.grantKind == .untilLock)
    }
}

@Suite struct SecretAskEveryUseGrantTests {
    let start = ContinuousClock.now

    private func binding(_ keys: [String], tab: String = "tab-2") -> SecretBinding {
        let pairs: [(String, String)] = keys.map { (name: String) -> (String, String) in (name, name) }
        return SecretBinding(source: .tool, asker: tab, program: "claude", command: ["npm test"],
                             keys: Dictionary(uniqueKeysWithValues: pairs), folder: "/Users/me/api", target: "new")
    }

    /// Ticking the box ends every grant that holds the key, and only those.
    @Test func tickingTheBoxEndsTheGrantsHoldingTheKey() {
        var book = SecretGrantBook()
        book.add(SecretGrant(kind: .fifteenMinutes, binding: binding(["ASKS_KEY"]), made: start, id: "one"))
        book.add(SecretGrant(kind: .untilLock, binding: binding(["ASKS_KEY", "LASTING_KEY"]), made: start, id: "both"))
        book.add(SecretGrant(kind: .fifteenMinutes, binding: binding(["LASTING_KEY"]), made: start, id: "other"))
        book.add(SecretGrant(kind: .oneUse, binding: binding(["ASKS_KEY"], tab: "tab-3"), made: start, id: "restart"))
        let ended: [String] = book.end(.askEveryUse("ASKS_KEY")).map(\.id).sorted()
        #expect(ended == ["both", "one"])
        // Allow once's single use, kept for a wrapper's restart, is that one approval: it stays.
        #expect(book.grants.map(\.id) == ["other", "restart"])
        #expect(book.end(.askEveryUse("STRIPE_KEY")).isEmpty)
    }

    /// The keys the grants in force hold that ask every time now: a key ticked here, one ticked by another copy of
    /// Next Term, or one gone from the vault.
    @Test func theGrantsToEndAreTheOnesHoldingAKeyThatAsks() throws {
        let index = try SecretApprovalChoicesTests.index()
        let grants: [SecretGrant] = [
            SecretGrant(kind: .fifteenMinutes, binding: binding(["LASTING_KEY"]), made: start, id: "lasting"),
            SecretGrant(kind: .fifteenMinutes, binding: binding(["ASKS_KEY", "LASTING_KEY"]), made: start, id: "asks"),
            SecretGrant(kind: .untilLock, binding: binding(["GONE_KEY"]), made: start, id: "gone"),
            SecretGrant(kind: .oneUse, binding: binding(["ONCE_KEY"]), made: start, id: "once"),
        ]
        #expect(SecretApprovalChoices.askingNames(heldBy: grants, in: index) == ["ASKS_KEY", "GONE_KEY"])
        #expect(SecretApprovalChoices.askingNames(heldBy: [grants[0]], in: index).isEmpty)
        #expect(SecretApprovalChoices.askingNames(heldBy: [], in: nil).isEmpty)
    }
}
