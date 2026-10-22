import Foundation

// The catalog itself: each line as its page prints it, with `--scope user` added to Claude Code's.

extension TrackerLines {
    private static func page(_ text: String) -> URL { URL(string: text)! }

    private static func claude(_ name: String, _ url: String, _ source: String) -> Cell {
        .line("claude mcp add --transport http --scope user \(name) \(url)", source: page(source))
    }

    private static func codex(_ name: String, _ url: String, _ source: String) -> Cell {
        .line("codex mcp add \(name) --url \(url)", source: page(source))
    }

    public static let catalog: [Tracker] = [linear, github, jira, notion, plane, shortcut, ticktick, todoist, asana, clickUp,
                                            azureDevOps]

    static let linear: Tracker = {
        let url = "https://mcp.linear.app/mcp"
        let source = "https://linear.app/docs/mcp"
        return Tracker(name: "Linear", url: url, page: page(source), domains: ["linear.app"],
                       lines: [.claude: claude("linear-server", url, source), .codex: codex("linear", url, source)], notes: [:])
    }()

    static let github: Tracker = {
        let url = "https://api.githubcopilot.com/mcp/"
        let guides = "https://github.com/github/github-mcp-server/blob/main/docs/installation-guides/"
        let line = "codex mcp add github --url \(url) --bearer-token-env-var GITHUB_PAT_TOKEN"
        let held = Cell.held("GitHub\u{2019}s line writes your token into Claude Code\u{2019}s settings file.",
                             page: page(guides + "install-claude.md"))
        let note = "Codex reads your token from GITHUB_PAT_TOKEN in its environment; Next Term doesn\u{2019}t set it or see it."
        return Tracker(name: "GitHub", url: url, page: page(guides + "install-codex.md"), domains: ["github.com"],
                       lines: [.claude: held, .codex: .line(line, source: page(guides + "install-codex.md"))],
                       notes: [.codex: note])
    }()

    static let jira: Tracker = {
        let url = "https://mcp.atlassian.com/v2/mcp"
        let source = "https://support.atlassian.com/atlassian-rovo-mcp-server/docs/getting-started-with-the-atlassian-remote-mcp-server/"
        return Tracker(name: "Jira", url: url, page: page(source), domains: ["atlassian.com"],
                       lines: [.claude: claude("atlassian", url, source), .codex: codex("atlassian", url, source)], notes: [:])
    }()

    static let notion: Tracker = {
        let url = "https://mcp.notion.com/mcp"
        let source = "https://developers.notion.com/docs/get-started-with-mcp"
        return Tracker(name: "Notion", url: url, page: page(source), domains: ["notion.com"],
                       lines: [.claude: claude("notion", url, source)], notes: [:])
    }()

    static let plane: Tracker = {
        let url = "https://mcp.plane.so/http/mcp"
        let source = "https://developers.plane.so/dev-tools/mcp-server-claude-code"
        return Tracker(name: "Plane", url: url, page: page(source), domains: ["plane.so"],
                       lines: [.claude: claude("plane", url, source), .codex: codex("plane", url, source)], notes: [:])
    }()

    static let shortcut: Tracker = {
        let url = "https://mcp.shortcut.com/mcp"
        let source = "https://www.shortcut.com/help/integrations/claude-code/"
        return Tracker(name: "Shortcut", url: url, page: page(source), domains: ["shortcut.com"],
                       lines: [.claude: claude("shortcut", url, source)], notes: [:])
    }()

    static let ticktick: Tracker = {
        let url = "https://mcp.ticktick.com"
        let source = "https://help.ticktick.com/"
        return Tracker(name: "TickTick", url: url, page: page(source), domains: ["ticktick.com"],
                       lines: [.claude: claude("ticktick", url, source), .codex: codex("ticktick", url, source)], notes: [:])
    }()

    static let todoist: Tracker = {
        let url = "https://ai.todoist.net/mcp"
        let source = "https://developer.todoist.com/guides/"
        return Tracker(name: "Todoist", url: url, page: page(source), domains: ["todoist.com", "todoist.net"],
                       lines: [.claude: claude("todoist", url, source)], notes: [:])
    }()

    static let asana: Tracker = {
        let source = page("https://developers.asana.com/docs/using-asanas-mcp-server")
        let why = Cell.held("Asana\u{2019}s server needs an OAuth app of your own.", page: source)
        return Tracker(name: "Asana", url: "https://mcp.asana.com/v2/mcp", page: source, domains: ["asana.com"],
                       lines: [.claude: why, .codex: why, .gemini: why], notes: [:])
    }()

    static let clickUp = Tracker(name: "ClickUp", url: "https://mcp.clickup.com/mcp",
                                 page: page("https://developer.clickup.com/docs/connect-an-ai-assistant-to-clickups-mcp-server"),
                                 domains: ["clickup.com"], lines: [:], notes: [:])

    static let azureDevOps = Tracker(name: "Azure DevOps", url: nil,
                                     page: page("https://learn.microsoft.com/en-us/azure/devops/mcp-server/mcp-server-overview"),
                                     domains: ["microsoft.com"], lines: [:], notes: [:])
}
