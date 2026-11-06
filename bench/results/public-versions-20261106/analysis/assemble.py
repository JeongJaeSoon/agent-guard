#!/usr/bin/env python3
"""고정 최종 CI 자료만 결합. 이전 취소 배치는 성능 집계에 포함하지 않는다."""
import argparse,csv,hashlib,json
from pathlib import Path

def read(p):
 s=p.read_text()
 try:return json.loads(s)
 except json.JSONDecodeError:return [json.loads(x) for x in s.splitlines() if x.strip()]
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def dump(p,x):p.write_text(json.dumps(x,ensure_ascii=False,indent=2)+'\n')
def main():
 p=argparse.ArgumentParser();p.add_argument('--ci-roots',nargs='+',required=True);p.add_argument('--out',required=True);p.add_argument('--local-install');p.add_argument('--ci-correctness');p.add_argument('--require-complete',action='store_true');p.add_argument('--runtime-policy',choices=['common','shipped'],default='common');p.add_argument('--local-correctness');a=p.parse_args();out=Path(a.out);out.mkdir(parents=True,exist_ok=True);runtime=[];install=[];correctness=[];other=[];sources=[];seen=set()
 for root in map(Path,a.ci_roots):
  run_id=root.parent.name if root.name=='extracted' else root.name
  # Only extracted artifact trees, never duplicate .zip or previous attempts.
  for file in sorted(root.rglob('samples.jsonl')):
   if 'runtime' not in file.parts:continue
   file_sha=sha(file)
   for i,row in enumerate(read(file),1):
    if not row.get('environment','').startswith('linux-ci-'):continue
    if row.get('policy_mode','shipped')!=a.runtime_policy:raise ValueError('policy cohort mismatch; refuse pooling '+str(file))
    row=row|dict(raw_source=str(file),raw_line=i,raw_source_sha256=file_sha,run_id=run_id)
    row['sample_id']=hashlib.sha256(json.dumps([row.get(k) for k in ['environment','phase','series','scanner','host','audit','case','version','variant','distribution','workers','round','order']],ensure_ascii=False).encode()).hexdigest()[:20]
    if row['sample_id'] in seen:raise ValueError('duplicate sample '+row['sample_id'])
    seen.add(row['sample_id']);runtime.append(row)
   sources.append(dict(kind='runtime',path=str(file),sha256=sha(file)))
  for file in sorted(root.rglob('results-*.json')):
   if 'installation' not in file.parts:continue
   value=read(file)
   if isinstance(value,list) and value and 'scenario' in value[0]:
    for i,row in enumerate(value,1):install.append(row|dict(raw_source=str(file),raw_row=i,run_id=run_id))
    sources.append(dict(kind='installation',path=str(file),sha256=sha(file)))
  for file in sorted(root.rglob('results.json')):
   if 'correctness' not in file.parts:continue
   doc=read(file)
   if not isinstance(doc,dict):continue
   if 'rows' in doc and all('host' in row and 'case' in row for row in doc['rows']):
    env=doc.get('label',file.parent.name)
    for i,row in enumerate(doc['rows'],1):correctness.append(row|dict(environment=env,raw_source=str(file),raw_row=i,run_id=run_id))
   else:other.append(dict(path=str(file),sha256=sha(file),data=doc))
   sources.append(dict(kind='correctness',path=str(file),sha256=sha(file)))
 if a.ci_correctness:
  correctness=read(Path(a.ci_correctness))['rows']
 if a.local_install:
  for row in read(Path(a.local_install)):install.append(row|dict(raw_source=a.local_install,cohort='local-supplement'))
 if a.local_correctness:
  doc=read(Path(a.local_correctness));cr=doc.get('rows',doc) if isinstance(doc,dict) else doc
  for row in cr:correctness.append(row|dict(raw_source=a.local_correctness,cohort='local-supplement',eligible=not row.get('oracle_invalid',False)))
 if a.require_complete:
  profiles={(r['scanner'],r['host']) for r in runtime}
  if profiles!={(s,h) for s in ['official','homebrew'] for h in ['claude','codex']}:raise ValueError('four complete primary profiles required')
  for scanner,host in profiles:
   samples=[r for r in runtime if r['scanner']==scanner and r['host']==host]
   if len(samples)!=2939:raise ValueError('frozen full controlled profile must contain 2939 rows')
   for key in ['scanner_sha256','config_sha256','deny_bash_sha256','deny_read_sha256']:
    if len({r[key] for r in samples})!=1:raise ValueError('effective bytes differ within profile: '+key)
 for name,rows in [('runtime',runtime),('installation',install),('correctness',correctness)]:
  dump(out/(name+'.json'),rows)
  fields=list(dict.fromkeys(k for r in rows for k in r))
  with (out/(name+'.csv')).open('w') as f:
   w=csv.DictWriter(f,fieldnames=fields);w.writeheader();w.writerows({k:json.dumps(v,ensure_ascii=False) if isinstance(v,(dict,list)) else v for k,v in r.items()} for r in rows)
 dump(out/'supplementary-correctness.json',other);dump(out/'source-index.json',sources)
 dump(out/'assembly-validation.json',dict(runtime_rows=len(runtime),runtime_samples_unique=len(seen),installation_rows=len(install),correctness_rows=len(correctness),ci_roots=a.ci_roots,excluded_previous_cancelled_runs=['42223034457','42223821896','42223821927','42223821933','42224583938','42224583990'],raw_files=len(sources)))
 print(len(runtime),len(install),len(correctness))
if __name__=='__main__':main()
