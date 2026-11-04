#!/bin/sh
# Same public Agent Guard bytes; scanner dependency is the variable under test.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
cd "$ROOT"
public=${1:?absolute official scanner required}
control=${2:?absolute rebuild control required}
candidate=${3:?absolute experimental scanner required}
out=${4:?new absolute evidence directory required}
mode_selection=${5:-all}
case "$mode_selection" in
  all) modes='off cold warm'; expected_targets=6 ;;
  off|cold|warm) modes=$mode_selection; expected_targets=2 ;;
  *) echo 'audit mode must be all, off, cold or warm' >&2; exit 2 ;;
esac
case "$public:$control:$candidate:$out" in /*:/*:/*:/*) ;; *) exit 2 ;; esac
[ ! -e "$out" ] || exit 2
mkdir -p "$out"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' 0
mkdir "$stage/public"
curl -fsSL https://github.com/JeongJaeSoon/agent-guard/releases/download/v3.7.0/agent-guard-3.7.0.tar.gz -o "$stage/public.tar.gz"
printf '%s  %s\n' d6ff2d398643f789d0259c782f7760504836f4495471dba613e3abc46dc2bf3d "$stage/public.tar.gz" | sha256sum -c - > "$out/public-checksum.txt"
tar -xzf "$stage/public.tar.gz" -C "$stage/public"
chmod -R a+rX "$stage/public"
image=agent-guard-scanner-experiment
docker build --secret id=proxy_ca,src=/etc/ssl/certs/ca-certificates.crt -f bench/native/Dockerfile -t "$image" . > "$out/build.log" 2>&1
docker image inspect "$image" --format '{{.Id}}' > "$out/image-id.txt"
run() {
  docker run --rm --init --network=none --cpus=2 --memory=1g --memory-swap=1g \
    -e AGENT_GUARD_BENCH_CGROUP_ISOLATED=1 \
    -v "$ROOT:/repo:ro" -v "$stage/public:/public:ro" \
    -v "$public:/scanner/public/gitleaks:ro" -v "$control:/scanner/control/gitleaks:ro" \
    -v "$candidate:/scanner/candidate/gitleaks:ro" "$image" "$@"
}
limits=$(run sh -c 'cat /sys/fs/cgroup/cpu.max /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory.swap.max')
[ "$(docker info --format '{{.CgroupDriver}}')" != none ] && [ "$limits" = "200000 100000
1073741824
0" ] || { echo 'resource limits not enforced' >&2; exit 2; }
printf '%s\n' "$limits" > "$out/enforced-limits.txt"
git rev-parse HEAD > "$out/checkout-sha.txt"
run sh -c 'uname -a; jq --version; sha256sum /scanner/*/gitleaks /public/bin/agent-guard /repo/plugins/agent-guard/config/gitleaks.toml' > "$out/environment.txt"
run cat /proc/cpuinfo > "$out/cpuinfo.txt"
core=/public/libexec/agent-guard-redact-x86_64-unknown-linux-musl
if [ "$mode_selection" = all ] || [ "$mode_selection" = off ]; then
run env AGENT_GUARD_RUST_CORE_BIN="$core" AGENT_GUARD_TEST_SHARD=4 sh -c '
  # Preserve the suite mocks; its real-scanner block discovers this candidate.
  PATH=/scanner/candidate:$PATH
  export PATH
  unset AGENT_GUARD_GITLEAKS_BIN
  exec sh tests/native-suite.sh
' > "$out/output-corpus.log" 2>&1
fi
for mode in $modes; do
  for host in claude codex; do
    run agent-guard-devtools masking-latency --baseline /public/bin/agent-guard --binary /public/bin/agent-guard \
      --baseline-packaged-native --native-core "$core" --packaged-native \
      --scanner /scanner/public/gitleaks --candidate-scanner /scanner/candidate/gitleaks \
      --audit-state "$mode" --host "$host" --runs 9 --resources --include-boundaries --trace-processes \
      > "$out/cli-$host-$mode.json" 2> "$out/cli-$host-$mode.stderr"
  done
done
if [ "$mode_selection" = all ] || [ "$mode_selection" = off ]; then
run agent-guard-devtools masking-latency --baseline /public/bin/agent-guard --binary /public/bin/agent-guard \
  --baseline-packaged-native --native-core "$core" --packaged-native \
  --scanner /scanner/public/gitleaks --candidate-scanner /scanner/control/gitleaks \
  --audit-state off --runs 9 --resources --case small-clean --case long-line --case many-replacement-leaves \
  > "$out/compiler-control.json" 2> "$out/compiler-control.stderr"
for workers in 1 4; do
  for trial in 1 2 3; do
    order='public candidate'
    if [ "$trial" = 2 ]; then order='candidate public'; fi
    for backend in $order; do
      run agent-guard-devtools load --binary /public/bin/agent-guard --core "$core" --packaged-native \
        --scanner "/scanner/$backend/gitleaks" --workers "$workers" --requests 8 \
        > "$out/load-$workers-$trial-$backend.json"
    done
  done
done
fi
jq -s --argjson expected_targets "$expected_targets" -f bench/scanner/assess.jq "$out"/cli-*.json > "$out/assessment.json"
cat "$out/assessment.json"
