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
sha256sum plugins/agent-guard/bin/agent-guard >"$OUT/cli-source-before.sha256"
CASE=$(mktemp -d)
trap 'rm -rf "$CASE"' 0
mkdir "$CASE/baseline"
git archive "$BASELINE" plugins/agent-guard | tar -x -C "$CASE/baseline"
IMAGE=${AGENT_GUARD_BENCH_IMAGE:-agent-guard-rust-experiment}
CA_BUNDLE=${AGENT_GUARD_BENCH_CA_BUNDLE:-/etc/ssl/certs/ca-certificates.crt}
if [ -z "${AGENT_GUARD_BENCH_IMAGE:-}" ]; then
  docker build --secret "id=proxy_ca,src=$CA_BUNDLE" -f bench/native/Dockerfile -t "$IMAGE" . >"$OUT/build.log" 2>&1
else
  printf 'Reusing explicitly selected image: %s\n' "$IMAGE" >"$OUT/build.log"
fi
# A reused image must contain exactly the current native source and lockfile.
docker run --rm --network=none -v "$ROOT:/repo:ro" "$IMAGE" sh -c '
  cmp /build/Cargo.toml /repo/native/redaction-core/Cargo.toml &&
  cmp /build/Cargo.lock /repo/native/redaction-core/Cargo.lock &&
  cmp /build/src/main.rs /repo/native/redaction-core/src/main.rs &&
  cmp /devtools/Cargo.toml /repo/native/devtools/Cargo.toml &&
  cmp /devtools/Cargo.lock /repo/native/devtools/Cargo.lock &&
  diff -r /devtools/src /repo/native/devtools/src &&
  ! command -v python3 && ! command -v python
'
docker image inspect "$IMAGE" --format '{{.Id}}' >"$OUT/image-id.txt"
CGROUP_ISOLATED=0
docker info --format '{"cgroup_driver":{{json .CgroupDriver}},"cgroup_version":{{json .CgroupVersion}},"warnings":{{json .Warnings}}}' >"$OUT/docker-info.json"
run() {
  docker run --rm --init --network=none --cpus=2 --memory=1g \
    -e "AGENT_GUARD_BENCH_CGROUP_ISOLATED=$CGROUP_ISOLATED" \
    -v "$ROOT:/repo:ro" -v "$CASE/baseline:/baseline:ro" -v "$SCANNER:/scanner/gitleaks:ro" \
    "$IMAGE" "$@"
}
CGROUP_DRIVER=$(docker info --format '{{.CgroupDriver}}')
LIMITS=$(run sh -c 'cat /sys/fs/cgroup/cpu.max; cat /sys/fs/cgroup/memory.max')
if [ "$CGROUP_DRIVER" != none ] && [ "$LIMITS" = "200000 100000
1073741824" ]; then
  CGROUP_ISOLATED=1
else
  echo 'Requested container limits are not visible; cgroup peaks must not be treated as container memory.' >&2
fi
CORE=/build/target/release/agent-guard-redact
OLD=/baseline/plugins/agent-guard/bin/agent-guard
run sh -c 'rustc --version; jq --version; /scanner/gitleaks version; cat /sys/fs/cgroup/cpu.max; cat /sys/fs/cgroup/memory.max; sha256sum /build/target/release/agent-guard-redact /baseline/plugins/agent-guard/bin/agent-guard /repo/plugins/agent-guard/bin/agent-guard /scanner/gitleaks; dpkg-query -W dash gawk libc6; ldd /build/target/release/agent-guard-redact; date -u' >"$OUT/environment.txt"
run agent-guard-devtools native-redaction --core "$CORE" >"$OUT/differential.json"
run agent-guard-devtools native-integration --core "$CORE" --scanner /scanner/gitleaks >"$OUT/integration.json"
run sh -c 'mkdir /tmp/legacy-jq; ln -s /usr/bin/jq /tmp/legacy-jq/jq; PATH=/tmp/legacy-jq:$PATH agent-guard-devtools native-integration --core /build/target/release/agent-guard-redact --scanner /scanner/gitleaks' >"$OUT/integration-jq16.json"
run agent-guard-devtools kernel --core "$CORE" --runs 15 >"$OUT/kernel.json"
run agent-guard-devtools masking-latency --baseline "$OLD" --native-core "$CORE" \
  --scanner /scanner/gitleaks --runs 9 --resources --include-boundaries --trace-processes >"$OUT/cli-claude.json" 2>"$OUT/cli-claude.log"
run agent-guard-devtools masking-latency --baseline "$OLD" --native-core "$CORE" \
  --scanner /scanner/gitleaks --runs 9 --resources --host codex \
  --case small-clean --case long-line --case many-replacement-leaves >"$OUT/cli-codex.json" 2>"$OUT/cli-codex.log"
run agent-guard-devtools masking-latency --baseline "$OLD" \
  --scanner /scanner/gitleaks --runs 9 --resources \
  --case small-clean --case long-line --case many-replacement-leaves >"$OUT/cli-shell-control.json" 2>"$OUT/cli-shell-control.log"
for workers in 1 4; do
  for repeat in 1 2 3; do
    order='shell rust'
    if [ "$repeat" = 2 ]; then order='rust shell'; fi
    for backend in $order; do
      if [ "$backend" = rust ]; then
        run agent-guard-devtools load --binary /repo/plugins/agent-guard/bin/agent-guard \
          --core "$CORE" --scanner /scanner/gitleaks --workers "$workers" --requests 8 >"$OUT/load-$workers-$repeat-$backend.json"
      else
        run agent-guard-devtools load --binary "$OLD" \
          --scanner /scanner/gitleaks --workers "$workers" --requests 8 >"$OUT/load-$workers-$repeat-$backend.json"
      fi
    done
  done
done
# The first clean workload showed environmental variance in the recorded run.
# Preserve the original trials and add a separate 21-pair stability check.
run agent-guard-devtools masking-latency --baseline "$OLD" --native-core "$CORE" \
  --scanner /scanner/gitleaks --runs 21 --resources --case small-clean \
  >"$OUT/cli-clean-followup.json" 2>"$OUT/cli-clean-followup.log"
sha256sum plugins/agent-guard/bin/agent-guard >"$OUT/cli-source-after.sha256"
cmp "$OUT/cli-source-before.sha256" "$OUT/cli-source-after.sha256"
