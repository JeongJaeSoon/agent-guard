#!/bin/sh
# Loaded only inside an output detector; pre-tool/startup paths do not parse
# these experimental functions. All intermediate records remain private.
AG_FUSED_PIPELINE_LOADED=1

# Isolated output-pipeline experiment; default dispatch remains unchanged.
detect_output_secret_records_fused() (
  response=$1
  env_records=${2:-yes}
  detector_dir=$(
    umask 077
    if [ -n "${AGENT_GUARD_RUNDIR:-}" ] && [ -d "$AGENT_GUARD_RUNDIR" ]; then
      mktemp -d "$AGENT_GUARD_RUNDIR/detector.XXXXXX" 2>/dev/null && exit 0
    fi
    mktemp -d "${TMPDIR:-/tmp}/detector.XXXXXX" 2>/dev/null || mktemp -d /tmp/detector.XXXXXX
  ) || exit 1
  umask 077
  detector_input=$detector_dir/input
  detector_strings=$detector_dir/strings
  detector_records=$detector_dir/records
  detector_work_a=$detector_dir/work-a
  detector_work_b=$detector_dir/work-b
  detector_cleanup() {
    rm -rf "$detector_dir"
  }
  trap 'detector_cleanup' 0
  trap 'exit 130' INT
  trap 'exit 143' TERM
  detector_fail() {
    detector_cleanup
    exit 1
  }

  : >"$detector_records" || detector_fail
  printf '%s' "$response" >"$detector_input" || detector_fail
  detector_prepared=0
  : >"$detector_strings" || detector_fail
  : >"$detector_dir/framed" || detector_fail
  case "${AGENT_GUARD_EXPERIMENTAL_OUTPUT_PREPARE_BIN:-}" in
    /*)
      if [ "$env_records" = yes ] \
          && detector_ack=$("$AGENT_GUARD_EXPERIMENTAL_OUTPUT_PREPARE_BIN" prepare-v1 \
               "$detector_strings" "$detector_dir/framed" <"$detector_input" 2>/dev/null) \
          && [ "$detector_ack" = prepared-v1 ]; then
        detector_prepared=1
      fi
      ;;
  esac
  if [ "$detector_prepared" -eq 0 ]; then
    jq -rj 'if type == "string" then . else [.. | strings] | join("\n") end' \
      <"$detector_input" >"$detector_strings" 2>/dev/null || detector_fail
  fi

  gl=${GITLEAKS_READY_BIN:-}
  [ -n "$gl" ] && [ -x "$gl" ] || detector_fail
  [ -f "$GITLEAKS_CONFIG" ] || detector_fail
  if output_scan_input_exceeds_cap "$response"; then
      printf '%s\n' '{"agent_guard_whole_leaf":true}' \
        >>"$detector_records" || detector_fail
  else
      detector_report=$detector_dir/report
      (
        ulimit -f 128 >/dev/null 2>&1 || exit 2
        "$gl" stdin --report-format json --report-path "$detector_report" \
          --no-banner --config "$GITLEAKS_CONFIG" <"$detector_strings"
      ) >/dev/null 2>&1
      detector_status=$?
      case "$detector_status" in 0|1) ;; *) detector_fail ;; esac
      [ -s "$detector_report" ] || detector_fail
      # Validate and extract in one parser invocation. Stage output privately:
      # a parser error after partial records must still fail the detector.
      jq -sc 'if length == 0 or any(.[]; type != "array")
              then error("invalid scanner report") else .[] end
             | .[]? | (.Secret // empty)
             | select(type == "string" and length > 0)' \
        "$detector_report" >>"$detector_records" 2>/dev/null || detector_fail
  fi

  if [ "$env_records" = yes ]; then
    if [ "$detector_prepared" -eq 0 ]; then
      frame_json_string_leaves <"$detector_input" \
        >"$detector_dir/framed" 2>/dev/null || detector_fail
    fi
    secretish_env_values <"$detector_dir/framed" \
      >>"$detector_records" 2>/dev/null || detector_fail
  fi

  grep -Eo 'eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+' \
    <"$detector_strings" >"$detector_work_a" 2>/dev/null
  detector_status=$?
  case "$detector_status" in 0|1) ;; *) detector_fail ;; esac
  grep -Eio 'bearer[ \t]+[-A-Za-z0-9._~+/=]+' \
    <"$detector_strings" >"$detector_work_b" 2>/dev/null
  detector_status=$?
  case "$detector_status" in 0|1) ;; *) detector_fail ;; esac
  awk '{ tok = $2; if (length(tok) >= 8) print tok }' \
    <"$detector_work_b" >>"$detector_work_a" 2>/dev/null || detector_fail
  jq -Rc 'select(length > 0)' <"$detector_work_a" \
    >>"$detector_records" 2>/dev/null || detector_fail

  cat "$detector_records"
  detector_status=$?
  exit "$detector_status"
)

bundle_secret_records_fused() (
  bundle_records=$(mktemp_file) || exit 1
  trap 'rm -f "$bundle_records"' 0
  if ! LC_ALL=C awk '
        BEGIN {
          max_records = 256
          max_bytes = 65536
        }
        {
          record_count++
          record_bytes += length($0) + 1
          if (record_count > max_records || record_bytes > max_bytes) {
            print "{\"agent_guard_whole_leaf\":true}"
            exceeded = 1
            exit
          }
          records[record_count] = $0
        }
        END {
          if (!exceeded)
            for (i = 1; i <= record_count; i++) print records[i]
        }
      ' >"$bundle_records" \
    || ! jq -sc '
        if any(.[]; type == "object" and .agent_guard_whole_leaf == true)
        then {whole_leaf: true, secrets: []}
        else {whole_leaf: false, secrets: unique}
        end
      ' <"$bundle_records" 2>/dev/null; then
    exit 1
  fi
  exit 0
)

detect_output_secret_bundle_fused() (
  bundle_raw=$(mktemp_file) || exit 1
  trap 'rm -f "$bundle_raw"' 0
  detect_output_secret_records "$1" >"$bundle_raw" || exit 1
  bundle_secret_records <"$bundle_raw"
)

