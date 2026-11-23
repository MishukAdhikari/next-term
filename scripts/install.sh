#!/bin/bash
# Installs Next Term (https://nxtrm.mishuk.me) from its release:
#
#     curl -fsSL https://nxtrm.mishuk.me/install.sh | bash
#
# It installs the version the site names, which moves only once a release is signed and checked, so a
# release GitHub has just published is not offered before its signature is up. It downloads the disk
# image and its SHA-256 from GitHub, or from the site's own copy when GitHub can't be reached or stalls,
# checks that the checksum is signed with the Next Term release key (below; the key never leaves the
# maintainer's Mac, so a release changed on GitHub or on the site is refused) and that the download
# matches it, checks the app's bundle and signature are intact, and
# copies it to /Applications (or ~/Applications when /Applications isn't writable). It never uses sudo
# and never replaces a Next Term that is running. Besides the app it adds only the nxtrm command, as a
# link in the first folder on your PATH meant for commands that you can write (~/.local/bin, ~/bin,
# /opt/homebrew/bin, /usr/local/bin); it never changes PATH or touches anyone else's nxtrm.
#
#     NEXTTERM_VERSION=0.7.0    a particular version instead of the latest (the site keeps copies of the
#                               last few; older ones come from GitHub only)
#     NEXTTERM_DIR=~/Apps       another folder
#
# Source: https://github.com/MishukAdhikari/next-term/blob/main/scripts/install.sh

# What the exit trap cleans up. Not local to main: the trap also runs after main has returned.
nt_work=""
nt_mount=""
nt_lock=""
nt_takeover=""
nt_created_dir=""
nt_done=""
nt_staged=""
nt_previous=""
nt_destination=""

nt_cleanup() {
    # Runs to the end whatever happens: a second Ctrl-C or one failed step must not strand the rest.
    trap '' INT TERM HUP
    set +e
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
    if [ -n "${nt_lock:-}" ]; then rm -f "${nt_lock}/pid"; rmdir "${nt_lock}" 2>/dev/null || true; fi
    if [ -n "${nt_takeover:-}" ]; then rmdir "${nt_takeover}" 2>/dev/null || true; fi
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
    # The app's updater checks with the same key, in Sources/NextTermCore/ReleaseSignature.swift; a test
    # keeps the two identical.
    local signer="release@next-term.mishuk.me" # the key's name, not the site's address: never changes
    local release_key="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIInsbvx/ft3ytGC9zAlM4hSOqqVKy0X94Ah77mDzAneG"

    say() { printf '%s\n' "$*"; }
    fail() { printf 'Next Term was not installed: %s\n' "$*" >&2; exit 1; }

    [ "$(uname -s)" = "Darwin" ] || fail "it runs on macOS only."
    local major
    major="$(sw_vers -productVersion | cut -d. -f1)"
    [ "${major:-0}" -ge 13 ] 2>/dev/null || fail "it needs macOS 13 or later (this Mac has $(sw_vers -productVersion))."
    local tool
    for tool in curl shasum hdiutil ditto codesign ssh-keygen /usr/libexec/PlistBuddy /usr/sbin/lsof; do
        command -v "${tool}" >/dev/null 2>&1 || fail "${tool} is missing."
    done

    # The version the site serves, and so the one installed. The site sets it only after the release is
    # signed and checked: GitHub calls a release latest minutes before its signature is up, doesn't answer
    # when it is down, and decides which release is latest without the release key, so a GitHub account
    # could point "latest" at an old signed release. Only this script run from the repository, with the
    # slot unfilled, asks GitHub.
    local min_version="@@MIN_VERSION@@" # the site fills in its current version
    local site_version=""
    case "${min_version}" in @*) ;; *) site_version="${min_version}" ;; esac
    local version="${NEXTTERM_VERSION:-}"
    version="${version#v}"
    local pinned="${version}"
    if [ -z "${version}" ] && [ -n "${site_version}" ]; then
        version="${site_version}"
    elif [ -z "${version}" ]; then
        local latest_url
        latest_url="$(curl -fsS --proto '=https' --tlsv1.2 --connect-timeout 20 --max-time 60 --retry 2 --retry-connrefused --retry-max-time 20 -o /dev/null -w '%{redirect_url}' "https://github.com/${repo}/releases/latest")" \
            || fail "the latest release could not be found."
        version="${latest_url##*/releases/tag/v}"
    fi
    local pattern='^[0-9]+(\.[0-9]+){1,3}(-[A-Za-z0-9.]+)?$'
    [[ ${version} =~ ${pattern} ]] || fail "“${version}” isn’t a version number."
    if [ -z "${pinned}" ]; then
        case "${version}" in *-*) fail "the latest is the pre-release ${version}; set NEXTTERM_VERSION=${version} to install it." ;; esac
    fi
    # True when $1 comes before $2. A pre-release (0.8.0-rc1) comes before its release (0.8.0).
    nt_older() {
        [ "$1" != "$2" ] || return 1
        local a="${1%%-*}" b="${2%%-*}"
        if [ "${a}" = "${b}" ]; then
            case "$1" in *-*) ;; *) return 1 ;; esac
            case "$2" in *-*) ;; *) return 0 ;; esac
            [ "$(printf '%s\n%s\n' "$1" "$2" | LC_ALL=C sort | head -1)" = "$1" ]
            return
        fi
        [ "$(printf '%s\n%s\n' "${a}" "${b}" | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n | head -1)" = "${a}" ]
    }
    # Where each file comes from, in order: GitHub, then the site's own copy of the release. Either may
    # serve anything; only what the release key signed is installed.
    local bases=("https://github.com/${repo}/releases/download/v${version}" "https://nxtrm.mishuk.me/releases/v${version}")
    local dmg_name="NextTerm-${version}.dmg"

    local target="${NEXTTERM_DIR:-/Applications}"
    if [ -z "${NEXTTERM_DIR:-}" ] && ! [ -w /Applications ]; then target="${HOME}/Applications"; fi
    case "${target}" in /*) ;; *) target="${PWD}/${target}" ;; esac # the folder walk below needs an absolute path
    if ! [ -d "${target}" ]; then
        case "/${target}/" in */../*) fail "give NEXTTERM_DIR without “..”." ;; esac
    fi
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
    nt_refuse_if_running() {
        local processes executable
        processes="$(ps -axo comm=)"
        while IFS= read -r executable; do
            case "${executable}" in
                /*"/${app_name}/Contents/MacOS/NextTerm") # a relative argv[0] is relative to that process's folder, not ours
                    if [ "${executable}" -ef "${destination}/Contents/MacOS/NextTerm" ]; then
                        fail "Next Term is running from ${target}. Use Next Term › Check for Updates…, or quit it and run this again."
                    fi ;;
            esac
        done <<PROCESSES
${processes}
PROCESSES
        # ps shows argv[0] as typed (./NextTerm, a symlink, exec -a); lsof finds the executable itself.
        if [ -e "${destination}/Contents/MacOS/NextTerm" ] && /usr/sbin/lsof -t -- "${destination}/Contents/MacOS/NextTerm" >/dev/null 2>&1; then
            fail "Next Term is running from ${target}. Use Next Term › Check for Updates…, or quit it and run this again."
        fi
    }
    nt_refuse_if_running

    # One install into a folder at a time. nt_lock is set only once the lock is ours. The lock holds the
    # installing shell's process id, so a lock left by a killed install (no trap ran) is taken over
    # instead of blocking every install after it. Taking one over happens under a second lock, so two
    # installers can't both take over the same stale one.
    local lock="${target}/.Next Term.install.lock"
    local holder=""
    # A process's identity: its id and when it started, so an id the system reused is told apart.
    nt_identity() { printf '%s %s\n' "$1" "$(ps -o lstart= -p "$1" 2>/dev/null | tr -s ' ')"; }
    # True when no running installer holds the lock: the process that wrote it is gone (its id is free,
    # or now names a process that started later); a lock without an id (0.11.83 and before) after ten minutes.
    nt_lock_is_stale() {
        local written
        written="$(head -1 "${lock}/pid" 2>/dev/null || true)"
        holder="${written%% *}"
        case "${holder}" in '' | *[!0-9]*) holder="" ;; esac
        if [ -n "${holder}" ]; then
            [ "$(nt_identity "${holder}")" != "${written}" ]
            return
        fi
        [ -d "${lock}" ] && [ -n "$(find "${lock}" -maxdepth 0 -mmin +10 2>/dev/null)" ]
    }
    if ! mkdir "${lock}" 2>/dev/null; then
        local takeover="${lock%.lock}.takeover"
        if ! mkdir "${takeover}" 2>/dev/null; then
            # Another installer is looking at the same lock, or one was killed doing it (minutes ago): a
            # stale one is renamed away first, so of two installers breaking it only one can.
            if [ -n "$(find "${takeover}" -maxdepth 0 -mmin +2 2>/dev/null)" ] && mv "${takeover}" "${takeover}.stale.$$" 2>/dev/null; then
                rmdir "${takeover}.stale.$$" 2>/dev/null || true
            fi
            mkdir "${takeover}" 2>/dev/null || fail "another install into ${target} is running; if not, remove “${lock}”."
        fi
        nt_takeover="${takeover}"
        if nt_lock_is_stale; then rm -rf "${lock}" 2>/dev/null || true; fi
        local got=0
        mkdir "${lock}" 2>/dev/null || got=1
        rmdir "${takeover}" 2>/dev/null || true
        nt_takeover=""
        [ "${got}" = 0 ] || fail "another install into ${target} is running${holder:+ (process ${holder})}; if not, remove “${lock}”."
    fi
    nt_lock="${lock}"
    nt_identity "$$" > "${lock}/pid" || fail "can’t write to ${target}."

    # An install killed between its two renames (no trap ran) may have left the old app aside: it goes
    # back, and what such a run left behind goes. Only this script makes these names, and the lock is ours.
    local leftover
    for leftover in "${target}/.Next Term.previous."* "${target}/.Next Term.installing."*; do
        [ -d "${leftover}" ] || continue
        if ! [ -e "${destination}" ] && [ -d "${leftover}/${app_name}" ] \
            && [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${leftover}/${app_name}/Contents/Info.plist" 2>/dev/null || true)" = "${bundle_id}" ]; then
            case "${leftover}" in */.Next\ Term.previous.*)
                mv "${leftover}/${app_name}" "${destination}" \
                    || fail "a stopped install left Next Term in ${leftover}; move it back to ${destination}."
                say "Put back the Next Term that a stopped install had moved aside." ;;
            esac
        fi
        rm -rf "${leftover}" 2>/dev/null || say "Could not remove ${leftover}."
    done

    nt_work="$(mktemp -d "${TMPDIR:-/tmp}/next-term-install.XXXXXX")"
    local work="${nt_work}"

    say "Downloading Next Term${version:+ ${version}}…"
    printf '%s %s\n' "${signer}" "${release_key}" > "${work}/allowed_signers"
    local get=(curl -fL --proto '=https' --tlsv1.2 --retry 1 --retry-connrefused --retry-max-time 20 --connect-timeout 10
        --speed-limit 2048 --speed-time 30 --silent --show-error) # a stalled download moves on
    local why="" expected="" actual=""
    # Downloads the three files from one place ($1) into $2 and checks them as one set: a page a captive
    # portal or a broken mirror returns, or a file cut short, fails here and the next place is tried.
    # Sets why when it fails.
    nt_try() {
        local from="$1" into="$2" name err
        rm -rf "${into}"; mkdir "${into}"
        # The signature first: it is the file a release gets last, and the smallest.
        local cap
        for name in "${dmg_name}.sha256.sig" "${dmg_name}.sha256" "${dmg_name}"; do
            cap=60 # the two small files: a slow or throttled host doesn't hold the fallback back
            [ "${name}" = "${dmg_name}" ] && cap=3600
            if ! err="$("${get[@]}" --max-time "${cap}" -o "${into}/${name}" "${from}/${name}" 2>&1)"; then
                err="${err##*curl: }"
                err="${err#(*) }"
                why="${name} could not be downloaded: ${err:-no answer}"
                return 1
            fi
        done
        if ! ssh-keygen -Y verify -f "${work}/allowed_signers" -I "${signer}" -n next-term-release -s "${into}/${dmg_name}.sha256.sig" \
            < "${into}/${dmg_name}.sha256" >/dev/null 2>&1; then
            why="its checksum is not signed with the Next Term release key"; return 1
        fi
        expected="$(awk 'NR == 1 { print tolower($1) }' "${into}/${dmg_name}.sha256")"
        actual="$(shasum -a 256 "${into}/${dmg_name}" | awk '{ print tolower($1) }')"
        local hex='^[0-9a-f]{64}$'
        [[ ${expected} =~ ${hex} ]] || { why="its published checksum is not a SHA-256"; return 1; }
        [ "${expected}" = "${actual}" ] || { why="the download does not match its signed SHA-256"; return 1; }
        # The signed text names the file, and the file name names the version: a signature from another release is refused.
        [ "$(cat "${into}/${dmg_name}.sha256")" = "${actual}  ${dmg_name}" ] || { why="the signed checksum is not for ${dmg_name}"; return 1; }
    }
    # GitHub, then the site, and the round once more for a connection that dropped midway.
    local round each place="" n=0
    for round in 1 2; do
        for each in "${bases[@]}"; do
            n=$((n + 1))
            case "${each}" in https://github.com/*) place="GitHub" ;; *) place="the site" ;; esac
            if nt_try "${each}" "${work}/try${n}"; then
                mv "${work}/try${n}/"* "${work}/"
                break 2
            fi
            say "From ${place}: ${why}."
            place=""
        done
    done
    [ -n "${place}" ] || fail "${version} could not be downloaded and checked from GitHub or from the site (last: ${why})."
    say "Checked: signed by the Next Term release key, SHA-256 ${actual}${place:+ (from ${place})}"

    nt_mount="${work}/mount"
    mkdir "${nt_mount}"
    # Once more after a pause: Spotlight or a virus scanner sometimes still holds a just-written image.
    hdiutil attach "${work}/${dmg_name}" -nobrowse -readonly -noautoopen -quiet -mountpoint "${nt_mount}" </dev/null 2>/dev/null \
        || { sleep 3; hdiutil attach "${work}/${dmg_name}" -nobrowse -readonly -noautoopen -quiet -mountpoint "${nt_mount}" </dev/null; } \
        || fail "the disk image could not be opened."
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
            fail "Next Term ${installed} is installed and the latest release is the older ${version}; set NEXTTERM_VERSION=${version} to install it anyway."
        fi
    fi
    codesign --verify --deep --strict "${source}" 2>/dev/null || fail "the app’s signature is broken."

    # Copy beside the old one, check the copy, then swap: a failure leaves the old app as it was.
    # Both folders are known to the exit trap from the moment they exist: Ctrl-C at any point leaves
    # either the old app or the new one in place, and nothing else.
    nt_staged="$(mktemp -d "${target}/.Next Term.installing.XXXXXX")" || fail "can’t write to ${target}."
    ditto "${source}" "${nt_staged}/${app_name}" || fail "the app could not be copied to ${target}."
    codesign --verify --deep --strict "${nt_staged}/${app_name}" 2>/dev/null || fail "the copied app does not verify."
    nt_refuse_if_running # again: it may have been opened during the download
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

    # True when the link target $1 is Next Term's: the script inside a copy of it that is Next Term by its
    # bundle identifier, or that has moved or gone since.
    nt_is_ours() {
        case "$1" in /*.app/Contents/Resources/bin/nxtrm) ;; *) return 1 ;; esac
        local app="${1%/Contents/Resources/bin/nxtrm}"
        [ -e "${app}" ] || return 0
        [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${app}/Contents/Info.plist" 2>/dev/null || true)" = "${bundle_id}" ]
    }

    # nxtrm for other terminals (Next Term's own tabs always have it), the way the app links it at launch.
    # PATH is walked as the shell walks it, and its first nxtrm decides: a link to this copy stays, Next
    # Term's link to another copy is repointed where it is (or, needing sudo, only a folder ahead of it
    # will do), anyone else's is left alone. With none, the first folder meant for commands that is
    # writable without sudo gets the link.
    nt_link_command() {
        local script="${destination}/Contents/Resources/bin/nxtrm"
        [ -x "${script}" ] || return 0
        case "${destination}" in # as the app does: the link would break whenever that disk is ejected
            /Volumes/*) say "nxtrm was not linked: ${target} is on another disk."; return 0 ;;
        esac
        local folders=() folder link target free=""
        IFS=: read -r -a folders <<<"${PATH:-}" || true
        for folder in ${folders[@]+"${folders[@]}"}; do
            while [ "${#folder}" -gt 1 ] && [ "${folder%/}" != "${folder}" ]; do folder="${folder%/}"; done
            case "${folder}" in /*) ;; *) continue ;; esac # relative to wherever a command runs; zsh takes a ~ literally
            link="${folder}/nxtrm"
            case "${link}" in */*.app/Contents/Resources/bin/nxtrm) continue ;; esac # a Next Term's own folder
            if [ -L "${link}" ]; then
                target="$(/usr/bin/readlink "${link}")" || target=""
                if [ "${target}" = "${script}" ]; then
                    say "nxtrm is on your PATH: ${link}"
                    return 0
                fi
                if nt_is_ours "${target}"; then
                    if ! [ -w "${folder}" ]; then
                        [ -n "${free}" ] && break # a folder ahead of it on PATH takes the link
                        [ -e "${link}" ] || continue # to a copy that is gone: the shell passes over it too
                        say "${link} opens another copy of Next Term, and changing it needs your password: Next Term offers to when it opens."
                        return 0
                    fi
                    if /bin/ln -sfh "${script}" "${link}"; then
                        say "Pointed ${link} at this copy: nxtrm opens Next Term from any terminal."
                    else
                        say "Could not point ${link} at this copy."
                    fi
                    return 0
                fi
            fi
            if [ -L "${link}" ] || [ -e "${link}" ]; then
                say "Left ${link} as it is: that nxtrm isn’t Next Term’s."
                return 0
            fi
            if [ -z "${free}" ] && [ -d "${folder}" ] && [ -w "${folder}" ]; then
                case "${folder}" in "${HOME}/.local/bin" | "${HOME}/bin" | /opt/homebrew/bin | /usr/local/bin) free="${link}" ;; esac
            fi
        done
        if [ -n "${free}" ] && /bin/ln -s "${script}" "${free}"; then
            say "Linked ${free}: nxtrm . opens a folder in Next Term from any terminal."
            return 0
        fi
        say "For nxtrm in other terminals, open Next Term: no folder on your PATH takes it without sudo, so it offers"
        say "to link /usr/local/bin/nxtrm with your password (later: Next Term › Install Command Line Tool (nxtrm)…)."
    }
    nt_link_command

    say "Open it from ${target}, or run: open -a \"${destination}\""
}

main "$@"
