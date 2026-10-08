import Testing
@testable import NextTermCore

@Suite struct CompletionOwnerTests {
    func arm(_ widget: String, _ definition: String, plugins: [String] = [], compsys: Bool = false) -> CompletionProtocol.Arm {
        .init(completionSystem: compsys, tabWidget: widget, tabWidgetDefinition: definition, plugins: plugins)
    }

    @Test func zshsOwnTabAsksNothing() {
        #expect(CompletionOwner.plugin(arm("expand-or-complete", "builtin")) == nil)
        #expect(CompletionOwner.plugin(arm("expand-or-complete", "completion:.expand-or-complete:_main_complete", compsys: true)) == nil)
        #expect(CompletionOwner.plugin(arm("complete-word", "completion:.complete-word:_main_complete", compsys: true)) == nil)
        #expect(CompletionOwner.plugin(arm("menu-complete", "builtin")) == nil)
        #expect(CompletionOwner.plugin(arm("expand-or-complete-with-dots", "user:expand-or-complete-with-dots")) == nil) // oh-my-zsh
        #expect(CompletionOwner.plugin(arm("fzf-completion", "user:fzf-completion", plugins: ["fzf"])) == nil)            // fzf's **
        // Wrapped by zsh-autosuggestions or zsh-syntax-highlighting, it is still zsh's own.
        #expect(CompletionOwner.plugin(arm("expand-or-complete", "user:_zsh_autosuggest_bound_1_expand-or-complete")) == nil)
        #expect(CompletionOwner.plugin(arm("expand-or-complete", "user:_zsh_highlight_widget_orig-s0.0000020-r21547-expand-or-complete")) == nil)
        // A shell where ^I can't be read: nothing to ask about.
        #expect(CompletionOwner.plugin(arm("", "")) == nil)
    }

    @Test func pluginsAreAskedAbout() {
        // zsh-autocomplete keeps the stock name for a widget of its own.
        let autocomplete = arm("complete-word", "completion:complete-word:.autocomplete__complete-word__completion-widget",
                               plugins: ["autocomplete"], compsys: true)
        #expect(CompletionOwner.plugin(autocomplete) == .autocomplete)
        #expect(CompletionOwner.plugin(autocomplete)?.listsAsYouType == true)
        #expect(CompletionOwner.plugin(arm("fzf-tab-complete", "user:fzf-tab-complete", plugins: ["fzf-tab"])) == .fzfTab)
        #expect(CompletionOwner.plugin(arm("fzf-tab-complete", "user:_zsh_autosuggest_bound_1_fzf-tab-complete", plugins: ["fzf-tab"])) == .fzfTab)
        // fzf-tab loaded but turned off (disable-fzf-tab): ^I is zsh's again.
        #expect(CompletionOwner.plugin(arm("expand-or-complete", "builtin", plugins: ["fzf-tab"])) == nil)
    }

    @Test func unknownWidgetsCountAsPlugins() {
        let mine = CompletionOwner.plugin(arm("my-tab", "user:my-tab"))
        #expect(mine == CompletionOwner.Plugin(id: "widget:my-tab", name: "my-tab"))
        // A stock name the user's own function took over.
        #expect(CompletionOwner.plugin(arm("complete-word", "user:my-complete-word"))?.name == "complete-word")
        #expect(CompletionOwner.plugin(arm("expand-or-complete", "completion:.expand-or-complete:_my_complete"))?.id == "widget:expand-or-complete")
        #expect(CompletionOwner.Plugin(id: "widget:my-tab").name == "my-tab" && CompletionOwner.Plugin(id: "fzf-tab") == .fzfTab)
    }
}
