import Foundation

/// Who answers Tab in a zsh, from its `arm` mark: zsh's own Tab (a stock widget, or a known wrapper of one),
/// or a plugin, which Next Term asks about once before taking Tab over (Settings › Terminal › Tab completion,
/// Auto). Widgets it doesn't know count as plugins and are named in the question.
public enum CompletionOwner {
    public struct Plugin: Equatable, Hashable, Sendable {
        /// What the choice is remembered by: "fzf-tab", "zsh-autocomplete", or "widget:<name>".
        public let id: String
        /// What the question and Settings call it.
        public let name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }

        public static let autocomplete = Plugin(id: "zsh-autocomplete", name: "zsh-autocomplete")
        public static let fzfTab = Plugin(id: "fzf-tab", name: "fzf-tab")

        /// A remembered id back as a plugin, for Settings.
        public init(id: String) {
            self.id = id
            name = id.hasPrefix("widget:") ? String(id.dropFirst("widget:".count)) : id
        }

        /// zsh-autocomplete lists as you type: choosing Next Term's list quiets that.
        public var listsAsYouType: Bool { self == .autocomplete }
    }

    /// zsh's own Tab widgets, and oh-my-zsh's and fzf's wrappers of it: no question.
    public static let stockWidgets: Set<String> = [
        "expand-or-complete", "complete-word", "menu-complete", "menu-expand-or-complete", "expand-or-complete-prefix",
        "expand-or-complete-with-dots", "fzf-completion",
    ]

    /// The plugin that owns Tab in a shell; nil when Tab is zsh's own.
    public static func plugin(_ arm: CompletionProtocol.Arm) -> Plugin? {
        if arm.plugins.contains("autocomplete") { return .autocomplete }
        if arm.plugins.contains("fzf-tab"), arm.tabWidget == "fzf-tab-complete" { return .fzfTab }
        let widget = arm.tabWidget
        guard !widget.isEmpty, !isStock(widget, definition: arm.tabWidgetDefinition) else { return nil }
        return Plugin(id: "widget:" + widget, name: widget)
    }

    /// A stock widget name as zsh, its completion system, or a plugin that only wraps widgets
    /// (zsh-autosuggestions, zsh-syntax-highlighting) defines it.
    static func isStock(_ widget: String, definition: String) -> Bool {
        guard stockWidgets.contains(widget) else { return false }
        if definition == "builtin" { return true }
        if definition.hasPrefix("completion:") { return definition.hasSuffix(":_main_complete") }
        guard definition.hasPrefix("user:") else { return false }
        let function = String(definition.dropFirst("user:".count))
        // oh-my-zsh's and fzf's own widgets, by their own names.
        if function == widget { return true }
        // A widget wrapped as it was, under the wrapper's name.
        let wrapped = wrappers.contains { function.hasPrefix($0) }
        return wrapped && (function.hasSuffix("_" + widget) || function.hasSuffix("-" + widget))
    }

    /// How zsh-autosuggestions and zsh-syntax-highlighting name a widget they wrap.
    static let wrappers = ["_zsh_autosuggest_bound_", "_zsh_highlight_widget_"]
}
