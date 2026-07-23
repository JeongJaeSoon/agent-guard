#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
PLUGIN="$ROOT/plugins/agent-guard"
ENTRY="$ROOT/docs/submission/claude-plugins-official/marketplace-entry.template.json"
REPORT="$ROOT/docs/claude-marketplace-readiness.md"

failures=0

ok() {
  printf 'ok: %s\n' "$1"
}

fail() {
  printf 'not ok: %s\n' "$1" >&2
  failures=$((failures + 1))
}

warn() {
  printf 'warn: %s\n' "$1"
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
require_file "$REPORT"
require_file "$ROOT/docs/submission/claude-plugins-official/curator-change-description.md"
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
  and .homepage == "https://github.com/JeongJaeSoon/agent-guard"
' "$ENTRY" >/dev/null; then
  ok "official marketplace entry template uses the pinned git-subdir form and discloses material behavior"
else
  fail "official marketplace entry template uses the pinned git-subdir form and discloses material behavior"
fi

entry_sha=$(jq -r '.source.sha // ""' "$ENTRY")
expected_sha=${AGENT_GUARD_SUBMISSION_SHA:-}
if [ -n "$expected_sha" ]; then
  if printf '%s\n' "$expected_sha" | grep -Eq '^[0-9a-f]{40}$'; then
    ok "AGENT_GUARD_SUBMISSION_SHA is a full commit SHA"
  else
    fail "AGENT_GUARD_SUBMISSION_SHA is a full commit SHA"
  fi
  if [ "$entry_sha" = "$expected_sha" ]; then
    ok "entry template is finalized at AGENT_GUARD_SUBMISSION_SHA"
  else
    fail "entry template is finalized at AGENT_GUARD_SUBMISSION_SHA"
  fi
else
  case "$entry_sha" in
    '<40-character-commit-sha-after-push>')
      ok "entry template keeps an explicit post-push SHA placeholder"
      ;;
    *)
      if printf '%s\n' "$entry_sha" | grep -Eq '^[0-9a-f]{40}$'; then
        ok "entry template contains a full commit SHA"
      else
        fail "entry template contains a full commit SHA or the documented placeholder"
      fi
      ;;
  esac
fi

# A 40-hex .source.sha is only a safety net if it still resolves to the payload
# reviewers will actually install. Verifying the format is not enough: if the
# pinned commit's plugins/agent-guard tree has drifted from the current payload,
# the submission green-lights a stale snapshot. When the pinned commit is
# present locally, require its subtree to equal HEAD's; when it is absent
# (shallow / submission checkouts), warn and skip rather than fail-closed, since
# we cannot compare a tree we do not have. The placeholder is handled above.
if printf '%s\n' "$entry_sha" | grep -Eq '^[0-9a-f]{40}$'; then
  if git -C "$ROOT" rev-parse "$entry_sha^{commit}" >/dev/null 2>&1; then
    if git -C "$ROOT" diff --quiet "$entry_sha" HEAD -- plugins/agent-guard; then
      ok "pinned .source.sha's plugins/agent-guard tree matches the current payload"
    else
      fail "pinned .source.sha's plugins/agent-guard tree differs from current payload; re-pin the SHA"
    fi
  else
    # "Could not verify" is not a pass. A shallow checkout (actions/checkout
    # defaults to fetch-depth 1) cannot resolve a pin that is more than a commit
    # or two back, which is the ordinary case — so warning and skipping here
    # would print "validation passed" for a run that never checked anything,
    # exactly the stale-pin scenario this guard exists to catch.
    fail "cannot verify the pinned .source.sha tree: commit $entry_sha is not present locally; use a full-history checkout (actions/checkout with fetch-depth: 0)"
  fi
fi

contains "$REPORT" 'No public application or direct PR path' 'readiness report records the official submission blocker'
contains "$REPORT" 'ungated `PreToolUse` or `PostToolUse`' 'readiness report records the broad-hook blocker'
contains "$REPORT" 'f9cb226d81172f53a1787cc3ba90dc9ab51aa169' 'readiness report pins the reviewed official snapshot'

if [ "$failures" -eq 0 ]; then
  printf 'submission readiness validation passed\n'
else
  printf 'submission readiness validation failed: %s issue(s)\n' "$failures" >&2
  exit 1
fi
