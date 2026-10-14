import Foundation

/// A provider's page where its keys are made and revoked: what a key's "Where it came from" link is suggested as. The
/// table is fixed and read on this Mac: no page is fetched, checked online or read from a project's files.
public struct KeyPage: Sendable, Hashable, Identifiable {
    /// A key's name that suggests the page.
    public enum NameSignal: Sendable, Hashable {
        /// This name, however its parts are marked: `CO_API_KEY`, or `coApiKey`.
        case exact(String)
        /// A name whose first parts spell this, however it splits it (`openAIApiKey` is OPEN, AI, API, KEY), and that
        /// holds a secret word (`SecretName.isSecret`): `PINECONE` gives `PINECONE_API_KEY`, never `PINECONE_INDEX`,
        /// and never `MY_PINECONE_KEY`. A webhook's or an OAuth app's secret is never taken this way.
        case prefix(String)
    }

    /// How a key's value starts, compared on its first bytes only.
    public struct ValuePrefix: Sendable, Hashable {
        /// The characters allowed after `head` in the bytes read.
        public enum Body: Sendable, Hashable {
            case any, hex, capitalsAndDigits, base64URL

            func allows(_ byte: UInt8) -> Bool {
                let digit: Bool = byte >= 0x30 && byte <= 0x39
                let capital: Bool = byte >= 0x41 && byte <= 0x5A
                let small: Bool = byte >= 0x61 && byte <= 0x7A
                switch self {
                case .any: return true
                case .hex: return digit || (byte >= 0x41 && byte <= 0x46) || (byte >= 0x61 && byte <= 0x66)
                case .capitalsAndDigits: return digit || capital
                case .base64URL: return digit || capital || small || byte == 0x2D || byte == 0x5F
                }
            }
        }

        public let head: String
        public let body: Body
        /// The value's whole length, for a shape whose head alone is too short to tell (AWS's `AKIA`); else nil, and
        /// the value has at least `SecretKeyPages.minimumLength` bytes.
        public let length: Int?

        /// A head that names the provider alone: `sk-proj-`.
        public static func head(_ head: String) -> ValuePrefix {
            ValuePrefix(head: head, body: .any, length: nil)
        }

        /// A short head, the characters allowed after it and the whole length: `AKIA`, 16 capitals or digits, 20 in
        /// all. The characters are checked only in the bytes read (`SecretKeyPages.headLength`); past them only the
        /// length counts, so a longer shape's tail is not.
        public static func shaped(_ head: String, _ body: Body, length: Int) -> ValuePrefix {
            ValuePrefix(head: head, body: body, length: length)
        }

        /// Whether a value whose first bytes are `bytes` (white space at its start skipped), and whose length without
        /// white space at either end is `length`, starts so.
        func matches(_ bytes: [UInt8], length valueLength: Int) -> Bool {
            let headBytes: [UInt8] = Array(head.utf8)
            guard bytes.count >= headBytes.count, bytes.starts(with: headBytes) else { return false }
            let longEnough: Bool = length.map { (fixed: Int) -> Bool in valueLength == fixed }
                ?? (valueLength >= SecretKeyPages.minimumLength)
            guard longEnough else { return false }
            return bytes[headBytes.count...].allSatisfy { (byte: UInt8) -> Bool in body.allows(byte) }
        }
    }

    /// A page that makes a new token with fields filled in from the URL.
    public enum NewToken: Sendable, Hashable {
        /// GitHub's new fine-grained token: `…/new?name=…&expires_in=90`.
        case githubFineGrained
    }

    /// Stable: `openai`, the same as the service catalog's id for a provider both know.
    public let id: String
    /// "OpenAI", what `list_secrets` names as a key's service.
    public let provider: String
    /// The page's name at the provider: "API Keys".
    public let label: String
    public let url: URL
    public let names: [NameSignal]
    public let prefixes: [ValuePrefix]
    /// One line for a provider whose rotation has a twist, shown beside the paste field.
    public let tip: String?
    public let newToken: NewToken?

    init(_ id: String, _ provider: String, _ label: String, _ address: String, names: [NameSignal],
         prefixes: [ValuePrefix] = [], tip: String? = nil, newToken: NewToken? = nil) {
        self.id = id
        self.provider = provider
        self.label = label
        // The table's own text, each checked by a test against the link rules.
        self.url = URL(string: address)!
        self.names = names
        self.prefixes = prefixes
        self.tip = tip
        self.newToken = newToken
    }

    /// The page's host, lower-cased: `platform.openai.com`.
    public var host: String { url.host?.lowercased() ?? "" }
}

// MARK: - GitHub's new token

extension KeyPage {
    /// The longest token name GitHub takes.
    public static let githubNameLimit = 40
    /// The new token's expiry in days: GitHub's choices run from 1 to 366.
    public static let githubExpiryDays = 90

    /// The page that makes the next token, filled with the key's name and today's date so the new token reads apart
    /// from the old one in GitHub's list: `GITHUB_TOKEN 2026-10-13`, the name cut so the whole fits in 40 characters.
    /// Nil for a page with no such form, or a name that isn't a key's name. No value ever goes into it.
    public func newTokenURL(name: String, date: Date, timeZone: TimeZone = .current) -> URL? {
        guard newToken == .githubFineGrained, StoredSecretName.isValid(name) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let day: DateComponents = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = day.year, let month = day.month, let dayOfMonth = day.day else { return nil }
        let stamp = String(format: "%04d-%02d-%02d", year, month, dayOfMonth)
        let room: Int = Self.githubNameLimit - stamp.count - 1
        let title: String = String(name.prefix(room)) + " " + stamp
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.path += "/new"
        let nameItem = URLQueryItem(name: "name", value: title)
        let expiryItem = URLQueryItem(name: "expires_in", value: String(Self.githubExpiryDays))
        parts.queryItems = [nameItem, expiryItem]
        return parts.url
    }
}

// MARK: - Suggesting a page

/// Which provider's key page a key came from, told on this Mac from its value's first bytes, then its name.
public enum SecretKeyPages {
    /// Every page, group by group.
    public static let all: [KeyPage] = {
        let groups: [[KeyPage]] = [aiModels, codeAndChat, cloudAndPayments, dataAndTracing]
        return groups.flatMap { (group: [KeyPage]) -> [KeyPage] in group }
    }()

    /// How many of a value's bytes are copied out and matched, after any white space at its start. No `String` is made
    /// of them. The rest is only compared with white space at its end, to know the value's length.
    public static let headLength = 24
    /// A value shorter than this names no provider by its head: no provider's key is shorter.
    public static let minimumLength = 20

    /// Heads more than one provider's keys start with, which no row takes without a shape: a bare `sk-` (a legacy
    /// OpenAI key or a DeepSeek one), `eyJ` (any JWT: Qdrant Cloud, a legacy Supabase key) and `SK` (a Twilio API key
    /// only when the bytes read are hex and the value is 34 long). Such a value is told by its name, or not at all.
    public static let sharedHeads = ["sk-", "eyJ", "SK"]

    /// What the link field suggests: the page the value's head names, else the one the name names, else none.
    public static func suggest(value: SecretBytes?, name: String) -> KeyPage? {
        if let value, let page = page(forValue: value) { return page }
        return page(forName: name)
    }

    /// The page a value's head names, longest head first. Only the page is kept, never a byte of the value.
    public static func page(forValue value: SecretBytes) -> KeyPage? {
        var read: (bytes: [UInt8], length: Int) = value.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            head(of: buffer)
        }
        defer { SecretBytes.wipe(&read.bytes) }
        for entry in prefixOrder where entry.prefix.matches(read.bytes, length: read.length) { return entry.page }
        return nil
    }

    /// Up to `headLength` bytes from the first one that isn't white space, and the length without white space at
    /// either end.
    static func head(of buffer: UnsafeRawBufferPointer) -> (bytes: [UInt8], length: Int) {
        var start = 0
        var end = buffer.count
        while start < end, isSpace(buffer[start]) { start += 1 }
        while end > start, isSpace(buffer[end - 1]) { end -= 1 }
        let stop: Int = min(end, start + headLength)
        return (Array(buffer[start..<stop]), end - start)
    }

    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || (byte >= 0x09 && byte <= 0x0D)
    }

    /// Every row's heads, longest first, then in table order; a head a shared one starts with is left out unless it
    /// has a shape.
    static let prefixOrder: [(prefix: KeyPage.ValuePrefix, page: KeyPage)] = {
        var entries: [(prefix: KeyPage.ValuePrefix, page: KeyPage)] = []
        for page in all {
            for prefix in page.prefixes {
                let shared: Bool = sharedHeads.contains { (head: String) -> Bool in head.hasPrefix(prefix.head) }
                if !shared || prefix.length != nil { entries.append((prefix, page)) }
            }
        }
        let order: [Int] = Array(entries.indices).sorted { (a: Int, b: Int) -> Bool in
            let aLength: Int = entries[a].prefix.head.utf8.count
            let bLength: Int = entries[b].prefix.head.utf8.count
            return aLength == bLength ? a < b : aLength > bLength
        }
        return order.map { (index: Int) -> (prefix: KeyPage.ValuePrefix, page: KeyPage) in entries[index] }
    }()
}

// MARK: - Names, hosts and links

extension SecretKeyPages {
    /// The parts a web framework puts before a name it hands the browser, read through: `NEXT_PUBLIC_SUPABASE_ANON_KEY`
    /// is Supabase's key.
    static let publicPrefixes: [[String]] = [
        ["NEXT", "PUBLIC"], ["NUXT", "PUBLIC"], ["EXPO", "PUBLIC"], ["REACT", "APP"], ["VITE"], ["PUBLIC"],
    ]

    /// The page a key's name names: an exact name first, then the longest provider prefix of a name that holds a
    /// secret word and isn't another kind of secret. The name is read in parts (`SecretName.segments`) and compared by
    /// its letters, so `openaiApiKey`, `openAIApiKey` and `OPENAI_API_KEY` read alike.
    public static func page(forName name: String) -> KeyPage? {
        var parts: [String] = SecretName.segments(of: name.trimmingCharacters(in: .whitespaces))
        let framework: [String]? = publicPrefixes.first { (prefix: [String]) -> Bool in
            parts.count > prefix.count && parts.starts(with: prefix)
        }
        if let framework { parts.removeFirst(framework.count) }
        guard !parts.isEmpty else { return nil }
        let letters: String = parts.joined()
        for page in all {
            for case .exact(let exact) in page.names where spelling(of: exact) == letters { return page }
        }
        guard SecretName.isSecret(parts.joined(separator: "_")), !namesAnotherKind(parts) else { return nil }
        var best: (page: KeyPage, length: Int)?
        for page in all {
            for case .prefix(let prefix) in page.names {
                let wanted: String = spelling(of: prefix)
                guard let used = partsSpelling(wanted, in: parts), used < parts.count else { continue }
                if wanted.count > (best?.length ?? 0) { best = (page, wanted.count) }
            }
        }
        return best?.page
    }

    /// A name's letters without the marks between its parts: `GITHUB_TOKEN` and `gitHubToken` are both GITHUBTOKEN.
    static func spelling(of name: String) -> String {
        SecretName.segments(of: name).joined()
    }

    /// How many of a name's first parts spell `word` together (OPEN and AI spell OPENAI), or nil. Whole parts only:
    /// OPENAIR spells no OPENAI.
    static func partsSpelling(_ word: String, in parts: [String]) -> Int? {
        var spelled = ""
        for (index, part) in parts.enumerated() {
            spelled += part
            if spelled == word { return index + 1 }
            guard word.hasPrefix(spelled) else { return nil }
        }
        return nil
    }

    /// Whether a name is a secret made somewhere other than a provider's key page: a webhook's signing secret
    /// (`STRIPE_WEBHOOK_SECRET`) or an OAuth app's client secret (`AZURE_CLIENT_SECRET`). A row whose page does make
    /// one names it exactly (Slack's apps page and `SLACK_CLIENT_SECRET`).
    static func namesAnotherKind(_ parts: [String]) -> Bool {
        if parts.contains("WEBHOOK") || parts.contains("WEBHOOKS") { return true }
        let pairs: Zip2Sequence<[String], ArraySlice<String>> = zip(parts, parts.dropFirst())
        return pairs.contains { (pair: (String, String)) -> Bool in pair.0 == "CLIENT" && pair.1 == "SECRET" }
    }

    /// The provider a link's host belongs to, for `list_secrets`' `service`: a page's host, or a host under it
    /// (`us.cloud.langfuse.com`), the most specific first. A port is not part of the host. Two pages can share a host
    /// (GitHub's fine-grained and classic tokens), so this names a provider, not a page: compare `provider`, not `id`.
    public static func page(forHost host: String) -> KeyPage? {
        var wanted: String = host.lowercased()
        if !wanted.hasPrefix("["), let colon = wanted.lastIndex(of: ":") { wanted = String(wanted[..<colon]) }
        guard !wanted.isEmpty else { return nil }
        if let exact = all.first(where: { (page: KeyPage) -> Bool in page.host == wanted }) { return exact }
        var best: KeyPage?
        for page in all where wanted.hasSuffix("." + page.host) {
            if page.host.count > (best?.host.count ?? 0) { best = page }
        }
        return best
    }

    /// The page a link is: an `https` link on a page's own host, at its path or under it (a page at the host's root
    /// covers every path there), the longest path first. GitHub's fine-grained tokens page is told from its classic one
    /// this way, by host and path, since the sheet that asks never holds the key's value.
    public static func page(forLink url: URL) -> KeyPage? {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return nil }
        let path: String = url.path
        var best: (page: KeyPage, length: Int)?
        for page in all where page.host == host {
            let own: String = page.url.path
            let root: Bool = own.isEmpty || own == "/"
            let covers: Bool = root || path == own || path.hasPrefix(own + "/")
            let longer: Bool = own.count > (best?.length ?? -1)
            guard covers, longer else { continue }
            best = (page, own.count)
        }
        return best?.page
    }
}

// MARK: - The table: AI models

// Each row opens the provider's own key page where its docs name one. Where the path couldn't be confirmed, it opens the
// console's root (xAI, Neon, Cloudflare, Sentry, Twilio, Azure) or the nearest page the docs name (Pinecone's project
// list), until the key-page hand check, each page opened while signed in, lengthens it. Heads are the ones secret
// scanners (gitleaks) and Next Term's own masking know; that check confirms the rest on a key of its own. A page the
// service catalog knows too is the catalog's page, and a test holds the two to it.

extension SecretKeyPages {
    static let aiModels: [KeyPage] = [openAI, anthropic, googleAIStudio, mistral, groq, openRouter, together, fireworks,
                                      huggingFace, replicate, cohere, deepSeek, xAI]

    static let openAI = KeyPage("openai", "OpenAI", "API Keys",
                                "https://platform.openai.com/settings/organization/api-keys",
                                names: [.prefix("OPENAI")],
                                prefixes: [.head("sk-proj-"), .head("sk-svcacct-"), .head("sk-admin-")])
    static let anthropic = KeyPage("anthropic", "Anthropic", "API Keys", "https://platform.claude.com/settings/keys",
                                   names: [.prefix("ANTHROPIC"), .exact("CLAUDE_API_KEY")],
                                   prefixes: [.head("sk-ant-api"), .head("sk-ant-admin")])
    static let googleAIStudio = KeyPage("google-ai-studio", "Google AI Studio", "API Keys",
                                        "https://aistudio.google.com/apikey",
                                        names: [.prefix("GEMINI"), .exact("GOOGLE_GENERATIVE_AI_API_KEY")])
    static let mistral = KeyPage("mistral", "Mistral", "API Keys", "https://console.mistral.ai/api-keys",
                                 names: [.prefix("MISTRAL")])
    static let groq = KeyPage("groq", "Groq", "API Keys", "https://console.groq.com/keys",
                              names: [.prefix("GROQ")], prefixes: [.head("gsk_")])
    static let openRouter = KeyPage("openrouter", "OpenRouter", "API Keys", "https://openrouter.ai/settings/keys",
                                    names: [.prefix("OPENROUTER")], prefixes: [.head("sk-or-v1-")])
    static let together = KeyPage("together", "Together", "API Keys",
                                  "https://api.together.ai/settings/projects/~current/api-keys",
                                  names: [.prefix("TOGETHER")])
    static let fireworks = KeyPage("fireworks", "Fireworks", "API Keys",
                                   "https://app.fireworks.ai/settings/users/api-keys",
                                   names: [.prefix("FIREWORKS")])
    static let huggingFace = KeyPage("huggingface", "Hugging Face", "Access Tokens",
                                     "https://huggingface.co/settings/tokens",
                                     names: [.prefix("HF"), .prefix("HUGGINGFACE"), .prefix("HUGGINGFACEHUB")],
                                     prefixes: [.head("hf_")])
    static let replicate = KeyPage("replicate", "Replicate", "API Tokens", "https://replicate.com/account/api-tokens",
                                   names: [.prefix("REPLICATE")], prefixes: [.head("r8_")])
    static let cohere = KeyPage("cohere", "Cohere", "API Keys", "https://dashboard.cohere.com/api-keys",
                                names: [.prefix("COHERE"), .exact("CO_API_KEY")])
    static let deepSeek = KeyPage("deepseek", "DeepSeek", "API Keys", "https://platform.deepseek.com/api_keys",
                                  names: [.prefix("DEEPSEEK")])
    static let xAI = KeyPage("xai", "xAI", "Console", "https://console.x.ai/",
                             names: [.prefix("XAI"), .exact("GROK_API_KEY")], prefixes: [.head("xai-")])
}

// MARK: - Code and chat

extension SecretKeyPages {
    static let codeAndChat: [KeyPage] = [githubFineGrained, githubClassic, slack, twilio, sendGrid, sentry]

    /// GitHub's recommended tokens, first for a GitHub name; Rotate opens its new-token page filled in.
    static let githubFineGrained = KeyPage("github", "GitHub", "Fine-grained Tokens",
                                           "https://github.com/settings/personal-access-tokens",
                                           names: githubTokenNames, prefixes: [.head("github_pat_")],
                                           newToken: .githubFineGrained)
    /// Only a personal access token's names: the page's new-token form makes one, and an OAuth app's client secret, an
    /// app's private key or a webhook's secret is made elsewhere.
    static let githubTokenNames: [KeyPage.NameSignal] = [
        .exact("GITHUB_TOKEN"), .exact("GITHUB_PAT"), .exact("GITHUB_PERSONAL_ACCESS_TOKEN"),
        .exact("GITHUB_ACCESS_TOKEN"), .exact("GITHUB_API_TOKEN"), .exact("GH_TOKEN"), .exact("GH_PAT"),
    ]
    static let githubClassic = KeyPage("github-classic", "GitHub", "Tokens (classic)", "https://github.com/settings/tokens",
                                       names: [], prefixes: [.head("ghp_")])
    static let slack = KeyPage("slack", "Slack", "Your Apps", "https://api.slack.com/apps",
                               names: [.prefix("SLACK"), .exact("SLACK_CLIENT_SECRET")],
                               prefixes: [.head("xoxb-"), .head("xoxp-"), .head("xoxa-"), .head("xoxr-"), .head("xapp-")])
    /// An API key's id is SK and 32 hex digits; SK alone starts too many words. The first 22 digits are checked, and
    /// the length.
    static let twilio = KeyPage("twilio", "Twilio", "Console", "https://console.twilio.com/",
                                names: [.prefix("TWILIO")], prefixes: [.shaped("SK", .hex, length: 34)])
    /// SG., 22 characters, a dot and 43 more, 69 in all. The first 21 characters are checked, and the length; the dot
    /// is past the bytes read.
    static let sendGrid = KeyPage("sendgrid", "SendGrid", "API Keys", "https://app.sendgrid.com/settings/api_keys",
                                  names: [.prefix("SENDGRID")], prefixes: [.shaped("SG.", .base64URL, length: 69)])
    static let sentry = KeyPage("sentry", "Sentry", "Console", "https://sentry.io/",
                                names: [.prefix("SENTRY")], prefixes: [.head("sntrys_"), .head("sntryu_")])
}

// MARK: - Cloud and payments

extension SecretKeyPages {
    static let cloudAndPayments: [KeyPage] = [aws, azure, cloudflare, vercel, stripe, supabase, neon, upstash]

    /// An access key's id is AKIA and 16 capitals or digits; the secret beside it has no head of its own.
    static let aws = KeyPage("aws", "AWS", "Security Credentials",
                             "https://console.aws.amazon.com/iam/home#/security_credentials",
                             names: [.exact("AWS_ACCESS_KEY_ID"), .exact("AWS_SECRET_ACCESS_KEY")],
                             prefixes: [.shaped("AKIA", .capitalsAndDigits, length: 20)],
                             tip: "Create a second access key, then deactivate the old one.")
    static let azure = KeyPage("azure", "Azure", "Portal", "https://portal.azure.com/",
                               names: [.prefix("AZURE")], tip: "Regenerate the key you are not using.")
    static let cloudflare = KeyPage("cloudflare", "Cloudflare", "Dashboard", "https://dash.cloudflare.com/",
                                    names: [.prefix("CLOUDFLARE"), .exact("CF_API_TOKEN"), .exact("CF_API_KEY")],
                                    prefixes: [.head("cfut_"), .head("cfat_"), .head("cfk_")])
    static let vercel = KeyPage("vercel", "Vercel", "Tokens", "https://vercel.com/account/tokens",
                                names: [.prefix("VERCEL")], prefixes: [.head("vcp_")])
    static let stripe = KeyPage("stripe", "Stripe", "API Keys", "https://dashboard.stripe.com/apikeys",
                                names: [.prefix("STRIPE")],
                                prefixes: [.head("sk_live_"), .head("sk_test_"), .head("rk_live_"), .head("rk_test_"),
                                           .head("pk_live_"), .head("pk_test_")],
                                tip: "Choose when the old key expires.")
    static let supabase = KeyPage("supabase", "Supabase", "API Keys",
                                  "https://supabase.com/dashboard/project/_/settings/api-keys",
                                  names: [.prefix("SUPABASE")], prefixes: [.head("sb_secret_"), .head("sb_publishable_")])
    static let neon = KeyPage("neon", "Neon", "Console", "https://console.neon.tech/", names: [.prefix("NEON")])
    static let upstash = KeyPage("upstash", "Upstash", "Console", "https://console.upstash.com/",
                                 names: [.prefix("UPSTASH"), .prefix("QSTASH")])
}

// MARK: - Data and tracing

extension SecretKeyPages {
    static let dataAndTracing: [KeyPage] = [pinecone, qdrant, weaviate, langSmith, langfuse, wandb, tavily]

    static let pinecone = KeyPage("pinecone", "Pinecone", "Projects", "https://app.pinecone.io/organizations/-/projects",
                                  names: [.prefix("PINECONE")], prefixes: [.head("pcsk_")])
    static let qdrant = KeyPage("qdrant", "Qdrant Cloud", "Console", "https://cloud.qdrant.io/", names: [.prefix("QDRANT")])
    static let weaviate = KeyPage("weaviate", "Weaviate Cloud", "Console", "https://console.weaviate.cloud/",
                                  names: [.prefix("WEAVIATE")])
    static let langSmith = KeyPage("langsmith", "LangSmith", "Settings", "https://smith.langchain.com/settings",
                                   names: [.prefix("LANGSMITH"), .prefix("LANGCHAIN")],
                                   prefixes: [.head("lsv2_pt_"), .head("lsv2_sk_")])
    static let langfuse = KeyPage("langfuse", "Langfuse", "Projects", "https://cloud.langfuse.com/",
                                  names: [.prefix("LANGFUSE")], prefixes: [.head("sk-lf-"), .head("pk-lf-")])
    static let wandb = KeyPage("wandb", "W&B", "API Key", "https://wandb.ai/authorize", names: [.prefix("WANDB")])
    static let tavily = KeyPage("tavily", "Tavily", "Dashboard", "https://app.tavily.com/",
                                names: [.prefix("TAVILY")], prefixes: [.head("tvly-")])
}
