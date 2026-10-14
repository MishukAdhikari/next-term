import Foundation
import Testing
@testable import NextTermCore

/// Which provider's key page Next Term suggests for a key: from its value's first bytes, then its name, with no fetch.
/// Every value here is made up: a provider's prefix and filler, put together at run time, so no file holds a key-shaped
/// string whole.
@Suite struct SecretKeyPagesTests {
    /// A made-up value: `head`, then `filler` up to `length` bytes.
    private static func value(_ head: String, length: Int = 48, filler: String = "x") -> SecretBytes {
        let room = max(0, length - head.utf8.count)
        let body = String(String(repeating: filler, count: room).prefix(room))
        return SecretBytes(utf8: head + body)
    }

    private static func provider(_ head: String, name: String = "LLM_KEY", length: Int = 48) -> String? {
        SecretKeyPages.suggest(value: value(head, length: length), name: name)?.provider
    }

    private static func page(_ id: String) -> KeyPage? {
        SecretKeyPages.all.first { (page: KeyPage) -> Bool in page.id == id }
    }

    // MARK: The value's prefix

    @Test func aValuesPrefixNamesItsProvider() {
        let cases: [(String, String)] = [
            ("sk-ant-api03-", "Anthropic"), ("sk-ant-admin01-", "Anthropic"),
            ("sk-proj-", "OpenAI"), ("sk-svcacct-", "OpenAI"), ("sk-admin-", "OpenAI"),
            ("sk-or-v1-", "OpenRouter"),
            ("pcsk_", "Pinecone"), ("lsv2_pt_", "LangSmith"), ("lsv2_sk_", "LangSmith"), ("hf_", "Hugging Face"),
            ("gsk_", "Groq"), ("tvly-", "Tavily"), ("r8_", "Replicate"), ("xai-", "xAI"),
            ("ghp_", "GitHub"), ("github_pat_", "GitHub"), ("sk_live_", "Stripe"), ("rk_test_", "Stripe"),
            ("pk_test_", "Stripe"), ("sb_secret_", "Supabase"), ("cfut_", "Cloudflare"), ("cfat_", "Cloudflare"),
            ("cfk_", "Cloudflare"), ("vcp_", "Vercel"), ("xoxb-", "Slack"), ("sk-lf-", "Langfuse"),
        ]
        for (head, provider) in cases {
            #expect(Self.provider(head) == provider, "\(head)")
        }
    }

    @Test func aClassicTokenAndAFineGrainedOneOpenTheirOwnPages() {
        let classic = SecretKeyPages.suggest(value: Self.value("ghp_"), name: "GITHUB_TOKEN")
        let fineGrained = SecretKeyPages.suggest(value: Self.value("github_pat_"), name: "GITHUB_TOKEN")
        #expect(classic?.url.absoluteString == "https://github.com/settings/tokens")
        #expect(fineGrained?.url.absoluteString == "https://github.com/settings/personal-access-tokens")
    }

    @Test func keysWithAFixedShapeMatchOnlyThatShape() {
        // An AWS access key id: AKIA and 16 capitals or digits, 20 in all.
        let aws = SecretBytes(utf8: "AKIA" + String(repeating: "X7", count: 8))
        #expect(SecretKeyPages.suggest(value: aws, name: "LLM_KEY")?.provider == "AWS")
        let lower = SecretBytes(utf8: "AKIA" + String(repeating: "x7", count: 8))
        #expect(SecretKeyPages.suggest(value: lower, name: "LLM_KEY") == nil)
        let longer = SecretBytes(utf8: "AKIA" + String(repeating: "X7", count: 10))
        #expect(SecretKeyPages.suggest(value: longer, name: "LLM_KEY") == nil)
        // A Twilio API key: SK and 32 hex digits. SK with fewer is any word.
        let twilio = SecretBytes(utf8: "SK" + String(repeating: "0a", count: 16))
        #expect(SecretKeyPages.suggest(value: twilio, name: "LLM_KEY")?.provider == "Twilio")
        let shortSID = SecretBytes(utf8: "SK" + String(repeating: "0a", count: 5) + String(repeating: "z", count: 20))
        #expect(SecretKeyPages.suggest(value: shortSID, name: "LLM_KEY") == nil)
        // A SendGrid key: SG., 22 characters, a dot and 43 more.
        let sendGrid = SecretBytes(utf8: "SG." + String(repeating: "q", count: 22) + "." + String(repeating: "w", count: 43))
        #expect(SecretKeyPages.suggest(value: sendGrid, name: "LLM_KEY")?.provider == "SendGrid")
        let notSendGrid = SecretBytes(utf8: "SG." + String(repeating: "q", count: 30))
        #expect(SecretKeyPages.suggest(value: notSendGrid, name: "LLM_KEY") == nil)
    }

    @Test func aPrefixTwoProvidersShareSuggestsNothing() {
        // A bare sk- is a legacy OpenAI key or a DeepSeek one; eyJ starts any JWT (Qdrant, legacy Supabase).
        #expect(Self.provider("sk-", length: 48) == nil)
        #expect(Self.provider("eyJ", length: 120) == nil)
        let twilioLike = SecretBytes(utf8: "SK" + String(repeating: "0a", count: 5))
        #expect(SecretKeyPages.suggest(value: twilioLike, name: "LLM_KEY") == nil)
        // The name may still say which.
        #expect(Self.provider("sk-", name: "DEEPSEEK_API_KEY") == "DeepSeek")
        #expect(Self.provider("eyJ", name: "QDRANT_API_KEY", length: 120) == "Qdrant Cloud")
    }

    @Test func noRowTakesAPrefixProvidersShare() {
        for page in SecretKeyPages.all {
            for prefix in page.prefixes where prefix.length == nil {
                let shared = SecretKeyPages.sharedHeads.contains { (head: String) -> Bool in head.hasPrefix(prefix.head) }
                #expect(!shared, "\(page.id): \(prefix.head)")
            }
        }
        let heads: [String] = SecretKeyPages.all.flatMap { (page: KeyPage) -> [String] in
            page.prefixes.map { (prefix: KeyPage.ValuePrefix) -> String in prefix.head }
        }
        #expect(Set(heads).count == heads.count)
    }

    @Test func theValueWinsOverTheName() {
        #expect(Self.provider("sk-or-v1-", name: "OPENAI_API_KEY") == "OpenRouter")
        #expect(Self.provider("gsk_", name: "OPENAI_API_KEY") == "Groq")
    }

    @Test func aShortValueSuggestsNothingByItsPrefix() {
        #expect(Self.provider("hf_", length: 10) == nil)
        #expect(Self.provider("sk-proj-", length: 19) == nil)
        #expect(Self.provider("sk-proj-", length: 20) == "OpenAI")
    }

    @Test func whiteSpaceAroundTheValueIsSkipped() {
        let padded = SecretBytes(utf8: "  \t" + "sk-proj-" + String(repeating: "x", count: 40) + " \n")
        #expect(SecretKeyPages.suggest(value: padded, name: "LLM_KEY")?.provider == "OpenAI")
        let awsPadded = SecretBytes(utf8: " AKIA" + String(repeating: "X7", count: 8) + "  ")
        #expect(SecretKeyPages.suggest(value: awsPadded, name: "LLM_KEY")?.provider == "AWS")
    }

    /// The suggester reads the value's first bytes inside `SecretBytes` and never makes a `String` of it: bytes after
    /// those it reads can be anything, even ones that aren't UTF-8.
    @Test func onlyTheValuesFirstBytesAreRead() {
        let head: [UInt8] = Array("sk-or-v1-".utf8) + [UInt8](repeating: UInt8(ascii: "x"), count: 15)
        #expect(head.count == SecretKeyPages.headLength)
        let rest: [UInt8] = [0xFF, 0xFE, 0x80, 0xC3, 0x28, 0xFF, 0xFF, 0xA0, 0xA1, 0xE2, 0x82]
        let value = SecretBytes(head + rest)
        #expect(value.utf8String() == nil)
        #expect(SecretKeyPages.suggest(value: value, name: "LLM_KEY")?.provider == "OpenRouter")
        #expect(SecretKeyPages.page(forValue: value)?.provider == "OpenRouter")
    }
}

// MARK: - The key's name

extension SecretKeyPagesTests {
    @Test func aNameNamesItsProvider() {
        let cases: [(String, String)] = [
            ("COHERE_API_KEY", "Cohere"), ("CO_API_KEY", "Cohere"), ("MISTRAL_API_KEY", "Mistral"),
            ("TOGETHER_API_KEY", "Together"), ("OPENAI_API_KEY", "OpenAI"), ("ANTHROPIC_API_KEY", "Anthropic"),
            ("GEMINI_API_KEY", "Google AI Studio"), ("HF_TOKEN", "Hugging Face"), ("HUGGINGFACEHUB_API_TOKEN", "Hugging Face"),
            ("PINECONE_API_KEY", "Pinecone"), ("LANGCHAIN_API_KEY", "LangSmith"), ("GH_TOKEN", "GitHub"),
            ("GITHUB_PERSONAL_ACCESS_TOKEN", "GitHub"), ("STRIPE_SECRET_KEY", "Stripe"),
            ("AWS_SECRET_ACCESS_KEY", "AWS"), ("AZURE_OPENAI_API_KEY", "Azure"), ("SLACK_BOT_TOKEN", "Slack"),
            ("UPSTASH_REDIS_REST_TOKEN", "Upstash"), ("WANDB_API_KEY", "W&B"), ("TAVILY_API_KEY", "Tavily"),
        ]
        for (name, provider) in cases {
            #expect(SecretKeyPages.page(forName: name)?.provider == provider, "\(name)")
        }
    }

    @Test func aNameWithNoProviderOrNoSecretWordSuggestsNothing() {
        for name in ["LLM_KEY", "API_KEY", "OPENAI_BASE_URL", "OPENAI_ORG_ID", "PINECONE_INDEX", "AWS_REGION", "KEY"] {
            #expect(SecretKeyPages.page(forName: name) == nil, "\(name)")
        }
        // A provider's name inside another's is not its: Azure's OpenAI key is Azure's.
        #expect(SecretKeyPages.page(forName: "AZURE_OPENAI_API_KEY")?.id == "azure")
        #expect(SecretKeyPages.page(forName: "MY_OPENAI_API_KEY") == nil)
    }

    @Test func aFrameworksPublicPrefixAndCamelCaseAreReadThrough() {
        #expect(SecretKeyPages.page(forName: "NEXT_PUBLIC_SUPABASE_ANON_KEY")?.provider == "Supabase")
        #expect(SecretKeyPages.page(forName: "VITE_OPENAI_API_KEY")?.provider == "OpenAI")
        #expect(SecretKeyPages.page(forName: "openaiApiKey")?.provider == "OpenAI")
        #expect(SecretKeyPages.page(forName: "NEXT_PUBLIC") == nil)
    }

    @Test func withNoValueTheNameAloneSuggests() {
        let cohere = SecretKeyPages.suggest(value: nil, name: "COHERE_API_KEY")
        #expect(cohere?.url.absoluteString == "https://dashboard.cohere.com/api-keys")
        #expect(SecretKeyPages.suggest(value: nil, name: "LLM_KEY") == nil)
    }

    /// The Add sheet's example: an OpenAI project key suggests its key page, a key with no known prefix its name's page,
    /// and a bare sk- under a name with no provider nothing.
    @Test func theAddSheetsExamples() {
        let openAI = SecretKeyPages.suggest(value: Self.value("sk-proj-"), name: "OPENAI_API_KEY")
        #expect(openAI?.provider == "OpenAI")
        #expect(openAI?.label == "API Keys")
        #expect(openAI?.url.absoluteString == "https://platform.openai.com/settings/organization/api-keys")
        let cohere = SecretKeyPages.suggest(value: Self.value("q7", filler: "n4"), name: "COHERE_API_KEY")
        #expect(cohere?.url.absoluteString == "https://dashboard.cohere.com/api-keys")
        #expect(SecretKeyPages.suggest(value: Self.value("sk-"), name: "LLM_KEY") == nil)
    }
}

// MARK: - The table

extension SecretKeyPagesTests {
    @Test func everyPagePassesTheLinkRulesAsWritten() {
        let noMask: (String) -> Bool = { (_: String) -> Bool in false }
        for page in SecretKeyPages.all {
            let address = page.url.absoluteString
            let checked: Result<URL, SecretLink.Refusal> = SecretLink.check(address, mask: noMask, value: nil)
            #expect((try? checked.get().absoluteString) == address, "\(page.id)")
            #expect(SafeWebLink.isAllowed(page.url), "\(page.id)")
            #expect(page.url.scheme == "https", "\(page.id)")
            #expect(page.url.query == nil, "\(page.id)")
        }
    }

    @Test func everyRowIsWellFormed() {
        let ids: [String] = SecretKeyPages.all.map { (page: KeyPage) -> String in page.id }
        #expect(Set(ids).count == ids.count)
        for page in SecretKeyPages.all {
            #expect(!page.provider.isEmpty && !page.label.isEmpty, "\(page.id)")
            #expect(!page.names.isEmpty || !page.prefixes.isEmpty, "\(page.id)")
            for signal in page.names {
                switch signal {
                case .exact(let name):
                    #expect(StoredSecretName.isValid(name) && SecretName.isSecret(name), "\(page.id): \(name)")
                case .prefix(let prefix):
                    #expect(StoredSecretName.isValid(prefix) && !prefix.hasSuffix("_"), "\(page.id): \(prefix)")
                }
            }
        }
        let rows: [String] = ["openai", "anthropic", "google-ai-studio", "mistral", "groq", "openrouter", "together",
                              "fireworks", "huggingface", "replicate", "cohere", "deepseek", "xai", "pinecone", "qdrant",
                              "weaviate", "supabase", "neon", "upstash", "vercel", "github", "stripe", "langsmith",
                              "langfuse", "wandb", "cloudflare", "twilio", "sendgrid", "sentry", "tavily", "aws"]
        for id in rows { #expect(Self.page(id) != nil, "\(id)") }
    }

    @Test func onlyAWSAzureAndStripeCarryARotateTip() {
        let tipped: [String] = SecretKeyPages.all.compactMap { (page: KeyPage) -> String? in
            page.tip == nil ? nil : page.id
        }
        #expect(Set(tipped) == ["aws", "azure", "stripe"])
        #expect(Self.page("aws")?.tip == "Create a second access key, then deactivate the old one.")
        #expect(Self.page("azure")?.tip == "Regenerate the key you are not using.")
        #expect(Self.page("stripe")?.tip == "Choose when the old key expires.")
    }

    /// The pages both tables know must be the same page, so the two can't drift apart.
    @Test func theServiceCatalogAndThisTableAgree() throws {
        let samePage = ["openai", "anthropic", "google-ai-studio", "huggingface", "mistral", "groq", "cohere", "deepseek",
                        "fireworks", "replicate", "together"]
        for id in samePage {
            let page = try #require(Self.page(id), "\(id)")
            let pages = Self.catalogPages(id)
            #expect(pages.contains(Self.hostAndPath(page.url)), "\(id): \(pages)")
        }
        // Every provider in both names the same host there, at least.
        for page in SecretKeyPages.all {
            let pages = Self.catalogPages(page.id)
            guard !pages.isEmpty else { continue }
            let hosts: [String] = pages.map { (pair: String) -> String in String(pair.prefix { $0 != "/" }) }
            #expect(hosts.contains(page.host), "\(page.id): \(hosts)")
        }
    }

    /// A catalog entry's pages on the provider's own host with a fixed path, as `host/path`.
    private static func catalogPages(_ id: String) -> [String] {
        guard let entry = ServiceCatalog.all.first(where: { (entry: ServiceEntry) -> Bool in entry.id == id }) else {
            return []
        }
        return entry.links.compactMap { (template: LinkTemplate) -> String? in
            guard case .web(let host) = template.target, template.query.isEmpty, template.fragment.isEmpty else { return nil }
            var path = ""
            for piece in template.path {
                guard case .text(let text) = piece else { return nil }
                path += text
            }
            return host + (path.isEmpty ? "/" : path)
        }
    }

    private static func hostAndPath(_ url: URL) -> String {
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let path: String = parts?.percentEncodedPath ?? ""
        return (parts?.host ?? "") + (path.isEmpty ? "/" : path)
    }
}

// MARK: - GitHub's new-token page, hosts and links

extension SecretKeyPagesTests {
    private static let utc = TimeZone(identifier: "UTC")!

    /// 13 October 2026, at noon in UTC.
    private static var thirteenthOfOctober: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let parts = DateComponents(year: 2026, month: 10, day: 13, hour: 12)
        return calendar.date(from: parts)!
    }

    @Test func githubsNewTokenPageIsFilledWithTheNameAndTheDate() throws {
        let github = try #require(Self.page("github"))
        let url = github.newTokenURL(name: "GITHUB_TOKEN", date: Self.thirteenthOfOctober, timeZone: Self.utc)
        let expected = "https://github.com/settings/personal-access-tokens/new?name=GITHUB_TOKEN%202026-10-13&expires_in=90"
        #expect(url?.absoluteString == expected)
        let long = github.newTokenURL(name: "GITHUB_PERSONAL_ACCESS_TOKEN", date: Self.thirteenthOfOctober, timeZone: Self.utc)
        let longExpected = "https://github.com/settings/personal-access-tokens/new"
            + "?name=GITHUB_PERSONAL_ACCESS_TOKEN%202026-10-13&expires_in=90"
        #expect(long?.absoluteString == longExpected)
        let noMask: (String) -> Bool = { (_: String) -> Bool in false }
        let checked: Result<URL, SecretLink.Refusal> = SecretLink.check(expected, mask: noMask, value: nil)
        #expect((try? checked.get().absoluteString) == expected)
    }

    /// GitHub takes a token name of at most 40 characters: the key's name is cut so its name, a space and the date fit.
    @Test func aLongNameIsCutSoTheDateStillFits() throws {
        let github = try #require(Self.page("github"))
        let name = "A" + String(repeating: "B", count: 62) + "C"
        #expect(name.count == 64)
        let url = try #require(github.newTokenURL(name: name, date: Self.thirteenthOfOctober, timeZone: Self.utc))
        let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let title = try #require(parts.queryItems?.first { (item: URLQueryItem) -> Bool in item.name == "name" }?.value)
        #expect(title.count == 40)
        #expect(title.hasSuffix(" 2026-10-13"))
        #expect(title.hasPrefix("ABBB"))
        // The date is the day where the user is: late on the 13th in UTC is the 14th in Tokyo.
        let late = Self.thirteenthOfOctober.addingTimeInterval(11 * 3600)
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let next = github.newTokenURL(name: "GITHUB_TOKEN", date: late, timeZone: tokyo)
        #expect(next?.absoluteString.contains("name=GITHUB_TOKEN%202026-10-14&") == true)
    }

    @Test func onlyGithubsFineGrainedPageHasANewTokenPage() throws {
        let classic = try #require(Self.page("github-classic"))
        #expect(classic.newTokenURL(name: "GITHUB_TOKEN", date: Self.thirteenthOfOctober) == nil)
        let openAI = try #require(Self.page("openai"))
        #expect(openAI.newTokenURL(name: "OPENAI_API_KEY", date: Self.thirteenthOfOctober) == nil)
        // A name that isn't a key's name goes into no URL.
        let github = try #require(Self.page("github"))
        #expect(github.newTokenURL(name: "github token&x=1", date: Self.thirteenthOfOctober) == nil)
    }

    @Test func aHostNamesItsProvider() {
        #expect(SecretKeyPages.page(forHost: "platform.openai.com")?.provider == "OpenAI")
        #expect(SecretKeyPages.page(forHost: "Platform.OpenAI.com")?.provider == "OpenAI")
        #expect(SecretKeyPages.page(forHost: "dashboard.stripe.com")?.provider == "Stripe")
        #expect(SecretKeyPages.page(forHost: "github.com")?.provider == "GitHub")
        // A region's host under the page's host is the provider's too; a port is not part of the host.
        #expect(SecretKeyPages.page(forHost: "us.cloud.langfuse.com")?.provider == "Langfuse")
        #expect(SecretKeyPages.page(forHost: "dashboard.stripe.com:443")?.provider == "Stripe")
        for host in ["example.com", "evilplatform.openai.com", "platform.openai.com.example.com", "openai.com", "",
                     "localhost:3000"] {
            #expect(SecretKeyPages.page(forHost: host) == nil, "\(host)")
        }
    }

    @Test func aLinkNamesThePageItIs() throws {
        let fineGrained = try #require(URL(string: "https://github.com/settings/personal-access-tokens"))
        #expect(SecretKeyPages.page(forLink: fineGrained)?.id == "github")
        let oneToken = try #require(URL(string: "https://github.com/settings/personal-access-tokens/4242"))
        #expect(SecretKeyPages.page(forLink: oneToken)?.id == "github")
        let classic = try #require(URL(string: "https://github.com/settings/tokens"))
        #expect(SecretKeyPages.page(forLink: classic)?.id == "github-classic")
        let keys = try #require(URL(string: "https://platform.openai.com/settings/organization/api-keys"))
        #expect(SecretKeyPages.page(forLink: keys)?.id == "openai")
        // A root page covers every path on its host; another page on a host with paths is none of them.
        let neon = try #require(URL(string: "https://console.neon.tech/app/projects/x"))
        #expect(SecretKeyPages.page(forLink: neon)?.id == "neon")
        for text in ["https://github.com/settings/profile", "https://github.com/settings/personal-access-tokensX",
                     "https://gist.github.com/settings/tokens", "http://github.com/settings/tokens"] {
            let url = try #require(URL(string: text))
            #expect(SecretKeyPages.page(forLink: url) == nil, "\(text)")
        }
    }
}
