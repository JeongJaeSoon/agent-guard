#!/usr/bin/env sh
# Direct contract for plugins/agent-guard/hooks/launch.sh, the v1 hook
# launcher every plugin manifest command delegates to. It drives
# `sh launch.sh <host> <hook-subcommand> <host-selected-root>` for both hosts
# over a fake plugin cache, so it proves root selection, recovery and the
# infrastructure-failure policy without the CLI. It cannot prove that a real
# host runs the manifest command or shows its stderr.
# Kept out of tests/run.sh: the monolith is already near ShellCheck's memory
# limit in CI, so each added line there risks the Lint job.
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
LAUNCHER="$ROOT/plugins/agent-guard/hooks/launch.sh"
GUARD="$ROOT/plugins/agent-guard/bin/agent-guard"
CASE=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-hook-launcher.XXXXXX") || exit 1
[ -n "$CASE" ] || exit 1
CASE=$(CDPATH= cd -- "$CASE" && pwd -P) || exit 1
trap 'chmod -R u+w "$CASE" 2>/dev/null; rm -rf "$CASE"' EXIT HUP INT TERM
OUT="$CASE/out"
ERR="$CASE/err"
unset AGENT_GUARD_SESSION_ID AGENT_GUARD_INFRA_FAILURE_MODE AGENT_GUARD_WARNING_DIR

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok - %s\n' "$1"; }
bad() {
  fail=$((fail + 1))
  printf 'not ok - %s\n' "$1"
  [ ! -s "$OUT" ] || sed 's/^/  stdout: /' "$OUT"
  [ ! -s "$ERR" ] || sed 's/^/  stderr: /' "$ERR"
}

# fake_version CACHE VERSION [EMBEDDED_VERSION [complete|binary-only [BODY]]]
fake_version() {
  fv_dir="$1/$2"
  mkdir -p "$fv_dir/bin" "$fv_dir/hooks"
  # shellcheck disable=SC2016 # expanded by the fake binary, not here
  fv_default='printf "selected-%s host=%s argc=%s args=%s\n" "$FV" "${AGENT_GUARD_HOOK_HOST-}" "$#" "$*"'
  {
    printf '#!/usr/bin/env sh\nVERSION=%s\nFV=%s\n' "${3:-$2}" "$2"
    printf '%s\n' "${5:-$fv_default}"
  } >"$fv_dir/bin/agent-guard"
  chmod +x "$fv_dir/bin/agent-guard"
  cp "$LAUNCHER" "$fv_dir/hooks/launch.sh"
  if [ "${4:-complete}" = complete ]; then
    mkdir -p "$fv_dir/config"
    : >"$fv_dir/config/gitleaks.toml"
    : >"$fv_dir/config/deny-read-paths.txt"
    : >"$fv_dir/config/deny-bash-patterns.txt"
  fi
}

# The matrix: two complete semver versions, a complete non-semver directory
# that sorts highest, a higher binary-only (interrupted) version, and a
# complete directory whose binary embeds a different version.
make_cache() {
  rm -rf "$1"
  mkdir -p "$1"
  fake_version "$1" 3.0.9
  fake_version "$1" 3.0.10
  fake_version "$1" 99.0.0beta
  fake_version "$1" 4.0.0 4.0.0 binary-only
  fake_version "$1" 5.0.0 5.0.1
}

count() { # count PATTERN FILE
  c=$(grep -c "$1" "$2" 2>/dev/null) || c=0
  printf '%s\n' "$c"
}

if grep -Fq 'interface v1 (frozen)' "$LAUNCHER" && [ -f "$LAUNCHER" ] && [ ! -L "$LAUNCHER" ]; then
  ok "launcher is a regular file that declares the frozen v1 interface"
else
  bad "launcher is a regular file that declares the frozen v1 interface"
fi

shells=sh
for candidate in dash bash; do
  command -v "$candidate" >/dev/null 2>&1 && shells="$shells $candidate"
done

NO_JQ_PATH="$CASE/no-jq-path"
mkdir -p "$NO_JQ_PATH"
for utility in sh dash bash awk sort tail cut cksum mkdir readlink id env; do
  utility_path=$(command -v "$utility" 2>/dev/null) || continue
  ln -s "$utility_path" "$NO_JQ_PATH/$utility"
done
if [ -e "$NO_JQ_PATH/jq" ] || PATH="$NO_JQ_PATH" command -v jq >/dev/null 2>&1; then
  printf 'Bail out! no-jq PATH still finds jq\n'
  exit 1
fi

for shell in $shells; do
  for host in claude codex; do
    case "$host" in
      claude) root_var=CLAUDE_PLUGIN_ROOT ;;
      *) root_var=PLUGIN_ROOT ;;
    esac
    T="$shell/$host"
    C="$CASE/cache-$shell-$host"
    W="$CASE/warn-$shell-$host"
    make_cache "$C"
    L="$C/3.0.9/hooks/launch.sh"

    # 1. A complete host-selected root is authoritative over higher siblings.
    printf '{}' | "$shell" "$L" "$host" hook-pre-tool "$C/3.0.9" >"$OUT" 2>"$ERR"
    status=$?
    if [ "$status" -eq 0 ] && [ "$(cat "$OUT")" = "selected-3.0.9 host=$host argc=1 args=hook-pre-tool" ] \
       && [ ! -s "$ERR" ] && [ ! -e "$C/current" ]; then
      ok "$T: the complete host-selected root is authoritative"
    else
      bad "$T: the complete host-selected root is authoritative (status $status)"
    fi

    # 2. Deleted root, no current: the highest complete semver sibling. The
    # non-semver, binary-only and version-mismatched directories never win.
    printf '{}' | "$shell" "$L" "$host" hook-stop "$C/3.0.0" >"$OUT" 2>"$ERR"
    status=$?
    if [ "$status" -eq 0 ] && [ "$(cat "$OUT")" = "selected-3.0.10 host=$host argc=1 args=hook-stop" ]; then
      ok "$T: a deleted root recovers the highest complete semver sibling"
    else
      bad "$T: a deleted root recovers the highest complete semver sibling (status $status)"
    fi

    # 3. Deleted root with a complete `current`: current wins over siblings.
    ln -s 3.0.9 "$C/current"
    printf '{}' | "$shell" "$L" "$host" hook-stop "$C/3.0.0" >"$OUT" 2>"$ERR"
    status=$?
    if [ "$status" -eq 0 ] && [ "$(cat "$OUT")" = "selected-3.0.9 host=$host argc=1 args=hook-stop" ]; then
      ok "$T: a deleted root recovers through a complete current"
    else
      bad "$T: a deleted root recovers through a complete current (status $status)"
    fi

    # 4. Dangling current: the highest complete semver sibling.
    rm -f "$C/current"
    ln -s 2.0.0 "$C/current"
    printf '{}' | "$shell" "$L" "$host" hook-stop "$C/3.0.0" >"$OUT" 2>"$ERR"
    status=$?
    if [ "$status" -eq 0 ] && [ "$(cat "$OUT")" = "selected-3.0.10 host=$host argc=1 args=hook-stop" ]; then
      ok "$T: a dangling current falls back to the highest complete semver sibling"
    else
      bad "$T: a dangling current falls back to the highest complete semver sibling (status $status)"
    fi
    rm -f "$C/current"

    # 5. An existing but incomplete root is refused with no substitution, in
    # both policies, even though complete siblings exist.
    for incomplete in 4.0.0 5.0.0; do
      printf '{"session_id":"incomplete-%s"}' "$incomplete" \
        | AGENT_GUARD_WARNING_DIR="$W-incomplete-$incomplete" \
          "$shell" "$L" "$host" hook-pre-tool "$C/$incomplete" >"$OUT" 2>"$ERR"
      status=$?
      if [ "$status" -eq 0 ] && [ ! -s "$OUT" ] \
         && grep -Fq "agent-guard: $root_var env not set, selected root was incomplete, or no installed binary was found; continuing because AGENT_GUARD_INFRA_FAILURE_MODE=open" "$ERR"; then
        ok "$T: an existing incomplete root $incomplete is refused without sibling substitution (open)"
      else
        bad "$T: an existing incomplete root $incomplete is refused without sibling substitution (open, status $status)"
      fi
      printf '{"session_id":"incomplete-%s"}' "$incomplete" \
        | AGENT_GUARD_WARNING_DIR="$W-incomplete-$incomplete" AGENT_GUARD_INFRA_FAILURE_MODE=closed \
          "$shell" "$L" "$host" hook-pre-tool "$C/$incomplete" >"$OUT" 2>"$ERR"
      status=$?
      if [ "$status" -eq 2 ] && [ ! -s "$OUT" ] \
         && grep -Fq 'selected root was incomplete' "$ERR" \
         && grep -Fq 'blocking because AGENT_GUARD_INFRA_FAILURE_MODE=closed' "$ERR"; then
        ok "$T: an existing incomplete root $incomplete is refused without sibling substitution (closed)"
      else
        bad "$T: an existing incomplete root $incomplete is refused without sibling substitution (closed, status $status)"
      fi
    done

    # 6. Closed mode explains every block, including repeats in one session
    # and an unrecognised mode value falling back to open.
    for attempt in first second; do
      printf '{"session_id":"closed-repeat"}' \
        | AGENT_GUARD_WARNING_DIR="$W-closed" AGENT_GUARD_INFRA_FAILURE_MODE=closed \
          "$shell" "$L" "$host" hook-pre-tool "$CASE/missing/0.0.0" >"$OUT" 2>"$ERR"
      status=$?
      if [ "$status" -eq 2 ] && grep -Fq 'blocking because AGENT_GUARD_INFRA_FAILURE_MODE=closed' "$ERR"; then
        ok "$T: closed mode explains the $attempt block in a session"
      else
        bad "$T: closed mode explains the $attempt block in a session (status $status)"
      fi
    done
    printf '{"session_id":"odd-mode"}' \
      | AGENT_GUARD_WARNING_DIR="$W-odd" AGENT_GUARD_INFRA_FAILURE_MODE=sometimes \
        "$shell" "$L" "$host" hook-pre-tool "$CASE/missing/0.0.0" >"$OUT" 2>"$ERR"
    status=$?
    if [ "$status" -eq 0 ] && grep -Fq 'continuing because AGENT_GUARD_INFRA_FAILURE_MODE=open' "$ERR"; then
      ok "$T: an unrecognised policy value is treated as open"
    else
      bad "$T: an unrecognised policy value is treated as open (status $status)"
    fi

    # 7. Open mode warns once per session across changing parents (Linux
    # starts each hook under a different parent), keyed by session_id.
    : >"$ERR"
    for sub in hook-pre-tool hook-post-tool hook-stop hook-session-start; do
      printf '{"session_id":"open-once"}' \
        | AGENT_GUARD_WARNING_DIR="$W-once" \
          "$shell" -c '"$0" "$1" "$2" "$3" "$4"; :' "$shell" "$L" "$host" "$sub" "$CASE/missing/0.0.0" \
          >"$OUT" 2>>"$ERR"
    done
    if [ "$(count 'no installed binary was found' "$ERR")" -eq 1 ] \
       && grep -Fq 'continuing because AGENT_GUARD_INFRA_FAILURE_MODE=open' "$ERR"; then
      ok "$T: the open warning is deduplicated by session across changing parents"
    else
      bad "$T: the open warning is deduplicated by session across changing parents (count $(count 'no installed binary was found' "$ERR"))"
    fi
    # A different session in the same directory warns again.
    printf '{"session_id":"open-twice"}' \
      | AGENT_GUARD_WARNING_DIR="$W-once" \
        "$shell" "$L" "$host" hook-stop "$CASE/missing/0.0.0" >"$OUT" 2>"$ERR"
    if [ "$(count 'no installed binary was found' "$ERR")" -eq 1 ]; then
      ok "$T: a new session gets its own open warning"
    else
      bad "$T: a new session gets its own open warning"
    fi

    # 8. AGENT_GUARD_SESSION_ID overrides the payload's session_id.
    : >"$ERR"
    for sub in hook-pre-tool hook-post-tool; do
      printf '{"session_id":"payload-%s"}' "$sub" \
        | AGENT_GUARD_SESSION_ID=launcher-override AGENT_GUARD_WARNING_DIR="$W-override" \
          "$shell" "$L" "$host" "$sub" "$CASE/missing/0.0.0" >"$OUT" 2>>"$ERR"
    done
    if [ "$(count 'no installed binary was found' "$ERR")" -eq 1 ]; then
      ok "$T: AGENT_GUARD_SESSION_ID overrides the payload session"
    else
      bad "$T: AGENT_GUARD_SESSION_ID overrides the payload session (count $(count 'no installed binary was found' "$ERR"))"
    fi

    # 9. Without jq the compact session_id is parsed by the shell. Same id
    # across parents warns once; two ids under ONE parent warn twice, which
    # a parent-PID fallback could not produce.
    : >"$ERR"
    for sub in hook-pre-tool hook-post-tool hook-stop; do
      printf '{"session_id":"no-jq"}' \
        | PATH="$NO_JQ_PATH" AGENT_GUARD_WARNING_DIR="$W-nojq" \
          "$shell" -c '"$0" "$1" "$2" "$3" "$4"; :' "$shell" "$L" "$host" "$sub" "$CASE/missing/0.0.0" \
          >"$OUT" 2>>"$ERR"
    done
    if [ "$(count 'no installed binary was found' "$ERR")" -eq 1 ]; then
      ok "$T: without jq the compact session_id deduplicates across parents"
    else
      bad "$T: without jq the compact session_id deduplicates across parents (count $(count 'no installed binary was found' "$ERR"))"
    fi
    printf '{"tool_name":"Bash","session_id":"no-jq-a"}' >"$CASE/payload-a"
    printf '{"tool_name":"Bash","session_id":"no-jq-b"}' >"$CASE/payload-b"
    PATH="$NO_JQ_PATH" AGENT_GUARD_WARNING_DIR="$W-nojq-two" \
      "$shell" -c '"$0" "$1" "$2" "$3" "$4" <"$5"; "$0" "$1" "$2" "$3" "$4" <"$6"; :' \
      "$shell" "$L" "$host" hook-stop "$CASE/missing/0.0.0" "$CASE/payload-a" "$CASE/payload-b" \
      >"$OUT" 2>"$ERR"
    if [ "$(count 'no installed binary was found' "$ERR")" -eq 2 ]; then
      ok "$T: without jq distinct session ids under one parent warn separately"
    else
      bad "$T: without jq distinct session ids under one parent warn separately (count $(count 'no installed binary was found' "$ERR"))"
    fi

    # 10. No session at all: the parent PID keys the marker.
    "$shell" -c 'printf "{}" | "$0" "$1" "$2" "$3" "$4"; printf "{}" | "$0" "$1" "$2" "$3" "$4"; :' \
      "$shell" "$L" "$host" hook-stop "$CASE/missing/0.0.0" >"$OUT" 2>"$ERR" \
      </dev/null
    one_parent=$(count 'no installed binary was found' "$ERR")
    : >"$ERR"
    for attempt in 1 2; do
      printf '{}' | AGENT_GUARD_WARNING_DIR="$W-ppid" \
        "$shell" -c '"$0" "$1" "$2" "$3" "$4"; :' "$shell" "$L" "$host" hook-stop "$CASE/missing/0.0.0" \
        >"$OUT" 2>>"$ERR"
    done
    if [ "$one_parent" -eq 1 ] && [ "$(count 'no installed binary was found' "$ERR")" -eq 2 ]; then
      ok "$T: without a session id the parent PID keys the open warning"
    else
      bad "$T: without a session id the parent PID keys the open warning (one parent $one_parent, two parents $(count 'no installed binary was found' "$ERR"))"
    fi

    # 11. A marker that cannot be written is not proof of an earlier warning.
    : >"$CASE/not-a-dir"
    : >"$ERR"
    for attempt in 1 2; do
      printf '{"session_id":"unwritable"}' \
        | AGENT_GUARD_WARNING_DIR="$CASE/not-a-dir/warnings" \
          "$shell" "$L" "$host" hook-stop "$CASE/missing/0.0.0" >"$OUT" 2>>"$ERR"
      status=$?
      [ "$status" -eq 0 ] || break
    done
    if [ "$status" -eq 0 ] && [ "$(count 'continuing because AGENT_GUARD_INFRA_FAILURE_MODE=open' "$ERR")" -eq 2 ]; then
      ok "$T: an uncreatable warning dir still warns on every call"
    else
      bad "$T: an uncreatable warning dir still warns on every call (status $status)"
    fi
    if [ "$(id -u)" -ne 0 ]; then
      mkdir -p "$W-readonly"
      chmod 0500 "$W-readonly"
      printf '{"session_id":"readonly"}' \
        | AGENT_GUARD_WARNING_DIR="$W-readonly" \
          "$shell" "$L" "$host" hook-stop "$CASE/missing/0.0.0" >"$OUT" 2>"$ERR"
      status=$?
      chmod 0700 "$W-readonly"
      if [ "$status" -eq 0 ] && grep -Fq 'continuing because AGENT_GUARD_INFRA_FAILURE_MODE=open' "$ERR"; then
        ok "$T: a read-only warning dir still warns"
      else
        bad "$T: a read-only warning dir still warns (status $status)"
      fi
    fi

    # 12. stdin reaches the binary byte for byte.
    S="$CASE/stdin-$shell-$host"
    rm -rf "$S"
    mkdir -p "$S"
    fake_version "$S" 3.0.10 3.0.10 complete 'cat'
    printf '{"session_id":"stdin",\n"tool_input":{"command":"printf \\"a\\tb\\""}}\n\n  trailing' >"$CASE/stdin-payload"
    "$shell" "$S/3.0.10/hooks/launch.sh" "$host" hook-pre-tool "$S/3.0.10" \
      <"$CASE/stdin-payload" >"$OUT" 2>"$ERR"
    status=$?
    if [ "$status" -eq 0 ] && cmp -s "$CASE/stdin-payload" "$OUT"; then
      ok "$T: stdin reaches the selected binary intact"
    else
      bad "$T: stdin reaches the selected binary intact (status $status)"
    fi
    "$shell" "$S/3.0.10/hooks/launch.sh" "$host" hook-pre-tool "$S/3.0.0" \
      <"$CASE/stdin-payload" >"$OUT" 2>"$ERR"
    if cmp -s "$CASE/stdin-payload" "$OUT"; then
      ok "$T: stdin reaches a recovered sibling binary intact"
    else
      bad "$T: stdin reaches a recovered sibling binary intact"
    fi

    # 13. The host pin overrides an inherited AGENT_GUARD_HOOK_HOST, and the
    # binary replaces the launcher process (no extra process per hook).
    P="$CASE/pid-$shell-$host"
    rm -rf "$P"
    mkdir -p "$P"
    # shellcheck disable=SC2016 # expanded by the fake binary, not here
    fake_version "$P" 3.0.9 3.0.9 complete \
      'printf "%s %s\n" "$$" "${AGENT_GUARD_HOOK_HOST-}"'
    printf '{}' | AGENT_GUARD_HOOK_HOST=bogus \
      "$shell" -c 'echo "$$" >"$0.pid"; exec "$0" "$1" "$2" "$3" "$4"' \
      "$shell" "$P/3.0.9/hooks/launch.sh" "$host" hook-stop "$P/3.0.9" >"$OUT" 2>"$ERR"
    if [ "$(cat "$OUT")" = "$(cat "$shell.pid" 2>/dev/null) $host" ]; then
      ok "$T: the binary replaces the launcher process with the host pinned"
    else
      bad "$T: the binary replaces the launcher process with the host pinned (wrapper pid $(cat "$shell.pid" 2>/dev/null))"
    fi
    rm -f "$shell.pid"

    # 14. Invalid arguments never reach a binary and get the policy.
    for args in "gemini hook-pre-tool" ":empty: hook-pre-tool" "$host scan-staged" \
      "$host hook-Pre-tool" "$host hook-pre-tool;id" "$host hook-pre/../tool"; do
      a_host=${args%% *}
      a_sub=${args#* }
      [ "$a_host" = :empty: ] && a_host=
      printf '{"session_id":"invalid"}' \
        | AGENT_GUARD_WARNING_DIR="$W-invalid" \
          "$shell" "$L" "$a_host" "$a_sub" "$C/3.0.9" >"$OUT" 2>"$ERR"
      status=$?
      if [ "$status" -eq 0 ] && [ ! -s "$OUT" ] \
         && grep -Fq 'unsupported host or hook subcommand; continuing because AGENT_GUARD_INFRA_FAILURE_MODE=open' "$ERR"; then
        ok "$T: invalid arguments '$args' get the open policy without executing"
      else
        bad "$T: invalid arguments '$args' get the open policy without executing (status $status)"
      fi
    done
    printf '{}' | AGENT_GUARD_INFRA_FAILURE_MODE=closed \
      "$shell" "$L" "$host" scan-staged "$C/3.0.9" >"$OUT" 2>"$ERR"
    status=$?
    if [ "$status" -eq 2 ] && [ ! -s "$OUT" ] \
       && grep -Fq 'unsupported host or hook subcommand; blocking because AGENT_GUARD_INFRA_FAILURE_MODE=closed' "$ERR"; then
      ok "$T: an invalid subcommand is blocked with a reason in closed mode"
    else
      bad "$T: an invalid subcommand is blocked with a reason in closed mode (status $status)"
    fi
    for argc in 2 4; do
      if [ "$argc" -eq 2 ]; then
        printf '{}' | "$shell" "$L" "$host" hook-pre-tool >"$OUT" 2>"$ERR"
      else
        printf '{}' | "$shell" "$L" "$host" hook-pre-tool "$C/3.0.9" extra >"$OUT" 2>"$ERR"
      fi
      status=$?
      if [ "$status" -eq 0 ] && [ ! -s "$OUT" ] && grep -Fq 'unsupported host or hook subcommand' "$ERR"; then
        ok "$T: $argc arguments are refused without executing"
      else
        bad "$T: $argc arguments are refused without executing (status $status)"
      fi
    done
  done

  # 15. The marker key includes the host: one session warns once per host.
  : >"$ERR"
  for host in claude codex claude codex; do
    printf '{"session_id":"per-host"}' \
      | AGENT_GUARD_WARNING_DIR="$CASE/warn-$shell-per-host" \
        "$shell" "$LAUNCHER" "$host" hook-stop "$CASE/missing/0.0.0" >"$OUT" 2>>"$ERR"
  done
  if [ "$(count 'no installed binary was found' "$ERR")" -eq 2 ] \
     && [ "$(count 'agent-guard: CLAUDE_PLUGIN_ROOT env not set' "$ERR")" -eq 1 ] \
     && [ "$(count 'agent-guard: PLUGIN_ROOT env not set' "$ERR")" -eq 1 ]; then
    ok "$shell: the open warning is once per host and names each host's root variable"
  else
    bad "$shell: the open warning is once per host and names each host's root variable"
  fi

  # 16. The default warning dir is the CLI's warning_root, created private,
  # and the marker keeps the manifest-<host>-<cksum>-<mode> name.
  TD="$CASE/tmpdir-$shell"
  mkdir -p "$TD"
  printf '{"session_id":"default-dir"}' \
    | env -u AGENT_GUARD_WARNING_DIR TMPDIR="$TD" \
      "$shell" "$LAUNCHER" claude hook-stop "$CASE/missing/0.0.0" >"$OUT" 2>"$ERR"
  sh "$ROOT/tests/helpers/extract-functions.sh" "$GUARD" "$CASE" warning_root >/dev/null 2>&1
  cli_root=$(env -u AGENT_GUARD_WARNING_DIR TMPDIR="$TD" \
    "$shell" -c '. "$0"; warning_root' "$CASE/warning_root.sh" 2>/dev/null)
  marker_sum=$(printf %s default-dir | cksum)
  if [ -n "$cli_root" ] && [ "$cli_root" = "$TD/agent-guard-warnings-$(id -u)" ] \
     && [ -f "$cli_root/manifest-claude-$marker_sum-open" ] \
     && case $(ls -ld "$cli_root") in drwx------*) true ;; *) false ;; esac; then
    ok "$shell: the default warning dir matches the CLI warning_root and is private"
  else
    bad "$shell: the default warning dir matches the CLI warning_root and is private (cli: $cli_root)"
    ls -la "$TD" | sed 's/^/  tmpdir: /'
  fi
done

# 17. A truncated launcher (interrupted copy) fails to parse instead of
# running a prefix of the policy or reaching a binary.
T="$CASE/truncated"
make_cache "$T"
lines=$(wc -l <"$LAUNCHER")
head -n "$((lines - 3))" "$LAUNCHER" >"$T/3.0.9/hooks/launch.sh"
printf '{}' | sh "$T/3.0.9/hooks/launch.sh" claude hook-stop "$T/3.0.9" >"$OUT" 2>"$ERR"
status=$?
if [ "$status" -ne 0 ] && [ ! -s "$OUT" ]; then
  ok "a truncated launcher fails to parse and executes nothing"
else
  bad "a truncated launcher fails to parse and executes nothing (status $status)"
fi

printf 'passed: %s\nfailed: %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
