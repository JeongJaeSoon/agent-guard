#!/usr/bin/env sh
# Direct scan dependency failures have a distinct public status. Keep this
# focused check runnable on its own as well as from the main suite.
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
GUARD="$ROOT/plugins/agent-guard/bin/agent-guard"
SCANNER="$ROOT/tests/fixtures/mock-gitleaks"
POLICY="$ROOT/plugins/agent-guard/config/gitleaks.toml"
CASE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-status.XXXXXX") || exit 1
trap 'rm -rf "$CASE_ROOT"' EXIT HUP INT TERM

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
mkdir "$CASE_ROOT/repo" "$CASE_ROOT/no-git"
git -C "$CASE_ROOT/repo" -c init.templateDir= init -q || exit 1
printf 'ordinary app source\n' >"$CASE_ROOT/repo/app.txt"
git -C "$CASE_ROOT/repo" add app.txt || exit 1

for dep in sh dirname pwd readlink awk; do
  dep_path=$(command -v "$dep") || exit 1
  ln -s "$dep_path" "$CASE_ROOT/no-git/$dep"
done

printf '#!/bin/sh\nexit 42\n' >"$CASE_ROOT/scanner-crash"
chmod +x "$CASE_ROOT/scanner-crash"
cd "$CASE_ROOT/repo" || exit 1

failed=0
checked=0
expect() {
  expected=$1
  label=$2
  shift 2
  "$@" >"$CASE_ROOT/out" 2>"$CASE_ROOT/err"
  actual=$?
  checked=$((checked + 1))
  if [ "$actual" -eq "$expected" ]; then
    printf 'ok - %s\n' "$label"
  else
    printf 'not ok - %s (expected %s, got %s)\n' "$label" "$expected" "$actual"
    sed 's/^/  stderr: /' "$CASE_ROOT/err"
    failed=$((failed + 1))
  fi
}

for scan in scan-path scan-staged scan-working-tree; do
  expect 3 "$scan reports missing scanner as unavailable" \
    env AGENT_GUARD_GITLEAKS_BIN="$CASE_ROOT/missing-scanner" \
      AGENT_GUARD_GITLEAKS_CONFIG="$POLICY" "$GUARD" "$scan" .
  expect 3 "$scan reports missing policy as unavailable" \
    env AGENT_GUARD_GITLEAKS_BIN="$SCANNER" \
      AGENT_GUARD_GITLEAKS_CONFIG="$CASE_ROOT/missing-policy" "$GUARD" "$scan" .
  expect 0 "$scan recovers to clean when dependencies return" \
    env AGENT_GUARD_GITLEAKS_BIN="$SCANNER" \
      AGENT_GUARD_GITLEAKS_CONFIG="$POLICY" "$GUARD" "$scan" .
done

for scan in scan-staged scan-working-tree; do
  expect 3 "$scan reports missing git as unavailable" \
    env PATH="$CASE_ROOT/no-git" AGENT_GUARD_GITLEAKS_BIN="$SCANNER" \
      AGENT_GUARD_GITLEAKS_CONFIG="$POLICY" "$GUARD" "$scan"
done

expect 3 'native Git hook retains unavailable status' \
  env AGENT_GUARD_GITLEAKS_BIN="$CASE_ROOT/missing-scanner" \
    AGENT_GUARD_GITLEAKS_CONFIG="$POLICY" "$ROOT/githooks/pre-commit"
expect 2 'scanner crash remains a scanner error' \
  env AGENT_GUARD_GITLEAKS_BIN="$CASE_ROOT/scanner-crash" \
    AGENT_GUARD_GITLEAKS_CONFIG="$POLICY" "$GUARD" scan-path .
expect 2 'explicit exec retains its fail-closed dependency status' \
  env AGENT_GUARD_OUTPUT_REDACT=mask \
    AGENT_GUARD_GITLEAKS_BIN="$CASE_ROOT/missing-scanner" \
    AGENT_GUARD_GITLEAKS_CONFIG="$POLICY" "$GUARD" exec -- sh -c 'touch should-not-run'
checked=$((checked + 1))
if [ ! -e should-not-run ]; then
  printf 'ok - unavailable exec does not run its command\n'
else
  printf 'not ok - unavailable exec ran its command\n'
  failed=$((failed + 1))
fi

printf '%s direct scan status checks, %s failed\n' "$checked" "$failed"
[ "$failed" -eq 0 ]
