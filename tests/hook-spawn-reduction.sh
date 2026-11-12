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
  json_value json_value_prime json_input_is_primed_object \
  rundir_temp_file || exit 1
for f in "$CASE/fn"/*.sh; do
  # shellcheck disable=SC1090
  . "$f"
done

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
# PostToolUse keeps its own jq object check (its failure selects the
# validation-recovery path), so only PreToolUse drops that one too.
no_field_jq() {
  ! grep -Eq '^-r \.tool_input \| type$|^-r \.tool_name // \.tool // \.name // empty$|^-r \.tool_input\.(command|workdir|file_path|content)' "$CASE/jq-calls" \
    && { [ "${1:-}" = post ] || ! grep -Eq '^-e type == "object"$' "$CASE/jq-calls"; }
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
check "Bash PostToolUse reads its input fields without one jq run each" no_field_jq post
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

printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
