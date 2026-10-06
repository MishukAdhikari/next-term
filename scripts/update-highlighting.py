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
}
# Grammars a language always loads with it, on top of the ones shiki-swift lists. Next Term tokenizes a
# line at a time, and shiki-swift guesses lazy embeds from that one line, so front matter (which needs
# both `---` lines in one string) would only colour if YAML happened to be loaded already.
EAGER = {"markdown": ["yaml"], "mdx": ["yaml"]}


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

    if out.exists():
        shutil.rmtree(out)
    (out / "grammars").mkdir(parents=True)
    (out / "themes").mkdir()
    (out / "licenses").mkdir()
    entries = []
    for lang in sorted(chosen):
        entry = dict(languages[lang])
        # Only point at grammars that ship; lazy ones load on demand (Markdown code fences).
        eager = entry["embeddedLangs"] + [x for x in EAGER.get(lang, []) if x not in entry["embeddedLangs"]]
        entry["embeddedLangs"] = [x for x in eager if x in chosen]
        entry["embeddedLangsLazy"] = [x for x in entry["embeddedLangsLazy"] if x in chosen and x not in eager]
        entry["embeddedIn"] = [x for x in entry.get("embeddedIn", []) if x in chosen]
        entry["injectTo"] = [x for x in entry.get("injectTo", []) if x in chosen]
        entries.append(entry)
        shutil.copy(src / entry["resource"], out / entry["resource"])
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

    lines = ["# Grammars shipped with Next Term", "",
             "From shikijs/textmate-grammars-themes (tm-grammars, MIT) via shiki-swift. Each grammar keeps its",
             "upstream licence:", "", "| Grammar | Licence | Source |", "|---|---|---|"]
    for lang in sorted(chosen):
        lines.append(f"| {lang} | {chosen[lang]} | {assets[lang]['source']} |")
    (out / "GRAMMARS.md").write_text("\n".join(lines) + "\n")
    print(f"{len(chosen)} grammars -> {out}")
    for lang, why in sorted(refused.items()):
        print(f"  left out {lang}: {why}")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else ".build/checkouts/shiki-swift")
