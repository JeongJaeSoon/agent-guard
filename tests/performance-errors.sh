#!/bin/sh
# Exercise the real packaged runner through a synthetic Docker build failure.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
case_dir=$(mktemp -d)
trap 'rm -rf "$case_dir"' 0
mkdir -p "$case_dir/bin" "$case_dir/evidence/packaged-performance" "$case_dir/evidence/instruction-count"
for tool in git tar sha256sum; do
  printf '#!/bin/sh\nexit 0\n' > "$case_dir/bin/$tool"
done
cat > "$case_dir/bin/curl" <<'MOCK'
#!/bin/sh
while [ "$#" -gt 0 ]; do
  if [ "$1" = -o ]; then shift; : > "$1"; fi
  shift
done
MOCK
cat > "$case_dir/bin/docker" <<'MOCK'
#!/bin/sh
printf '%s\n' "$PERFORMANCE_FIXTURE_ERROR" >&2
exit 42
MOCK
chmod 755 "$case_dir/bin/"*
printf 'measurement_error\n' > "$case_dir/evidence/packaged-performance/verdict.txt"
printf 'passed\n' > "$case_dir/evidence/instruction-count/verdict.txt"
previous=
for cause in 'package mirror unavailable' 'Dockerfile COPY missing source'; do
  export PERFORMANCE_FIXTURE_ERROR="$cause"
  out="$case_dir/$(printf '%s' "$cause" | tr ' ' '-')"
  status=0
  PATH="$case_dir/bin:$PATH" sh "$ROOT/bench/native/run-packaged.sh" /synthetic/scanner synthetic-base "$out" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || status=$?
  [ "$status" -eq 42 ] || { echo 'build error exit status was lost' >&2; exit 1; }
  grep -Fxq "$cause" "$case_dir/stderr" || { echo 'Docker build stderr was buried' >&2; exit 1; }
  cp "$case_dir/stderr" "$case_dir/evidence/packaged-performance/errors.txt"
  identity=$(sh "$ROOT/.github/scripts/performance-cause.sh" "$case_dir/evidence" '- Packaged performance evidence: failure')
  [ "$identity" != "$previous" ] || { echo 'different build failures shared an issue identity' >&2; exit 1; }
  previous=$identity
  RUN_URL=https://example.invalid/run HEAD_SHA=synthetic \
    sh "$ROOT/.github/scripts/performance-issue-body.sh" "$case_dir/evidence" '- Packaged performance evidence: failure' > "$case_dir/body"
  grep -Fxq "$cause" "$case_dir/body" || { echo 'Docker build stderr was missing from issue body' >&2; exit 1; }
done
cause_for() {
  printf '%s\n' "$@" > "$case_dir/evidence/packaged-performance/errors.txt"
  sh "$ROOT/.github/scripts/performance-cause.sh" "$case_dir/evidence" '- Packaged performance evidence: failure'
}
first=$(cause_for 'integration start: host=claude fixture=0 variant=shell' \
  'integration end: host=claude fixture=0 variant=shell seconds=0.497 status=exit status: 0' \
  'baseline long-line 0.706s' 'candidate long-line 0.689s' 'measurement timed out')
same=$(cause_for 'integration start: host=claude fixture=0 variant=shell' \
  'integration end: host=claude fixture=0 variant=shell seconds=1.234 status=exit status: 0' \
  'baseline long-line 2.123s' 'candidate long-line 3.456s' 'measurement timed out')
[ "$first" = "$same" ] || { echo 'sample timing jitter changed the failure identity' >&2; exit 1; }
different=$(cause_for 'integration start: host=codex fixture=1 variant=shell' \
  'baseline dense-controls 0.706s' 'candidate dense-controls 0.689s' 'measurement timed out')
[ "$first" != "$different" ] || { echo 'distinct timeout locations shared an identity' >&2; exit 1; }
[ "$(cause_for 'cli-claude.log:' 'measurement timed out')" != "$(cause_for 'cli-codex.log:' 'measurement timed out')" ] \
  || { echo 'distinct measurement tools shared a timeout identity' >&2; exit 1; }
[ "$(cause_for 'candidate long-line 1.234s' 'measurement timed out')" != \
  "$(cause_for 'candidate long-line 2.345s' 'output validation failed')" ] \
  || { echo 'different measurement errors shared an identity after normalization' >&2; exit 1; }
[ "$(cause_for '#5 0.123 ERROR: package mirror unavailable' '#5 DONE 1.2s' 'sha256:synthetic 0.2s done')" = \
  "$(cause_for '#5 1.234 ERROR: package mirror unavailable' '#5 DONE 2.3s' 'sha256:synthetic 1.3s done')" ] \
  || { echo 'Docker progress timing changed the failure identity' >&2; exit 1; }
[ "$(cause_for 'host/fallback mismatch: claude, fixture=1, baseline_seconds=1.234, candidate_seconds=2.345, output=bad')" = \
  "$(cause_for 'host/fallback mismatch: claude, fixture=1, baseline_seconds=2.345, candidate_seconds=3.456, output=bad')" ] \
  || { echo 'fallback timing changed the failure identity' >&2; exit 1; }
printf 'ok - distinct Docker build failures preserve stderr and issue identity\n'
printf 'ok - timing jitter is normalized while timeout locations and errors stay distinct\n'
