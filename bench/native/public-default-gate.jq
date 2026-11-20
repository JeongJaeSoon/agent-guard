# Verdict of the public v3.7.0 comparison in run-packaged.sh. $names lists the
# cases the comparison runs. With $complete_only it only says whether the
# screening is complete and verified, which decides whether a 21-pair
# confirmation may replace a failed screening.
def median: sort | .[length / 2 | floor];
def cpu($arm): .resource_usage[$arm] as $r
  | [range(0; $r.user_cpu_seconds.samples | length) as $i
     | $r.user_cpu_seconds.samples[$i] + $r.system_cpu_seconds.samples[$i]] | median;
(.runs == 9 and ([.cases[].name] | sort) == ($names | sort) and all(.cases[]; .verified == true))
and ($complete_only or all(.cases[];
  .seconds.candidate.median <= .seconds.baseline.median * 1.05
  and cpu("candidate") <= cpu("baseline") * 1.05))
