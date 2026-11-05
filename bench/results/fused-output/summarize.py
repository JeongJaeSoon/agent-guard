#!/usr/bin/env python3
"""모든 원시 표본을 보존한 채 scanner별 판정과 RSS/처리량을 집계한다."""
import itertools, json, pathlib, statistics, sys
root=pathlib.Path(sys.argv[1])
rows=[];jobs=[];load=[]
for folder in sorted(root.glob('fused-performance-*')):
    scanner, audit=folder.name.removeprefix('fused-performance-').rsplit('-',1)
    paths=list(folder.rglob('assessment.json'))
    if not paths:
        jobs.append(dict(scanner=scanner,audit=audit,complete=False));continue
    assessment=json.loads(paths[0].read_text())
    jobs.append(dict(scanner=scanner,audit=audit,complete=assessment['measurements_complete']))
    for path in sorted(folder.rglob('cli-*.json')):
        report=json.loads(path.read_text())
        assert report['scanner_sha256']==report['candidate_scanner_sha256']
        for case in report['cases']:
            arms={}
            for arm in ['baseline','candidate']:
                values=case['resource_usage'][arm]
                arms[arm]=dict(latency_seconds=case['seconds'][arm]['median'],
                    cpu_seconds=statistics.median([u+s for u,s in zip(values['user_cpu_seconds']['samples'],values['system_cpu_seconds']['samples'])]),
                    max_child_rss_mib=values['max_child_peak_rss_kib']['median']/1024)
            rows.append(dict(scanner=scanner,audit=audit,host=report['host'],name=case['name'],verified=case['verified'],arms=arms,
                latency_change_percent=100*(arms['candidate']['latency_seconds']/arms['baseline']['latency_seconds']-1),
                cpu_change_percent=100*(arms['candidate']['cpu_seconds']/arms['baseline']['cpu_seconds']-1)))
    for workers in [1,4]:
        if audit!='off':continue
        arms={}
        for arm in ['baseline','candidate']:
            values=[json.loads(p.read_text()) for p in folder.rglob(f'load-{workers}-*-{arm}.json')]
            if len(values)!=3:continue
            assert all(v['verified'] for v in values)
            arms[arm]=dict(requests_per_second=statistics.median(v['requests_per_second'] for v in values),
                cpu_seconds=statistics.median(v['user_cpu_seconds']+v['system_cpu_seconds'] for v in values),
                max_child_rss_mib=statistics.median(v['max_child_peak_rss_kib'] for v in values)/1024,
                sampled_rss_sum_mib=statistics.median(v['sampled_process_rss_peak_kib'] for v in values)/1024)
        if arms:load.append(dict(scanner=scanner,workers=workers,arms=arms,requests_per_trial=8))
present={(j['scanner'],j['audit']) for j in jobs if j['complete']}
required=set(itertools.product(['official','stdlib','homebrew'],['off','cold','warm']))
regressions=[r for r in rows if r['name']!='many-replacement-leaves' and (r['latency_change_percent']>5 or r['cpu_change_percent']>5)]
targets=[r for r in rows if r['name']=='many-replacement-leaves']
declared_targets=[r for r in targets if r['scanner']=='stdlib']
complete=present==required and len(rows)==378
result=dict(scope='same scanner in both arms; public v3.7.0 baseline; target stdlib, actual Homebrew extension reported separately',
    measurements_complete=complete,missing_jobs=sorted(required-present),comparison_count=len(rows),
    mismatch_count=sum(not r['verified'] for r in rows),ordinary_regressions=regressions,targets=targets,load=load,
    accepted_performance=(complete and not regressions and all(r['verified'] for r in rows)
        and len(declared_targets)==6 and all(r['latency_change_percent']<=-10 or r['cpu_change_percent']<=-10 for r in declared_targets)),
    all_cases=rows)
(root/'summary.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps({k:result[k] for k in ['measurements_complete','missing_jobs','comparison_count','mismatch_count','ordinary_regressions','accepted_performance']},indent=2))
