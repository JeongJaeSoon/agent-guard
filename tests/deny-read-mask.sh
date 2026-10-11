#!/usr/bin/env sh
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
GUARD="$ROOT/plugins/agent-guard/bin/agent-guard"
MOCK_GITLEAKS="$ROOT/tests/fixtures/mock-gitleaks"
CASE=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-deny-mask.XXXXXX")
CASE=$(CDPATH= cd -- "$CASE" && pwd -P)
trap 'chmod -R u+rwx "$CASE" 2>/dev/null; rm -rf "$CASE"' 0
export AGENT_GUARD_LOG_MODE=off
export AGENT_GUARD_GITLEAKS_BIN="$MOCK_GITLEAKS"
export AGENT_GUARD_WARNING_DIR="$CASE/warnings"
unset AI_AGENT AGENT_GUARD_DENY_READ_MODE AGENT_GUARD_INFRA_FAILURE_MODE
pass=0; fail=0
ok() { pass=$((pass + 1)); printf 'ok - %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'not ok - %s\n' "$1"; }
rand() { od -An -N12 -tx1 /dev/urandom | tr -d ' \n'; }
VALUES=
gen() {
  for gen_name in "$@"; do
    gen_v=$(rand)
    eval "$gen_name=\$gen_v"
    VALUES="$VALUES $gen_v"
  done
}
show() {
  sed 's/^/  stdout: /' "$CASE/out"
  sed 's/^/  stderr: /' "$CASE/err"
}

W="$CASE/work"
mkdir "$W"
DOT=".en""v"
gen V1 V2 V3
printf '# database\nDB_PASSWORD=%s\nexport API_TOKEN="%s"\nEMPTY=\nOTHER=%s # note\n' \
  "$V1" "$V2" "$V3" >"$W/$DOT"
VIEW='# database
DB_PASSWORD=[MASKED]
export API_TOKEN=[MASKED]
EMPTY=
OTHER=[MASKED]
'
HEADER="agent-guard: masked view follows (values replaced with [MASKED]; the file itself was not read by the tool)"
EXPECTED="agent-guard: blocked sensitive file access: $W/$DOT
$HEADER
$VIEW"
GUIDE='agent-guard: for a masked view, read the protected file alone with the read tool or `cat <path>`'
BAD_MODE='agent-guard: AGENT_GUARD_DENY_READ_MODE must be block or mask; no masked view'

hook() {
  hook_host=$1 hook_mode=$2 hook_json=$3
  shift 3
  printf '%s' "$hook_json" | env AGENT_GUARD_HOOK_HOST="$hook_host" \
    AGENT_GUARD_DENY_READ_MODE="$hook_mode" "$@" "$GUARD" hook-pre-tool \
    >"$CASE/out" 2>"$CASE/err"
  status=$?
}
read_json() { jq -nc --arg p "$1" '{tool_name:"Read",tool_input:{file_path:$p},session_id:"deny-mask"}'; }
bash_json() { jq -nc --arg c "$1" --arg d "$W" '{tool_name:"Bash",tool_input:{command:$c,workdir:$d},session_id:"deny-mask"}'; }

no_values() {
  for v in $VALUES; do
    if grep -Fq "$v" "$CASE/out" "$CASE/err"; then return 1; fi
  done
  return 0
}

expect_reason() {
  if [ "$status" -eq 2 ] && [ ! -s "$CASE/out" ] \
     && printf '%s' "$2" | cmp -s - "$CASE/err" && no_values; then
    ok "$1"
  else
    bad "$1 (status $status)"
    show
  fi
}

expect_blocked() {
  if [ "$status" -eq 2 ] && no_values && ! grep -Fq "$HEADER" "$CASE/err" \
     && ! grep -Fq '[MASKED]' "$CASE/err" \
     && { [ $# -lt 2 ] || [ "$(tail -n 1 "$CASE/err")" = "$2" ]; }; then
    ok "$1"
  else
    bad "$1 (status $status)"
    show
  fi
}

for host in claude codex; do
  hook "$host" mask "$(read_json "$W/$DOT")"
  expect_reason "$host: mask Read gets the masked view" "$EXPECTED"
  for cmd in "cat $DOT" "cat -- $DOT" "  cat	 ./$DOT  " "cat $W/$DOT"; do
    hook "$host" mask "$(bash_json "$cmd")"
    expect_reason "$host: mask '$cmd' gives the Read reason byte for byte" "$EXPECTED"
  done
done

hook claude mask "$(jq -nc --arg d "$W" --arg c "cat $DOT" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}')"
expect_reason "cat resolves a relative path against the event cwd" "$EXPECTED"

mkdir "$CASE/home"
cp "$W/$DOT" "$CASE/home/$DOT"
hook claude mask "$(bash_json "cat ~/$DOT")" HOME="$CASE/home"
expect_reason "cat ~/ resolves against HOME" "agent-guard: blocked sensitive file access: $CASE/home/$DOT
$HEADER
$VIEW"

ln -s "$DOT" "$W/link.env"
hook claude mask "$(read_json "$W/link.env")"
expect_reason "Read of a symlink names the resolved file" "$EXPECTED"
hook claude mask "$(bash_json "cat link.env")"
expect_reason "cat of a symlink names the resolved file" "$EXPECTED"

# Claude Code 2.1.214+ also gets the reason as JSON.
for json in "$(read_json "$W/$DOT")" "$(bash_json "cat $DOT")"; do
  hook claude mask "$json" AI_AGENT=claude-code_2-1-300_test
  reason=$(jq -r '.hookSpecificOutput.permissionDecisionReason' "$CASE/out" 2>/dev/null)
  if [ "$status" -eq 2 ] && printf '%s' "$EXPECTED" | cmp -s - "$CASE/err" \
     && [ "$reason" = "$(printf '%s' "$EXPECTED")" ] \
     && [ "$(jq -r '.hookSpecificOutput.permissionDecision' "$CASE/out")" = deny ] \
     && no_values; then
    ok "claude JSON reason carries the masked view ($(printf '%s' "$json" | jq -r .tool_name))"
  else
    bad "claude JSON reason carries the masked view (status $status)"
    show
  fi
done

for mode in "" block; do
  for host in claude codex; do
    hook "$host" "$mode" "$(read_json "$W/$DOT")"
    expect_reason "$host: mode '${mode:-unset}' Read blocks as before" \
      "agent-guard: blocked sensitive file access: $W/$DOT
"
    hook "$host" "$mode" "$(bash_json "cat $DOT")"
    expect_blocked "$host: mode '${mode:-unset}' cat blocks as before without guidance" \
      "agent-guard: if the command reads no protected file, rewrite the matched text so it is not path-shaped and retry; do not weaken the deny list. Examples: jq '.[\"key\"]' instead of jq '.key'; a commit message that omits the path; a structured Grep pattern instead of an inline shell search."
  done
done

BAD_VALUE=mask-please-$(rand)
hook claude "$BAD_VALUE" "$(read_json "$W/$DOT")"
expect_reason "invalid mode blocks a Read and names only the variable" \
  "agent-guard: blocked sensitive file access: $W/$DOT
$BAD_MODE
"
hook claude "$BAD_VALUE" "$(bash_json "cat $DOT")"
if [ "$status" -eq 2 ] && [ "$(tail -n 1 "$CASE/err")" = "$BAD_MODE" ] \
   && ! grep -Fq "$BAD_VALUE" "$CASE/err" && no_values; then
  ok "invalid mode blocks cat and names only the variable"
else
  bad "invalid mode blocks cat and names only the variable (status $status)"
  show
fi
hook claude "$BAD_VALUE" "$(read_json "$ROOT/README.md")"
if [ "$status" -eq 0 ] && [ ! -s "$CASE/err" ]; then
  ok "invalid mode does not affect a read that is not deny-listed"
else
  bad "invalid mode does not affect a read that is not deny-listed (status $status)"
  show
fi

NL='
'
for cmd in "cat \"$DOT\"" "cat '$DOT'" "cat \$PWD/$DOT" "cat .en*" "cat .en?" \
  "cat $DOT $DOT" "cat $DOT | head" "cat $DOT >copy" "cat <$DOT" "cat $DOT; true" \
  "cat $DOT && true" "cat $DOT${NL}true" "true${NL}cat $DOT" "X=1 cat $DOT" "sed -n p $DOT" "head $DOT" \
  "cat -n $DOT" "cat ~+/$DOT" "cat\\ $DOT" "less $DOT" "cat $DOT &"; do
  hook claude mask "$(bash_json "$cmd")"
  expect_blocked "mask '$cmd' blocks without content and ends with the guidance" "$GUIDE"
done

for tool in Grep Glob NotebookRead; do
  hook claude mask "$(jq -nc --arg t "$tool" --arg p "$W/$DOT" '{tool_name:$t,tool_input:{path:$p,notebook_path:$p,pattern:"x"}}')"
  expect_blocked "mask $tool blocks without a masked view"
done
hook claude mask "$(jq -nc --arg p "$W/$DOT" '{tool_name:"Read",tool_input:{file_path:$p,note:$p}}')"
expect_reason "mask Read with a second deny-listed field blocks as before" \
  "agent-guard: blocked sensitive file access: $W/$DOT
"
hook claude mask "$(jq -nc --arg p "$W/$DOT" --arg r "$ROOT/README.md" '{tool_name:"Read",tool_input:{file_path:$r,note:$p}}')"
expect_blocked "mask Read with the deny-listed path outside file_path blocks"
hook claude mask "$(jq -nc --arg p "$DOT" '{tool_name:"Read",tool_input:{file_path:$p}}')"
expect_blocked "mask Read of a relative path blocks without a masked view"

mkdir "$CASE/fail"
gen F1 F2 F3
printf 'machine x login y password %s\n' "$F1" >"$CASE/fail/.netrc"
printf 'GOOD=%s\nnot an assignment %s\n' "$F2" "$F2" >"$CASE/fail/broken.env"
mkdir "$CASE/fail/dir.env"
awk -v v="$F3" 'BEGIN { for (i = 0; i < 6000; i++) print "K" i "=" v }' >"$CASE/fail/huge.env"
printf 'K=%s\n' "$F3" >"$CASE/fail/locked.env"
printf 'K=%s\n' "$F3" >"$CASE/fail/.envrc"
chmod 000 "$CASE/fail/locked.env"
for name in .netrc .envrc broken.env dir.env huge.env locked.env missing.env; do
  [ "$name" = locked.env ] && [ -r "$CASE/fail/locked.env" ] && continue
  for form in read cat; do
    case $form in
      read) hook claude mask "$(read_json "$CASE/fail/$name")" ;;
      cat) hook claude mask "$(bash_json "cat $CASE/fail/$name")" ;;
    esac
    expect_blocked "mask $form of $name blocks without content" \
      "agent-guard: no masked view: the file is not a readable json, yaml, ini or dotenv file within the supported subset and 64 KiB"
  done
done

mkdir "$CASE/nomktemp"
printf '#!/bin/sh\nexit 1\n' >"$CASE/nomktemp/mktemp"
chmod +x "$CASE/nomktemp/mktemp"
for json in "$(read_json "$W/$DOT")" "$(bash_json "cat $DOT")"; do
  hook claude mask "$json" PATH="$CASE/nomktemp:$PATH"
  expect_blocked "mask blocks without content when temp files fail ($(printf '%s' "$json" | jq -r .tool_name))"
done

mkdir "$CASE/size"
gen S1
pad() { awk -v n="$1" 'BEGIN { s = "#"; while (length(s) < n) s = s "x"; print s }'; }
{ printf 'K=%s\n' "$S1"; pad 6132; } >"$CASE/size/at.env"
{ printf 'K=%s\n' "$S1"; pad 6133; } >"$CASE/size/over.env"
hook claude mask "$(read_json "$CASE/size/at.env")"
size=$(sed '1,2d' "$CASE/err" | wc -c | tr -d ' ')
if [ "$status" -eq 2 ] && [ "$size" -eq 6144 ] && no_values && grep -Fqx "$HEADER" "$CASE/err"; then
  ok "a 6,144-byte view is returned"
else
  bad "a 6,144-byte view is returned (status $status, $size bytes)"
  show
fi
hook claude mask "$(read_json "$CASE/size/over.env")"
expect_reason "a 6,145-byte view is refused, not cut" \
  "agent-guard: blocked sensitive file access: $CASE/size/over.env
agent-guard: no masked view: the file is too large for a masked view
"

mkdir "$CASE/scan"
printf '# rotated AGENT_GUARD_TEST_SECRET last week\nK=%s\n' "$V1" >"$CASE/scan/$DOT"
for infra in open closed; do
  hook claude mask "$(read_json "$CASE/scan/$DOT")" AGENT_GUARD_INFRA_FAILURE_MODE="$infra"
  expect_reason "a secret left in a comment refuses the view (infra $infra)" \
    "agent-guard: blocked sensitive file access: $CASE/scan/$DOT
agent-guard: no masked view: the masked view still contains secret-like text
"
done

printf '#!/bin/sh\n[ "${1:-}" = stdin ] && exit 7\nexec "%s" "$@"\n' "$MOCK_GITLEAKS" >"$CASE/gitleaks-fails-scans"
chmod +x "$CASE/gitleaks-fails-scans"
for infra in open closed; do
  hook claude mask "$(jq -nc --arg p "$W/$DOT" --arg s "deny-mask-scan-$infra-$$" '{tool_name:"Read",tool_input:{file_path:$p},session_id:$s}')" \
    AGENT_GUARD_GITLEAKS_BIN="$CASE/gitleaks-fails-scans" AGENT_GUARD_INFRA_FAILURE_MODE="$infra"
  expect_reason "a rescan that cannot run refuses the view (infra $infra)" \
    "agent-guard: blocked sensitive file access: $W/$DOT
agent-guard: no masked view: the secret scanner could not check the masked view
"
done

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
