#!/usr/bin/env python3
"""Builds Resources/Highlighting from a shiki-swift checkout: the TextMate grammars Next Term ships,
in shiki-swift's manifest format, with only licences we have checked.

    python3 scripts/update-highlighting.py <path to shiki-swift checkout>

shiki-swift's own `Shiki` resource bundle carries every grammar it knows, including GPL-3.0 ones
(nginx, ada, gnuplot, org, racket) and some with no licence at all. Next Term never ships that bundle:
it loads this curated copy through `BundledShikiAssets(bundle:)` instead.
"""
import json
import pathlib
import re
import shutil
import sys

# What a developer opens most, by file type. Each language pulls in the grammars it embeds.
WANTED = """
php blade html html-derivative css scss less javascript typescript tsx jsx json jsonc json5 jsonl
markdown yaml toml shellscript fish powershell python go rust swift sql xml java kotlin c cpp csharp
objective-c lua vue svelte graphql ini diff git-commit git-rebase dotenv perl r dart erlang haskell
scala clojure groovy hcl terraform nix proto prisma regexp twig astro csv log viml cmake http docker
make ruby elixir zig ocaml julia
mdx liquid handlebars jinja pug erb haml razor edge templ angular-html angular-ts marko glimmer-js glimmer-ts
stylus sass coffee postcss just
cypher rst tsv mermaid sparql turtle
""".split()

# SPDX ids whose terms allow shipping the grammar file in an MIT app with a notice.
PERMISSIVE = {"MIT", "Apache-2.0", "BSD-2-Clause", "BSD-3-Clause", "ISC", "Zlib", "0BSD", "Unlicense", "CC0-1.0", "MPL-2.0"}
# TextMate's own bundles declare no SPDX id; their README grants: "Permission to copy, use, modify,
# sell and distribute this software is granted." Checked for yaml.tmbundle, toml.tmbundle and
# ruby.tmbundle (erb; no -license file beside it).
TEXTMATE_PERMISSIVE = ("https://github.com/textmate/yaml.tmbundle/", "https://github.com/textmate/toml.tmbundle/",
                       "https://github.com/textmate/ruby.tmbundle/")
# GitHub could not classify these LICENSE files; read by hand (2026-10-06).
CHECKED = {
    "sass": "MIT (LICENSE: Robin Bentley, Leonard Grosoli; atom/language-sass)",
    "elixir": "Apache-2.0 (LICENSE: Copyright 2012 Plataformatec)",
    # Read at both pinned commits (a1963c6 sparql, 3f1364b turtle) and at HEAD, 2026-10-07.
    "sparql": "Apache-2.0 (stardog-vsc/stardog-rdf-grammars/LICENSE)",
    "turtle": "Apache-2.0 (stardog-vsc/stardog-rdf-grammars/LICENSE)",
}
# tm-grammars' NOTICE has no section for these, so their licence text ships beside it, from
# scripts/grammars/licenses (copied unchanged from upstream).
LICENSE_TEXT = {"sparql": "stardog-rdf-grammars-LICENSE.txt", "turtle": "stardog-rdf-grammars-LICENSE.txt"}
# Grammars a language always loads with it, on top of the ones shiki-swift lists. Next Term tokenizes a
# line at a time, and shiki-swift guesses lazy embeds from that one line, so front matter (which needs
# both `---` lines in one string) would only colour if YAML happened to be loaded already. Mermaid
# colours Markdown fences as an injection, which only works once it is loaded.
EAGER = {"markdown": ["yaml", "mermaid"], "mdx": ["yaml"]}
# Scopes an injection grammar is injected into, where its file does not say (shiki-swift reads the file).
INJECT_TO = {"mermaid": ["text.html.markdown"]}
# Grammars with an injectionSelector that inject nowhere, knowingly. angular-expression: the other
# Angular grammars include it by name, as in shiki. vue-sfc-style-variable-injection: upstream targets
# source.vue, but Vue's grammar is text.html.vue, so it never applied.
NOT_INJECTED = {"angular-expression", "vue-sfc-style-variable-injection"}


def main(checkout: str) -> None:
    src = pathlib.Path(checkout) / "Sources/Shiki/Resources"
    out = pathlib.Path(__file__).resolve().parent.parent / "Resources/Highlighting"
    manifest = json.loads((src / "language-manifest.json").read_text())
    provenance = json.loads((src / "provenance.json").read_text())
    languages = {entry["id"]: entry for entry in manifest["languages"]}
    assets = {asset["id"]: asset for asset in provenance["assets"] if asset["kind"] in ("grammar", "injection")}

    def licence(lang: str):
        if lang in CHECKED:
            return CHECKED[lang]
        asset = assets[lang]
        spdx = asset["license"].get("spdx")
        if spdx in PERMISSIVE:
            return spdx
        if asset["source"].startswith(TEXTMATE_PERMISSIVE):
            return "TextMate bundle licence (permission to copy, use, modify, sell and distribute)"
        return None

    chosen, refused = {}, {}

    def take(lang: str, wanted_by: str) -> bool:
        if lang in chosen:
            return True
        if lang in refused or lang not in languages or lang not in assets:
            refused.setdefault(lang, "not in shiki-swift")
            return False
        why = licence(lang)
        if why is None:
            refused[lang] = f"licence {assets[lang]['license'].get('spdx')!r} (wanted by {wanted_by})"
            return False
        chosen[lang] = why
        for dependency in languages[lang]["embeddedLangs"] + EAGER.get(lang, []):
            take(dependency, lang)  # a missing embedded grammar only leaves that part plain
        return True

    for lang in WANTED:
        take(lang, "Next Term")

    scopes = {languages[lang]["scopeName"] for lang in chosen}
    notice = (src / "licenses/tm-grammars-NOTICE.txt").read_text()
    in_notice = {name.strip() for files in re.findall(r"^Files:\s+(.*)$", notice, re.M) for name in files.split(",")}
    entries, grammars = [], {}
    for lang in sorted(chosen):
        entry = dict(languages[lang])
        # Only point at grammars that ship; lazy ones load on demand (Markdown code fences).
        eager = entry["embeddedLangs"] + [x for x in EAGER.get(lang, []) if x not in entry["embeddedLangs"]]
        entry["embeddedLangs"] = [x for x in eager if x in chosen]
        entry["embeddedLangsLazy"] = [x for x in entry["embeddedLangsLazy"] if x in chosen and x not in eager]
        entry["embeddedIn"] = [x for x in entry.get("embeddedIn", []) if x in chosen]
        # injectTo holds scope names: keep those a shipped grammar's scope is, or starts with.
        targets = entry.get("injectTo", []) + [x for x in INJECT_TO.get(lang, []) if x not in entry.get("injectTo", [])]
        entry["injectTo"] = [x for x in targets if any(s == x or s.startswith(x + ".") for s in scopes)]
        entries.append(entry)
        data = (src / entry["resource"]).read_bytes()
        raw = json.loads(data)
        if lang in INJECT_TO:
            raw["injectTo"] = entry["injectTo"]
            data = (json.dumps(raw, separators=(",", ":"), ensure_ascii=False) + "\n").encode()
        grammars[entry["resource"]] = data
        if "injectionSelector" in raw and lang not in NOT_INJECTED and not (entry["injectTo"] and raw.get("injectTo")):
            sys.exit(f"{lang} has an injectionSelector but injects into nothing: add it to INJECT_TO or NOT_INJECTED")
        if lang not in LICENSE_TEXT and entry["resource"].split("/")[-1] not in in_notice \
                and not assets[lang]["source"].startswith(TEXTMATE_PERMISSIVE):
            sys.exit(f"{lang}: tm-grammars-NOTICE.txt has no licence text for it; vendor one and list it in LICENSE_TEXT")

    if out.exists():
        shutil.rmtree(out)
    (out / "grammars").mkdir(parents=True)
    (out / "themes").mkdir()
    (out / "licenses").mkdir()
    for resource, data in grammars.items():
        (out / resource).write_bytes(data)
    aliases = {alias: target for alias, target in manifest["aliases"].items() if target in chosen}
    (out / "language-manifest.json").write_text(json.dumps(
        {"schemaVersion": 1, "package": manifest["package"], "aliases": aliases, "languages": entries},
        indent=1, sort_keys=True) + "\n")
    # Next Term's own theme; no third-party theme ships.
    (out / "theme-manifest.json").write_text(json.dumps({"schemaVersion": 1, "themes": [
        {"id": "next-dark", "displayName": "Next Dark", "type": "dark", "resource": "themes/next-dark.json"}]}, indent=1) + "\n")
    theme = pathlib.Path(__file__).resolve().parent / "next-dark-theme.json"
    shutil.copy(theme, out / "themes/next-dark.json")
    for name in ("tm-grammars-LICENSE.txt", "tm-grammars-NOTICE.txt"):
        shutil.copy(src / "licenses" / name, out / "licenses" / name)
    for name in {LICENSE_TEXT[lang] for lang in chosen if lang in LICENSE_TEXT}:
        shutil.copy(pathlib.Path(__file__).resolve().parent / "grammars/licenses" / name, out / "licenses" / name)

    lines = ["# Grammars shipped with Next Term", "",
             "From shikijs/textmate-grammars-themes (tm-grammars, MIT) via shiki-swift. Each grammar keeps its",
             "upstream licence:", "", "| Grammar | Licence | Source |", "|---|---|---|"]
    for lang in sorted(chosen):
        text = f"; text in licenses/{LICENSE_TEXT[lang]}" if lang in LICENSE_TEXT else ""
        lines.append(f"| {lang} | {chosen[lang]}{text} | {assets[lang]['source']} |")
    (out / "GRAMMARS.md").write_text("\n".join(lines) + "\n")
    print(f"{len(chosen)} grammars -> {out}")
    for lang, why in sorted(refused.items()):
        print(f"  left out {lang}: {why}")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else ".build/checkouts/shiki-swift")
