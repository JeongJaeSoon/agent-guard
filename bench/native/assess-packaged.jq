def require($ok; $message): if $ok then . else error($message) end;
def median: sort | .[length / 2 | floor];
def change($a; $b): 100 * ($b / $a - 1);
def cpu($r; $backend):
  $r.resource_usage[$backend] as $u
  | [range(0; $u.user_cpu_seconds.samples|length) as $i
     | $u.user_cpu_seconds.samples[$i] + $u.system_cpu_seconds.samples[$i]] | median;
def row($host; $r):
  {host:$host, name:$r.name,
   latency_change_percent:change($r.seconds.baseline.median; $r.seconds.candidate.median),
   cpu_change_percent:change(cpu($r; "baseline"); cpu($r; "candidate")),
   max_child_peak_rss_change_percent:change($r.resource_usage.baseline.max_child_peak_rss_kib.median; $r.resource_usage.candidate.max_child_peak_rss_kib.median)};
.[0] as $claude | .[1] as $codex | .[2] as $clean | .[3] as $control
| .[4] as $kernel | .[5] as $diff | .[6] as $hosts | .[7:] as $loads
| require(length == 19; "incomplete measurement set")
| require($diff.passed == 1024 and $diff.failed == 0 and $hosts.passed == 90 and $hosts.failed == 0 and $hosts.native_invocation_verified; "correctness gate failed")
| require(($claude.cases|length) == 21 and ($codex.cases|length) == 3 and ($control.cases|length) == 3 and ($clean.cases|length) == 1; "missing CLI cases")
| require(all([$claude,$codex,$control,$kernel,$clean][]; all(.cases[]; .verified == true)); "unverified output")
| require(all([$claude,$codex,$control,$clean][]; .binary_sha256 == $claude.binary_sha256 and .scanner_sha256 == $claude.scanner_sha256 and .config_sha256 == $claude.config_sha256); "source/scanner/config mismatch")
| require(all([$claude,$codex,$clean][]; .native_core_sha256 == $kernel.native_sha256 and .native_dispatch == "packaged-checksum"); "not the qualified packaged helper")
| require($claude.runs == 9 and $codex.runs == 9 and $control.runs == 9 and $clean.runs == 21; "unexpected sample counts")
| require(all($loads[]; .verified == true and .requests == 8 and .cgroup_isolated == true and .container_cgroup["cpu.max"] == "200000 100000" and .container_cgroup["memory.max"] == "1073741824"); "load limits or verification missing")
| [($claude.cases[] | row("claude"; .)), ($codex.cases[] | row("codex"; .))] as $initial
# This clean-input follow-up is scheduled before observing any measurements.
# Retain initial rows and record the replacement explicitly; never hide them.
| row("claude"; $clean.cases[0]) as $followup
| require($followup.name == "small-clean"; "wrong clean follow-up")
| [$initial[] | if .host == "claude" and .name == "small-clean" then $followup else . end] as $rows
| [$rows[] | select(.latency_change_percent > 5)] as $regressions
| [$rows[] | select(.name == "many-replacement-leaves")] as $hot
| {performance_gate_passed:(($hot|length) == 2 and all($hot[]; .latency_change_percent <= -10 or .cpu_change_percent <= -10) and ($regressions|length) == 0),
   limits:{cpu:2, memory_bytes:1073741824, swap_bytes:0},
   source_sha256:$claude.binary_sha256, scanner_sha256:$claude.scanner_sha256,
   initial_cli:$initial, clean_followup:$followup, evaluated_cli:$rows,
   latency_regressions_over_5_percent:$regressions,
   shell_control:[$control.cases[] | row("control"; .)],
   load:[$loads | group_by([.workers,.backend])[]
     | {workers:.[0].workers,backend:.[0].backend,
        requests_per_second:([.[].requests_per_second]|median),
        cpu_seconds_per_request:([.[]|(.user_cpu_seconds+.system_cpu_seconds)/.requests]|median),
        sampled_sum_rss_mib:([.[].sampled_process_rss_peak_kib/1024]|median),
        max_child_peak_rss_mib:([.[].max_child_peak_rss_kib/1024]|median)}],
   limitations:["RSS sum is sampled every 10 ms and can double-count shared pages or miss peaks", "Child peak RSS is not concurrent process-tree memory", "Linux x64 performance is not a measured speedup for other platforms", "Passing this metric gate does not imply final CI or public release verification"]}
