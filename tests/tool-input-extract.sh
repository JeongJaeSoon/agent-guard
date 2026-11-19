#!/usr/bin/env sh
set -u

# Every file-writing tool shape must reach both input gates with the text it
# would write: the secret gate and the PII gate block the same planted value
# whichever field the host used, and PostToolUse scans the file the call
# actually wrote, including an apply_patch `Move to:` destination.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
GUARD=${AGENT_GUARD_TEST_BINARY:-$ROOT/plugins/agent-guard/bin/agent-guard}
CASE=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-tool-input.XXXXXX") || exit 1
[ -n "$CASE" ] || exit 1
CASE=$(CDPATH= cd -- "$CASE" && pwd -P) || exit 1
trap 'rm -rf "$CASE"' 0
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir "$CASE/home" "$CASE/repo" "$CASE/repo/vault" || exit 1
cd "$CASE/repo" || exit 1
git init -q || exit 1
printf 'vault/\n' >.gitignore
export HOME="$CASE/home" AGENT_GUARD_LOG_MODE=off AGENT_GUARD_RELEASE_CHECK=off
export AGENT_GUARD_HOOK_HOST=claude AGENT_GUARD_WARNING_DIR="$CASE/warnings"
export AGENT_GUARD_GITLEAKS_BIN="$ROOT/tests/fixtures/mock-gitleaks"
unset AGENT_GUARD_PII_SKIP AGENT_GUARD_PII_PROVIDER AGENT_GUARD_OUTPUT_REDACT AI_AGENT
SECRET=AGENT_GUARD_TEST_SECRET
CARD='4111 1111 1111 1111'
passed=0
failed=0

expect() { # expected-status name event pii-mode json
  printf '%s' "$5" | AGENT_GUARD_PII_HOOK_MODE="$4" "$GUARD" "$3" >"$CASE/out" 2>"$CASE/err"
  status=$?
  if [ "$status" -eq "$1" ]; then passed=$((passed + 1)); else
    failed=$((failed + 1))
    printf 'not ok - %s (expected %s, got %s)\n' "$2" "$1" "$status"
    sed 's/^/  stderr: /' "$CASE/err"
  fi
}

# shape NAME VALUE prints the tool call with VALUE as the written text.
shape() {
  v=$(printf '%s' "$2" | jq -Rs .)
  case $1 in
    write-file_path) printf '{"tool_name":"Write","tool_input":{"file_path":"a.ts","content":%s}}' "$v" ;;
    write-path) printf '{"tool_name":"Write","tool_input":{"path":"a.ts","content":%s}}' "$v" ;;
    edit) printf '{"tool_name":"Edit","tool_input":{"file_path":"a.ts","old_string":"x","new_string":%s}}' "$v" ;;
    multiedit-second) printf '{"tool_name":"MultiEdit","tool_input":{"file_path":"a.ts","edits":[{"new_string":"one"},{"new_string":%s}]}}' "$v" ;;
    notebookedit) printf '{"tool_name":"NotebookEdit","tool_input":{"notebook_path":"n.ipynb","new_source":%s}}' "$v" ;;
    patch-input-add) p=$(printf '*** Begin Patch\n*** Add File: p.ts\n+%s\n*** End Patch\n' "$2" | jq -Rs .)
      printf '{"tool_name":"apply_patch","tool_input":{"input":%s}}' "$p" ;;
    patch-command-move) p=$(printf '*** Begin Patch\n*** Update File: q.ts\n*** Move to: r.ts\n@@\n-old\n+%s\n*** End Patch\n' "$2" | jq -Rs .)
      printf '{"tool_name":"apply_patch","tool_input":{"command":%s}}' "$p" ;;
    patch-unified-diff) p=$(printf 'diff --git a/s.ts b/s.ts\n--- a/s.ts\n+++ b/s.ts\n@@ -1 +1 @@\n-a\n+%s\n' "$2" | jq -Rs .)
      printf '{"tool_name":"apply_patch","tool_input":{"patch":%s}}' "$p" ;;
    patch-diff-field) p=$(printf '*** Begin Patch\n*** Add File: d.ts\n+%s\n*** End Patch\n' "$2" | jq -Rs .)
      printf '{"tool_name":"apply_patch","tool_input":{"diff":%s}}' "$p" ;;
  esac
}

for s in write-file_path write-path edit multiedit-second notebookedit \
  patch-input-add patch-command-move patch-unified-diff patch-diff-field; do
  expect 2 "secret gate blocks $s" hook-pre-tool off "$(shape "$s" "$SECRET")"
  expect 2 "PII gate blocks a card in $s" hook-pre-tool mask "$(shape "$s" "card $CARD")"
  expect 0 "clean $s passes both gates" hook-pre-tool mask "$(shape "$s" 'plain words')"
done

# PostToolUse scans the file the call wrote. vault/ is gitignored, so only the
# direct target scan can see it.
printf '%s\n' "$SECRET" >vault/creds.txt
printf '%s\n' 'port = 8080' >vault/clean.txt
post() { # status name tool_input-json
  expect "$1" "$2" hook-post-tool off \
    "{\"tool_name\":$3,\"tool_input\":$4,\"tool_response\":\"ok\",\"cwd\":\"$CASE/repo\"}"
}
move_to() {
  printf '*** Begin Patch\n*** Update File: q.ts\n*** Move to: %s\n@@\n-old\n+port = 1\n*** End Patch\n' "$1" | jq -Rs '{command: .}'
}
post 2 'post-tool scans an apply_patch Move to destination' '"apply_patch"' "$(move_to vault/creds.txt)"
post 0 'post-tool passes a clean Move to destination' '"apply_patch"' "$(move_to vault/clean.txt)"
post 2 'post-tool scans a NotebookEdit notebook_path' '"NotebookEdit"' '{"notebook_path":"vault/creds.txt","new_source":"x"}'
post 2 'post-tool scans a NotebookEdit file_path' '"NotebookEdit"' '{"file_path":"vault/creds.txt","new_source":"x"}'
post 2 'post-tool scans a MultiEdit path field' '"MultiEdit"' '{"path":"vault/creds.txt","edits":[]}'
post 0 'post-tool passes a clean MultiEdit target' '"MultiEdit"' '{"file_path":"vault/clean.txt","edits":[]}'

printf 'tool input extraction assertions: %s passed, %s failed\n' "$passed" "$failed"
test "$failed" -eq 0
