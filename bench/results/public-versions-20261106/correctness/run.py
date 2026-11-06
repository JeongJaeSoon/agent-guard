#!/usr/bin/env python3
"""공개 배포본 정확도. 실패도 기록하며 제한시간·기대값을 변경하지 않는다."""
import argparse,csv,hashlib,json,os,signal,subprocess,time
from pathlib import Path
from make_workloads import workloads
from common import payload,validate

def sha(path): return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def main():
    p=argparse.ArgumentParser()
    p.add_argument('--releases',default='/workspace/agent-guard-lab/releases')
    p.add_argument('--scanner',required=True)
    p.add_argument('--scanner-name',required=True)
    p.add_argument('--out',required=True)
    p.add_argument('--versions',default='v3.6.13,v3.6.14,v3.6.15,v3.7.0,v3.7.1,v3.8.0,v3.8.1')
    p.add_argument('--variants',default='default')
    p.add_argument('--cases',default='')
    p.add_argument('--config-mode',choices=['fixed','packaged'],default='fixed')
    p.add_argument('--label',default='linux-jq1.6-actual4CPU16GiB')
    args=p.parse_args(); out=Path(args.out); out.mkdir(parents=True,exist_ok=False)
    versions=args.versions.split(','); cases=workloads()
    if args.cases: cases=[c for c in cases if c['name'] in args.cases.split(',')]
    releases=Path(args.releases)
    config=releases/'v3.6.13/payload/config/gitleaks.toml'
    state=out/'state'; state.mkdir(); (state/'.env').write_text('SENTINEL=protected-not-executed\n')
    # The allowed commit-message fixture must see a real empty repository,
    # rather than accidentally exercising missing-repository degradation.
    subprocess.run(['git','init','-q',str(state)],check=True,capture_output=True)
    # No inherited Agent Guard overrides; all state is beneath the evidence dir.
    base={k:v for k,v in os.environ.items() if not k.startswith('AGENT_GUARD_') and k not in ['AI_AGENT','CLAUDE_PLUGIN_ROOT','PLUGIN_ROOT']}
    base.update(HOME=str(state),XDG_CONFIG_HOME=str(state/'config'),XDG_CACHE_HOME=str(state/'cache'),XDG_STATE_HOME=str(state/'xdg-state'),AGENT_GUARD_LOG_MODE='off',AGENT_GUARD_RELEASE_CHECK='off',AGENT_GUARD_PII_HOOK_MODE='off',AGENT_GUARD_OUTPUT_REDACT='mask',AGENT_GUARD_GITLEAKS_BIN=args.scanner,AGENT_GUARD_GITLEAKS_CONFIG=str(config))
    rows=[]
    for version in versions:
        for variant in args.variants.split(','):
            if variant=='fused' and version not in ['v3.8.0','v3.8.1']: continue
            cli=releases/version/'payload/bin/agent-guard'
            for host in ['claude','codex']:
                for case in cases:
                    name=case['name']; label=f'{version}-{variant}-{host}-{name}'
                    dest=out/label; dest.mkdir(); env=base|{'AGENT_GUARD_HOOK_HOST':host,'AGENT_GUARD_WARNING_DIR':str(dest/'warnings'),'AGENT_GUARD_INFRA_FAILURE_MODE':case.get('infra_mode','open')}
                    if args.config_mode=='packaged': env['AGENT_GUARD_GITLEAKS_CONFIG']=str(releases/version/'payload/config/gitleaks.toml')
                    if variant=='fused':
                        env['AGENT_GUARD_EXPERIMENTAL_OUTPUT_PIPELINE']='fused'
                        env['AGENT_GUARD_EXPERIMENTAL_OUTPUT_PREPARE_BIN']=str(releases/version/'payload/libexec/agent-guard-redact-x86_64-unknown-linux-musl')
                    if variant=='shell': env['AGENT_GUARD_EXPERIMENTAL_REDACTOR']='shell'
                    if case.get('scanner_failure'): env['AGENT_GUARD_GITLEAKS_BIN']=str(dest/'missing-scanner')
                    data=payload(case); command=[str(cli),{'hook':'hook-post-tool','pre':'hook-pre-tool','prompt':'hook-user-prompt'}.get(case['route'],'exec')]
                    if case['route']=='exec':
                        source=dest/'synthetic-output'; source.write_text(case['value']); command+=['--','cat',str(source)]; data=b''
                    (dest/'stdin.json').write_bytes(data)
                    start=time.monotonic(); proc=subprocess.Popen(command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env,cwd=state,start_new_session=True)
                    timeout=False
                    try: stdout,stderr=proc.communicate(data,timeout=30)
                    except subprocess.TimeoutExpired:
                        timeout=True; os.killpg(proc.pid,signal.SIGKILL); stdout,stderr=proc.communicate()
                    elapsed=time.monotonic()-start
                    (dest/'stdout').write_bytes(stdout); (dest/'stderr').write_bytes(stderr)
                    ok,reasons,actual=validate(case,host,stdout,stderr,proc.returncode)
                    if timeout: ok=False; reasons.append('timeout-30s')
                    classification='pass'
                    if not ok:
                        if timeout: classification='timeout'
                        elif case.get('category')=='false-positive': classification='false-positive'
                        elif case.get('category')=='security-positive': classification='detection-miss'
                        else: classification='mismatch-needs-review'
                    row=dict(version=version,variant=variant,scanner=args.scanner_name,host=host,case=name,config_mode=args.config_mode,config_sha256=sha(env['AGENT_GUARD_GITLEAKS_CONFIG']),success=ok,expected_match=ok,classification=classification,reason=','.join(reasons),status=proc.returncode,timeout=timeout,elapsed_seconds=elapsed,raw_path=str(dest),stdout_sha256=hashlib.sha256(stdout).hexdigest(),expected_sha256=hashlib.sha256(json.dumps(case['expected'],sort_keys=True,ensure_ascii=False).encode()).hexdigest(),same_work_eligible=ok)
                    (dest/'result.json').write_text(json.dumps(row,ensure_ascii=False,indent=2)+'\n')
                    if not ok: (dest/'actual.json').write_text(json.dumps(actual,ensure_ascii=False,indent=2)+'\n')
                    rows.append(row); print(label,classification,flush=True)
                    (out/'results.json').write_text(json.dumps(dict(label=args.label,timeout_seconds=30,scanner_sha256=sha(args.scanner),config_sha256=sha(config),rows=rows),ensure_ascii=False,indent=2)+'\n')
    with (out/'results.csv').open('w') as f:
        writer=csv.DictWriter(f,fieldnames=list(rows[0])); writer.writeheader(); writer.writerows(rows)

if __name__=='__main__': main()
