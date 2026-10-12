import Testing
@testable import NextTermCore

/// The sidebar's Services group, open or closed project by project: closed where you closed it, open where its rows
/// first appear, and never changed by a switch between projects. The paths are made up.
@Suite struct SidebarGroupExpansionTests {
    let shop = "/Projects/shop"
    let bot = "/Projects/support-bot"

    @Test func aGroupOpensTheFirstTimeItsRowsAppear() {
        var memory = SidebarGroupExpansion()
        let action = memory.rowsAppeared(in: shop, rootIsOpen: true)
        #expect(action == .expand)
    }

    @Test func aGroupYouClosedStaysClosedForThatProjectOnly() {
        var memory = SidebarGroupExpansion()
        memory.groupClosed(in: shop, rootIsOpen: true)
        let inShop = memory.rowsAppeared(in: shop, rootIsOpen: true)
        let inBot = memory.rowsAppeared(in: bot, rootIsOpen: true)
        // The outline keeps one group object for every project and can show it open from bot: it is closed again.
        let backInShop = memory.rowsAppeared(in: shop, rootIsOpen: true)
        #expect([inShop, inBot, backInShop] == [.collapse, .expand, .collapse])
    }

    @Test func aGroupThatClosedWithTheProjectsFolderIsNotRemembered() {
        var memory = SidebarGroupExpansion()
        memory.groupClosed(in: shop, rootIsOpen: false)
        let action = memory.rowsAppeared(in: shop, rootIsOpen: true)
        #expect(action == .expand)
    }

    @Test func openingTheGroupForgetsTheClose() {
        var memory = SidebarGroupExpansion()
        memory.groupClosed(in: shop, rootIsOpen: true)
        memory.groupOpened(in: shop)
        let action = memory.rowsAppeared(in: shop, rootIsOpen: true)
        #expect(action == .expand)
    }

    @Test func rowsFoundWhileTheFolderIsClosedOpenWithItOnce() {
        var memory = SidebarGroupExpansion()
        let action = memory.rowsAppeared(in: shop, rootIsOpen: false)
        let first = memory.rootOpened(shop)
        let second = memory.rootOpened(shop)
        #expect(action == .waitForRoot)
        #expect(first)
        #expect(!second, "once")
    }

    @Test func rowsOfAProjectWhoseGroupYouClosedStayClosedWhenItsFolderOpens() {
        var memory = SidebarGroupExpansion()
        memory.groupClosed(in: shop, rootIsOpen: true)
        let action = memory.rowsAppeared(in: shop, rootIsOpen: false)
        let opens = memory.rootOpened(shop)
        #expect(action == .collapse)
        #expect(!opens)
    }

    /// shop's rows came while its folder was closed. A switch to bot opens bot's saved folder before bot's rows are
    /// shown: the group must not open there, which would also forget that you closed it in bot.
    @Test func anotherProjectsWaitDoesNotOpenTheGroupAfterASwitch() {
        var memory = SidebarGroupExpansion()
        memory.groupClosed(in: bot, rootIsOpen: true)
        let inShop = memory.rowsAppeared(in: shop, rootIsOpen: false)
        let opensInBot = memory.rootOpened(bot)
        let inBot = memory.rowsAppeared(in: bot, rootIsOpen: true)
        #expect(inShop == .waitForRoot)
        #expect(!opensInBot, "the wait is shop's")
        #expect(inBot == .collapse)
        #expect(memory.isCollapsed(in: bot))
    }

    @Test func rowsAppearingAgainEndAnEarlierWait() {
        var memory = SidebarGroupExpansion()
        let inShop = memory.rowsAppeared(in: shop, rootIsOpen: false)
        let inBot = memory.rowsAppeared(in: bot, rootIsOpen: true)
        let opensInShop = memory.rootOpened(shop)
        let backInShop = memory.rowsAppeared(in: shop, rootIsOpen: true)
        #expect([inShop, inBot, backInShop] == [.waitForRoot, .expand, .expand])
        #expect(!opensInShop, "shop decides again when its rows next appear")
    }
}
