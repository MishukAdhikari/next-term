import Foundation

/// The history hook (see ShellHistory), written beside the integration's `.zshenv` as `history.zsh`
/// (ShellIntegration.install) and sourced at a tab's first prompt, whether Tab completion is on or off.
///
/// It is one raw literal: scripts/zsh-integration-test.py reads it from here, and ShellHistoryTests checks that its key,
/// its mark and its limits are ShellHistory's.
public enum ZshHistoryScript {
    public static let script = #"""
# Next Term: a line Next Term or an agent submits by itself stays out of zsh's history (see ShellHistory). The
# integration's first precmd sources this file, after the user's .zshrc and plugins have loaded. At each new line a
# private key is bound in every keymap and a `hist` mark says so; just before Next Term's own Return, that key names the
# line. The next line zsh adds to its history is kept out of it if it is that line to the byte, and the name is dropped
# there whatever the line was, and at each new line and prompt: so it can never hide a line typed later. Nothing here
# sets a history option or variable (it only puts back HISTFILE's export, which `fc -p` drops), writes the history file,
# starts a process, or evaluates a line.
zmodload zsh/zleparameter 2>/dev/null || return 0
builtin autoload -Uz add-zsh-hook add-zle-hook-widget

typeset -g __nextterm_hkey=$'\e[6974~'
# The line named, and whether one is (it may be empty).
typeset -g __nextterm_hline= __nextterm_hnamed=
# The line just kept out, for the integration's preexec: zsh gives preexec no typed text for a line not in its history.
typeset -g __nextterm_hran=
# Whether HISTFILE was exported when `fc -p` unset it: zsh's pop brings back its value alone, so preexec exports it again.
typeset -g __nextterm_hexport=

# The private key's widget: a kind letter, a 6-digit length and the payload, escaped as Tab completion's fields are and
# decoded with printf %b. `h` names the line about to be submitted. Anything else (a kind this version doesn't know, a
# frame that doesn't all arrive at once) is read and dropped, so it never lands on the line.
__nextterm_hkeywidget() {
  emulate -L zsh
  local kind len payload=
  __nextterm_hline= __nextterm_hnamed=
  read -t 0.5 -k 1 kind && read -t 0.5 -k 6 len || return 0
  [[ $len == <-> ]] || return 0
  (( len = 10#$len, len <= 65536 )) || return 0
  if (( len )); then read -t 0.5 -k $len payload || return 0; fi
  [[ $kind == h ]] || return 0
  builtin printf -v __nextterm_hline %b "$payload"
  __nextterm_hnamed=1
  return 0
}

# zshaddhistory: the line named is kept out the way zsh offers this hook (zshmisc): `fc -p` gives it a history list of
# its own, which zsh drops as soon as it has handled the line, the user's list and history file coming back as they
# were. So it is in neither the history (↑, zsh-autosuggestions) nor the file, not even until the next line, as a line
# kept out by status 1 alone would be, and an earlier line like it stays. Any other line goes in as it always does.
__nextterm_haddhistory() {
  emulate -L zsh
  local named=$__nextterm_hnamed line=$__nextterm_hline
  __nextterm_hline= __nextterm_hnamed=
  [[ -n $named && ${1%$'\n'} == "$line" ]] || return 0
  __nextterm_hran=$line
  [[ ${(t)HISTFILE-} == *-export* ]] && __nextterm_hexport=1
  fc -p
  return 1
}

# Before the command runs (zsh has popped `fc -p`'s list by then): HISTFILE exported again if it was, so the line kept out
# and every program after it see it as before (hstr finds the history file through it).
__nextterm_hpreexec() {
  emulate -L zsh
  [[ -n $__nextterm_hexport ]] && export HISTFILE
  __nextterm_hexport=
  return 0
}

# At each new line: the key bound in every keymap, nothing named yet, and the mark that says Next Term may name the line
# it submits now.
__nextterm_hready() {
  emulate -L zsh
  local km
  for km in ${keymaps:#.safe}; do builtin bindkey -M $km $__nextterm_hkey __nextterm_hkeywidget 2>/dev/null; done
  __nextterm_hline= __nextterm_hnamed=
  builtin printf '\033]6973;%s;hist;1\007' "$__nextterm_nonce"
  return 0
}

# At each prompt, after the other precmd hooks: nothing named outlives it, and our line hook comes back if a plugin
# replaced zle-line-init (zsh-vi-mode does, in a precmd of its own). Until it is back, no `hist` mark: Next Term names
# nothing, and the line goes into the history as before.
__nextterm_hprecmd() {
  emulate -L zsh
  __nextterm_hline= __nextterm_hnamed= __nextterm_hran=
  # A line kept out that never got to preexec (it did not parse): HISTFILE exported again here.
  __nextterm_hpreexec
  local -a list
  zstyle -g list zle-line-init widgets
  [[ ${widgets[zle-line-init]-} == user:azhw:zle-line-init && -n ${(M)list:#<->:__nextterm_hready} ]] && return 0
  # The plugin's widget stays, and runs first: ours out of the list, so the re-add keeps it as entry 0.
  [[ -n ${(M)list:#<->:__nextterm_hready} ]] && add-zle-hook-widget -d line-init __nextterm_hready
  add-zle-hook-widget line-init __nextterm_hready
  return 0
}

zle -N __nextterm_hkeywidget
zle -N __nextterm_hready
add-zsh-hook zshaddhistory __nextterm_haddhistory
add-zsh-hook preexec __nextterm_hpreexec
typeset -ga precmd_functions
precmd_functions=(${precmd_functions:#__nextterm_hprecmd} __nextterm_hprecmd)
__nextterm_hprecmd
"""#
}
