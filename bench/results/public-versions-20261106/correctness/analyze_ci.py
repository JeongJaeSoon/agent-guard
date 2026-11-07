#!/usr/bin/env python3
"""회수된 CI 원본을 바꾸지 않고 사례별 파생 판정과 집계를 만든다."""
import argparse,collections,csv,hashlib,json
from pathlib import Path

def main():
    p=argparse.ArgumentParser();p.add_argument('--artifacts',required=True);p.add_argument('--out',required=True);a=p.parse_args();base=Path(a.artifacts);out=Path(a.out);out.mkdir(parents=True,exist_ok=True)
    rows=[];summaries=[];framing=[];cores=[];sources=[]
    for source in sorted(base.rglob('results.json')):
        if 'correctness' not in source.parts:continue
        data=json.loads(source.read_text());rawrows=data.get('rows',[])
        if not rawrows:continue
        scope=source.parent.name
        artifact=source
        while artifact.parent!=base and not (artifact/'provision').exists():artifact=artifact.parent
        provision=artifact/'provision';limits=(provision/'applied-limits.txt').read_text().strip() if (provision/'applied-limits.txt').exists() else ''
        verified=limits=='200000 100000\n1073741824\n0'
        environment=data.get('label') or f'linux-ci-{artifact.name}-2cpu-1g-jq171'
        if any('core_sha256' in r or r.get('reason')=='no public native binary' for r in rawrows):
            cores.append({'environment':environment,'scope':scope,'resource_limits_verified':verified,'source':str(source),'rows':rawrows});continue
        sources.append({'source':str(source),'source_sha256':hashlib.sha256(source.read_bytes()).hexdigest(),'environment':environment,'scope':scope,'resource_limits_verified':verified,'n':len(rawrows)})
        if 'fallback' in scope:kind='fault-injection'
        elif 'scanner-config' in scope:kind='scanner-config-only'
        else:kind='cli-independent'
        for original in rawrows:
            r=dict(original);r.update(environment=environment,scope=kind,dataset=scope,source_results=str(source),resource_limits_verified=verified,oracle_invalid=False,included_in_accuracy_count=True,classification_analysis=r.get('classification',''),reason_analysis='')
            if kind=='cli-independent':
                case=r['case'];v=r['version']
                if not r['success'] and case=='snapshot-control' and v in ['v3.6.13','v3.6.14']:
                    r.update(classification_analysis='known-snapshot-token-compatibility-difference',reason_analysis='Valid d<n>:base64 snapshot overmasked before v3.6.15; consistent with 9a0ee9e; not a later-version regression')
                elif not r['success'] and case in ['message-body-fp','commit-message-fp','env-prose-fp'] and v!='v3.8.1':
                    r.update(classification_analysis='known-message-body-false-positive',reason_analysis='Fixed synthetic quoted message is data; denied before v3.8.1; consistent with 7a643f4')
                elif not r['success'] and case in ['env-substitution-positive','set-substitution-positive'] and v!='v3.8.1':
                    r.update(classification_analysis='known-env-output-policy-gap',reason_analysis='Expected pre-hook exit2 but allowed this synthetic env/set substitution; actual shell command was not executed; fixed by v3.8.1 in this corpus')
                elif not r['success'] and 'jq16' in scope and v=='v3.6.13':
                    r.update(classification_analysis='known-jq16-nul-overmasking',reason_analysis='Secondary jq1.6: clean strings overmasked before v3.6.14; not same-work speedup')
                if r.get('raw_path'):
                    raw=source.parent/Path(r['raw_path']).name;err=(raw/'stderr').read_bytes() if (raw/'stderr').exists() else b''
                    if b'gitleaks version command timed out after 2s' in err:
                        r.update(classification_analysis='scanner-readiness-timeout-2s',reason_analysis='Actual scanner internal readiness timeout, preserved without retry/timeout increase')
                    if case.startswith('scanner-failure-'):
                        stdout=(raw/'stdout').read_bytes();valid=True
                        if stdout.strip():
                            try:doc=json.loads(stdout);valid=isinstance(doc,dict) and isinstance(doc.get('hookSpecificOutput'),dict)
                            except (ValueError,UnicodeDecodeError):valid=False
                        framing.append({'environment':environment,'version':v,'variant':r.get('variant'),'host':r.get('host'),'case':case,'single_json_object_or_empty':valid,'source':str(raw/'stdout')})
            elif kind=='fault-injection' and not r['success'] and r['case']=='prepare-partial-success':
                r.update(classification_analysis='trusted-override-false-success-passthrough',reason_analysis='User-selected arbitrary prepare helper intentionally returned prepared-v1/status0 with false partial data. Original synthetic sensitive output passed through; not a failed verified public native binary or ordinary default-path regression.')
            elif kind=='scanner-config-only' and not r['success'] and r['case']=='orca-repo-id' and r['version']!='v3.8.1':
                r.update(classification_analysis='known-repository-id-scanner-false-positive',reason_analysis='Packaged config scanner-only control: unquoted lowercase --repo id:UUID incorrectly found before v3.8.1; neighboring credential positives retained')
            rows.append(r)
        groups=collections.defaultdict(list)
        for r in rows:
            if r['source_results']==str(source):groups[(r['version'],r.get('variant','scanner-only'))].append(r)
        for (version,variant),group in groups.items():
            summaries.append(dict(environment=environment,scope=kind,dataset=scope,version=version,variant=variant,n=len(group),passed=sum(r['success'] for r in group),failed=sum(not r['success'] for r in group),classifications=dict(collections.Counter(r['classification_analysis'] for r in group)),source=str(source)))
    (out/'ci-analysis.json').write_text(json.dumps({'scope':'Derived metadata only; exact raw CI originals unchanged','sources':sources,'rows':rows},ensure_ascii=False,indent=2)+'\n')
    (out/'ci-summary.json').write_text(json.dumps({'groups':summaries,'existing_core_corpus':cores,'failure_stdout_framing':{'n':len(framing),'passed':sum(r['single_json_object_or_empty'] for r in framing),'failed':sum(not r['single_json_object_or_empty'] for r in framing),'rows':framing}},ensure_ascii=False,indent=2)+'\n')
    if rows:
        keys=list(dict.fromkeys(k for r in rows for k in r))
        with (out/'ci-analysis.csv').open('w') as f:
            w=csv.DictWriter(f,fieldnames=keys);w.writeheader();w.writerows(rows)
    print('sources',len(sources),'rows',len(rows),'groups',len(summaries),'framing',len(framing),'core_sources',len(cores))

if __name__=='__main__':main()
