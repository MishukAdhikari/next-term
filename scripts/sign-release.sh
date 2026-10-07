#!/bin/bash
# Signs a published release's checksum with the Next Term release key, after CI has published it:
#
#     scripts/sign-release.sh v0.8.0
#
# The installer (site/src/install.sh) installs only a disk image whose checksum this key signed, and
# the signed text names the versioned file (NextTerm-0.8.0.dmg), so a signature can't be moved to
# another release. The private key never goes to CI or the repository: it lives on the maintainer's
# Mac, in ~/.config/next-term/release-signing-key (override with NEXTTERM_RELEASE_KEY).
#
# It signs only what the release workflow uploaded (github-actions[bot]), never an asset a person's
# token put there, and only a checksum that matches the disk image it names.
set -euo pipefail
cd "$(dirname "$0")/.."

tag="${1:?usage: scripts/sign-release.sh vX.Y.Z}"
version="${tag#v}"
[[ $version =~ ^[0-9]+(\.[0-9]+){1,3}(-[A-Za-z0-9.]+)?$ ]] || { echo "“${tag}” isn’t a release tag." >&2; exit 1; }
key="${NEXTTERM_RELEASE_KEY:-$HOME/.config/next-term/release-signing-key}"
[ -f "$key" ] || { echo "No release key at $key" >&2; exit 1; }
repo="MishukAdhikari/next-term"
dmg="NextTerm-${version}.dmg"
sum="${dmg}.sha256"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

uploaders="$(gh api "repos/${repo}/releases/tags/${tag}" --jq '.assets[] | .name + " " + .uploader.login')"
for name in "$dmg" "$sum"; do
    grep -qxF "${name} github-actions[bot]" <<<"$uploaders" \
        || { echo "${name} was not uploaded by the release workflow; not signing." >&2; exit 1; }
done

gh release download "$tag" --pattern "$dmg" --pattern "$sum" --dir "$work" --clobber
actual="$(shasum -a 256 "$work/$dmg" | awk '{ print $1 }')"
[ "$(cat "$work/$sum")" = "${actual}  ${dmg}" ] || { echo "${sum} does not match ${dmg}; not signing." >&2; exit 1; }
ssh-keygen -q -Y sign -f "$key" -n next-term-release "$work/$sum"
gh release upload "$tag" "$work/$sum.sig" --clobber
echo "Signed ${sum}: ${actual}"
