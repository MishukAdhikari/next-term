import Foundation

// Finding tmux and herdr on a host: one finder, two lists of names.
//
// ssh runs its command through the login shell without login or interactive mode, so the PATH that ~/.profile,
// ~/.zprofile or the interactive part of an rc file sets (Linuxbrew, mise, asdf, Nix, rustup, herdr's
// HERDR_INSTALL_DIR) is not there: a tool that runs in the user's own terminal can be missing from /bin/sh's PATH.
// herdr is looked for in this order:
// 1. the executable of the user's running herdr server, so the client and the CLI speak its protocol (and, on Linux,
//    when it is the only one, the socket variables it runs with: of several, herdr picks the session, as it would);
// 2. where a tab opens or check_host asks, and no server runs: the PATH the user's login shell sets, run without a
//    terminal for 3 seconds at most, nothing of it shown;
// 3. /bin/sh's PATH;
// 4. the folders herdr's installer, Homebrew, mise, asdf and Nix use (herdr's own list, and a few more).
// tmux takes 3 and 4. A copy counts only as a file that can run, and where a tab opens, only once its --version (tmux
// -V) answers: a folder named herdr, or a broken mise shim, is passed over and named. A tab writes what it found to
// ~/.cache/next-term/herdr, which the 2-second status checks read when no herdr server runs (a running server's copy
// comes first there too); they never run the login shell.
//
// Every script here is fixed text plus quoted values, as Remote.swift's rule says; what the host reports is cut and
// stripped of control characters before it is printed.
extension RemoteShell {
    /// The end of the status check's herdr section: without it the answer was cut.
    static let herdrEndMarker = "@@NEXTTERM-HERDR-END@@"
    /// Where herdr's install page is: a tab with no herdr points there (Next Term never installs it).
    public static let herdrInstallPage = "https://herdr.dev/docs/install/"
    /// What the status checks looked through, for the herdr section's `missing` line.
    static let herdrPlaces = "path,local-bin,cargo,brew,mise,asdf,nix"

    /// A new marker for the login shell's environment, made on this Mac for each script: rc-file noise cannot forge it.
    static func newEnvMark() -> String {
        "@@NT-ENV-" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16)).lowercased() + "@@"
    }

    /// The finder's own functions. nt_ok: `$1` is a file that can run (and with nt_check set, answers it; the first one
    /// that doesn't is nt_bad, and its first line nt_said). nt_on_path NAME LIST: the first copy on a PATH list, a mise or
    /// asdf shim (the first one there) only when nothing else runs. nt_known NAME: the install folders. Each sets NTF to
    /// what it found. All their variables start with nt_, so a script's own (C, H, K, T, p, s…) are left alone.
    static let finderFunctions = #"""
        nt_nl='
        '
        nt_tab=$(printf '\t')
        nt_ok() {
          [ -f "$1" ] && [ -x "$1" ] || return 1
          [ -n "$nt_check" ] || return 0
          if nt_v=$("$1" $nt_check 2>&1 </dev/null); then return 0; fi
          if [ -z "$nt_bad" ]; then
            nt_bad=$(printf '%s' "$1" | tr -d '\000-\037\177' | cut -c 1-300)
            nt_said=$(printf '%s\n' "$nt_v" | head -n 1 | tr -d '\000-\037\177' | cut -c 1-200)
          fi
          return 1
        }
        nt_on_path() {
          nt_shim=; nt_ifs=$IFS; IFS=:; set -f
          for nt_d in $2; do
            IFS=$nt_ifs
            case $nt_d in /*) ;; *) continue ;; esac
            case $nt_d/$1 in
              */mise/shims/*|*/asdf/shims/*|*/.asdf/shims/*)
                if [ -z "$nt_shim" ] && [ -f "$nt_d/$1" ] && [ -x "$nt_d/$1" ]; then nt_shim=$nt_d/$1; fi
                continue ;;
            esac
            if nt_ok "$nt_d/$1"; then set +f; NTF=$nt_d/$1; return 0; fi
          done
          IFS=$nt_ifs; set +f
          if [ -n "$nt_shim" ] && nt_ok "$nt_shim"; then NTF=$nt_shim; return 0; fi
          return 1
        }
        nt_places() {
          nt_n=$1
          M=${MISE_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/mise}
          if [ "$nt_n" = herdr ] && [ -n "${HERDR_INSTALL_DIR:-}" ]; then printf '%s\n' "$HERDR_INSTALL_DIR/herdr"; fi
          printf '%s\n' "$HOME/.local/bin/$nt_n" "$HOME/bin/$nt_n" "${CARGO_HOME:-$HOME/.cargo}/bin/$nt_n" \
            "/home/linuxbrew/.linuxbrew/bin/$nt_n" "$HOME/.linuxbrew/bin/$nt_n" "/opt/homebrew/bin/$nt_n" "/usr/local/bin/$nt_n" \
            "$M/installs/$nt_n/latest/bin/$nt_n" "$M/installs/$nt_n/latest/$nt_n"
          case $nt_n in
            herdr) set -- herdr aqua-herdrdev-herdr github-herdrdev-herdr github-ogulcancelik-herdr ;;
            *) set -- "$nt_n" ;;
          esac
          for nt_t; do
            for nt_d in "$M/installs/$nt_t"/*; do
              if [ -d "$nt_d" ] && [ "${nt_d##*/}" != latest ]; then printf '%s\t%s\n' "${nt_d##*/}" "$nt_d"; fi
            done
          done | sort -t. -k1,1nr -k2,2nr -k3,3nr | cut -f 2- | while IFS= read -r nt_d; do
            printf '%s\n' "$nt_d/bin/$nt_n" "$nt_d/$nt_n"
          done
          printf '%s\n' "$M/shims/$nt_n" "${ASDF_DATA_DIR:-$HOME/.asdf}/shims/$nt_n" "$HOME/.nix-profile/bin/$nt_n" \
            "${XDG_STATE_HOME:-$HOME/.local/state}/nix/profile/bin/$nt_n" "/etc/profiles/per-user/${USER:-$(id -un 2>/dev/null)}/bin/$nt_n" \
            "/nix/var/nix/profiles/default/bin/$nt_n" "/run/current-system/sw/bin/$nt_n"
        }
        nt_known() {
          nt_list=$(nt_places "$1")
          nt_ifs=$IFS; IFS=$nt_nl; set -f
          for nt_p in $nt_list; do
            IFS=$nt_ifs
            if nt_ok "$nt_p"; then set +f; NTF=$nt_p; return 0; fi
          done
          IFS=$nt_ifs; set +f
          return 1
        }
        """#

    /// herdr's own: nt_running (the executable of a `herdr server` this user runs: /proc on Linux, ps elsewhere; NTS, its
    /// pid, only when it is the only server, since which of several started first says nothing of the session wanted),
    /// the socket variables it runs with (nt_server_env, Linux), nt_use_env (exports those three, and only those), and
    /// the cache a tab writes (nt_herdr_save) and the status checks read (nt_herdr_cached).
    static let herdrFunctions = #"""
        nt_running() {
          NTS=; nt_first=; nt_firstpid=; nt_count=0
          command -v pgrep >/dev/null 2>&1 || return 1
          for nt_q in $(pgrep -u "$(id -u)" -x "$1" 2>/dev/null); do
            nt_e=
            if [ -r "/proc/$nt_q/cmdline" ]; then
              [ "$(tr '\000' '\n' < "/proc/$nt_q/cmdline" 2>/dev/null | sed -n 2p)" = server ] || continue
              nt_e=$(readlink "/proc/$nt_q/exe" 2>/dev/null)
              nt_e=${nt_e% (deleted)}
            else
              [ "$(ps -o args= -p "$nt_q" 2>/dev/null | awk '{ print $2 }')" = server ] || continue
              nt_e=$(ps -o comm= -p "$nt_q" 2>/dev/null)
            fi
            case $nt_e in /*) ;; *) continue ;; esac
            nt_count=$((nt_count + 1))
            if [ -z "$nt_first" ] && nt_ok "$nt_e"; then nt_first=$nt_e; nt_firstpid=$nt_q; fi
          done
          [ -n "$nt_first" ] || return 1
          NTF=$nt_first
          if [ "$nt_count" -eq 1 ]; then NTS=$nt_firstpid; fi
          return 0
        }
        nt_server_env() {
          [ -n "$NTS" ] && [ -r "/proc/$NTS/environ" ] || return 0
          nt_env=$(tr '\000' '\n' < "/proc/$NTS/environ" 2>/dev/null | grep -E '^(HERDR_SESSION|HERDR_SOCKET_PATH|XDG_CONFIG_HOME)=' | tr -d '\001-\011\013-\037\177')
        }
        nt_use_env() {
          nt_ifs=$IFS; IFS=$nt_nl; set -f
          for nt_l in $nt_env; do
            IFS=$nt_ifs
            case $nt_l in
              HERDR_SESSION=*) HERDR_SESSION=${nt_l#*=}; export HERDR_SESSION ;;
              HERDR_SOCKET_PATH=*) HERDR_SOCKET_PATH=${nt_l#*=}; export HERDR_SOCKET_PATH ;;
              XDG_CONFIG_HOME=*) XDG_CONFIG_HOME=${nt_l#*=}; export XDG_CONFIG_HOME ;;
            esac
          done
          IFS=$nt_ifs; set +f
        }
        nt_herdr_save() {
          mkdir -p "$C" 2>/dev/null
          case $H in
            /*) ;;
            *) rm -f "$C/herdr" 2>/dev/null; return 0 ;;
          esac
          {
            printf 'path\t%s\nhow\t%s\n' "$H" "$HW"
            if [ -n "$nt_env" ]; then printf '%s\n' "$nt_env" | while IFS= read -r nt_l; do printf 'env\t%s\n' "$nt_l"; done; fi
          } > "$C/herdr.$$" 2>/dev/null && mv -f "$C/herdr.$$" "$C/herdr" 2>/dev/null
          rm -f "$C/herdr.$$" 2>/dev/null
        }
        nt_herdr_cached() {
          [ -f "$C/herdr" ] || return 1
          nt_cp=; nt_cw=; nt_env=
          while IFS=$nt_tab read -r nt_k nt_val; do
            case $nt_k in
              path) nt_cp=$nt_val ;;
              how) nt_cw=$nt_val ;;
              env) nt_env=$nt_env$nt_val$nt_nl ;;
            esac
          done < "$C/herdr"
          case $nt_cp in /*) ;; *) return 1 ;; esac
          nt_ok "$nt_cp" || return 1
          NTF=$nt_cp; HW=${nt_cw:-cache}
        }
        """#

    /// The login shell's PATH: nt_login_env MARK FLAGS… runs the user's shell (SHELL, which sshd sets to the passwd
    /// one) with FLAGS and `echo MARK; /usr/bin/env; echo MARK`, stdin from /dev/null, stdout into a file of Next Term's
    /// that is deleted after, stderr nowhere, through setsid where there is one (no rc file can then open the tab's
    /// terminal). A watchdog ends it after 3 seconds (macOS hosts have no `timeout`); it holds no output of the script's,
    /// so nothing waits for it. nt_lp is the PATH between the marks, nt_env herdr's socket variables. nt_login_find
    /// MARK: herdr on it; bash and zsh that gave a PATH without herdr are asked once more as interactive shells (Ubuntu's
    /// ~/.bashrc sets PATH after its "not interactive" guard), only where setsid is. A shell that gave nothing in time
    /// is not asked again. The shell's aliases and functions are never used, only PATH.
    static let loginFunctions = #"""
        nt_login_env() {
          nt_m=$1; shift
          nt_lp=; nt_o="$C/login-env.$$"
          mkdir -p "$C" 2>/dev/null
          : > "$nt_o" 2>/dev/null || return 1
          if command -v setsid >/dev/null 2>&1; then
            setsid "$nt_s" "$@" "echo $nt_m; /usr/bin/env; echo $nt_m" </dev/null >"$nt_o" 2>/dev/null &
          else
            "$nt_s" "$@" "echo $nt_m; /usr/bin/env; echo $nt_m" </dev/null >"$nt_o" 2>/dev/null &
          fi
          nt_w=$!
          ( sleep 3; kill -9 "$nt_w" ) >/dev/null 2>&1 &
          nt_k=$!
          wait "$nt_w" 2>/dev/null
          kill "$nt_k" 2>/dev/null
          nt_got=$(sed -n "/${nt_m}\$/,/^${nt_m}\$/p" "$nt_o" 2>/dev/null)
          rm -f "$nt_o" 2>/dev/null
          nt_lp=$(printf '%s\n' "$nt_got" | sed -n 's/^PATH=//p' | head -n 1)
          nt_env=$(printf '%s\n' "$nt_got" | grep -E '^(HERDR_SESSION|HERDR_SOCKET_PATH|XDG_CONFIG_HOME)=' | tr -d '\001-\011\013-\037\177')
          [ -n "$nt_lp" ]
        }
        nt_login_find() {
          nt_s=${SHELL:-}
          case $nt_s in /*) ;; *) return 1 ;; esac
          [ -f "$nt_s" ] && [ -x "$nt_s" ] || return 1
          case ${nt_s##*/} in
            bash|zsh|ksh|ksh93|mksh|sh|dash|ash|yash|fish) nt_login_env "$1" -l -c ;;
            *) nt_login_env "$1" -c ;;
          esac || return 1
          nt_on_path herdr "$nt_lp" && return 0
          command -v setsid >/dev/null 2>&1 || return 1
          case ${nt_s##*/} in bash|zsh) ;; *) return 1 ;; esac
          nt_login_env "$1" -l -i -c
          nt_on_path herdr "$nt_lp"
        }
        """#

    /// Finds tmux: on PATH, or where Homebrew, Linuxbrew, mise, asdf, Nix and user installs put it (a non-login shell's
    /// PATH often lacks them). Sets T. `checked`: only a tmux whose -V answers (where a tab opens; a status check
    /// every 2 seconds runs nothing to look).
    static func tmuxFinder(checked: Bool) -> String {
        [
            finderFunctions,
            "nt_check=\(checked ? "-V" : ""); nt_bad=; NTF=; T=",
            "if nt_on_path tmux \"$PATH\" || nt_known tmux; then T=$NTF; fi",
        ].joined(separator: "\n")
    }

    static let findTmux = tmuxFinder(checked: false)

    /// Finds herdr for a status check: the running server's (a copy upgraded under it, say an older mise version still
    /// installed, would not speak its protocol), where the last tab found it (the cache), /bin/sh's PATH, the install
    /// folders; never the login shell. Sets H, and HW to how it was found.
    static let findHerdr = [
        finderFunctions,
        herdrFunctions,
        "H=; HW=; nt_bad=; nt_said=; nt_env=; NTF=; nt_check=",
        "if nt_running herdr; then H=$NTF; HW=running; nt_server_env",
        "elif nt_herdr_cached; then H=$NTF",
        "elif nt_on_path herdr \"$PATH\"; then H=$NTF; HW=path",
        "elif nt_known herdr; then H=$NTF; HW=known",
        "fi",
        "nt_use_env",
    ].joined(separator: "\n")

    /// Finds herdr where a tab opens (and for check_host): the running server's, else the login shell's PATH, /bin/sh's,
    /// the install folders, each copy asked its --version; then writes the cache. Sets H and HW, or nt_bad and nt_said
    /// for a copy that did not run. Needs C.
    static func herdrTabFinder(mark: String = newEnvMark()) -> String {
        [
            finderFunctions,
            herdrFunctions,
            loginFunctions,
            "H=; HW=; nt_bad=; nt_said=; nt_env=; NTF=; nt_check=--version",
            "if nt_running herdr; then H=$NTF; HW=running; nt_server_env",
            "elif nt_login_find \(quote(mark)); then H=$NTF; HW=login",
            "elif nt_on_path herdr \"$PATH\"; then H=$NTF; HW=path",
            "elif nt_known herdr; then H=$NTF; HW=known",
            "fi",
            "nt_use_env",
            "nt_herdr_save",
        ].joined(separator: "\n")
    }

    /// The status check's herdr section, after findHerdr: where herdr is and what `herdr agent list` said, stdout and
    /// stderr together (herdr prints one JSON object on one of them), its exit status, and an end marker. herdr before
    /// 0.5.10 has no `agent` command: then, when `agent list` failed saying so (an agent's title may say it too),
    /// `pane list`. Line breaks become spaces (pretty-printed JSON reads the same, and noise stays apart from it);
    /// escape sequences, and BEL, which ends an OSC, stay for HerdrAgent.listing to read past, other control characters
    /// go; 1 MB at most. `session`: a named herdr session's (`--session`, in a subshell without herdr's own socket
    /// variables, which name the default session's), said on a `session<TAB>name` line after the marker; nil for herdr's
    /// default, as before, with no such line. `wantsFocus`: a tab of the session is on screen, so when no agent has
    /// herdr's focus (a shell pane does), `tabs<TAB>` and what `herdr tab list` said follow, to tell which tab it is.
    static var herdrSection: String { herdrSection(session: nil) }

    static func herdrSection(session: String?, wantsFocus: Bool = false) -> String {
        herdrSection(word: session.map(quote), wantsFocus: wantsFocus)
    }

    /// The section, `word` being the session as one sh word (a quoted name, or a variable the caller set from herdr's own
    /// list of sessions).
    static func herdrSection(word: String?, wantsFocus: Bool) -> String {
        // herdr with its arguments, for the session asked. A subshell inside $( ) starts with a space: "$((" is arithmetic.
        func herdr(_ arguments: String) -> String {
            guard let word else { return "\"$H\" \(arguments)" }
            return " ( unset HERDR_SOCKET_PATH HERDR_SESSION; exec \"$H\" --session \(word) \(arguments) )"
        }
        let clean = "tr '\\n\\r\\t' '   ' | tr -d '\\000-\\006\\010-\\032\\034-\\037\\177'"
        var lines = ["printf '\\n%s\\n' \(quote(herdrMarker))"]
        if let word { lines.append("printf 'session\\t%s\\n' \(word)") }
        lines += [
            "if [ -z \"$H\" ]; then",
            "  printf 'missing\\t%s\\n' \(quote(herdrPlaces))",
            "else",
            "  printf 'where\\t%s\\t%s\\n' \"$(printf '%s' \"$H\" | tr -d '\\000-\\037\\177' | cut -c 1-1024)\" \"$HW\"",
            "  nt_out=$(\(herdr("agent list")) 2>&1 </dev/null); nt_x=$?; nt_cmd=agent",
            "  if [ \"$nt_x\" -ne 0 ]; then",
            "    case $nt_out in",
            "      *'unknown command'*|*'unrecognized subcommand'*) nt_out=$(\(herdr("pane list")) 2>&1 </dev/null); nt_x=$?; nt_cmd=pane ;;",
            "    esac",
            "  fi",
            "  printf 'exit\\t%s\\t%s\\n' \"$nt_x\" \"$nt_cmd\"",
            "  printf 'out\\t'; printf '%s' \"$nt_out\" | \(clean) | head -c 1000000; echo",
        ]
        if wantsFocus {
            lines += [
                "  if [ \"$nt_x\" -eq 0 ] && ! printf '%s' \"$nt_out\" | grep -Eq '\"focused\"[[:space:]]*:[[:space:]]*true'; then",
                "    nt_tl=$(\(herdr("tab list")) 2>&1 </dev/null)",
                "    printf 'tabs\\t'; printf '%s' \"$nt_tl\" | \(clean) | head -c 200000; echo",
                "  fi",
            ]
        }
        lines += [
            "fi",
            "printf '%s\\n' \(quote(herdrEndMarker))",
        ]
        return lines.joined(separator: "\n")
    }

    /// What a herdr tab says when herdr is not there (or a copy did not run), in plain lines, then the reason in K.plain
    /// for the status check. The install page is a link (OSC 8) and plain text, which ⌘-click finds too.
    static var herdrMissingNote: String {
        let stops = "so this tab is a plain shell: what runs in it stops if the connection drops."
        let looked = "Looked on your login shell's PATH and /bin/sh's PATH, and in ~/.local/bin, ~/bin, ~/.cargo/bin and the "
            + "Homebrew, mise, asdf and Nix folders."
        let elsewhere = " (Next Term never installs it). If it is installed somewhere else, add that folder to PATH in "
            + "~/.profile or ~/.zprofile. Then open a new herdr tab."
        return [
            "  if [ -n \"$nt_bad\" ]; then",
            "    printf 'herdr at %s did not run (herdr --version said: %s)\\n' \"$nt_bad\" \"$nt_said\" > \"$K.plain\" 2>/dev/null",
            "    printf 'Next Term: herdr at %s did not run (herdr --version said: %s), %s\\r\\n' \"$nt_bad\" \"$nt_said\" \(quote(stops))",
            "  else",
            "    : > \"$K.plain\" 2>/dev/null",
            "    printf '%s\\r\\n' \(quote("Next Term: herdr was not found on this host, " + stops))",
            "  fi",
            "  printf '%s\\r\\n' \(quote(looked))",
            "  printf 'To use herdr here, install it yourself: \\033]8;;%s\\033\\\\%s\\033]8;;\\033\\\\%s\\r\\n' "
                + "\(quote(herdrInstallPage)) \(quote(herdrInstallPage)) \(quote(elsewhere))",
        ].joined(separator: "\n")
    }
}
