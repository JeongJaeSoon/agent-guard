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
printf 'measurement timed out\n' > "$case_dir/evidence/packaged-performance/errors.txt"
identity=$(sh "$ROOT/.github/scripts/performance-cause.sh" "$case_dir/evidence" '- Packaged performance evidence: failure')
printf '%s\n' 'integration end: host=claude fixture=0 seconds=0.497 status=exit status: 0' \
  'baseline long-line 0.706s' 'candidate long-line 0.689s' 'measurement timed out' \
  > "$case_dir/evidence/packaged-performance/errors.txt"
with_progress=$(sh "$ROOT/.github/scripts/performance-cause.sh" "$case_dir/evidence" '- Packaged performance evidence: failure')
[ "$identity" = "$with_progress" ] || { echo 'sample timing jitter changed the failure identity' >&2; exit 1; }
printf 'ok - distinct Docker build failures preserve stderr and issue identity\n'
printf 'ok - measurement progress timing does not change the failure cause\n'
