import Foundation

/// Tab completion's zsh hook, written beside the integration's `.zshenv` as `completion.zsh`
/// (ShellIntegration.install) and sourced at a tab's first prompt when Tab completion is on.
///
/// The hook is one raw literal with placeholders (`@NT_PREFIX@` and the rest of `values`), filled from
/// CompletionProtocol's constants so the two can't drift: CompletionProtocolTests checks each value, and
/// scripts/zsh-integration-test.py fills the literal from the same table.
public enum ZshCompletionScript {
    public static var script: String {
        var text = template
        for (placeholder, value) in values { text = text.replacingOccurrences(of: placeholder, with: value) }
        return text
    }

    /// What each placeholder becomes, as zsh source text.
    static let values: [(String, String)] = [
        ("@NT_PREFIX@", #"\e[6973~"#),
        ("@NT_VERSION@", #"1"#),
        ("@NT_WAIT@", #"0.15"#),
        ("@NT_MAX_LINE@", #"16384"#),
    ]

    static let template = #"""
# Next Term: Tab completion (see CompletionProtocol). The integration's first precmd sources this file,
# after the user's .zshrc and plugins have loaded, in tabs where Tab completion was on when the shell started.
# ^I keeps the user's own binding: Next Term turns a real Tab into a private key, bound here in every keymap,
# and sends it only while the last `arm` mark said this shell can take it. Nothing here starts a process,
# evaluates the line, or writes a file of the user's.
zmodload zsh/zleparameter zsh/parameter zsh/datetime 2>/dev/null || return 0
zmodload -F zsh/system b:sysopen b:sysseek 2>/dev/null
zmodload -F zsh/files b:zf_rm 2>/dev/null
builtin autoload -Uz add-zle-hook-widget

typeset -g __nextterm_ckey=$'@NT_PREFIX@'
typeset -gi __nextterm_cfd=-1 __nextterm_cquiet=0
typeset -g __nextterm_copen= __nextterm_cpath= __nextterm_cbase= __nextterm_crbuf= __nextterm_cword=
typeset -g __nextterm_ck= __nextterm_cid=
typeset -g __nextterm_cisearch=
typeset -ga __nextterm_cf __nextterm_cwords

# A scratch descriptor (close-on-exec, its file already removed) to read what `bindkey` prints without a
# subshell.
() {
  emulate -L zsh
  local f=${TMPDIR:-/tmp}/.nextterm-$$-$RANDOM$RANDOM
  sysopen -rw -o cloexec,creat,excl -m 600 -u __nextterm_cfd $f 2>/dev/null && zf_rm -f -- $f 2>/dev/null
}

# REPLY: $1 percent-encoded (every byte outside ! to ~, and % ; , which the marks use as separators).
__nextterm_cenc() {
  emulate -L zsh -o extendedglob +o multibyte
  REPLY=${1//(#m)[^\!-\$\&-+\--:\<-~]/%${(l:2::0:)$(( [##16] #MATCH & 255 ))}}
}

# reply: each argument percent-encoded, in one expansion.
__nextterm_cencall() {
  emulate -L zsh -o extendedglob +o multibyte
  reply=( "${(@)argv//(#m)[^\!-\$\&-+\--:\<-~]/%${(l:2::0:)$(( [##16] #MATCH & 255 ))}}" )
}

__nextterm_cmark() {
  emulate -L zsh
  builtin printf '\033]6973;%s;%s\007' "$__nextterm_nonce" "${(j:;:)argv}"
}

__nextterm_cdone() { __nextterm_cmark done $1 $2; }

# REPLY: the widget keymap $1 runs for the keys $2 ("" when it can't be read).
__nextterm_cbound() {
  emulate -L zsh
  REPLY=
  (( __nextterm_cfd >= 0 )) || return 1
  local line
  sysseek -u $__nextterm_cfd 0 && builtin bindkey -M "$1" "$2" >&$__nextterm_cfd 2>/dev/null &&
    sysseek -u $__nextterm_cfd 0 && IFS= read -r -u $__nextterm_cfd line || return 1
  REPLY=${line#* }
}

# What this shell can take, at each new line and keymap change: the keymap, the context, whether the private
# key is bound here, whether zsh's completion system is loaded, what ^I runs, the plugins that own Tab or
# list as you type, and whether zsh-autocomplete's list is quieted.
__nextterm_carm() {
  emulate -L zsh
  local km=${1:-${KEYMAP:-main}} bound=0 compsys=0 widget= plugins=
  __nextterm_cbound $km $__nextterm_ckey && [[ $REPLY == __nextterm_ckeywidget ]] && bound=1
  __nextterm_cbound $km '^I' && widget=${REPLY:0:64}
  (( ${+functions[compdef]} && ${+functions[_main_complete]} )) && compsys=1
  (( ${+functions[.autocomplete:async:complete]} )) && plugins+=' autocomplete'
  (( ${+widgets[fzf-tab-complete]} )) && plugins+=' fzf-tab'
  (( ${+widgets[fzf-completion]} )) && plugins+=' fzf'
  __nextterm_cencall "$km" "${CONTEXT-}" "$widget" "${${widgets[$widget]-}:0:128}" "${plugins# }"
  __nextterm_cmark arm @NT_VERSION@ "$reply[1]" "$reply[2]" $bound $compsys "$reply[3]" "$reply[4]" "$reply[5]" $__nextterm_cquiet
  return 0
}

__nextterm_carmhook() { __nextterm_cisearch=; __nextterm_carm; return 0; }

# Incremental search takes keys of its own: Tab is plain there until it ends.
__nextterm_cisearchhook() {
  [[ -n $__nextterm_cisearch ]] && return 0
  __nextterm_cisearch=1
  __nextterm_carm isearch
  return 0
}

__nextterm_cisearchexit() { __nextterm_cisearch=; __nextterm_carm; return 0; }

# After the private key: a kind letter, a 6-digit id, a 6-digit length and the payload, its fields split by
# `;` and decoded with printf %b. False if they don't all arrive at once or are malformed.
__nextterm_cframe() {
  emulate -L zsh
  local kind id len payload= f v
  __nextterm_ck= __nextterm_cid=
  __nextterm_cf=()
  read -t 0.5 -k 1 kind && read -t 0.5 -k 6 id && read -t 0.5 -k 6 len || return 1
  [[ $kind == [a-z] && $id == <-> && $len == <-> ]] || return 1
  (( len = 10#$len, len <= 65536 )) || return 1
  if (( len )); then read -t 0.5 -k $len payload || return 1; fi
  __nextterm_ck=$kind __nextterm_cid=$id
  for f in "${(@s:;:)payload}"; do
    builtin printf -v v %b "$f"
    __nextterm_cf+=( "$v" )
  done
  return 0
}

# The private key's widget: what Next Term sent, by kind. Anything else (a late answer, a stale id, a kind
# this version doesn't know) is read and dropped, so it never lands on the line.
__nextterm_ckeywidget() {
  emulate -L zsh -o extendedglob
  __nextterm_cframe || return 0
  case $__nextterm_ck in
    (t) __nextterm_ctab $__nextterm_cid ;;
    (k) [[ $__nextterm_cid == $__nextterm_copen ]] && __nextterm_ctake ;;
  esac
  return 0
}

# The word before the cursor, as typed: the last of zsh's own words for the command so far ("" after a blank).
__nextterm_cwordnow() {
  emulate -L zsh
  local line=$PREBUFFER$LBUFFER
  __nextterm_cwords=( ${(z)line} )
  __nextterm_cword=
  local last=${__nextterm_cwords[-1]-}
  [[ -n $last && $LBUFFER == *"$last" ]] && __nextterm_cword=$last
}

# Where Next Term steps back before asking: zsh's own Tab is the right one, or the word could run code.
__nextterm_cplain() {
  emulate -L zsh -o extendedglob
  [[ $LBUFFER == *[^[:blank:]]* ]] || return 0
  [[ -z $RBUFFER || $RBUFFER == [[:space:]]* ]] || return 0
  [[ $CONTEXT == cont && $PREBUFFER == *'<<'* ]] && return 0
  () { emulate -L zsh +o multibyte; (( ${#PREBUFFER} + 2 * ${#LBUFFER} + ${#RBUFFER} <= @NT_MAX_LINE@ )); } || return 0
  __nextterm_cwordnow
  [[ -n $__nextterm_cword || $LBUFFER == *[[:blank:]] ]] || return 0
  [[ $__nextterm_cword == *('$('|'`'|'<('|'>('|'=(')* ]] && return 0
  return 1
}

# A real Tab, sent as the private key with Next Term's id.
__nextterm_ctab() {
  emulate -L zsh -o extendedglob
  local id=$1
  __nextterm_cclose
  if [[ $KEYMAP != (main|emacs|viins) || $CONTEXT != (start|cont) ]] || __nextterm_cplain; then
    __nextterm_cdone $id native
    zle -U $'\t'
  elif (( ${+functions[compdef]} && ${+functions[_main_complete]} )); then
    # With zsh's completion system loaded, its own Tab answers for now.
    __nextterm_cdone $id native
    zle -U $'\t'
  else
    __nextterm_cengine $id
  fi
  return 0
}

# Next Term's own engine: report the line, then wait briefly for the answer. No answer in time: zsh's own Tab.
__nextterm_cengine() {
  emulate -L zsh -o extendedglob
  local id=$1 head= resolved= name
  if [[ $__nextterm_cword == '~/'* && -n $HOME ]]; then
    head='~/' resolved=$HOME/
  elif [[ $__nextterm_cword == (#b)'$'([A-Za-z_][A-Za-z0-9_]#)/* ]]; then
    name=$match[1]
    if [[ ${(Pt)name-} == scalar* && -n ${(P)name-} ]]; then head="\$$name/" resolved=${(P)name}/; fi
  fi
  __nextterm_cencall "$PWD" "$LBUFFER" "$RBUFFER" "$PREBUFFER" "$__nextterm_cword" "${(Q)__nextterm_cword}" "$head" "$resolved"
  local -a fields=( "${reply[@]}" )
  __nextterm_cencall "${__nextterm_cwords[@]}"
  __nextterm_cmark tab $id "${fields[1]}" "${fields[2]}" "${fields[3]}" "${fields[4]}" "${(j: :)reply}" "${fields[5]}" "${fields[6]}" "${fields[7]}" "${fields[8]}"
  local -F deadline=$(( EPOCHREALTIME + @NT_WAIT@ )) left
  local c rest
  while true; do
    (( left = deadline - EPOCHREALTIME ))
    if (( left <= 0 )) || ! read -t $left -k 1 c; then
      __nextterm_cdone $id native
      zle -U $'\t'
      return 0
    fi
    rest=
    [[ $c == $'\e' ]] && read -t 0.5 -k $(( ${#__nextterm_ckey} - 1 )) rest
    if [[ $c$rest != $__nextterm_ckey ]]; then
      # Not an answer: the keys go back to the line, after zsh's own Tab.
      __nextterm_cdone $id native
      zle -U $'\t'$c$rest
      return 0
    fi
    if ! __nextterm_cframe; then
      __nextterm_cdone $id native
      zle -U $'\t'
      return 0
    fi
    [[ $__nextterm_ck == a && $__nextterm_cid == $id ]] && break
  done
  case ${__nextterm_cf[1]-} in
    (i) LBUFFER=${LBUFFER:0:$(( ${#LBUFFER} - ${#__nextterm_cword} ))}${__nextterm_cf[2]-} ;;
    (o) __nextterm_copenlist $id e ;;
    (*) zle -U $'\t' ;;
  esac
  return 0
}

# A list is open for `id`: its word is reported as the line changes, until the cursor leaves it.
__nextterm_copenlist() {
  __nextterm_copen=$1 __nextterm_cpath=$2
  __nextterm_cbase=${LBUFFER:0:$(( ${#LBUFFER} - ${#__nextterm_cword} ))}
  __nextterm_crbuf=$RBUFFER
  __nextterm_cline force
}

__nextterm_cclose() {
  __nextterm_copen= __nextterm_cpath= __nextterm_cbase= __nextterm_crbuf=
}

# The word now, and whether the cursor left it. Sent only while a list is open, and only when it changed.
__nextterm_cline() {
  emulate -L zsh -o extendedglob
  local id=$__nextterm_copen rest= left=0
  [[ -n $id ]] || return 0
  if [[ $RBUFFER != $__nextterm_crbuf || ${LBUFFER:0:${#__nextterm_cbase}} != $__nextterm_cbase ]]; then
    left=1
  else
    rest=${LBUFFER:${#__nextterm_cbase}}
    local -a w=( ${(z)rest} )
    (( ${#w} <= 1 )) && [[ $rest == "${w[1]-}" ]] || left=1
  fi
  if (( left )); then
    __nextterm_cmark line $id 1
    __nextterm_cclose
    return 0
  fi
  [[ $1 != force && $rest == $__nextterm_cword ]] && return 0
  __nextterm_cword=$rest
  __nextterm_cencall "$rest" "${(Q)rest}"
  __nextterm_cmark line $id 0 "$reply[1]" "$reply[2]"
}

__nextterm_credraw() { [[ -n $__nextterm_copen ]] && __nextterm_cline; return 0; }

__nextterm_cfinish() {
  [[ -n $__nextterm_copen ]] && __nextterm_cmark line $__nextterm_copen 1
  __nextterm_cclose
  return 0
}

# A row was chosen (or the list closed), for the open id.
__nextterm_ctake() {
  emulate -L zsh -o extendedglob
  local how=${__nextterm_cf[1]-} old=${__nextterm_cf[2]-}
  local same=0
  [[ $LBUFFER == "$__nextterm_cbase$old" && $RBUFFER == "$__nextterm_crbuf" ]] && same=1
  case $how in
    (w) # Next Term's own: the new word, quoted by Next Term.
      if (( same )); then LBUFFER=$__nextterm_cbase${__nextterm_cf[3]-}; else zle beep; fi ;;
  esac
  __nextterm_cclose
  return 0
}

# At each prompt: the private key bound in every keymap, and our line hooks back if a plugin replaced them.
__nextterm_cprecmd() {
  emulate -L zsh
  local km hook fn
  local -a list
  for km in ${keymaps:#.safe}; do builtin bindkey -M $km $__nextterm_ckey __nextterm_ckeywidget 2>/dev/null; done
  for hook fn in line-init __nextterm_carmhook keymap-select __nextterm_carmhook line-pre-redraw __nextterm_credraw \
                 line-finish __nextterm_cfinish isearch-update __nextterm_cisearchhook isearch-exit __nextterm_cisearchexit; do
    zstyle -g list zle-$hook widgets
    [[ ${widgets[zle-$hook]-} == user:azhw:zle-$hook && -n ${(M)list:#<->:$fn} ]] && continue
    add-zle-hook-widget $hook $fn
  done
  return 0
}

zle -N __nextterm_ckeywidget
zle -N __nextterm_carmhook
zle -N __nextterm_credraw
zle -N __nextterm_cfinish
zle -N __nextterm_cisearchhook
zle -N __nextterm_cisearchexit
typeset -ga precmd_functions
precmd_functions=(${precmd_functions:#__nextterm_cprecmd} __nextterm_cprecmd)
__nextterm_cprecmd
"""#
}
