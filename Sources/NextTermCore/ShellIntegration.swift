import Foundation

/// The zsh integration and the private OSC 6973 protocol it speaks.
///
/// Next Term starts zsh with `ZDOTDIR` pointing at a directory holding `zshenvScript` as `.zshenv`.
/// That script restores the user's own `ZDOTDIR`, sources their `.zshenv`, and adds two hooks:
///
///     ESC ] 6973 ; <nonce> ; cmd ; <base64 typed> ; <base64 expanded> BEL   preexec, a command starts
///     ESC ] 6973 ; <nonce> ; end ; <exit status> BEL                         precmd, the command finished
///     ESC ] 6973 ; <nonce> ; cwd ; <base64 directory> BEL                    precmd, the working directory
///     ESC ] 6973 ; <nonce> ; jobs ; <count> ; <base64 job list> BEL          precmd, suspended/background jobs
///
/// "expanded" is the line with aliases expanded, so `claude-auto` (an alias for `claude …`) is seen as an agent.
///
/// Anything printed to the terminal can contain these bytes (a `cat` of a log, a remote host over ssh),
/// so each tab gets a random nonce. The shell receives it as `NEXTTERM_NONCE`, keeps it in an unexported
/// variable and removes it from the environment, so programs it runs never see it. Marks without the
/// tab's nonce are ignored.
public enum ShellIntegration {
    public static let oscCode = 6973
    public static let nonceVariable = "NEXTTERM_NONCE"
    /// Longest command line kept (it is only shown in tooltips and used to name the program).
    public static let maxCommandLength = 4096
    static let maxPayloadBytes = 65_536

    public static func makeNonce() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    public enum Event: Equatable, Sendable {
        case commandStarted(String, expanded: String?)
        case commandFinished(Int32)
        case directory(String)
        case jobs(Int, summary: String)
    }

    /// Parses an OSC 6973 payload (everything after `6973;`). Returns nil unless it carries `nonce`.
    public static func parse(_ payload: some Collection<UInt8>, nonce: String) -> Event? {
        guard !nonce.isEmpty, payload.count <= maxPayloadBytes, let text = String(bytes: payload, encoding: .utf8) else { return nil }
        let parts = text.split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == nonce else { return nil }
        let value = String(parts[2])
        switch parts[1] {
        case "cmd":
            let fields = value.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard let typed = decode(fields[0]) else { return nil }
            let expanded = fields.count > 1 ? decode(fields[1]).map { String($0.prefix(maxCommandLength)) } : nil
            return .commandStarted(String(typed.prefix(maxCommandLength)), expanded: expanded == typed ? nil : expanded)
        case "jobs":
            let fields = value.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard let count = Int(fields[0]), count >= 0 else { return nil }
            let summary = fields.count > 1 ? (decode(fields[1]) ?? "") : ""
            return .jobs(count, summary: String(summary.prefix(1000)))
        case "end":
            return Int32(value).map(Event.commandFinished)
        case "cwd":
            guard let dir = decode(value), dir.hasPrefix("/"), dir.utf8.count <= 4096 else { return nil }
            return .directory(dir)
        default:
            return nil
        }
    }

    private static func decode(_ base64: String) -> String? {
        if base64.isEmpty { return "" }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Writes `.zshenv` under `directory` (if it changed) and returns the directory to use as `ZDOTDIR`.
    public static func install(in directory: URL) throws -> URL {
        let zdotdir = directory.appendingPathComponent("shell/zsh", isDirectory: true)
        try FileManager.default.createDirectory(at: zdotdir, withIntermediateDirectories: true)
        let file = zdotdir.appendingPathComponent(".zshenv")
        let data = Data(zshenvScript.utf8)
        if (try? Data(contentsOf: file)) != data {
            try data.write(to: file, options: .atomic)
        }
        return zdotdir
    }

    public static let zshenvScript = #"""
# Next Term shell integration.
# Next Term starts zsh with ZDOTDIR pointing here. Put the user's ZDOTDIR back first, so their own
# .zshenv, .zprofile, .zshrc and .zlogin load from where they always do.
# Take the tab's nonce out of the environment first, so not even the user's .zshenv (or anything it
# starts) can see it.
typeset -g __nextterm_nonce="${NEXTTERM_NONCE-}"
unset NEXTTERM_NONCE

if [[ -n "$NEXTTERM_USER_ZDOTDIR" ]]; then
  ZDOTDIR="$NEXTTERM_USER_ZDOTDIR"
else
  unset ZDOTDIR
fi
unset NEXTTERM_USER_ZDOTDIR

[[ -f "${ZDOTDIR:-$HOME}/.zshenv" ]] && builtin source "${ZDOTDIR:-$HOME}/.zshenv"

# Report command start (with its text), command end (with exit code) and the working directory over a
# private OSC 6973, tagged with this tab's nonce. The nonce lives in an unexported variable: programs
# started from this shell never see it, so nothing they print can pass for these marks.
if [[ -o interactive && -n "${__nextterm_nonce-}" && -z "${__nextterm_hooked-}" ]]; then
  typeset -g __nextterm_hooked=1
  zmodload zsh/parameter 2>/dev/null

  __nextterm_b64() { emulate -L zsh; builtin printf '%s' "$1" | command base64 | command tr -d '\n'; }

  # `fg`, `fg %2`, `%2`: sets REPLY to the command line of the job being resumed.
  __nextterm_jobtext() {
    emulate -L zsh
    REPLY=
    local -a w=(${=1})
    local spec n k
    if [[ ${w[1]-} == fg ]]; then spec=${w[2]:-%+}
    elif [[ ${w[1]-} == %* && ${#w} -eq 1 ]]; then spec=${w[1]}
    else return; fi
    case $spec in
      (%|%%|%+) for k in ${(k)jobstates}; do [[ ${jobstates[$k]} == *:+:* ]] && n=$k; done ;;
      (%-) for k in ${(k)jobstates}; do [[ ${jobstates[$k]} == *:-:* ]] && n=$k; done ;;
      (%<->) n=${spec#%} ;;
    esac
    [[ -n $n ]] && REPLY=${jobtexts[$n]-}
  }

  __nextterm_preexec() {
    emulate -L zsh
    local line=$1 expanded=${3-$1}
    __nextterm_jobtext "$line"
    [[ -n $REPLY ]] && line=$REPLY expanded=$REPLY
    builtin printf '\033]6973;%s;cmd;%s;%s\007' "$__nextterm_nonce" "$(__nextterm_b64 "$line")" "$(__nextterm_b64 "$expanded")"
  }

  __nextterm_precmd() {
    local ret=$?  # first, before anything else changes it
    emulate -L zsh
    builtin printf '\033]6973;%s;end;%s\007' "$__nextterm_nonce" "$ret"
    builtin printf '\033]6973;%s;cwd;%s\007' "$__nextterm_nonce" "$(__nextterm_b64 "$PWD")"
    # Jobs left behind (Ctrl-Z, `&`), so closing the tab can warn before they are killed.
    local -a js
    local k
    for k in ${(k)jobstates}; do js+=("${jobtexts[$k]-} (${jobstates[$k]%%:*})"); done
    builtin printf '\033]6973;%s;jobs;%s;%s\007' "$__nextterm_nonce" "${#js}" "$(__nextterm_b64 "${(pj:\n:)js}")"
  }

  # Register in a function: the user's .zshenv may already have set options such as nounset or
  # ksh_arrays, and `emulate -L zsh` shields this code from them. Our hooks run first, so $? is still
  # the command's exit status and not another hook's.
  __nextterm_install() {
    emulate -L zsh
    typeset -ga precmd_functions preexec_functions
    precmd_functions=(__nextterm_precmd ${precmd_functions:#__nextterm_precmd})
    preexec_functions=(__nextterm_preexec ${preexec_functions:#__nextterm_preexec})
  }
  __nextterm_install
  unfunction __nextterm_install
else
  unset __nextterm_nonce
fi
"""#
}
