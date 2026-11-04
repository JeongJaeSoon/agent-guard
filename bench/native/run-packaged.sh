#!/bin/sh
# Strict qualification of the packaged dispatch, including checksum/startup cost.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
cd "$ROOT"
scanner=${1:?absolute scanner required}
baseline=${2:?baseline git ref required}
out=${3:?new absolute results directory required}
case "$scanner:$out" in /*:/*) ;; *) exit 2 ;; esac
[ ! -e "$out" ] || { echo 'refusing to overwrite measurement evidence' >&2; exit 2; }
mkdir -p "$out"
case_dir=$(mktemp -d)
trap 'rm -rf "$case_dir"' 0
mkdir "$case_dir/baseline"
git archive "$baseline" plugins/agent-guard | tar -x -C "$case_dir/baseline"
image=agent-guard-packaged-qualification
docker build --secret id=proxy_ca,src=/etc/ssl/certs/ca-certificates.crt \
  -f bench/native/Dockerfile -t "$image" . > "$out/build.log" 2>&1
docker image inspect "$image" --format '{{.Id}}' > "$out/image-id.txt"
docker info --format '{{json .}}' > "$out/docker-info.json"
run() {
  docker run --rm --init --network=none --cpus=2 --memory=1g --memory-swap=1g \
    -e AGENT_GUARD_BENCH_CGROUP_ISOLATED=1 \
    -v "$ROOT:/repo:ro" -v "$case_dir/baseline:/baseline:ro" -v "$scanner:/scanner/gitleaks:ro" \
    "$image" "$@"
}
limits=$(run sh -c 'cat /sys/fs/cgroup/cpu.max /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory.swap.max')
[ "$(docker info --format '{{.CgroupDriver}}')" != none ] \
  && [ "$limits" = "200000 100000
1073741824
0" ] || { echo 'required 2 CPU / 1 GiB / no-swap cgroup limits are not enforced' >&2; exit 2; }
printf '%s\n' "$limits" > "$out/enforced-limits.txt"
core=/repo/plugins/agent-guard/libexec/agent-guard-redact-x86_64-unknown-linux-musl
old=/baseline/plugins/agent-guard/bin/agent-guard
run sh -c 'uname -a; jq --version; /scanner/gitleaks version; sha256sum plugins/agent-guard/bin/agent-guard plugins/agent-guard/libexec/agent-guard-redact-* /scanner/gitleaks; dpkg-query -W dash gawk libc6; date -u' > "$out/environment.txt"
run cat /proc/cpuinfo > "$out/cpuinfo.txt"
run agent-guard-devtools native-redaction --core "$core" > "$out/differential.json"
run agent-guard-devtools native-integration --core "$core" --scanner /scanner/gitleaks > "$out/integration.json"
run sh tests/native-packaged.sh "$core" /scanner/gitleaks > "$out/packaged.log"
run agent-guard-devtools kernel --core "$core" --runs 15 > "$out/kernel.json"
run agent-guard-devtools masking-latency --baseline "$old" --native-core "$core" --packaged-native \
  --scanner /scanner/gitleaks --runs 9 --resources --include-boundaries --trace-processes > "$out/cli-claude.json" 2> "$out/cli-claude.log"
run agent-guard-devtools masking-latency --baseline "$old" --native-core "$core" --packaged-native \
  --scanner /scanner/gitleaks --runs 9 --resources --host codex \
  --case small-clean --case long-line --case many-replacement-leaves > "$out/cli-codex.json" 2> "$out/cli-codex.log"
run agent-guard-devtools masking-latency --baseline "$old" --scanner /scanner/gitleaks --runs 9 --resources \
  --case small-clean --case long-line --case many-replacement-leaves > "$out/cli-shell-control.json" 2> "$out/cli-shell-control.log"
for workers in 1 4; do
  for repeat in 1 2 3; do
    order='shell rust'
    if [ "$repeat" = 2 ]; then order='rust shell'; fi
    for backend in $order; do
      if [ "$backend" = rust ]; then
        run agent-guard-devtools load --binary /repo/plugins/agent-guard/bin/agent-guard \
          --core "$core" --packaged-native --scanner /scanner/gitleaks --workers "$workers" --requests 8 > "$out/load-$workers-$repeat-$backend.json"
      else
        run agent-guard-devtools load --binary "$old" --scanner /scanner/gitleaks \
          --workers "$workers" --requests 8 > "$out/load-$workers-$repeat-$backend.json"
      fi
    done
  done
done
run agent-guard-devtools masking-latency --baseline "$old" --native-core "$core" --packaged-native \
  --scanner /scanner/gitleaks --runs 21 --resources --case small-clean > "$out/cli-clean-followup.json" 2> "$out/cli-clean-followup.log"
sh bench/native/assess-packaged.sh "$out"
