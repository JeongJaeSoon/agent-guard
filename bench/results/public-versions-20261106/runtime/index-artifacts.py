#!/usr/bin/env python3
"""Verify locally recovered source ZIPs; never run a measurement or change samples."""
import argparse,csv,hashlib,json
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]

def expected():
    out=[]
    for scanner in ['official','homebrew']:
        for host in ['claude','codex']:
            out.append((42224583403,f'public-version-benchmark-linux-{scanner}-{host}','public-bash-policy-secondary'))
            out.append((42224583622,f'public-version-rss-linux-{scanner}-{host}','public-bash-policy-rss-supplement'))
            out.append((42232755942,f'public-version-controlled-linux-{scanner}-{host}','common-policy-primary'))
        for config in ['fixed','packaged']:
            out.append((42224583403,f'public-version-correctness-linux-{scanner}-{config}','accuracy-public-config'))
    out.append((42227732499,'public-version-installation-compact-linux','installation-existing-measurements-compact-export'))
    return out

def main():
    p=argparse.ArgumentParser();p.add_argument('--out',type=Path,default=ROOT/'evidence/ci/artifact-index.json');p.add_argument('--require-complete',action='store_true');a=p.parse_args();rows=[];missing=[]
    for run,name,cohort in expected():
        folder=ROOT/'evidence/ci'/str(run);path=folder/(name+'.zip');meta=folder/(name+'.artifact.json')
        if not path.is_file() or not meta.is_file():missing.append(dict(run_id=run,name=name,cohort=cohort));continue
        m=json.loads(meta.read_text());actual=hashlib.sha256(path.read_bytes()).hexdigest()
        if actual!=m['digest'] or path.stat().st_size!=m['size']:raise ValueError(f'ZIP size/digest mismatch: {path}')
        # Metadata snapshots can be native REST or connector-normalized payloads.
        remote={}
        for snapshot in sorted(folder.glob('*artifacts.json'),reverse=True):
            try:data=json.loads(snapshot.read_text())
            except (ValueError,OSError):continue
            remote=next((x for x in data.get('artifacts',[]) if x['id']==m['id']),{})
            if remote:break
        if remote.get('digest') and remote['digest']!='sha256:'+actual:raise ValueError(f'API ZIP digest mismatch: {path}')
        rows.append(dict(cohort=cohort,run_id=run,artifact_id=m['id'],name=name,zip=str(path.relative_to(ROOT)),size_bytes=path.stat().st_size,sha256=actual,github_url=f"https://github.com/JeongJaeSoon/agent-guard/actions/runs/{run}/artifacts/{m['id']}",created_at=remote.get('created_at'),expires_at=remote.get('expires_at'),source_head=remote.get('workflow_run',{}).get('head_sha'),local_zip_verified=True))
    result=dict(expected_local_source_zips=len(expected()),verified_local_source_zips=len(rows),missing=missing,artifacts=rows,scope='Each source ZIP retains original raw bytes. Primary common-policy and earlier public-Bash-policy cohorts remain separate. Installation compact export retains every nonpublic generated file plus the complete original-file hash manifest; the original large artifact stays linked with its expiry.')
    a.out.parent.mkdir(parents=True,exist_ok=True);a.out.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
    if rows:
        with a.out.with_suffix('.csv').open('w',newline='') as f:
            w=csv.DictWriter(f,fieldnames=list(rows[0]));w.writeheader();w.writerows(rows)
    print(json.dumps({'expected':len(expected()),'verified':len(rows),'missing':[x['name'] for x in missing]},ensure_ascii=False))
    if a.require_complete and missing:raise SystemExit('source evidence incomplete; no silent omission permitted')

if __name__=='__main__':main()
