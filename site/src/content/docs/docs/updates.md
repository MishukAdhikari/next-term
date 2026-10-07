---
title: Updates
description: "How Next Term updates itself from GitHub Releases: a daily check, a one-click install verified with the release key, and how to turn automatic checks off."
---

You install Next Term once. After that it keeps itself current from GitHub Releases, and every update is checked before it replaces anything.

## How it works

1. **A daily check.** About 20 seconds after launch, and then once a day, Next Term asks GitHub for the latest release. Drafts and pre-releases are ignored.
2. **You decide.** When there is a newer version, the update window opens over your project with what’s new: the notes of every version since yours, newest first. It offers **Install and Relaunch**, **Remind Me Later** and **Skip This Version**. Opened by the daily check, it doesn’t take the keyboard: what you’re typing to an agent stays in the terminal until you click the window.
3. **Download and verify.** **Install and Relaunch** checks the release as the [one-line installer](/docs/security-and-privacy/#the-installer) does. The release’s SHA-256 checksum must be signed with the Next Term release key and must name that version’s disk image (`NextTerm-0.8.0.dmg`). Next Term then downloads the disk image with a progress window and checks that it matches the checksum. It opens the image read-only, copies the new app next to the current one, and checks that it really is Next Term, at the expected version, with an intact code signature.
4. **Swap on quit.** “Next Term 0.8.0 is ready” offers to relaunch now (running commands and agents stop) or later. The new version replaces the old one when Next Term quits; if anything goes wrong during the swap, the old app is put back.

If any step fails, nothing is replaced, and Next Term says what went wrong. A release whose checksum isn’t signed with the release key, or whose download doesn’t match it, is refused. For any other failure, such as a lost connection, Next Term offers the release’s page so you can download it there instead.

Each release is signed a few minutes after it is published. If you install one before that, Next Term says it isn’t signed yet, checks again every 10 minutes for the next two hours, and downloads it once it is signed. A release that is more than a day old and still has no signature is refused.

## The Update button

While a new version waits, a blue **Update** button sits at the top right of each project window. Click it to open the update window again. Once the update is downloaded, it reads **Relaunch to Update**.

- **Remind Me Later** (or the window’s close button) keeps the button. The daily check opens the window again after a day.
- **Skip This Version** hides the window and the button for that version. The next version is offered as usual, and **Check for Updates…** still shows a skipped one.

## Check now

**Next Term › Check for Updates…** checks at once and tells you either way: a new version, “Next Term is up to date”, or that GitHub did not answer.

## Turn automatic checks off

Untick **Next Term › Check for Updates Automatically**. Next Term then makes no update check on its own; **Check for Updates…** still works when you ask. (Its only other requests of its own are background fetches from your projects’ git remotes, wherever they are hosted; **Settings › Editor › Git** turns those off. See [Background fetch](/docs/projects-and-git/#background-fetch).)

## What the check sends

Only a request for the latest release of `MishukAdhikari/next-term` on GitHub, with the app’s version in the `User-Agent` header (“NextTerm/0.8.0”). When there is a newer version, a second request reads the recent releases, for the notes of each version since yours. There is no other identifying data, no account and no analytics. If GitHub’s API is rate-limited, Next Term reads the newest version from the releases page instead. Downloads are accepted only over HTTPS from GitHub.

## Updating from an earlier version

Every version since 0.1.0 has the updater: choose **Next Term › Check for Updates…** and install the newest from there. Release notes for every version are on the [releases page](https://github.com/MishukAdhikari/next-term/releases).

Development builds (`swift run`) have no version and never check for updates.
