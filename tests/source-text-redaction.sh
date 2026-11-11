#!/bin/sh
# PostToolUse redaction must hide credential values, not the source code and
# test fixtures that merely name a credential field. A type annotation
# (`privateKey: string;`), an object member that reads a value
# (`privateKey: config.privateKey,`) hold no credential. Without this the host
# gets a rewritten result for ordinary source, and Codex, which cannot swap a
# result in place, turns it into a blocked tool call.
#
# Controls: a random credential under the same keys, placeholder-looking values
# (the policy pins them as masked) and a vendor-shaped token must still be
# hidden, so the gate stays a value test and not a key-name allowlist.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
BIN=${AGENT_GUARD_TEST_BINARY:-$ROOT/plugins/agent-guard/bin/agent-guard}
CASE=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-source-redact.XXXXXX") || exit 1
trap 'rm -rf "$CASE"' 0 HUP INT TERM
export AGENT_GUARD_LOG_MODE=off AGENT_GUARD_RELEASE_CHECK=off
export AGENT_GUARD_GITLEAKS_BIN="$ROOT/tests/fixtures/mock-gitleaks"

rand() { od -An -N"$1" -tx1 /dev/urandom | tr -d ' \n'; }
# A digit first keeps the random part out of every word-shaped placeholder.
secret=9$(rand 10)
suffixed=test-repo-9$(rand 6)

pass=0 fail=0 n=0
ok() { pass=$((pass + 1)); printf 'ok - %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'not ok - %s\n' "$1"; }

run_hook() { # $1 host, $2 stdout text
  jq -nc --arg o "$2" \
    '{tool_name:"Bash",tool_input:{command:"rg x"},tool_response:{stdout:$o,stderr:"",interrupted:false}}' \
    | AGENT_GUARD_HOOK_HOST=$1 "$BIN" hook-post-tool >"$CASE/out" 2>"$CASE/err"
}

keeps() { # $1 text: the output stays as it was
  n=$((n + 1))
  for host in claude codex; do
    run_hook "$host" "$1"
    if [ $? -eq 0 ] && [ ! -s "$CASE/out" ]; then
      ok "source text $n kept on $host"
    else
      bad "source text $n rewritten on $host: $1"
      sed 's/^/  out: /' "$CASE/out"
    fi
  done
}

hides() { # $1 text, $2 literal that must not survive
  n=$((n + 1))
  for host in claude codex; do
    run_hook "$host" "$1"
    if [ $? -eq 0 ] && [ -s "$CASE/out" ] && ! grep -qF -- "$2" "$CASE/out"; then
      ok "credential $n hidden on $host"
    else
      bad "credential $n shown or not rewritten on $host: $1"
      sed 's/^/  out: /' "$CASE/out"
    fi
  done
}

# Types, not values.
keeps '  privateKey: string;'
keeps '  password: string | null;'
keeps '  readonly apiKey: Buffer;'
keeps '  secret_id?: string;'
keeps 'function login(password: string, token: string) {'
keeps 'def connect(self, password: str, token: str) -> None:'
keeps '  token: number,'

# Object members that read a value.
keeps '  privateKey: config.privateKey,'
keeps '  privateKey: this.options.privateKey,'
keeps '  privateKey: process.env.GITHUB_APP_PRIVATE_KEY,'
keeps '  repositoryPassword: input.repositoryPassword,'
keeps '  secret_id: cfg.secretId,'

# Placeholder-looking values are deliberately still masked: the post-tool policy
# pins that decorated placeholders and fake-*-body strings are not exempt.
#
# The values are assembled at run time: a literal quoted credential or bearer
# header in the file is what static secret scanners flag.
q='"'
ph=test-repo-$(printf pass)word
fk=fake-$(printf k)ey
bt=test-token-$(printf 12)34
hides "  password: $q$ph$q" "$ph"
hides "  api_key: $fk" "$fk"
hides "  headers: { authorization: ${q}Bearer $bt$q }," "$bt"

# The same keys with a credential in the value.
hides "  privateKey: $secret" "$secret"
hides "  password: \"$secret\"" "$secret"
hides "  repositoryPassword: $secret," "$secret"
hides "  secret_id: \"$secret\"" "$secret"
hides "  headers: { authorization: \"Bearer $secret\" }," "$secret"
hides "  api_key: $suffixed" "$suffixed"
hides "  password: \"$suffixed\"" "$suffixed"
hides "  password: test-repo-password-$secret" "$secret"
hides "  token: foo.bar.$secret," "$secret"
hides "  privateKey: my.Secret.phrase," "my.Secret.phrase"

# A two-word value with a capital (`correct.Horse`) is a passphrase shape, not a
# member read, so it stays masked; a camelCase leaf is the member read.
hides '  token: abc.Def,' abc.Def
hides '  secret: correct.Horse,' correct.Horse
hides '  password: hunter.Two,' hunter.Two
keeps '  secret_id: cfg.secretId,'

# Letters and dots with a camelCase end are also what a passphrase of words
# looks like, so the member-read exemption needs a head that source code reads
# members from (config, opts, this, process, ...). Any other head stays masked.
hides '  password: winter.coldPassword,' winter.coldPassword
hides '  secret: winter.cold.coldPassword,' winter.cold.coldPassword
hides '  token: purple.rainbowToken,' purple.rainbowToken
hides '  password: {winter.coldPassword}, user: x' winter.coldPassword
keeps '  secret: config.secretValue,'
keeps '  token: this.state.authToken,'

# A type word alone at the end of a line is a YAML scalar, not an annotation:
# the annotation forms above all have code after the word.
kw=pass$(printf word)
hides "$kw: boolean" boolean
hides "db_$kw: symbol" symbol
hides "  $kw: object" object
keeps "  $kw: boolean;"
keeps "function login($kw: any) {"

# An underscore or dollar sign in a member name is accepted only in the shape of
# an environment variable; a mixed-case segment with one stays masked.
for v in 'config.my_Secret' 'opts.my$Pass' 'this.a_b_C' 'config.$_Q'; do
  hides "  $kw: $v," "$v"
done
keeps "  $kw: process.env.GITHUB_APP_PRIVATE_KEY,"

# Issue #426: `rg -n` and `cat` of compose files, Helm values, TypeScript config
# and fixture JSON that only NAME a credential. A logical or nullish operator
# after a member read, an environment-variable leaf, a `process.env.` read at
# the end of a line, a code keyword before a call, a quoted value that is only
# an expansion or template, an existingSecret object name and status words.
keeps '  token: process.env.EGRESS_PROXY_TOKEN ?? "",'
keeps '  token: opts.token ?? defaultToken,'
keeps '  token: options.token || process.env.WERFT_TOKEN,'
keeps '  token: config.token && config.token.trim(),'
keeps '  egressToken: env.EGRESS_TOKEN,'
keeps '  apiKey: env.API_KEY,'
keeps '  token: env.WERFT_TOKEN ?? "",'
keeps '  token: process.env.EGRESS_PROXY_TOKEN'
keeps '    const token = await createBootstrapToken(db);'
keeps '  const token = await getToken();'
keeps '  let secret = typeof opts.secret === "string" ? opts.secret : undefined;'
keeps '{"name": "client", "env": {"WERFT_TOKEN": "${WERFT_TOKEN}"}}'
keeps '  token: "${WERFT_TOKEN}"'
keeps '  "token": "$WERFT_TOKEN",'
keeps '  export WERFT_TOKEN="$(werft token create)"'
keeps '  BOOTSTRAP_TOKEN: "${{ secrets.BOOTSTRAP_TOKEN }}"'
keeps '  "apiKey": "{{ .Values.apiKey }}",'
keeps '  password: "{{ .Values.postgres.password | quote }}"'
keeps '    existingSecret: werft-egress'
keeps '    existingSecretKey: egress-token'
keeps '  "expectedEnv": {"BOOTSTRAP_TOKEN": "required"},'
keeps 'infra/compose.core.yml:13:      EGRESS_PROXY_TOKEN: ${EGRESS_PROXY_TOKEN:-}'
keeps 'apps/control-host/src/api/api-settings.ts:10:  bootstrapToken: string;'
keeps 'apps/control-host/src/api/api-settings.ts:16:  // Bootstrap token is generated on first start'

# Controls for #426: the same shapes with a credential in them still mask.
# The operator form needs a root head and an identifier chain, the env leaf
# needs capitals and underscores only, the keyword needs a call after it, a
# quoted expansion must be the whole value, and existingSecret takes only a
# lowercase name that is not credential shaped.
hides "  token: config.a$secret ?? x," "$secret"
hides "  token: winter.coldPassword ?? x," winter.coldPassword
hides "  $kw: hunter$secret ?? x" "hunter$secret"
hides "  token: env.A$secret," "$secret"
hides "  token: process.env.API_KEY_$secret" "$secret"
hides "  token: await$secret" "$secret"
hides "  token: \"\${WERFT_TOKEN}$secret\"" "$secret"
hides "  token: \"\$token$secret\"" "$secret"
hides "  token: \"\${{ secrets.X }}$secret\"" "$secret"
hides "  token: \"{{ \\\"$secret\\\" }}\"" "$secret"
hides "    existingSecret: $secret" "$secret"
hides "    existingSecretKey: \"Abc$secret\"" "Abc$secret"
hides "  $kw: required$secret" "required$secret"
hides "TOKEN=ghp_$secret$secret" "$secret"

# A quoted command substitution is a reference only when no word inside can
# be a literal: echo and printf print their argument, a long or mixed word is
# a value, and an existingSecret suffix that is not a reference name holds one.
hides "DB_$kw=\"\$(echo Q7v$secret)\"" "Q7v$secret"
hides "export API_TOKEN=\"\$(printf %s Sup3r$secret | base64)\"" "Sup3r$secret"
hides "  $kw: \"\$(echo -n hunter2$secret)\"" "hunter2$secret"
hides "  token: \"\$(/usr/bin/echo verysecret)\"" verysecret
hides "  token: \"\$(werft login verysecretpassphrase)\"" verysecretpassphrase
hides "    existingSecretPassword: verysecretpassphrase" verysecretpassphrase
hides "    existingSecretToken: verysecretpassphrase" verysecretpassphrase
# A bare argument outside the closed subcommand list, or any word after an
# option that names a credential, is the value itself.
hides "  TOKEN=\"\$(werft token hunterpass)\"" hunterpass
hides "  token: \"\$(werft token abcdefghij)\"" abcdefghij
hides "  token: \"\$(cmd --$kw hunterpw)\"" hunterpw
hides "  token: \"\$(cmd -p hunter)\"" hunter
hides "  token: \"\$(cmd --api-key hunterkey)\"" hunterkey
keeps '  TOKEN="$(cat /run/secrets/werft_token)"'
keeps '  TOKEN="$(cat /run/secrets/egress_token)"'
keeps '  TOKEN="$(vault read -field token /secret/werft)"'
keeps '    existingSecretName: werft-egress'

printf '# pass=%s fail=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
