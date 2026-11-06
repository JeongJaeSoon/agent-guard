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
hides '  password: "test-repo-password"' test-repo-password
hides '  api_key: fake-key' fake-key
hides '  headers: { authorization: "Bearer test-token-1234" },' test-token-1234

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

printf '# pass=%s fail=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
