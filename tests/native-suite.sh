#!/bin/sh
# Preserve the existing jq precise-stage fault injection when testing native mode.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
: "${AGENT_GUARD_RUST_CORE_BIN:?absolute path to release binary required}"
case "$AGENT_GUARD_RUST_CORE_BIN" in /*) ;; *) exit 2 ;; esac
NATIVE_REAL_CORE=$AGENT_GUARD_RUST_CORE_BIN
export NATIVE_REAL_CORE
CASE=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-native-suite.XXXXXX")
trap 'rm -rf "$CASE"' 0
cat >"$CASE/core" <<'CORE'
#!/bin/sh
if [ "${AGENT_GUARD_TEST_PARTIAL_STAGE:-}" = precise ]; then
  printf '{"partial":'
  exit 2
fi
printf x >> "$NATIVE_SUITE_MARKER"
exec "$NATIVE_REAL_CORE" "$@"
CORE
chmod +x "$CASE/core"
export AGENT_GUARD_EXPERIMENTAL_REDACTOR=rust
AGENT_GUARD_RUST_CORE_BIN="$CASE/core"
NATIVE_SUITE_MARKER="$CASE/used"
export AGENT_GUARD_RUST_CORE_BIN NATIVE_SUITE_MARKER
case "${1:-suite}" in
  suite) sh "$ROOT/tests/run.sh" ;;
  audit) sh "$ROOT/tests/audit-log.sh" ;;
  *) echo "usage: sh tests/native-suite.sh [suite|audit]" >&2; exit 2 ;;
esac
test -s "$NATIVE_SUITE_MARKER"
