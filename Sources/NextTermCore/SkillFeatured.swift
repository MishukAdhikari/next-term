import Foundation

/// Skills Window › Skills suggests, from the agents' makers' own public repositories. Only names, places
/// and the commit that was looked at ship with Next Term, never a skill's files: installing one fetches
/// that commit and shows the usual review, and a newer commit upstream shows as an update to review.
public struct SkillFeatured: Equatable, Sendable {
    public let name: String
    public let owner: String
    public let repo: String
    /// The skill's folder in the repository.
    public let path: String
    /// The commit that was reviewed for this list.
    public let commit: String
    public let summary: String

    public var source: SkillSource { SkillSource(owner: owner, repo: repo, path: path) }

    static let anthropic = "683bc88e56f3e09ba94f7055977f3d3aa499f202"
    static let openAI = "49f948faa9258a0c61caceaf225e179651397431"

    static func fromAnthropic(_ name: String, _ summary: String) -> SkillFeatured {
        SkillFeatured(name: name, owner: "anthropics", repo: "skills", path: "skills/" + name, commit: anthropic, summary: summary)
    }

    static func fromOpenAI(_ name: String, _ summary: String) -> SkillFeatured {
        SkillFeatured(name: name, owner: "openai", repo: "skills", path: "skills/.curated/" + name, commit: openAI, summary: summary)
    }

    public static let list: [SkillFeatured] = [
        fromAnthropic("skill-creator", "Create and improve skills, and measure how well they work."),
        fromAnthropic("mcp-builder", "Build MCP servers that give agents new tools."),
        fromAnthropic("frontend-design", "Distinctive, intentional visual design for new UI."),
        fromAnthropic("webapp-testing", "Test local web apps with Playwright."),
        fromAnthropic("canvas-design", "Visual art in PNG and PDF from a design philosophy."),
        fromAnthropic("theme-factory", "Style slides, documents and pages with a theme."),
        fromOpenAI("gh-fix-ci", "Find and fix failing GitHub Actions checks."),
        fromOpenAI("gh-address-comments", "Work through review comments on a pull request."),
        fromOpenAI("playwright", "Drive a real browser from the terminal."),
        fromOpenAI("security-best-practices", "Review code for security issues by language."),
        fromOpenAI("jupyter-notebook", "Create and edit Jupyter notebooks."),
        fromOpenAI("openai-docs", "Answer from OpenAI's current documentation."),
    ]
}
