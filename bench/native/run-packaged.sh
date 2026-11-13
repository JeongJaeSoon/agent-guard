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
# Keep the original pre-native control, and separately qualify ordinary default
# dispatch against the actual public v3.7.0 payload with its packaged core.
mkdir "$case_dir/public"
curl -fsSL https://github.com/JeongJaeSoon/agent-guard/releases/download/v3.7.0/agent-guard-3.7.0.tar.gz -o "$case_dir/public.tar.gz"
printf '%s  %s\n' d6ff2d398643f789d0259c782f7760504836f4495471dba613e3abc46dc2bf3d "$case_dir/public.tar.gz" | sha256sum -c - > "$out/public-checksum.txt"
tar -xzf "$case_dir/public.tar.gz" -C "$case_dir/public"
chmod -R a+rX "$case_dir/public"
image=agent-guard-packaged-qualification
docker build --secret id=proxy_ca,src=/etc/ssl/certs/ca-certificates.crt \
  -f bench/native/Dockerfile -t "$image" . > "$out/build.log" 2>&1
docker image inspect "$image" --format '{{.Id}}' > "$out/image-id.txt"
docker info --format '{{json .}}' > "$out/docker-info.json"
run() {
  docker run --rm --init --network=none --cpus=2 --memory=1g --memory-swap=1g \
    -e AGENT_GUARD_BENCH_CGROUP_ISOLATED=1 \
    -v "$ROOT:/repo:ro" -v "$case_dir/baseline:/baseline:ro" -v "$scanner:/scanner/gitleaks:ro" \
    -v "$case_dir/public:/public:ro" \
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
legacy_status=0
sh bench/native/assess-packaged.sh "$out" || legacy_status=$?
# Predeclared confirmation (see bench/native/confirm.jq): a screened latency
# regression stands only if 21 fresh pairs repeat it. assessment.json keeps the
# screening verdict; legacy-confirmation.json holds the confirmed one. Missing
# target improvement or broken evidence is never re-measured.
if [ "$legacy_status" -ne 0 ] && legacy_screened=$(jq -ce '
    [.evaluated_cli[] | select(.name == "many-replacement-leaves")] as $hot
    | if ($hot | length) == 2
         and all($hot[]; .latency_change_percent <= -10 or .cpu_change_percent <= -10)
         and (.latency_regressions_over_5_percent | length) > 0
      then [.latency_regressions_over_5_percent[] | {host, name}] else false end
  ' "$out/assessment.json" 2>/dev/null); then
  for host in claude codex; do
    set --
    for name in $(printf '%s' "$legacy_screened" | jq -r --arg host "$host" '.[] | select(.host == $host) | .name'); do
      set -- "$@" --case "$name"
    done
    [ "$#" -gt 0 ] || continue
    run agent-guard-devtools masking-latency --baseline "$old" --native-core "$core" --packaged-native \
      --scanner /scanner/gitleaks --runs 21 --resources --include-boundaries --host "$host" "$@" \
      > "$out/legacy-confirm-$host.json" 2> "$out/legacy-confirm-$host.log"
  done
  set --
  for host in claude codex; do
    [ ! -f "$out/legacy-confirm-$host.json" ] || set -- "$@" "$out/legacy-confirm-$host.json"
  done
  jq -n --argjson screened "$legacy_screened" --argjson check_cpu false -f bench/native/confirm.jq "$@" \
    < /dev/null > "$out/legacy-confirmation.json"
  jq -e '.passed' "$out/legacy-confirmation.json" && legacy_status=0
fi
public_status=0
run agent-guard-devtools masking-latency --baseline /public/bin/agent-guard \
  --baseline-packaged-native --native-core "$core" --packaged-native \
  --scanner /scanner/gitleaks --runs 9 --resources --include-boundaries \
  --case exec-clean --case exec-multiline --case exec-long-quoted-secret \
  --case pre-unknown-tool > "$out/cli-public-default.json" 2> "$out/cli-public-default.log" || public_status=$?
if [ "$public_status" -eq 0 ]; then
jq -e '
  def median: sort | .[length / 2 | floor];
  def cpu($arm): .resource_usage[$arm] as $r
    | [range(0; $r.user_cpu_seconds.samples | length) as $i
       | $r.user_cpu_seconds.samples[$i] + $r.system_cpu_seconds.samples[$i]] | median;
  .runs == 9 and (.cases | length) == 4 and all(.cases[];
    .verified and .seconds.candidate.median <= .seconds.baseline.median * 1.05
    and cpu("candidate") <= cpu("baseline") * 1.05)
' "$out/cli-public-default.json" > "$out/public-default-gate.txt" || public_status=$?
fi
# The same confirmation for the public-default comparison, after a complete and
# verified screening only.
if [ "$public_status" -ne 0 ] \
  && jq -e '.runs == 9 and (.cases | length) == 4 and all(.cases[]; .verified == true)' \
    "$out/cli-public-default.json" > /dev/null 2>&1 \
  && public_screened=$(jq -n --argjson screened '[]' --argjson check_cpu true -f bench/native/confirm.jq \
      "$out/cli-public-default.json" < /dev/null \
    | jq -ce '[.confirmed[] | {host, name}] | if length > 0 then . else false end'); then
  set --
  for name in $(printf '%s' "$public_screened" | jq -r '.[].name'); do
    set -- "$@" --case "$name"
  done
  run agent-guard-devtools masking-latency --baseline /public/bin/agent-guard \
    --baseline-packaged-native --native-core "$core" --packaged-native \
    --scanner /scanner/gitleaks --runs 21 --resources --include-boundaries "$@" \
    > "$out/public-default-confirm.json" 2> "$out/public-default-confirm.log"
  jq -n --argjson screened "$public_screened" --argjson check_cpu true -f bench/native/confirm.jq \
    "$out/public-default-confirm.json" < /dev/null > "$out/public-default-confirmation.json"
  jq -e '.passed' "$out/public-default-confirmation.json" && public_status=0
fi
[ "$legacy_status" -eq 0 ] && [ "$public_status" -eq 0 ]
