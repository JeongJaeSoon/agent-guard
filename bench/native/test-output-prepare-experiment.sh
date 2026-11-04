#!/bin/sh
# Run the existing output corpus against the isolated experiment.
# Fault injection must reach the replacement stage as well as its jq fallback.
set -eu
root=${1:?absolute experimental checkout required}
core=${2:?absolute experimental helper required}
case "$root:$core" in /*:/*) ;; *) exit 2 ;; esac
case_dir=$(mktemp -d)
trap 'rm -rf "$case_dir"' 0
cat > "$case_dir/prepare" <<'SH'
#!/bin/sh
case "${AGENT_GUARD_TEST_PARTIAL_STAGE:-}" in
  detector_leaf|detector_frame)
    printf partial > "$2"
    printf partial > "$3"
    printf prepared
    exit 2
    ;;
esac
printf x >> "$OUTPUT_PREPARE_MARKER"
exec "$OUTPUT_PREPARE_REAL_CORE" "$@"
SH
chmod 755 "$case_dir/prepare"
export OUTPUT_PREPARE_MARKER="$case_dir/used" OUTPUT_PREPARE_REAL_CORE="$core"
export AGENT_GUARD_EXPERIMENTAL_OUTPUT_PREPARE_BIN="$case_dir/prepare"
export AGENT_GUARD_RUST_CORE_BIN="$core" AGENT_GUARD_TEST_SHARD=4
sh "$root/tests/native-suite.sh"
test -s "$OUTPUT_PREPARE_MARKER"
