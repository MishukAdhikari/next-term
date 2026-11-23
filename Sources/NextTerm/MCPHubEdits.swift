import AppKit
import NextTermCore

/// The changes Settings › MCP Servers makes to the MCP hub's lists (MCPHubScope.write), and its one Undo. A change is
/// all or nothing: one that fails part way puts back what it had written. Undo puts each list back as it was before the
/// last change, only while each is still what that change left (a hand edit since is never overwritten).
///
/// A project's list the user changes here was theirs to read first: when it was approved as it was, the approval moves
/// with it to its new bytes, so the user's own edit never leaves its servers waiting. One that wasn't approved stays
/// waiting.
@MainActor
enum MCPHubEdits {
    struct Edit {
        let title: String
        let writes: [MCPHubScope.Written]
    }

    /// The last change, for Undo.
    private(set) static var last: Edit?

    /// The user's list: the self-test's own while it runs.
    static var userFile: String { MCPHubControl.userFile ?? MCPHubScope.userPath() }

    /// One change to one list.
    struct Step {
        let change: MCPHubFile.Change
        let file: String
        let place: MCPHubFile.Place
    }

    /// Makes the steps, in order, as one change titled `title`. Nil when done (or nothing changed); else why not, in a
    /// sentence, with nothing changed.
    @discardableResult
    static func apply(_ title: String, _ steps: [Step]) -> String? {
        var writes: [MCPHubScope.Written] = []
        func fail(_ failure: MCPHubScope.SaveFailure) -> String {
            for written in writes.reversed() { _ = MCPHubScope.undo(written) }
            return sentence(failure)
        }
        for step in steps {
            let approvedBefore = step.place == .project ? wasApproved(step.file) : false
            switch MCPHubScope.write(step.change, to: step.file, place: step.place) {
            case .failure(let failure): return fail(failure)
            case .success(nil): continue
            case .success(let written?):
                writes.append(written)
                guard step.place == .project, approvedBefore else { continue }
                let change = MCPHubFile.Change.approve(file: step.file, digest: SecretRun.digest(written.after))
                switch MCPHubScope.write(change, to: userFile, place: .user) {
                case .failure(let failure): return fail(failure)
                case .success(let approval): if let approval { writes.append(approval) }
                }
            }
        }
        if !writes.isEmpty {
            last = Edit(title: title, writes: writes)
            NotificationCenter.default.post(name: MCPHubControl.changed, object: nil)
        }
        return nil
    }

    /// Undoes the last change: nil when done, else why not.
    @discardableResult
    static func undo() -> String? {
        guard let edit = last else { return nil }
        for written in edit.writes.reversed() {
            if case .failure(let failure) = MCPHubScope.undo(written) {
                last = nil
                NotificationCenter.default.post(name: MCPHubControl.changed, object: nil)
                return "Undo stopped: " + sentence(failure)
            }
        }
        last = nil
        NotificationCenter.default.post(name: MCPHubControl.changed, object: nil)
        return nil
    }

    /// Whether a project's list, as it is now, is approved (or isn't there yet: a list the user starts here is theirs).
    static func wasApproved(_ file: String) -> Bool {
        let folder = (file as NSString).deletingLastPathComponent
        guard FileManager.default.fileExists(atPath: file) else { return true }
        guard let text = SkillLibrary.readText(file, in: folder) else { return false }
        return choices().isApproved(file, digest: SecretRun.digest(Data(text.utf8)))
    }

    /// The user's choices as their list has them now.
    static func choices() -> MCPHubChoices {
        let found = MCPHubScope.sources(folder: nil, home: NSHomeDirectory(), userFile: userFile)
        guard case .success(let read)? = found.user?.read else { return MCPHubChoices() }
        return MCPHubChoices.read(read.document)
    }

    static func sentence(_ failure: MCPHubScope.SaveFailure) -> String {
        switch failure {
        case .refused(.invalid(let reasons)): return reasons.joined(separator: " ")
        case .refused(.unreadable(let problem)): return "Next Term can\u{2019}t use the list: \(problem.reason). Fix it, then try again."
        case .write(.changed): return "The list changed on disk since Next Term read it. Look again, then try again."
        case .write(let other): return "The list couldn\u{2019}t be written: \(other.localizedDescription)"
        }
    }
}
