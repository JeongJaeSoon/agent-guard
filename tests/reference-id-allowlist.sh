#!/usr/bin/env sh
set -u

# A UUID under a reference-id field (`secretId`, `tokenRef`, `credential_ref`)
# names a stored credential; generic-api-key reads the keyword in the field
# name as a credential label. Only that shape is exempt, and UUID-shaped real
# credentials (Vault AppRole and Consul `secret_id`/`SecretID`, vendor keys)
# keep their findings. Also pins that obvious low-entropy docs placeholders
# pass while a random 64-hex example token stays blocked.
# Kept out of tests/run.sh: the monolith is already near ShellCheck's memory
# limit in CI, so each added line there risks the Lint job.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
GUARD="$ROOT/plugins/agent-guard/bin/agent-guard"
CASE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-reference-id.XXXXXX")
CASE_ROOT=$(CDPATH= cd -- "$CASE_ROOT" && pwd -P)
ORIGINAL_PATH=$PATH
# A host that passes the variable empty means "no real gitleaks": PATH then holds
# only run.sh's mock, which would turn every must-fail case into a false failure.
GITLEAKS=${AGENT_GUARD_TEST_REAL_GITLEAKS-$(command -v gitleaks 2>/dev/null || true)}
pass=0
fail=0

cleanup() {
  rm -rf "$CASE_ROOT"
}
trap cleanup EXIT INT TERM
# Scanned directory holds only the fixture; stdout/stderr captures stay outside.
mkdir -p "$CASE_ROOT/scan" "$CASE_ROOT/work"

if [ -z "$GITLEAKS" ]; then
  printf 'skip - real gitleaks is not installed\n'
  exit 0
fi

export AGENT_GUARD_LOG_MODE=off
export AGENT_GUARD_RELEASE_CHECK=off
export AGENT_GUARD_GITLEAKS_CONFIG=${REFERENCE_ID_TEST_CONFIG:-$ROOT/plugins/agent-guard/config/gitleaks.toml}
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
unset AI_AGENT
SCAN_PATH="$(dirname "$GITLEAKS"):$ORIGINAL_PATH"

ok() {
  pass=$((pass + 1))
  printf 'ok - %s\n' "$1"
}

not_ok() {
  fail=$((fail + 1))
  printf 'not ok - %s\n' "$1"
  [ ! -s "$CASE_ROOT/err" ] || sed 's/^/  stderr: /' "$CASE_ROOT/err"
}

# $1 expected status, $2 label, $3 file content
scan_case() {
  printf '%s\n' "$3" >"$CASE_ROOT/scan/fixture.ts"
  PATH="$SCAN_PATH" "$GUARD" scan-path "$CASE_ROOT/scan" \
    >"$CASE_ROOT/out" 2>"$CASE_ROOT/err"
  scan_status=$?
  if [ "$scan_status" -eq "$1" ]; then
    ok "scan-path: $2"
  else
    not_ok "scan-path: $2 (expected $1, got $scan_status)"
  fi
}

# $1 expected rule id, $2 label, $3 text. Names the detector, not only the verdict.
rule_case() {
  rm -f "$CASE_ROOT/report.json"
  printf '%s\n' "$3" | "$GITLEAKS" stdin --no-banner --no-color --log-level error \
    --config "$AGENT_GUARD_GITLEAKS_CONFIG" --exit-code 1 \
    --report-format json --report-path "$CASE_ROOT/report.json" \
    >"$CASE_ROOT/out" 2>"$CASE_ROOT/err"
  rule_status=$?
  rule_ids=$(jq -r '[.[].RuleID] | unique | join(",")' "$CASE_ROOT/report.json" 2>/dev/null)
  if [ "$rule_status" -eq 1 ] && [ "$rule_ids" = "$1" ]; then
    ok "rule $1: $2"
  else
    not_ok "rule $1: $2 (status $rule_status, rules '${rule_ids}')"
  fi
}

# $1 expected hook status, $2 label, $3 file name, $4 Edit new_string.
# A block must carry the Edit content scan message.
edit_case() {
  edit_session=$(printf 'reference-id-%s' "$((pass + fail))")
  jq -nc --arg p "$CASE_ROOT/work/$3" --arg n "$4" --arg d "$CASE_ROOT/work" \
    --arg s "$edit_session" \
    '{tool_name:"Edit",tool_input:{file_path:$p,old_string:"placeholder",new_string:$n},cwd:$d,session_id:$s}' |
    PATH="$SCAN_PATH" AGENT_GUARD_HOOK_HOST=claude "$GUARD" hook-pre-tool \
      >"$CASE_ROOT/out" 2>"$CASE_ROOT/err"
  edit_status=$?
  if [ "$edit_status" -ne "$1" ]; then
    not_ok "Edit hook: $2 (expected $1, got $edit_status)"
  elif [ "$1" -eq 2 ] &&
    ! grep -q 'secret-like value detected in proposed Edit content' "$CASE_ROOT/err"; then
    not_ok "Edit hook: $2 (blocked without the Edit content scan message)"
  else
    ok "Edit hook: $2"
  fi
}

# Fixed, not random: a low-entropy id falls under the rule's floor and would
# turn every must-fail case below into a silent pass. Secret-shaped words are
# built at run time so this file holds no literal finding.
REF_ID=$(printf '%s-%s-%s-%s-%s' 7b42a1e9 63dc 4f08 a295 1c8e6d03b574)
REF_UPPER=$(printf '%s' "$REF_ID" | tr 'a-f' 'A-F')
REF_HEX=$(printf '%s%s' c3e85f1a90d24b6e 8f17a4d2093be6c5)
REF_HEX64=$(printf '%s%s%s' "$REF_HEX" 7b42a1e963dc4f08 a2951c8e6d03b574)
REF_ZEROS=$(printf '%064d' 0)
REF_XS=$(printf '%064d' 0 | tr 0 x)
REF_INV=$(printf '%s%s' inv _)
REF_SEC=$(printf '%s%s' sec ret)
REF_TOK=$(printf '%s%s' to ken)
REF_AK=$(printf '%s%s' api Key)
REF_PW=$(printf '%s%s' pass word)
REF_HK=$(printf '%s%s' hero ku)
REF_SNYK=$(printf '%s%s' sn yk)

# The two Edits that were blocked: werft OIDC test fixtures put a random UUID
# into a field naming a secret-store entry.
edit_case 0 "a UUID under a secretId fixture field is allowed" \
  flow-cookie.test.ts "      ${REF_SEC}Id: \"$REF_ID\","
edit_case 0 "a UUID under a secretId field inside an object literal is allowed" \
  provider-login.test.ts "  const row = { ${REF_SEC}Id: '$REF_ID', provider: 'oidc' };"

# OpenAPI request examples: an obvious placeholder passes, a random 64-hex
# token cannot be told from a real one and stays blocked.
edit_case 0 "an example token of 64 zeros is allowed" \
  openapi.ts "    requestExample: { ${REF_TOK}: \"$REF_INV$REF_ZEROS\" },"
edit_case 0 "an example token of 64 x characters is allowed" \
  openapi.ts "    requestExample: { ${REF_TOK}: \"$REF_INV$REF_XS\" },"
edit_case 0 "an EXAMPLE placeholder token is allowed" \
  openapi.ts "    requestExample: { ${REF_TOK}: \"${REF_INV}EXAMPLE\" },"
edit_case 0 "a REDACTED placeholder token is allowed" \
  openapi.ts "    requestExample: { ${REF_TOK}: \"${REF_INV}REDACTED\" },"
edit_case 2 "a random 64-hex example token is blocked" \
  openapi.ts "    requestExample: { ${REF_TOK}: \"$REF_INV$REF_HEX64\" },"
rule_case generic-api-key "a random 64-hex example token" \
  "    requestExample: { ${REF_TOK}: \"$REF_INV$REF_HEX64\" },"

# Reference-id shapes that are exempt.
scan_case 0 "a UUID assigned to a dotted secretId property is clean" \
  "this.${REF_SEC}Id = \"$REF_ID\";"
scan_case 0 "a UUID under a tokenId field is clean" \
  "  ${REF_TOK}Id: \"$REF_ID\","
scan_case 0 "a backtick-quoted UUID under a secretRef field is clean" \
  "  ${REF_SEC}Ref: \`$REF_ID\`,"
scan_case 0 "a UUID under a snake credential_ref field with => is clean" \
  "  credential_ref => '$REF_ID',"
scan_case 0 "an unquoted UUID under a snake token_id YAML key is clean" \
  "${REF_TOK}_id: $REF_ID"
scan_case 0 "a UUID under a snake token_id JSON key is clean" \
  "{\"${REF_TOK}_id\":\"$REF_ID\"}"
scan_case 0 "an unquoted UUID under secretId before a shell separator is clean" \
  "${REF_SEC}Id=$REF_ID; echo done"
scan_case 0 "a UUID under a secretRef field with := is clean" \
  "vault.${REF_SEC}Ref := \"$REF_ID\""
scan_case 0 "two reference ids on one line are clean" \
  "  { ${REF_SEC}Id: '$REF_ID', ${REF_TOK}Ref: '$REF_ID' }"
# The snake `_id` branch spells "a segment that does not end in secret" one
# position at a time; each suffix of the word and each one-letter change of it
# stays exempt. The `api_` prefix keeps every name a generic-api-key finding.
for ref_seg in s et ret cret ecret xecret sxcret sexret secxet secrxt secrex; do
  scan_case 0 "a UUID under api_${ref_seg}_id is clean" \
    "api_${ref_seg}_id = \"$REF_ID\""
done

# UUID-shaped real credentials keep their findings.
scan_case 1 "a UUID under a secret field is still found" \
  "  ${REF_SEC}: \"$REF_ID\","
scan_case 1 "a UUID under an apiKey field is still found" \
  "  ${REF_AK}: \"$REF_ID\","
scan_case 1 "a UUID assigned to a token name is still found" \
  "${REF_TOK} = \"$REF_ID\""
scan_case 1 "a UUID under a password field is still found" \
  "  ${REF_PW}: \"$REF_ID\","
scan_case 1 "a Vault AppRole secret_id is still found" \
  "${REF_SEC}_id = \"$REF_ID\""
scan_case 1 "a Vault AppRole secret_id in a JSON login body is still found" \
  "{\"role_id\":\"web\",\"${REF_SEC}_id\":\"$REF_ID\"}"
scan_case 1 "a UUID under a client_secret_id field is still found" \
  "  client_${REF_SEC}_id: \"$REF_ID\","
scan_case 1 "a UUID under a snake name ending in secret before _id is still found" \
  "  app${REF_SEC}_id: \"$REF_ID\","
scan_case 1 "a UUID under a dotted client.secret_id is still found" \
  "client.${REF_SEC}_id = \"$REF_ID\""
scan_case 1 "a UUID under a hyphenated client-secret_id is still found" \
  "client-${REF_SEC}_id = \"$REF_ID\""
scan_case 1 "a Consul SecretID is still found" \
  "  SecretID: \"$REF_ID\","
scan_case 1 "an upper-case SECRET_ID assignment is still found" \
  "VAULT_SECRET_ID=$REF_ID"
scan_case 1 "a kebab-case secret-id property is still found" \
  "spring.cloud.vault.app-role.${REF_SEC}-id=$REF_ID"
scan_case 1 "an uppercase UUID under a secretId field is still found" \
  "  ${REF_SEC}Id: \"$REF_UPPER\","
scan_case 1 "a UUID with trailing characters under a secretId field is still found" \
  "  ${REF_SEC}Id: \"$REF_ID$REF_HEX\","
# `mob-`, not `sdk-`: the upstream rule's stopwords already pass `sdk-<uuid>`.
scan_case 1 "a prefixed UUID under a key reference field is still found" \
  "  mobileKeyRef: \"mob-$REF_ID\","
scan_case 1 "a secret after a reference id on one line is still found" \
  "  { ${REF_SEC}Id: '$REF_ID', ${REF_TOK}: '$REF_ID' }"
scan_case 1 "a UUID under a reference id after a credential word is still found" \
  "${REF_TOK} ${REF_SEC}Id: $REF_ID"
scan_case 1 "a UUID under a name that only contains Id is still found" \
  "  ${REF_SEC}IdToken: \"$REF_ID\","
scan_case 1 "an unquoted UUID joined to a double-quoted tail is still found" \
  "${REF_SEC}Id=$REF_ID\"Z\""
scan_case 1 "an unquoted UUID joined to a single-quoted tail is still found" \
  "${REF_SEC}Id=$REF_ID'Z'"
# A backslash and n or r is not a separator: the shell keeps it in the word.
scan_case 1 "an unquoted UUID followed by an escaped n is still found" \
  "${REF_SEC}Id=$REF_ID\\nZ"
scan_case 1 "an unquoted UUID followed by an escaped r is still found" \
  "${REF_SEC}Id=$REF_ID\\rZ"

# Vendor rules for UUID-shaped keys are not targeted by the exemption.
rule_case heroku-api-key "a UUID under a heroku key id field" \
  "  ${REF_HK}KeyId: \"$REF_ID\","
rule_case snyk-api-token "a UUID under a snyk token id field" \
  "${REF_SNYK}_${REF_TOK}_id = \"$REF_ID\""

printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
