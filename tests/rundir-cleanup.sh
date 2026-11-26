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
mkdir "$CASE/launch-bin" || exit 1
real_setsid=$(command -v setsid 2>/dev/null) || real_setsid=
sed "s|@CASE@|$CASE|g; s|@REAL@|$real_setsid|g" >"$CASE/launch-bin/setsid" <<'STUB'
#!/bin/sh
# The gitleaks probe uses setsid too; record only the reap pass.
case " $* " in
  *" __reap-run-dirs "*)
    printf '%s\n' "$$" >>"@CASE@/reaper-pids"
    [ ! -e "@CASE@/slow-reap" ] || sleep 6
    ;;
esac
[ -z "@REAL@" ] || exec "@REAL@" "$@"
exec perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV or exit 126' "$@"
STUB
chmod +x "$CASE/launch-bin/setsid"

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
  env HOME="$CASE/home" XDG_STATE_HOME="$3" TMPDIR="$2" AGENT_GUARD_LOG_MODE=on AGENT_GUARD_SCAN_CACHE=off \
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
  : >"$CASE/reaper-pids"
  printf '{"session_id":"rundir-reap-%s-%s","tool_name":"Read","tool_input":{"file_path":"%s/plain.txt"}}' "$$" "$n" "$CASE" \
    | { # shellcheck disable=SC2086
        env HOME="$CASE/home" XDG_STATE_HOME="$3" TMPDIR="$2" AGENT_GUARD_LOG_MODE=on AGENT_GUARD_SCAN_CACHE=off \
          PATH="$CASE/launch-bin:$PATH" AGENT_GUARD_GITLEAKS_BIN="$ROOT/tests/fixtures/mock-gitleaks" AGENT_GUARD_RELEASE_CHECK=off \
          $sh_ "$GUARD" hook-pre-tool >"$CASE/reap-out" 2>"$CASE/reap-err"; }
}
: >"$CASE/plain.txt"

# reap_wait: a due run starts the pass detached and does not wait for it.
# The setsid on the runs' PATH records the pass's PID (exec keeps it) before
# it hands over to the real setsid, or perl where there is none.
reap_wait() {
  rw_i=0
  while [ ! -s "$CASE/reaper-pids" ] && [ "$rw_i" -lt 200 ]; do
    rw_i=$((rw_i + 1))
    sleep 0.05
  done
  rw_pid=$(tail -n 1 "$CASE/reaper-pids" 2>/dev/null)
  rw_i=0
  while [ -n "$rw_pid" ] && kill -0 "$rw_pid" 2>/dev/null && [ "$rw_i" -lt 400 ]; do
    rw_i=$((rw_i + 1))
    sleep 0.05
  done
}

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
  reap_wait
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

  # A time with a leading zero is octal to shell arithmetic (dash aborts on
  # 08): the line is ignored, so the directory counts as missing (due), and
  # the hook still runs.
  mkdir -m 700 "$tmp/agent-guard-run.Oc08Zz"
  touch -t "$OLD" "$tmp/agent-guard-run.Oc08Zz"
  printf '08 %s\n' "$tmp" >"$marker"
  reap_run "$sh_" "$tmp" "$state"
  status=$?
  reap_wait
  read -r stamp _ <"$marker" || stamp=
  if [ "$status" -eq 0 ] && [ "${stamp:-0}" -ge "$NOW" ] 2>/dev/null && expect_gone "$tmp" agent-guard-run.Oc08Zz; then
    ok "$sh_: a time with a leading zero is ignored and the hook passes"
  else
    not_ok "$sh_: a time with a leading zero is ignored and the hook passes (status $status, marker $stamp)"
  fi
  rm -rf "$tmp/agent-guard-run.Oc08Zz"

  # A clock set back (marker in the future) is due once, then waits again.
  mkdir -m 700 "$tmp/agent-guard-run.Zz99Yy"
  touch -t "$OLD" "$tmp/agent-guard-run.Zz99Yy"
  printf '%s %s\n' "$((NOW + 86400))" "$tmp" >"$marker"
  reap_run "$sh_" "$tmp" "$state"
  reap_wait
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
reap_wait
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
reap_wait
reap_run "$first_shell" "$CASE/pair-b" "$CASE/pair-state"
reap_wait
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
  reap_wait
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

# A directory missing from an existing marker (its line was dropped, or it
# is new) is due at once.
stale_in "$CASE/missing-tmp" agent-guard-run.Mi12Ss
mkdir -p "$CASE/missing-state/agent-guard" && chmod 700 "$CASE/missing-state/agent-guard"
printf '%s %s\n' "$NOW" "$CASE/elsewhere" >"$CASE/missing-state/agent-guard/rundir-reap"
reap_run "$first_shell" "$CASE/missing-tmp" "$CASE/missing-state"
reap_wait
if expect_gone "$CASE/missing-tmp" agent-guard-run.Mi12Ss; then
  ok "a directory missing from an existing marker is reaped at once"
else
  not_ok "a directory missing from an existing marker is reaped at once"
fi

# A relative TMPDIR names a different directory from each working directory,
# so it is not reaped.
stale_in "$CASE/rel/tmp" agent-guard-run.Re12La
mkdir -p "$CASE/rel-state/agent-guard" && chmod 700 "$CASE/rel-state/agent-guard"
printf '%s %s\n' "$NOW" "$CASE/elsewhere" >"$CASE/rel-state/agent-guard/rundir-reap"
(cd "$CASE/rel" && reap_run "$first_shell" tmp "$CASE/rel-state")
if expect_kept "$CASE/rel/tmp" agent-guard-run.Re12La; then
  ok "a relative TMPDIR is not reaped"
else
  not_ok "a relative TMPDIR is not reaped"
fi

# macOS: an ACL that lets others add or delete entries makes the parent
# unsafe even at mode 0755.
if [ "$(uname -s)" = Darwin ]; then
  stale_in "$CASE/acl-tmp" agent-guard-run.Ac12Ls
  if chmod +a "everyone allow add_subdirectory,delete_child" "$CASE/acl-tmp" 2>/dev/null; then
    due_run "$CASE/acl-tmp" "$CASE/acl-state"
    if expect_kept "$CASE/acl-tmp" agent-guard-run.Ac12Ls; then
      ok "a parent with an allow ACL is not reaped"
    else
      not_ok "a parent with an allow ACL is not reaped"
    fi
    chmod -N "$CASE/acl-tmp" 2>/dev/null || :
  fi
fi

# The hook does not wait for the pass: a pass that takes 6 s leaves the hook
# well inside its time limit, and still finishes afterwards.
stale_in "$CASE/slow-tmp" agent-guard-run.Sl12Ow
: >"$CASE/slow-reap"
slow_start=$(perl -MTime::HiRes=time -e 'printf "%d", time * 1000')
due_run_nowait() {
  mkdir -p "$2/agent-guard" && chmod 700 "$2/agent-guard"
  printf '%s %s\n' "$((NOW - 3601))" "$1" >"$2/agent-guard/rundir-reap"
  reap_run "$first_shell" "$1" "$2"
}
due_run_nowait "$CASE/slow-tmp" "$CASE/slow-state"
slow_ms=$(( $(perl -MTime::HiRes=time -e 'printf "%d", time * 1000') - slow_start ))
reap_wait
rm -f "$CASE/slow-reap"
if [ "$slow_ms" -lt 4000 ] && expect_gone "$CASE/slow-tmp" agent-guard-run.Sl12Ow; then
  ok "the hook returns without waiting for a slow reap pass, which still completes"
else
  not_ok "the hook returns without waiting for a slow reap pass, which still completes (hook took ${slow_ms} ms)"
fi

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

# Seven retired directories in the marker and two in use, alternating: both
# in use get reaped, and the marker stays at 8 lines.
mkdir -p "$CASE/lru-state/agent-guard"
chmod 700 "$CASE/lru-state/agent-guard"
: >"$CASE/lru-state/agent-guard/rundir-reap"
for i in 1 2 3 4 5 6 7; do
  printf '%s %s\n' "$NOW" "$CASE/retired-$i" >>"$CASE/lru-state/agent-guard/rundir-reap"
done
for d in a b; do
  mkdir -p "$CASE/lru-$d"
  reap_run "$first_shell" "$CASE/lru-$d" "$CASE/lru-state"
  reap_wait
done
for d in a b; do
  stale_in "$CASE/lru-$d" "agent-guard-run.Lr12$d$d"
done
# Make both clocks due, keeping the order of the lines.
sed "s|^[0-9]* \($CASE/lru-\)|$((NOW - 3601)) \1|" "$CASE/lru-state/agent-guard/rundir-reap" >"$CASE/lru-marker"
cat "$CASE/lru-marker" >"$CASE/lru-state/agent-guard/rundir-reap"
reap_run "$first_shell" "$CASE/lru-a" "$CASE/lru-state"
reap_wait
reap_run "$first_shell" "$CASE/lru-b" "$CASE/lru-state"
reap_wait
if expect_gone "$CASE/lru-a" agent-guard-run.Lr12aa && expect_gone "$CASE/lru-b" agent-guard-run.Lr12bb \
    && [ "$(grep -c . "$CASE/lru-state/agent-guard/rundir-reap")" -le 8 ]; then
  ok "two alternating directories beside seven retired ones both get reaped"
else
  not_ok "two alternating directories beside seven retired ones both get reaped"
  sed "s|$CASE|<case>|; s/^/  /" "$CASE/lru-state/agent-guard/rundir-reap"
fi

# doctor counts what the reaper would remove and removes nothing; with no
# private state directory it says that nothing will.
DOC_TMP="$CASE/doctor-tmp"
fixture "$DOC_TMP"
before=$(find "$DOC_TMP" | LC_ALL=C sort)
for mode in on off; do
  env HOME="$CASE/home" XDG_STATE_HOME="$CASE/doctor-state" TMPDIR="$DOC_TMP" AGENT_GUARD_LOG_MODE=$mode AGENT_GUARD_SCAN_CACHE=off \
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
# A shared parent is counted (read-only) and doctor says why it stays.
chmod 777 "$CASE/shared-tmp"
env HOME="$CASE/home" XDG_STATE_HOME="$CASE/doctor-state" TMPDIR="$CASE/shared-tmp" AGENT_GUARD_LOG_MODE=on AGENT_GUARD_SCAN_CACHE=off \
  AGENT_GUARD_GITLEAKS_BIN="$ROOT/tests/fixtures/mock-gitleaks" AGENT_GUARD_RELEASE_CHECK=off \
  sh "$GUARD" doctor >"$CASE/doctor-out" 2>&1 </dev/null
chmod 755 "$CASE/shared-tmp"
if grep -q 'temp: 1 stale run directories in .*nothing removes them while other users can change entries in that directory' "$CASE/doctor-out"; then
  ok "doctor counts a shared parent's leftovers and says why they stay"
else
  not_ok "doctor counts a shared parent's leftovers and says why they stay"
  grep 'temp:' "$CASE/doctor-out" | sed 's/^/  /'
fi

# A state directory that fails its checks stops reaping, and doctor says so.
mkdir -p "$CASE/doctor-bad-state/agent-guard"
chmod 755 "$CASE/doctor-bad-state/agent-guard"
fixture "$CASE/doctor-bad-tmp"
env HOME="$CASE/home" XDG_STATE_HOME="$CASE/doctor-bad-state" TMPDIR="$CASE/doctor-bad-tmp" AGENT_GUARD_LOG_MODE=on AGENT_GUARD_SCAN_CACHE=off \
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
# The first marker is private (0600) whatever the umask.
mkdir -p "$CASE/mode-tmp"
reap_run "$first_shell" "$CASE/mode-tmp" "$CASE/mode-state"
if [ "$(ls -l "$CASE/mode-state/agent-guard/rundir-reap" 2>/dev/null | cut -c1-10)" = "-rw-------" ]; then
  ok "the first reap marker is created with mode 0600"
else
  not_ok "the first reap marker is created with mode 0600"
fi

# A TMPDIR that cannot be listed is reported as such, not as clean.
mkdir -p "$CASE/unlisted-tmp"
stale_in "$CASE/unlisted-tmp" agent-guard-run.Un12Ls
chmod 300 "$CASE/unlisted-tmp"
env HOME="$CASE/home" XDG_STATE_HOME="$CASE/doctor-state" TMPDIR="$CASE/unlisted-tmp" AGENT_GUARD_LOG_MODE=on AGENT_GUARD_SCAN_CACHE=off \
  AGENT_GUARD_GITLEAKS_BIN="$ROOT/tests/fixtures/mock-gitleaks" AGENT_GUARD_RELEASE_CHECK=off \
  sh "$GUARD" doctor >"$CASE/doctor-out" 2>&1 </dev/null
chmod 755 "$CASE/unlisted-tmp"
if grep -q 'temp: could not list .* to look for stale run directories' "$CASE/doctor-out"; then
  ok "doctor says when it cannot list the temp directory"
else
  not_ok "doctor says when it cannot list the temp directory"
  grep 'temp:' "$CASE/doctor-out" | sed 's/^/  /'
fi
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