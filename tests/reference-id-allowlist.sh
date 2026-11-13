#!/usr/bin/env sh
set -u

# A UUID under a reference-id field (`clientId`, `tokenRef`, `credential_ref`)
# names a stored object; generic-api-key reads the keyword in the field name as
# a credential label. Only that shape is exempt. A name ending in `secret` or
# `secrets` (`secretId`, `secret_ref`) keeps its finding, and so do UUID-shaped
# real credentials (Vault AppRole and Consul `secret_id`/`SecretID`, vendor
# keys). Also pins that obvious low-entropy docs placeholders pass while a
# random 64-hex example token stays blocked.
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

# $1 expected status, $2 label, $3 file content, $4 `raw` to omit the final LF.
# The fixture is named $scan_name (a path allowlist keys on the extension).
scan_name=fixture.ts
scan_case() {
  rm -f "$CASE_ROOT/scan/"*
  if [ "${4:-}" = raw ]; then
    printf '%s' "$3" >"$CASE_ROOT/scan/$scan_name"
  else
    printf '%s\n' "$3" >"$CASE_ROOT/scan/$scan_name"
  fi
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
REF_SEC_UC=$(printf '%s%s' Sec ret)
REF_TOK=$(printf '%s%s' to ken)
REF_AK=$(printf '%s%s' api Key)
REF_PW=$(printf '%s%s' pass word)
REF_HK=$(printf '%s%s' hero ku)
REF_SNYK=$(printf '%s%s' sn yk)

# The two Edits that were blocked: werft OIDC test fixtures put a random UUID
# into a `secretId` field. A name ending in secret stays blocked, because a
# Vault AppRole secret_id is a UUID; werft references an existing constant
# instead.
edit_case 2 "a UUID under a secretId fixture field stays blocked" \
  flow-cookie.test.ts "      ${REF_SEC}Id: \"$REF_ID\","
edit_case 2 "a UUID under a secretId field inside an object literal stays blocked" \
  provider-login.test.ts "  const row = { ${REF_SEC}Id: '$REF_ID', provider: 'oidc' };"
edit_case 2 "a UUID under a secretRef fixture field stays blocked" \
  flow-cookie.test.ts "      ${REF_SEC}Ref: \"$REF_ID\","
# Other reference ids pass. `clientId` and `sessionRef` carry no credential
# keyword; the auth- and token-prefixed names reach the exemption.
edit_case 0 "a UUID under a clientId fixture field is allowed" \
  flow-cookie.test.ts "      clientId: \"$REF_ID\","
edit_case 0 "a UUID under a sessionRef fixture field is allowed" \
  flow-cookie.test.ts "      sessionRef: \"$REF_ID\","
edit_case 0 "a UUID under an oauthClientId fixture field is allowed" \
  flow-cookie.test.ts "      oauthClientId: \"$REF_ID\","
edit_case 0 "a UUID under an authSessionRef fixture field is allowed" \
  provider-login.test.ts "  const row = { authSessionRef: '$REF_ID', provider: 'oidc' };"
edit_case 0 "a UUID under a tokenRef fixture field is allowed" \
  flow-cookie.test.ts "      ${REF_TOK}Ref: \"$REF_ID\","

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
scan_case 0 "a UUID assigned to a dotted tokenId property is clean" \
  "this.${REF_TOK}Id = \"$REF_ID\";"
scan_case 0 "a UUID under a tokenId field is clean" \
  "  ${REF_TOK}Id: \"$REF_ID\","
scan_case 0 "a backtick-quoted UUID under a tokenRef field is clean" \
  "  ${REF_TOK}Ref: \`$REF_ID\`,"
scan_case 0 "a UUID under a credentialRef field is clean" \
  "  credentialRef: \"$REF_ID\","
scan_case 0 "a UUID under an accessTokenRef field is clean" \
  "  access${REF_TOK}Ref: '$REF_ID',"
scan_case 0 "a UUID under a name holding secret before other words is clean" \
  "  ${REF_SEC}sManagerRef: \"$REF_ID\","
scan_case 0 "a UUID under a snake credential_ref field with => is clean" \
  "  credential_ref => '$REF_ID',"
scan_case 0 "an unquoted UUID under a snake token_id YAML key is clean" \
  "${REF_TOK}_id: $REF_ID"
scan_case 0 "a UUID under a snake token_id JSON key is clean" \
  "{\"${REF_TOK}_id\":\"$REF_ID\"}"
scan_case 0 "a UUID under a mixed-case snake authSession_id key is clean" \
  "authSession_id: \"$REF_ID\""
scan_case 0 "an unquoted UUID under tokenId before a shell separator is clean" \
  "${REF_TOK}Id=$REF_ID; echo done"
scan_case 0 "a UUID under a tokenRef field with := is clean" \
  "vault.${REF_TOK}Ref := \"$REF_ID\""
scan_case 0 "two reference ids on one line are clean" \
  "  { ${REF_TOK}Id: '$REF_ID', credentialRef: '$REF_ID' }"
# The name part spells "does not end in secret or secrets" one position at a
# time; each suffix of those words and each one-letter change of them stays
# exempt under every suffix. The `api_` prefix keeps every name a
# generic-api-key finding.
for ref_seg in s et ret cret ecret xecret sxcret sexret secxet secrxt secrex \
  ts ets rets crets ecrets xecrets sxcrets sexrets secxets secrxts secrexs secretx; do
  for ref_suffix in Id Ref _id _ref; do
    scan_case 0 "a UUID under api_${ref_seg}${ref_suffix} is clean" \
      "api_${ref_seg}${ref_suffix} = \"$REF_ID\""
  done
done

# A name ending in secret or secrets, in any case, keeps its finding.
rule_case generic-api-key "a UUID under a secretId field" \
  "  ${REF_SEC}Id: \"$REF_ID\","
for ref_name in "${REF_SEC}Id" "${REF_SEC}Ref" "${REF_SEC}_ref" "${REF_SEC}_id" \
  "${REF_SEC_UC}Id" "${REF_SEC_UC}Ref" "${REF_SEC_UC}_ref" "client${REF_SEC_UC}Ref" \
  "client${REF_SEC_UC}Id" "client_${REF_SEC}_ref" "vault.${REF_SEC}Id" \
  "${REF_SEC}sRef" "${REF_SEC}s_id" "my${REF_SEC_UC}sId" "api_${REF_SEC}Id"; do
  scan_case 1 "a UUID under $ref_name is still found" \
    "  $ref_name: \"$REF_ID\","
done
scan_case 1 "a UUID assigned to a dotted secretId property is still found" \
  "this.${REF_SEC}Id = \"$REF_ID\";"
scan_case 1 "a backtick-quoted UUID under a secretRef field is still found" \
  "  ${REF_SEC}Ref: \`$REF_ID\`,"
scan_case 1 "an unquoted UUID under secretId before a shell separator is still found" \
  "${REF_SEC}Id=$REF_ID; echo done"
scan_case 1 "a UUID under a secretRef field with := is still found" \
  "vault.${REF_SEC}Ref := \"$REF_ID\""
scan_case 1 "a secretId after another reference id on one line is still found" \
  "  { ${REF_TOK}Id: '$REF_ID', ${REF_SEC}Id: '$REF_ID' }"
# The shapes the backstop leaves alone stay found under a secret name.
scan_case 1 "a shell-assigned quoted UUID under secretId with one trailing comma is still found" \
  "${REF_SEC}Id=\"$REF_ID\","
scan_case 1 "a quoted UUID under secret_ref in a multi-line Python keyword argument is still found" \
  "client.create(
    ${REF_SEC}_ref=\"$REF_ID\",
    name=\"web\",
)"

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
scan_case 1 "an uppercase UUID under a tokenId field is still found" \
  "  ${REF_TOK}Id: \"$REF_UPPER\","
scan_case 1 "a UUID with trailing characters under a tokenId field is still found" \
  "  ${REF_TOK}Id: \"$REF_ID$REF_HEX\","
# `mob-`, not `sdk-`: the upstream rule's stopwords already pass `sdk-<uuid>`.
scan_case 1 "a prefixed UUID under a key reference field is still found" \
  "  mobileKeyRef: \"mob-$REF_ID\","
scan_case 1 "a secret after a reference id on one line is still found" \
  "  { ${REF_TOK}Id: '$REF_ID', ${REF_TOK}: '$REF_ID' }"
scan_case 1 "a UUID under a reference id after a credential word is still found" \
  "${REF_TOK} ${REF_TOK}Id: $REF_ID"
scan_case 1 "a UUID under a name that only contains Id is still found" \
  "  ${REF_TOK}IdToken: \"$REF_ID\","
scan_case 1 "an unquoted UUID joined to a double-quoted tail is still found" \
  "${REF_TOK}Id=$REF_ID\"Z\""
scan_case 1 "an unquoted UUID joined to a single-quoted tail is still found" \
  "${REF_TOK}Id=$REF_ID'Z'"
# The allowlist sees only up to the closing quote; a backstop rule finds a
# quoted UUID that the shell joins to more text.
rule_case agent-guard-reference-id-concatenation "a double-quoted UUID joined to more text" \
  "${REF_TOK}Id=\"$REF_ID\"Z"
scan_case 1 "a single-quoted UUID joined to more text is still found" \
  "${REF_TOK}Id='$REF_ID'Z"
scan_case 1 "a quoted UUID joined to another quoted string is still found" \
  "${REF_TOK}Id=\"$REF_ID\"\"Z\""
scan_case 1 "a quoted UUID joined to an escaped n is still found" \
  "${REF_TOK}Id=\"$REF_ID\"\\nZ"
scan_case 1 "a quoted UUID joined to a variable is still found" \
  "${REF_TOK}Id=\"$REF_ID\"\$TAIL"
scan_case 0 "a quoted UUID closing a call argument is clean" \
  "  login({ ${REF_TOK}Id: \"$REF_ID\"})"
scan_case 0 "a quoted UUID before a list bracket is clean" \
  "  ids: [${REF_TOK}Ref: '$REF_ID']"
scan_case 0 "a quoted UUID before a spaced comment is clean" \
  "${REF_TOK}Ref: \"$REF_ID\" # fixture"
scan_case 0 "a quoted UUID at a CRLF line end is clean" \
  "${REF_TOK}Ref: \"$REF_ID\"$(printf '\r')"
# An adjacent # does not start a shell comment, and a lone CR or FF does not
# end the word.
scan_case 1 "a quoted UUID joined to a hash is still found" \
  "${REF_TOK}Id=\"$REF_ID\"#Z"
scan_case 1 "a quoted UUID joined to a lone carriage return is still found" \
  "${REF_TOK}Id=\"$REF_ID\"$(printf '\r')Z"
scan_case 1 "a quoted UUID joined to a form feed is still found" \
  "${REF_TOK}Id=\"$REF_ID\"$(printf '\f')Z"
# After a bare `=` (a shell assignment), `,` `]` `}` joined to more text stay
# in the word; after `:` they close a JS or JSON value.
for ref_tail in ',Z' ']Z' '}Z' ',,' '],x'; do
  scan_case 1 "a shell-assigned quoted UUID joined to $ref_tail is still found" \
    "${REF_TOK}Id=\"$REF_ID\"$ref_tail"
done
scan_case 1 "a shell-assigned quoted UUID joined to a comma and lone CR is still found" \
  "${REF_TOK}Id=\"$REF_ID\",$(printf '\r')Z"
scan_case 0 "a shell-assigned quoted UUID before a comma and space is clean" \
  "f(${REF_TOK}_ref=\"$REF_ID\", x=1)"
scan_case 0 "a quoted UUID in a multi-line Python keyword argument is clean" \
  "client.create(
    ${REF_TOK}_ref=\"$REF_ID\",
    name=\"web\",
)"
scan_case 0 "a quoted UUID after => before a comma is clean" \
  "  ${REF_TOK}_ref => \"$REF_ID\",x"
scan_case 0 "a quoted UUID after := before a comma is clean" \
  "${REF_TOK}Ref := \"$REF_ID\",x"
scan_case 0 "a low-entropy shell-assigned quoted UUID joined to a comma stays clean" \
  "${REF_TOK}Id=\"11111111-1111-4111-8111-111111111111\",Z"
scan_case 1 "a quoted UUID before a carriage return at end of file is still found" \
  "${REF_TOK}Id=\"$REF_ID\"$(printf '\r')" raw
# generic-api-key's own rule allowlists and stopwords drop these on origin/main;
# the backstop copies them, so it adds no finding here.
for ref_name in apiId keyId authorId credential_id aPiRef; do
  scan_case 0 "a quoted UUID joined to more text under $ref_name stays clean" \
    "$ref_name=\"$REF_ID\"Z"
done
scan_case 0 "a quoted UUID holding a stopword joined to more text stays clean" \
  "${REF_TOK}Id=\"000000e9-63dc-4f08-a295-1c8e6d03b574\"Z"
scan_case 0 "a joined quoted UUID on a --mount=type=secret line stays clean" \
  "RUN --mount=type=$REF_SEC,id=x ${REF_TOK}Id=\"$REF_ID\"Z"
scan_case 0 "a joined quoted UUID on an import line stays clean" \
  "import {x} from \"m\"; ${REF_TOK}Id=\"$REF_ID\"Z"
scan_name=recipe.bb
scan_case 0 "a joined quoted UUID on a BitBake LICENSE line stays clean" \
  "LICENSE=\"MIT\"; ${REF_TOK}Id=\"$REF_ID\"Z"
scan_name=fixture.ts
scan_case 1 "the same joined quoted UUID outside a BitBake file is still found" \
  "LICENSE=\"MIT\"; ${REF_TOK}Id=\"$REF_ID\"Z"
# The backstop mirrors generic-api-key's name bound: a name too long for it
# carried no finding before and gets none now.
scan_case 0 "a quoted UUID under a name too long for the keyword bound is clean" \
  "const ${REF_TOK}ExternalResourceRowId = \"$REF_ID\".toString();"
# A backslash and n or r is not a separator: the shell keeps it in the word.
scan_case 1 "an unquoted UUID followed by an escaped n is still found" \
  "${REF_TOK}Id=$REF_ID\\nZ"
scan_case 1 "an unquoted UUID followed by an escaped r is still found" \
  "${REF_TOK}Id=$REF_ID\\rZ"

# Vendor rules for UUID-shaped keys are not targeted by the exemption.
rule_case heroku-api-key "a UUID under a heroku key id field" \
  "  ${REF_HK}KeyId: \"$REF_ID\","
rule_case snyk-api-token "a UUID under a snyk token id field" \
  "${REF_SNYK}_${REF_TOK}_id = \"$REF_ID\""

printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
