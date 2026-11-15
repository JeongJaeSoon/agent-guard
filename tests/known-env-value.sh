#!/bin/sh
# Output masking of values from the project's root dotenv files (#445). The
# values are fake and assembled at runtime so repository scanners do not take
# them for deployed credentials.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
GUARD=${AGENT_GUARD_TEST_CLI:-"$ROOT/plugins/agent-guard/bin/agent-guard"}
CASE=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-known-value.XXXXXX") || exit 1
trap 'rm -rf "$CASE"' 0
export AGENT_GUARD_GITLEAKS_BIN="$ROOT/tests/fixtures/mock-gitleaks"
export AGENT_GUARD_LOG_MODE=off AGENT_GUARD_RELEASE_CHECK=off
export AGENT_GUARD_PII_HOOK_MODE=off
unset AGENT_GUARD_KNOWN_VALUE_REDACT AGENT_GUARD_OUTPUT_REDACT \
  AGENT_GUARD_DENY_READ_PATHS 2>/dev/null || :

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}
ok() { printf 'ok - %s\n' "$1"; }

PROJECT="$CASE/project"
mkdir -p "$PROJECT/sub"
git -C "$PROJECT" init -q
seed=$(printf '%s%s' zX7fake Qm2v9Lr)
meta=$(printf '%s%s' 'a.*[]$\&/' 'b9Zq^(x)')
quoted=$(printf '%s%s' quoted-fake '-Vq83mZ')
crlf=$(printf '%s%s' crlf-fake '-Lw42pT')
template=$(printf '%s%s' template-fake '-Ex51nK')
sub_value=$(printf '%s%s' nested-fake '-Sd73qP')
{
  printf 'APP_SEED=%s\n' "$seed"
  printf 'SHORT=abc1234\n'
  printf 'FLAG=FALSE\n'
  printf 'COUNT=123456789\n'
  printf 'EMPTY=\n'
  printf "META='%s'\n" "$meta"
  printf 'export QUOTED="%s" # note\n' "$quoted"
  printf 'CRLF=%s\r\n' "$crlf"
} >"$PROJECT/.env"
printf 'EXAMPLE_VALUE=%s\n' "$template" >"$PROJECT/.env.example"
# Not at the project root: never read.
printf 'NESTED=%s\n' "$sub_value" >"$PROJECT/sub/.env.local"

probe() {
  printf '%s\n' "$1" | (cd "$PROJECT" && "$GUARD" exec -- cat) 2>"$CASE/stderr"
}

expect_exec() {
  label=$1 input=$2 expected=$3
  actual=$(probe "$input") || fail "$label (status)"
  [ "$actual" = "$expected" ] || fail "$label: got [$actual]"
  ok "$label"
}

# --- block (default): protected files are never opened ------------------------
unset AGENT_GUARD_DENY_READ_MODE 2>/dev/null || :
expect_exec 'block mode leaves a generic-key value unmasked' \
  "worker started, seed $seed" "worker started, seed $seed"
# Prove no read attempt: an unreadable .env would make mask mode skip it, but a
# read in block mode would still show up as a value-dependent difference. Use a
# FIFO with no writer instead; opening it would hang the probe.
if command -v mkfifo >/dev/null 2>&1; then
  FIFO_PROJECT="$CASE/fifo"
  mkdir "$FIFO_PROJECT"
  mkfifo "$FIFO_PROJECT/.env.fifo-check"
  out=$(printf 'plain %s\n' "$seed" | (cd "$FIFO_PROJECT" && "$GUARD" exec -- cat)) \
    || fail 'block mode exec with a FIFO dotenv'
  [ "$out" = "plain $seed" ] || fail 'block mode FIFO output'
  ok 'block mode does not open a dotenv FIFO'
fi
AGENT_GUARD_DENY_READ_MODE=block
export AGENT_GUARD_DENY_READ_MODE
expect_exec 'explicit block mode leaves the value unmasked' \
  "APP_SEED=$seed" "APP_SEED=$seed"

# --- mask: the issue's reproduction --------------------------------------------
AGENT_GUARD_DENY_READ_MODE=mask
expect_exec 'secret-like key still masked' \
  "DB_PASSWORD=$seed" 'DB_PASSWORD=[REDACTED]'
expect_exec 'generic key assignment masked' \
  "APP_SEED=$seed" 'APP_SEED=[REDACTED]'
expect_exec 'bare value in a log line masked' \
  "worker started, seed $seed" 'worker started, seed [REDACTED]'
expect_exec 'value inside an argv list masked' \
  "subprocess.CalledProcessError: Command '['false', '-u', 'deploy:$seed']' returned non-zero exit status 1." \
  "subprocess.CalledProcessError: Command '['false', '-u', 'deploy:[REDACTED]']' returned non-zero exit status 1."
expect_exec 'URL password masked' \
  "postgresql://app:$seed@db.example.com/app" 'postgresql://app:[REDACTED]@db.example.com/app'
expect_exec 'regex metacharacters match literally' \
  "meta $meta end" 'meta [REDACTED] end'
expect_exec 'metacharacter value is not a pattern' \
  'meta aXbbbbbb9Zq end' 'meta aXbbbbbb9Zq end'
expect_exec 'double-quoted value with inline comment masked' \
  "q=$quoted." 'q=[REDACTED].'
expect_exec 'CRLF value masked without the CR' \
  "c $crlf" 'c [REDACTED]'
expect_exec 'short, boolean and numeric values stay' \
  'abc1234 FALSE 123456789 ok' 'abc1234 FALSE 123456789 ok'
expect_exec 'template file values are not read' \
  "t $template" "t $template"
expect_exec 'nested dotenv files are not read' \
  "n $sub_value" "n $sub_value"
actual=$(printf 'sub %s\n' "$seed" | (cd "$PROJECT/sub" && "$GUARD" exec -- cat)) \
  || fail 'subdirectory exec status'
[ "$actual" = 'sub [REDACTED]' ] || fail 'git top-level dotenv from a subdirectory'
ok 'git top-level dotenv applies from a subdirectory'

for name in stderr; do
  if grep -F -e "$seed" -e "$quoted" -e "$crlf" "$CASE/$name" >/dev/null 2>&1; then
    fail "a known value reached $name"
  fi
done
ok 'known values never reach stderr'

# --- opt-outs ---------------------------------------------------------------
AGENT_GUARD_KNOWN_VALUE_REDACT=off
export AGENT_GUARD_KNOWN_VALUE_REDACT
expect_exec 'AGENT_GUARD_KNOWN_VALUE_REDACT=off disables it' \
  "seed $seed" "seed $seed"
unset AGENT_GUARD_KNOWN_VALUE_REDACT
AGENT_GUARD_OUTPUT_REDACT=off
export AGENT_GUARD_OUTPUT_REDACT
expect_exec 'AGENT_GUARD_OUTPUT_REDACT=off disables it' \
  "seed $seed" "seed $seed"
unset AGENT_GUARD_OUTPUT_REDACT

# --- an unreadable dotenv does not break other rules -------------------------
if [ "$(id -u)" -ne 0 ]; then
  UNREADABLE="$CASE/unreadable"
  mkdir "$UNREADABLE"
  printf 'APP_SEED=%s\n' "$seed" >"$UNREADABLE/.env"
  chmod 000 "$UNREADABLE/.env"
  out=$(printf 'seed %s DB_PASSWORD=%s\n' "$seed" "$seed" \
    | (cd "$UNREADABLE" && "$GUARD" exec -- cat) 2>"$CASE/stderr") \
    || fail 'unreadable dotenv exec status'
  chmod 600 "$UNREADABLE/.env"
  [ "$out" = "seed $seed DB_PASSWORD=[REDACTED]" ] \
    || fail "unreadable dotenv: got [$out]"
  grep -F "$seed" "$CASE/stderr" >/dev/null 2>&1 \
    && fail 'unreadable dotenv: value on stderr'
  ok 'an unreadable dotenv contributes no values and other rules still mask'
fi

# --- a file outside the mask-file dotenv subset contributes nothing ------------
MIXED="$CASE/mixed"
mkdir "$MIXED"
other=$(printf '%s%s' other-fake '-Mn62rB')
printf 'APP_SEED=%s\n' "$seed" >"$MIXED/.env"
printf 'OTHER=%s\nURL=${HOST}/x\n' "$other" >"$MIXED/.env.local"
out=$(printf 'a %s b %s\n' "$seed" "$other" \
  | (cd "$MIXED" && "$GUARD" exec -- cat) 2>"$CASE/stderr") \
  || fail 'mixed dotenv exec status'
[ "$out" = "a [REDACTED] b $other" ] || fail "mixed dotenv: got [$out]"
[ ! -s "$CASE/stderr" ] || fail 'mixed dotenv: unexpected stderr'
ok 'an unparsable dotenv is skipped while the other root file still masks'

# --- the experimental fused detector gets the same records --------------------
out=$(printf 'seed %s\n' "$seed" \
  | (cd "$PROJECT" && AGENT_GUARD_EXPERIMENTAL_OUTPUT_PIPELINE=fused \
      "$GUARD" exec -- cat)) || fail 'fused exec status'
[ "$out" = 'seed [REDACTED]' ] || fail "fused pipeline: got [$out]"
ok 'the fused output pipeline masks known values too'

# --- values never reach the audit log or a leftover temp file -----------------
LOGCASE="$CASE/log"
mkdir -p "$LOGCASE/tmp"
out=$(printf 'seed %s\n' "$seed" \
  | (cd "$PROJECT" && XDG_STATE_HOME="$LOGCASE/state" AGENT_GUARD_LOG_MODE=on \
      TMPDIR="$LOGCASE/tmp" "$GUARD" exec -- cat)) || fail 'logged exec status'
[ "$out" = 'seed [REDACTED]' ] || fail "logged exec: got [$out]"
if grep -rF -e "$seed" -e "$quoted" -e "$meta" -e "$crlf" "$LOGCASE" >/dev/null 2>&1; then
  fail 'a known value reached the audit log or a temp file'
fi
[ -z "$(ls -A "$LOGCASE/tmp")" ] || fail 'exec left temp files behind'
ok 'known values never reach the audit log and no temp file is left'

# --- a symlinked dotenv is not followed ---------------------------------------
LINKED="$CASE/linked"
mkdir "$LINKED"
ln -s "$PROJECT/.env" "$LINKED/.env"
out=$(printf 'seed %s\n' "$seed" | (cd "$LINKED" && "$GUARD" exec -- cat)) \
  || fail 'symlinked dotenv exec status'
[ "$out" = "seed $seed" ] || fail 'symlinked dotenv was followed'
ok 'a symlinked dotenv is skipped'

# --- PostToolUse on both hosts -------------------------------------------------
post_input=$(jq -cn --arg cwd "$PROJECT" --arg out "worker started, seed $seed" \
  '{hook_event_name:"PostToolUse",cwd:$cwd,tool_name:"Bash",
    tool_input:{command:"run"},tool_response:{stdout:$out,stderr:"",interrupted:false}}')
for host in claude codex; do
  actual=$(printf '%s' "$post_input" \
    | (cd "$CASE" && AGENT_GUARD_HOOK_HOST=$host "$GUARD" hook-post-tool) 2>"$CASE/stderr") \
    || fail "$host PostToolUse status"
  case $host in
    claude)
      leaf=$(printf '%s' "$actual" | jq -r '.hookSpecificOutput.updatedToolOutput.stdout') ;;
    codex)
      leaf=$(printf '%s' "$actual" | jq -r '.hookSpecificOutput.additionalContext') ;;
  esac
  case $leaf in
    *'worker started, seed [REDACTED]'*) ;;
    *) fail "$host PostToolUse did not mask: [$actual]" ;;
  esac
  case $actual in *"$seed"*) fail "$host PostToolUse leaked the value" ;; esac
  if grep -F "$seed" "$CASE/stderr" >/dev/null 2>&1; then
    fail "$host PostToolUse stderr carries the value"
  fi
  ok "$host PostToolUse masks a known dotenv value from the event cwd"
done

AGENT_GUARD_DENY_READ_MODE=block
for host in claude codex; do
  actual=$(printf '%s' "$post_input" \
    | (cd "$CASE" && AGENT_GUARD_HOOK_HOST=$host "$GUARD" hook-post-tool) 2>/dev/null) \
    || fail "$host PostToolUse block status"
  [ -z "$actual" ] || fail "$host PostToolUse in block mode rewrote output"
  ok "$host PostToolUse in block mode leaves the value"
done
