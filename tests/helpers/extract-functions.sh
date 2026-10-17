#!/bin/sh
# Usage: sh extract-functions.sh SOURCE EXISTING_OUTPUT_DIR FUNCTION...
# Callers own cleanup and source only the named bodies, never CLI startup.
set -eu
SOURCE=$1 OUTPUT=$2
shift 2
[ "$#" -gt 0 ] || exit 2
for function do
  awk -v name="$function" '
    $0 == name "() {" { starts++; copying=1 }
    copying { print }
    copying && $0 == "}" { ends++; copying=0 }
    END { if (starts != 1 || ends != 1 || copying) exit 1 }
  ' "$SOURCE" >"$OUTPUT/$function.sh" || {
    printf 'not ok - cannot isolate %s exactly once\n' "$function" >&2
    exit 1
  }
  sh -n "$OUTPUT/$function.sh"
done
