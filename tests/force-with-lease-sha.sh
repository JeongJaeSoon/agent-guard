#!/usr/bin/env sh
set -u

# `git push --force-with-lease=<ref>:<expect>` names the object id the remote
# ref must still point at: 40 lowercase hex (64 in a SHA-256 repository). When
# the ref name holds a keyword such as `access` or `token`, generic-api-key
# reads `<ref>:<id>` as a labelled secret (#478). Only that exact shape, on a
# line with no other assignment, may pass the Bash PreToolUse check and the
# prompt guard, on Claude and Codex. A conventional-commit message before the
# push (`git commit -m "fix(scope): a, b" && git push --force-with-lease=...`)
# passes too, because a separator there is followed only by short words; a
# separator followed by a value-length token run (a real-looking value inside
# the message, a later assignment, an API-key header) keeps the findings. A longer hex run, uppercase hex, quoted or
# two-argument spellings, and a real keyword assignment (alone or on the same
# line as a lease) keep their findings.
# Kept out of tests/run.sh: the monolith is already near ShellCheck's memory
# limit in CI, so each added line there risks the Lint job.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
GUARD="$ROOT/plugins/agent-guard/bin/agent-guard"
CASE=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-lease-sha.XXXXXX") || exit 1
[ -n "$CASE" ] || exit 1
CASE=$(CDPATH= cd -- "$CASE" && pwd -P) || exit 1
trap 'rm -rf "$CASE"' EXIT INT TERM
mkdir "$CASE/cwd" "$CASE/home" "$CASE/scan"
# A host that passes the variable empty means "no real gitleaks".
GITLEAKS=${AGENT_GUARD_TEST_REAL_GITLEAKS-$(command -v gitleaks 2>/dev/null || true)}
if [ -z "$GITLEAKS" ]; then
  printf 'skip - real gitleaks is not installed\n'
  exit 0
fi
export HOME="$CASE/home" AGENT_GUARD_LOG_MODE=off AGENT_GUARD_RELEASE_CHECK=off
export AGENT_GUARD_GITLEAKS_CONFIG=${FORCE_LEASE_TEST_CONFIG:-$ROOT/plugins/agent-guard/config/gitleaks.toml}
export AGENT_GUARD_PII_HOOK_MODE=off AGENT_GUARD_PROMPT_GUARD_MODE=block
export AGENT_GUARD_INFRA_FAILURE_MODE=closed AGENT_GUARD_WARNING_DIR="$CASE/warnings"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
unset AGENT_GUARD_GITLEAKS_BIN AGENT_GUARD_OUTPUT_REDACT AI_AGENT
PATH="$(dirname "$GITLEAKS"):$PATH"
# The Bash check scans a command that mentions git from inside a repository.
git init -q "$CASE/cwd" || exit 1
pass=0
fail=0
n=0

ok() { pass=$((pass + 1)); printf 'ok - %s\n' "$1"; }
not_ok() {
  fail=$((fail + 1))
  printf 'not ok - %s\n' "$1"
  cut -c1-200 "$CASE/err" | sed 's/^/  stderr: /'
}

# Fixed, not random: a low-entropy id falls under generic-api-key's 3.5
# entropy floor and would turn every must-keep-finding case into a silent
# pass. Built from pieces at run time so this file holds no literal finding.
SHA1=$(printf '%s%s%s%s' 9f3a7c21d4e6 b05a8c731d2f 4e69ab07c35d 8e12)
SHA2=$(printf '%s%s%s%s%s' 4b1d09e7a35c 82f6d0143ba9 c7e5128d6f40 a93be5071c2d 68f4e3a1b957c2d1)
OTHER=$(printf '%s%s%s%s' 3c8e5a09f1d7 24b6e08c9a13 d5f7e2410b68 a9c4)
if [ "${#SHA1}" -ne 40 ] || [ "${#SHA2}" -ne 64 ] || [ "${#OTHER}" -ne 40 ]; then
  printf 'not ok - fixed hex lengths\n'
  exit 1
fi
UPPER=$(printf '%s' "$SHA1" | tr 'a-f' 'A-F')
TAIL10=$(printf '%s' "$OTHER" | cut -c1-10)
TEN=$(printf "%s%s" abcdef 1234)
ACC=agent-access-team-only
TOK=api-token-rotation
P=$(printf '%s%s' to ken)
LEASE="git push --force-with-lease"
# A keyword branch longer than nine characters, as in #503's report.
KC=team/keycloak-login-flow

# $1 host, $2 expected status, $3 label, $4 Bash command, $5 the block
# message expected (default: the shell command scan's).
pre_case() {
  n=$((n + 1))
  jq -nc --arg c "$4" --arg d "$CASE/cwd" --arg s "lease-$n" \
    '{session_id:$s,hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$c},cwd:$d}' |
    (cd "$CASE/cwd" && AGENT_GUARD_HOOK_HOST=$1 "$GUARD" hook-pre-tool) >"$CASE/out" 2>"$CASE/err"
  status=$?
  if [ "$status" -ne "$2" ]; then
    not_ok "$1 PreToolUse: $3 (expected $2, got $status)"
  elif [ "$2" -eq 2 ] && ! grep -q "${5:-secret-like value detected in shell command}" "$CASE/err"; then
    not_ok "$1 PreToolUse: $3 (blocked without the expected message)"
  else
    ok "$1 PreToolUse: $3"
  fi
}

# $1 host, $2 expected status, $3 label, $4 prompt text.
prompt_case() {
  n=$((n + 1))
  jq -nc --arg p "$4" --arg d "$CASE/cwd" --arg s "lease-$n" \
    '{session_id:$s,hook_event_name:"UserPromptSubmit",prompt:$p,cwd:$d}' |
    (cd "$CASE/cwd" && AGENT_GUARD_HOOK_HOST=$1 "$GUARD" hook-user-prompt) >"$CASE/out" 2>"$CASE/err"
  status=$?
  if [ "$status" -eq "$2" ]; then
    ok "$1 UserPromptSubmit: $3"
  else
    not_ok "$1 UserPromptSubmit: $3 (expected $2, got $status)"
  fi
}

# Same text through the Bash command check and the prompt guard. The prompt
# prefix holds no `:` or `=`, which would keep the lease line from passing.
# Both checks get the same event for both hosts here, and the host changes the
# block message and output envelope, never the decision. So they run for
# Claude; the rows after the loop keep one passing and one blocking command and
# prompt for Codex.
both() {
  [ "$1" != codex ] || return 0
  pre_case "$1" "$2" "$3" "$4"
  prompt_case "$1" "$2" "$3" "the subagent ran $4"
}

for host in claude codex; do
  both "$host" 0 'lease on a keyword branch with a 40-hex id' "$LEASE=$ACC:$SHA1 origin HEAD"
  both "$host" 0 'lease on a second keyword branch' "$LEASE=$TOK:$SHA1 origin HEAD"
  both "$host" 0 'lease with a 64-hex id (SHA-256 repository)' "$LEASE=$ACC:$SHA2 origin HEAD"
  both "$host" 0 'lease at the end of the line' "git push origin HEAD --force-with-lease=$TOK:$SHA1"
  both "$host" 0 'lease after a commit without assignments' "git commit -m wip && $LEASE=$ACC:$SHA1 origin HEAD"
  both "$host" 0 'lease with a slash in the ref name' "$LEASE=team/$ACC:$SHA1 origin HEAD"
  both "$host" 0 'conventional commit and lease' "git commit -m \"fix: tighten lease check\" && $LEASE=$ACC:$SHA1 origin HEAD"
  both "$host" 0 'git add, commit and lease' "git add -A && git commit -m \"fix: tighten lease check\" && $LEASE=$ACC:$SHA1 origin HEAD"
  both "$host" 0 'two -m messages and lease' "git commit -m \"fix: tighten\" -m \"body: more detail here\" && $LEASE=$TOK:$SHA1 origin HEAD"
  both "$host" 0 'scoped commit message and lease' "git commit -m \"fix(scope): tighten lease check\" && $LEASE=$ACC:$SHA2 origin HEAD"
  both "$host" 0 'commit message with a comma and lease' "git commit -m \"fix(scope): tighten, then check\" && $LEASE=$ACC:$SHA1 origin HEAD"
  both "$host" 0 'lease then prose with a colon' "$LEASE=$ACC:$SHA1 origin HEAD && echo done: ok, yes"
  # The refspec usually pushed with the lease (#503): `<remote> HEAD:<ref>`
  # right after it, whatever the length of the ref name.
  both "$host" 0 'lease, remote and HEAD:<keyword branch>' "$LEASE=$KC:$SHA1 origin HEAD:$KC"
  both "$host" 0 'lease, remote and HEAD:<access branch>' "$LEASE=$ACC:$SHA1 origin HEAD:$ACC"
  both "$host" 0 'lease, remote and +HEAD:refs/heads/<branch>' "$LEASE=$TOK:$SHA2 origin +HEAD:refs/heads/$TOK"
  both "$host" 0 'commit, then lease with a refspec' "git commit -m \"fix: tighten lease check\" && $LEASE=$KC:$SHA1 origin HEAD:$KC"

  both "$host" 2 'access_token: hex' "access_$P: $OTHER"
  both "$host" 2 'api_token=hex' "api_$P=$OTHER"
  both "$host" 2 'ACCESS_KEY="hex"' "ACCESS_KEY=\"$OTHER\""
  both "$host" 2 'lease then a keyword assignment on the same line' "$LEASE=$ACC:$SHA1 origin HEAD; api_$P=$OTHER"
  both "$host" 2 'keyword assignment then a lease on the same line' "api_$P=$OTHER; $LEASE=$ACC:$SHA1 origin HEAD"
  both "$host" 2 'lease then a colon-form keyword assignment' "$LEASE=$ACC:$SHA1 origin HEAD && echo access_$P: $OTHER"
  both "$host" 2 'commit, assignment before the push, and lease' "git commit -m \"fix: x\" && api_$P=$OTHER $LEASE=$ACC:$SHA1 origin HEAD"
  both "$host" 2 'real-looking value inside the commit message' "git commit -m \"$P: $OTHER\" && $LEASE=$ACC:$SHA1 origin HEAD"
  both "$host" 2 'lease then a header with a key' "git commit -m \"fix: x\" && $LEASE=$ACC:$SHA1 origin HEAD && curl -H \"X-Api-Key: $OTHER\" https://example.invalid"
  both "$host" 2 'comma form after a commit message' "git commit -m \"fix: $P, $OTHER\" && $LEASE=$ACC:$SHA1 origin HEAD"
  both "$host" 2 'refspec then a keyword assignment' "$LEASE=$KC:$SHA1 origin HEAD:$KC; api_$P=$OTHER"
  both "$host" 2 'keyword name and value in the refspec' "$LEASE=$KC:$SHA1 origin access_$P:$OTHER"
  both "$host" 2 'value after the refspec' "$LEASE=$KC:$SHA1 origin HEAD:$KC $P:$OTHER"
  # A credential in a URL is the URL deny pattern's to block; the line
  # allowlist must not reach it.
  pre_case "$host" 2 'token in the push URL' "git push https://x-access-$P:$OTHER@example.invalid/o/r.git HEAD:$KC" 'by deny pattern'
  pre_case "$host" 2 'token in the push URL after a lease' "$LEASE=$KC:$SHA1 https://x-access-$P:$OTHER@example.invalid/o/r.git HEAD:$KC" 'by deny pattern'
  prompt_case "$host" 2 'token in the push URL after a lease' "the subagent ran $LEASE=$KC:$SHA1 https://x-access-$P:$OTHER@example.invalid/o/r.git HEAD:$KC"
  both "$host" 2 'token in a git -C commit message' "git -C $CASE/cwd commit -m \"fix: rotate api_$P=$OTHER\""
  both "$host" 2 'token in a git commit message' "git commit -m \"$P: $OTHER\""
done
pre_case codex 0 'lease on a keyword branch with a 40-hex id' "$LEASE=$ACC:$SHA1 origin HEAD"
pre_case codex 2 'keyword assignment with a hex value' "api_$P=$OTHER"
prompt_case codex 0 'lease on a keyword branch with a 40-hex id' "the subagent ran $LEASE=$ACC:$SHA1 origin HEAD"
prompt_case codex 2 'keyword assignment with a hex value' "the subagent ran api_$P=$OTHER"

# Shape boundaries go through scan-path with the real scanner: the hooks let
# some of these shapes pass with or without this allowlist, so they cannot show
# that the allowlist stays narrow.
scan_case() {
  rm -f "$CASE/scan/"*
  printf '%s\n' "$3" >"$CASE/scan/fixture.txt"
  "$GUARD" scan-path "$CASE/scan" >"$CASE/out" 2>"$CASE/err"
  status=$?
  if [ "$status" -eq "$1" ]; then
    ok "scan-path: $2"
  else
    not_ok "scan-path: $2 (expected $1, got $status)"
  fi
}

scan_case 0 'lease on a keyword branch with a 40-hex id' "$LEASE=$ACC:$SHA1 origin HEAD"
scan_case 0 'lease with a 64-hex id (SHA-256 repository)' "$LEASE=$TOK:$SHA2 origin HEAD"
scan_case 0 'lease at the end of the line' "git push origin HEAD --force-with-lease=$TOK:$SHA1"
scan_case 0 'lease line followed by an unrelated line' "$LEASE=$ACC:$SHA1 origin HEAD
echo done"
scan_case 0 'conventional commit and lease' "git commit -m \"fix(scope): tighten, then check\" && $LEASE=$ACC:$SHA1 origin HEAD"
scan_case 0 'git add, commit with two -m, and lease' "git add -A && git commit -m \"fix: a\" -m \"body: more\" && $LEASE=$TOK:$SHA2 origin HEAD"
scan_case 1 'ten-character value after a separator before the lease' "git commit -m \"fix\" && api_$P=$TEN && $LEASE=$ACC:$SHA1 origin HEAD"
scan_case 1 'twelve-character base64 value after a separator' "git commit -m \"fix\" && api_$P=Ab3+Cd4/Ef5g && $LEASE=$ACC:$SHA1 origin HEAD"
scan_case 1 'value after five fill quotes' "git commit -m \"fix\" && api_$P=\"\"\"\"\"$OTHER && $LEASE=$ACC:$SHA1 origin HEAD"
scan_case 1 'value after => ' "git commit -m \"fix\" && api_$P=>\"$OTHER\" && $LEASE=$ACC:$SHA1 origin HEAD"
scan_case 1 'value after a bare comma' "git commit -m \"fix\" && echo $P, $OTHER && $LEASE=$ACC:$SHA1 origin HEAD"
scan_case 1 'value after || ' "git commit -m \"fix\" && api_$P || $OTHER && $LEASE=$ACC:$SHA1 origin HEAD"
scan_case 1 'assignment before the push on the same command' "git commit -m \"fix: x\" && api_$P=$OTHER $LEASE=$ACC:$SHA1"
scan_case 1 'real-looking value inside the commit message' "git commit -m \"$P: $OTHER\" && $LEASE=$ACC:$SHA1 origin HEAD"
scan_case 1 'header with a key after the lease' "git commit -m \"fix: x\" && $LEASE=$ACC:$SHA1 && curl -H \"X-Api-Key: $OTHER\" https://example.invalid"
scan_case 1 'lease line followed by a keyword assignment line' "$LEASE=$ACC:$SHA1 origin HEAD
api_$P=$OTHER"
scan_case 1 'access_token: hex' "access_$P: $OTHER"
scan_case 1 'api_token=hex' "api_$P=$OTHER"
scan_case 1 'ACCESS_KEY="hex"' "ACCESS_KEY=\"$OTHER\""
scan_case 1 'lease then a keyword assignment on the same line' "$LEASE=$ACC:$SHA1 origin HEAD; api_$P=$OTHER"
scan_case 1 'keyword assignment then a lease on the same line' "api_$P=$OTHER; $LEASE=$ACC:$SHA1 origin HEAD"
scan_case 1 'lease id with one more hex digit' "$LEASE=$ACC:${SHA1}a origin HEAD"
scan_case 1 'lease id followed by token characters' "$LEASE=$ACC:${SHA1}_x origin HEAD"
scan_case 1 'lease id followed by a second hex run' "$LEASE=$ACC:$SHA1$OTHER origin HEAD"
scan_case 1 'lease id with a 41 to 63 hex run' "$LEASE=$ACC:$SHA1$TAIL10 origin HEAD"
scan_case 1 'lease id with uppercase hex' "$LEASE=$ACC:$UPPER origin HEAD"
scan_case 1 'lease id in quotes' "$LEASE=$ACC:\"$SHA1\" origin HEAD"
scan_case 1 'two-argument spelling that git does not accept' "$LEASE $ACC:$SHA1 origin HEAD"
scan_case 1 'other flag with a keyword name and hex' "git push --force-if-includes=$ACC:$SHA1 origin HEAD"
scan_case 1 'keyword name and hex without the flag' "echo $ACC:$SHA1"
scan_case 1 'compact keyword key and hex' "access-$P:$SHA1"
scan_case 0 'lease, remote and HEAD:<keyword branch>' "$LEASE=$KC:$SHA1 origin HEAD:$KC"
scan_case 1 'refspec then a keyword assignment' "$LEASE=$KC:$SHA1 origin HEAD:$KC; api_$P=$OTHER"
scan_case 1 'keyword name and value in the refspec' "$LEASE=$KC:$SHA1 origin access_$P:$OTHER"
scan_case 1 'refspec ref with a value after a colon' "$LEASE=$KC:$SHA1 origin HEAD:$KC:$OTHER"
scan_case 1 'URL remote with a token before HEAD:<ref>' "$LEASE=$KC:$SHA1 https://x-access-$P:$OTHER@example.invalid/r HEAD:$KC"

printf '%s force-with-lease checks, %s failed\n' "$((pass + fail))" "$fail"
[ "$fail" -eq 0 ]
