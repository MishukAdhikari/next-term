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
    ]

    static let template = #"""
# Next Term: the ghost hook (see GhostProtocol). The integration's first precmd sources this file, after the user's .zshrc
# and plugins have loaded, in every local tab. As the line changes it reports the line, once no key is pending; at each new
# line it says whether zsh-autosuggestions draws its suggestions here. Next Term draws its own over the terminal, never into
# the line. Nothing here starts a process, writes a file, evaluates the line, or sets a history option.
zmodload zsh/zleparameter zsh/parameter 2>/dev/null || return 0
builtin autoload -Uz add-zle-hook-widget

typeset -g __nextterm_gkey=$'@NG_PREFIX@'
# The line's number and the generation: each new line, and each change of BUFFER, CURSOR or POSTDISPLAY on it, is a new one.
typeset -gi __nextterm_gline=0 __nextterm_ggen=0
# What the last redraw saw, and whether that was reported.
typeset -g __nextterm_gbuf= __nextterm_gcur= __nextterm_gpost= __nextterm_gsent=
typeset -g __nextterm_gk= __nextterm_gid=
typeset -ga __nextterm_gf

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
# count, in characters.
__nextterm_greport() {
  emulate -L zsh +o multibyte
  local flags= buf=$BUFFER post=$POSTDISPLAY
  (( ${#buf} > @NG_MAX_LINE@ )) && flags+=l buf=
  (( ${#post} > @NG_MAX_LINE@ )) && flags+=L post=
  (( ${REGION_ACTIVE:-0} )) && flags+=r
  (( ${ISEARCHMATCH_ACTIVE:-0} )) && flags+=i
  __nextterm_gencall "${KEYMAP-}" "${CONTEXT-}" "$buf" "$post"
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

# zle-line-init: a new line and a new generation; the `ghost` mark, then the line as it starts (empty, mostly), so an empty
# prompt has a generation of its own.
__nextterm_ginit() {
  emulate -L zsh
  (( __nextterm_gline = (__nextterm_gline + 1) % 1000000000, __nextterm_ggen = (__nextterm_ggen + 1) % 1000000000 ))
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
  (( len = 10#$len, len <= 65536 )) || return 1
  if (( len )); then read -t @NG_FRAME_WAIT@ -k $len payload || return 1; fi
  __nextterm_gk=$kind __nextterm_gid=$id
  for f in "${(@s:;:)payload}"; do
    builtin printf -v v %b "$f"
    __nextterm_gf+=( "$v" )
  done
  return 0
}

# The private key's widget: what Next Term sent, by kind. Anything else (a kind this version doesn't know, a frame that
# doesn't all arrive at once) is read and dropped, so it never lands on the line.
__nextterm_gkeywidget() {
  emulate -L zsh
  __nextterm_gframe || return 0
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
