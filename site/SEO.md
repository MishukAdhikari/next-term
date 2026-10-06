# Search and AI visibility for next-term.mishuk.me

This file is not published. It says where people and AI assistants find the site, what to do about it, and what the build already does. Last checked against the sources at the end on 6 October 2026.

## Is Search Console enough?

**No. Search Console covers Google only.** That includes Google Search, AI Overviews, AI Mode and Gemini’s grounding: they all draw on Google’s index, with nothing extra to set up. The other assistants draw on other indexes:

| Where people ask | What it searches | How a new site gets in |
|---|---|---|
| Google Search, AI Overviews, AI Mode | Google’s index (Googlebot) | Search Console: sitemap, URL Inspection |
| Gemini app | Google Search grounding (`Google-Extended` controls it; the site allows it) | Same as Google |
| ChatGPT search | OAI-SearchBot plus unnamed third-party search providers (widely reported to be Bing) | Allow OAI-SearchBot (done); Bing Webmaster Tools |
| Microsoft Copilot | Bing | Bing Webmaster Tools, IndexNow |
| DuckDuckGo | “Largely” Bing for ordinary links | Bing Webmaster Tools |
| Claude | Brave Search (Anthropic’s listed web-search subprocessor) and Claude-SearchBot | Allow Claude-SearchBot (done); Brave finds pages by crawling; links help |
| Perplexity | Its own index (PerplexityBot) | Allow PerplexityBot (done); links help |
| Brave Search | Its own index; crawls only what Googlebot may crawl | No console; links, or the re-fetch form |

So: Search Console for Google, **Bing Webmaster Tools plus IndexNow** for Bing (which carries ChatGPT search, Copilot and DuckDuckGo), and **links from places people already read** for Brave, Perplexity and Claude, which have no submission console.

## Checklist

### Owner actions, in this order

1. **Search Console** (`sc-domain:mishuk.me`, already verified by the apex TXT record; do not delete it).
   **Sitemaps** → add `https://next-term.mishuk.me/sitemap-index.xml` → Submit. Then **URL Inspection** → `https://next-term.mishuk.me/` → **Request indexing**; repeat for `/docs/`, `/docs/agents/`, `/docs/orchestration/` and `/docs/faq/`.
2. **Bing Webmaster Tools** ([bing.com/webmasters](https://www.bing.com/webmasters)). After step 1, sign in and choose **Import from Google Search Console**: it brings verified sites and their sitemaps and verifies them for you. If `next-term.mishuk.me` is not in the list, add it by hand (verification by DNS CNAME on `mishuk.me` needs no site change), submit the same sitemap, and use **URL Inspection → Request indexing** for the home page. Later, its **AI Performance** report shows citations in Copilot and Bing’s AI answers.
3. **IndexNow**, after the deploy that carries the key file: `npm run indexnow` once (all pages), then `npm run indexnow -- <changed paths>` after each later deploy. See `README.md`, “After a deploy: IndexNow”.
4. **GitHub repository settings** (currently empty): set the Website and topics, and link the site from the README:
   ```sh
   gh repo edit MishukAdhikari/next-term --homepage https://next-term.mishuk.me \
     --add-topic macos --add-topic terminal --add-topic terminal-emulator --add-topic code-editor \
     --add-topic swift --add-topic appkit --add-topic ai-agents --add-topic claude-code \
     --add-topic codex --add-topic gemini-cli --add-topic mcp --add-topic mcp-server
   ```
   In the README, a line under the tagline such as `Website and documentation: https://next-term.mishuk.me`.
5. **Cloudflare** (the API token cannot read these settings, so check them in the dashboard for `mishuk.me`):
   - **AI Crawl Control / Block AI bots** must not block this hostname; **Bot Fight Mode** must not challenge verified bots. A request with a crawler’s user-agent from an ordinary IP gets `200`, which does not prove the real crawlers do: Cloudflare judges them by verified IP. After step 2, Bing’s URL Inspection shows what Bingbot gets.
   - **Managed robots.txt** is off: the live `/robots.txt` is byte-for-byte the build’s.
   - **Web Analytics** injects `static.cloudflareinsights.com/beacon.min.js` into pages served to browsers. That contradicts the footer (“no trackers and no third-party requests”). Either turn off its automatic setup for this hostname, or change the footer.
6. **Be written about where people and models read about agent tooling**, as each becomes possible:
   - **Show HN** (“Show HN: Next Term – a macOS terminal that shows which AI agent needs you”), linking the GitHub repository or the site, when you can stay in the thread for a few hours.
   - **awesome-claude-code**: its rules need 14 days since the first commit with continued work (from 20 October 2026) or 100 stars. Submit through its web issue form, by hand; one resource at a time.
   - **awesome-mac** and **open-source-mac-os-apps**: pull requests following each list’s CONTRIBUTING.
   - **Product Hunt**: optional; it brings a link and some traffic more than search value.
   - **Homebrew cask**: not yet. homebrew/cask requires apps to pass Gatekeeper, and releases are not notarized. Revisit after notarization (or offer a tap of your own).
7. **Brave Search** (Claude’s web search): no console exists. Once the site is linked from GitHub and elsewhere, check `site:next-term.mishuk.me` on search.brave.com; if it is missing after a few weeks, use [search.brave.com/submit-url](https://search.brave.com/submit-url).
8. **Check every few weeks**: Search Console **Pages**, **Performance** and the **Generative AI performance** report (AI Overviews and AI Mode), Bing’s **AI Performance**, and ask ChatGPT, Claude, Perplexity, Gemini and Copilot questions such as “terminal that shows which Claude Code agent is waiting on me”, “open-source Warp alternative for macOS”, “MCP server to orchestrate Claude Code and Codex”. Note whether Next Term is named and described correctly.

### Decisions for the owner

- **Home page title.** “Next Term — the missing IDE for the terminal” has neither “macOS” nor “AI agents” in it, and the title is what search results and AI citations show. A version such as “Next Term — the macOS terminal for AI coding agents” (52 characters) would match what people type. The tagline stays on the page either way.
- **Cloudflare Web Analytics** (above): keep the beacon and change the footer, or turn it off.
- **Sitemap `lastmod`**: not set. Bing asks for an accurate one and Google uses it when it is accurate. For 17 pages that IndexNow and the sitemap already cover, it matters little; adding it means configuring `@astrojs/sitemap` directly with dates from git.
- **Markdown copies of each page** (llms.txt v2 suggests `/docs/agents/index.md` plus `rel="alternate" type="text/markdown"`): `/llms-full.txt` already gives agents every page as Markdown, so this is optional.

### Site changes (done in the build)

- A unique `<title>` (60 characters or fewer) and meta description (155 or fewer) on every page, a canonical URL, Open Graph and Twitter card tags with a 1200 × 630 image (`/og.jpg`), `lang="en"`, one `<h1>` per page. The not-found page has no canonical or `og:url` (it is served at every missing address) and is `noindex`.
- JSON-LD: `SoftwareApplication` and `WebSite` on the home page, `BreadcrumbList` on every docs page, `FAQPage` on `/docs/faq/` (generated from the visible questions, so the two always match).
- `/sitemap-index.xml` (and `/sitemap-0.xml`) listing every page except the 404.
- `/robots.txt` allowing everything, naming GPTBot, OAI-SearchBot, ChatGPT-User, ClaudeBot, Claude-SearchBot, Claude-User, anthropic-ai, PerplexityBot, Perplexity-User, Google-Extended, Applebot-Extended and CCBot, with the sitemap line.
- `/llms.txt` (llmstxt.org format) and `/llms-full.txt` (all docs as Markdown), generated from the docs at build time. Every page links to `/llms.txt` with `rel="describedby"`, as llms.txt v2 recommends. Lighthouse’s agentic-browsing audit passes. Google Search ignores llms.txt (it neither helps nor hurts there); it is for agents and tools that read docs.
- `/<key>.txt`, the IndexNow key file, from `INDEXNOW_KEY` in `src/config.ts`, and `scripts/indexnow.mjs` to ping after a deploy.
- `npm run check` verifies all of the above before a deploy.

The site’s address lives in one place: `SITE` in `astro.config.mjs`.

## What the structured data can and cannot do

- **No software rich result.** Google shows the software-app rich result only with `offers.price` *and* `aggregateRating` or `review`. The site has the price (0) and no ratings, and must not invent any. The markup still tells search engines and assistants the name, category, OS, version, price, licence and download.
- **No FAQ rich result.** Google stopped showing FAQ rich results on 7 May 2026 and removed their documentation in June. The `FAQPage` markup is still valid schema.org, harmless, and readable by other engines and assistants, so it stays.
- **Nothing special for AI Overviews.** Google’s AI features use the ordinary index: a page needs to be indexed and eligible for a snippet, and “there’s no special schema.org structured data that you need to add”.
- Test after deploys that change them: the [Rich Results Test](https://search.google.com/test/rich-results) and the [Schema Markup Validator](https://validator.schema.org/).

## Re-checking the live site

```sh
for p in / /docs/ /docs/faq/ /robots.txt /sitemap-index.xml /llms.txt /llms-full.txt /og.jpg; do
  curl -s -o /dev/null -w "%{http_code} $p\n" "https://next-term.mishuk.me$p"
done
curl -s -o /dev/null -w "%{http_code} /nothing-here\n" https://next-term.mishuk.me/nothing-here
curl -s https://next-term.mishuk.me/robots.txt | diff - dist/robots.txt && echo "robots.txt as built"
```

## Social cards

Paste `https://next-term.mishuk.me/` and a docs URL into a card preview (for example the LinkedIn Post Inspector or opengraph.xyz) and check the title, description and image. Regenerate `public/og.jpg` with `scripts/make-og-image.swift` after retaking the screenshots.

## On every release

Update `VERSION` in `src/config.ts` and the version examples in the docs (see `README.md`), rebuild, run `npm run check`, deploy, then `npm run indexnow -- <the pages that changed>`. The sitemap updates itself; there is nothing to resubmit in Search Console. Request indexing there only for pages that changed a lot.

## Sources

- Google: [AI features and your website](https://developers.google.com/search/docs/appearance/ai-features), [optimizing for generative AI features](https://developers.google.com/search/docs/fundamentals/ai-optimization-guide) (llms.txt “neither harm nor help”), [Google-Extended](https://developers.google.com/search/docs/crawling-indexing/google-common-crawlers), [software app structured data](https://developers.google.com/search/docs/appearance/structured-data/software-app), [sitemaps and lastmod](https://developers.google.com/search/docs/crawling-indexing/sitemaps/build-sitemap), [changelog](https://developers.google.com/search/updates) (FAQ rich result removed May 2026).
- OpenAI: [crawlers](https://developers.openai.com/api/docs/bots), [searching the web with ChatGPT](https://help.openai.com/en/articles/9237897-chatgpt-search).
- Microsoft: [web search in Copilot uses Bing](https://learn.microsoft.com/en-us/copilot/microsoft-365/manage-public-web-access), [import from Search Console](https://blogs.bing.com/webmaster/september-2019/Import-sites-from-Search-Console-to-Bing-Webmaster-Tools), [AI Performance report](https://blogs.bing.com/webmaster/2026/2/Introducing-AI-Performance-in-Bing-Webmaster-Tools-Public-Preview/), [sitemaps in AI search](https://blogs.bing.com/webmaster/2025/7/Keeping-Content-Discoverable-with-Sitemaps-in-AI-Powered-Search/).
- Anthropic: [crawlers](https://support.claude.com/en/articles/8896518-does-anthropic-crawl-data-from-the-web-and-how-can-site-owners-block-the-crawler), [subprocessors](https://trust.anthropic.com/subprocessors) (Brave Search, web search).
- Perplexity: [crawlers](https://docs.perplexity.ai/guides/bots), [its own index](https://www.perplexity.ai/hub/blog/architecting-and-evaluating-an-ai-first-search-api).
- DuckDuckGo: [result sources](https://duckduckgo.com/duckduckgo-help-pages/results/sources). Brave: [crawler](https://search.brave.com/help/brave-search-crawler).
- IndexNow: [documentation](https://www.indexnow.org/documentation), [FAQ](https://www.indexnow.org/faq), [participating engines](https://www.indexnow.org/searchengines.json).
- llms.txt: [the v2 proposal](https://llmstxt.org/), [Lighthouse audit](https://developer.chrome.com/docs/lighthouse/agentic-browsing/llms-txt).
- Distribution: [Show HN](https://news.ycombinator.com/showhn.html), [awesome-claude-code rules](https://github.com/hesreallyhim/awesome-claude-code/blob/main/CONTRIBUTING.md), [Homebrew acceptable casks](https://docs.brew.sh/Acceptable-Casks), [GitHub topics](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/classifying-your-repository-with-topics).
