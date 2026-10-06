# Screenshots

Real screenshots of Next Term 0.2.0, taken by the app’s self-test (`scripts/selftest.sh`) on 6 October 2026, cropped with `sips` and compressed to WebP with `cwebp -q 80`. Astro converts them again at build time into the sizes each page needs.

Because they come from the self-test, they show **test data**: a throwaway project called `proj` in a temporary folder, files such as `long.ts` and `diff.txt`, and tab titles such as `tmp` and `PATH=…`. They are accurate about the app, but they should be replaced with screenshots of a real project before a wider launch.

| File | Used on | Source and crop | Retake? |
|---|---|---|---|
| `proposal-window.webp` | Home (hero), Agents | `st-proposal.png`, top 975 px (stops above a long temporary `PATH=` command line) | **Yes.** The sidebar shows the temporary path `/private/var/folders/…`; the code is a three-line test file. Retake with a real project and a realistic Claude edit. |
| `claude-selection.webp` | Home, Agents | `st-real-claude.png`, right of the sidebar (the sidebar listed private folders in `~/Code`) | **Yes.** The account’s model and plan line and the folder in Claude Code’s banner are painted over with the terminal background; retake in a demo project. |
| `diff.webp` | Home, Diffs | `st-diff.png`, diff area only | **Yes.** The file is `line 1` … `line 14` test text. Retake with a real change in real code. |
| `editor.webp` | Editor | `st-editor.png`, editor area only | **Yes.** A generated `long.ts` with repeated lines. Retake with code that shows the highlighting. |
| `find-in-files.webp` | Find and Replace in Files | `st-find.png`, whole window | Optional. Clean, but the project is the test `proj`. |
| `tab-status.webp` | Home | `st.png`, the tab bar | **Yes.** Tab titles are `tmp`, `nex…631` and `PATH=…`. Retake with agent tabs named after real work (`claude — api`, `codex — web`). |
| `tab-marks.webp` | Agent status | `st.png`, the four tabs with marks | **Yes**, with the tab bar above. |
| `sidebar-git.webp` | Projects and git | `st-sidebar.png`, sidebar only | **Yes.** The root row shows the temporary path. |
| `layout-terminal-right.webp` | Layouts | `st-terminal-right.png`, whole window | **Yes.** Temporary path in the sidebar and the generated `long.ts`. |

`public/og.jpg`, the social card, is made from `proposal-window` with `scripts/make-og-image.swift`; regenerate it after retaking that screenshot (instructions at the top of the script).

## Retaking

1. Open a real, public project (for example a small Laravel or Next.js app) with a few uncommitted changes, so the sidebar shows colours and `+12 −3` counts.
2. Use a 1100 × 720 point window on a Retina display (2200 × 1440 pixels), as the self-test does, in the default layout.
3. Name tabs after the work (<kbd>⌥⌘R</kbd>) and run real agents.
4. Crop away anything personal (home folder names, account banners).
5. Compress: `cwebp -q 80 -m 6 -resize 1600 0 in.png -o name.webp` (1400 for half-width images), keep each file under about 300 KB, and replace the file here under the same name. Update the alt text on the pages that use it.
