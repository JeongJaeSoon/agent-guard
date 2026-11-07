#!/usr/bin/env python3
"""공개 v3.8.x를 격리 복사해 선택형 prepare 실패·partial 복귀를 검증한다."""
import argparse,hashlib,json,os,shutil,subprocess
from pathlib import Path
from common import payload,validate
from make_workloads import workloads

def main():
    p=argparse.ArgumentParser();p.add_argument('--releases',required=True);p.add_argument('--scanner',required=True);p.add_argument('--scanner-name',required=True);p.add_argument('--out',required=True)
    a=p.parse_args();out=Path(a.out);out.mkdir(parents=True,exist_ok=False);rows=[]
    case=next(c for c in workloads() if c['name']=='structure')
    env={k:v for k,v in os.environ.items() if not k.startswith('AGENT_GUARD_') and k not in ['AI_AGENT','CLAUDE_PLUGIN_ROOT','PLUGIN_ROOT']}
    env.update(HOME=str(out/'home'),AGENT_GUARD_RELEASE_CHECK='off',AGENT_GUARD_LOG_MODE='off',AGENT_GUARD_PII_HOOK_MODE='off',AGENT_GUARD_OUTPUT_REDACT='mask',AGENT_GUARD_GITLEAKS_BIN=a.scanner,AGENT_GUARD_GITLEAKS_CONFIG=str(Path(a.releases)/'v3.6.13/payload/config/gitleaks.toml'))
    for version in ['v3.8.0','v3.8.1']:
      for fault in ['prepare-missing','prepare-partial-error','prepare-partial-success','packaged-checksum-corrupt','packaged-core-missing']:
        dest=out/version/fault; dest.mkdir(parents=True);copy=dest/'payload';shutil.copytree(Path(a.releases)/version/'payload',copy)
        core=copy/'libexec/agent-guard-redact-x86_64-unknown-linux-musl';e=env.copy()
        if fault.startswith('prepare-'):
          helper=dest/'prepare'
          if fault!='prepare-missing':
            helper.write_text('#!/bin/sh\nprintf "untrusted partial" > "$2"\nprintf "untrusted frames" > "$3"\nprintf "prepared-v1\\n"\nexit '+('2' if fault.endswith('error') else '0')+'\n');helper.chmod(0o755)
          e.update(AGENT_GUARD_EXPERIMENTAL_OUTPUT_PIPELINE='fused',AGENT_GUARD_EXPERIMENTAL_OUTPUT_PREPARE_BIN=str(helper))
        elif fault=='packaged-checksum-corrupt':
          core.with_name(core.name+'.sha256').write_text('invalid-checksum\n')
        elif fault=='packaged-core-missing':core.unlink()
        for host in ['claude','codex']:
          e['AGENT_GUARD_HOOK_HOST']=host
          p=subprocess.run([str(copy/'bin/agent-guard'),'hook-post-tool'],input=payload(case),capture_output=True,env=e,timeout=30)
          (dest/(host+'-stdout')).write_bytes(p.stdout);(dest/(host+'-stderr')).write_bytes(p.stderr)
          ok,reasons,actual=validate(case,host,p.stdout,p.stderr,p.returncode)
          rows.append(dict(version=version,variant='fallback-fault-injection',scanner=a.scanner_name,host=host,case=fault,success=ok,classification='pass' if ok else 'fallback-mismatch',reason=','.join(reasons),status=p.returncode,raw_path=str(dest),actual=actual))
        # Public originals remain untouched. Remove copied release data only;
        # exact source identity is in release manifest and all outputs remain.
        shutil.rmtree(copy)
    (out/'results.json').write_text(json.dumps(dict(scope='isolated copied public v3.8.x payload fault injection; same independent structure expectation',scanner_sha256=hashlib.sha256(Path(a.scanner).read_bytes()).hexdigest(),rows=rows),ensure_ascii=False,indent=2)+'\n')
    print('rows',len(rows),'failed',sum(not r['success'] for r in rows))

if __name__=='__main__':main()
