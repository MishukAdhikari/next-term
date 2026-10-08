import Foundation

/// Tab completion's hook on a server, only where the user allowed it (RemoteCompletionConsent), and only for a login
/// shell that is zsh: the same hook as on the Mac (ZshCompletionScript), in `~/.cache/next-term/completion/`,
/// started by Next Term's own launch command (RemoteShell.tabScript), so none of the user's files change. Removing
/// it is deleting that folder. bash's hook isn't here: its scope waits for the owner's word.
///
/// The files: `completion.zsh` (the hook), `zsh/.zshenv` (hands over to the user's own config, then loads the hook
/// at the first prompt), `start` (the launch command), `nonce` (0600, read at each prompt) and `version`. The nonce
/// arrives on the script's stdin, never on a command line.
///
/// The hook sends completion marks only (arm, tab, comp, done, line), never cmd, end, cwd or jobs: the tab's status
/// keeps coming from the status checks.
public enum RemoteCompletionHook {
    public static let version = 1
    /// The folder on the server, as one sh word.
    static let folder = "\"$HOME/.cache/next-term/completion\""
    /// How long a Tab waits for Next Term's answer when its key doesn't say (Next Term's Tab keys to a server do).
    static let firstWait = "0.6"

    /// `.zshenv` for the hooked zsh, in the hook's `zsh/` folder.
    public static let zshenv = #"""
# Next Term: Tab completion on this server, which you allowed from Next Term on your Mac. Remove it there (New
# Remote Tab… › Tab completion › Remove), or delete the folder this file is in: the next tab starts as before.
# Next Term's launch command starts zsh with ZDOTDIR here. Put your ZDOTDIR back first, so your own .zshenv,
# .zprofile, .zshrc and .zlogin load from where they always do.
typeset -g __nextterm_cdir="${${(%):-%x}:A:h:h}"
if [[ -n "${NEXTTERM_USER_ZDOTDIR-}" ]]; then
  ZDOTDIR="$NEXTTERM_USER_ZDOTDIR"
else
  unset ZDOTDIR
fi
unset NEXTTERM_USER_ZDOTDIR

[[ -f "${ZDOTDIR:-$HOME}/.zshenv" ]] && builtin source "${ZDOTDIR:-$HOME}/.zshenv"

# The hook loads at the first prompt, after your .zshrc and plugins, in an interactive shell. Inside Next Term's own
# tmux its marks go through tmux's passthrough; inside any other tmux it stays silent. Only Tab completion's marks
# are sent: never the commands you run.
if [[ -o interactive && -z "${__nextterm_cloaded-}" ]]; then
  typeset -g __nextterm_cloaded=1 __nextterm_nonce= __nextterm_cwrap= __nextterm_cwait=@NT_FIRST_WAIT@
  typeset -g __nextterm_cscratch=$__nextterm_cdir
  if [[ -n "${TMUX-}" ]]; then
    if [[ "${${TMUX%%,*}:t}" == nextterm ]]; then __nextterm_cwrap=1; else __nextterm_cdir=; fi
  fi
  # At each prompt: the nonce (Remove, or Turn On Again, on the Mac makes a new one), then the hook, once.
  __nextterm_cserver() {
    emulate -L zsh
    local n=
    [[ -n $__nextterm_cdir && -r $__nextterm_cdir/nonce ]] && IFS= read -r n < $__nextterm_cdir/nonce
    __nextterm_nonce=$n
    if [[ -n $n ]] && (( ! ${+functions[__nextterm_cprecmd]} )) && [[ -r $__nextterm_cdir/completion.zsh ]]; then
      builtin source $__nextterm_cdir/completion.zsh
    fi
    return 0
  }
  () {
    emulate -L zsh
    typeset -ga precmd_functions
    precmd_functions=(__nextterm_cserver ${precmd_functions:#__nextterm_cserver})
  }
fi
"""#.replacingOccurrences(of: "@NT_FIRST_WAIT@", with: firstWait)

    /// The launch command: the user's login shell, with the hook when it is zsh and the hook's files are there.
    public static let start = #"""
#!/bin/sh
# Next Term: starts your login shell for a tab, with Tab completion's hook when your shell is zsh (see
# completion.zsh beside this file). Without the hook's files, your shell starts as it always does.
H="$HOME/.cache/next-term/completion"
case "${SHELL##*/}" in
  zsh)
    if [ -r "$H/completion.zsh" ] && [ -r "$H/zsh/.zshenv" ]; then
      NEXTTERM_USER_ZDOTDIR="${ZDOTDIR-}"
      ZDOTDIR="$H/zsh"
      export NEXTTERM_USER_ZDOTDIR ZDOTDIR
    fi ;;
esac
exec "${SHELL:-/bin/sh}" -l
"""#

    /// The private key, as a sh word that makes its bytes (tmux takes it from the command line as it is).
    static let keyWord = "\"$(printf '\\033[6973~')\""

    /// Next Term's own tmux settings on a hooked host: the private key is a key tmux knows (user-keys), and goes on
    /// to the pane as it came.
    static let tmuxConfig = RemoteShell.tmuxConfig + """

        set -sq user-keys[0] "\\e[6973~"
        bind -n User0 send-keys -l "\\e[6973~"
        """

    /// The same, on a tmux server that is already running (tmux reads its config only as it starts). Needs T.
    static let tmuxLive = """
        if [ -n "$T" ]; then
          "$T" -L nextterm set -sq 'user-keys[0]' \(keyWord) 2>/dev/null
          "$T" -L nextterm bind -n User0 send-keys -l \(keyWord) 2>/dev/null
        fi
        """

    /// A plain tab's launch on a hooked host: the hook's start command, or the login shell as before when its files
    /// are gone.
    static let offLaunch = """
        [ -x \(folder)/start ] && exec \(folder)/start
        """ + "\n" + RemoteShell.plainShell(nil)

    /// A tmux tab's launch on a hooked host: the user key on the live server, then a new session runs the start
    /// command (a session that is already running keeps its shell).
    static func tmuxLaunch(session: String) -> String {
        let name = RemoteShell.quote(RemoteShell.safeName(session))
        let open = "exec \"$T\" -L nextterm -f \"$C/tmux.conf\" new-session -A -s \(name) -c \"$PWD\""
        return [
            tmuxLive,
            "if [ -x \(folder)/start ]; then",
            "  \(open) 'exec \"$HOME/.cache/next-term/completion/start\"'",
            "fi",
            open,
        ].joined(separator: "\n")
    }

    /// What the scripts below say.
    public enum Report: Equatable, Sendable {
        /// Written, at this version.
        case installed
        /// Gone (Remove).
        case removed
        /// There, at this version (nil: unknown).
        case present(version: Int?)
        /// Not there: someone deleted it.
        case missing
        /// The login shell is another one: no hook for it.
        case otherShell(String)
        /// It could not be written (a full disk, a home that can't be written).
        case failed(String)
    }

    public static func parse(_ output: String) -> Report? {
        guard let lines = RemoteShell.payload(output) else { return nil }
        for line in lines {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            switch fields.first {
            case "installed": return .installed
            case "removed": return .removed
            case "missing": return .missing
            case "present": return .present(version: fields.count > 1 ? Int(fields[1]) : nil)
            case "shell": return .otherShell(fields.count > 1 ? fields[1] : "")
            case "failed": return .failed(fields.count > 1 ? fields[1] : "")
            default: continue
            }
        }
        return nil
    }

    /// Writes the hook, with the nonce read from stdin; or says why not. A hook that fails half-way is taken away
    /// again, so nothing is left behind.
    public static var installScript: String {
        let files: [(name: String, text: String, mode: String)] = [
            ("completion.zsh", ZshCompletionScript.script, "600"),
            ("zsh/.zshenv", zshenv, "600"),
            ("start", start, "700"),
            ("version", "\(version)\n", "600"),
        ]
        var lines = [
            "umask 077",
            "C=\(RemoteShell.cacheDir); H=\(folder)",
            "printf '\\n%s\\n' \(RemoteShell.quote(RemoteShell.marker))",
            "s=${SHELL##*/}",
            "if [ \"$s\" != zsh ]; then printf 'shell\\t%s\\n' \"$(printf '%s' \"$s\" | tr -cd 'A-Za-z0-9._-')\"; exit 0; fi",
            "IFS= read -r n; n=$(printf '%s' \"$n\" | tr -cd '0-9a-f')",
            "[ -n \"$n\" ] || { printf 'failed\\t%s\\n' 'no nonce'; exit 0; }",
            "nt_fail() { rm -rf \"$H\"; printf 'failed\\t%s\\n' \"$1\"; exit 0; }",
            "mkdir -p \"$H/zsh\" 2>/dev/null && chmod 700 \"$H\" \"$H/zsh\" 2>/dev/null || nt_fail 'the folder could not be made'",
        ]
        for file in files {
            let path = "\"$H/\(file.name)\""
            let temporary = "\"$H/\(file.name).new\""
            lines.append("printf '%s' \(RemoteShell.quote(file.text)) > \(temporary) 2>/dev/null && chmod \(file.mode) \(temporary) && mv -f \(temporary) \(path) || nt_fail \(RemoteShell.quote(file.name))")
        }
        lines += [
            "printf '%s\\n' \"$n\" > \"$H/nonce.new\" 2>/dev/null && chmod 600 \"$H/nonce.new\" && mv -f \"$H/nonce.new\" \"$H/nonce\" || nt_fail nonce",
            RemoteShell.findTmux,
            tmuxLive,
            "printf 'installed\\t\(version)\\n'",
        ]
        return lines.joined(separator: "\n")
    }

    /// Deletes the hook's folder, and takes the user key off Next Term's own tmux server and out of its settings.
    public static var removeScript: String {
        [
            "C=\(RemoteShell.cacheDir); H=\(folder)",
            "rm -rf \"$H\"",
            RemoteShell.findTmux,
            "if [ -n \"$T\" ]; then \"$T\" -L nextterm set -su 'user-keys' 2>/dev/null; \"$T\" -L nextterm unbind -n User0 2>/dev/null; fi",
            "if [ -f \"$C/tmux.conf\" ] && grep -q 6973 \"$C/tmux.conf\" 2>/dev/null; then printf '%s\\n' \(RemoteShell.quote(RemoteShell.tmuxConfig)) > \"$C/tmux.conf\"; fi",
            "printf '\\n%s\\n' \(RemoteShell.quote(RemoteShell.marker))",
            "[ -e \"$H\" ] && printf 'failed\\t%s\\n' 'the folder is still there' || printf 'removed\\n'",
        ].joined(separator: "\n")
    }

    /// Whether the hook is there, and at which version. Writes nothing.
    public static var checkScript: String {
        [
            "H=\(folder)",
            "printf '\\n%s\\n' \(RemoteShell.quote(RemoteShell.marker))",
            "if [ -r \"$H/completion.zsh\" ] && [ -r \"$H/zsh/.zshenv\" ] && [ -x \"$H/start\" ] && [ -r \"$H/nonce\" ]; then",
            "  printf 'present\\t%s\\n' \"$(tr -cd '0-9' < \"$H/version\" 2>/dev/null)\"",
            "else",
            "  printf 'missing\\n'",
            "fi",
        ].joined(separator: "\n")
    }
}
