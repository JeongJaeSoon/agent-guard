#!/bin/sh
# Loaded only inside an output detector; pre-tool/startup paths do not parse
# these experimental functions. All intermediate records remain private.
AG_FUSED_PIPELINE_LOADED=1

# Prepare the scanner strings ($2) and framed string leaves ($3) of the
# response file ($1) with the opt-in native core in one process. Succeeds only
# on a complete prepared-v1 acknowledgement; on failure the caller rewrites
# both files with the jq stages, so partial helper output is never used.
output_prepare_fused() {
  case "${AGENT_GUARD_EXPERIMENTAL_OUTPUT_PREPARE_BIN:-}" in
    /*) ;;
    *) return 1 ;;
  esac
  fused_ack=$("$AGENT_GUARD_EXPERIMENTAL_OUTPUT_PREPARE_BIN" prepare-v1 \
    "$2" "$3" <"$1" 2>/dev/null) && [ "$fused_ack" = prepared-v1 ]
}
