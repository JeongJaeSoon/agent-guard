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
if [ -n "${AGENT_GUARD_EXPERIMENTAL_OUTPUT_PREPARE_BIN:-}" ]; then
  NATIVE_REAL_PREPARE=$AGENT_GUARD_EXPERIMENTAL_OUTPUT_PREPARE_BIN
  export NATIVE_REAL_PREPARE
  cat >"$CASE/prepare-core" <<'PREPARE'
#!/bin/sh
# These injections represent a failed extraction/framing stage. Fail the
# native attempt too, then retain the existing failing jq fallback and exact
# whole-leaf expectation. Healthy native preparation has separate corpus tests.
case "${AGENT_GUARD_TEST_PARTIAL_STAGE:-}" in
  detector_leaf|detector_frame)
    printf 'partial' >"$2"
    printf 'partial' >"$3"
    exit 2 ;;
esac
exec "$NATIVE_REAL_PREPARE" "$@"
PREPARE
  chmod +x "$CASE/prepare-core"
  AGENT_GUARD_EXPERIMENTAL_OUTPUT_PREPARE_BIN="$CASE/prepare-core"
  export AGENT_GUARD_EXPERIMENTAL_OUTPUT_PREPARE_BIN
fi
case "${1:-suite}" in
  suite) sh "$ROOT/tests/run.sh" ;;
  audit) sh "$ROOT/tests/audit-log.sh" ;;
  *) echo "usage: sh tests/native-suite.sh [suite|audit]" >&2; exit 2 ;;
esac
test -s "$NATIVE_SUITE_MARKER"
