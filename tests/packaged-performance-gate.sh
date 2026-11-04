#!/bin/sh
# Synthetic unit fixtures for the verdict calculator, never benchmark evidence.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
case_dir=$(mktemp -d)
trap 'rm -rf "$case_dir"' 0
jq -n '
  def usage: {user_cpu_seconds:{samples:[3,3,3]},system_cpu_seconds:{samples:[1,1,1]},max_child_peak_rss_kib:{median:100}};
  def row($name;$candidate): {name:$name,verified:true,seconds:{baseline:{median:10},candidate:{median:$candidate}},resource_usage:{baseline:usage,candidate:usage}};
  {binary_sha256:{baseline:"synthetic-old",candidate:"synthetic-new"},scanner_sha256:"synthetic-scanner",config_sha256:"synthetic-config",native_core_sha256:"synthetic-core",native_dispatch:"packaged-checksum",runs:9,
   cases:([row("small-clean";10),row("many-replacement-leaves";8)] + [range(0;19)|row("ordinary-"+tostring;10)])} as $cli
  | [$cli, ($cli|.cases=.cases[:3]), ($cli|.runs=21|.cases=.cases[:1]), ($cli|.cases=.cases[:3]),
     {native_sha256:"synthetic-core",cases:[{verified:true}]},
     {passed:1024,failed:0}, {passed:90,failed:0,native_invocation_verified:true}]
    + [range(0;12)|{workers:(if .<6 then 1 else 4 end),backend:(if .%2==0 then "shell" else "rust" end),verified:true,requests:8,cgroup_isolated:true,container_cgroup:{"cpu.max":"200000 100000","memory.max":"1073741824"},requests_per_second:2,user_cpu_seconds:3,system_cpu_seconds:1,sampled_process_rss_peak_kib:1024,max_child_peak_rss_kib:512}]
' > "$case_dir/synthetic.json"
jq -f "$ROOT/bench/native/assess-packaged.jq" "$case_dir/synthetic.json" > "$case_dir/verdict"
jq -e '.performance_gate_passed and (.evaluated_cli[]|select(.name=="many-replacement-leaves")|.latency_change_percent < -19.99 and .latency_change_percent > -20.01)' "$case_dir/verdict" >/dev/null
reject() {
  jq "$2" "$case_dir/synthetic.json" > "$case_dir/changed.json"
  if jq -f "$ROOT/bench/native/assess-packaged.jq" "$case_dir/changed.json" > "$case_dir/verdict" 2> "$case_dir/err" \
      && jq -e '.performance_gate_passed' "$case_dir/verdict" >/dev/null; then
    echo "performance gate accepted $1" >&2; exit 1
  fi
  printf 'ok - synthetic gate rejects %s\n' "$1"
}
reject ordinary-regression '.[0].cases[2].seconds.candidate.median=10.6'
reject insufficient-improvement '.[0].cases[1].seconds.candidate.median=9.5'
reject source-mismatch '.[1].binary_sha256.candidate="wrong"'
reject missing-case '.[0].cases|=.[1:]'
reject output-mismatch '.[0].cases[0].verified=false'
reject ineffective-limits '.[7].container_cgroup["cpu.max"]="max 100000"'
reject wrong-dispatch '.[1].native_dispatch="explicit-override"'
printf 'passed: synthetic verdict calculator tests (not performance measurements)\n'
