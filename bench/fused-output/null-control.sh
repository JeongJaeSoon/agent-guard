#!/bin/sh
# Fixed negative controls and paired candidate measurements; never retry to pass.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
cd "$ROOT"
scanner=${1:?absolute scanner}
out=${2:?new absolute output directory}
[ ! -e "$out" ]
mkdir -p "$out"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' 0
mkdir "$stage/public"
curl -fsSL https://github.com/JeongJaeSoon/agent-guard/releases/download/v3.7.0/agent-guard-3.7.0.tar.gz -o "$stage/public.tar.gz"
printf '%s  %s\n' d6ff2d398643f789d0259c782f7760504836f4495471dba613e3abc46dc2bf3d "$stage/public.tar.gz" | sha256sum -c - > "$out/public-checksum.txt"
tar -xzf "$stage/public.tar.gz" -C "$stage/public"
chmod -R a+rX "$stage/public"
mkdir -p plugins/agent-guard/libexec
cp "$stage/public/libexec/agent-guard-redact-x86_64-unknown-linux-musl"* plugins/agent-guard/libexec/
image=agent-guard-null-control
docker build --secret id=proxy_ca,src=/etc/ssl/certs/ca-certificates.crt -f bench/native/Dockerfile -t "$image" . > "$out/build.log" 2>&1
docker image inspect "$image" --format '{{.Id}}' > "$out/image-id.txt"
affinity=$(python3 -c 'import os; c=sorted(os.sched_getaffinity(0)); assert len(c)>=2; print(",".join(map(str,c[:2])))')
printf '%s\n' "$affinity" > "$out/pinned-cpus.txt"
run() {
  scheduling=$1; shift
  if [ "$scheduling" = pinned ]; then set -- --cpuset-cpus="$affinity" "$@"; fi
  docker run --rm --init --network=none --cpus=2 --memory=1g --memory-swap=1g \
    -e AGENT_GUARD_BENCH_CGROUP_ISOLATED=1 \
    -v "$stage/public:/public:ro" -v "$scanner:/scanner/gitleaks:ro" \
    -v /home/linuxbrew/.linuxbrew:/home/linuxbrew/.linuxbrew:ro "$@"
}
for scheduling in quota pinned; do
  limits=$(run "$scheduling" "$image" sh -c 'cat /sys/fs/cgroup/cpu.max /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory.swap.max')
  [ "$(docker info --format '{{.CgroupDriver}}')" != none ] && [ "$limits" = "200000 100000
1073741824
0" ]
  printf '%s\n' "$limits" > "$out/limits-$scheduling.txt"
  run "$scheduling" "$image" sh -c 'cat /sys/fs/cgroup/cpuset.cpus.effective; cat /proc/self/status; cat /proc/cpuinfo' > "$out/environment-$scheduling.txt"
done
git rev-parse HEAD > "$out/driver-head.txt"
sha256sum "$scanner" plugins/agent-guard/bin/agent-guard "$stage/public/bin/agent-guard" > "$out/identities.txt"
for trial in 1 2 3; do
  case "$trial" in
    1) order='aa-quota ab-pinned ab-quota aa-pinned' ;;
    2) order='aa-pinned ab-quota ab-pinned aa-quota' ;;
    3) order='ab-quota aa-pinned aa-quota ab-pinned' ;;
  esac
  for group in $order; do
    scheduling=${group#*-}
    candidate=/public/bin/agent-guard
    set --
    case "$group" in
      ab-*) candidate=/repo/plugins/agent-guard/bin/agent-guard
        set -- --fused-output --prepare-core /build/target/release/agent-guard-redact ;;
    esac
    for host in claude codex; do
      run "$scheduling" "$image" agent-guard-devtools masking-latency \
        --baseline /public/bin/agent-guard --binary "$candidate" \
        --baseline-packaged-native --native-core /public/libexec/agent-guard-redact-x86_64-unknown-linux-musl --packaged-native \
        --scanner /scanner/gitleaks --audit-state off --host "$host" \
        --runs 9 --resources --cgroup-stats --include-boundaries \
        --case exec-over-cap-8388608 --case exec-long-quoted-secret \
        --case pre-read-clean --case small-clean --case many-replacement-leaves "$@" \
        > "$out/$trial-$group-$host.json" 2> "$out/$trial-$group-$host.stderr"
      # Collection validity only. A/A threshold excursions are evidence.
      jq -e '.runs == 9 and (.cases|length)==5 and all(.cases[]; .verified)' "$out/$trial-$group-$host.json"
      case "$group" in aa-*) jq -e '.binary_sha256.baseline == .binary_sha256.candidate and .fused_output == false' "$out/$trial-$group-$host.json" ;; esac
    done
  done
done
