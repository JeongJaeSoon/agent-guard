#!/bin/sh
# #537: how the CLI hands gitleaks runs to the opt-in scan client, checked
# with a recording stand-in client so no Go toolchain is needed. The real
# client and helper are covered by tests/gitleaks-helper.sh.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
GUARD="$ROOT/plugins/agent-guard/bin/agent-guard"
CFG="$ROOT/plugins/agent-guard/config/gitleaks.toml"
CASE=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-helper-routing.XXXXXX") || exit 1
CASE=$(CDPATH= cd -- "$CASE" && pwd -P)
trap 'rm -rf "$CASE"' 0 HUP INT TERM
pass=0 fail=0
ok() { pass=$((pass + 1)); printf 'ok - %s\n' "$*"; }
bad() { fail=$((fail + 1)); printf 'not ok - %s\n' "$*"; }
expect() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

mkdir -p "$CASE/bin" "$CASE/lib" "$CASE/empty" "$CASE/home" "$CASE/xs" "$CASE/work"
cp "$ROOT/tests/fixtures/mock-gitleaks" "$CASE/bin/gitleaks"
chmod +x "$CASE/bin/gitleaks"
GL="$CASE/bin/gitleaks"
CALLS="$CASE/calls"
# The stand-in records its arguments, one call per line, then behaves as the
# real client does on a fallback: it execs the given gitleaks with the rest.
cat >"$CASE/lib/agent-guard-scan" <<'EOF'
#!/bin/sh
printf '%s|' "$@" >>"$AG_ROUTING_CALLS"
printf '\n' >>"$AG_ROUTING_CALLS"
[ -z "${AG_ROUTING_FAIL:-}" ] || exit 2
gitleaks=$2
while [ "$#" -gt 0 ] && [ "$1" != -- ]; do shift; done
shift
exec "$gitleaks" "$@"
EOF
chmod +x "$CASE/lib/agent-guard-scan"
CLIENT="$CASE/lib/agent-guard-scan"
export HOME="$CASE/home" XDG_STATE_HOME="$CASE/xs" PATH="$CASE/bin:$PATH" AG_ROUTING_CALLS="$CALLS"
export AGENT_GUARD_GITLEAKS_BIN_DIR="$CASE/empty" AGENT_GUARD_RELEASE_CHECK=off
unset AGENT_GUARD_GITLEAKS_BIN AGENT_GUARD_GITLEAKS_CONFIG AGENT_GUARD_LOG_MODE AGENT_GUARD_GITLEAKS_HELPER \
  AGENT_GUARD_EXPERIMENTAL_OUTPUT_PIPELINE AGENT_GUARD_INFRA_FAILURE_MODE
STATE="$CASE/xs/agent-guard"
secret=AGENT_GUARD_TEST_SECRET
pre() { jq -nc --arg c "$1" '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$c}}'; }
post() { jq -nc --arg o "$1" '{hook_event_name:"PostToolUse",tool_name:"Bash",tool_input:{command:"cat x"},tool_response:{stdout:$o,stderr:"",interrupted:false}}'; }
hook() { # $1 hook, $2 json, then VAR=value settings -> .out .err .status
  ag_hook=$1 ag_json=$2
  shift 2
  (cd "$CASE/work" && printf '%s' "$ag_json" | env "$@" "$GUARD" "$ag_hook" >"$CASE/h.out" 2>"$CASE/h.err")
  echo "$?" >"$CASE/h.status"
}
snapshot() { for f in out err status; do cp "$CASE/h.$f" "$CASE/$1.$f"; done; }
same_as() { cmp -s "$CASE/h.out" "$CASE/$1.out" && cmp -s "$CASE/h.err" "$CASE/$1.err" && cmp -s "$CASE/h.status" "$CASE/$1.status"; }

# Off: no client, the existing verdicts.
: >"$CALLS"
hook hook-pre-tool "$(pre "echo $secret")" AG_X=1; snapshot pre-secret
hook hook-pre-tool "$(pre 'ls -la src')" AG_X=1; snapshot pre-clean
hook hook-post-tool "$(post "token $secret")" AG_X=1; snapshot post-secret
expect "off: the CLI never starts the client" '[ ! -s "$CALLS" ]'
expect "off: a secret command is denied and a clean one allowed" \
  '[ "$(cat "$CASE/pre-secret.status")" = 2 ] && [ "$(cat "$CASE/pre-clean.status")" = 0 ]'

# On: every scan goes through the client, with the probed scanner and version.
rm -rf "$STATE/gitleaks-clean"
: >"$CALLS"
hook hook-pre-tool "$(pre "echo $secret")" AGENT_GUARD_GITLEAKS_HELPER="$CLIENT"
expect "on: a secret command gets the same deny as off" 'same_as pre-secret'
expect "on: the stdin scan passes the probed gitleaks, its version and the private state directory" \
  'grep -qxF -- "--gitleaks|$GL|--gitleaks-version|8.30.1|--state-dir|$STATE|--|stdin|--redact|--no-banner|--no-color|--log-level|error|--config|$CFG|--exit-code|1|" "$CALLS"'
rm -rf "$STATE/gitleaks-clean"
hook hook-pre-tool "$(pre 'ls -la src')" AGENT_GUARD_GITLEAKS_HELPER="$CLIENT"
expect "on: a clean command gets the same allow as off" 'same_as pre-clean'
: >"$CALLS"
hook hook-post-tool "$(post "token $secret")" AGENT_GUARD_GITLEAKS_HELPER="$CLIENT"
expect "on: tool output is masked as off" 'same_as post-secret'
expect "on: the output detector's report scan goes through the client" \
  'grep -q -- "|--|stdin|--report-format|json|--report-path|.*|--no-banner|--config|$CFG|$" "$CALLS"'
: >"$CALLS"
hook hook-post-tool "$(post "token $secret")" AGENT_GUARD_GITLEAKS_HELPER="$CLIENT" AGENT_GUARD_EXPERIMENTAL_OUTPUT_PIPELINE=fused
expect "on: the fused output pipeline's report scan goes through the client" \
  'grep -q -- "|--|stdin|--report-format|json|--report-path|.*|--no-banner|--config|$CFG|$" "$CALLS"'

# AGENT_GUARD_GITLEAKS_CONFIG reaches the client as --config, so the helper
# key and request hash follow the custom file.
cp "$CFG" "$CASE/custom.toml"
: >"$CALLS"
hook hook-pre-tool "$(pre "echo $secret")" AGENT_GUARD_GITLEAKS_HELPER="$CLIENT" AGENT_GUARD_GITLEAKS_CONFIG="$CASE/custom.toml"
expect "AGENT_GUARD_GITLEAKS_CONFIG is passed to the client as the scan config" \
  'grep -qF -- "|--config|$CASE/custom.toml|" "$CALLS" && same_as pre-secret'

# Switches that keep the existing path.
: >"$CALLS"
hook hook-pre-tool "$(pre "echo $secret")" AGENT_GUARD_GITLEAKS_HELPER="$CLIENT" AGENT_GUARD_GITLEAKS_BIN="$GL"
expect "an explicit AGENT_GUARD_GITLEAKS_BIN keeps its scanner without the client" '[ ! -s "$CALLS" ] && same_as pre-secret'
hook hook-pre-tool "$(pre "echo $secret")" AGENT_GUARD_GITLEAKS_HELPER="$CLIENT" AGENT_GUARD_LOG_MODE=off
expect "without the private state directory the client is not used" '[ ! -s "$CALLS" ] && [ "$(cat "$CASE/h.status")" = 2 ]'
for value in lib/agent-guard-scan "$CASE/lib/missing" "$CASE/lib"; do
  hook hook-pre-tool "$(pre "echo $secret")" AGENT_GUARD_GITLEAKS_HELPER="$value"
  expect "a relative, missing or non-file AGENT_GUARD_GITLEAKS_HELPER ($value) is ignored" '[ ! -s "$CALLS" ] && same_as pre-secret'
done
chmod -x "$CLIENT"
hook hook-pre-tool "$(pre "echo $secret")" AGENT_GUARD_GITLEAKS_HELPER="$CLIENT"
expect "a non-executable client is ignored" '[ ! -s "$CALLS" ] && same_as pre-secret'
chmod +x "$CLIENT"

# A client that fails is a scanner failure, never a clean scan.
rm -rf "$STATE/gitleaks-clean"
hook hook-pre-tool "$(pre 'ls -la src')" AGENT_GUARD_GITLEAKS_HELPER="$CLIENT" AG_ROUTING_FAIL=1
expect "a failing client follows the open infrastructure policy (warn, allow)" \
  '[ "$(cat "$CASE/h.status")" = 0 ] && grep -q "gitleaks failed while scanning" "$CASE/h.err"'
rm -rf "$STATE/gitleaks-clean"
hook hook-pre-tool "$(pre 'ls -la src')" AGENT_GUARD_GITLEAKS_HELPER="$CLIENT" AG_ROUTING_FAIL=1 AGENT_GUARD_INFRA_FAILURE_MODE=closed
expect "a failing client follows the closed infrastructure policy (deny)" '[ "$(cat "$CASE/h.status")" = 2 ]'
expect "a failed scan is not stored as a clean verdict" '[ ! -d "$STATE/gitleaks-clean" ] || [ -z "$(ls "$STATE/gitleaks-clean")" ]'

printf '\npassed: %s\nfailed: %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
