#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
cd "$ROOT"
scanner=${1:?absolute scanner path}
mode=${2:?off cold or warm}
out=${3:?new absolute evidence directory}
case "$mode" in off|cold|warm) ;; *) exit 2 ;; esac
case "$scanner:$out" in /*:/*) ;; *) exit 2 ;; esac
[ ! -e "$out" ] || exit 2
mkdir -p "$out"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' 0
mkdir "$stage/public"
curl -fsSL https://github.com/JeongJaeSoon/agent-guard/releases/download/v3.7.0/agent-guard-3.7.0.tar.gz -o "$stage/public.tar.gz"
printf '%s  %s\n' d6ff2d398643f789d0259c782f7760504836f4495471dba613e3abc46dc2bf3d "$stage/public.tar.gz" | sha256sum -c - > "$out/public-checksum.txt"
tar -xzf "$stage/public.tar.gz" -C "$stage/public"
chmod -R a+rX "$stage/public"
# Attribution runs retain the public redactor in both arms. Release qualification
# can instead use one qualified candidate artifact for preparation and redaction.
# Both modes keep every native process startup inside candidate timing.
mkdir -p plugins/agent-guard/libexec
qualified_core=${AGENT_GUARD_BENCH_FUSED_PACKAGED_CORE:-}
core=/public/libexec/agent-guard-redact-x86_64-unknown-linux-musl
prepare=/build/target/release/agent-guard-redact
comparison_scope='same scanner and public redactor; output pipeline experiment'
if [ -n "$qualified_core" ]; then
  case "$qualified_core" in /*/agent-guard-redact-x86_64-unknown-linux-musl) ;; *) exit 2 ;; esac
  [ -f "$qualified_core" ] && [ ! -L "$qualified_core" ]
  [ -f "$qualified_core.sha256" ] && [ ! -L "$qualified_core.sha256" ]
  (cd "${qualified_core%/*}" && sha256sum -c "${qualified_core##*/}.sha256") > "$out/candidate-core-checksum.txt"
  cp "$qualified_core" "$qualified_core.sha256" plugins/agent-guard/libexec/
  core=/repo/plugins/agent-guard/libexec/agent-guard-redact-x86_64-unknown-linux-musl
  prepare=$core
  comparison_scope='same scanner; public v3.7.0 versus candidate sharing one qualified packaged core'
else
  cp "$stage/public/libexec/agent-guard-redact-x86_64-unknown-linux-musl"* plugins/agent-guard/libexec/
fi
image=agent-guard-fused-proof
docker build --secret id=proxy_ca,src=/etc/ssl/certs/ca-certificates.crt -f bench/native/Dockerfile -t "$image" . > "$out/build.log" 2>&1
docker image inspect "$image" --format '{{.Id}}' > "$out/image-id.txt"
run_container() {
  docker run --rm --init --network=none --cpus=2 --memory=1g --memory-swap=1g \
    -e AGENT_GUARD_BENCH_CGROUP_ISOLATED=1 \
    -v "$stage/public:/public:ro" -v "$scanner:/scanner/gitleaks:ro" "$@"
}
run() {
  # Real Linux Homebrew bottles reference their own dynamic loader/libraries.
  # Preserve that published binary and runtime prefix instead of patching ELF.
  if [ -d /home/linuxbrew/.linuxbrew ]; then
    run_container -v /home/linuxbrew/.linuxbrew:/home/linuxbrew/.linuxbrew:ro "$image" "$@"
  else
    run_container "$image" "$@"
  fi
}
limits=$(run sh -c 'cat /sys/fs/cgroup/cpu.max /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory.swap.max')
[ "$(docker info --format '{{.CgroupDriver}}')" != none ] && [ "$limits" = "200000 100000
1073741824
0" ] || { echo 'resource limits not enforced' >&2; exit 2; }
printf '%s\n' "$limits" > "$out/enforced-limits.txt"
git rev-parse HEAD > "$out/checkout-sha.txt"
run sh -c 'uname -a; jq --version; sha256sum /scanner/gitleaks /public/bin/agent-guard plugins/agent-guard/bin/agent-guard plugins/agent-guard/scripts/output-pipeline-experiment.sh /build/target/release/agent-guard-redact; cat /proc/cpuinfo' > "$out/environment.txt"
measure() {
  measure_host=$1 measure_runs=$2
  shift 2
  run agent-guard-devtools masking-latency --baseline /public/bin/agent-guard \
    --binary /repo/plugins/agent-guard/bin/agent-guard \
    --fused-output --prepare-core "$prepare" \
    --baseline-packaged-native --native-core "$core" --packaged-native \
    --scanner /scanner/gitleaks --audit-state "$mode" --host "$measure_host" \
    --runs "$measure_runs" --resources --include-boundaries "$@"
}
for host in claude codex; do
  measure "$host" 9 --trace-processes > "$out/cli-$host.json" 2> "$out/cli-$host.stderr"
done
if [ "$mode" = off ]; then
  for workers in 1 4; do
    for trial in 1 2 3; do
      order='baseline candidate'
      if [ "$trial" = 2 ]; then order='candidate baseline'; fi
      for arm in $order; do
        binary=/public/bin/agent-guard
        load_core=/public/libexec/agent-guard-redact-x86_64-unknown-linux-musl
        set --
        if [ "$arm" = candidate ]; then
          binary=/repo/plugins/agent-guard/bin/agent-guard
          load_core=$core
          set -- --fused-output --prepare-core "$prepare"
        fi
        run agent-guard-devtools load --binary "$binary" --core "$load_core" --packaged-native \
          --scanner /scanner/gitleaks --workers "$workers" --requests 8 "$@" > "$out/load-$workers-$trial-$arm.json"
      done
    done
  done
fi
jq -s --argjson expected_targets 2 -f bench/scanner/assess.jq "$out"/cli-*.json \
  | jq --arg scope "$comparison_scope" '.scope=$scope' > "$out/screening.json"
# Predeclared confirmation (see bench/native/confirm.jq): only flagged cases are
# measured again, and screening.json keeps the original verdict.
screened=$(jq -c '[.ordinary_regressions[] | {host, name}]' "$out/screening.json")
for host in claude codex; do
  set --
  for name in $(printf '%s' "$screened" | jq -r --arg host "$host" '.[] | select(.host == $host) | .name'); do
    set -- "$@" --case "$name"
  done
  [ "$#" -gt 0 ] || continue
  measure "$host" 21 "$@" > "$out/confirm-$host.json" 2> "$out/confirm-$host.stderr"
done
set --
for host in claude codex; do
  [ ! -f "$out/confirm-$host.json" ] || set -- "$@" "$out/confirm-$host.json"
done
jq -n --argjson screened "$screened" --argjson check_cpu true -f bench/native/confirm.jq "$@" \
  < /dev/null > "$out/confirmation.json"
jq --slurpfile confirmation "$out/confirmation.json" -f bench/fused-output/finalize.jq \
  "$out/screening.json" > "$out/assessment.json"
# Always preserve sub-threshold measurements. The aggregate applies declared
# target and ordinary-path criteria; this step only requires complete evidence.
jq -e '.measurements_complete and all(.all_cases[]; .verified)' "$out/assessment.json"
