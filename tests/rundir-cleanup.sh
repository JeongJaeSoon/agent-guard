#!/usr/bin/env sh
set -u

# The per-invocation run directory ($TMPDIR/agent-guard-run.*) holds scan
# temp files, such as gitleaks stdin captures, so a leftover can keep scanned
# text on disk. Two halves:
#
# 1. Signals. A host ends a hook by signalling its process group: Claude Code
#    sends TERM at the hook timeout (then KILL), a terminal sends HUP or INT.
#    Each catchable signal must remove the directory on every shell the CLI
#    runs under (bash 3.2 as macOS sh, dash as Debian/Ubuntu sh, busybox ash)
#    and end with 128 + the signal number. dash runs no EXIT trap for a signal
#    that has no trap of its own.
# 2. Reaping. A KILL (Codex kills the hook's group with it at the timeout)
#    runs no trap at all, so a later run removes stale run directories: only
#    its own name pattern, owned by the user, mode 0700, no symlink, older
#    than the reap age, and no live owner. At most once per interval, timed
#    by a marker in the private state directory; the first run only starts
#    that clock.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
GUARD=${AGENT_GUARD_TEST_BINARY:-$ROOT/plugins/agent-guard/bin/agent-guard}
CASE=$(mktemp -d "${TMPDIR:-/tmp}/rundir-cleanup.XXXXXX") || exit 1
[ -n "$CASE" ] || exit 1
# The state directory must be a plain absolute path (macOS /var is a symlink).
CASE=$(cd "$CASE" && pwd -P) || exit 1
LIVE_PIDS=
cleanup() {
  for p in $LIVE_PIDS; do kill -KILL "$p" 2>/dev/null || :; done
  rm -rf "$CASE"
}
trap cleanup 0
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

pass=0 fail=0
ok() { pass=$((pass + 1)); printf 'ok - %s\n' "$1"; }
not_ok() { fail=$((fail + 1)); printf 'not ok - %s\n' "$1"; }

# kill -SIG -- -PGID is not portable (dash rejects --); perl signals the group.
group_kill() { perl -e 'kill $ARGV[0], -$ARGV[1] or exit 1' "$1" "$2"; }

command -v perl >/dev/null 2>&1 || { printf 'not ok - perl is required to start the CLI in its own process group\n'; exit 1; }

# A gitleaks stand-in whose content scan blocks until it is signalled: the
# slow path a host timeout interrupts.
mkdir "$CASE/bin" || exit 1
sed "s|@ROOT@|$ROOT|g; s|@CASE@|$CASE|g" >"$CASE/bin/gitleaks" <<'STUB'
#!/bin/sh
case "${1:-}" in
  stdin|detect|dir) : >"@CASE@/scan-started"; sleep 10; exit 0 ;;
  *) exec "@ROOT@/tests/fixtures/mock-gitleaks" "$@" ;;
esac
STUB
chmod +x "$CASE/bin/gitleaks"

SHELLS=
for s in bash dash; do
  p=$(command -v "$s" 2>/dev/null) && SHELLS="$SHELLS $p"
done
if command -v busybox >/dev/null 2>&1 && busybox sh -c : 2>/dev/null; then
  SHELLS="$SHELLS busybox-sh"
fi
case "$SHELLS" in *dash*) ;; *) not_ok "dash is installed (the Debian/Ubuntu sh, and the launcher's choice where present)" ;; esac
case "$SHELLS" in *bash*) ;; *) not_ok "bash is installed" ;; esac

n=0
# start_guard SHELL TMP STATE: runs hook-pre-tool as the leader of its own
# process group (as Claude Code and Codex start a hook) with the default
# signal dispositions, in the background. Sets GUARD_PID.
start_guard() {
  n=$((n + 1))
  printf '{"session_id":"rundir-cleanup-%s-%s","tool_name":"Write","tool_input":{"file_path":"x.txt","content":"ordinary text"}}' "$$" "$n" >"$CASE/payload"
  case "$1" in busybox-sh) set -- "busybox sh" "$2" "$3" ;; esac
  rm -f "$CASE/scan-started"
  # $1 is unquoted so "busybox sh" splits into its two words.
  # shellcheck disable=SC2086
  env HOME="$CASE/home" XDG_STATE_HOME="$3" TMPDIR="$2" \
    AGENT_GUARD_GITLEAKS_BIN="$CASE/bin/gitleaks" AGENT_GUARD_RELEASE_CHECK=off \
    perl -e 'setpgrp(0, 0); $SIG{INT} = $SIG{QUIT} = $SIG{HUP} = $SIG{TERM} = "DEFAULT"; exec @ARGV or exit 127' \
      $1 "$GUARD" hook-pre-tool <"$CASE/payload" >"$CASE/out" 2>"$CASE/err" &
  GUARD_PID=$!
  i=0
  while [ ! -e "$CASE/scan-started" ] && [ "$i" -lt 150 ]; do
    i=$((i + 1))
    sleep 0.1
  done
  [ -e "$CASE/scan-started" ]
}

run_dirs() { find "$1" -mindepth 1 -maxdepth 1 -name 'agent-guard-run.*' 2>/dev/null; }

mkdir "$CASE/home" || exit 1
for sh_ in $SHELLS; do
  for sig in HUP INT TERM; do
    case $sig in HUP) want=129 ;; INT) want=130 ;; TERM) want=143 ;; esac
    tmp="$CASE/sig-$n-tmp"
    rm -rf "$tmp"; mkdir "$tmp"
    if ! start_guard "$sh_" "$tmp" "$CASE/sig-state"; then
      group_kill KILL "$GUARD_PID" 2>/dev/null || :
      wait "$GUARD_PID" 2>/dev/null
      not_ok "$sh_: the scan starts before $sig is sent"
      continue
    fi
    if [ -z "$(run_dirs "$tmp")" ]; then
      not_ok "$sh_: a run directory exists while the scan runs"
    fi
    group_kill "$sig" "$GUARD_PID"
    wait "$GUARD_PID"
    status=$?
    left=$(run_dirs "$tmp")
    if [ "$status" -eq "$want" ] && [ -z "$left" ]; then
      ok "$sh_: $sig to the hook's process group removes the run directory and exits $want"
    else
      not_ok "$sh_: $sig to the hook's process group removes the run directory and exits $want (status $status, left: ${left:+${left##*/}})"
    fi
  done
done

# Must-fail control for the check above: a KILL runs no trap, so the run
# directory stays. The reaper tests below start from that leftover.
KILL_TMP="$CASE/kill-tmp"
mkdir "$KILL_TMP" || exit 1
first_shell=${SHELLS# }
first_shell=${first_shell%% *}
if start_guard "$first_shell" "$KILL_TMP" "$CASE/kill-state"; then
  group_kill KILL "$GUARD_PID" 2>/dev/null
  wait "$GUARD_PID" 2>/dev/null
  KILLED=$(run_dirs "$KILL_TMP")
  if [ -n "$KILLED" ]; then
    ok "control: KILL leaves the run directory behind"
  else
    not_ok "control: KILL leaves the run directory behind"
  fi
else
  group_kill KILL "$GUARD_PID" 2>/dev/null || :
  wait "$GUARD_PID" 2>/dev/null
  KILLED=
  not_ok "control: the scan starts before KILL is sent"
fi

# --- reaping ---------------------------------------------------------------
OLD=202001010000
NOW=$(date +%s)
# reap_run SHELL TMP STATE: one ordinary hook run that finishes.
reap_run() {
  n=$((n + 1))
  sh_=$1
  case "$sh_" in busybox-sh) sh_="busybox sh" ;; esac
  printf '{"session_id":"rundir-reap-%s-%s","tool_name":"Read","tool_input":{"file_path":"%s/plain.txt"}}' "$$" "$n" "$CASE" \
    | { # shellcheck disable=SC2086
        env HOME="$CASE/home" XDG_STATE_HOME="$3" TMPDIR="$2" \
          AGENT_GUARD_GITLEAKS_BIN="$ROOT/tests/fixtures/mock-gitleaks" AGENT_GUARD_RELEASE_CHECK=off \
          $sh_ "$GUARD" hook-pre-tool >"$CASE/reap-out" 2>"$CASE/reap-err"; }
}
: >"$CASE/plain.txt"

# fixture TMP: every kind of entry the reaper must keep or remove.
fixture() {
  t=$1
  out=$t-outside
  mkdir -p "$t" "$out"
  : >"$out/keep"
  # Removed: stale, private, ours, no live owner.
  mkdir -m 700 "$t/agent-guard-run.Ab12Cd" "$t/agent-guard-run.999999999.Ef34Gh"
  printf 'scan capture\n' >"$t/agent-guard-run.Ab12Cd/agent-guard.Qw12Er"
  mkdir -m 700 "$t/agent-guard-run.Ab12Cd/pii.Zx34Cv"
  # A symlink inside a stale directory is removed, its target is not.
  ln -s "$out" "$t/agent-guard-run.Ab12Cd/link"
  # Kept: a live owner, too new, wrong mode, a symlink, a regular file,
  # names outside the pattern.
  sleep 60 &
  live=$!
  LIVE_PIDS="$LIVE_PIDS $live"
  mkdir -m 700 "$t/agent-guard-run.$live.Ij56Kl" "$t/agent-guard-run.Mn78Op"
  mkdir -m 755 "$t/agent-guard-run.Qr90St"
  mkdir -m 700 "$out/agent-guard-run.Uv12Wx"
  ln -s "$out/agent-guard-run.Uv12Wx" "$t/agent-guard-run.Yz34Ab"
  : >"$t/agent-guard-run.Cd56Ef"
  chmod 700 "$t/agent-guard-run.Cd56Ef"
  mkdir -m 700 "$t/agent-guard-runner.Gh78Ij" "$t/agent-guard-run.Kl90" "$t/agent-guard.Mn12Op" "$t/agent-guard-run.12x.Qr34St"
  for e in agent-guard-run.Ab12Cd agent-guard-run.999999999.Ef34Gh "agent-guard-run.$live.Ij56Kl" \
      agent-guard-run.Qr90St agent-guard-runner.Gh78Ij agent-guard-run.Kl90 agent-guard.Mn12Op \
      agent-guard-run.12x.Qr34St agent-guard-run.Cd56Ef; do
    touch -t "$OLD" "$t/$e"
  done
  touch -t "$OLD" "$out/agent-guard-run.Uv12Wx"
  touch -h -t "$OLD" "$t/agent-guard-run.Yz34Ab" 2>/dev/null || :
}

expect_gone() { [ ! -e "$1/$2" ] && [ ! -L "$1/$2" ]; }
expect_kept() { [ -e "$1/$2" ] || [ -L "$1/$2" ]; }

for sh_ in $SHELLS; do
  tmp="$CASE/reap-$n-tmp"
  state="$CASE/reap-$n-state"
  fixture "$tmp"
  [ -z "$KILLED" ] || { cp -R "$KILLED" "$tmp/" && chmod 700 "$tmp/${KILLED##*/}" && touch -t "$OLD" "$tmp/${KILLED##*/}"; }

  # First run: no marker yet, so it only starts the clock.
  reap_run "$sh_" "$tmp" "$state"
  marker="$state/agent-guard/rundir-reap"
  if [ -f "$marker" ] && expect_kept "$tmp" agent-guard-run.Ab12Cd; then
    ok "$sh_: the first run writes the reap marker and removes nothing"
  else
    not_ok "$sh_: the first run writes the reap marker and removes nothing"
  fi

  # Not due yet: a marker from just now leaves everything.
  reap_run "$sh_" "$tmp" "$state"
  if expect_kept "$tmp" agent-guard-run.Ab12Cd; then
    ok "$sh_: a run within the interval removes nothing"
  else
    not_ok "$sh_: a run within the interval removes nothing"
  fi

  # Due: the marker is an interval old.
  printf '%s\n' "$((NOW - 3601))" >"$marker"
  reap_run "$sh_" "$tmp" "$state"
  bad=
  for e in agent-guard-run.Ab12Cd agent-guard-run.999999999.Ef34Gh ${KILLED:+"${KILLED##*/}"}; do
    expect_gone "$tmp" "$e" || bad="$bad $e"
  done
  if [ -z "$bad" ]; then
    ok "$sh_: a due run removes stale private run directories with no live owner"
  else
    not_ok "$sh_: a due run removes stale private run directories with no live owner (kept:$bad)"
  fi
  bad=
  for e in "agent-guard-run.$live.Ij56Kl" agent-guard-run.Mn78Op agent-guard-run.Qr90St agent-guard-run.Yz34Ab \
      agent-guard-run.Cd56Ef agent-guard-runner.Gh78Ij agent-guard-run.Kl90 agent-guard.Mn12Op agent-guard-run.12x.Qr34St; do
    expect_kept "$tmp" "$e" || bad="$bad $e"
  done
  [ -f "$tmp-outside/keep" ] && [ -d "$tmp-outside/agent-guard-run.Uv12Wx" ] || bad="$bad <symlink target>"
  [ -z "$(run_dirs "$tmp" | grep -v -e Ij56Kl -e Mn78Op -e Qr90St -e Yz34Ab -e Cd56Ef -e Kl90 -e 12x)" ] || bad="$bad <a run directory that should be gone>"
  if [ -z "$bad" ]; then
    ok "$sh_: it keeps live, new, non-private, symlinked, non-directory and other-named entries and symlink targets"
  else
    not_ok "$sh_: it keeps live, new, non-private, symlinked, non-directory and other-named entries and symlink targets (wrong:$bad)"
  fi
  IFS= read -r stamp <"$marker" || stamp=
  if [ "${stamp:-0}" -ge "$NOW" ] 2>/dev/null; then
    ok "$sh_: the due run restarts the interval"
  else
    not_ok "$sh_: the due run restarts the interval (marker: $stamp)"
  fi

  # A clock set back (marker in the future) is due once, then waits again.
  mkdir -m 700 "$tmp/agent-guard-run.Zz99Yy"
  touch -t "$OLD" "$tmp/agent-guard-run.Zz99Yy"
  printf '%s\n' "$((NOW + 86400))" >"$marker"
  reap_run "$sh_" "$tmp" "$state"
  if expect_gone "$tmp" agent-guard-run.Zz99Yy; then
    ok "$sh_: a marker from the future does not stop reaping"
  else
    not_ok "$sh_: a marker from the future does not stop reaping"
  fi
  for p in $LIVE_PIDS; do kill -KILL "$p" 2>/dev/null || :; done
  LIVE_PIDS=
done

# TMPDIR may itself be a symlink (macOS /var/folders lives under /var ->
# /private/var); the reaper lists the directory it names, and nothing else.
mkdir -p "$CASE/real-tmp" "$CASE/link-state"
ln -s "$CASE/real-tmp" "$CASE/link-tmp"
mkdir -m 700 "$CASE/real-tmp/agent-guard-run.Ln12Kt"
touch -t "$OLD" "$CASE/real-tmp/agent-guard-run.Ln12Kt"
reap_run "$first_shell" "$CASE/link-tmp" "$CASE/link-state"
printf '%s\n' "$((NOW - 3601))" >"$CASE/link-state/agent-guard/rundir-reap"
reap_run "$first_shell" "$CASE/link-tmp" "$CASE/link-state"
if expect_gone "$CASE/real-tmp" agent-guard-run.Ln12Kt && [ -L "$CASE/link-tmp" ]; then
  ok "a TMPDIR that is a symlink is reaped through and stays a symlink"
else
  not_ok "a TMPDIR that is a symlink is reaped through and stays a symlink"
fi

printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]