def median: sort | if length % 2 == 1 then .[length / 2 | floor] else (.[length / 2 - 1] + .[length / 2]) / 2 end;
def cpu($backend):
  .resource_usage[$backend] as $r
  | [range(0; $r.user_cpu_seconds.samples | length) as $i
     | $r.user_cpu_seconds.samples[$i] + $r.system_cpu_seconds.samples[$i]] | median;
[.[] | .host as $host | .cases[] |
  {host: $host, name, verified,
   latency_change_percent: (100 * (.seconds.candidate.median / .seconds.baseline.median - 1)),
   cpu_change_percent: (100 * (cpu("candidate") / cpu("baseline") - 1))}] as $rows
| ($rows | map(select(.name == "many-replacement-leaves"))) as $targets
| ($rows | map(select(.name != "many-replacement-leaves" and
    (.latency_change_percent > 5 or .cpu_change_percent > 5)))) as $regressions
| {targets: $targets, ordinary_regressions: $regressions, all_cases: $rows,
   accepted: (($targets | length) == 2 and
     all($targets[]; .latency_change_percent <= -10 or .cpu_change_percent <= -10) and
     ($regressions | length) == 0 and all($rows[]; .verified)),
   scope: "explicit experimental preparation; public v3.7.0 redactor bytes on both sides; no release/default change"}
