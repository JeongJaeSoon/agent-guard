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

# Confirmation of screened regressions (bench/native/confirm.jq and the fused
# finalize step): fresh 21-pair rows decide, and incomplete evidence never passes.
jq -n '
  def n($v): [range(0;21) | $v];
  def usage($cpu): {user_cpu_seconds:{samples:n($cpu)},system_cpu_seconds:{samples:n(1)}};
  def row($name;$latency;$cpu): {name:$name,verified:true,
    seconds:{baseline:{median:10,samples:n(10)},candidate:{median:$latency,samples:n($latency)}},
    resource_usage:{baseline:usage(3),candidate:usage($cpu)}};
  {host:"codex",runs:21,cases:[row("escaped-control";10.1;3)]}' > "$case_dir/confirm.json"
jq -n '{measurements_complete:true,
  targets:[{host:"codex",name:"many-replacement-leaves",verified:true,latency_change_percent:-20,cpu_change_percent:-15}],
  ordinary_regressions:[{host:"codex",name:"escaped-control",verified:true,latency_change_percent:27,cpu_change_percent:-5}],
  all_cases:[{verified:true}],performance_accepted:false}' > "$case_dir/screening.json"
confirm() {
  jq "$2" "$case_dir/confirm.json" > "$case_dir/confirm-changed.json"
  jq "$3" "$case_dir/screening.json" > "$case_dir/screening-changed.json"
  jq -n --argjson screened "$(jq -c '[.ordinary_regressions[] | {host, name}]' "$case_dir/screening-changed.json")" \
    --argjson check_cpu "$4" -f "$ROOT/bench/native/confirm.jq" "$case_dir/confirm-changed.json" \
    < /dev/null > "$case_dir/confirmation.json"
  jq --slurpfile confirmation "$case_dir/confirmation.json" -f "$ROOT/bench/fused-output/finalize.jq" \
    "$case_dir/screening-changed.json" > "$case_dir/final.json"
  got="$(jq -r '.passed' "$case_dir/confirmation.json") $(jq -r '.performance_accepted' "$case_dir/final.json")"
  [ "$got" = "$5 $6" ] || { echo "confirmation $1: expected $5 $6, got $got" >&2; exit 1; }
  jq -e '.screened_regressions | length == 1' "$case_dir/final.json" >/dev/null \
    || { echo "confirmation $1 dropped the screening rows" >&2; exit 1; }
  printf 'ok - synthetic confirmation %s gives %s, fused verdict %s\n' "$1" "$5" "$6"
}
confirm noise-not-repeated . . true true true
confirm latency-repeated '.cases[0].seconds.candidate.median=10.6' . true false false
confirm cpu-repeated '.cases[0].resource_usage.candidate.user_cpu_seconds.samples|=map(3.3)' . true false false
confirm cpu-ignored-when-latency-only '.cases[0].resource_usage.candidate.user_cpu_seconds.samples|=map(3.3)' . false true true
confirm too-few-samples '.cases[0].seconds.candidate.samples|=.[:1]' . true false false
confirm empty-system-cpu '.cases[0].resource_usage.candidate.system_cpu_seconds.samples=[]' . true false false
confirm missing-confirmation '.cases=[]' . true false false
confirm short-confirmation '.runs=9' . true false false
confirm unverified-confirmation '.cases[0].verified=false' . true false false
confirm unrequested-case '.cases+=[.cases[0]|.name="exec-clean"]' . true false false
confirm wrong-host '.host="claude"' . true false false
confirm missed-target . '.targets[0].latency_change_percent=-5|.targets[0].cpu_change_percent=-5' true true false
# Nothing screened: no confirmation file, the screening verdict stands.
jq -n --argjson screened '[]' --argjson check_cpu true -f "$ROOT/bench/native/confirm.jq" < /dev/null > "$case_dir/confirmation.json"
jq '.ordinary_regressions=[]' "$case_dir/screening.json" > "$case_dir/screening-changed.json"
jq --slurpfile confirmation "$case_dir/confirmation.json" -f "$ROOT/bench/fused-output/finalize.jq" \
  "$case_dir/screening-changed.json" | jq -e '.performance_accepted and .measurements_complete' >/dev/null \
  || { echo 'confirmation without screened regressions changed the verdict' >&2; exit 1; }
printf 'ok - synthetic confirmation nothing-screened keeps the screening verdict\n'
printf 'passed: synthetic verdict calculator tests (not performance measurements)\n'
