#!/bin/bash
# Before each release: checks the AgentCLI table (Sources/NextTermCore/AgentCLI.swift, KTD20) against the agents
# installed here, so a renamed resume word is found before a release ships it.
#
# For each agent of the table on PATH, it reads the agent's --version, its --help, and the --help of its resume path
# when that is a subcommand (`codex resume --help`). Every word of the resume form must be in the resume path's help,
# and every option the table does not mark hidden in one of the helps. It prints the installed and the checked version
# of each agent and, when the agent passes, the `checked` line to record in the table.
#
# It reads the table from its source, never from a copy, and changes nothing. Each agent runs only with --version or
# --help, with no input, for at most 20 seconds, under sandbox-exec with no network and no writes outside this
# script's own temporary folder, which it removes.
#
# Usage: scripts/agent-cli-check.sh [--strict] [agent ...]   the agents on PATH, or only the ones named (claude, codex,
#                                                            commandCode: the table's names)
#        scripts/agent-cli-check.sh --list                   the table as this script reads it, one agent a line;
#                                                            runs nothing
#   --strict   a missing option fails the check too, not only a missing resume word
# Exit status: 0 when each agent checked has every resume word in its help; 1 when one does not, when a help fails,
# or with --strict when an option is missing; 2 on a usage error, a table it cannot read, or no sandbox.
#
# Plain bash 3.2, as macOS ships it.
set -u
set -f
set -o pipefail

agent_path=${PATH:-}
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

root=$(cd "$(dirname "$0")/.." && pwd -P) || exit 2
table="$root/Sources/NextTermCore/AgentCLI.swift"
limit=20

usage() {
  sed -n '/^# Usage:/,/^# Plain bash/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

fail_usage() {
  echo "agent-cli-check: $1" >&2
  exit 2
}

# The table, one agent a line: name|programs|subcommand|resume form|options|hidden|checked version|checked date. Words
# are split by spaces. The resume form writes the id as <id>, the folder as <folder>, and Copilot's joined option as
# --resume=<id>. An agent with no resume form has an empty one, and a check made from documentation only an empty
# version.
read_table() {
  [ -r "$table" ] || fail_usage "cannot read the table: no $table"
  awk '
    function fail(message) {
      print "agent-cli-check: cannot read the table: " message > "/dev/stderr"
      failed = 1
      exit 2
    }

    # The text between the brackets of `key: [...]`, "nil" for `key: nil`, or "absent".
    function list(entry, key,   at, rest, last) {
      at = index(entry, " " key ": ")
      if (at == 0) at = index(entry, "(" key ": ")
      if (at == 0) return "absent"
      rest = substr(entry, at + length(key) + 3)
      if (rest ~ /^nil/) return "nil"
      if (substr(rest, 1, 1) != "[") fail(name ": " key " is no list")
      last = index(rest, "]")
      if (last == 0) fail(name ": " key " has no end")
      return substr(rest, 2, last - 2)
    }

    # Each string literal in `text`, in order.
    function strings(text,   out) {
      out = ""
      while (match(text, /"[^"]*"/)) {
        out = out (out == "" ? "" : " ") substr(text, RSTART + 1, RLENGTH - 2)
        text = substr(text, RSTART + RLENGTH)
      }
      return out
    }

    # The words of a resume form.
    function words(text,   count, parts, i, part, word, out) {
      count = split(text, parts, ",")
      out = ""
      for (i = 1; i <= count; i++) {
        part = parts[i]
        gsub(/^[ \t]+|[ \t]+$/, "", part)
        if (part == "") continue
        if (part ~ /^"[^"]*"$/) {
          word = substr(part, 2, length(part) - 2)
        } else if (part == ".id") {
          word = "<id>"
        } else if (part == ".folder") {
          word = "<folder>"
        } else if (part ~ /^\.joinedID\("[^"]*"\)$/) {
          word = substr(part, 12, length(part) - 13) "=<id>"
        } else {
          fail(name ": a resume word it does not know: " part)
        }
        out = out (out == "" ? "" : " ") word
      }
      return out
    }

    function emit(entry,   programs, subcommand, resume, options, hidden, rest, version, date) {
      programs = list(entry, "programs")
      resume = list(entry, "resume")
      options = list(entry, "options")
      subcommand = list(entry, "subcommand")
      hidden = list(entry, "hidden")
      if (programs == "absent" || programs == "nil") fail(name ": no programs")
      if (resume == "absent") fail(name ": no resume")
      if (options == "absent" || options == "nil") fail(name ": no options")
      if (subcommand == "absent") subcommand = ""
      if (hidden == "absent") hidden = ""
      rest = substr(entry, index(entry, "checked: Checked("))
      version = ""
      if (match(rest, /version: "[^"]*"/)) {
        version = substr(rest, RSTART + 10, RLENGTH - 11)
      } else if (rest !~ /version: nil/) {
        fail(name ": no checked version")
      }
      if (!match(rest, /date: "[^"]*"/)) fail(name ": no checked date")
      date = substr(rest, RSTART + 7, RLENGTH - 8)
      print name "|" strings(programs) "|" strings(subcommand) "|" (resume == "nil" ? "" : words(resume)) "|" \
        strings(options) "|" strings(hidden) "|" version "|" date
      count++
    }

    # An entry runs from `static let <name> = AgentCLI(` to its `checked:` line.
    /static let [A-Za-z0-9_]+ = AgentCLI\(/ {
      name = $0
      sub(/^.*static let /, "", name)
      sub(/ = AgentCLI\(.*$/, "", name)
      entry = ""
      inside = 1
    }
    inside {
      line = $0
      sub(/(^|[ \t])\/\/.*$/, "", line)
      entry = entry " " line
      if (line ~ /checked: Checked\(/) {
        inside = 0
        emit(entry)
      }
    }
    END {
      if (failed) exit 2
      if (inside) fail(name ": no checked line")
      if (count == 0) fail("no entries")
    }
  ' "$table"
}

# The first program of `names` on the caller's PATH, as an absolute path. Only absolute folders of PATH count, so no
# program runs from the current folder.
find_program() {
  local name dir old_ifs
  for name in $1; do
    old_ifs=$IFS
    IFS=:
    for dir in $agent_path; do
      IFS=$old_ifs
      case $dir in /*) ;; *) continue ;; esac
      if [ -f "$dir/$name" ] && [ -x "$dir/$name" ]; then
        printf '%s\n' "$dir/$name"
        return 0
      fi
    done
    IFS=$old_ifs
  done
  return 1
}

# Stops a process and every process under it.
kill_tree() {
  local child
  kill -STOP "$1" 2>/dev/null
  for child in $(pgrep -P "$1"); do
    kill_tree "$child"
  done
  kill -9 "$1" 2>/dev/null
}

# Runs an agent with its arguments, with no input, under the sandbox, for at most $limit seconds. Its output goes to
# $1.out and $1.err without terminal escapes. The status is the agent's, or 124 when it ran out of time.
run_agent() {
  local out=$1 pid watch status
  shift
  /usr/bin/env TMPDIR="$work/tmp" XDG_CACHE_HOME="$work/cache" XDG_STATE_HOME="$work/state" NO_COLOR=1 TERM=dumb \
    DISABLE_AUTOUPDATER=1 NO_UPDATE_NOTIFIER=1 PATH="$agent_path" \
    /usr/bin/sandbox-exec -p "$profile" "$@" </dev/null >"$out.raw" 2>"$out.rawerr" &
  pid=$!
  (
    sleeper=""
    trap '[ -n "$sleeper" ] && kill "$sleeper" 2>/dev/null; exit 0' TERM
    sleep "$limit" &
    sleeper=$!
    wait "$sleeper"
    : >"$out.late"
    kill_tree "$pid"
  ) &
  watch=$!
  wait "$pid" 2>/dev/null
  status=$?
  kill "$watch" 2>/dev/null
  wait "$watch" 2>/dev/null
  [ -e "$out.late" ] && status=124
  LC_ALL=C sed -e "s/${escape}\[[0-9;?]*[A-Za-z]//g" -e "s/${escape}//g" -e "s/${carriage}//g" "$out.raw" >"$out.out"
  LC_ALL=C sed -e "s/${escape}\[[0-9;?]*[A-Za-z]//g" -e "s/${escape}//g" -e "s/${carriage}//g" "$out.rawerr" >"$out.err"
  return $status
}

# What a failed run says: "ran out of time", or its status and the first line of its error (or output).
failure() {
  local out=$1 status=$2 line
  if [ "$status" -eq 124 ]; then
    printf 'ran out of time after %s s' "$limit"
    return
  fi
  line=$(LC_ALL=C grep -m 1 '[^[:space:]]' "$out.err" || LC_ALL=C grep -m 1 '[^[:space:]]' "$out.out")
  line=$(printf '%s' "$line" | LC_ALL=C sed -e 's/^[[:space:]]*//' | LC_ALL=C cut -c 1-160)
  printf 'exited with status %s' "$status"
  [ -n "$line" ] && printf ': %s' "$line"
}

# The words of $1 that none of the files after it names. A word is named when it stands alone: no letter, digit, `_`
# or `-` touches it (`--model` in "-m, --model <MODEL>", `e` in "[aliases: e]").
missing_words() {
  local words=$1
  shift
  LC_ALL=C awk -v words="$words" '
    function named(text, word,   from, at, before, after) {
      from = 1
      while ((at = index(substr(text, from), word)) > 0) {
        at += from - 1
        before = at > 1 ? substr(text, at - 1, 1) : ""
        after = substr(text, at + length(word), 1)
        if (before !~ /[A-Za-z0-9_-]/ && after !~ /[A-Za-z0-9_-]/) return 1
        from = at + 1
      }
      return 0
    }
    { text = text "\n" $0 }
    END {
      count = split(words, list, " ")
      for (i = 1; i <= count; i++) if (!named(text, list[i])) print list[i]
    }
  ' "$@"
}

# A version as --version prints one: the first `1.2` or longer, else its first line, else "unknown".
installed_version() {
  local out=$1 version
  version=$(cat "$out.out" "$out.err" | LC_ALL=C grep -E -o -m 1 '[0-9]+\.[0-9]+[0-9A-Za-z.+-]*' | head -n 1)
  if [ -n "$version" ]; then
    printf '%s\n' "$version"
    return
  fi
  version=$(cat "$out.out" "$out.err" | LC_ALL=C grep -m 1 '[^[:space:]]' |
    LC_ALL=C sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | LC_ALL=C cut -c 1-40)
  printf '%s\n' "${version:-unknown}"
}

# Checks one agent of the table. Sets `result` to passed, failed or skipped.
check_agent() {
  local name=$1 programs=$2 subcommand=$3 resume=$4 options=$5 hidden=$6 version=$7 date=$8
  local program program_name path_words word resume_words option_words installed checked status out
  local bad=0
  result=skipped
  [ -n "$programs" ] || return 0
  if ! program=$(find_program "$programs"); then
    echo "$name: not on PATH"
    return 0
  fi
  program_name=${program##*/}
  echo "$name ($program)"
  out="$work/$name"

  run_agent "$out.version" "$program" --version
  status=$?
  if [ "$status" -eq 0 ]; then
    installed=$(installed_version "$out.version")
  else
    installed="unknown ($program_name --version $(failure "$out.version" "$status"))"
  fi
  checked=${version:-against its documentation}
  echo "  installed $installed, checked $checked on $date"

  # The resume path: the subcommand the options belong to, then the resume form's words up to its first option or
  # value (`codex resume`, `amp threads continue`, `goose session`).
  path_words=$subcommand
  for word in $resume; do
    case $word in -*|"<"*) break ;; esac
    path_words="${path_words:+$path_words }$word"
  done
  resume_words=""
  for word in $resume; do
    case $word in "<"*) continue ;; esac
    resume_words="${resume_words:+$resume_words }${word%%=<id>}"
  done
  option_words=""
  for word in $options; do
    case " $hidden $resume_words " in *" $word "*) continue ;; esac
    option_words="${option_words:+$option_words }$word"
  done

  if [ -n "$path_words" ]; then
    echo "  help: $program_name --help, $program_name $path_words --help"
  else
    echo "  help: $program_name --help"
  fi
  run_agent "$out.help" "$program" --help
  status=$?
  if [ "$status" -ne 0 ]; then
    echo "  $program_name --help $(failure "$out.help" "$status")"
    bad=1
  fi
  if [ -n "$path_words" ]; then
    # shellcheck disable=SC2086 # the path's words are the table's, one word each
    run_agent "$out.path" "$program" $path_words --help
    status=$?
    if [ "$status" -ne 0 ]; then
      echo "  $program_name $path_words --help $(failure "$out.path" "$status")"
      bad=1
    fi
  else
    cp "$out.help.out" "$out.path.out" && cp "$out.help.err" "$out.path.err" || exit 2
  fi

  # The resume words in the resume path's own help; the options in either help.
  if [ "$bad" -eq 0 ]; then
    for word in $(missing_words "$resume_words" "$out.path.out" "$out.path.err"); do
      echo "  missing resume word: $word"
      bad=1
    done
    for word in $(missing_words "$option_words" "$out.help.out" "$out.help.err" "$out.path.out" "$out.path.err"); do
      echo "  missing option: $word"
      [ "$strict" -eq 1 ] && bad=1
    done
  fi

  if [ "$bad" -ne 0 ]; then
    echo "  FAILED"
    result=failed
    return 0
  fi
  echo "  passed"
  case $installed in
    [0-9]*.*) echo "  record: checked: Checked(version: \"$installed\", date: \"$(date +%Y-%m-%d)\")" ;;
  esac
  result=passed
}

strict=0
list=0
names=""
while [ $# -gt 0 ]; do
  case $1 in
    --strict) strict=1 ;;
    --list) list=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) fail_usage "unknown option $1 (see --help)" ;;
    *) names="$names $1" ;;
  esac
  shift
done

entries=$(read_table) || exit 2
if [ "$list" -eq 1 ]; then
  printf '%s\n' "$entries"
  exit 0
fi

known=$(printf '%s\n' "$entries" | cut -d '|' -f 1)
for name in $names; do
  printf '%s\n' "$known" | grep -q -x -F -e "$name" || fail_usage "no agent named $name in the table ($(echo $known))"
done

work=$(mktemp -d "${TMPDIR:-/tmp}/agent-cli-check.XXXXXX") || fail_usage "cannot make a temporary folder"
work=$(cd "$work" && pwd -P) || exit 2
trap 'rm -rf "$work"' EXIT
trap 'exit 130' INT TERM
case $work in
  *'"'*|*'\'*) fail_usage "the temporary folder's path has a quote or a backslash: $work" ;;
esac
mkdir "$work/tmp" "$work/cache" "$work/state" || exit 2
escape=$(printf '\033')
carriage=$(printf '\r')

# Everything is allowed but the network and writes, and writes only into the temporary folder and /dev/null.
profile="(version 1)(allow default)(deny network*)(deny file-write*)"
profile="$profile(allow file-write* (subpath \"$work\") (literal \"/dev/null\"))"
if ! /usr/bin/sandbox-exec -p "$profile" /usr/bin/true 2>/dev/null; then
  fail_usage "sandbox-exec cannot run here, so no agent is run"
fi

echo "The AgentCLI table against the agents on PATH, $(date +%Y-%m-%d)"
echo
passed=""
failed=""
skipped=0
while IFS='|' read -r name programs subcommand resume options hidden version date; do
  [ -z "$names" ] || case " $names " in *" $name "*) ;; *) continue ;; esac
  check_agent "$name" "$programs" "$subcommand" "$resume" "$options" "$hidden" "$version" "$date"
  case $result in
    passed) passed="$passed $name" ;;
    failed) failed="$failed $name" ;;
    *) [ -n "$programs" ] && skipped=$((skipped + 1)) ;;
  esac
done <<EOF
$entries
EOF

count() { set -- $1; echo $#; }
echo
summary="$(count "$passed $failed") checked, $(count "$passed") passed, $skipped not on PATH."
if [ -n "$failed" ]; then
  echo "$summary Failed:$(echo "$failed" | sed 's/ /, /g; s/^,//')."
  exit 1
fi
echo "$summary"
exit 0
