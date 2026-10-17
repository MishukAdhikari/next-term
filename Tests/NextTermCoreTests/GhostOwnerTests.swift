import Foundation
import Testing
@testable import NextTermCore

@Suite struct GhostOwnerTests {
    typealias Hook = GhostProtocol.Hook
    let plain = Hook(plugin: "zsh-autosuggestions", enabled: true, strategies: ["history"])

    func line(_ post: String?) -> GhostProtocol.BufferReport {
        GhostProtocol.BufferReport(line: 1, gen: 1, cursor: 3, buffer: "git", postdisplay: post)
    }

    @Test func whoDrawsSuggestions() {
        #expect(GhostOwner.owner(hook: plain, report: line("")) == .autosuggestions)
        // Atuin's come through the plugin, named by its strategy.
        let atuin = Hook(plugin: "zsh-autosuggestions", enabled: true, strategies: ["atuin", "history"])
        #expect(GhostOwner.owner(hook: atuin, report: nil) == .atuin)
        // Turned off (by Next Term, or by hand): nobody, so Next Term's show.
        #expect(GhostOwner.owner(hook: Hook(plugin: "zsh-autosuggestions", enabled: false), report: line("")) == nil)
        // Atuin's strategy without the plugin loaded draws nothing.
        #expect(GhostOwner.owner(hook: Hook(strategies: ["atuin"]), report: line("")) == nil)
        #expect(GhostOwner.loaded(Hook(strategies: ["atuin"])) == nil)
        #expect(GhostOwner.loaded(Hook(plugin: "zsh-autosuggestions", enabled: false, strategies: ["atuin"])) == .atuin)
        // A ghost on the line from something Next Term doesn't know: left alone, never asked about.
        let unknown = GhostOwner.owner(hook: Hook(), report: line("eckout main"))
        #expect(unknown == .unknown && unknown?.canTakeOver == false)
        #expect(GhostOwner.owner(hook: Hook(), report: line(nil)) == .unknown)
        #expect(GhostOwner.owner(hook: nil, report: line("")) == nil)
        #expect(GhostOwner.Plugin.autosuggestions.canTakeOver && GhostOwner.Plugin.atuin.canTakeOver)
    }

    @Test func theAnswerFollowsTheChoice() {
        let plugin = GhostOwner.Plugin.autosuggestions
        #expect(GhostOwner.answer(for: plugin, nextTermChosen: nil, dismissedThisLaunch: false) == .ask)
        #expect(GhostOwner.answer(for: plugin, nextTermChosen: true, dismissedThisLaunch: false) == .nextTerm)
        #expect(GhostOwner.answer(for: plugin, nextTermChosen: false, dismissedThisLaunch: false) == .plugin)
        // Not Now once: the plugin's until the next launch; a choice made since wins.
        #expect(GhostOwner.answer(for: plugin, nextTermChosen: nil, dismissedThisLaunch: true) == .plugin)
        #expect(GhostOwner.answer(for: plugin, nextTermChosen: true, dismissedThisLaunch: true) == .nextTerm)
        // Twice: for good.
        #expect(!GhostOwner.notNowIsForGood(count: 1) && GhostOwner.notNowIsForGood(count: 2))
        // An unknown plugin keeps them, chosen or not.
        #expect(GhostOwner.answer(for: .unknown, nextTermChosen: true, dismissedThisLaunch: false) == .plugin)
        #expect(GhostOwner.Plugin(id: "atuin") == .atuin && GhostOwner.Plugin(id: "unknown") == nil)
    }

    /// Once a launch in a tab, at an idle prompt, a second after the last key; never while you type.
    @Test func theQuestionWaitsForAnIdlePrompt() {
        #expect(GhostOwner.mayAsk(answer: .ask, askedBefore: false, lineEmpty: true, afterCommand: true, sinceKey: 1.2))
        #expect(!GhostOwner.mayAsk(answer: .ask, askedBefore: false, lineEmpty: true, afterCommand: true, sinceKey: 0.3))
        #expect(!GhostOwner.mayAsk(answer: .ask, askedBefore: false, lineEmpty: false, afterCommand: true, sinceKey: 5))
        #expect(!GhostOwner.mayAsk(answer: .ask, askedBefore: false, lineEmpty: true, afterCommand: false, sinceKey: 5))
        #expect(!GhostOwner.mayAsk(answer: .ask, askedBefore: true, lineEmpty: true, afterCommand: true, sinceKey: 5))
        #expect(!GhostOwner.mayAsk(answer: .plugin, askedBefore: false, lineEmpty: true, afterCommand: true, sinceKey: 5))
    }

    @Test func aNewTabIsToldWhatWasChosen() {
        #expect(GhostOwner.startValue(autosuggestions: .ask, atuin: .ask) == nil)
        #expect(GhostOwner.startValue(autosuggestions: .nextTerm, atuin: .plugin) == "t")
        #expect(GhostOwner.startValue(autosuggestions: .plugin, atuin: .nextTerm) == "a")
        #expect(GhostOwner.startValue(autosuggestions: .nextTerm, atuin: .nextTerm) == "ta")
    }
}
