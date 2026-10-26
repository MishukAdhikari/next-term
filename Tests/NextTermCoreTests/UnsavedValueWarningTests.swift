import Foundation
import Testing
@testable import NextTermCore

/// The warning before database tabs with an unsaved value close with others, with their window, or at a quit (R22).
struct UnsavedValueWarningTests {
    @Test func itNamesTheFileOrFiles() {
        #expect(UnsavedValueWarning.title(["agent.db"]) == "“agent.db” has a value you haven’t saved.")
        #expect(UnsavedValueWarning.title(["agent.db", "notes.db"]) == "“agent.db” and “notes.db” have values you haven’t saved.")
        #expect(UnsavedValueWarning.title(["a.db", "b.db", "c.db", "d.db", "e.db"])
            == "“a.db”, “b.db”, “c.db” and 2 more have values you haven’t saved.")
        // One file open in tabs of two windows: named once.
        #expect(UnsavedValueWarning.title(["agent.db", "agent.db"]) == "“agent.db” has values you haven’t saved.")
    }

    @Test func itSaysNothingIsWrittenAndHowToKeepThem() {
        #expect(UnsavedValueWarning.info(1, .close)
            == "If you close anyway, it is lost and nothing is written. To keep it, click Cancel and save it in its tab.")
        #expect(UnsavedValueWarning.info(2, .quit)
            == "If you quit anyway, they are lost and nothing is written. To keep them, click Cancel and save each in its tab.")
    }

    @Test func cancelComesFirstAndThereIsNoSave() {
        #expect(UnsavedValueWarning.buttons(.close) == ["Cancel", "Close Anyway"])
        #expect(UnsavedValueWarning.buttons(.quit) == ["Cancel", "Quit Anyway"])
        for action in [UnsavedValueWarning.Action.close, .quit] {
            #expect(!UnsavedValueWarning.buttons(action).contains { $0.contains("Save") })
        }
    }
}
