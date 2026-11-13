# Confirmation rows for the cases a 9-run screening flagged, measured again
# with 21 fresh alternating pairs. A screened case counts as a regression only
# when its confirmation also exceeds the caller's threshold; callers keep the
# screening rows beside these. Shared runners add off-CPU stalls that move one
# 9-pair median by 6-60% while CPU stays flat; a real cost repeats.
# Input: masking-latency reports (`jq -n -f confirm.jq --argjson screened ...
# --argjson check_cpu ... files`). $screened: [{host, name}] flagged by the
# screening. $check_cpu: whether CPU above 5% also confirms, as in that screening.
def median: sort | .[length / 2 | floor];
def cpu($arm): .resource_usage[$arm] as $r
  | [range(0; $r.user_cpu_seconds.samples | length) as $i
     | $r.user_cpu_seconds.samples[$i] + $r.system_cpu_seconds.samples[$i]] | median;
[inputs | .host as $host | .runs as $runs | .cases[]
 | {host:$host, name, verified, runs:$runs,
    samples_complete:([.seconds.baseline.samples, .seconds.candidate.samples,
                       (.resource_usage.baseline, .resource_usage.candidate
                        | .user_cpu_seconds.samples, .system_cpu_seconds.samples)]
                      | all(type == "array" and length == $runs and all(.[]; type == "number"))),
    latency_change_percent:(100 * (.seconds.candidate.median / .seconds.baseline.median - 1)),
    cpu_change_percent:(100 * (cpu("candidate") / cpu("baseline") - 1))}] as $rows
| ($screened | map({host, name}) | unique) as $wanted
| (($rows | map({host, name}) | sort) == $wanted
   and all($rows[]; .runs == 21 and .samples_complete and .verified == true)) as $complete
| [$rows[] | select(.latency_change_percent > 5 or ($check_cpu and .cpu_change_percent > 5))] as $confirmed
| {complete:$complete, rows:$rows, confirmed:$confirmed,
   passed:($complete and ($confirmed | length) == 0)}
