/// The all-files diff's one button for every file: "Collapse All" while any file is open, since a click then folds
/// them all, and "Expand All" only once every file is folded away, since a click then opens them all.
public enum FoldAllTitle {
    /// `collapsed`: each file's state, in the list's order.
    public static func title(collapsed: [Bool]) -> String {
        collapsed.contains(false) ? "Collapse All" : "Expand All"
    }
}
