# Input: the bench/scanner/assess.jq screening. $confirmation: bench/native/confirm.jq
# output for its ordinary_regressions. The screening rows stay in the result.
$confirmation[0] as $c
| .screened_regressions = .ordinary_regressions
| .confirmation = $c
| .ordinary_regressions = $c.confirmed
| .measurements_complete = (.measurements_complete and $c.complete)
| .performance_accepted = (.measurements_complete
    and all(.targets[]; .latency_change_percent <= -10 or .cpu_change_percent <= -10)
    and ($c.confirmed | length) == 0 and all(.all_cases[]; .verified))
