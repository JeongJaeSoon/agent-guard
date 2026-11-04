#!/bin/sh
# Experimental evidence collection, not a release qualification or adoption gate.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
cd "$ROOT"
scanner=${1:?absolute scanner required}
prepare=${2:?absolute experimental helper required}
out=${3:?new absolute results directory required}
case "$scanner:$prepare:$out" in /*:/*:/*) ;; *) exit 2 ;; esac
[ ! -e "$out" ] || { echo 'refusing to overwrite evidence' >&2; exit 2; }
mkdir -p "$out"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' 0
mkdir "$stage/public" "$stage/candidate"
curl -fLsS https://github.com/JeongJaeSoon/agent-guard/releases/download/v3.7.0/agent-guard-3.7.0.tar.gz -o "$stage/public.tar.gz"
printf '%s  %s\n' d6ff2d398643f789d0259c782f7760504836f4495471dba613e3abc46dc2bf3d "$stage/public.tar.gz" | sha256sum -c - > "$out/archive-checksum.txt"
tar -xzf "$stage/public.tar.gz" -C "$stage/public"
cp -R plugins/agent-guard/. "$stage/candidate/"
mkdir -p "$stage/candidate/libexec"
# Use the SAME publicly shipped redactor on both sides; only preparation differs.
cp "$stage/public/libexec/agent-guard-redact-x86_64-unknown-linux-musl"* "$stage/candidate/libexec/"
chmod -R a+rX "$stage/public" "$stage/candidate"
chmod 755 "$prepare"
image=agent-guard-output-experiment
docker build --secret id=proxy_ca,src=/etc/ssl/certs/ca-certificates.crt -f bench/native/Dockerfile -t "$image" . > "$out/build.log" 2>&1
docker image inspect "$image" --format '{{.Id}}' > "$out/image-id.txt"
run() {
  docker run --rm --init --network=none --cpus=2 --memory=1g --memory-swap=1g \
    -e AGENT_GUARD_BENCH_CGROUP_ISOLATED=1 \
    -v "$ROOT:/repo:ro" -v "$stage/public:/public:ro" -v "$stage/candidate:/candidate:ro" \
    -v "$scanner:/scanner/gitleaks:ro" -v "$prepare:/prepare:ro" "$image" "$@"
}
limits=$(run sh -c 'cat /sys/fs/cgroup/cpu.max /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory.swap.max')
[ "$(docker info --format '{{.CgroupDriver}}')" != none ] && [ "$limits" = "200000 100000
1073741824
0" ] || { echo 'required resource limits are not enforced' >&2; exit 2; }
printf '%s\n' "$limits" > "$out/enforced-limits.txt"
git rev-parse HEAD > "$out/checkout-sha.txt"
run sh -c 'uname -a; jq --version; /scanner/gitleaks version; sha256sum /public/bin/agent-guard /candidate/bin/agent-guard /public/libexec/agent-guard-redact-x86_64-unknown-linux-musl /candidate/libexec/agent-guard-redact-x86_64-unknown-linux-musl /prepare /scanner/gitleaks /repo/plugins/agent-guard/config/gitleaks.toml' > "$out/environment.txt"
run cat /proc/cpuinfo > "$out/cpuinfo.txt"
run sh bench/native/test-output-prepare-experiment.sh /repo /prepare > "$out/output-corpus.log" 2>&1
for host in claude codex; do
  run agent-guard-devtools masking-latency --binary /candidate/bin/agent-guard \
    --baseline /public/bin/agent-guard --baseline-packaged-native \
    --native-core /candidate/libexec/agent-guard-redact-x86_64-unknown-linux-musl --packaged-native \
    --output-prepare-core /prepare --scanner /scanner/gitleaks --host "$host" --runs 9 \
    --resources --include-boundaries --trace-processes > "$out/cli-$host.json" 2> "$out/cli-$host.log"
done
for workers in 1 4; do
  for repeat in 1 2 3; do
    order='baseline candidate'
    if [ "$repeat" = 2 ]; then order='candidate baseline'; fi
    for backend in $order; do
      if [ "$backend" = baseline ]; then
        run agent-guard-devtools load --binary /public/bin/agent-guard \
          --core /public/libexec/agent-guard-redact-x86_64-unknown-linux-musl --packaged-native \
          --scanner /scanner/gitleaks --workers "$workers" --requests 8 > "$out/load-$workers-$repeat-$backend.json"
      else
        run agent-guard-devtools load --binary /candidate/bin/agent-guard \
          --core /candidate/libexec/agent-guard-redact-x86_64-unknown-linux-musl --packaged-native \
          --output-prepare-core /prepare --scanner /scanner/gitleaks --workers "$workers" --requests 8 > "$out/load-$workers-$repeat-$backend.json"
      fi
    done
  done
done
# The assessment reports a failed experiment without turning collection into a
# release gate. No default or release changes are authorized by collection alone.
jq -s -f bench/native/assess-output-prepare.jq "$out/cli-claude.json" "$out/cli-codex.json" > "$out/assessment.json"
cat "$out/assessment.json"
