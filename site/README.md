# next-term.mishuk.me

The website and documentation for Next Term: a landing page and one documentation page per area, built with [Astro](https://astro.build) and [Starlight](https://starlight.astro.build) (both MIT). The output is plain static files: no server code, no cookies, no trackers, and no requests to any other site.

## Commands

Run these in `site/`. Node 22.12 or later.

| Command | Does |
|---|---|
| `npm ci` | Install the pinned dependencies (into `site/node_modules` only) |
| `npm run dev` | Local server with live reload at `http://localhost:4321` (search works only in a build) |
| `npm run build` | Build the site into `site/dist/` |
| `npm run preview` | Serve `dist/` locally, search included |
| `npm run check` | Check `dist/`: links and #fragments, HTML structure, JSON-LD, sitemap, third-party requests, title and description lengths, one `<h1>`, alt text, typography (needs Python 3) |

The build must finish without warnings and `npm run check` must pass before a deploy. CI (`.github/workflows/site.yml`) runs both on every change to `site/`.

## Where things are

| Path | What |
|---|---|
| `astro.config.mjs` | **The site’s address (`SITE`)**, the sidebar, the head tags every page gets, Starlight options |
| `src/config.ts` | Facts pages repeat: version, download and repository links, the one-sentence summary |
| `src/pages/index.astro` | The landing page, with its `SoftwareApplication` and `WebSite` JSON-LD |
| `src/content/docs/docs/*.md` | The documentation, one Markdown file per page (`docs/index.mdx` is the docs home) |
| `src/routeData.ts` | Adds `BreadcrumbList` JSON-LD to every docs page and `FAQPage` to the FAQ, read from the page itself |
| `src/pages/llms.txt.ts`, `llms-full.txt.ts` | `/llms.txt` and `/llms-full.txt`, generated from the docs at build time |
| `src/pages/robots.txt.ts` | `/robots.txt`: everything allowed, AI crawlers named, the sitemap |
| `src/pages/404.astro` | The not-found page (`dist/404.html`) |
| `src/styles/custom.css` | The app’s colours (dark and light), fonts, measure, tables, keys |
| `src/assets/screenshots/` | Screenshots, and a README saying which to retake |
| `public/` | Favicon, touch icon, `og.jpg` social card |
| `scripts/check-dist.py` | The checks behind `npm run check` |
| `scripts/make-og-image.swift` | Rebuilds `public/og.jpg` |
| `SEO.md` | Search Console, Bing and AI-search steps (not published) |

### Changing the address

`SITE` in `astro.config.mjs` is the only place the domain is written. Canonical URLs, Open Graph tags, the sitemap, `robots.txt`, `llms.txt` and the JSON-LD all follow it. Change it, rebuild, and point the web server at the new name.

### A new Next Term release

1. Set `VERSION` in `src/config.ts`.
2. Search the docs for the old version (`grep -rn "0.2.0" src/content`) and update the DMG name and the examples.
3. Update anything the release added or changed, labelling what is not released yet as “Coming next” or “Coming soon”.
4. `npm run build && npm run check`, then deploy.

### Writing style

Docs say what a feature does, how to use it (menus and keys) and why it matters, in plain sentences. Type it properly: curly quotes and apostrophes (’ “ ”), en dashes for ranges (1–8), em dashes for breaks, the ellipsis character (…), the real minus in `+12 −3`, and the macOS key glyphs in `<kbd>` in Apple’s order: <kbd>⌃⌥⇧⌘K</kbd>. Write `&#96;` for a backtick inside `<kbd>`. Bold, not italic, for emphasis. `npm run check` catches straight quotes, `--`, `...` and double spaces.

## Deploying

The site is plain files in `dist/`. Copy them to the web root (for example `/var/www/next-term.mishuk.me`), replacing what is there:

```sh
npm ci && npm run build && npm run check
rsync -a --delete dist/ <host>:/var/www/next-term.mishuk.me/
```

An nginx server block that fits the build (Astro writes `page/index.html` for each page and long-lived, content-hashed files under `/_astro/`):

```nginx
server {
    server_name next-term.mishuk.me;
    root /var/www/next-term.mishuk.me;
    index index.html;
    charset utf-8;                      # llms.txt and robots.txt contain curly quotes and ⌘
    charset_types text/plain text/css application/javascript application/xml;

    error_page 404 /404.html;

    location / {
        try_files $uri $uri/ =404;      # /docs/agents → 301 to /docs/agents/ → index.html
    }
    location /_astro/ {
        add_header Cache-Control "public, max-age=31536000, immutable";
    }
    location /pagefind/ {
        add_header Cache-Control "public, max-age=3600";
    }

    add_header X-Content-Type-Options nosniff always;
    add_header Referrer-Policy strict-origin-when-cross-origin always;

    gzip on;
    gzip_types text/plain text/css application/javascript application/json application/xml image/svg+xml;
    # listen / TLS as for the server's other sites
}
```

Pagefind (the search) loads `.wasm` and `.pf_*` files from `/pagefind/`; nginx’s standard `mime.types` covers them. Behind Cloudflare, see the crawler notes in `SEO.md`: Cloudflare’s AI-bot blocking would override `robots.txt`.
