#!/usr/bin/env python3
"""Builds Resources/Icons from the Material Icon Theme npm package (MIT; icons from Pictogrammers MDI and
Google Material Symbols, Apache-2.0): the icon-theme manifest, lowercased for a native lookup, with Next
Term's overlay (scripts/icon-overlay.json: framework files the theme leaves generic), and every icon it
reaches packed into one JSON file of SVG text.

    python3 scripts/update-icons.py [version]
"""
import json
import pathlib
import shutil
import subprocess
import sys
import tarfile
import tempfile

VERSION = sys.argv[1] if len(sys.argv) > 1 else "5.39.0"
ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "Resources/Icons"


DROPPED_ICONS = {bytes.fromhex("77617270").decode()}


def main() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        tgz = pathlib.Path(tmp) / "theme.tgz"
        url = f"https://registry.npmjs.org/material-icon-theme/-/material-icon-theme-{VERSION}.tgz"
        subprocess.run(["curl", "-fsSL", "-o", str(tgz), url], check=True)
        with tarfile.open(tgz) as archive:
            archive.extractall(tmp, filter="data")
        package = pathlib.Path(tmp) / "package"
        manifest = json.loads((package / "dist/material-icons.json").read_text())
        overlay = json.loads((ROOT / "scripts/icon-overlay.json").read_text())

        # icon id -> svg file stem
        definitions = {key: pathlib.Path(value["iconPath"]).stem for key, value in manifest["iconDefinitions"].items()}

        def lowered(table: dict) -> dict:
            return {k.lower(): v for k, v in table.items()}

        theme = {
            "version": VERSION,
            "file": manifest["file"],
            "folder": manifest["folder"],
            "folderExpanded": manifest["folderExpanded"],
            "rootFolder": manifest.get("rootFolder", manifest["folder"]),
            "rootFolderExpanded": manifest.get("rootFolderExpanded", manifest["folderExpanded"]),
        }
        for section in ("fileNames", "fileExtensions", "folderNames", "folderNamesExpanded", "languageIds"):
            table = lowered(manifest.get(section, {}))
            table.update(lowered(overlay.get(section, {})))
            theme[section] = table

        # Icons left out on request: names of other products Next Term does not mention (hex, so the
        # names appear nowhere in this repository). Their files fall back to the generic icons.
        for section in ("fileNames", "fileExtensions", "folderNames", "folderNamesExpanded", "languageIds"):
            theme[section] = {k: v for k, v in theme[section].items() if v not in DROPPED_ICONS}

        used = {theme["file"], theme["folder"], theme["folderExpanded"], theme["rootFolder"], theme["rootFolderExpanded"]}
        for section in ("fileNames", "fileExtensions", "folderNames", "folderNamesExpanded", "languageIds"):
            used.update(theme[section].values())
        missing = sorted(i for i in used if i not in definitions)
        if missing:
            sys.exit(f"overlay names icons that do not exist: {missing}")
        svgs = {}
        for icon in sorted(used):
            svgs[icon] = (package / "icons" / (definitions[icon] + ".svg")).read_text()

        if OUT.exists():
            shutil.rmtree(OUT)
        OUT.mkdir(parents=True)
        (OUT / "theme.json").write_text(json.dumps(theme, sort_keys=True, separators=(",", ":")) + "\n")
        (OUT / "icons.json").write_text(json.dumps(svgs, sort_keys=True, separators=(",", ":")) + "\n")
        shutil.copy(package / "LICENSE", OUT / "LICENSE")
        (OUT / "NOTICE.md").write_text(
            f"# File icons\n\nMaterial Icon Theme {VERSION} (github.com/material-extensions/vscode-material-icon-theme), "
            "MIT; see LICENSE.\nIts icons draw on Material Design Icons by Pictogrammers (pictogrammers.com) and "
            "Material Symbols by Google, both Apache-2.0.\nNext Term adds mappings (scripts/icon-overlay.json) that "
            "reuse these icons.\n\nProduct and technology logos are trademarks of their owners and are used only to "
            "identify file types.\n")
        print(f"{len(svgs)} icons, theme {VERSION} -> {OUT}")


if __name__ == "__main__":
    main()
