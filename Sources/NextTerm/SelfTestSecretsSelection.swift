import AppKit
import NextTermCore

#if DEBUG
extension SelfTest {
    /// A reload keeps the selected key by its id, not its row (review finding #25): with SELECT_B selected, SELECT_A
    /// deleted elsewhere (the other Secrets view, or another copy of Next Term) leaves SELECT_B selected, not the key that
    /// moved into its row; SELECT_B renamed stays selected; deleted, it leaves nothing selected, so Reveal, Copy and
    /// Delete… act on no other key.
    static func secretsSelectionChecks(view: SecretsView) async {
        let store = SecretsStore.shared
        let names = ["SELECT_A", "SELECT_B", "SELECT_C"]
        for name in names {
            let value = SecretBytes(utf8: secretsValue(name.lowercased()))
            _ = try? await store.perform(.add(name: name, purpose: "the selection checks", purposeBy: .user, origin: .settings,
                                              writeOnly: false, value: value))
        }
        view.reload()
        view.select("SELECT_B")
        let picked = view.selectedEntry?.name
        _ = try? await store.perform(.delete(name: "SELECT_A"))
        view.reload()
        let kept = view.selectedEntry?.name
        check(picked == "SELECT_B" && kept == "SELECT_B",
              "secrets: a key deleted elsewhere leaves the selected key selected, found by its id", kept ?? "nothing selected")
        _ = try? await store.perform(.edit(name: "SELECT_B", newName: "SELECT_B2", purpose: nil, purposeBy: .user))
        view.reload()
        let renamed = view.selectedEntry?.name
        check(renamed == "SELECT_B2" && view.editButton.isEnabled,
              "secrets: the selected key renamed stays selected, with Edit… on", renamed ?? "nothing selected")
        _ = try? await store.perform(.delete(name: "SELECT_B2"))
        view.reload()
        let after = view.selectedEntry?.name
        check(after == nil && !view.deleteButton.isEnabled,
              "secrets: the selected key deleted elsewhere leaves nothing selected, not the key now in its row", after ?? "nothing selected")
        for name in names + ["SELECT_B2"] where store.index?.entry(named: name) != nil {
            _ = try? await store.perform(.delete(name: name))
        }
    }
}
#endif
