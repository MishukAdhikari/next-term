import Foundation

/// The ghost hook, written beside the integration's `.zshenv` as `ghost.zsh` (ShellIntegration.install) and sourced at a
/// local tab's first prompt, whether Tab completion and suggestions are on or off: what MCP's read_tab says is typed comes
/// from its reports too.
///
/// One raw literal with placeholders (`@NG_PREFIX@` and the rest of `values`), filled from GhostProtocol's constants so the
/// two can't drift: GhostProtocolTests checks each value, and scripts/zsh-integration-test.py fills the literal from the
/// same table.
public enum ZshGhostScript {
    public static var script: String {
        var text = template
        for (placeholder, value) in values { text = text.replacingOccurrences(of: placeholder, with: value) }
        return text
    }

    /// What each placeholder becomes, as zsh source text.
    static let values: [(String, String)] = [
        ("@NG_PREFIX@", #"\e[6975~"#),
        ("@NG_VERSION@", #"1"#),
        ("@NG_MAX_LINE@", #"2048"#),
        ("@NG_FRAME_WAIT@", #"0.5"#),
        ("@NG_MAX_PAYLOAD@", #"65536"#),
    ]

    static let template = #"""
# Next Term: the ghost hook (see GhostProtocol). The integration's first precmd sources this file, after the user's .zshrc
# and plugins have loaded, in every local tab. As the line changes it reports the line, once no key is pending; at each new
# line it says whether zsh-autosuggestions draws its suggestions here. Next Term draws its own over the terminal, never into
# the line, and puts one on the line only through its key, while the line is still the one it saw. Nothing here starts a
# process, writes a file of the user's, evaluates the line, or sets a history option.
zmodload zsh/zleparameter zsh/parameter 2>/dev/null || return 0
zmodload -F zsh/system b:sysopen b:sysseek 2>/dev/null
zmodload -F zsh/files b:zf_rm 2>/dev/null
builtin autoload -Uz add-zle-hook-widget

typeset -g __nextterm_gkey=$'@NG_PREFIX@'
# The line's number and the generation: each new line, and each change of BUFFER, CURSOR or POSTDISPLAY on it, is a new one.
typeset -gi __nextterm_gline=0 __nextterm_ggen=0
# What the last redraw saw, and whether that was reported.
typeset -g __nextterm_gbuf= __nextterm_gcur= __nextterm_gpost= __nextterm_gsent=
typeset -g __nextterm_gk= __nextterm_gid=
typeset -ga __nextterm_gf
# The keymap `main` is, read at each new line: emacs or viins (`bindkey -v`), or main when it can't be read.
typeset -g __nextterm_gmain=main
typeset -gi __nextterm_gfd=-1
# What the tab started with (the integration's NEXTTERM_GHOST), for its first line: `t`, zsh-autosuggestions' suggestions
# off, as the user chose Next Term's; `a`, the same where they are Atuin's (ZSH_AUTOSUGGEST_STRATEGY names atuin).
typeset -g __nextterm_gtake=${__nextterm_gstart-}
unset __nextterm_gstart
# This hook turned zsh-autosuggestions off (and set ZSH_AUTOSUGGEST_MANUAL_REBIND, which wasn't set before: 1), so it may
# give both back.
typeset -g __nextterm_gtook= __nextterm_grebind=

# A scratch descriptor of this hook's own (close-on-exec, its file already removed) to read what `bindkey` prints without a
# subshell, as Tab completion's hook has its own.
() {
  emulate -L zsh
  local f=${TMPDIR:-/tmp}/.nextterm-g-$$-$RANDOM$RANDOM
  sysopen -rw -o cloexec,creat,excl -m 600 -u __nextterm_gfd $f 2>/dev/null && zf_rm -f -- $f 2>/dev/null
}

# REPLY: the first line `bindkey` prints for its arguments ("" when it can't be read).
__nextterm_gbindkey() {
  emulate -L zsh
  REPLY=
  (( __nextterm_gfd >= 0 )) || return 1
  sysseek -u $__nextterm_gfd 0 && builtin bindkey "$@" >&$__nextterm_gfd 2>/dev/null &&
    sysseek -u $__nextterm_gfd 0 && IFS= read -r -u $__nextterm_gfd REPLY
}

# __nextterm_gmain: what `main` is linked to, read at each new line.
__nextterm_gmainmap() {
  emulate -L zsh
  __nextterm_gmain=main
  __nextterm_gbindkey -lL main || return 0
  [[ $REPLY == 'bindkey -A '(emacs|viins)' main' ]] && __nextterm_gmain=${${REPLY#bindkey -A }% main}
  return 0
}

# reply: each argument percent-encoded as Tab completion's fields are (every byte outside ! to ~, and % ; ,). Printable
# ASCII, nearly every line, only has its % and ; replaced, which costs far less.
__nextterm_gencall() {
  emulate -L zsh -o extendedglob +o multibyte
  if [[ ${(j::)argv} == [\ -~]# ]]; then
    reply=( "${(@)${(@)argv//\%/%25}//;/%3B}" )
  else
    reply=( "${(@)argv//(#m)[^\!-\$\&-+\--:\<-~]/%${(l:2::0:)$(( [##16] #MATCH & 255 ))}}" )
  fi
}

__nextterm_gmark() {
  emulate -L zsh
  builtin printf '\033]6973;%s;%s\007' "$__nextterm_nonce" "${(j:;:)argv}"
}

# The `ghost` mark: the hook, and the zsh-autosuggestions it sees in this shell (loaded, and on unless it was disabled), with
# ZSH_AUTOSUGGEST_STRATEGY's words, which Atuin sets for its own suggestions through it.
__nextterm_ghook() {
  emulate -L zsh
  local plugin= on=0
  if (( ${+widgets[autosuggest-fetch]} )); then
    plugin=zsh-autosuggestions
    (( ${+_ZSH_AUTOSUGGEST_DISABLED} )) || on=1
  fi
  local -a strategies
  strategies=( ${ZSH_AUTOSUGGEST_STRATEGY[@]-} )
  __nextterm_gencall "$plugin" "${(j: :)strategies}"
  __nextterm_gmark ghost @NG_VERSION@ "$reply[1]" $on "$reply[2]"
}

# The `buf` mark for the line now. BUFFER and POSTDISPLAY over @NG_MAX_LINE@ bytes go empty, flagged; CURSOR is zsh's own
# count, in characters; `main` is named as the keymap it is.
__nextterm_greport() {
  emulate -L zsh +o multibyte
  local flags= buf=$BUFFER post=$POSTDISPLAY km=${KEYMAP-}
  [[ $km == main ]] && km=$__nextterm_gmain
  (( ${#buf} > @NG_MAX_LINE@ )) && flags+=l buf=
  (( ${#post} > @NG_MAX_LINE@ )) && flags+=L post=
  (( ${REGION_ACTIVE:-0} )) && flags+=r
  (( ${ISEARCHMATCH_ACTIVE:-0} )) && flags+=i
  __nextterm_gencall "$km" "${CONTEXT-}" "$buf" "$post"
  __nextterm_gmark buf $__nextterm_gline $__nextterm_ggen $CURSOR "$reply[1]" "$reply[2]" "$flags" "$reply[3]" "$reply[4]"
  __nextterm_gsent=1
}

# zle-line-pre-redraw: a change of the line is a new generation, reported once no key is pending, so keys that came in one
# write give one report, for the line after the last of them. A redraw that changed nothing says nothing.
__nextterm_gredraw() {
  emulate -L zsh
  if [[ $BUFFER != "$__nextterm_gbuf" || $CURSOR != "$__nextterm_gcur" || $POSTDISPLAY != "$__nextterm_gpost" ]]; then
    __nextterm_gbuf=$BUFFER __nextterm_gcur=$CURSOR __nextterm_gpost=$POSTDISPLAY __nextterm_gsent=
    (( __nextterm_ggen = (__nextterm_ggen + 1) % 1000000000 ))
  fi
  [[ -z $__nextterm_gsent ]] || return 0
  (( PENDING || ${KEYS_QUEUED_COUNT:-0} )) && return 0
  __nextterm_greport
  return 0
}

# zsh-autosuggestions' async suggestion comes from a `zle -F` handler through its autosuggest-suggest widget, whose redraw
# (zle -R) runs no zle-line-pre-redraw: while that widget is the plugin's own, it reports once the plugin's function, called
# as it was, has run. Nothing else of the plugin's changes.
__nextterm_gsuggest() {
  _zsh_autosuggest_widget_suggest "$@"
  local ret=$?
  __nextterm_gredraw
  return $ret
}

# zsh-autosuggestions' suggestions off in this shell (`t`: Next Term's show instead), and with them its rebinding of every
# widget at each prompt, about 20 ms (ZSH_AUTOSUGGEST_MANUAL_REBIND, which its precmd reads to drop itself); or (`g`) both
# given back as they were, where this hook turned them off. Only as the user chose, through Next Term's key or the tab's
# start; never a file of theirs.
__nextterm_gtakeover() {
  emulate -L zsh
  (( ${+widgets[autosuggest-fetch]} )) || return 0
  if [[ $1 == t ]]; then
    (( ${+_ZSH_AUTOSUGGEST_DISABLED} )) && return 0
    zle autosuggest-disable
    __nextterm_gtook=1 __nextterm_grebind=
    if (( ! ${+ZSH_AUTOSUGGEST_MANUAL_REBIND} )); then
      typeset -g ZSH_AUTOSUGGEST_MANUAL_REBIND=1
      __nextterm_grebind=1
    fi
  elif [[ $1 == g && -n $__nextterm_gtook ]]; then
    __nextterm_gtook=
    (( ${+_ZSH_AUTOSUGGEST_DISABLED} )) && zle autosuggest-enable
    if [[ -n $__nextterm_grebind ]]; then
      __nextterm_grebind=
      unset ZSH_AUTOSUGGEST_MANUAL_REBIND
      # Its precmd dropped itself once the variable was set: back, rebinding at each prompt as before.
      (( ${+functions[_zsh_autosuggest_start]} )) && precmd_functions=(${precmd_functions:#_zsh_autosuggest_start} _zsh_autosuggest_start)
    fi
  fi
  return 0
}

# The tab's start (__nextterm_gtake), at its first line: zsh-autosuggestions off where the user chose Next Term's for it,
# Atuin's or its own.
__nextterm_gstarttake() {
  emulate -L zsh
  local take=$__nextterm_gtake
  __nextterm_gtake=
  (( ${+widgets[autosuggest-fetch]} )) || return 0
  if [[ " ${ZSH_AUTOSUGGEST_STRATEGY[*]-} " == *" atuin "* ]]; then
    [[ $take == *a* ]] && __nextterm_gtakeover t
  else
    [[ $take == *t* ]] && __nextterm_gtakeover t
  fi
  return 0
}

# zle-line-init: a new line and a new generation; the `ghost` mark, then the line as it starts (empty, mostly), so an empty
# prompt has a generation of its own.
__nextterm_ginit() {
  emulate -L zsh
  (( __nextterm_gline = (__nextterm_gline + 1) % 1000000000, __nextterm_ggen = (__nextterm_ggen + 1) % 1000000000 ))
  __nextterm_gmainmap
  [[ -n $__nextterm_gtake ]] && __nextterm_gstarttake
  __nextterm_ghook
  __nextterm_gbuf=$BUFFER __nextterm_gcur=$CURSOR __nextterm_gpost=$POSTDISPLAY
  __nextterm_greport
  return 0
}

# After the private key: a kind letter, a 6-digit id, a 6-digit length and the payload, its fields split by `;` and decoded
# with printf %b, as Tab completion's frames are. False if they don't all arrive at once or are malformed.
__nextterm_gframe() {
  emulate -L zsh
  local kind id len payload= f v
  __nextterm_gk= __nextterm_gid=
  __nextterm_gf=()
  read -t @NG_FRAME_WAIT@ -k 1 kind && read -t @NG_FRAME_WAIT@ -k 6 id && read -t @NG_FRAME_WAIT@ -k 6 len || return 1
  [[ $kind == [a-z] && $id == <-> && $len == <-> ]] || return 1
  (( len = 10#$len, len <= @NG_MAX_PAYLOAD@ )) || return 1
  if (( len )); then read -t @NG_FRAME_WAIT@ -k $len payload || return 1; fi
  __nextterm_gk=$kind __nextterm_gid=$id
  for f in "${(@s:;:)payload}"; do
    builtin printf -v v %b "$f"
    __nextterm_gf+=( "$v" )
  done
  return 0
}

# True when the keys $1 do nothing in this keymap, only move the cursor on, or take zsh-autosuggestions' suggestion (which
# Next Term's stands in for): what an accept may take them for. No keys at all (⌥→ without Option as Meta) do nothing. The
# binding is read here, when a key accepts, so a prompt costs nothing.
__nextterm_gmotion() {
  emulate -L zsh
  [[ -n $1 ]] || return 0
  __nextterm_gbindkey -M ${KEYMAP:-main} "$1" || return 1
  [[ ${REPLY##* } == (.|)(undefined-key|forward-char|vi-forward-char|end-of-line|vi-end-of-line|vi-add-eol|forward-word|emacs-forward-word|vi-forward-word|vi-forward-blank-word|autosuggest-accept|autosuggest-partial-accept) ]]
}

# An accept (a): the line Next Term saw becomes the new line, the cursor at its end, while the generation (the frame's id),
# the line and the cursor are as Next Term saw them and the key would only move the cursor (__nextterm_gmotion). Otherwise
# the key's own bytes go back to zsh, which does what that key does; with none, nothing happens. Nothing runs either way.
__nextterm_gaccept() {
  emulate -L zsh
  (( ${#__nextterm_gf} == 3 )) || return 0
  local seen=$__nextterm_gf[1] new=$__nextterm_gf[2] key=$__nextterm_gf[3]
  if (( 10#$__nextterm_gid == __nextterm_ggen % 1000000 && CURSOR == ${#BUFFER} )) && [[ $BUFFER == "$seen" ]] && __nextterm_gmotion "$key"; then
    BUFFER=$new
    CURSOR=${#BUFFER}
  elif [[ -n $key ]]; then
    zle -U "$key"
  fi
  return 0
}

# The private key's widget: what Next Term sent, by kind. Anything else (a kind this version doesn't know, a frame that
# doesn't all arrive at once) is read and dropped, so it never lands on the line.
__nextterm_gkeywidget() {
  emulate -L zsh
  __nextterm_gframe || return 0
  local before=$BUFFER
  case $__nextterm_gk in
    (a) __nextterm_gaccept ;;
    (o) __nextterm_gtakeover ${__nextterm_gf[1]-}
        __nextterm_ghook
        __nextterm_greport ;;
  esac
  # zsh-autosuggestions never wraps this widget: a line changed here is asked for a suggestion that fits it, as Tab
  # completion's widget does.
  if [[ $BUFFER != $before ]] && (( ${+widgets[autosuggest-fetch]} && ! ${+_ZSH_AUTOSUGGEST_DISABLED} )); then
    zle autosuggest-fetch
  fi
  return 0
}

# At each prompt: the private key bound in every keymap, our line hooks back if a plugin replaced them, and
# zsh-autosuggestions' suggest widget reporting (__nextterm_gsuggest) if the plugin defined it again.
__nextterm_gprecmd() {
  emulate -L zsh
  local km hook fn
  local -a list
  for km in ${keymaps:#.safe}; do builtin bindkey -M $km $__nextterm_gkey __nextterm_gkeywidget 2>/dev/null; done
  for hook fn in line-init __nextterm_ginit line-pre-redraw __nextterm_gredraw; do
    zstyle -g list zle-$hook widgets
    [[ ${widgets[zle-$hook]-} == user:azhw:zle-$hook && -n ${(M)list:#<->:$fn} ]] && continue
    add-zle-hook-widget $hook $fn
  done
  [[ ${widgets[autosuggest-suggest]-} == user:_zsh_autosuggest_widget_suggest ]] && zle -N autosuggest-suggest __nextterm_gsuggest
  return 0
}

zle -N __nextterm_gkeywidget
zle -N __nextterm_ginit
zle -N __nextterm_gredraw
typeset -ga precmd_functions
precmd_functions=(${precmd_functions:#__nextterm_gprecmd} __nextterm_gprecmd)
__nextterm_gprecmd
"""#
}
