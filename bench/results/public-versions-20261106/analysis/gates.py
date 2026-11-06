#!/usr/bin/env python3
"""사전에 고정한 10%/5% 판정을 전 조건·전 지표에서 보존한다."""
import csv,json
from pathlib import Path
B=Path(__file__).resolve().parents[1]
d=json.loads((B/'report/data.json').read_text());out=[]
for group_name in ['aggregates','installation_aggregates']:
 for r in d[group_name]:
  for comparison in ['previous','cumulative','optional','cross_variant_baseline']:
   p=r.get(comparison+'_pct')
   if p is None:continue
   higher=r['metric']=='throughput_rps';gain=p if higher else -p
   status='improvement>=10%' if gain>=10 else 'regression>5%' if gain < -5 else 'below-threshold'
   out.append(r|dict(dataset=group_name,comparison=comparison,change_pct=p,gain_pct=gain,status=status))
fields=list(dict.fromkeys(k for r in out for k in r))
with (B/'analysis/changes.csv').open('w') as f:
 w=csv.DictWriter(f,fieldnames=fields);w.writeheader();w.writerows(out)
reg=[r for r in out if r['status']=='regression>5%']
(B/'analysis/regressions.json').write_text(json.dumps(reg,ensure_ascii=False,indent=2)+'\n')
(B/'analysis/threshold-summary.json').write_text(json.dumps(dict(criteria={'improvement_at_least_percent':10,'regression_strictly_above_percent':5},comparisons=len(out),improved=sum(r['status']=='improvement>=10%' for r in out),regressed=len(reg),below_threshold=sum(r['status']=='below-threshold' for r in out),note='Counts cover separate conditions/metrics/comparison types, not independent experiments or a population-average improvement; no percentages averaged. Endpoint direct and seven-version series are kept separate.'),ensure_ascii=False,indent=2)+'\n')
print(len(out),len(reg))
