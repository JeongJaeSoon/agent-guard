#!/usr/bin/env sh
# agent-guard hook launcher, interface v1 (frozen).
#
#   sh <root>/hooks/launch.sh <host> <hook-subcommand> <host-selected-root>
#
# Every plugin hook manifest command delegates here. That command may run a
# launcher from an older or newer sibling version directory, so this
# interface never changes: exactly three arguments, <host> is claude or codex,
# <hook-subcommand> matches hook-[a-z-]*. Anything else gets the
# infrastructure-failure policy below and nothing is executed.
#
# Invariants (the manifest resolver's, moved here unchanged):
# - A complete host-selected root is authoritative: its bin/agent-guard is
#   executable, its three policy files are readable, and the VERSION embedded
#   in the binary equals the directory name when that name is semver.
# - Only when that root no longer exists (a plugin update deleted it
#   mid-session) is `current` used, if it names a complete semver version,
#   else the highest complete semver sibling.
# - A root that exists but is incomplete is never replaced by a sibling: an
#   interrupted update can leave a higher directory holding only the binary.
# - The hooks whose event carries text to or from the agent (hook-pre-tool,
#   hook-user-prompt, hook-post-tool, hook-post-tool-failure) block when the
#   check cannot run and AGENT_GUARD_INFRA_FAILURE_MODE is unset; the other
#   hooks continue. open and closed apply to every hook, and any other value
#   is read as unset.
# - With no binary, a block exits 2 with the reason every time; continuing
#   warns once per host, session and mode and exits 0. The session comes from
#   AGENT_GUARD_SESSION_ID, else the payload's session_id (jq, or a
#   compact-JSON parse without jq), else the parent PID. A marker that cannot
#   be written still warns. The output of a tool that already ran cannot be
#   withheld here: only the binary knows the shape each tool's output takes.
# - The binary runs with AGENT_GUARD_HOOK_HOST pinned and stdin untouched. For
#   a hook that continues it replaces this shell (exec). For a hook that
#   blocks, this shell stays as its parent: 0 and 2 pass through, any other
#   status is a check that did not finish and becomes exit 2 with the reason,
#   and a TERM, INT or HUP sent to this shell is passed on to the binary.
#
# The whole body is one brace group, so the shell parses the entire file
# before running any of it: a truncated or half-replaced launcher fails as a
# syntax error instead of running a prefix of the policy.
{
host=${1-}
sub=${2-}
r=${3-}
args_ok=1
[ "$#" -eq 3 ] || args_ok=0
root_var=
case "$host" in
  claude) root_var=CLAUDE_PLUGIN_ROOT ;;
  codex) root_var=PLUGIN_ROOT ;;
  *) args_ok=0 ;;
esac
case "$sub" in
  hook-*)
    case "${sub#hook-}" in
      *[!abcdefghijklmnopqrstuvwxyz-]*) args_ok=0 ;;
    esac
    ;;
  *) args_ok=0 ;;
esac

# Text crosses the agent boundary in these events, so they block unless the
# mode says open. An unrecognised mode is read as unset.
text=0
case "$sub" in
  hook-pre-tool|hook-user-prompt|hook-post-tool|hook-post-tool-failure) text=$args_ok ;;
esac
case "${AGENT_GUARD_INFRA_FAILURE_MODE:-}" in
  open|closed)
    mode=$AGENT_GUARD_INFRA_FAILURE_MODE
    because="AGENT_GUARD_INFRA_FAILURE_MODE=$mode"
    ;;
  *)
    if [ "$text" -eq 1 ]; then
      mode=closed
      because='the secret scan did not run (the default when AGENT_GUARD_INFRA_FAILURE_MODE is unset)'
    else
      mode=open
      because='AGENT_GUARD_INFRA_FAILURE_MODE=open'
    fi
    ;;
esac
unchecked=
case "$mode" in
  closed)
    action=blocking
    case "$sub" in
      hook-post-tool|hook-post-tool-failure)
        unchecked='; the tool output was not checked and could not be withheld' ;;
    esac
    ;;
  *) action=continuing ;;
esac

semver() {
  case ${1:-} in ""|*[!0-9.]*) return 1 ;; esac
  o=$IFS
  IFS=.
  # shellcheck disable=SC2086 # split on IFS=. into major, minor, patch
  set -- $1
  IFS=$o
  [ "$#" -eq 3 ] && [ -n "$1" ] && [ -n "$2" ] && [ -n "$3" ]
}

root_ok() {
  q=$1
  e=${2:-}
  z="$q/bin/agent-guard"
  [ -x "$z" ] && [ -r "$q/config/gitleaks.toml" ] \
    && [ -r "$q/config/deny-read-paths.txt" ] \
    && [ -r "$q/config/deny-bash-patterns.txt" ] || return 1
  u=
  while IFS= read -r l; do
    case "$l" in VERSION=*) u=${l#VERSION=}; break ;; esac
  done <"$z"
  [ -n "$u" ] && { [ -z "$e" ] || [ "$u" = "$e" ]; }
}

x=
if [ "$args_ok" -eq 1 ] && [ -n "$r" ]; then
  b=${r%/*}
  v=${r##*/}
  semver "$v" || v=
  if root_ok "$r" "$v"; then
    x="$r/bin/agent-guard"
  elif [ ! -e "$r" ]; then
    c="$b/current"
    t=
    [ -L "$c" ] && t=$(readlink "$c" 2>/dev/null) || :
    if semver "$t" && root_ok "$c" "$t"; then
      x="$c/bin/agent-guard"
    else
      x=$(for z in "$b"/*/bin/agent-guard; do
        [ -x "$z" ] || continue
        q=${z%/bin/agent-guard}
        v=${q##*/}
        semver "$v" || continue
        root_ok "$q" "$v" || continue
        printf '%s\t%s\n' "$v" "$z"
      done | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1 | cut -f 2-)
    fi
  fi
fi

if [ ! -x "$x" ]; then
  p=
  while IFS= read -r line || [ -n "$line" ]; do p=$p$line; done
  if [ "$args_ok" -ne 1 ]; then
    # No trustworthy host to key a marker on: say why on every call.
    echo "agent-guard: hook launcher was called with an unsupported host or hook subcommand; $action because $because" >&2
    [ "$mode" = closed ] && exit 2
    exit 0
  fi
  # Same default as the CLI's warning_root: sh has no UID variable.
  d=${AGENT_GUARD_WARNING_DIR:-${TMPDIR:-/tmp}/agent-guard-warnings-$(id -u 2>/dev/null || echo user)}
  i=${AGENT_GUARD_SESSION_ID:-}
  if [ -z "$i" ] && command -v jq >/dev/null 2>&1; then
    i=$(printf %s "$p" | jq -r ".session_id // empty" 2>/dev/null)
  fi
  if [ -z "$i" ]; then
    case "$p" in
      *\"session_id\":\"*)
        i=${p#*\"session_id\":\"}
        i=${i%%\"*}
        case "$i" in ""|*[!A-Za-z0-9._:-]*) i= ;; esac
        ;;
    esac
  fi
  if [ -n "$i" ]; then
    i=$(printf %s "$i" | cksum)
  else
    i=ppid-${PPID:-0}
  fi
  k="$d/manifest-$host-$i-$mode"
  warn=1
  # Nothing is executed after this point, so the private umask stays local.
  umask 077
  if [ "$mode" = open ] && mkdir -p "$d" 2>/dev/null; then
    # Only an existing marker proves this session already warned.
    (set -C; : >"$k") 2>/dev/null || { [ -e "$k" ] && warn=0; }
  fi
  [ "$warn" -eq 0 ] || echo "agent-guard: $root_var env not set, selected root was incomplete, or no installed binary was found$unchecked; $action because $because; reinstall or update the agent-guard plugin, then restart the host" >&2
  [ "$mode" = closed ] && exit 2
  exit 0
fi

AGENT_GUARD_HOOK_HOST=$host
export AGENT_GUARD_HOOK_HOST
[ "$mode" = closed ] && [ "$text" -eq 1 ] || exec "$x" "$sub"

# This shell stays to see how the binary ends. A background command reads
# /dev/null unless its input is another descriptor, hence 3.
got=
child=
trap 'got=1; [ -z "$child" ] || kill -TERM "$child" 2>/dev/null' TERM INT HUP
exec 3<&0
"$x" "$sub" <&3 3<&- &
child=$!
exec 3<&-
[ -z "$got" ] || kill -TERM "$child" 2>/dev/null
wait "$child"
s=$?
# A trapped signal ends that wait early; this one collects the binary.
[ -z "$got" ] || { wait "$child" 2>/dev/null; s=143; }
case "$s" in 0|2) exit "$s" ;; esac
echo "agent-guard: the hook ended with status $s before it finished its check$unchecked; blocking because $because; retry the call, and reinstall or update the agent-guard plugin if it keeps failing" >&2
exit 2
}
