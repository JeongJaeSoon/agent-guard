#!/bin/sh
# Local regression: assignment-probe errors must not become a clean prompt.
# Synthetic scanner/input only; the real CLI and all non-target awk calls run.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
GUARD="$ROOT/plugins/agent-guard/bin/agent-guard"
CASE=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-assignment-failure.XXXXXX")
trap 'rm -rf "$CASE"' 0
mkdir -p "$CASE/bin" "$CASE/home" "$CASE/functions"
export HOME="$CASE/home" AGENT_GUARD_LOG_MODE=off AGENT_GUARD_RELEASE_CHECK=off
export AGENT_GUARD_GITLEAKS_BIN="$ROOT/tests/fixtures/mock-gitleaks"
export AGENT_GUARD_GITLEAKS_CONFIG="$ROOT/plugins/agent-guard/config/gitleaks.toml"
export AGENT_GUARD_PROMPT_GUARD_MODE=block AGENT_GUARD_PII_HOOK_MODE=off
unset AI_AGENT
REAL_AWK=$(command -v awk)
export REAL_AWK
INJECT_LOG="$CASE/injected"
export INJECT_LOG
cat >"$CASE/bin/awk" <<'SHIM'
#!/bin/sh
hit=
for arg do
  case "${INJECT_STAGE%%-*}:$arg" in
    producer:*'NR > 1 { emit_char("\n") }'*) hit=$INJECT_STAGE ;;
    detector:record_mode=probe) hit=$INJECT_STAGE ;;
  esac
done
if [ -n "$hit" ]; then
  cat >/dev/null
  printf '%s\n' "$hit" >>"$INJECT_LOG"
  case "$hit" in
    producer-partial) printf 'DB_PASSWORD=assignment-probe-synthetic-value\036' ;;
    detector-partial) printf 'x\n' ;;
  esac
  exit 23
fi
exec "$REAL_AWK" "$@"
SHIM
chmod +x "$CASE/bin/awk"
sh "$ROOT/tests/helpers/extract-functions.sh" "$GUARD" "$CASE/functions" \
  frame_plaintext_leaf secretish_env_values prompt_has_secretish_assignment
cat "$CASE/functions/frame_plaintext_leaf.sh" "$CASE/functions/secretish_env_values.sh" \
  "$CASE/functions/prompt_has_secretish_assignment.sh" >"$CASE/probe.sh"
printf '\nprompt_has_secretish_assignment "$1"\n' >>"$CASE/probe.sh"
PATH="$CASE/bin:$PATH"
export PATH
pass=0 fail=0
ok() { pass=$((pass + 1)); printf 'ok - %s\n' "$*"; }
bad() { fail=$((fail + 1)); printf 'not ok - %s\n' "$*"; }
assignment='DB_PASSWORD=assignment-probe-synthetic-value'
clean='ordinary benign prompt'
for kind in clean secret clean-lines secret-lines clean-controls secret-controls; do
  case $kind in
    clean) value=$clean expected=1 ;;
    secret) value=$assignment expected=0 ;;
    clean-lines) value=$(printf 'ordinary\nbenign\n\n.'); value=${value%.}; expected=1 ;;
    secret-lines) value=$(printf '%s\n\n.' "$assignment"); value=${value%.}; expected=0 ;;
    clean-controls) value=$(printf 'ordinary\036\037benign'); expected=1 ;;
    secret-controls) value=$(printf '%s\036\037suffix' "$assignment"); expected=0 ;;
  esac
  : >"$INJECT_LOG"
  status=0
  INJECT_STAGE= sh "$CASE/probe.sh" "$value" >"$CASE/out" 2>"$CASE/err" || status=$?
  if [ "$status" -eq "$expected" ] && [ ! -s "$INJECT_LOG" ] \
    && ! LC_ALL=C grep -Fq "assignment-probe-synthetic-value" "$CASE/out" "$CASE/err"; then
    ok "direct $kind control status=$status"
  else bad "direct $kind control expected=$expected actual=$status"; fi
done
for stage in producer detector producer-partial detector-partial; do
  : >"$INJECT_LOG"
  status=0
  INJECT_STAGE=$stage sh "$CASE/probe.sh" "$assignment" >"$CASE/out" 2>"$CASE/err" || status=$?
  if [ "$(cat "$INJECT_LOG")" != "$stage" ]; then
    bad "direct $stage injection did not hit exactly once"
  elif [ "$status" -gt 1 ] \
    && ! LC_ALL=C grep -Fq "assignment-probe-synthetic-value" "$CASE/out" "$CASE/err"; then
    ok "direct $stage error remains distinguishable from clean status=$status"
  else bad "direct $stage error collapsed to status=$status (injected exit=23)"; fi
done
for host in claude codex; do
  for policy in open closed; do
    for kind in clean secret producer detector producer-partial detector-partial; do
      stage=
      case $kind in clean) value=$clean expected=0 ;; secret) value=$assignment expected=2 ;; *) value=$assignment stage=$kind; case $policy in open) expected=0 ;; closed) expected=2 ;; esac ;; esac
      : >"$INJECT_LOG"
      jq -nc --arg p "$value" --arg s "$host-$policy-$kind" '{prompt:$p,session_id:$s}' >"$CASE/input"
      status=0
      INJECT_STAGE=$stage AGENT_GUARD_HOOK_HOST=$host AGENT_GUARD_INFRA_FAILURE_MODE=$policy \
        AGENT_GUARD_WARNING_DIR="$CASE/warnings-$host-$policy-$kind" \
        "$GUARD" hook-user-prompt <"$CASE/input" >"$CASE/out" 2>"$CASE/err" || status=$?
      matched=yes
      if [ -n "$stage" ]; then
        [ "$(cat "$INJECT_LOG")" = "$stage" ] || matched=no
        case $policy in
          open)
            grep -q 'continuing because AGENT_GUARD_INFRA_FAILURE_MODE=open' "$CASE/err" || matched=no
            jq -e '.hookSpecificOutput.additionalContext | contains("AGENT_GUARD_INFRA_FAILURE_MODE=open")' "$CASE/out" >/dev/null 2>&1 || matched=no ;;
          closed) grep -q 'Blocking because AGENT_GUARD_INFRA_FAILURE_MODE=closed' "$CASE/err" || matched=no ;;
        esac
      else
        [ ! -s "$INJECT_LOG" ] || matched=no
        case $kind in clean) [ ! -s "$CASE/out" ] && [ ! -s "$CASE/err" ] || matched=no ;; secret) grep -q 'contains secret-like values' "$CASE/err" || matched=no ;; esac
      fi
      # With AI_AGENT unset, both hosts block via exit 2 and stderr only.
      # Only an open-policy infrastructure failure emits a JSON notice here.
      # An open-policy notice must not carry a blocking decision.
      # Slurping rejects multiple top-level responses as well as invalid JSON.
      if [ -n "$stage" ] && [ "$policy" = open ]; then
        jq -se 'length == 1 and (.[0] | type == "object" and (has("decision") | not) and
          (.hookSpecificOutput | type == "object" and
            .hookEventName == "UserPromptSubmit" and
            (.additionalContext | type == "string" and length > 0)))' \
          "$CASE/out" >/dev/null 2>&1 || matched=no
      else
        [ ! -s "$CASE/out" ] || matched=no
      fi
      if LC_ALL=C grep -Fq 'assignment-probe-synthetic-value' "$CASE/out" "$CASE/err"; then
        matched=no
      fi
      if [ "$status" -eq "$expected" ] && [ "$matched" = yes ]; then
        ok "$host $policy $kind status=$status"
      else
        bad "$host $policy $kind expected=$expected actual=$status injected=$(cat "$INJECT_LOG") stdout_bytes=$(wc -c <"$CASE/out" | tr -d ' ') stderr_bytes=$(wc -c <"$CASE/err" | tr -d ' ')"
      fi
    done
  done
done
printf 'passed: %s\nfailed: %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
