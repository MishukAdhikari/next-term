import AppKit
import NextTermCore

/// Settings › Skills: Personal (the user's skills, SkillsSettingsView) or Project (a project's, ProjectSkillsView), by
/// the switch at its top. The Project view is made the first time it is chosen, and the one hidden never reads its
/// folders. Settings is kept while the app runs, so it opens again on the side last shown.
final class SkillsPane: NSView {
    let scope = NSSegmentedControl(labels: ["Personal", "Project"], trackingMode: .selectOne, target: nil, action: nil)
    let personal = SkillsSettingsView()
    private(set) var project: ProjectSkillsView?

    override init(frame: NSRect) {
        super.init(frame: frame)
        scope.selectedSegment = 0
        scope.target = self
        scope.action = #selector(scopeChanged)
        let personalTip = "Your skills in ~/.agents/skills, ~/.claude/skills, ~/.codex/skills, ~/.commandcode/skills and ~/.config/opencode/skills."
        scope.setToolTip(personalTip + " Agents get them in every project.", forSegment: 0)
        scope.setToolTip("A project's own skills, as each agent loads them there.", forSegment: 1)
        scope.setAccessibilityLabel("Skills scope")
        scope.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scope)
        NSLayoutConstraint.activate([
            scope.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            scope.centerXAnchor.constraint(equalTo: centerXAnchor),
        ])
        place(personal)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Shows Personal (0) or Project (1).
    func show(_ index: Int) {
        scope.selectedSegment = index
        if index == 1, project == nil {
            let view = ProjectSkillsView()
            view.onShowPersonal = { [weak self] in self?.show(0) }
            project = view
            place(view)
        }
        personal.isHidden = index != 0
        project?.isHidden = index != 1
        if index == 0 { personal.reload() } else { project?.reload(following: true) }
    }

    @objc private func scopeChanged() { show(scope.selectedSegment) }

    private func place(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: scope.bottomAnchor, constant: 2),
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}
