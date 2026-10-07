#!/usr/bin/env python3
"""Checks the built site in dist/ before it is deployed. Run after `npm run build`:

    npm run check        (or: python3 scripts/check-dist.py)

It fails (exit 1) on:
- internal links, images, scripts and #fragments that do not resolve to a built file or element;
- HTML that is not well formed (unbalanced or misnested tags);
- JSON-LD that does not parse, or a page missing the structured data it should have;
- a page missing from the sitemap, or a sitemap entry with no page;
- a missing IndexNow key file, or a canonical link on the not-found page;
- any resource loaded from another origin (scripts, styles, fonts, images, frames);
- a <title> over 60 characters, a meta description over 155, no or several <h1>, a missing lang,
  an image without alt text;
- typewriter typography in visible text: straight quotes, "--", "...", double spaces.

Standard library only, so it runs anywhere Python 3.9+ does.
"""
from __future__ import annotations

import json
import re
import sys
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urlparse
from xml.etree import ElementTree

ROOT = Path(__file__).resolve().parent.parent
DIST = ROOT / "dist"
CONFIG = (ROOT / "astro.config.mjs").read_text(encoding="utf-8")
SITE = re.search(r"const SITE = '([^']+)'", CONFIG).group(1).rstrip("/")
SITE_HOST = urlparse(SITE).netloc

VOID = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"}
# Elements whose text is code or not visible prose: typography rules do not apply inside them.
NO_TYPO = {"code", "pre", "kbd", "script", "style", "svg", "template", "textarea", "samp"}
# Hosts that pages may link to (navigation only; nothing is loaded from them).
LINK_HOSTS = {"github.com", "opensource.org"}
# The official sites the comparison pages (/compare/) cite as their sources.
LINK_HOSTS |= {
    "code.visualstudio.com", "docs.github.com", "code.claude.com",
    "www.jetbrains.com", "blog.jetbrains.com", "junie.jetbrains.com",
    "cursor.com", "devin.ai", "docs.devin.ai", "zed.dev",
    "iterm2.com", "ghostty.org",
}

errors: list[str] = []
warnings: list[str] = []


def error(page: str, message: str) -> None:
    errors.append(f"{page}: {message}")


class Page(HTMLParser):
    def __init__(self, name: str) -> None:
        super().__init__(convert_charrefs=True)
        self.name = name
        self.stack: list[tuple[str, int]] = []
        self.ids: set[str] = set()
        self.links: list[tuple[str, str, str]] = []  # (tag, attribute, url)
        self.jsonld: list[str] = []
        self.title = ""
        self.description: str | None = None
        self.h1 = 0
        self.lang: str | None = None
        self.text_runs: list[str] = []
        self._in_title = False
        self._in_jsonld = False
        self._no_typo = 0
        self._buffer: list[str] = []
        self.images_without_alt: list[str] = []

    # Structure ---------------------------------------------------------------------------------
    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag not in VOID:
            self.stack.append((tag, self.getpos()[0]))
        if tag == "html":
            self.lang = a.get("lang")
        if "id" in a and a["id"]:
            self.ids.add(a["id"])
        if tag == "a" and a.get("name"):
            self.ids.add(a["name"])
        if tag == "title":
            self._in_title = True
        if tag == "h1":
            self.h1 += 1
        if tag == "meta" and a.get("name") == "description":
            self.description = a.get("content", "")
        if tag == "script" and a.get("type") == "application/ld+json":
            self._in_jsonld = True
            self._buffer = []
        if tag in NO_TYPO:
            self._no_typo += 1
        if tag == "img" and "alt" not in a:
            self.images_without_alt.append(a.get("src", "?"))
        for attribute in ("href", "src"):
            if a.get(attribute):
                self.links.append((tag, attribute, a[attribute]))
        for attribute in ("srcset",):
            if a.get(attribute):
                for candidate in a[attribute].split(","):
                    url = candidate.strip().split(" ")[0]
                    if url:
                        self.links.append((tag, "srcset", url))
        if tag == "link":
            self.links.append(("link:" + (a.get("rel") or ""), "href", a.get("href", "")))
        if a.get("style"):
            for url in re.findall(r"url\(([^)]+)\)", a["style"]):
                self.links.append((tag, "style", url.strip("'\" ")))

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)
        if tag not in VOID and self.stack and self.stack[-1][0] == tag:
            self.stack.pop()
            if tag in NO_TYPO:
                self._no_typo -= 1

    def handle_endtag(self, tag):
        if tag in VOID:
            return
        if tag == "title":
            self._in_title = False
        if tag == "script" and self._in_jsonld:
            self.jsonld.append("".join(self._buffer))
            self._in_jsonld = False
        if tag in NO_TYPO:
            self._no_typo = max(0, self._no_typo - 1)
        if not self.stack:
            error(self.name, f"line {self.getpos()[0]}: </{tag}> closes nothing")
            return
        open_tag, line = self.stack[-1]
        if open_tag == tag:
            self.stack.pop()
            return
        # Tolerate the end tags HTML lets you omit (p, li, td…) only if the real match is below.
        names = [t for t, _ in self.stack]
        if tag in names:
            while self.stack and self.stack[-1][0] != tag:
                skipped, at = self.stack.pop()
                if skipped not in {"p", "li", "dt", "dd", "tr", "td", "th", "option", "thead", "tbody"}:
                    error(self.name, f"line {at}: <{skipped}> is not closed before </{tag}>")
            self.stack.pop()
        else:
            error(self.name, f"line {self.getpos()[0]}: </{tag}> does not match <{open_tag}> from line {line}")

    def handle_data(self, data):
        if self._in_title:
            self.title += data
        if self._in_jsonld:
            self._buffer.append(data)
        elif self._no_typo == 0 and data.strip():
            self.text_runs.append(data)


def target_for(path: str) -> Path | None:
    """The built file a site path refers to, or None."""
    path = unquote(path)
    candidates = []
    if path.endswith("/"):
        candidates.append(DIST / path.lstrip("/") / "index.html")
    else:
        candidates.append(DIST / path.lstrip("/"))
        candidates.append(DIST / path.lstrip("/") / "index.html")
    for candidate in candidates:
        if candidate.is_file():
            return candidate
    return None


def page_url(file: Path) -> str:
    rel = file.relative_to(DIST).as_posix()
    if rel == "index.html":
        return "/"
    if rel.endswith("/index.html"):
        return "/" + rel[: -len("index.html")]
    return "/" + rel


def main() -> int:
    if not DIST.is_dir():
        print("dist/ not found: run `npm run build` first.", file=sys.stderr)
        return 1
    html_files = sorted(DIST.rglob("*.html"))
    html_files = [f for f in html_files if "pagefind" not in f.parts]
    pages: dict[str, Page] = {}
    for file in html_files:
        name = page_url(file)
        parser = Page(name)
        parser.feed(file.read_text(encoding="utf-8"))
        parser.close()
        for tag, line in parser.stack:
            if tag not in {"html", "body", "head", "p", "li"}:
                error(name, f"line {line}: <{tag}> is never closed")
        pages[name] = parser

    # Links, resources and fragments --------------------------------------------------------------
    external_links: dict[str, set[str]] = {}
    for name, page in pages.items():
        for tag, attribute, url in page.links:
            if not url or url.startswith(("mailto:", "tel:", "data:", "javascript:")):
                continue
            parsed = urlparse(url)
            is_navigation = tag == "a"
            if parsed.scheme in ("http", "https"):
                if parsed.netloc == SITE_HOST:
                    # Absolute links to this site (canonical, og:url): must exist too.
                    path = parsed.path or "/"
                    if target_for(path) is None and not path.startswith("/404"):
                        error(name, f"{tag} {attribute}={url} points at a page that is not built")
                    continue
                if is_navigation or tag.startswith("link:canonical") or tag.startswith("link:alternate"):
                    external_links.setdefault(parsed.netloc, set()).add(url)
                    if parsed.netloc not in LINK_HOSTS:
                        warnings.append(f"{name}: link to {url}")
                    continue
                if tag.startswith("link:") and not any(r in tag for r in ("stylesheet", "preload", "modulepreload", "icon", "manifest", "prefetch", "preconnect", "dns-prefetch")):
                    continue
                error(name, f"loads a third-party resource: <{tag} {attribute}={url}>")
                continue
            if parsed.scheme:
                continue
            if url.startswith("#"):
                fragment = unquote(url[1:])
                if fragment and fragment not in page.ids:
                    error(name, f"#{fragment} has no matching id on the page")
                continue
            if url.startswith("//"):
                error(name, f"protocol-relative URL {url}")
                continue
            path = parsed.path
            if not path.startswith("/"):
                base = name if name.endswith("/") else name.rsplit("/", 1)[0] + "/"
                path = str(Path(base + path)).replace("\\", "/")
                if url.endswith("/") and not path.endswith("/"):
                    path += "/"
            target = target_for(path)
            if target is None:
                error(name, f"{tag} {attribute}={url} does not resolve")
                continue
            if parsed.fragment and target.suffix == ".html":
                target_page = pages.get(page_url(target))
                if target_page and unquote(parsed.fragment) not in target_page.ids:
                    error(name, f"{url}: #{parsed.fragment} not found on {page_url(target)}")

    # Built CSS and JS must not pull anything from elsewhere.
    for asset in list(DIST.rglob("*.css")) + list(DIST.rglob("*.js")):
        text = asset.read_text(encoding="utf-8", errors="replace")
        rel = asset.relative_to(DIST).as_posix()
        for match in re.finditer(r"""(?:@import\s+(?:url\()?|url\()\s*['"]?(https?:)?//([^'")\s]+)""", text):
            error(rel, f"loads a third-party resource: {match.group(0)[:120]}")
        for host in ("fonts.googleapis.com", "fonts.gstatic.com", "googletagmanager.com", "google-analytics.com", "cdn.jsdelivr.net", "unpkg.com", "cdnjs.cloudflare.com"):
            if host in text:
                error(rel, f"mentions {host}")

    # Head, headings, images, language ------------------------------------------------------------
    for name, page in pages.items():
        if page.lang != "en":
            error(name, f'<html lang="{page.lang}"> (expected "en")')
        title = page.title.strip()
        if not title:
            error(name, "no <title>")
        elif len(title) > 60:
            error(name, f"<title> is {len(title)} characters (max 60): {title}")
        if page.description is None:
            error(name, "no meta description")
        elif len(page.description) > 155:
            error(name, f"meta description is {len(page.description)} characters (max 155)")
        if page.h1 != 1:
            error(name, f"{page.h1} <h1> elements (expected exactly 1)")
        for src in page.images_without_alt:
            error(name, f"image without alt: {src}")

    # Structured data -------------------------------------------------------------------------------
    for name, page in pages.items():
        types = []
        for block in page.jsonld:
            try:
                data = json.loads(block)
            except json.JSONDecodeError as exc:
                error(name, f"JSON-LD does not parse: {exc}")
                continue
            types.append(data.get("@type"))
            if data.get("@type") == "FAQPage" and len(data.get("mainEntity", [])) < 5:
                error(name, "FAQPage has fewer than 5 questions")
        if name == "/":
            for wanted in ("WebSite", "SoftwareApplication"):
                if wanted not in types:
                    error(name, f"missing {wanted} JSON-LD")
        if name.startswith("/docs/") and "BreadcrumbList" not in types:
            error(name, "missing BreadcrumbList JSON-LD")
        if name == "/docs/faq/" and "FAQPage" not in types:
            error(name, "missing FAQPage JSON-LD")

    # Sitemap ---------------------------------------------------------------------------------------
    listed: set[str] = set()
    namespace = {"s": "http://www.sitemaps.org/schemas/sitemap/0.9"}
    index = ElementTree.parse(DIST / "sitemap-index.xml")
    for loc in index.findall(".//s:loc", namespace):
        sitemap = DIST / urlparse(loc.text).path.lstrip("/")
        for page_loc in ElementTree.parse(sitemap).findall(".//s:loc", namespace):
            listed.add(urlparse(page_loc.text).path)
    expected = {name for name in pages if not name.startswith("/404")}
    for name in sorted(expected - listed):
        error("sitemap", f"{name} is not listed")
    for name in sorted(listed - expected):
        error("sitemap", f"{name} is listed but not built")

    # Text files for crawlers ----------------------------------------------------------------------
    for name in ("robots.txt", "llms.txt", "llms-full.txt"):
        if not (DIST / name).is_file():
            error(name, "missing")
    robots = (DIST / "robots.txt").read_text(encoding="utf-8")
    for agent in ("GPTBot", "ClaudeBot", "PerplexityBot", "Google-Extended"):
        if f"User-agent: {agent}" not in robots:
            error("robots.txt", f"does not name {agent}")
    if f"Sitemap: {SITE}/sitemap-index.xml" not in robots:
        error("robots.txt", "no Sitemap line for this site")
    for name in ("llms.txt", "llms-full.txt"):
        text = (DIST / name).read_text(encoding="utf-8")
        for url in re.findall(r"\((https?://[^)\s]+)\)", text):
            parsed = urlparse(url)
            if parsed.netloc == SITE_HOST and target_for(parsed.path or "/") is None:
                error(name, f"link {url} does not resolve")

    # The IndexNow key file: /<key>.txt holding exactly the key from src/config.ts.
    key = re.search(r"export const INDEXNOW_KEY = '([^']+)'", (ROOT / "src" / "config.ts").read_text(encoding="utf-8"))
    if not key:
        error("src/config.ts", "no INDEXNOW_KEY")
    else:
        key_file = DIST / f"{key.group(1)}.txt"
        if not key_file.is_file():
            error(key_file.name, "IndexNow key file missing")
        elif key_file.read_text(encoding="utf-8").strip() != key.group(1):
            error(key_file.name, "does not contain exactly the IndexNow key")

    # The not-found page is served at every missing address: it must not claim an address of its own.
    not_found = pages.get("/404.html")
    if not_found and any(tag == "link:canonical" for tag, _, _ in not_found.links):
        error("/404.html", "has a canonical link")

    # Typography in visible text ------------------------------------------------------------------
    rules = [
        (re.compile(r'"'), "straight double quote"),
        (re.compile(r"(?<![A-Za-z0-9])'|'(?![A-Za-z])|(?<=[A-Za-z])'(?=[A-Za-z])"), "straight apostrophe or quote"),
        (re.compile(r"(?<!-)--(?!-)"), "double hyphen (use an en or em dash)"),
        (re.compile(r"\.\.\."), "three periods (use …)"),
        (re.compile(r"\S  +\S"), "double space"),
    ]
    for name, page in pages.items():
        for run in page.text_runs:
            for pattern, label in rules:
                if pattern.search(run):
                    error(name, f"{label} in text: {run.strip()[:80]!r}")

    # Words glued to inline elements: a space lost when markup was split across lines.
    glued = re.compile(r"[A-Za-z0-9,;:]<(?:a|code|kbd|strong)[ >]|</(?:a|code|kbd|strong)>[A-Za-z0-9(]")
    for file in html_files:
        html = file.read_text(encoding="utf-8")
        html = re.sub(r"<(script|style)\b.*?</\1>", "", html, flags=re.S)
        for match in glued.finditer(html):
            context = html[max(0, match.start() - 30): match.end() + 30].replace("\n", " ")
            error(page_url(file), f"missing space around an inline element: …{context}…")

    # Report ----------------------------------------------------------------------------------------
    for message in warnings:
        print(f"note: {message}")
    print(f"Checked {len(pages)} pages in {DIST}.")
    print("External link hosts: " + ", ".join(f"{host} ({len(urls)})" for host, urls in sorted(external_links.items())))
    if errors:
        for message in errors:
            print(f"error: {message}", file=sys.stderr)
        print(f"{len(errors)} problem(s).", file=sys.stderr)
        return 1
    print("All checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
