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
        ("@NT_VERSION@", #"2"#),
        ("@NT_WAIT@", #"0.15"#),
        ("@NT_MAX_LINE@", #"16384"#),
        ("@NT_MAX_MATCHES@", #"2000"#),
        ("@NT_CHUNK@", #"48000"#),
        ("@NT_FRAME_WAIT@", #"0.5"#),
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
typeset -gi __nextterm_cfd=-1
typeset -g __nextterm_copen= __nextterm_cpath= __nextterm_cbase= __nextterm_crbuf= __nextterm_cword=
typeset -g __nextterm_ck= __nextterm_cid=
typeset -g __nextterm_cisearch=
# What ^I runs in the keymap of the last `arm`.
typeset -g __nextterm_ctabw=
# The tab started with zsh-autocomplete's list as you type off (the integration's NEXTTERM_COMPLETION=q): see
# __nextterm_cquietstart.
typeset -g __nextterm_cstartq=
[[ ${__nextterm_cstart-} == q ]] && __nextterm_cstartq=1
typeset -ga __nextterm_cf __nextterm_cwords
# zsh's own matches, kept for the open list: each as compadd quoted it, the options to add it again, its
# IPREFIX, PREFIX, SUFFIX and ISUFFIX; and what the popup shows: the text, the description, the group, the kind; and
# for a folder zsh's file completion added, where it is (what going into it checks).
typeset -ga __nextterm_cmw __nextterm_cma __nextterm_cmp __nextterm_cmt __nextterm_cmd __nextterm_cmg __nextterm_cmk __nextterm_cmf
typeset -gA __nextterm_cmseen
typeset -g __nextterm_cmstem=
typeset -gi __nextterm_cmi=0
# Lists gone into a folder from, kept for ⌫ (__nextterm_cpush): how many.
typeset -gi __nextterm_cdepth=0

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

# On a server, inside Next Term's own tmux, marks go through tmux's passthrough (RemoteCompletionHook sets
# __nextterm_cwrap).
__nextterm_cmark() {
  emulate -L zsh
  if [[ -n ${__nextterm_cwrap-} ]]; then
    builtin printf '\033Ptmux;\033\033]6973;%s;%s\007\033\\' "$__nextterm_nonce" "${(j:;:)argv}"
  else
    builtin printf '\033]6973;%s;%s\007' "$__nextterm_nonce" "${(j:;:)argv}"
  fi
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
  __nextterm_ctabw=$widget
  (( ${+functions[compdef]} && ${+functions[_main_complete]} )) && compsys=1
  (( ${+functions[.autocomplete:async:complete]} )) && plugins+=' autocomplete'
  (( ${+widgets[fzf-tab-complete]} )) && plugins+=' fzf-tab'
  (( ${+widgets[fzf-completion]} )) && plugins+=' fzf'
  # zsh-autocomplete's list as you type is off in this shell: its redraw hook is gone (__nextterm_cconfig).
  local quiet=0
  local -a hooks
  if [[ $plugins == *autocomplete* ]]; then
    zstyle -g hooks zle-line-pre-redraw widgets
    [[ -z ${(M)hooks:#<->:.autocomplete:async:complete} ]] && quiet=1
  fi
  __nextterm_cencall "$km" "${CONTEXT-}" "$widget" "${${widgets[$widget]-}:0:128}" "${plugins# }"
  __nextterm_cmark arm @NT_VERSION@ "$reply[1]" "$reply[2]" $bound $compsys "$reply[3]" "$reply[4]" "$reply[5]" $quiet
  return 0
}

# zsh-autocomplete's list as you type off (q1) or back on (q0), in this shell only, by taking its redraw hook out
# or putting it back. No file is touched. False when that changed nothing (it was so already, or isn't loaded).
__nextterm_cquiet() {
  emulate -L zsh
  (( ${+functions[.autocomplete:async:complete]} )) || return 1
  local -a hooks
  zstyle -g hooks zle-line-pre-redraw widgets
  local on=0
  [[ -n ${(M)hooks:#<->:.autocomplete:async:complete} ]] && on=1
  case $1 in
    (q1) (( on )) || return 1
         add-zle-hook-widget -d line-pre-redraw .autocomplete:async:complete ;;
    (q0) (( on )) && return 1
         add-zle-hook-widget line-pre-redraw .autocomplete:async:complete ;;
    (*) return 1 ;;
  esac
  return 0
}

# The same from a key (q1 or q0, in a widget): its list on screen goes too, and a new `arm` says where it stands.
__nextterm_cquietkey() {
  emulate -L zsh
  __nextterm_cstartq=
  __nextterm_cquiet "${1-}" || return 0
  [[ $1 == q1 ]] && zle -R -c
  __nextterm_carm
}

# The `config` key: the user's choice changed (Settings, or the question at a first Tab).
__nextterm_cconfig() { __nextterm_cquietkey "${__nextterm_cf[1]-}"; }

# Off from the start where the tab started so, with no key: a key sent at the first prompt could reach a command typed
# ahead of it. At each prompt until its redraw hook is there to take out (zsh-autocomplete adds it at its first
# precmd, which may run after ours), and at the first line at the latest.
__nextterm_cquietstart() {
  emulate -L zsh
  [[ -n $__nextterm_cstartq ]] || return 0
  __nextterm_cquiet q1 && __nextterm_cstartq=
  [[ ${1-} == line ]] && __nextterm_cstartq=
  return 0
}

__nextterm_carmhook() { __nextterm_cisearch=; __nextterm_cquietstart line; __nextterm_carm; return 0; }

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
  read -t @NT_FRAME_WAIT@ -k 1 kind && read -t @NT_FRAME_WAIT@ -k 6 id && read -t @NT_FRAME_WAIT@ -k 6 len || return 1
  [[ $kind == [a-z] && $id == <-> && $len == <-> ]] || return 1
  (( len = 10#$len, len <= 65536 )) || return 1
  if (( len )); then read -t @NT_FRAME_WAIT@ -k $len payload || return 1; fi
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
    (k) if [[ ${__nextterm_cf[1]-} == l ]]; then __nextterm_ctakeline
        elif [[ ${__nextterm_cf[1]-} == u ]]; then __nextterm_cup ${__nextterm_cf[2]-}
        elif [[ $__nextterm_cid == $__nextterm_copen ]]; then __nextterm_ctake; fi ;;
    (n) # Next Term can't show zsh's list: zsh's own Tab.
        if [[ $__nextterm_cid == $__nextterm_copen ]]; then __nextterm_cclose; zle -U $'\t'; fi ;;
    (c) __nextterm_cconfig ;;
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
  # fzf's trigger (`vim **`) is fzf's.
  [[ $__nextterm_cword == *'**' ]] && return 0
  # So is `kill ` where fzf's ^I widget lists processes for it with no trigger (fzf 0.30 and older; later ones give
  # it zsh's own Tab): its command is the first word with a letter or digit and no `=`, as fzf reads it.
  if [[ $LBUFFER == *' ' && $__nextterm_ctabw == fzf-completion && ${functions[fzf-completion]-} == *'= kill '* ]]; then
    local w
    for w in ${(z)LBUFFER}; do
      w=${(Q)w}
      [[ $w == *[[:alnum:]]* && $w != *=* ]] || continue
      [[ $w == kill ]] && return 0
      break
    done
  fi
  return 1
}

# A real Tab, sent as the private key with Next Term's id. On a server it says how long to wait for Next Term's
# answer (w<ms>, from the connection's round trip, 150 to 600 ms). Where zsh-autocomplete's list as you type isn't
# as the user chose, it says that too (q1 or q0): a server's hook starts with it on. With d, one folder that matches
# goes in and what is inside is listed (zsh's path; Next Term's own engine answers so itself).
__nextterm_ctab() {
  emulate -L zsh -o extendedglob
  local id=$1 f drill=
  for f in "${__nextterm_cf[@]}"; do
    case $f in
      (w<150-600>) typeset -gF __nextterm_cwait=$(( ${f#w} / 1000.0 )) ;;
      (q[01]) __nextterm_cquietkey $f ;;
      (d) drill=1 ;;
    esac
  done
  __nextterm_cclose
  if [[ $KEYMAP != (main|emacs|viins) || $CONTEXT != (start|cont) ]] || __nextterm_cplain; then
    __nextterm_cdone $id native
    zle -U $'\t'
  elif (( ${+functions[compdef]} && ${+functions[_main_complete]} )); then
    __nextterm_csystem $id $drill
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
  local -F deadline=$(( EPOCHREALTIME + ${__nextterm_cwait:-@NT_WAIT@} )) left
  local c rest
  while true; do
    (( left = deadline - EPOCHREALTIME ))
    if (( left <= 0 )) || ! read -t $left -k 1 c; then
      __nextterm_cdone $id native
      zle -U $'\t'
      return 0
    fi
    rest=
    [[ $c == $'\e' ]] && read -t @NT_FRAME_WAIT@ -k $(( ${#__nextterm_ckey} - 1 )) rest
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
    (i) LBUFFER=${LBUFFER:0:$(( ${#LBUFFER} - ${#__nextterm_cword} ))}${__nextterm_cf[2]-}
        # With o: one folder went in, and the list of what is inside opens for the word now.
        if [[ ${__nextterm_cf[3]-} == o ]]; then
          __nextterm_cwordnow
          __nextterm_copenlist $id e
        fi ;;
    (o) __nextterm_copenlist $id e ;;
    (*) zle -U $'\t' ;;
  esac
  return 0
}

# compadd while Next Term reads zsh's own matches (the technique of fzf-tab and zsh-capture-completion, both
# MIT): each match is kept with what it takes to add it again, and none reaches zsh's own list.
__nextterm_ccompadd() {
  local -A apre hpre dscrs oad
  local -a opts ign expl isfile hits dscr
  zparseopts -E -a opts P:=apre p:=hpre d:=dscrs X+:=expl O:=oad A:=oad D:=oad f=isfile x:=ign \
    i: S: s: I: r: R: W: F: M+: E: q e Q n U C J:=ign V:=ign a=ign l=ign k=ign o=ign 1=ign 2=ign
  # compadd asked only to match (-O, -A, -D): it adds nothing, so it runs as it is.
  if (( ${#oad} )); then
    builtin compadd "$@"
    return
  fi
  (( ${#dscrs} == 1 )) && dscr=( "${(@P)${(v)dscrs}}" )
  builtin compadd -A hits -D dscr "$@"
  local ret=$?
  emulate -L zsh -o extendedglob
  (( ${#hits} )) || return $ret
  local i dir= suffix= kind word place stem=$IPREFIX${hpre[-p]-}
  for (( i = 1; i < ${#opts}; i++ )); do
    [[ $opts[i] == -W ]] && dir=$opts[i+1]
    [[ $opts[i] == -S ]] && suffix=$opts[i+1]
  done
  [[ -z $dir && -n $isfile ]] && dir=${(Q)${hpre[-p]-}}
  [[ -n $dir && $dir != */ ]] && dir+=/
  opts+=( "${(@kv)apre}" "${(@kv)hpre}" $isfile )
  [[ -n $__nextterm_cmstem || ${#__nextterm_cmw} -gt 0 ]] || __nextterm_cmstem=$stem
  for (( i = 1; i <= ${#hits}; i++ )); do
    word=$hits[i]
    (( ${+__nextterm_cmseen[$word]} )) && continue
    __nextterm_cmseen[$word]=1
    kind= place=
    if [[ $word == */ || $suffix == / ]] || { [[ -n $isfile ]] && (( ${#__nextterm_cmw} < @NT_MAX_MATCHES@ )) && [[ -d $dir${(Q)word} ]]; }; then
      kind=d
      [[ -n $isfile ]] && place=$dir${(Q)word}
    elif [[ -n $isfile ]]; then
      kind=f
    fi
    __nextterm_cmw+=( "$word" )
    __nextterm_cma+=( "${(pj:\1:)opts}" )
    __nextterm_cmp+=( "$IPREFIX"$'\1'"$PREFIX"$'\1'"$SUFFIX"$'\1'"$ISUFFIX" )
    __nextterm_cmt+=( "${(Q)word}" )
    __nextterm_cmd+=( "${dscr[i]-}" )
    __nextterm_cmg+=( "${expl[2]-}" )
    __nextterm_cmk+=( "$kind" )
    __nextterm_cmf+=( "$place" )
  done
  # zsh counts the call as a success, so the completers after it don't run, as with its own Tab.
  builtin compadd -U -qS '' ''
}

# The completion widget that reads zsh's matches: the user's own completion (fzf-tab's copy of it when fzf-tab
# is loaded, so fzf never starts), with compadd standing in, and nothing inserted or listed. It runs with the
# user's options, as zsh's own Tab does.
__nextterm_ccapture() {
  local __nextterm_had=${+functions[compadd]} __nextterm_old=${functions[compadd]-}
  functions[compadd]=${functions[__nextterm_ccompadd]}
  {
    # `|| true`: no match is no error, even under the user's err_return.
    if (( ${+functions[_ftb__main_complete]} )); then _ftb__main_complete || true; else _main_complete || true; fi
  } always {
    if (( __nextterm_had )); then functions[compadd]=$__nextterm_old; else unfunction compadd; fi
  }
  compstate[insert]=
  compstate[list]=
  return 0
}

# The completion widget that adds match $__nextterm_cmi again, with the options zsh gave it, so zsh quotes and
# inserts it as its own Tab would: the word typed so far is replaced, then a space unless it's a folder.
__nextterm_ctakematch() {
  emulate -L zsh
  local i=$__nextterm_cmi
  local -a parts args
  parts=( "${(@ps:\1:)__nextterm_cmp[i]}" )
  args=( "${(@ps:\1:)__nextterm_cma[i]}" )
  [[ -z ${args[1]-} ]] && args=()
  IPREFIX=${parts[1]-} PREFIX=${parts[2]-} SUFFIX=${parts[3]-} ISUFFIX=${parts[4]-}
  builtin compadd "${args[@]}" -U -Q -- "$__nextterm_cmw[i]"
  compstate[insert]=1
  [[ $RBUFFER == ' '* ]] || compstate[insert]+=' '
  compstate[list]=
  return 0
}

# zsh's own matches for the word now, in the arrays above.
__nextterm_ccapturenow() {
  emulate -L zsh
  __nextterm_cmw=() __nextterm_cma=() __nextterm_cmp=() __nextterm_cmt=() __nextterm_cmd=() __nextterm_cmg=() __nextterm_cmk=()
  __nextterm_cmf=() __nextterm_cmseen=() __nextterm_cmstem=
  # Defined only now: a completion widget in a shell without zsh's completion system would leave its own Tab
  # with nothing to complete.
  (( ${+widgets[__nextterm_ccapturewidget]} )) || zle -C __nextterm_ccapturewidget complete-word __nextterm_ccapture
  (( ${+widgets[__nextterm_ctakewidget]} )) || zle -C __nextterm_ctakewidget complete-word __nextterm_ctakematch
  zle __nextterm_ccapturewidget
}

# With zsh's completion system loaded: zsh's own matches. None: zsh's own Tab. One: it goes in; with $2 (the Tab's d),
# a folder that goes in so has what is inside listed. More: they go to Next Term in `comp` marks, and the list opens.
__nextterm_csystem() {
  emulate -L zsh
  local id=$1 drill=${2-}
  __nextterm_ccapturenow
  case ${#__nextterm_cmw} in
    (0) __nextterm_cdone $id native
        zle -U $'\t' ;;
    (1) __nextterm_cmi=1
        zle __nextterm_ctakewidget
        if [[ -n $drill && ${__nextterm_cmk[1]-} == d ]] && __nextterm_centers 1; then
          __nextterm_cinside $id
        else
          __nextterm_cdone $id inserted
        fi ;;
    (*) __nextterm_ccomp $id
        __nextterm_copenlist $id z ;;
  esac
  return 0
}

# Match $1 is a folder that can be entered, or one whose place zsh didn't say (zsh lists what it can inside).
__nextterm_centers() {
  local place=${__nextterm_cmf[$1]-}
  [[ -z $place ]] || [[ -d $place && -x $place ]]
}

# A folder just went in: zsh's matches for what is inside, listed under $1. None: the list closes (done inserted).
__nextterm_cinside() {
  emulate -L zsh
  local id=$1
  __nextterm_cwordnow
  __nextterm_ccapturenow
  if (( ${#__nextterm_cmw} )); then
    __nextterm_ccomp $id
    __nextterm_copenlist $id z
  else
    __nextterm_cclose
    __nextterm_cdone $id inserted
  fi
}

# Into folder match $1 of the open list, for Next Term's Tab on its row: what is inside is listed under $2. One that
# can't be entered (no permission, gone) is refused (done kept), and the list stays as it was. Else the list's
# matches are kept for ⌫ (__nextterm_cup), and zsh puts the folder in as its own Tab would.
__nextterm_cdrill() {
  emulate -L zsh
  local i=$1 to=$2 from=$__nextterm_copen
  if [[ ${__nextterm_cmk[i]-} != d ]] || ! __nextterm_centers $i; then
    __nextterm_cdone $to kept
    return 0
  fi
  __nextterm_cpush $from
  # No `line` for the list gone from while zsh works.
  __nextterm_copen= __nextterm_cpath=
  __nextterm_cmi=$i
  zle __nextterm_ctakewidget
  __nextterm_cinside $to
}

# The open list's matches, kept for going back up: one level for each folder gone into.
__nextterm_cpush() {
  emulate -L zsh
  local n=$(( __nextterm_cdepth + 1 )) a src
  for a in cmw cma cmp cmt cmd cmg cmk cmf; do
    src=__nextterm_$a
    typeset -ga __nextterm_${a}_$n
    set -A __nextterm_${a}_$n "${(@P)src}"
  done
  typeset -g __nextterm_cmstem_$n=$__nextterm_cmstem __nextterm_cmid_$n=$1
  __nextterm_cdepth=$n
}

# ⌫ took the `/` after a folder gone into (the key comes for the list open now): the list it was gone into from, open
# again under its own id $1, for the word now. Anything else, such as a list that closed meanwhile: Next Term hears
# that list is gone (`line` … left).
__nextterm_cup() {
  emulate -L zsh
  local to=$1 n=$__nextterm_cdepth a src=__nextterm_cmid_$__nextterm_cdepth
  if [[ -z $__nextterm_copen || $__nextterm_cid != $__nextterm_copen ]] || (( n < 1 )) || [[ ${(P)src-} != $to ]]; then
    [[ $to == <-> ]] && __nextterm_cmark line $to 1
    [[ -n $__nextterm_copen && $__nextterm_cid == $__nextterm_copen ]] && __nextterm_cclose
    return 0
  fi
  for a in cmw cma cmp cmt cmd cmg cmk cmf; do
    src=__nextterm_${a}_$n
    set -A __nextterm_$a "${(@P)src}"
    unset $src
  done
  src=__nextterm_cmstem_$n
  __nextterm_cmstem=${(P)src}
  unset $src __nextterm_cmid_$n
  __nextterm_cdepth=$(( n - 1 ))
  __nextterm_copen= __nextterm_cpath=
  __nextterm_cwordnow
  __nextterm_copenlist $to z
}

# The lists kept for going back up, dropped.
__nextterm_cforget() {
  emulate -L zsh
  local n a
  for (( n = __nextterm_cdepth; n > 0; n-- )); do
    for a in cmw cma cmp cmt cmd cmg cmk cmf; do unset __nextterm_${a}_$n; done
    unset __nextterm_cmstem_$n __nextterm_cmid_$n
  done
  __nextterm_cdepth=0
}

# The matches as `comp` marks: the total, then the first @NT_MAX_MATCHES@ in chunks of under @NT_CHUNK@ bytes.
__nextterm_ccomp() {
  emulate -L zsh
  local id=$1 n=${#__nextterm_cmw} i item chunk=
  local -a texts dscrs groups chunks
  (( n > @NT_MAX_MATCHES@ )) && n=@NT_MAX_MATCHES@
  __nextterm_cencall "${(@)__nextterm_cmt[1,n]}"
  texts=( "${reply[@]}" )
  __nextterm_cencall "${(@)__nextterm_cmd[1,n]}"
  dscrs=( "${reply[@]}" )
  __nextterm_cencall "${(@)__nextterm_cmg[1,n]}"
  groups=( "${reply[@]}" )
  for (( i = 1; i <= n; i++ )); do
    item="$texts[i],$dscrs[i],$groups[i],$__nextterm_cmk[i]"
    if (( ${#chunk} + ${#item} >= @NT_CHUNK@ )) && [[ -n $chunk ]]; then
      chunks+=( "$chunk" )
      chunk=
    fi
    chunk+="${chunk:+ }$item"
  done
  chunks+=( "$chunk" )
  __nextterm_cencall "$__nextterm_cmstem" "${(Q)__nextterm_cmstem}"
  local stem=$reply[1] stemq=$reply[2]
  for (( i = 1; i <= ${#chunks}; i++ )); do
    __nextterm_cmark comp $id ${#__nextterm_cmw} $i ${#chunks} "$stem" "$stemq" "$chunks[i]"
  done
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
  (( __nextterm_cdepth )) && __nextterm_cforget
  return 0
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

# A whole line from Suggest a Command (the user asked for it and submitted): it replaces the line being edited,
# one line or several, with the cursor at its end. Nothing runs until the user presses Return.
__nextterm_ctakeline() {
  __nextterm_cclose
  BUFFER=${__nextterm_cf[2]-}
  CURSOR=${#BUFFER}
  zle -R
  return 0
}

# A row was chosen (or the list closed), for the open id. Into a folder: Next Term's own word with o, which keeps the
# list open for the word now, or zsh's match with the id what is inside is listed under (__nextterm_cdrill). u: back up
# (__nextterm_cup, from the key's widget). A take that finds another word beeps; one into a folder says the list is gone
# (`line` … left).
__nextterm_ctake() {
  emulate -L zsh -o extendedglob
  local how=${__nextterm_cf[1]-} old=${__nextterm_cf[2]-} id=$__nextterm_copen
  local same=0
  [[ $LBUFFER == "$__nextterm_cbase$old" && $RBUFFER == "$__nextterm_crbuf" ]] && same=1
  case $how in
    (w) # Next Term's own: the new word, quoted by Next Term.
      local into=${__nextterm_cf[4]-}
      if (( same )); then
        LBUFFER=$__nextterm_cbase${__nextterm_cf[3]-}
        if [[ $into == o ]]; then
          __nextterm_cline force
          return 0
        fi
      else
        zle beep
        [[ $into == o ]] && __nextterm_cmark line $id 1
      fi ;;
    (m) # zsh's own, by its place in the list: zsh adds it again and quotes it.
      local index=${__nextterm_cf[3]-} to=${__nextterm_cf[4]-}
      if (( same )) && [[ $__nextterm_cpath == z && $index == <1-> ]] && (( index <= ${#__nextterm_cmw} )); then
        if [[ $to == <-> ]]; then
          __nextterm_cdrill $index $to
          return 0
        fi
        __nextterm_cmi=$index
        zle __nextterm_ctakewidget
      else
        zle beep
        [[ -n $to ]] && __nextterm_cmark line $id 1
      fi ;;
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
  __nextterm_cquietstart
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
