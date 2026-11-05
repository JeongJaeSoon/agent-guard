from pathlib import Path
import json,statistics,sys
root=Path(sys.argv[1]);median=statistics.median
allrows=[];raw={}
files=sorted(root.glob('[123]-*-*.json'));assert len(files)==24, (root,len(files))
for p in files:
 trial,kind,scheduling,host=p.stem.split('-');report=json.loads(p.read_text());assert report['runs']==9
 assert len(report['cases'])==5 and all(c['verified'] for c in report['cases'])
 if kind=='aa':assert report['binary_sha256']['baseline']==report['binary_sha256']['candidate'] and not report['fused_output']
 for c in report['cases']:
  entry={'trial':int(trial),'kind':kind,'scheduling':scheduling,'host':host,'name':c['name'],'arms':{}}
  for arm in ['baseline','candidate']:
   r=c['resource_usage'][arm];cpu=[u+s for u,s in zip(r['user_cpu_seconds']['samples'],r['system_cpu_seconds']['samples'])]
   entry['arms'][arm]={'latency':c['seconds'][arm]['median'],'cpu':median(cpu),'throttled_samples':sum(v>0 for v in r['cgroup_nr_throttled']['samples']),'throttled_usec_median':r['cgroup_throttled_usec']['median']}
   key=(kind,scheduling,host,c['name'],arm)
   accum=raw.setdefault(key,{'latency':[],'cpu':[],'throttled':[]})
   accum['latency']+=c['seconds'][arm]['samples'];accum['cpu']+=cpu;accum['throttled']+=r['cgroup_throttled_usec']['samples']
  for field in ['latency','cpu']:entry[field+'_change_percent']=100*(entry['arms']['candidate'][field]/entry['arms']['baseline'][field]-1)
  allrows.append(entry)
pooled=[]
for kind,scheduling,host,name,arm in raw:
 if arm!='baseline':continue
 entry={'kind':kind,'scheduling':scheduling,'host':host,'name':name,'samples_per_arm':27,'arms':{}}
 for a in ['baseline','candidate']:
  v=raw[(kind,scheduling,host,name,a)];assert len(v['latency'])==27
  entry['arms'][a]={f:median(v[f]) for f in ['latency','cpu','throttled']}
 for f in ['latency','cpu']:entry[f+'_change_percent']=100*(entry['arms']['candidate'][f]/entry['arms']['baseline'][f]-1)
 pooled.append(entry)
summary={'scope':'fixed A/A negative controls and attribution A/B; 3 blocks of 9 pairs; original results retained; whole-cgroup throttle counters are not CLI CPU','comparison_count':len(allrows),'cli_runs':len(allrows)*18,'rows':allrows,'pooled_27':pooled,'groups':[]}
for kind in ['aa','ab']:
 for scheduling in ['quota','pinned']:
  rr=[r for r in allrows if r['kind']==kind and r['scheduling']==scheduling]
  group={'kind':kind,'scheduling':scheduling,'comparisons':len(rr),'positive_5pct_excursions':[r for r in rr if (kind=='aa' or r['name']!='many-replacement-leaves') and (r['latency_change_percent']>5 or r['cpu_change_percent']>5)],'absolute_5pct_excursions':sum(abs(r['latency_change_percent'])>5 or abs(r['cpu_change_percent'])>5 for r in rr)}
  summary['groups'].append(group)
(root.parent/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
for g in summary['groups']:
 print(g['kind'],g['scheduling'],'positive',len(g['positive_5pct_excursions']),'absolute',g['absolute_5pct_excursions'],'of',g['comparisons'])
 for r in g['positive_5pct_excursions']:print(' ',r['trial'],r['host'],r['name'],'lat',round(r['latency_change_percent'],2),'cpu',round(r['cpu_change_percent'],2),'throttle',[r['arms'][a]['throttled_samples'] for a in ['baseline','candidate']])
print('pooled 27')
for r in pooled:print(r['kind'],r['scheduling'],r['host'],r['name'],round(r['latency_change_percent'],2),round(r['cpu_change_percent'],2))
