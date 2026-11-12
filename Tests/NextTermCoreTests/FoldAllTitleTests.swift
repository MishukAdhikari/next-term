import Testing
@testable import NextTermCore

@Suite struct FoldAllTitleTests {
    /// Collapse All while any file is open, Expand All only once every file is folded, as a click acts.
    @Test func followsTheFilesOneByOne() {
        #expect(FoldAllTitle.title(collapsed: [false, false]) == "Collapse All")
        #expect(FoldAllTitle.title(collapsed: [true, false]) == "Collapse All")
        #expect(FoldAllTitle.title(collapsed: [true, true]) == "Expand All")
        #expect(FoldAllTitle.title(collapsed: [false, true, true]) == "Collapse All")
    }
}
