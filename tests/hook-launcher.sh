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

DEFAULT_BLOCK='blocking because the secret scan did not run (the default when AGENT_GUARD_INFRA_FAILURE_MODE is unset)'
TEXT_SUBS='hook-pre-tool hook-user-prompt hook-post-tool hook-post-tool-failure'
# A stand-in binary that records its PID, then waits until a TERM arrives.
term_body=$(cat <<'EOF'
trap 'echo stopped >"$0.term"; kill "$nap" 2>/dev/null; exit 143' TERM
echo "$$" >"$0.pid"
sleep 30 &
nap=$!
wait "$nap"
EOF
)

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
        | AGENT_GUARD_WARNING_DIR="$W-incomplete-$incomplete" AGENT_GUARD_INFRA_FAILURE_MODE=open \
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
    # and an unrecognised mode value is read as unset.
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
        "$shell" "$L" "$host" hook-stop "$CASE/missing/0.0.0" >"$OUT" 2>"$ERR"
    status=$?
    if [ "$status" -eq 0 ] && grep -Fq 'continuing because AGENT_GUARD_INFRA_FAILURE_MODE=open' "$ERR"; then
      ok "$T: an unrecognised policy value is read as unset (Stop continues)"
    else
      bad "$T: an unrecognised policy value is read as unset (Stop continues, status $status)"
    fi
    printf '{"session_id":"odd-mode"}' \
      | AGENT_GUARD_WARNING_DIR="$W-odd" AGENT_GUARD_INFRA_FAILURE_MODE=sometimes \
        "$shell" "$L" "$host" hook-pre-tool "$CASE/missing/0.0.0" >"$OUT" 2>"$ERR"
    status=$?
    if [ "$status" -eq 2 ] && grep -Fq "$DEFAULT_BLOCK" "$ERR"; then
      ok "$T: an unrecognised policy value is read as unset (PreToolUse blocks)"
    else
      bad "$T: an unrecognised policy value is read as unset (PreToolUse blocks, status $status)"
    fi

    # 7. Open mode warns once per session across changing parents (Linux
    # starts each hook under a different parent), keyed by session_id.
    : >"$ERR"
    for sub in hook-pre-tool hook-post-tool hook-stop hook-session-start; do
      printf '{"session_id":"open-once"}' \
        | AGENT_GUARD_WARNING_DIR="$W-once" AGENT_GUARD_INFRA_FAILURE_MODE=open \
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
          AGENT_GUARD_INFRA_FAILURE_MODE=open \
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
        | PATH="$NO_JQ_PATH" AGENT_GUARD_WARNING_DIR="$W-nojq" AGENT_GUARD_INFRA_FAILURE_MODE=open \
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
    # binary replaces the launcher process for a hook that continues (Stop
    # here; a hook that carries text under an explicit open, just below).
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
    printf '{}' | AGENT_GUARD_INFRA_FAILURE_MODE=open \
      "$shell" -c 'echo "$$" >"$0.pid"; exec "$0" "$1" "$2" "$3" "$4"' \
      "$shell" "$P/3.0.9/hooks/launch.sh" "$host" hook-pre-tool "$P/3.0.9" >"$OUT" 2>"$ERR"
    if [ "$(cat "$OUT")" = "$(cat "$shell.pid" 2>/dev/null) $host" ]; then
      ok "$T: an explicit open keeps the exec for a hook that carries text"
    else
      bad "$T: an explicit open keeps the exec for a hook that carries text"
    fi
    rm -f "$shell.pid"

    # The hooks whose event carries text to or from the agent block by
    # default when no binary can run, and say why on every call. Stop and
    # SessionStart keep the open default.
    NX="$CASE/noexec-$shell-$host"
    rm -rf "$NX"
    mkdir -p "$NX"
    fake_version "$NX" 3.0.9
    chmod -x "$NX/3.0.9/bin/agent-guard"
    for sub in $TEXT_SUBS; do
      for broken in "missing:$CASE/missing/0.0.0" "not-executable:$NX/3.0.9" "incomplete:$C/4.0.0"; do
        default_ok=yes
        for attempt in first second; do
          printf '{"session_id":"default-block"}' \
            | AGENT_GUARD_WARNING_DIR="$W-default" \
              "$shell" "$L" "$host" "$sub" "${broken#*:}" >"$OUT" 2>"$ERR"
          status=$?
          [ "$status" -eq 2 ] && [ ! -s "$OUT" ] && grep -Fq "$DEFAULT_BLOCK" "$ERR" \
            && grep -Fq 'reinstall or update the agent-guard plugin' "$ERR" \
            && ! grep -Fq '=open' "$ERR" || default_ok=no
          case "$sub" in
            hook-post-tool*)
              grep -Fq 'the tool output was not checked and could not be withheld' "$ERR" || default_ok=no ;;
            *) ! grep -Fq 'could not be withheld' "$ERR" || default_ok=no ;;
          esac
        done
        if [ "$default_ok" = yes ]; then
          ok "$T: $sub blocks by default when the binary is ${broken%%:*}"
        else
          bad "$T: $sub blocks by default when the binary is ${broken%%:*} (status $status)"
        fi
      done
    done
    for sub in hook-stop hook-session-start; do
      printf '{"session_id":"default-open"}' \
        | AGENT_GUARD_WARNING_DIR="$W-default-$sub" \
          "$shell" "$L" "$host" "$sub" "$CASE/missing/0.0.0" >"$OUT" 2>"$ERR"
      status=$?
      if [ "$status" -eq 0 ] && grep -Fq 'continuing because AGENT_GUARD_INFRA_FAILURE_MODE=open' "$ERR"; then
        ok "$T: $sub keeps the open default with no binary"
      else
        bad "$T: $sub keeps the open default with no binary (status $status)"
      fi
    done
    printf '{"session_id":"explicit-open"}' \
      | AGENT_GUARD_WARNING_DIR="$W-explicit-open" AGENT_GUARD_INFRA_FAILURE_MODE=open \
        "$shell" "$L" "$host" hook-user-prompt "$CASE/missing/0.0.0" >"$OUT" 2>"$ERR"
    status=$?
    if [ "$status" -eq 0 ] && grep -Fq 'continuing because AGENT_GUARD_INFRA_FAILURE_MODE=open' "$ERR"; then
      ok "$T: an explicit open lets a hook that carries text continue with no binary"
    else
      bad "$T: an explicit open lets a hook that carries text continue with no binary (status $status)"
    fi

    # A binary that starts and ends with a status other than 0 or 2 did not
    # finish its check: for the hooks that carry text that is a block with the
    # reason. 0 and 2 pass through untouched, and so does everything under an
    # explicit open or for the other hooks.
    K="$CASE/crash-$shell-$host"
    rm -rf "$K"
    mkdir -p "$K"
    fake_version "$K" 1.0.0 1.0.0 complete 'cat >/dev/null; echo fine; exit 0'
    fake_version "$K" 1.0.1 1.0.1 complete 'cat >/dev/null; echo partial; exit 1'
    fake_version "$K" 1.0.2 1.0.2 complete 'cat >/dev/null; echo verdict; echo reason >&2; exit 2'
    # shellcheck disable=SC2016 # expanded by the fake binary, not here
    fake_version "$K" 1.0.9 1.0.9 complete 'cat >/dev/null; kill -KILL "$$"'
    for sub in $TEXT_SUBS; do
      crash_ok=yes
      printf '{}' | "$shell" "$K/1.0.1/hooks/launch.sh" "$host" "$sub" "$K/1.0.1" >"$OUT" 2>"$ERR"
      status=$?
      [ "$status" -eq 2 ] && grep -Fq 'ended with status 1 before it finished its check' "$ERR" \
        && grep -Fq "$DEFAULT_BLOCK" "$ERR" || crash_ok=no
      printf '{}' | "$shell" "$K/1.0.9/hooks/launch.sh" "$host" "$sub" "$K/1.0.9" >"$OUT" 2>"$ERR"
      status=$?
      [ "$status" -eq 2 ] && grep -Fq 'ended with status 137 before it finished its check' "$ERR" || crash_ok=no
      if [ "$crash_ok" = yes ]; then
        ok "$T: $sub turns a binary that exits 1 or dies of a signal into a block with the reason"
      else
        bad "$T: $sub turns a binary that exits 1 or dies of a signal into a block with the reason (status $status)"
      fi
      printf '{}' | "$shell" "$K/1.0.0/hooks/launch.sh" "$host" "$sub" "$K/1.0.0" >"$OUT" 2>"$ERR"
      status=$?
      pass_ok=yes
      [ "$status" -eq 0 ] && [ "$(cat "$OUT")" = fine ] && [ ! -s "$ERR" ] || pass_ok=no
      printf '{}' | "$shell" "$K/1.0.2/hooks/launch.sh" "$host" "$sub" "$K/1.0.2" >"$OUT" 2>"$ERR"
      status=$?
      [ "$status" -eq 2 ] && [ "$(cat "$OUT")" = verdict ] && [ "$(cat "$ERR")" = reason ] || pass_ok=no
      if [ "$pass_ok" = yes ]; then
        ok "$T: $sub passes the binary's 0 and 2 through with its output untouched"
      else
        bad "$T: $sub passes the binary's 0 and 2 through with its output untouched (status $status)"
      fi
    done
    printf '{}' | AGENT_GUARD_INFRA_FAILURE_MODE=open \
      "$shell" "$K/1.0.1/hooks/launch.sh" "$host" hook-pre-tool "$K/1.0.1" >"$OUT" 2>"$ERR"
    status=$?
    if [ "$status" -eq 1 ] && [ "$(cat "$OUT")" = partial ] && [ ! -s "$ERR" ]; then
      ok "$T: an explicit open passes a crashed binary's status through as before"
    else
      bad "$T: an explicit open passes a crashed binary's status through as before (status $status)"
    fi
    printf '{}' | AGENT_GUARD_INFRA_FAILURE_MODE=closed \
      "$shell" "$K/1.0.1/hooks/launch.sh" "$host" hook-post-tool "$K/1.0.1" >"$OUT" 2>"$ERR"
    status=$?
    if [ "$status" -eq 2 ] && grep -Fq 'blocking because AGENT_GUARD_INFRA_FAILURE_MODE=closed' "$ERR" \
       && grep -Fq 'the tool output was not checked and could not be withheld' "$ERR"; then
      ok "$T: closed mode blocks a crashed PostToolUse binary and says the output was not withheld"
    else
      bad "$T: closed mode blocks a crashed PostToolUse binary and says the output was not withheld (status $status)"
    fi
    stop_ok=yes
    for stop_mode in '' closed; do
      printf '{}' | AGENT_GUARD_INFRA_FAILURE_MODE="$stop_mode" \
        "$shell" "$K/1.0.1/hooks/launch.sh" "$host" hook-stop "$K/1.0.1" >"$OUT" 2>"$ERR"
      [ "$?" -eq 1 ] && [ ! -s "$ERR" ] || stop_ok=no
    done
    if [ "$stop_ok" = yes ]; then
      ok "$T: hook-stop still hands a crashed binary's status to the host"
    else
      bad "$T: hook-stop still hands a crashed binary's status to the host"
    fi

    # A TERM that reaches the launcher goes on to the binary, and the launcher
    # collects it before it leaves: nothing keeps running.
    G="$CASE/term-$shell-$host"
    rm -rf "$G"
    mkdir -p "$G"
    fake_version "$G" 2.0.0 2.0.0 complete "$term_body"
    printf '{}' >"$CASE/term-input"
    "$shell" "$G/2.0.0/hooks/launch.sh" "$host" hook-pre-tool "$G/2.0.0" \
      <"$CASE/term-input" >"$OUT" 2>"$ERR" &
    launcher_pid=$!
    tries=0
    while [ ! -s "$G/2.0.0/bin/agent-guard.pid" ] && [ "$tries" -lt 100 ]; do
      sleep 0.1
      tries=$((tries + 1))
    done
    child_pid=$(cat "$G/2.0.0/bin/agent-guard.pid" 2>/dev/null)
    kill -TERM "$launcher_pid" 2>/dev/null
    wait "$launcher_pid"
    status=$?
    if [ -n "$child_pid" ] && [ "$child_pid" != "$launcher_pid" ] && [ "$status" -eq 2 ] \
       && [ -s "$G/2.0.0/bin/agent-guard.term" ] && ! kill -0 "$child_pid" 2>/dev/null \
       && grep -Fq 'before it finished its check' "$ERR"; then
      ok "$T: a TERM sent to the launcher reaches the binary and leaves nothing running"
    else
      bad "$T: a TERM sent to the launcher reaches the binary and leaves nothing running (status $status, child ${child_pid:-none})"
      [ -z "$child_pid" ] || kill -KILL "$child_pid" 2>/dev/null
    fi

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

# The manifest command answers by itself when no launcher exists anywhere. It
# follows the same defaults, and an unrecognised value is read as unset.
for host in claude codex; do
  case "$host" in
    claude) manifest="$ROOT/plugins/agent-guard/hooks/hooks.json"; root_var=CLAUDE_PLUGIN_ROOT ;;
    *) manifest="$ROOT/plugins/agent-guard/hooks.json"; root_var=PLUGIN_ROOT ;;
  esac
  for event in $(jq -r '.hooks | keys[]' "$manifest"); do
    command=$(jq -r --arg e "$event" '.hooks[$e][0].hooks[0].command' "$manifest")
    case "$event" in
      Stop|SessionStart) want=0; why='continuing because AGENT_GUARD_INFRA_FAILURE_MODE=open' ;;
      *) want=2; why='blocking because AGENT_GUARD_INFRA_FAILURE_MODE=unset' ;;
    esac
    line_ok=yes
    for value in '' sometimes; do
      printf '{}' | env "$root_var=$CASE/no-plugin/0.0.0" AGENT_GUARD_INFRA_FAILURE_MODE="$value" \
        sh -c "$command" >"$OUT" 2>"$ERR"
      status=$?
      [ "$status" -eq "$want" ] && [ ! -s "$OUT" ] && grep -Fq "$why" "$ERR" || line_ok=no
      [ "$want" -eq 0 ] || ! grep -Fq '=open' "$ERR" || line_ok=no
    done
    printf '{}' | env "$root_var=$CASE/no-plugin/0.0.0" AGENT_GUARD_INFRA_FAILURE_MODE=open \
      sh -c "$command" >"$OUT" 2>"$ERR"
    [ "$?" -eq 0 ] && grep -Fq 'continuing because AGENT_GUARD_INFRA_FAILURE_MODE=open' "$ERR" || line_ok=no
    printf '{}' | env "$root_var=$CASE/no-plugin/0.0.0" AGENT_GUARD_INFRA_FAILURE_MODE=closed \
      sh -c "$command" >"$OUT" 2>"$ERR"
    [ "$?" -eq 2 ] && grep -Fq 'blocking because AGENT_GUARD_INFRA_FAILURE_MODE=closed' "$ERR" || line_ok=no
    if [ "$line_ok" = yes ]; then
      ok "$host $event: the manifest command's own fallback has the event's default (status $want unset)"
    else
      bad "$host $event: the manifest command's own fallback has the event's default (want $want unset)"
    fi
  done
done

# 18. The CLI is a POSIX sh script, and dash runs it several times faster than
# bash acting as sh. A binary that starts with the CLI's own interpreter line
# is handed to a system dash where there is one, for a hook that continues
# (exec) and for one that blocks (child). Any other binary, such as a native
# one from another version directory, is executed as it is.
dash_path=
for candidate in /bin/dash /usr/bin/dash; do
  if [ -x "$candidate" ]; then dash_path=$candidate; break; fi
done
# shellcheck disable=SC2016 # expanded by the fake binary, not here
interp_body='ps -o comm= -p "$$"; printf "args=%s\n" "$*"'
T="$CASE/interp"
mkdir -p "$T"
fake_version "$T" 1.0.0 1.0.0 complete "$interp_body"
fake_version "$T" 2.0.0 2.0.0 complete "$interp_body"
{ printf '#!/bin/sh\n'; sed 1d "$T/2.0.0/bin/agent-guard"; } >"$T/other"
cat "$T/other" >"$T/2.0.0/bin/agent-guard"
for sub in hook-stop hook-pre-tool; do
  for version in 1.0.0 2.0.0; do
    case "$version:$dash_path" in
      1.0.0:/*) want=dash ;;
      *) want=sh ;;
    esac
    printf '{}' | sh "$LAUNCHER" claude "$sub" "$T/$version" >"$OUT" 2>"$ERR"
    status=$?
    name=$(sed -n 1p "$OUT")
    name=${name##*/}
    if [ "$status" -eq 0 ] && [ "$name" = "$want" ] && [ "$(sed -n 2p "$OUT")" = "args=$sub" ] && [ ! -s "$ERR" ]; then
      ok "$sub: a binary with interpreter line $(sed -n 1p "$T/$version/bin/agent-guard") runs under $want"
    else
      bad "$sub: a binary with interpreter line $(sed -n 1p "$T/$version/bin/agent-guard") runs under $want (got $name, status $status)"
    fi
  done
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
