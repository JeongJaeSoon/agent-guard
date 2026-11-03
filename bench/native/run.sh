#!/bin/sh
# Reproducible Linux/x86_64 experiment. Run without other local test/benchmark jobs.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
cd "$ROOT"
if [ "$#" -ne 3 ]; then
  echo 'usage: sh bench/native/run.sh /absolute/gitleaks baseline-git-ref /absolute/results-dir' >&2
  exit 2
fi
SCANNER=$1
BASELINE=$2
OUT=$3
case "$SCANNER:$OUT" in /*:/*) ;; *) exit 2 ;; esac
case "$(uname -s):$(uname -m)" in Linux:x86_64) ;; *) echo 'this image pins Linux/x86_64 jq' >&2; exit 2 ;; esac
mkdir -p "$OUT"
CASE=$(mktemp -d)
trap 'rm -rf "$CASE"' 0
mkdir "$CASE/baseline"
git archive "$BASELINE" plugins/agent-guard | tar -x -C "$CASE/baseline"
IMAGE=agent-guard-rust-experiment
CA_BUNDLE=${AGENT_GUARD_BENCH_CA_BUNDLE:-/etc/ssl/certs/ca-certificates.crt}
docker build --secret "id=proxy_ca,src=$CA_BUNDLE" -f bench/native/Dockerfile -t "$IMAGE" . >"$OUT/build.log" 2>&1
docker image inspect "$IMAGE" --format '{{.Id}}' >"$OUT/image-id.txt"
run() {
  docker run --rm --init --network=none --cpus=2 --memory=1g \
    -e PYTHONDONTWRITEBYTECODE=1 \
    -v "$ROOT:/repo:ro" -v "$CASE/baseline:/baseline:ro" -v "$SCANNER:/scanner/gitleaks:ro" \
    "$IMAGE" "$@"
}
CORE=/build/target/release/agent-guard-redact
OLD=/baseline/plugins/agent-guard/bin/agent-guard
run sh -c 'rustc --version; jq --version; /scanner/gitleaks version; cat /sys/fs/cgroup/cpu.max; cat /sys/fs/cgroup/memory.max; sha256sum /build/target/release/agent-guard-redact /baseline/plugins/agent-guard/bin/agent-guard /repo/plugins/agent-guard/bin/agent-guard /scanner/gitleaks; dpkg-query -W dash gawk libc6 python3; ldd /build/target/release/agent-guard-redact; date -u' >"$OUT/environment.txt"
run python3 tests/native-redaction.py --core "$CORE" >"$OUT/differential.json"
run python3 tests/native-integration.py --core "$CORE" --scanner /scanner/gitleaks >"$OUT/integration.json"
run python3 bench/native/kernel.py --core "$CORE" --runs 15 >"$OUT/kernel.json"
run python3 bench/masking-latency.py --baseline "$OLD" --native-core "$CORE" \
  --scanner /scanner/gitleaks --runs 9 --resources --include-boundaries --trace-processes >"$OUT/cli-claude.json" 2>"$OUT/cli-claude.log"
run python3 bench/masking-latency.py --baseline "$OLD" --native-core "$CORE" \
  --scanner /scanner/gitleaks --runs 9 --resources --host codex \
  --case small-clean --case long-line --case many-replacement-leaves >"$OUT/cli-codex.json" 2>"$OUT/cli-codex.log"
run python3 bench/masking-latency.py --baseline "$OLD" \
  --scanner /scanner/gitleaks --runs 9 --resources \
  --case small-clean --case long-line --case many-replacement-leaves >"$OUT/cli-shell-control.json" 2>"$OUT/cli-shell-control.log"
for workers in 1 4; do
  for repeat in 1 2 3; do
    order='shell rust'
    if [ "$repeat" = 2 ]; then order='rust shell'; fi
    for backend in $order; do
      if [ "$backend" = rust ]; then
        run python3 bench/native/load.py --binary /repo/plugins/agent-guard/bin/agent-guard \
          --core "$CORE" --scanner /scanner/gitleaks --workers "$workers" --requests 8 >"$OUT/load-$workers-$repeat-$backend.json"
      else
        run python3 bench/native/load.py --binary "$OLD" \
          --scanner /scanner/gitleaks --workers "$workers" --requests 8 >"$OUT/load-$workers-$repeat-$backend.json"
      fi
    done
  done
done
