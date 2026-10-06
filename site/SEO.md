# Search and AI visibility for next-term.mishuk.me

This file is not published. It lists what to do once the site is live, and what is already built in.

## Already in the build

- A unique `<title>` (60 characters or fewer) and meta description (155 or fewer) on every page, a canonical URL, Open Graph and Twitter card tags with a 1200 × 630 image (`/og.jpg`), `lang="en"`, one `<h1>` per page.
- JSON-LD: `SoftwareApplication` and `WebSite` on the home page, `BreadcrumbList` on every docs page, `FAQPage` on `/docs/faq/` (generated from the visible questions, so the two always match).
- `/sitemap-index.xml` (and `/sitemap-0.xml`) listing every page except the 404.
- `/robots.txt` allowing everything, naming GPTBot, OAI-SearchBot, ChatGPT-User, ClaudeBot, Claude-SearchBot, Claude-User, anthropic-ai, PerplexityBot, Perplexity-User, Google-Extended, Applebot-Extended and CCBot, with the sitemap line.
- `/llms.txt` (llmstxt.org format: summary, key facts, every docs page with a one-line description) and `/llms-full.txt` (all docs as Markdown), both generated from the docs at build time.
- `npm run check` verifies all of the above before a deploy.

The site’s address lives in one place: `SITE` in `astro.config.mjs`.

## 1. After the first deploy

Check that these answer `200` over HTTPS, and that `/nothing-here` answers `404` with the site’s not-found page:

```sh
for p in / /docs/ /docs/faq/ /robots.txt /sitemap-index.xml /llms.txt /llms-full.txt /og.jpg; do
  curl -s -o /dev/null -w "%{http_code} $p\n" "https://next-term.mishuk.me$p"
done
curl -s -o /dev/null -w "%{http_code} /nothing-here\n" https://next-term.mishuk.me/nothing-here
```

## 2. Google Search Console

The **domain property `mishuk.me` is already verified** (by the TXT record on the apex; do not delete it). A domain property covers every subdomain, so `next-term.mishuk.me` needs no new verification.

1. Open [Search Console](https://search.google.com/search-console) and pick the `mishuk.me` property.
2. **Sitemaps** → add `https://next-term.mishuk.me/sitemap-index.xml` → Submit.
3. **URL Inspection** → enter `https://next-term.mishuk.me/` → **Request indexing**. Do the same for `/docs/`, `/docs/agents/` and `/docs/faq/`.
4. Optional: add a URL-prefix property `https://next-term.mishuk.me/` to see this site’s reports on their own.
5. After a few days, check **Pages** (indexing) for errors, and **Core Web Vitals** once there is traffic.

Structured data:

- Test `https://next-term.mishuk.me/` and `/docs/faq/` in the [Rich Results Test](https://search.google.com/test/rich-results) and the [Schema Markup Validator](https://validator.schema.org/).
- Expect no star-rating rich result: Google shows those for software only with real ratings or reviews, and the site does not invent any. FAQ rich results are limited to a few kinds of sites, but the markup still helps search engines and assistants read the page.

## 3. Bing Webmaster Tools

Bing’s index also feeds ChatGPT search, Copilot and DuckDuckGo, so it matters for AI answers.

1. Sign in to [Bing Webmaster Tools](https://www.bing.com/webmasters).
2. Choose **Import from Google Search Console**: it brings the verified site and its sitemaps over.
3. If it does not list `next-term.mishuk.me`, add the site and submit `https://next-term.mishuk.me/sitemap-index.xml` under **Sitemaps**.
4. Use **URL Inspection** and **Request indexing** for the home page.
5. Optional: enable IndexNow later (a key file in `public/` and a ping after each deploy) so Bing and Yandex pick up changes within minutes.

## 4. AI search and assistants

- **Cloudflare comes first.** The site is behind Cloudflare, which can block AI crawlers no matter what `robots.txt` says. In the Cloudflare dashboard for `mishuk.me`: make sure **AI Crawl Control / Block AI bots** does not block this hostname, that **Managed robots.txt** is off (it would add `Disallow` lines for AI crawlers), and that **Bot Fight Mode** does not challenge verified bots. Then fetch `https://next-term.mishuk.me/robots.txt` and confirm it is exactly the file from the build.
- **llms.txt** is at `/llms.txt`, linked from every page’s footer and `<head>`. Assistants that read it get the summary and links; `/llms-full.txt` gives them all the docs in one request.
- **One set of facts everywhere.** Name (“Next Term”), tagline (“The missing IDE for the terminal”), what it is (a native macOS terminal and editor for running AI coding agents side by side), version, MIT. Keep the GitHub README, the repository’s About text and the release notes saying the same thing as the site.
- **Link the site from GitHub.** Set the repository’s Website field to `https://next-term.mishuk.me` and link it from the README. Add topics such as `macos`, `terminal`, `terminal-emulator`, `code-editor`, `swift`, `appkit`, `ai-agents`, `claude-code`, `codex`, `gemini-cli`.
- **Be where people and models read about agent tooling:** awesome lists (for example awesome-claude-code and awesome-macos), a Show HN post, and short write-ups that link to the docs. Assistants answer from what is widely and consistently written.
- **Answer-shaped pages.** The FAQ and the docs are written as direct answers (“How do I connect Claude Code to Next Term, as with VS Code?”). Add a question when people ask it.
- **Check every few weeks** by asking ChatGPT, Claude, Perplexity and Gemini questions such as “What terminal shows which Claude Code agent is waiting on me?”, “open-source Warp alternative for macOS”, “terminal for running several AI coding agents”, and note whether Next Term is named and described correctly.

## 5. Social cards

Paste `https://next-term.mishuk.me/` and a docs URL into a card preview (for example the LinkedIn Post Inspector or opengraph.xyz) and check the title, description and image. Regenerate `public/og.jpg` with `scripts/make-og-image.swift` after retaking the screenshots.

## 6. On every release

Update `VERSION` in `src/config.ts` and the version examples in the docs (see `README.md`), rebuild, run `npm run check`, deploy. The sitemap updates itself; there is nothing to resubmit. Request indexing for pages that changed a lot.
