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

# The reaper refuses a parent that its group can write, so fixture
# directories must not depend on the caller's umask (002 on some systems).
umask 022
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

# sh always; bash and dash (the launcher's choice where present) and busybox
# sh when installed. Both CI runners have bash and dash.
SHELLS=sh
for s in bash dash; do
  if p=$(command -v "$s" 2>/dev/null); then
    SHELLS="$SHELLS $p"
  else
    printf '# skip %s: not installed\n' "$s"
  fi
done
if command -v busybox >/dev/null 2>&1 && busybox sh -c : 2>/dev/null; then
  SHELLS="$SHELLS busybox-sh"
fi

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
  env HOME="$CASE/home" XDG_STATE_HOME="$3" TMPDIR="$2" AGENT_GUARD_LOG_MODE=on \
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
    state="$tmp-state"
    if ! start_guard "$sh_" "$tmp" "$state"; then
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
    if grep -q '"interrupted"' "$state"/agent-guard/event-* 2>/dev/null; then
      ok "$sh_: the support log records $sig as interrupted"
    else
      not_ok "$sh_: the support log records $sig as interrupted"
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
        env HOME="$CASE/home" XDG_STATE_HOME="$3" TMPDIR="$2" AGENT_GUARD_LOG_MODE=on \
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
  mkdir -m 755 "$t/agent-guard-run.Qr90St" "$t/agent-guard-run.999999996.Pm75Xx"
  mkdir -m 700 "$out/agent-guard-run.Uv12Wx"
  ln -s "$out/agent-guard-run.Uv12Wx" "$t/agent-guard-run.Yz34Ab"
  : >"$t/agent-guard-run.Cd56Ef"
  chmod 700 "$t/agent-guard-run.Cd56Ef"
  # Ages around the two limits: 61 minutes for a name with an owner PID,
  # a week for an older name without one.
  mkdir -m 700 "$t/agent-guard-run.999999998.Hh22Jj" "$t/agent-guard-run.999999997.Nw30Mn" "$t/agent-guard-run.Lg12Cy"
  age "$t/agent-guard-run.999999998.Hh22Jj" 7200
  age "$t/agent-guard-run.999999997.Nw30Mn" 1800
  age "$t/agent-guard-run.Lg12Cy" 172800
  # A newline in a stale name must not split off a record that names a
  # directory find never checked (here the new Fr12Sh).
  mkdir -m 700 "$t/agent-guard-run.Fr12Sh" "$t/agent-guard-run.Fr12Sh
1.Xy12Zw"
  touch -t "$OLD" "$t/agent-guard-run.Fr12Sh
1.Xy12Zw"
  mkdir -m 700 "$t/agent-guard-runner.Gh78Ij" "$t/agent-guard-run.Kl90" "$t/agent-guard.Mn12Op" "$t/agent-guard-run.12x.Qr34St"
  for e in agent-guard-run.Ab12Cd agent-guard-run.999999999.Ef34Gh "agent-guard-run.$live.Ij56Kl" \
      agent-guard-run.Qr90St agent-guard-run.999999996.Pm75Xx agent-guard-runner.Gh78Ij agent-guard-run.Kl90 agent-guard.Mn12Op \
      agent-guard-run.12x.Qr34St agent-guard-run.Cd56Ef; do
    touch -t "$OLD" "$t/$e"
  done
  touch -t "$OLD" "$out/agent-guard-run.Uv12Wx"
  touch -h -t "$OLD" "$t/agent-guard-run.Yz34Ab" 2>/dev/null || :
}

# age PATH SECONDS: sets the modification time SECONDS ago.
age() { perl -e 'utime(time, time - $ARGV[1], $ARGV[0]) or exit 1' "$1" "$2"; }

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
  printf '%s %s\n' "$((NOW - 3601))" "$tmp" >"$marker"
  reap_run "$sh_" "$tmp" "$state"
  bad=
  for e in agent-guard-run.Ab12Cd agent-guard-run.999999999.Ef34Gh agent-guard-run.999999998.Hh22Jj ${KILLED:+"${KILLED##*/}"}; do
    expect_gone "$tmp" "$e" || bad="$bad $e"
  done
  if [ -z "$bad" ]; then
    ok "$sh_: a due run removes stale private run directories with no live owner"
  else
    not_ok "$sh_: a due run removes stale private run directories with no live owner (kept:$bad)"
  fi
  bad=
  for e in "agent-guard-run.$live.Ij56Kl" agent-guard-run.Mn78Op agent-guard-run.Qr90St agent-guard-run.Yz34Ab \
      agent-guard-run.Cd56Ef agent-guard-runner.Gh78Ij agent-guard-run.Kl90 agent-guard.Mn12Op agent-guard-run.12x.Qr34St \
      agent-guard-run.999999997.Nw30Mn agent-guard-run.Lg12Cy agent-guard-run.Fr12Sh agent-guard-run.999999996.Pm75Xx "agent-guard-run.Fr12Sh
1.Xy12Zw"; do
    expect_kept "$tmp" "$e" || bad="$bad $e"
  done
  [ -f "$tmp-outside/keep" ] && [ -d "$tmp-outside/agent-guard-run.Uv12Wx" ] || bad="$bad <symlink target>"
  [ -z "$(run_dirs "$tmp" | grep -v -e Ij56Kl -e Mn78Op -e Qr90St -e Yz34Ab -e Cd56Ef -e Kl90 -e 12x -e Nw30Mn -e Lg12Cy -e Fr12Sh -e Pm75Xx -e '^1.Xy12Zw$')" ] || bad="$bad <a run directory that should be gone>"
  if [ -z "$bad" ]; then
    ok "$sh_: it keeps live, new, non-private, symlinked, non-directory and other-named entries and symlink targets"
  else
    not_ok "$sh_: it keeps live, new, non-private, symlinked, non-directory and other-named entries and symlink targets (wrong:$bad)"
  fi
  read -r stamp _ <"$marker" || stamp=
  if [ "${stamp:-0}" -ge "$NOW" ] 2>/dev/null; then
    ok "$sh_: the due run restarts the interval"
  else
    not_ok "$sh_: the due run restarts the interval (marker: $stamp)"
  fi

  # A marker with a leading zero is octal to shell arithmetic (dash aborts
  # on 08): it is read as no marker, and the hook still runs.
  mkdir -m 700 "$tmp/agent-guard-run.Oc08Zz"
  touch -t "$OLD" "$tmp/agent-guard-run.Oc08Zz"
  printf '08 %s\n' "$tmp" >"$marker"
  reap_run "$sh_" "$tmp" "$state"
  status=$?
  read -r stamp _ <"$marker" || stamp=
  if [ "$status" -eq 0 ] && [ "${stamp:-0}" -ge "$NOW" ] 2>/dev/null && expect_kept "$tmp" agent-guard-run.Oc08Zz; then
    ok "$sh_: a marker with a leading zero restarts the clock and the hook passes"
  else
    not_ok "$sh_: a marker with a leading zero restarts the clock and the hook passes (status $status, marker $stamp)"
  fi
  rm -rf "$tmp/agent-guard-run.Oc08Zz"

  # A clock set back (marker in the future) is due once, then waits again.
  mkdir -m 700 "$tmp/agent-guard-run.Zz99Yy"
  touch -t "$OLD" "$tmp/agent-guard-run.Zz99Yy"
  printf '%s %s\n' "$((NOW + 86400))" "$tmp" >"$marker"
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
printf '%s %s\n' "$((NOW - 3601))" "$CASE/link-tmp" >"$CASE/link-state/agent-guard/rundir-reap"
reap_run "$first_shell" "$CASE/link-tmp" "$CASE/link-state"
if expect_gone "$CASE/real-tmp" agent-guard-run.Ln12Kt && [ -L "$CASE/link-tmp" ]; then
  ok "a TMPDIR that is a symlink is reaped through and stays a symlink"
else
  not_ok "a TMPDIR that is a symlink is reaped through and stays a symlink"
fi

# Each temp directory keeps its own interval: a due run in one does not use
# up the other's.
mkdir -p "$CASE/pair-a" "$CASE/pair-b" "$CASE/pair-state/agent-guard"
chmod 700 "$CASE/pair-state/agent-guard"
for d in a b; do
  mkdir -m 700 "$CASE/pair-$d/agent-guard-run.Pr12$d$d"
  touch -t "$OLD" "$CASE/pair-$d/agent-guard-run.Pr12$d$d"
done
printf '%s %s\n%s %s\n' "$((NOW - 3601))" "$CASE/pair-a" "$((NOW - 3601))" "$CASE/pair-b" >"$CASE/pair-state/agent-guard/rundir-reap"
reap_run "$first_shell" "$CASE/pair-a" "$CASE/pair-state"
reap_run "$first_shell" "$CASE/pair-b" "$CASE/pair-state"
if expect_gone "$CASE/pair-a" agent-guard-run.Pr12aa && expect_gone "$CASE/pair-b" agent-guard-run.Pr12bb \
    && [ "$(grep -c . "$CASE/pair-state/agent-guard/rundir-reap")" -eq 2 ]; then
  ok "each temp directory has its own reap interval"
else
  not_ok "each temp directory has its own reap interval"
fi

# A marker that is a symlink is neither followed nor replaced, and nothing
# is reaped through it.
mkdir -p "$CASE/sym-tmp" "$CASE/sym-state/agent-guard"
chmod 700 "$CASE/sym-state/agent-guard"
printf 'victim\n' >"$CASE/victim"
ln -s "$CASE/victim" "$CASE/sym-state/agent-guard/rundir-reap"
mkdir -m 700 "$CASE/sym-tmp/agent-guard-run.Sy12Mk"
touch -t "$OLD" "$CASE/sym-tmp/agent-guard-run.Sy12Mk"
reap_run "$first_shell" "$CASE/sym-tmp" "$CASE/sym-state"
status=$?
if [ "$status" -eq 0 ] && [ "$(cat "$CASE/victim")" = victim ] && [ -L "$CASE/sym-state/agent-guard/rundir-reap" ] \
    && expect_kept "$CASE/sym-tmp" agent-guard-run.Sy12Mk; then
  ok "a symlinked marker is not followed, replaced or used"
else
  not_ok "a symlinked marker is not followed, replaced or used (status $status)"
fi

# stale_in TMP NAME: a stale private run directory TMP/NAME.
stale_in() { mkdir -p "$1" && mkdir -m 700 "$1/$2" && touch -t "$OLD" "$1/$2"; }
# due_run TMP STATE: one run in TMP with its interval already over.
due_run() {
  mkdir -p "$2/agent-guard" && chmod 700 "$2/agent-guard"
  printf '%s %s\n' "$((NOW - 3601))" "$1" >"$2/agent-guard/rundir-reap"
  reap_run "$first_shell" "$1" "$2"
}

# A parent where another user could swap an entry between the check and rm
# is not reaped; a sticky one is.
stale_in "$CASE/shared-tmp" agent-guard-run.Sh12Rd
chmod 777 "$CASE/shared-tmp"
due_run "$CASE/shared-tmp" "$CASE/shared-state"
stale_in "$CASE/sticky-tmp" agent-guard-run.St12Ky
chmod 1777 "$CASE/sticky-tmp"
due_run "$CASE/sticky-tmp" "$CASE/sticky-state"
if expect_kept "$CASE/shared-tmp" agent-guard-run.Sh12Rd && expect_gone "$CASE/sticky-tmp" agent-guard-run.St12Ky; then
  ok "reaping skips a shared parent without the sticky bit and works in a sticky one"
else
  not_ok "reaping skips a shared parent without the sticky bit and works in a sticky one"
fi
chmod 755 "$CASE/shared-tmp" "$CASE/sticky-tmp"

# Ineligible names, however many, do not hide an eligible directory.
mkdir -p "$CASE/many-tmp"
i=0
while [ "$i" -lt 2100 ]; do
  : >"$CASE/many-tmp/agent-guard-run.A$(printf '%05d' "$i")"
  i=$((i + 1))
done
stale_in "$CASE/many-tmp" agent-guard-run.zz99Zz
due_run "$CASE/many-tmp" "$CASE/many-state"
if expect_gone "$CASE/many-tmp" agent-guard-run.zz99Zz && expect_kept "$CASE/many-tmp" agent-guard-run.A00000; then
  ok "2,100 ineligible names do not keep an eligible directory from being reaped"
else
  not_ok "2,100 ineligible names do not keep an eligible directory from being reaped"
fi
rm -rf "$CASE/many-tmp"

# Seven retired directories in the marker and two in use, alternating: the
# least recent line goes, so both in use keep their clocks and get reaped.
mkdir -p "$CASE/lru-state/agent-guard"
chmod 700 "$CASE/lru-state/agent-guard"
: >"$CASE/lru-state/agent-guard/rundir-reap"
for i in 1 2 3 4 5 6 7; do
  printf '%s %s\n' "$NOW" "$CASE/retired-$i" >>"$CASE/lru-state/agent-guard/rundir-reap"
done
for d in a b; do
  mkdir -p "$CASE/lru-$d"
  reap_run "$first_shell" "$CASE/lru-$d" "$CASE/lru-state"
done
for d in a b; do
  stale_in "$CASE/lru-$d" "agent-guard-run.Lr12$d$d"
done
# Make both clocks due, keeping the order of the lines.
sed "s|^[0-9]* \($CASE/lru-\)|$((NOW - 3601)) \1|" "$CASE/lru-state/agent-guard/rundir-reap" >"$CASE/lru-marker"
cat "$CASE/lru-marker" >"$CASE/lru-state/agent-guard/rundir-reap"
reap_run "$first_shell" "$CASE/lru-a" "$CASE/lru-state"
reap_run "$first_shell" "$CASE/lru-b" "$CASE/lru-state"
if expect_gone "$CASE/lru-a" agent-guard-run.Lr12aa && expect_gone "$CASE/lru-b" agent-guard-run.Lr12bb \
    && [ "$(grep -c . "$CASE/lru-state/agent-guard/rundir-reap")" -le 8 ]; then
  ok "the marker drops its least recent directory, not one in use"
else
  not_ok "the marker drops its least recent directory, not one in use"
  sed "s|$CASE|<case>|; s/^/  /" "$CASE/lru-state/agent-guard/rundir-reap"
fi

# doctor counts what the reaper would remove and removes nothing; with no
# private state directory it says that nothing will.
DOC_TMP="$CASE/doctor-tmp"
fixture "$DOC_TMP"
before=$(find "$DOC_TMP" | LC_ALL=C sort)
for mode in on off; do
  env HOME="$CASE/home" XDG_STATE_HOME="$CASE/doctor-state" TMPDIR="$DOC_TMP" AGENT_GUARD_LOG_MODE=$mode \
    AGENT_GUARD_GITLEAKS_BIN="$ROOT/tests/fixtures/mock-gitleaks" AGENT_GUARD_RELEASE_CHECK=off \
    sh "$GUARD" doctor >"$CASE/doctor-out" 2>&1 </dev/null
  case $mode in
    on) want='temp: 3 stale run directories in [^ ]* (left by a killed run; a later hook or scan removes them' ;;
    off) want='temp: 3 stale run directories in [^ ]* (left by a killed run; nothing removes them while the private state directory is off' ;;
  esac
  after=$(find "$DOC_TMP" | LC_ALL=C sort)
  if grep -q "$want" "$CASE/doctor-out" && [ "$before" = "$after" ]; then
    ok "doctor (log $mode) counts stale run directories and removes none"
  else
    not_ok "doctor (log $mode) counts stale run directories and removes none"
    grep 'temp:' "$CASE/doctor-out" | sed 's/^/  /'
  fi
done
for p in $LIVE_PIDS; do kill -KILL "$p" 2>/dev/null || :; done
LIVE_PIDS=
# A state directory that fails its checks stops reaping, and doctor says so.
mkdir -p "$CASE/doctor-bad-state/agent-guard"
chmod 755 "$CASE/doctor-bad-state/agent-guard"
fixture "$CASE/doctor-bad-tmp"
env HOME="$CASE/home" XDG_STATE_HOME="$CASE/doctor-bad-state" TMPDIR="$CASE/doctor-bad-tmp" AGENT_GUARD_LOG_MODE=on \
  AGENT_GUARD_GITLEAKS_BIN="$ROOT/tests/fixtures/mock-gitleaks" AGENT_GUARD_RELEASE_CHECK=off \
  sh "$GUARD" doctor >"$CASE/doctor-out" 2>&1 </dev/null
if grep -q 'nothing removes them while the private state directory fails its ownership or mode check' "$CASE/doctor-out"; then
  ok "doctor says a state directory that fails its checks stops reaping"
else
  not_ok "doctor says a state directory that fails its checks stops reaping"
  grep 'temp:' "$CASE/doctor-out" | sed 's/^/  /'
fi
for p in $LIVE_PIDS; do kill -KILL "$p" 2>/dev/null || :; done
LIVE_PIDS=
mkdir "$CASE/doctor-empty"
env HOME="$CASE/home" XDG_STATE_HOME="$CASE/doctor-state" TMPDIR="$CASE/doctor-empty" \
  AGENT_GUARD_GITLEAKS_BIN="$ROOT/tests/fixtures/mock-gitleaks" AGENT_GUARD_RELEASE_CHECK=off \
  sh "$GUARD" doctor >"$CASE/doctor-out" 2>&1 </dev/null
if grep -q 'temp: no stale run directories in' "$CASE/doctor-out"; then
  ok "doctor says when there is no stale run directory"
else
  not_ok "doctor says when there is no stale run directory"
fi

printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]