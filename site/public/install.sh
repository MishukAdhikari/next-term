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
# Source: https://github.com/MishukAdhikari/next-term/blob/main/site/public/install.sh

# What the exit trap cleans up. Not local to main: the trap also runs after main has returned.
nt_work=""
nt_mount=""
nt_lock=""
nt_created_dir=""
nt_done=""

nt_cleanup() {
    if [ -n "${nt_mount:-}" ] && [ -d "${nt_mount}" ]; then hdiutil detach "${nt_mount}" -quiet -force >/dev/null 2>&1 || true; fi
    if [ -n "${nt_work:-}" ]; then rm -rf "${nt_work}"; fi
    if [ -n "${nt_lock:-}" ]; then rmdir "${nt_lock}" 2>/dev/null || true; fi
    # A folder this run made for nothing goes again.
    if [ -z "${nt_done:-}" ] && [ -n "${nt_created_dir:-}" ]; then rmdir "${nt_created_dir}" 2>/dev/null || true; fi
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

    local version="${NEXTTERM_VERSION:-}"
    version="${version#v}"
    local base dmg_name
    if [ -n "${version}" ]; then
        local pattern='^[0-9]+(\.[0-9]+){1,3}(-[A-Za-z0-9.]+)?$'
        [[ ${version} =~ ${pattern} ]] || fail "“${version}” isn’t a version number."
        base="https://github.com/${repo}/releases/download/v${version}"
        dmg_name="NextTerm-${version}.dmg"
    else
        base="https://github.com/${repo}/releases/latest/download"
        dmg_name="NextTerm.dmg"
    fi

    local target="${NEXTTERM_DIR:-/Applications}"
    if [ -z "${NEXTTERM_DIR:-}" ] && ! [ -w /Applications ]; then target="${HOME}/Applications"; fi
    if ! [ -d "${target}" ]; then
        mkdir -p "${target}" 2>/dev/null || fail "can’t create ${target}."
        nt_created_dir="${target}"
    fi
    target="$(cd "${target}" && pwd -P)" || fail "can’t open ${target}."
    [ -w "${target}" ] || fail "can’t write to ${target}. Set NEXTTERM_DIR to a folder you own."
    local destination="${target}/${app_name}"

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

    # One install into a folder at a time.
    nt_lock="${target}/.Next Term.install.lock"
    mkdir "${nt_lock}" 2>/dev/null || { nt_lock=""; fail "another install into ${target} is running (if not, remove “${target}/.Next Term.install.lock”)."; }

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
    if [ -n "${version}" ] && [ "${found_version}" != "${version}" ]; then fail "the disk image holds ${found_version}, not ${version}."; fi
    codesign --verify --deep --strict "${source}" 2>/dev/null || fail "the app’s signature is broken."

    # Copy beside the old one, check the copy, then swap: a failure leaves the old app as it was.
    local staged previous
    staged="$(mktemp -d "${target}/.Next Term.installing.XXXXXX")" || fail "can’t write to ${target}."
    ditto "${source}" "${staged}/${app_name}" || { rm -rf "${staged}"; fail "the app could not be copied to ${target}."; }
    codesign --verify --deep --strict "${staged}/${app_name}" 2>/dev/null || { rm -rf "${staged}"; fail "the copied app does not verify."; }
    if [ -e "${destination}" ]; then
        previous="$(mktemp -d "${target}/.Next Term.previous.XXXXXX")" || { rm -rf "${staged}"; fail "can’t write to ${target}."; }
        mv "${destination}" "${previous}/${app_name}" || { rm -rf "${staged}" "${previous}"; fail "the installed Next Term could not be moved aside."; }
        if mv "${staged}/${app_name}" "${destination}"; then
            rm -rf "${previous}" 2>/dev/null || say "The old copy could not be removed: ${previous}"
        else
            mv "${previous}/${app_name}" "${destination}" || fail "the new app could not be put in place; the old one is in ${previous}."
            rm -rf "${staged}" "${previous}"
            fail "the new app could not be put in place; the old one is back."
        fi
    else
        mv "${staged}/${app_name}" "${destination}" || { rm -rf "${staged}"; fail "the app could not be put in place."; }
    fi
    rm -rf "${staged}"
    nt_done=1

    say "Installed Next Term ${found_version} in ${destination}"
    say "Open it from ${target}, or run: open -a \"${destination}\""
}

main "$@"
