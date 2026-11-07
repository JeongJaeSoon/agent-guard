#!/usr/bin/env python3
"""Independent median/IQR summary of immutable CI installation evidence."""
import argparse,collections,csv,json,pathlib,statistics
P=pathlib.Path
VERSIONS=['3.6.13','3.6.14','3.6.15','3.7.0','3.7.1','3.8.0','3.8.1']
def main():
 ap=argparse.ArgumentParser();ap.add_argument('--source',required=True);ap.add_argument('--out',required=True);a=ap.parse_args();source=P(a.source);out=P(a.out);out.mkdir(parents=True,exist_ok=True)
 rows=[]
 for kind in ['cached','network']:rows+=json.loads((source/'installation'/kind/f'results-{kind}.json').read_text())
 groups=collections.defaultdict(list)
 for r in rows:
  if r['warmup']:continue
  scenario=r['scenario']
  if scenario=='standalone-update-cached' and r.get('from_version')==r['version']:scenario='standalone-reinstall-cached'
  groups[scenario,r['version'],r['environment']].append(r)
 agg=[]
 for (scenario,v,env),rs in groups.items():
  record=dict(scenario=scenario,version=v,environment=env,n=len(rs),successes=sum(r['success'] for r in rs),failures=sum(not r['success'] for r in rs),raw_indices=[rows.index(r) for r in rs])
  for metric in ['wall_s','cpu_s','max_child_rss_kib','installed_bytes','download_bytes','home_delta_bytes']:
   vals=[r[metric] for r in rs if isinstance(r.get(metric),(int,float))]
   if vals:q=statistics.quantiles(vals,n=4,method='inclusive');record[metric+'_median']=statistics.median(vals);record[metric+'_iqr']=q[2]-q[0]
  if scenario=='dependency-scanner-cached':record['new_dependency_bytes_median']=statistics.median(r['home_delta_bytes'] for r in rs)
  agg.append(record)
 for record in agg:
  scenario=record['scenario'];v=record['version'];idx=VERSIONS.index(v)
  previous=next((r for r in agg if r['scenario']==scenario and idx>0 and r['version']==VERSIONS[idx-1]),None)
  baseline=next((r for r in agg if r['scenario']==scenario and r['version']=='3.6.13'),None)
  for metric in ['wall_s','cpu_s','max_child_rss_kib','installed_bytes','download_bytes']:
   key=metric+'_median'
   if key not in record:continue
   for label,ref in [('previous_release',previous),('baseline_3_6_13',baseline)]:
    change=(record[key]/ref[key]-1)*100 if ref and ref.get(key) else None
    record[metric+'_'+label+'_change_percent']=change
    record[metric+'_'+label+'_flag']=('improved>=10%' if change<=-10 else 'regressed>5%' if change>5 else 'within_threshold') if change is not None else 'N/A'
 limits=(source/'provision/applied-limits.txt').read_text().splitlines();assert limits==['200000 100000','1073741824','0']
 assert all(x['n']==9 for x in agg);assert all(r['checksum_match'] for r in rows if r['scenario']=='asset-network-download')
 summary=dict(environment='linux-ci-install-2cpu-1g',limits=dict(cpu_max=limits[0],memory_max=limits[1],memory_swap_max=limits[2]),raw_source=str(source),source_artifact=json.loads((source/'source-artifact.json').read_text()),attempts=len(rows),warmups=sum(r['warmup'] for r in rows),measured=sum(not r['warmup'] for r in rows),failures=sum(not r['success'] for r in rows),aggregates=agg,notes=[
 'Primary installation CI actually applied 2CPU,1GiB,memory.swap.max=0. Host swapfile remains visible in proc/swaps but this cgroup cannot use swap.',
 'cached installer excludes network; transport uses local copy shim, whose Python execution cost is included. Not total cold installation.',
 'network condition measures actual archive-only curl transfer. Its original raw scope string incorrectly repeats the cached-install description; raw bytes are preserved, and scenario/command/schema/checksum distinguish this condition.',
 'Do not sum network median and cached installer median as measured total; no cross-environment break-even arithmetic.',
 'Baseline update is same-version reinstall and has a distinct derived scenario. No cumulative upgrade baseline exists in this sample set.',
 'dependency installed_bytes raw includes48Bpreexisting sentinels; home_delta_bytes is actual new scanner file logical size.',
 'Artifact expiration is source-artifact expires_at (2026-12-06 UTC); compact export run does not rerun measurements.'
 ])
 (out/'ci-summary.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2)+'\n')
 with open(out/'aggregate-ci.csv','w') as f:
  fields=list(dict.fromkeys(k for r in agg for k in r));writer=csv.DictWriter(f,fieldnames=fields);writer.writeheader();writer.writerows(agg)
 print(json.dumps({k:summary[k] for k in ['attempts','warmups','measured','failures','limits']}))
 for r in agg:
  if r['scenario']=='standalone-fresh-cached' and r['version'] in ['3.6.13','3.8.1']:print(json.dumps(r))
if __name__=='__main__':main()
