#!/bin/sh
# With AGENT_GUARD_INFRA_FAILURE_MODE unset, a secret scan that did not run
# blocks (PreToolUse, the prompt) or withholds (PostToolUse), because unscanned
# text that reaches the agent cannot be taken back. Every other infrastructure
# failure stays open, and an explicit open or closed applies to both kinds.
# Stub scanners make each failure; the marker is assembled at run time.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
GUARD=${AGENT_GUARD_TEST_BINARY:-$ROOT/plugins/agent-guard/bin/agent-guard}
CASE=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-scan-default.XXXXXX") || exit 1
[ -n "$CASE" ] || exit 1
CASE=$(CDPATH= cd -- "$CASE" && pwd -P) || exit 1
trap 'rm -rf "$CASE"' 0
mkdir -p "$CASE/home" "$CASE/w" "$CASE/good" "$CASE/scanfail" "$CASE/hang"
export HOME="$CASE/home" AGENT_GUARD_LOG_MODE=off AGENT_GUARD_RELEASE_CHECK=off
export AGENT_GUARD_PII_HOOK_MODE=off AGENT_GUARD_PROMPT_GUARD_MODE=block
export AGENT_GUARD_WARNING_DIR="$CASE/warnings"
export AGENT_GUARD_GITLEAKS_CONFIG="$ROOT/plugins/agent-guard/config/gitleaks.toml"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
unset AI_AGENT AGENT_GUARD_INFRA_FAILURE_MODE
pass=0 fail=0
ok() { pass=$((pass + 1)); printf 'ok - %s\n' "$*"; }
bad() {
  fail=$((fail + 1)); printf 'not ok - %s\n' "$*"
  sed 's/^/  stdout: /' "$CASE/out"; sed 's/^/  stderr: /' "$CASE/err"
}
check() { label=$1; shift; if "$@"; then ok "$label"; else bad "$label"; fi; }

printf '#!/bin/sh\nexec "%s" "$@"\n' "$ROOT/tests/fixtures/mock-gitleaks" >"$CASE/good/gitleaks"
printf '#!/bin/sh\n[ "${1:-}" != version ] || { echo 8.30.1; exit 0; }\necho scanner broke >&2\nexit 2\n' \
  >"$CASE/scanfail/gitleaks"
printf '#!/bin/sh\n[ "${1:-}" != version ] || exec sleep 6\nexit 0\n' >"$CASE/hang/gitleaks"
chmod +x "$CASE/good/gitleaks" "$CASE/scanfail/gitleaks" "$CASE/hang/gitleaks"
GOOD="$CASE/good/gitleaks" MISSING=/nonexistent/gitleaks
SCANFAIL="$CASE/scanfail/gitleaks" HANG="$CASE/hang/gitleaks"
git init -q "$CASE/w" || exit 1

marker="AGENT_GUARD_TEST_""SECRET"
seq_n=0
# $1 subcommand, $2 policy (unset, or a value for the variable), $3 scanner,
# $4 event JSON. Leaves the status in s and the streams in $CASE/out and err.
hook() {
  seq_n=$((seq_n + 1))
  hook_event=$(printf '%s' "$4" | jq -c --arg s "scan-default-$seq_n" --arg d "$CASE/w" \
    '. + {session_id: $s, cwd: $d}')
  (
    cd "$CASE/w" || exit 99
    [ "$2" = unset ] || export AGENT_GUARD_INFRA_FAILURE_MODE="$2"
    printf '%s' "$hook_event" \
      | AGENT_GUARD_GITLEAKS_BIN="$3" AGENT_GUARD_HOOK_HOST="${HOST:-claude}" "$GUARD" "$1" \
        >"$CASE/out" 2>"$CASE/err"
  )
  s=$?
}
err_has() { grep -Fq -- "$1" "$CASE/err"; }
out_has() { grep -Fq -- "$1" "$CASE/out"; }
any_has() { cat "$CASE/out" "$CASE/err" | grep -Fq -- "$1"; }
bash_clean='{"tool_name":"Bash","tool_input":{"command":"ls -la"}}'
read_clean=$(jq -nc --arg p "$CASE/w/notes.txt" '{tool_name:"Read",tool_input:{file_path:$p}}')
write_marker=$(jq -nc --arg m "$marker" --arg p "$CASE/w/notes.txt" \
  '{tool_name:"Write",tool_input:{file_path:$p,content:("value " + $m)}}')
post_marker=$(jq -nc --arg m "$marker" \
  '{tool_name:"Bash",tool_input:{command:"cat notes"},
    tool_response:{stdout:("value " + $m),stderr:"",interrupted:false,isImage:false}}')
failure_marker=$(jq -nc --arg m "$marker" \
  '{tool_name:"Bash",tool_input:{command:"false"},error:("failed with " + $m)}')
prompt_marker=$(jq -nc --arg m "$marker" '{prompt:("please use " + $m + " here")}')
default_block='Blocking because the secret scan did not run'

# Controls: a scanner that works passes clean input and stops the marker, so
# the blocks below come from the missing scan and not from the harness.
hook hook-pre-tool unset "$GOOD" "$bash_clean"
check 'control: a working scanner passes a clean command with no message' \
  test "$s:$(cat "$CASE/out" "$CASE/err" | wc -c | tr -d ' ')" = 0:0
hook hook-pre-tool unset "$GOOD" "$write_marker"
check 'control: a working scanner blocks the marker in a Write' test "$s" -eq 2
hook hook-post-tool unset "$GOOD" "$post_marker"
check 'control: a working scanner masks the marker in tool output' \
  sh -c 'test "$1" -eq 0 && grep -Fq updatedToolOutput "$2" && ! grep -Fq "$3" "$2"' _ "$s" "$CASE/out" "$marker"
hook hook-user-prompt unset "$GOOD" "$prompt_marker"
check 'control: a working scanner blocks the marker in a prompt' test "$s" -eq 2

# PreToolUse: no scanner, no call.
for pre_event in "$bash_clean" "$read_clean" "$write_marker"; do
  pre_tool=$(printf '%s' "$pre_event" | jq -r .tool_name)
  hook hook-pre-tool unset "$MISSING" "$pre_event"
  check "PreToolUse $pre_tool is blocked by default when gitleaks is missing" \
    sh -c 'test "$1" -eq 2 && grep -Fq "$2" "$3"' _ "$s" "$default_block" "$CASE/err"
done
hook hook-pre-tool unset "$MISSING" "$bash_clean"
check 'the default block names the missing scanner' err_has 'missing or unusable: gitleaks.'
check 'the default block names doctor and the install path' \
  sh -c 'grep -Fq " doctor " "$1" && grep -Fq "setup --install" "$1" && grep -Fq setup-agent-guard "$1"' _ "$CASE/err"
check 'the default block does not tell the model which setting lets it pass' \
  sh -c '! grep -Fq "AGENT_GUARD_INFRA_FAILURE_MODE=open" "$1"' _ "$CASE/err"
hook hook-pre-tool open "$MISSING" "$bash_clean"
check 'explicit open still lets the call through with a notice' \
  sh -c 'test "$1" -eq 0 && grep -Fq "continuing because AGENT_GUARD_INFRA_FAILURE_MODE=open." "$2"' _ "$s" "$CASE/err"
check 'an explicit open is not described as the default' \
  sh -c '! grep -Fq "(the default)" "$1"' _ "$CASE/err"
hook hook-pre-tool closed "$MISSING" "$bash_clean"
check 'explicit closed keeps its own reason' \
  sh -c 'test "$1" -eq 2 && grep -Fq "Blocking because AGENT_GUARD_INFRA_FAILURE_MODE=closed." "$2"' _ "$s" "$CASE/err"
hook hook-pre-tool strict "$MISSING" "$bash_clean"
check 'an unknown value is read as unset' \
  sh -c 'test "$1" -eq 2 && grep -Fq "$2" "$3"' _ "$s" "$default_block" "$CASE/err"

# A scan that started and failed is the same case.
hook hook-pre-tool unset "$SCANFAIL" "$write_marker"
check 'a scan that errors is blocked by default' \
  sh -c 'test "$1" -eq 2 && grep -Fq "scanner infrastructure failed before it could verify" "$2" && grep -Fq "$3" "$2"' \
  _ "$s" "$CASE/err" "$default_block"
hook hook-pre-tool open "$SCANFAIL" "$write_marker"
check 'explicit open passes a scan that errors' test "$s" -eq 0

# A version check that timed out needs a retry, not an installation.
hook hook-pre-tool unset "$HANG" "$bash_clean"
check 'a timed-out version check is blocked by default' \
  sh -c 'test "$1" -eq 2 && grep -Fq "Scanner readiness: timeout." "$2" && grep -Fq "$3" "$2"' \
  _ "$s" "$CASE/err" "$default_block"
check 'the timeout block says to retry and names doctor, not an install' \
  sh -c 'grep -Fq "retry the call" "$1" && grep -Fq " doctor " "$1" && ! grep -Fq setup-agent-guard "$1"' _ "$CASE/err"

# PostToolUse runs after the tool: the block must also replace the output.
hook hook-post-tool unset "$MISSING" "$post_marker"
check 'PostToolUse blocks by default when gitleaks is missing' \
  sh -c 'test "$1" -eq 2 && grep -Fq "$2" "$3"' _ "$s" "$default_block" "$CASE/err"
check 'the unscanned output is replaced, so the marker does not reach the agent' \
  sh -c 'grep -Fq updatedToolOutput "$1" && grep -Fq REDACTED "$1" && ! grep -Fq "$2" "$1"' _ "$CASE/out" "$marker"
check 'the replacement is one JSON object' test "$(jq -s length <"$CASE/out" 2>/dev/null)" = 1
hook hook-post-tool open "$MISSING" "$post_marker"
check 'explicit open leaves the output alone and says the scan did not run' \
  sh -c 'test "$1" -eq 0 && ! grep -Fq updatedToolOutput "$2" && grep -Fq DEGRADED "$2"' _ "$s" "$CASE/out"

# A failed tool result cannot be blocked or replaced; it is reported.
hook hook-post-tool-failure unset "$MISSING" "$failure_marker"
check 'PostToolUseFailure reports an unchecked failure by default' \
  sh -c 'test "$1" -eq 0 && grep -Fq "NOT checked" "$2" && grep -Fq additionalContext "$2"' _ "$s" "$CASE/out"

# The prompt.
hook hook-user-prompt unset "$MISSING" "$prompt_marker"
check 'a prompt is blocked by default when gitleaks is missing' \
  sh -c 'test "$1" -eq 2 && grep -Fq "$2" "$3"' _ "$s" "$default_block" "$CASE/err"
hook hook-user-prompt open "$MISSING" "$prompt_marker"
check 'explicit open passes a rule-only prompt and says the scan did not run' \
  sh -c 'test "$1" -eq 0 && grep -Fq "secret scan did not run" "$2"' _ "$s" "$CASE/err"
big_prompt=$(LC_ALL=C awk 'BEGIN {
  for (i = 0; i < 8000; i++)
    printf "line %d of an innocuous log dump with nothing sensitive\n", i
}' | jq -Rsc '{prompt: .}')
hook hook-user-prompt unset "$GOOD" "$big_prompt"
check 'a prompt over the scan cap is blocked by default and says how to narrow it' \
  sh -c 'test "$1" -eq 2 && grep -Fq "too large" "$2" && grep -Fq "smaller parts" "$2"' _ "$s" "$CASE/err"
hook hook-user-prompt open "$GOOD" "$big_prompt"
check 'explicit open passes a prompt over the scan cap' test "$s" -eq 0

# Failures that are not a missing secret scan keep the open default.
unresolved='{"tool_name":"Bash","tool_input":{"command":"\"${TOOL:-git}\" commit -m x"}}'
hook hook-pre-tool unset "$GOOD" "$unresolved"
check 'an unresolved git command still continues by default' \
  sh -c 'test "$1" -eq 0 && grep -Fq "could not be resolved safely" "$2" && grep -Fq "continuing because AGENT_GUARD_INFRA_FAILURE_MODE=open (the default)." "$2"' \
  _ "$s" "$CASE/err"
hook hook-pre-tool closed "$GOOD" "$unresolved"
check 'explicit closed blocks an unresolved git command' \
  sh -c 'test "$1" -eq 2 && grep -Fq "Blocking because AGENT_GUARD_INFRA_FAILURE_MODE=closed." "$2"' _ "$s" "$CASE/err"

# The commit gate: a scanner that fails is blocked, because a push cannot be
# taken back; a directory that is no repository is not a missing scan (the
# commit fails there by itself).
git -C "$CASE/w" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m base || exit 1
printf 'plain words\n' >"$CASE/w/staged.txt"
git -C "$CASE/w" add staged.txt || exit 1
commit='{"tool_name":"Bash","tool_input":{"command":"git commit -m note"}}'
hook hook-pre-tool unset "$GOOD" "$commit"
check 'control: a clean staged change passes the commit gate' test "$s" -eq 0
hook hook-pre-tool unset "$SCANFAIL" "$commit"
check 'the commit gate is blocked by default when its gitleaks scan fails' \
  sh -c 'test "$1" -eq 2 && grep -Fq "scanner infrastructure failed before it could verify" "$2" && grep -Fq "$3" "$2"' \
  _ "$s" "$CASE/err" "$default_block"
hook hook-pre-tool open "$SCANFAIL" "$commit"
check 'explicit open passes a commit whose gitleaks scan fails' test "$s" -eq 0
mkdir -p "$CASE/plain"
norepo=$(jq -nc --arg d "$CASE/plain" '{tool_name:"Bash",tool_input:{command:"git commit -m note"},cwd:$d}')
seq_n=$((seq_n + 1))
printf '%s' "$norepo" | jq -c --arg s "scan-default-$seq_n" '. + {session_id: $s}' \
  | (cd "$CASE/plain" && AGENT_GUARD_GITLEAKS_BIN="$GOOD" AGENT_GUARD_HOOK_HOST=claude "$GUARD" hook-pre-tool \
      >"$CASE/out" 2>"$CASE/err")
s=$?
check 'a commit in a directory that is no repository still continues by default' \
  sh -c 'test "$1" -eq 0 && grep -Fq "is not a git repository" "$2" && grep -Fq "continuing because AGENT_GUARD_INFRA_FAILURE_MODE=open (the default)." "$2"' \
  _ "$s" "$CASE/err"

# The disk backstops after a tool call keep the open default: withholding the
# output would do nothing for a file on disk.
big="$CASE/w/big.bin"
post_write=$(jq -nc --arg p "$big" '{tool_name:"Write",tool_input:{file_path:$p,content:"plain"},
  tool_response:{type:"create",filePath:$p,content:"plain",structuredPatch:[],originalFile:null,userModified:false}}')
printf '%s\n' '*.bin' >"$CASE/w/.gitignore"
# An ignored file over the 10 MiB scan budget: the written-file scan cannot run.
dd if=/dev/zero of="$big" bs=1048576 count=11 2>/dev/null || exit 1
hook hook-post-tool unset "$GOOD" "$post_write"
check 'a written file the backstop cannot scan still continues by default' \
  sh -c 'test "$1" -eq 0 && grep -Fq "could not be scanned" "$2" && grep -Fq "continuing because AGENT_GUARD_INFRA_FAILURE_MODE=open (the default)." "$2" && ! grep -Fq REDACTED "$3"' \
  _ "$s" "$CASE/err" "$CASE/out"
hook hook-post-tool closed "$GOOD" "$post_write"
check 'explicit closed blocks a written file the backstop cannot scan' test "$s" -eq 2
rm -f "$big"

# Codex takes no replacement; the default still blocks and names the reason.
HOST=codex hook hook-pre-tool unset "$MISSING" "$bash_clean"
check 'Codex PreToolUse is blocked by default when gitleaks is missing' \
  sh -c 'test "$1" -eq 2 && grep -Fq "$2" "$3"' _ "$s" "$default_block" "$CASE/err"

printf '1..%s\n' "$((pass + fail))"
[ "$fail" -eq 0 ]
