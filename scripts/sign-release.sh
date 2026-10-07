#!/bin/bash
# Signs a published release's checksums with the Next Term release key, after CI has published it:
#
#     scripts/sign-release.sh v0.7.0
#
# The installer (site/public/install.sh) installs only what this key signed, so a release changed by
# anyone who can upload to GitHub (a leaked token, a compromised CI step) is refused. The private key
# never goes to CI or the repository: it lives on the maintainer's Mac, in
# ~/.config/next-term/release-signing-key (override with NEXTTERM_RELEASE_KEY). Its public half is
# written into install.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

tag="${1:?usage: scripts/sign-release.sh vX.Y.Z}"
version="${tag#v}"
key="${NEXTTERM_RELEASE_KEY:-$HOME/.config/next-term/release-signing-key}"
[ -f "$key" ] || { echo "No release key at $key" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

assets="$(gh release view "$tag" --json assets --jq '.[].[].name')"
signed=()
for name in "NextTerm-$version.dmg.sha256" "NextTerm.dmg.sha256"; do
    # The version-less copy belongs to the newest release only; older ones may not have it.
    grep -qxF "$name" <<<"$assets" || continue
    gh release download "$tag" --pattern "$name" --dir "$work" --clobber
    # Sign only a checksum that matches the disk image it names.
    dmg="$(awk 'NR == 1 { print $2 }' "$work/$name")"
    gh release download "$tag" --pattern "$dmg" --dir "$work" --clobber
    expected="$(awk 'NR == 1 { print $1 }' "$work/$name")"
    actual="$(shasum -a 256 "$work/$dmg" | awk '{ print $1 }')"
    [ "$expected" = "$actual" ] || { echo "$name does not match $dmg; not signing." >&2; exit 1; }
    ssh-keygen -q -Y sign -f "$key" -n next-term-release "$work/$name"
    signed+=("$work/$name.sig")
done
[ "${#signed[@]}" -gt 0 ] || { echo "$tag has no checksums to sign." >&2; exit 1; }
gh release upload "$tag" "${signed[@]}" --clobber
echo "Signed: $(printf '%s ' "${signed[@]##*/}")"
