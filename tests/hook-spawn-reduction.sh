#!/bin/sh
# #407: a hook used to start a process for every field it read from its own
# input, for every scan temp file, and for checks the shell can make itself.
# Each shortcut below must answer exactly what the process it replaces would
# have answered; whenever it cannot, it must fall back to that process. The
# unit cases compare both paths byte for byte, and the hook cases pin that the
# replaced jq runs are gone while every verdict (deny, block, mask) stays.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
GUARD="$ROOT/plugins/agent-guard/bin/agent-guard"
CASE=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-spawn.XXXXXX") || exit 1
CASE=$(CDPATH= cd -- "$CASE" && pwd -P)
trap 'rm -rf "$CASE"' 0 HUP INT TERM
pass=0 fail=0
ok() { pass=$((pass + 1)); printf 'ok - %s\n' "$*"; }
bad() { fail=$((fail + 1)); printf 'not ok - %s\n' "$*"; }
check() { label=$1; shift; if "$@"; then ok "$label"; else bad "$label"; fi; }

mkdir -p "$CASE/fn" "$CASE/bin" "$CASE/home" "$CASE/repo" "$CASE/out"
sh "$ROOT/tests/helpers/extract-functions.sh" "$GUARD" "$CASE/fn" \
  json_value json_value_cached json_value_to json_value_prime \
  json_input_is_primed_object rundir_temp_file private_writes_begin \
  private_writes_end scan_file_bytes || exit 1
for f in "$CASE/fn"/*.sh; do
  # shellcheck disable=SC1090
  . "$f"
done
# The cache keys are the JV_* expression constants beside the functions.
sed -n '/^JV_INPUT_TYPE=/,/^JV_NEW_STRING=/p' "$GUARD" >"$CASE/fn/constants.sh"
[ "$(grep -c '^JV_' "$CASE/fn/constants.sh")" -eq 7 ] || exit 1
# shellcheck disable=SC1091
. "$CASE/fn/constants.sh"

# --- json_value answers primed fields exactly as jq -r does ------------------
EXPRS='.tool_input | type
.tool_name // .tool // .name // empty
.tool_input.workdir // .tool_input.cwd // .cwd // empty
.tool_input.command // .tool_input.cmd // empty
.tool_input.file_path // .tool_input.path // empty
.tool_input.content // empty
.tool_input.new_string // empty
.tool_input.pattern // empty'
jq -nc '
  {tool_name:"Bash",tool_input:{command:"ls"}},
  {tool_name:"Bash",tool_input:{command:"printf %s \u0027it\u0027\u0027s\u0027 \"$HOME\" `id`\n\n"},cwd:"/tmp/a b"},
  {tool_name:"Bash",tool_input:{cmd:"echo trailing\n\n\n",workdir:"rel/dir\n"}},
  {tool_name:"Bash",tool_input:{command:["bash","-lc","cat .env"]}},
  {tool_name:"Bash",tool_input:{command:"a\u0000b"}},
  {tool_name:"Bash",tool_input:{command:""}},
  {tool_name:"Bash",tool_input:{command:null,cmd:"fallback"}},
  {tool_name:"Bash",tool_input:{command:false}},
  {tool_name:42,tool_input:{command:7}},
  {tool_name:{nested:"x"},tool_input:{}},
  {tool:"Read",tool_input:{path:"~/.ssh/id_rsa"}},
  {name:"Write",tool_input:{file_path:"√ünïcødé.txt",content:"line1\nline2\n",new_string:"-n"}},
  {tool_name:"Bash",tool_input:"{\"command\":\"ls\"}"},
  {tool_name:"Bash",tool_input:["ls"]},
  {tool_name:"Bash",tool_input:null},
  {tool_name:"Bash"},
  {tool_name:"Edit",tool_input:{file_path:"a",new_string:"-e \\\\n \u0027"}}
' >"$CASE/inputs" || exit 1
{
  cat "$CASE/inputs"
  printf '%s\n' '{"tool_name":"Bash","tool_input":{"command":"one"}} {"tool_name":"Read","tool_input":{"command":"two"}}'
  printf '%s\n' '["not","an","object"]'
  printf '%s\n' '{"tool_name": "Bash", "tool_input": {"command": "spaced \"json\""}}'
} >"$CASE/all-inputs"

jv_mismatch=0
jv_hits=0
while IFS= read -r doc; do
  JV_CACHE_INPUT=
  # Unprimed: every expression runs jq.
  printf '%s\n' "$EXPRS" | while IFS= read -r expr; do
    json_value "$expr" "$doc" | od -An -c
    echo "status=$?"
  done >"$CASE/unprimed" 2>&1
  json_value_prime "$doc"
  printf '%s\n' "$EXPRS" | while IFS= read -r expr; do
    json_value "$expr" "$doc" | od -An -c
    echo "status=$?"
  done >"$CASE/primed" 2>&1
  cmp -s "$CASE/unprimed" "$CASE/primed" || {
    jv_mismatch=1
    printf '  mismatch for %s\n' "$doc"
  }
  # Command-substitution values too (trailing newlines, NUL handling).
  printf '%s\n' "$EXPRS" | while IFS= read -r expr; do
    v=$(json_value "$expr" "$doc"); printf '[%s]\n' "$v"
  done >"$CASE/primed-sub" 2>&1
  # json_value_to holds what the substitution holds, with the same status.
  printf '%s\n' "$EXPRS" | while IFS= read -r expr; do
    json_value_to "$expr" "$doc"; printf '%s[%s]\n' "$?" "$jv_out"
  done >"$CASE/primed-to" 2>&1
  printf '%s\n' "$EXPRS" | while IFS= read -r expr; do
    v=$(json_value "$expr" "$doc"); printf '%s[%s]\n' "$?" "$v"
  done >"$CASE/primed-sub-status" 2>&1
  cmp -s "$CASE/primed-sub-status" "$CASE/primed-to" || {
    jv_mismatch=1
    printf '  json_value_to mismatch for %s\n' "$doc"
  }
  saved=$JV_CACHE_INPUT
  JV_CACHE_INPUT=
  printf '%s\n' "$EXPRS" | while IFS= read -r expr; do
    v=$(json_value "$expr" "$doc"); printf '[%s]\n' "$v"
  done >"$CASE/unprimed-sub" 2>&1
  JV_CACHE_INPUT=$saved
  cmp -s "$CASE/unprimed-sub" "$CASE/primed-sub" || {
    jv_mismatch=1
    printf '  substitution mismatch for %s\n' "$doc"
  }
  [ -z "$JV_CACHE_INPUT" ] || jv_hits=$((jv_hits + 1))
done <"$CASE/all-inputs"
check "primed json_value prints the same bytes and status as jq -r" [ "$jv_mismatch" -eq 0 ]

# Unprimed, json_value_to must hold what `$(json_value ...)` holds, with the
# same status, and neither reader may pass the input to json_value_cached: that
# argument copies the whole input, and an input over 256 Ki characters (a large
# PostToolUse tool output) is never primed (94S-1831).
jv_unprimed_mismatch=0
while IFS= read -r doc; do
  JV_CACHE_INPUT=
  printf '%s\n' "$EXPRS" | while IFS= read -r expr; do
    json_value_to "$expr" "$doc"; printf '%s[%s]\n' "$?" "$jv_out"
  done >"$CASE/unprimed-to" 2>&1
  printf '%s\n' "$EXPRS" | while IFS= read -r expr; do
    v=$(json_value "$expr" "$doc"); printf '%s[%s]\n' "$?" "$v"
  done >"$CASE/unprimed-jq-status" 2>&1
  cmp -s "$CASE/unprimed-jq-status" "$CASE/unprimed-to" || {
    jv_unprimed_mismatch=1
    printf '  unprimed json_value_to mismatch for %s\n' "$doc"
  }
done <"$CASE/all-inputs"
check "unprimed json_value_to holds the same value and status as a json_value substitution" \
  [ "$jv_unprimed_mismatch" -eq 0 ]
(
  json_value_cached() { printf 'called\n' >>"$CASE/jv-cached-calls"; return 1; }
  : >"$CASE/jv-cached-calls"
  JV_CACHE_INPUT=
  doc='{"tool_name":"mcp__x__read","tool_response":"public status"}'
  json_value_to '.tool_name // .tool // .name // empty' "$doc"
  [ "$jv_out" = mcp__x__read ] || exit 1
  [ "$(json_value '.tool_name // "tool"' "$doc")" = mcp__x__read ] || exit 1
  [ ! -s "$CASE/jv-cached-calls" ] || exit 1
  # Once primed, the lookup runs again.
  JV_CACHE_INPUT=$doc
  json_value_to '.tool_name // .tool // .name // empty' "$doc"
  [ -s "$CASE/jv-cached-calls" ]
)
check "an unprimed input is never handed to json_value_cached" [ "$?" -eq 0 ]
check "single-object inputs are primed" [ "$jv_hits" -ge 15 ]

json_value_prime '{"a":1} {"b":2}'
check "a stream of two documents is not treated as one object" \
  sh -c '[ -z "$1" ]' _ "$JV_CACHE_INPUT"
json_value_prime '[1]'
if json_input_is_primed_object '[1]'; then bad "an array is not a primed object"; else ok "an array is not a primed object"; fi
json_value_prime '{"tool_name":"Bash"'
if json_input_is_primed_object '{"tool_name":"Bash"'; then bad "invalid JSON is not a primed object"; else ok "invalid JSON is not a primed object"; fi
# Large inputs and large fields stay on the per-field jq path (a big Write body
# would cost more to quote into the shell than the jq runs it saves).
big=$(awk 'BEGIN { s = "a"; while (length(s) < 70000) s = s s; print s }')
doc="{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/x\",\"content\":\"$big\"}}"
json_value_prime "$doc"
# (Compared in this shell: a single argv string is capped near 128 KiB.)
if [ -n "$JV_CACHE_INPUT" ] && [ -z "${jv_content_set:-}" ] && [ "${jv_tool:-}" = Write ]; then
  ok "a field longer than 64 Ki characters is not cached"
else
  bad "a field longer than 64 Ki characters is not cached"
fi
if [ "$(json_value '.tool_input.content // empty' "$doc")" = "$big" ]; then
  ok "an uncached large field still prints what jq prints"
else
  bad "an uncached large field still prints what jq prints"
fi
huge=$(printf '%s' "$big" | awk '{ s = $0; while (length(s) < 270000) s = s s; print s }')
json_value_prime "{\"tool_name\":\"Write\",\"tool_input\":{\"content\":\"$huge\"}}"
if [ -z "$JV_CACHE_INPUT" ]; then
  ok "an input longer than 256 Ki characters is not primed"
else
  bad "an input longer than 256 Ki characters is not primed"
fi
# The hooks measure their input first and call json_value_prime "$input"
# measured within the limit, '' over it. Both must leave exactly the cache
# state json_value_prime "$input" leaves.
jv_state() { set | grep -E '^(JV_CACHE_|jv_)' | cksum; }
prime_states_match() {
  json_value_prime '{"tool_name":"Edit","tool_input":{"content":"x"}}'
  json_value_prime "$input"; direct=$(jv_state)
  json_value_prime '{"tool_name":"Edit","tool_input":{"content":"x"}}'
  if [ "${#input}" -le 262144 ]; then json_value_prime "$input" measured; else json_value_prime ''; fi
  [ "$direct" = "$(jv_state)" ]
}
edge_body=$(printf '%s' "$huge" | cut -c1-262100)
edge_head='{"tool_name":"Write","tool_input":{"content":"'
edge_tail='"}}'
for edge_len in 262143 262144 262145; do
  pad=$((edge_len - ${#edge_head} - ${#edge_tail}))
  input="$edge_head$(printf '%s' "$edge_body" | cut -c1-"$pad")$edge_tail"
  check "measured priming matches json_value_prime at ${#input} characters" prime_states_match
done
for input in "$doc" '{"a":1} {"b":2}' '[1]' "{\"tool_name\":\"Write\",\"tool_input\":{\"content\":\"$huge\"}}"; do
  check "measured priming matches json_value_prime on a ${#input}-character input" prime_states_match
done
measured_sites=$(grep -c "if \[ \"\${#input}\" -le 262144 \]; then json_value_prime \"\$input\" measured; else json_value_prime ''; fi" "$GUARD")
if [ "$measured_sites" -eq 2 ] && ! grep -q 'json_value_prime "\$input"$' "$GUARD"; then
  ok "both hooks prime through the measured form"
else
  bad "both hooks prime through the measured form"
fi
doc='{"tool_name":"Bash","tool_input":{"command":"ls"}}'
json_value_prime "$doc"
check "a primed object is recognized only for the same text" json_input_is_primed_object "$doc"
if json_input_is_primed_object "$doc "; then bad "different input text is not the primed object"; else ok "different input text is not the primed object"; fi
# With jq unreachable, a primed field still answers and an unlisted one fails
# exactly as a missing jq would, proving which path ran.
(
  PATH="$CASE/empty-path"
  [ "$(json_value '.tool_name // .tool // .name // empty' "$doc")" = Bash ] || exit 1
  json_value '.tool_input.pattern // empty' "$doc" >/dev/null 2>&1 && exit 1
  exit 0
)
check "primed fields need no jq process; unlisted expressions still run jq" [ "$?" -eq 0 ]

# --- rundir_temp_file: unique private files without mktemp -------------------
RUNDIR=$(mktemp -d "$CASE/run.XXXXXX") || exit 1
AGENT_GUARD_RUNDIR=$RUNDIR
AG_UMASK=$(umask)
umask 022
AG_UMASK=$(umask)
set +C
seen="$CASE/seen"
: >"$seen"
rt_ok=1
i=0
while [ "$i" -lt 12 ]; do
  i=$((i + 1))
  f=$(rundir_temp_file) || { rt_ok=0; break; }
  case "$f" in "$RUNDIR"/agent-guard.*) ;; *) rt_ok=0 ;; esac
  [ -f "$f" ] && [ ! -L "$f" ] && [ ! -s "$f" ] || rt_ok=0
  # Removing a file must never free its name for a later call.
  [ $((i % 3)) -eq 0 ] && rm -f "$f"
  printf '%s\n' "$f" >>"$seen"
done
check "rundir temp files are regular, empty and inside the rundir" [ "$rt_ok" -eq 1 ]
check "no rundir temp file name is ever handed out twice" \
  [ "$(sort "$seen" | uniq -d | wc -l | tr -d ' ')" -eq 0 ]
mode=$(ls -l "$(rundir_temp_file)" | cut -c1-10)
check "rundir temp files are created mode 600" [ "$mode" = "-rw-------" ]
check "rundir temp file restores the caller's umask" [ "$(umask)" = "$AG_UMASK" ]
case $- in *C*) bad "rundir temp file leaves noclobber off when it was off" ;; *) ok "rundir temp file leaves noclobber off when it was off" ;; esac
set -C
f=$(rundir_temp_file) || f=
case $- in *C*) ok "rundir temp file keeps noclobber on when it was on" ;; *) bad "rundir temp file keeps noclobber on when it was on" ;; esac
set +C
printf 'garbage\n' >|"$RUNDIR/.next"
f2=$(rundir_temp_file) || f2=
check "a corrupt hint still yields a fresh file" sh -c '[ -n "$1" ] && ! grep -Fxq "$1" "$2"' _ "$f2" "$seen"
# A name already present (a planted symlink) is skipped, never followed.
n=1
while [ -e "$RUNDIR/.claim.$n" ]; do n=$((n + 1)); done
ln -s "$CASE/outside" "$RUNDIR/agent-guard.$n"
printf '%s\n' "$n" >|"$RUNDIR/.next"
f3=$(rundir_temp_file) || f3=
check "an existing entry at the next name is skipped, not followed" \
  sh -c '[ -n "$1" ] && [ "$1" != "$2" ] && [ ! -e "$3" ]' _ "$f3" "$RUNDIR/agent-guard.$n" "$CASE/outside"
# A FIFO at the next name (or at its claim marker) must be skipped, not opened:
# noclobber opens an existing non-regular file, and a FIFO would block forever.
fifo_ok=1
for fifo_at in agent-guard claim; do
  n=1
  while [ -e "$RUNDIR/.claim.$n" ] || [ -e "$RUNDIR/agent-guard.$n" ] \
      || [ -L "$RUNDIR/agent-guard.$n" ]; do n=$((n + 1)); done
  case "$fifo_at" in
    claim) fifo="$RUNDIR/.claim.$n" ;;
    *) fifo="$RUNDIR/agent-guard.$n" ;;
  esac
  mkfifo "$fifo" || { fifo_ok=0; continue; }
  printf '%s\n' "$n" >|"$RUNDIR/.next"
  ( rundir_temp_file >"$CASE/fifo-out" 2>/dev/null ) &
  fifo_pid=$!
  waited=0
  while kill -0 "$fifo_pid" 2>/dev/null && [ "$waited" -lt 50 ]; do
    sleep 0.1 2>/dev/null || sleep 1
    waited=$((waited + 1))
  done
  if kill -0 "$fifo_pid" 2>/dev/null; then
    fifo_ok=0
    kill "$fifo_pid" 2>/dev/null
    # Release a writer blocked on the FIFO so the subshell can exit.
    : <"$fifo" &
    wait "$fifo_pid" 2>/dev/null
  else
    wait "$fifo_pid" 2>/dev/null
    got=$(cat "$CASE/fifo-out")
    [ -n "$got" ] && [ -f "$got" ] && [ ! -p "$got" ] && [ "$got" != "$RUNDIR/agent-guard.$n" ] || fifo_ok=0
  fi
  [ -p "$fifo" ] || fifo_ok=0
done
check "a FIFO at the next name or claim is skipped without blocking" [ "$fifo_ok" -eq 1 ]
AG_UMASK=
if rundir_temp_file >/dev/null 2>&1; then bad "without a saved umask the shortcut declines"; else ok "without a saved umask the shortcut declines"; fi
AG_UMASK=$(umask)
AGENT_GUARD_RUNDIR=
if rundir_temp_file >/dev/null 2>&1; then bad "without a rundir the shortcut declines"; else ok "without a rundir the shortcut declines"; fi

# --- scan_file_bytes: wc without tr, failing closed on anything else ---------
printf 'abcdef' >"$CASE/six-bytes"
check "the byte count of a file is exact" \
  sh -c '. "$1"; scan_file_bytes "$2" && [ "$scan_byte_count" = 6 ]' _ \
  "$CASE/fn/scan_file_bytes.sh" "$CASE/six-bytes"
check "BSD wc blank padding is trimmed as tr would" \
  sh -c '. "$1"; wc() { printf "      42\n"; }; scan_file_bytes "$2" && [ "$scan_byte_count" = 42 ]' _ \
  "$CASE/fn/scan_file_bytes.sh" "$CASE/six-bytes"
for wc_out in '' '4 2' '42x' '-1'; do
  check "a wc answer of '$wc_out' fails closed" \
    sh -c '. "$1"; wc() { printf "%s\n" "$2"; }; ! scan_file_bytes "$3"' _ \
    "$CASE/fn/scan_file_bytes.sh" "$wc_out" "$CASE/six-bytes"
done
check "an unreadable file fails closed" \
  sh -c '. "$1"; ! scan_file_bytes "$2"' _ \
  "$CASE/fn/scan_file_bytes.sh" "$CASE/no-such-file"

# --- hooks: the replaced jq runs are gone and every verdict stays ------------
REAL_JQ=$(command -v jq)
cat >"$CASE/bin/jq" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$CASE/jq-calls"
exec "$REAL_JQ" "\$@"
EOF
cat >"$CASE/bin/gitleaks" <<EOF
#!/bin/sh
printf '%s\n' "\${1:-}" >>"$CASE/gitleaks-calls"
exec sh "$ROOT/tests/fixtures/mock-gitleaks" "\$@"
EOF
chmod 755 "$CASE/bin/jq" "$CASE/bin/gitleaks"
export PATH="$CASE/bin:$PATH" HOME="$CASE/home" XDG_STATE_HOME="$CASE/state"
export AGENT_GUARD_GITLEAKS_BIN="$CASE/bin/gitleaks" AGENT_GUARD_RELEASE_CHECK=off
export AGENT_GUARD_GITLEAKS_CONFIG="$ROOT/plugins/agent-guard/config/gitleaks.toml"
export AGENT_GUARD_LOG_MODE=on AGENT_GUARD_HOOK_HOST=claude AGENT_GUARD_PII_HOOK_MODE=off
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
unset AI_AGENT
(
  cd "$CASE/repo" || exit 1
  git init -q && git config user.email t@example.invalid && git config user.name t \
    && printf '%s\n' ok >README.md && git add README.md && git commit -q -m init
) || exit 1

hook() { # $1 subcommand, $2 json -> status; stdout in $CASE/out/stdout
  : >"$CASE/jq-calls"
  : >"$CASE/gitleaks-calls"
  (cd "$CASE/repo" && printf '%s' "$2" | "$GUARD" "$1" >"$CASE/out/stdout" 2>"$CASE/out/stderr")
}
# A primed object answers the object check in both hooks; an input that is
# not one still runs it (see the non-object PostToolUse case below).
no_field_jq() {
  ! grep -Eq '^-r \.tool_input \| type$|^-r \.tool_name // \.tool // \.name // empty$|^-r \.tool_input\.(command|workdir|file_path|content)' "$CASE/jq-calls" \
    && ! grep -Eq '^-e type == "object"$' "$CASE/jq-calls"
}

hook hook-pre-tool '{"session_id":"s","tool_name":"Bash","tool_input":{"command":"ls"}}'
check "safe Bash command is allowed" [ "$?" -eq 0 ]
check "Bash PreToolUse reads its input fields without one jq run each" no_field_jq
check "Bash PreToolUse still scans the command with gitleaks" grep -qx stdin "$CASE/gitleaks-calls"

hook hook-pre-tool '{"session_id":"s","tool_name":"Bash","tool_input":{"command":"cat .env"}}'
check "protected-path Bash command is still denied" [ "$?" -eq 2 ]
hook hook-pre-tool '{"session_id":"s","tool_name":"Read","tool_input":{"file_path":".env.local"}}'
check "protected Read is still denied" [ "$?" -eq 2 ]
check "Read PreToolUse reads its input fields without one jq run each" no_field_jq
hook hook-pre-tool '{"session_id":"s","tool_name":"Write","tool_input":{"file_path":"a.txt","content":"AGENT_GUARD_TEST_SECRET"}}'
check "secret Write is still blocked" [ "$?" -eq 2 ]
hook hook-pre-tool '{"session_id":"s","tool_name":"Bash","tool_input":"{\"command\":\"cat .env\"}"}'
check "string-encoded protected Bash command is still denied" [ "$?" -eq 2 ]
hook hook-pre-tool '{"session_id":"s","tool_name":"Bash","tool_input":{"command":["cat",".env"]}}'
check "array command keeps the jq path and its verdict" [ "$?" -eq 2 ]
hook hook-pre-tool '[{"tool_name":"Bash"}]'
check "non-object hook input is still rejected" [ "$?" -eq 2 ]

hook hook-post-tool '{"session_id":"s","tool_name":"Bash","tool_input":{"command":"ls"},"tool_response":{"stdout":"README.md\n","stderr":"","interrupted":false}}'
check "clean Bash PostToolUse passes" [ "$?" -eq 0 ]
check "Bash PostToolUse reads its input fields without one jq run each" no_field_jq
check "a clean work tree adds no working-tree scanner run" \
  [ "$(grep -cx stdin "$CASE/gitleaks-calls")" -eq 1 ]

hook hook-post-tool '{"session_id":"s","tool_name":"Bash","tool_input":{"command":"echo"},"tool_response":{"stdout":"token AGENT_GUARD_TEST_SECRET here\n","stderr":"","interrupted":false}}'
check "a secret in tool output is masked with success, not an error" [ "$?" -eq 0 ]
check "the masked output no longer carries the secret" \
  sh -c 'grep -q updatedToolOutput "$1" && ! grep -q AGENT_GUARD_TEST_SECRET "$1"' _ "$CASE/out/stdout"

printf '%s\n' AGENT_GUARD_TEST_SECRET >"$CASE/repo/leaked.txt"
hook hook-post-tool '{"session_id":"s","tool_name":"Write","tool_input":{"file_path":"leaked.txt"}}'
check "a secret written to the work tree is still blocked" [ "$?" -eq 2 ]
rm -f "$CASE/repo/leaked.txt"
printf '%s\n' AGENT_GUARD_TEST_SECRET >>"$CASE/repo/README.md"
hook hook-post-tool '{"session_id":"s","tool_name":"Edit","tool_input":{"file_path":"README.md"}}'
check "a secret added to a tracked file is still blocked" [ "$?" -eq 2 ]
(cd "$CASE/repo" && git add README.md && git show HEAD:README.md >README.md)
hook hook-post-tool '{"session_id":"s","tool_name":"Edit","tool_input":{"file_path":"README.md"}}'
check "a secret staged and reverted on disk is still blocked" [ "$?" -eq 2 ]

# An assignment dump over the 256 KiB probe threshold but under the output scan
# cap takes the large-output precheck, which reuses the cap check's byte count.
# It must still mask every leaf whole, and the shell must report no error.
mid_dump=$(jq -nc '[range(0; 7000) | "PASSWORD=value-detection-\(.)-abcdefgh"] as $o
  | {session_id:"s",tool_name:"Read",tool_input:{file_path:"dump.json"},tool_response:$o}')
hook hook-post-tool "$mid_dump"
check "a ${#mid_dump}-byte assignment dump is masked with success" [ "$?" -eq 0 ]
check "the large-output precheck masks every leaf of the dump whole" \
  jq -e '.hookSpecificOutput.updatedToolOutput | length == 7000 and all(. == "[REDACTED]")' "$CASE/out/stdout"
check "the large-output precheck reports no shell error" \
  sh -c '! grep -Eq "^[^ ]*: [0-9]+: " "$1"' _ "$CASE/out/stderr"

# #477: the jq/sed rewrite path is gated by a cheap name check. The letters
# "sed" inside an ordinary word must not open it: a clean command such as
# `printf 'build passed'` has to cost the same awk runs as `printf 'build ok'`.
REAL_AWK=$(command -v awk)
cat >"$CASE/bin/awk" <<EOF
#!/bin/sh
printf '%s\n' x >>"$CASE/awk-calls"
exec "$REAL_AWK" "\$@"
EOF
chmod 755 "$CASE/bin/awk"
awk_runs() { # $1 Bash command -> number of awk processes one PreToolUse starts
  : >"$CASE/awk-calls"
  hook hook-pre-tool "$(jq -nc --arg c "$1" '{session_id:"s",tool_name:"Bash",tool_input:{command:$c}}')" || return 1
  wc -l <"$CASE/awk-calls" | tr -d ' '
}
plain=$(awk_runs "printf 'build ok'")
check "a clean Bash command is allowed with awk counted" [ -n "$plain" ]
for word in passed used closed released; do
  got=$(awk_runs "printf 'build $word'")
  check "the letters sed inside '$word' start no extra awk (plain $plain, got ${got:-none})" \
    [ "${got:-x}" = "$plain" ]
done
got=$(awk_runs "sed -n 1p README.md")
check "a real sed command still reaches the rewrite path (plain $plain, got ${got:-none})" \
  [ "${got:-0}" -gt "$plain" ]

# 94S-1712: the literal-substitution check runs only for a backquote or `$(`
# next to a single quote or a here-document. Another quoted word and a `$`
# without `(` cost what they cost before; a backquote in a single-quoted word
# or a here-document body opens it.
quoted=$(awk_runs "echo 'see x here'")
got=$(awk_runs "echo 'see x here' 'and y'")
check "a second single-quoted word starts no extra awk (one $quoted, got ${got:-none})" \
  [ "${got:-x}" = "${quoted:-y}" ]
dollar=$(awk_runs "echo 'see \$HOME here'")
got=$(awk_runs "echo 'see \$USER here'")
check "a dollar sign without a parenthesis keeps the check closed (${dollar:-none}, got ${got:-none})" \
  [ "${got:-x}" = "${dollar:-y}" ]
hd_nl='
'
bq=$(printf '\140')
hd=$(awk_runs "cat <<'EOF'${hd_nl}build ok${hd_nl}EOF")
got=$(awk_runs "cat <<'EOF'${hd_nl}build ${bq}ok${bq}${hd_nl}EOF")
check "only a here-document with a backquote reaches the check (${hd:-none}, got ${got:-none})" \
  [ "${got:-0}" -gt "${hd:-99}" ]
got=$(awk_runs "echo 'see ${bq}x${bq} here'")
check "a backquote in a single-quoted word reaches the check (${quoted:-none}, got ${got:-none})" \
  [ "${got:-0}" -gt "$quoted" ]

# #477: with logging off there is no state directory, and the protected-path
# scan used to run one grep per deny-list entry in each of its four passes
# (242 greps for `printf 'build passed'`). The combined regex now lives in the
# run directory for one invocation, so a clean quoted command needs a handful.
# The limits leave room for one or two more checks, not for the old loop.
REAL_GREP=$(command -v grep)
cat >"$CASE/bin/grep" <<EOF
#!/bin/sh
printf '%s\n' x >>"$CASE/grep-calls"
exec "$REAL_GREP" "\$@"
EOF
chmod 755 "$CASE/bin/grep"
grep_runs() { # $1 log mode, $2 host -> grep processes of one clean PreToolUse
  : >"$CASE/grep-calls"
  AGENT_GUARD_LOG_MODE=$1 AGENT_GUARD_HOOK_HOST=$2 \
    hook hook-pre-tool '{"session_id":"s","tool_name":"Bash","tool_input":{"command":"printf '\''build passed'\''"}}' \
    || return 1
  "$REAL_GREP" -c '' "$CASE/grep-calls"
}
for host in claude codex; do
  got=$(grep_runs off "$host")
  check "$host: a clean quoted Bash command with logging off starts at most 12 greps (got ${got:-none})" \
    [ "${got:-99}" -le 12 ]
  grep_runs on "$host" >/dev/null
  got=$(grep_runs on "$host")
  check "$host: the same command with logging on and a warm cache starts at most 8 greps (got ${got:-none})" \
    [ "${got:-99}" -le 8 ]
  AGENT_GUARD_LOG_MODE=off AGENT_GUARD_HOOK_HOST=$host \
    hook hook-pre-tool '{"session_id":"s","tool_name":"Bash","tool_input":{"command":"cat '\''.e'\''nv"}}'
  check "$host: a quote-split protected path is still denied with logging off" [ "$?" -eq 2 ]
done

# Without `*`, `?`, `[` or a backslash in the command, the shell-expanded passes
# read the literal regexes: the shell-expanded combined file, the costliest
# one to build and for grep to compile, is neither built nor read. A glob
# still reads it, and so does a protected path spelled with one.
cat >"$CASE/bin/grep" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$CASE/grep-calls"
exec "$REAL_GREP" "\$@"
EOF
sx_reads() { # $1 log mode, $2 Bash command -> greps of the shell-expanded file
  : >"$CASE/grep-calls"
  AGENT_GUARD_LOG_MODE=$1 \
    hook hook-pre-tool "$(jq -nc --arg c "$2" '{session_id:"s",tool_name:"Bash",tool_input:{command:$c}}')"
  printf '%s:' "$?"
  "$REAL_GREP" -c 'deny-path-regex-shell-expanded' "$CASE/grep-calls"
}
for log in off on; do
  for c in 'ls -la src' "printf 'build passed'" 'git status' "jq '.data.key' data.json"; do
    got=$(sx_reads "$log" "$c")
    check "logging $log: '$c' reads no shell-expanded regex file (got $got)" [ "$got" = 0:0 ]
  done
  got=$(sx_reads "$log" 'ls *.txt')
  case "$got" in 0:[1-9]*) got_ok=1 ;; *) got_ok=0 ;; esac
  check "logging $log: a glob still reads the shell-expanded regex file (got $got)" \
    [ "$got_ok" -eq 1 ]
  got=$(sx_reads "$log" 'cat .e?v')
  check "logging $log: a protected path spelled with a glob is still denied (got $got)" \
    [ "${got%%:*}" = 2 ]
done
rm -f "$CASE/bin/grep"

# With logging off the combined protected-path regex is built in every Bash
# PreToolUse, and each entry's regex used to be compiled in two command
# substitutions (about 240 shells for `printf 'build passed'`, of some 350).
# Each word and each command name also cost a shell or three. Shells are
# counted as the distinct process ids in a bash trace of one hook run; the
# trace goes through a FIFO because the scanner probe limits file sizes.
XTRACE_BASH=
for b in "$(command -v bash 2>/dev/null)" /opt/homebrew/bin/bash /usr/local/bin/bash; do
  [ -n "$b" ] && [ -x "$b" ] || continue
  # BASH_XTRACEFD needs bash 4.1.
  "$b" -c '[ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 1 ]; }' \
    2>/dev/null && { XTRACE_BASH=$b; break; }
done
printf '%s\n' 'PS4='\''+$BASHPID '\''; set -x' >"$CASE/xtrace.env"
printf '0\n' >"$CASE/xtrace.session"
shell_count() { # $1 log mode, $2 Bash command -> shells forked by one PreToolUse
  rm -f "$CASE/xtrace.fifo" "$CASE/xtrace"
  mkfifo "$CASE/xtrace.fifo" || return 1
  cat "$CASE/xtrace.fifo" >"$CASE/xtrace" &
  sc_reader=$!
  # A fresh session each time: a degraded notice is shown once per session.
  sc_session=$(($(cat "$CASE/xtrace.session") + 1))
  printf '%s\n' "$sc_session" >"$CASE/xtrace.session"
  jq -nc --arg c "$2" --arg s "shells-$sc_session" '{session_id:$s,tool_name:"Bash",tool_input:{command:$c}}' \
    | (cd "$CASE/repo" && AGENT_GUARD_LOG_MODE=$1 BASH_ENV="$CASE/xtrace.env" BASH_XTRACEFD=7 \
        sh -c 'exec 7>"$1"; shift; exec "$@"' _ "$CASE/xtrace.fifo" \
        "$XTRACE_BASH" "$GUARD" hook-pre-tool >"$CASE/out/stdout" 2>"$CASE/out/stderr")
  sc_status=$?
  wait "$sc_reader"
  # A degraded scanner adds a notice and skips work, which proves nothing.
  [ "$sc_status" -eq 0 ] && [ ! -s "$CASE/out/stdout" ] && [ ! -s "$CASE/out/stderr" ] || return 1
  sed -n 's/^+* *\([0-9][0-9]*\) .*/\1/p' "$CASE/xtrace" | sort -u | wc -l | tr -d ' '
}
if [ -z "$XTRACE_BASH" ]; then
  ok 'Bash PreToolUse shell counts # SKIP no bash 4.1 or later'
else
  for c in 'ls -la src' "printf 'build passed'" 'ls -la src | head -5' 'git status'; do
    got=$(shell_count off "$c")
    check "with logging off, '$c' forks at most 125 shells (got ${got:-none})" \
      [ "${got:-999}" -le 125 ]
  done
  shell_count on 'ls -la src' >/dev/null
  at_most() { [ -n "$1" ] && [ -n "$2" ] && [ "$1" -le "$2" ]; }
  # #510: the explicit cache opt-in with logging off prepares the state
  # directory with the checks logging on makes, and writes no event file, so
  # a warm run forks no more shells than logging on.
  logged=$(shell_count on 'ls -la src')
  (export AGENT_GUARD_SCAN_CACHE=on; shell_count off 'ls -la src') >/dev/null
  got=$(export AGENT_GUARD_SCAN_CACHE=on; shell_count off 'ls -la src')
  check "logging off with AGENT_GUARD_SCAN_CACHE=on and a warm cache forks no more shells than logging on (on ${logged:-none}, got ${got:-none})" \
    at_most "$got" "$logged"
  for log in off on; do
    one=$(shell_count "$log" 'ls a')
    got=$(shell_count "$log" 'ls a b c d e f g h')
    check "logging $log: seven more words fork no more shells (one ${one:-none}, got ${got:-none})" \
      at_most "$got" "$one"
    got=$(shell_count "$log" 'ls a | head | tail')
    check "logging $log: two more piped commands fork at most one more shell (one ${one:-none}, got ${got:-none})" \
      at_most "$got" "$((${one:-0} + 1))"
  done
fi

# --- fewer jq runs per PostToolUse, fewer awk runs per Bash PreToolUse -------
# A clean Bash PostToolUse used to start 11 jq runs, and Bash PreToolUse 13
# awk runs for 'ls -la src' (16 for the cd, pipe and list below). Each shortcut answers what the run it replaces
# answered: the object check the primed input already made, a NUL walk that
# cannot change a response with no NUL, the re-validation of a bundle that is
# exactly the empty one, two line-to-JSON runs over consecutive input, an awk
# filter folded into the awk after the sort, and the tokenizers asked again for
# the same text by sibling subshells. The cases below pin the counts and that
# every mask and denial they touch still happens.
cat >"$CASE/bin/jq" <<EOF
#!/bin/sh
printf 'run\n' >>"$CASE/jq-runs"
printf '%s\n' "\$*" >>"$CASE/jq-calls"
exec "$REAL_JQ" "\$@"
EOF
chmod 755 "$CASE/bin/jq"
# An earlier case leaves a staged secret behind; Bash runs the work-tree backstop.
(cd "$CASE/repo" && git reset -q --hard && git clean -qfd) || exit 1
# A prefix assignment before a function call outlives it in some shells.
export AGENT_GUARD_HOOK_HOST=claude AGENT_GUARD_LOG_MODE=on
post_jq_runs() { # $1 json -> status of one PostToolUse; jq runs counted
  : >"$CASE/jq-runs"
  hook hook-post-tool "$1"
}
lacks() { ! grep -Fq -- "$1" "$2"; }
count_lines() { grep -c -- "$1" "$2"; }
nul_walk='walk(if type == "string" and (index('
post_jq_runs '{"session_id":"s","tool_name":"Bash","tool_input":{"command":"make"},"tool_response":{"stdout":"build ok\n","stderr":"","interrupted":false}}'
check "clean Bash PostToolUse with jq counted passes unchanged" \
  sh -c '[ "$1" -eq 0 ] && [ ! -s "$2" ]' _ "$?" "$CASE/out/stdout"
got=$(wc -l <"$CASE/jq-runs" | tr -d ' ')
check "a clean Bash PostToolUse starts at most 7 jq runs (got $got)" [ "$got" -le 7 ]
check "a clean Bash PostToolUse makes no second object check" \
  sh -c '! grep -Eq "^-e type == \"object\"\$" "$1"' _ "$CASE/jq-calls"
check "a response with no NUL starts no NUL walk" lacks "$nul_walk" "$CASE/jq-calls"
check "the empty secret bundle is not parsed again" \
  lacks 'invalid secret bundle' "$CASE/jq-calls"
check "compact-token lines are encoded in one jq run" \
  [ "$(count_lines '^-Rc select(length > 0)$' "$CASE/jq-calls")" -eq 1 ]

post_jq_runs '{"session_id":"s","tool_name":"Bash","tool_input":{"command":"x"},"tool_response":{"stdout":"a\u0000b","stderr":"","interrupted":false}}'
check "a NUL-bearing Bash output is masked with success" [ "$?" -eq 0 ]
check "the NUL-bearing leaf is replaced whole" \
  jq -e '.hookSpecificOutput.updatedToolOutput == {stdout: "[REDACTED]", stderr: "", interrupted: false}' "$CASE/out/stdout"
check "a NUL-bearing response still runs the NUL walk" grep -Fq "$nul_walk" "$CASE/jq-calls"

# Both compact-token detectors in one output: one jq run encodes both lines.
seg() { od -An -N12 -tx1 /dev/urandom | tr -d ' \n'; }
jwt_shape="eyJ$(seg).eyJ$(seg).$(seg)"
auth_word=Bear; auth_word="${auth_word}er"
auth_value="$(seg)$(seg)"
post_jq_runs "$(jq -nc --arg o "id $jwt_shape and $auth_word $auth_value end" \
  '{session_id:"s",tool_name:"Bash",tool_input:{command:"x"},tool_response:{stdout:$o,stderr:"",interrupted:false}}')"
check "output with a JWT and an authorization value is masked with success" [ "$?" -eq 0 ]
check "both compact-token values are masked" \
  sh -c 'grep -q updatedToolOutput "$1" && ! grep -Fq "$2" "$1" && ! grep -Fq "$3" "$1"' _ \
  "$CASE/out/stdout" "$jwt_shape" "$auth_value"
check "the two token detectors share one jq run" \
  [ "$(count_lines '^-Rc select(length > 0)$' "$CASE/jq-calls")" -eq 1 ]

# Not an object: the object check still runs and still rejects it.
post_jq_runs '[{"tool_name":"Bash"}]'
check "non-object PostToolUse input keeps the jq object check" \
  grep -Eq '^-e type == "object"$' "$CASE/jq-calls"

got=$(awk_runs 'ls -la src')
check "Bash PreToolUse for 'ls -la src' starts at most 9 awk runs (got ${got:-none})" \
  [ "${got:-99}" -le 9 ]
got=$(awk_runs 'cd src && grep -n TODO a.txt | head -5; echo done')
check "Bash PreToolUse for a cd, pipe and list starts at most 12 awk runs (got ${got:-none})" \
  [ "${got:-99}" -le 12 ]
hook hook-pre-tool '{"session_id":"s","tool_name":"Bash","tool_input":{"command":"cd src && cat ../.env | head -5; echo done"}}'
check "the same shape naming a protected path is still denied" [ "$?" -eq 2 ]

# The memoized tokenizers hold what the command substitution holds, with the
# same status, on a miss, on a hit, and after another text took the memo.
sh "$ROOT/tests/helpers/extract-functions.sh" "$GUARD" "$CASE/fn" \
  git_command_records git_command_records_to shell_command_words \
  shell_command_words_to || exit 1
memo_ok=$(
  for f in git_command_records git_command_records_to shell_command_words shell_command_words_to; do
    # shellcheck disable=SC1090
    . "$CASE/fn/$f.sh"
  done
  fs=$(printf '\034')
  nl='
'
  set -- 'ls -la src' 'cd src && grep -n TODO a.txt | head -5; echo done' \
    "git commit -m \"\$(cat <<'EOF'${nl}msg${nl}EOF${nl})\"" "printf 'a${nl}b'${nl}${nl}" \
    'echo "unclosed' "x${fs}y" '' "cd ~\"/sub\" && FOO\\=1 git push" \
    "cat <<EOF${nl}\$(id)${nl}EOF"
  for t in "$@"; do
    for g in '' gate; do
      ref=$(git_command_records "$t" "$g"); rs=$?
      git_command_records_to "$t" "$g"; s1=$? o1=$GCR_OUT
      git_command_records_to "$t" "$g"; s2=$? o2=$GCR_OUT
      git_command_records_to "other $t" "$g"; git_command_records_to "$t" "$g"; s3=$? o3=$GCR_OUT
      [ "$rs:$ref" = "$s1:$o1" ] && [ "$rs:$ref" = "$s2:$o2" ] && [ "$rs:$ref" = "$s3:$o3" ] \
        || printf 'gcr mismatch [%s] gate=%s\n' "$t" "$g"
    done
    ref=$(shell_command_words "$t"); rs=$?
    shell_command_words_to "$t"; s1=$? o1=$SCW_OUT
    shell_command_words_to "$t"; s2=$? o2=$SCW_OUT
    shell_command_words_to "other $t"; shell_command_words_to "$t"; s3=$? o3=$SCW_OUT
    [ "$rs:$ref" = "$s1:$o1" ] && [ "$rs:$ref" = "$s2:$o2" ] && [ "$rs:$ref" = "$s3:$o3" ] \
      || printf 'scw mismatch [%s]\n' "$t"
  done
  # A hit starts no awk; a subshell reads what its parent memoized.
  git_command_records_to 'ls -la src'
  shell_command_words_to 'ls -la src'
  (
    awk() { printf 'awk ran\n'; return 1; }
    git_command_records_to 'ls -la src' && [ "$GCR_OUT" = "$(printf '0ls\n0-la\n0src')" ] \
      || printf 'gcr hit failed\n'
    shell_command_words_to 'ls -la src' && [ "$SCW_OUT" = "$(printf 'ls\n-la\nsrc')" ] \
      || printf 'scw hit failed\n'
  )
  printf 'done\n'
)
check "memoized tokenizers match the command substitution they replace" [ "$memo_ok" = done ]

printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
