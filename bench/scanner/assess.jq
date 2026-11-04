def median: sort | .[length / 2 | floor];
def cpu($arm): .resource_usage[$arm] as $r
  | [range(0; $r.user_cpu_seconds.samples | length) as $i
     | $r.user_cpu_seconds.samples[$i] + $r.system_cpu_seconds.samples[$i]] | median;
all(.[]; .runs == 9) as $expected_runs
| [.[] | .host as $host | .audit_state as $audit | .cases[] |
 {host:$host, audit_state:$audit, name, verified,
  latency_change_percent:(100 * (.seconds.candidate.median / .seconds.baseline.median - 1)),
  cpu_change_percent:(100 * (cpu("candidate") / cpu("baseline") - 1))}] as $rows
| ($rows | map(select(.name == "many-replacement-leaves"))) as $targets
| ($rows | map(select(.name != "many-replacement-leaves" and (.latency_change_percent > 5 or .cpu_change_percent > 5)))) as $regressions
| ($expected_runs and ($targets | length) == $expected_targets
   and ($rows | length) == ($expected_targets * 21)
   and ($rows | map([.host,.audit_state,.name]) | unique | length) == ($expected_targets * 21)) as $complete
| {measurements_complete:$complete, targets:$targets, ordinary_regressions:$regressions, all_cases:$rows,
   performance_accepted:($complete and all($targets[]; .latency_change_percent <= -10 or .cpu_change_percent <= -10) and ($regressions | length) == 0 and all($rows[]; .verified)),
   scope:"same public Agent Guard; changed scanner dependency; correctness and deployment qualification remain separate"}
