#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
PLUGIN="$ROOT/plugins/agent-guard"
ENTRY="$ROOT/docs/submission/marketplace-entry.template.json"

failures=0

ok() {
  printf 'ok: %s\n' "$1"
}

fail() {
  printf 'not ok: %s\n' "$1" >&2
  failures=$((failures + 1))
}

require_file() {
  if [ -f "$1" ]; then
    ok "$1 exists"
  else
    fail "$1 exists"
  fi
}

require_json() {
  require_file "$1"
  if [ -f "$1" ] && jq -e . "$1" >/dev/null; then
    ok "$1 is valid JSON"
  else
    fail "$1 is valid JSON"
  fi
}

contains() {
  file=$1
  pattern=$2
  label=$3
  if grep -Fq "$pattern" "$file"; then
    ok "$label"
  else
    fail "$label"
  fi
}

for file in README.md LICENSE PRIVACY.md SECURITY.md SUPPORT.md THIRD_PARTY_NOTICES.md; do
  require_file "$ROOT/$file"
  require_file "$PLUGIN/$file"
done

require_json "$PLUGIN/.claude-plugin/plugin.json"
require_json "$PLUGIN/hooks/hooks.json"
require_json "$ENTRY"
require_file "$ROOT/docs/submission/claude-community/form-draft.md"

for file in LICENSE PRIVACY.md SUPPORT.md THIRD_PARTY_NOTICES.md; do
  if cmp -s "$ROOT/$file" "$PLUGIN/$file"; then
    ok "plugin payload $file matches repository policy"
  else
    fail "plugin payload $file matches repository policy"
  fi
done

manifest="$PLUGIN/.claude-plugin/plugin.json"
if jq -e '
  .name == "agent-guard"
  and .license == "MIT"
  and .homepage == "https://github.com/JeongJaeSoon/agent-guard"
  and .repository == "https://github.com/JeongJaeSoon/agent-guard"
  and .author.url == "https://github.com/JeongJaeSoon"
  and (.description | test("no-telemetry"))
  and (.description | test("hooks inspect"))
  and (.description | test("every enabled"))
  and (.description | test("PII"))
' "$manifest" >/dev/null; then
  ok "Claude manifest discloses identity, maintainer, license, broad hooks, telemetry, and PII"
else
  fail "Claude manifest discloses identity, maintainer, license, broad hooks, telemetry, and PII"
fi

events=$(jq -r '.hooks | keys[]' "$PLUGIN/hooks/hooks.json")
for event in $events; do
  contains "$PLUGIN/PRIVACY.md" "\`$event\`" "privacy policy enumerates $event"
done

contains "$PLUGIN/PRIVACY.md" 'no outbound' 'privacy policy discloses default network behavior'
contains "$PLUGIN/PRIVACY.md" 'retain it after the hook or command finishes' 'privacy policy discloses retention'
contains "$PLUGIN/PRIVACY.md" 'AGENT_GUARD_PII_REDACT_URL' 'privacy policy discloses the optional PII endpoint'
contains "$PLUGIN/PRIVACY.md" 'defaults to `off`' 'privacy policy discloses PII hook default'
contains "$PLUGIN/SECURITY.md" '/security/advisories/new' 'plugin payload provides private security reporting'
contains "$PLUGIN/SUPPORT.md" 'GitHub Issues' 'plugin payload provides a public support channel'
contains "$PLUGIN/SUPPORT.md" 'Windows is not currently supported' 'plugin payload discloses platform limits'
contains "$PLUGIN/README.md" 'enabled session' 'plugin README discloses broad hook scope'
contains "$PLUGIN/README.md" 'never run' 'plugin README discloses lifecycle download behavior'

if jq -e '
  .name == "agent-guard"
  and .category == "security"
  and (.description | test("no-telemetry"))
  and (.description | test("every enabled"))
  and (.description | test("PII"))
  and .source.source == "git-subdir"
  and .source.url == "https://github.com/JeongJaeSoon/agent-guard.git"
  and .source.path == "plugins/agent-guard"
  and .source.ref == "main"
  and .source.sha == "<40-character-commit-sha-after-merge>"
  and .homepage == "https://github.com/JeongJaeSoon/agent-guard"
' "$ENTRY" >/dev/null; then
  ok "optional marketplace entry template uses stable git-subdir metadata and a post-merge SHA placeholder"
else
  fail "optional marketplace entry template uses stable git-subdir metadata and a post-merge SHA placeholder"
fi

if [ "$failures" -eq 0 ]; then
  printf 'submission readiness validation passed\n'
else
  printf 'submission readiness validation failed: %s issue(s)\n' "$failures" >&2
  exit 1
fi
