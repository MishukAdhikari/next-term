#!/bin/bash
# Installs Next Term (https://next-term.mishuk.me) from its GitHub release:
#
#     curl -fsSL https://next-term.mishuk.me/install.sh | bash
#
# It downloads the disk image and its SHA-256, checks that the checksum is signed with the Next Term
# release key (below; the key never leaves the maintainer's Mac, so a release changed on GitHub is
# refused) and that the download matches it, checks the app's bundle and signature are intact, and
# copies it to /Applications (or ~/Applications when /Applications isn't writable). It never uses sudo,
# never replaces a Next Term that is running, and changes nothing else.
#
#     NEXTTERM_VERSION=0.7.0    a particular version instead of the latest
#     NEXTTERM_DIR=~/Apps       another folder
#
# Source: https://github.com/MishukAdhikari/next-term/blob/main/site/src/install.sh

# What the exit trap cleans up. Not local to main: the trap also runs after main has returned.
nt_work=""
nt_mount=""
nt_lock=""
nt_created_dir=""
nt_done=""
nt_staged=""
nt_previous=""
nt_destination=""

nt_cleanup() {
    if [ -n "${nt_mount:-}" ] && [ -d "${nt_mount}" ]; then hdiutil detach "${nt_mount}" -quiet -force >/dev/null 2>&1 || true; fi
    if [ -n "${nt_work:-}" ]; then rm -rf "${nt_work}"; fi
    # Stopped halfway through (Ctrl-C): the copy goes, and the old app comes back if it was moved aside.
    if [ -n "${nt_staged:-}" ]; then rm -rf "${nt_staged}"; fi
    if [ -n "${nt_previous:-}" ]; then
        if [ -n "${nt_destination:-}" ] && ! [ -e "${nt_destination}" ] && [ -d "${nt_previous}/Next Term.app" ]; then
            mv "${nt_previous}/Next Term.app" "${nt_destination}" 2>/dev/null || true
        fi
        if ! [ -d "${nt_previous}/Next Term.app" ]; then rm -rf "${nt_previous}"; fi
    fi
    if [ -n "${nt_lock:-}" ]; then rmdir "${nt_lock}" 2>/dev/null || true; fi
    # Folders this run made for nothing go again, innermost first, up to the first one it made.
    if [ -z "${nt_done:-}" ] && [ -n "${nt_created_dir:-}" ]; then
        local dir="${nt_destination%/*}"
        # Only inside what this run made: a folder that was there before is never touched.
        case "${dir}/" in "${nt_created_dir}/"*) ;; *) dir="${nt_created_dir}" ;; esac
        while [ -n "${dir}" ] && rmdir "${dir}" 2>/dev/null; do
            [ "${dir}" = "${nt_created_dir}" ] && break
            dir="${dir%/*}"
        done
    fi
}

# Everything runs from main, called on the last line: a download cut short runs nothing.
main() {
    set -euo pipefail
    trap nt_cleanup EXIT

    local repo="MishukAdhikari/next-term"
    local bundle_id="me.mishuk.nextterm"
    local app_name="Next Term.app"
    # The Next Term release key's public half (scripts/sign-release.sh signs each release's checksums).
    local signer="release@next-term.mishuk.me"
    local release_key="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIInsbvx/ft3ytGC9zAlM4hSOqqVKy0X94Ah77mDzAneG"

    say() { printf '%s\n' "$*"; }
    fail() { printf 'Next Term was not installed: %s\n' "$*" >&2; exit 1; }

    [ "$(uname -s)" = "Darwin" ] || fail "it runs on macOS only."
    local major
    major="$(sw_vers -productVersion | cut -d. -f1)"
    [ "${major:-0}" -ge 13 ] 2>/dev/null || fail "it needs macOS 13 or later (this Mac has $(sw_vers -productVersion))."
    local tool
    for tool in curl shasum hdiutil ditto codesign ssh-keygen /usr/libexec/PlistBuddy; do
        command -v "${tool}" >/dev/null 2>&1 || fail "${tool} is missing."
    done

    # The oldest release "latest" may resolve to: GitHub decides which release is latest, the release
    # key does not, so a GitHub account could otherwise point "latest" at an old signed release.
    local min_version="@@MIN_VERSION@@" # the site fills in its current version
    local version="${NEXTTERM_VERSION:-}"
    version="${version#v}"
    local pinned="${version}"
    if [ -z "${version}" ]; then
        local latest_url
        latest_url="$(curl -fsS --proto '=https' --tlsv1.2 --connect-timeout 20 -o /dev/null -w '%{redirect_url}' "https://github.com/${repo}/releases/latest")" \
            || fail "the latest release could not be found."
        version="${latest_url##*/releases/tag/v}"
    fi
    local pattern='^[0-9]+(\.[0-9]+){1,3}(-[A-Za-z0-9.]+)?$'
    [[ ${version} =~ ${pattern} ]] || fail "“${version}” isn’t a version number."
    nt_older() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n | head -1)" = "$1" ]; }
    if [ -z "${pinned}" ] && nt_older "${version}" "${min_version}"; then
        fail "GitHub says the latest release is ${version}, older than ${min_version}; refusing a rollback."
    fi
    local base="https://github.com/${repo}/releases/download/v${version}"
    local dmg_name="NextTerm-${version}.dmg"

    local target="${NEXTTERM_DIR:-/Applications}"
    if [ -z "${NEXTTERM_DIR:-}" ] && ! [ -w /Applications ]; then target="${HOME}/Applications"; fi
    if ! [ -d "${target}" ]; then
        # The outermost folder this run creates, so a failure can take them all away again.
        local top="${target%/}"
        while [ -n "${top%/*}" ] && ! [ -d "${top%/*}" ]; do top="${top%/*}"; done
        mkdir -p "${target}" 2>/dev/null || fail "can’t create ${target}."
        nt_created_dir="$(cd "${top}" && pwd -P)" || nt_created_dir=""
    fi
    target="$(cd "${target}" && pwd -P)" || fail "can’t open ${target}."
    [ -w "${target}" ] || fail "can’t write to ${target}. Set NEXTTERM_DIR to a folder you own."
    local destination="${target}/${app_name}"
    nt_destination="${destination}"

    # A running Next Term holds your terminals and agents: never replace it from under them. Every
    # process's executable is compared by file identity, so any spelling of the folder is caught.
    local processes executable
    processes="$(ps -axo comm=)"
    while IFS= read -r executable; do
        case "${executable}" in
            *"/${app_name}/Contents/MacOS/NextTerm")
                if [ "${executable}" -ef "${destination}/Contents/MacOS/NextTerm" ]; then
                    fail "Next Term is running from ${target}. Use Next Term › Check for Updates…, or quit it and run this again."
                fi ;;
        esac
    done <<PROCESSES
${processes}
PROCESSES
    # ps shows argv[0] as typed (./NextTerm, a symlink, exec -a); lsof finds the executable itself.
    if [ -e "${destination}/Contents/MacOS/NextTerm" ] && lsof -t -- "${destination}/Contents/MacOS/NextTerm" >/dev/null 2>&1; then
        fail "Next Term is running from ${target}. Use Next Term › Check for Updates…, or quit it and run this again."
    fi

    # One install into a folder at a time. nt_lock is set only once the lock is ours.
    local lock="${target}/.Next Term.install.lock"
    mkdir "${lock}" 2>/dev/null || fail "another install into ${target} is running (if not, remove “${lock}”)."
    nt_lock="${lock}"

    nt_work="$(mktemp -d "${TMPDIR:-/tmp}/next-term-install.XXXXXX")"
    local work="${nt_work}"

    say "Downloading Next Term${version:+ ${version}}…"
    local get=(curl -fL --proto '=https' --tlsv1.2 --retry 2 --connect-timeout 20 --silent --show-error)
    "${get[@]}" -o "${work}/${dmg_name}" "${base}/${dmg_name}" || fail "the download failed."
    "${get[@]}" -o "${work}/${dmg_name}.sha256" "${base}/${dmg_name}.sha256" || fail "its checksum could not be downloaded."
    "${get[@]}" -o "${work}/${dmg_name}.sha256.sig" "${base}/${dmg_name}.sha256.sig" \
        || fail "its checksum’s signature could not be downloaded (a release that was just published is signed a few minutes later)."

    printf '%s %s\n' "${signer}" "${release_key}" > "${work}/allowed_signers"
    ssh-keygen -Y verify -f "${work}/allowed_signers" -I "${signer}" -n next-term-release -s "${work}/${dmg_name}.sha256.sig" \
        < "${work}/${dmg_name}.sha256" >/dev/null 2>&1 || fail "the checksum is not signed with the Next Term release key."
    local expected actual
    expected="$(awk 'NR == 1 { print tolower($1) }' "${work}/${dmg_name}.sha256")"
    actual="$(shasum -a 256 "${work}/${dmg_name}" | awk '{ print tolower($1) }')"
    local hex='^[0-9a-f]{64}$'
    [[ ${expected} =~ ${hex} ]] || fail "the published checksum is not a SHA-256."
    [ "${expected}" = "${actual}" ] || fail "the download does not match its signed SHA-256."
    # The signed text names the file, and the file name names the version: a signature from another release is refused.
    [ "$(cat "${work}/${dmg_name}.sha256")" = "${actual}  ${dmg_name}" ] || fail "the signed checksum is not for ${dmg_name}."
    say "Checked: signed by the Next Term release key, SHA-256 ${actual}"

    nt_mount="${work}/mount"
    mkdir "${nt_mount}"
    hdiutil attach "${work}/${dmg_name}" -nobrowse -readonly -noautoopen -quiet -mountpoint "${nt_mount}" || fail "the disk image could not be opened."
    local source="${nt_mount}/${app_name}"
    [ -d "${source}" ] || fail "the disk image has no ${app_name}."
    local plist="${source}/Contents/Info.plist"
    local found_id found_version
    found_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${plist}" 2>/dev/null || true)"
    found_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${plist}" 2>/dev/null || true)"
    [ "${found_id}" = "${bundle_id}" ] || fail "the disk image holds something other than Next Term (${found_id})."
    [ "${found_version}" = "${version}" ] || fail "the disk image holds ${found_version}, not ${version}."
    # Never replace a newer Next Term with an older one unless that version was asked for.
    if [ -z "${pinned}" ] && [ -f "${destination}/Contents/Info.plist" ]; then
        local installed
        installed="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${destination}/Contents/Info.plist" 2>/dev/null || true)"
        if [ -n "${installed}" ] && nt_older "${version}" "${installed}"; then
            fail "Next Term ${installed} is installed and GitHub's latest is the older ${version}; set NEXTTERM_VERSION=${version} to install it anyway."
        fi
    fi
    codesign --verify --deep --strict "${source}" 2>/dev/null || fail "the app’s signature is broken."

    # Copy beside the old one, check the copy, then swap: a failure leaves the old app as it was.
    # Both folders are known to the exit trap from the moment they exist: Ctrl-C at any point leaves
    # either the old app or the new one in place, and nothing else.
    nt_staged="$(mktemp -d "${target}/.Next Term.installing.XXXXXX")" || fail "can’t write to ${target}."
    ditto "${source}" "${nt_staged}/${app_name}" || fail "the app could not be copied to ${target}."
    codesign --verify --deep --strict "${nt_staged}/${app_name}" 2>/dev/null || fail "the copied app does not verify."
    trap '' INT TERM HUP # the two renames are not split by a keystroke
    if [ -e "${destination}" ]; then
        nt_previous="$(mktemp -d "${target}/.Next Term.previous.XXXXXX")" || fail "can’t write to ${target}."
        mv "${destination}" "${nt_previous}/${app_name}" || fail "the installed Next Term could not be moved aside."
        mv "${nt_staged}/${app_name}" "${destination}" || fail "the new app could not be put in place; the old one is back."
        rm -rf "${nt_previous}" 2>/dev/null || say "The old copy could not be removed: ${nt_previous}"
        nt_previous=""
    else
        mv "${nt_staged}/${app_name}" "${destination}" || fail "the app could not be put in place."
    fi
    trap - INT TERM HUP
    nt_done=1

    say "Installed Next Term ${found_version} in ${destination}"
    say "Open it from ${target}, or run: open -a \"${destination}\""
}

main "$@"
