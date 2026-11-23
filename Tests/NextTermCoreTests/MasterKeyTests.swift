import Foundation
import Testing
@testable import NextTermCore

struct MasterKeyTests {
    // Few rounds: the tests check the logic, not the cost.
    let rounds: UInt32 = 1_000
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    func record(_ key: String = "correct horse battery", recovery: String = "AAAA-BBBB-CCCC-DDDD") -> MasterKeyRecord {
        MasterKey.set(key, recovery: recovery, now: start, rounds: rounds)
    }

    @Test func onlyVerifiersAreStored() throws {
        let made = record()
        let json = String(decoding: try JSONEncoder().encode(made), as: UTF8.self)
        #expect(!json.contains("correct horse") && !json.contains("AAAA"))
        #expect(made.key.matches("correct horse battery") && !made.key.matches("correct horse batterY"))
        #expect(made.key.salt != made.recovery.salt)
        #expect(MasterKey.set("correct horse battery", recovery: "x", rounds: rounds).key.check != made.key.check)
    }

    @Test func weakKeysAreRefused() {
        #expect(MasterKey.weakness(of: "short") == .tooShort)
        #expect(MasterKey.weakness(of: "aaaaaaaaaaaaaa") == .allOneCharacter)
        #expect(MasterKey.weakness(of: "abcd-efgh-jkmn-pqrs", recovery: "ABCDEFGHJKMNPQRS") == .sameAsRecoveryKey)
        #expect(MasterKey.weakness(of: "correct horse battery") == nil)
    }

    @Test func recoveryKeysAreLongAndReadAsTyped() {
        let key = MasterKey.makeRecoveryKey()
        #expect(key.split(separator: "-").count == 8 && key.split(separator: "-").allSatisfy { $0.count == 4 })
        #expect(!key.contains("0") && !key.contains("O") && !key.contains("1") && !key.contains("I"))
        #expect(MasterKey.makeRecoveryKey() != key)
        #expect(MasterKey.normalizedRecovery(" aaaa bbbb-cccc ") == "AAAABBBBCCCC")
    }

    @Test func wrongTriesWaitLongerThenLockOut() {
        var made = record()
        var now = start
        for left in stride(from: MasterKey.freeTries - 1, through: 0, by: -1) {
            #expect(MasterKey.attempt("nope", record: &made, onMac: false, now: now) == .wrong(triesLeftBeforeWait: left))
        }
        #expect(MasterKey.attempt("correct horse battery", record: &made, onMac: false, now: now) == .wait(seconds: 30))
        now = now.addingTimeInterval(30)
        #expect(MasterKey.attempt("nope", record: &made, onMac: false, now: now) == .wrong(triesLeftBeforeWait: 0))
        #expect(MasterKey.waitLeft(made, now: now) == 60)
        for _ in 0..<3 {
            now = now.addingTimeInterval(MasterKey.waitLeft(made, now: now))
            _ = MasterKey.attempt("nope", record: &made, onMac: false, now: now)
        }
        now = now.addingTimeInterval(MasterKey.waitLeft(made, now: now))
        #expect(MasterKey.attempt("nope", record: &made, onMac: false, now: now) == .lockedOut)
        #expect(MasterKey.lockedOut(made))
        // Locked out: only the right key, typed on the Mac, clears it.
        now = now.addingTimeInterval(10_000_000)
        #expect(MasterKey.attempt("correct horse battery", record: &made, onMac: false, now: now) == .lockedOut)
        #expect(MasterKey.attempt("correct horse battery", record: &made, onMac: true, now: now) == .right)
        #expect(made.wrongTries == 0 && !MasterKey.lockedOut(made))
    }

    @Test func changingNeedsTheCurrentKey() throws {
        var made = record()
        let refused = MasterKey.change(current: "wrong one here", to: "a brand new passphrase", record: &made, now: start, rounds: rounds)
        #expect(refused == .failure(.wrongKey(.wrong(triesLeftBeforeWait: 4))))
        #expect(MasterKey.change(current: "correct horse battery", to: "short", record: &made, now: start, rounds: rounds)
            == .failure(.weak(.tooShort)))
        #expect(MasterKey.change(current: "correct horse battery", to: "correct horse battery", record: &made, now: start, rounds: rounds)
            == .failure(.sameAsBefore))
        let changed = try MasterKey.change(current: "correct horse battery", to: "a brand new passphrase", record: &made,
                                           now: start, rounds: rounds).get()
        #expect(changed.key.matches("a brand new passphrase") && !changed.key.matches("correct horse battery"))
        #expect(changed.recovery == made.recovery) // the recovery key stays unless a new one is given
    }

    @Test func theRecoveryKeyReplacesAForgottenKeyAndIsReplacedToo() throws {
        var made = record()
        let refused = MasterKey.recover(with: "ZZZZ-ZZZZ-ZZZZ-ZZZZ", newKey: "a brand new passphrase", newRecovery: "NEWW-NEWW-NEWW-NEWW",
                                        record: &made, now: start, rounds: rounds)
        #expect(refused == .failure(.wrongKey(.wrong(triesLeftBeforeWait: 4))))
        let recovered = try MasterKey.recover(with: "aaaa bbbb cccc dddd", newKey: "a brand new passphrase", newRecovery: "NEWW-NEWW-NEWW-NEWW",
                                              record: &made, now: start, rounds: rounds).get()
        #expect(recovered.key.matches("a brand new passphrase"))
        #expect(recovered.recovery.matches("NEWWNEWWNEWWNEWW") && !recovered.recovery.matches("AAAABBBBCCCCDDDD"))
        #expect(recovered.wrongTries == 0)
    }

    @Test func anEmptyTryIsJustWrong() {
        var made = record()
        #expect(MasterKey.attempt("", record: &made, onMac: true, now: start) == .wrong(triesLeftBeforeWait: 4))
    }
}
