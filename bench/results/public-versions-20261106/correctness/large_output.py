#!/usr/bin/env python3
"""주 corpus 밖의 사전고정 1/8 MiB 보안 cap 검사. 지연 비교가 아니다."""
import argparse,csv,gzip,hashlib,json,os,re,signal,subprocess,time
from pathlib import Path

VERSIONS=['v3.6.13','v3.6.14','v3.6.15','v3.7.0','v3.7.1','v3.8.0','v3.8.1']
SIZES=[1048576,8388608]

def execve_success_lines(text):
    pending={};out=[]
    for line in text.splitlines():
        match=re.match(r'^(\d+)\s+(.*)$',line)
        pid,body=match.groups() if match else ('main',line)
        if 'execve(' in body and '<unfinished ...>' in body:
            pending[pid]=body.split('<unfinished ...>')[0];continue
        if body.startswith('<... execve resumed>'):
            body=pending.pop(pid,'')+body.split('<... execve resumed>',1)[1]
        if 'execve(' in body and re.search(r'= 0$',body):out.append(body)
    return out

def compress_verified(path):
    original=path.read_bytes();dest=path.with_name(path.name+'.gz')
    with dest.open('wb') as f:
        with gzip.GzipFile(filename='',mode='wb',fileobj=f,mtime=0) as z:z.write(original)
    with gzip.open(dest,'rb') as f:
        if f.read()!=original:raise RuntimeError('gzip verification failed: '+str(path))
    path.unlink()
    return {'path':str(dest),'uncompressed_bytes':len(original),'uncompressed_sha256':hashlib.sha256(original).hexdigest(),'gzip_sha256':hashlib.sha256(dest.read_bytes()).hexdigest()}

def main():
    p=argparse.ArgumentParser();p.add_argument('--releases',required=True);p.add_argument('--scanner',required=True);p.add_argument('--out',required=True);a=p.parse_args()
    out=Path(a.out);out.mkdir(parents=True,exist_ok=False);releases=Path(a.releases);inputs=out/'inputs';inputs.mkdir();home=out/'home';home.mkdir()
    for size in SIZES:(inputs/str(size)).write_bytes(b'a'*size)
    arms=[(v,'default') for v in VERSIONS]+[(v,'fused') for v in ['v3.8.0','v3.8.1']]
    protocol=dict(scope='supplemental security cap accuracy; not same-work latency; primary 32 cases unchanged',frozen_before_execution=True,versions=VERSIONS,arms=arms,host='none (exec route has no host dispatch)',sizes_bytes=SIZES,input_byte='a',expected_stdout='[REDACTED]\\n',expected_status=0,timeout_seconds=30,n_per_condition=1,environment='linux-local-actual4CPU16GiB-jq1.7.1',scanner_sha256=hashlib.sha256(Path(a.scanner).read_bytes()).hexdigest(),config_sha256=hashlib.sha256((releases/'v3.6.13/payload/config/gitleaks.toml').read_bytes()).hexdigest(),detailed_instrumentation='strace execve only; diagnostic elapsed not a performance sample')
    (out/'protocol.json').write_text(json.dumps(protocol,ensure_ascii=False,indent=2)+'\n')
    rows=[]
    base={k:v for k,v in os.environ.items() if not k.startswith('AGENT_GUARD_') and k not in ['AI_AGENT','CLAUDE_PLUGIN_ROOT','PLUGIN_ROOT']}
    base.update(HOME=str(home),AGENT_GUARD_LOG_MODE='off',AGENT_GUARD_RELEASE_CHECK='off',AGENT_GUARD_PII_HOOK_MODE='off',AGENT_GUARD_OUTPUT_REDACT='mask',AGENT_GUARD_GITLEAKS_BIN=a.scanner,AGENT_GUARD_GITLEAKS_CONFIG=str(releases/'v3.6.13/payload/config/gitleaks.toml'))
    for version,variant in arms:
      for size in SIZES:
        case=f'exec-over-cap-{size}';dest=out/f'{version}-{variant}-{case}';dest.mkdir();env=base.copy();core=releases/version/'payload/libexec/agent-guard-redact-x86_64-unknown-linux-musl'
        if variant=='fused':env.update(AGENT_GUARD_EXPERIMENTAL_OUTPUT_PIPELINE='fused',AGENT_GUARD_EXPERIMENTAL_OUTPUT_PREPARE_BIN=str(core))
        command=['strace','-f','-s','256','-e','trace=execve','-o',str(dest/'exec.trace'),str(releases/version/'payload/bin/agent-guard'),'exec','--','cat',str(inputs/str(size))]
        start=time.monotonic();p=subprocess.Popen(command,stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env,cwd=home,start_new_session=True);timeout=False
        try:stdout,stderr=p.communicate(timeout=30)
        except subprocess.TimeoutExpired:
          timeout=True;os.killpg(p.pid,signal.SIGKILL);stdout,stderr=p.communicate()
        elapsed=time.monotonic()-start;(dest/'stdout').write_bytes(stdout);(dest/'stderr').write_bytes(stderr)
        trace=(dest/'exec.trace').read_text(errors='replace')
        successes=execve_success_lines(trace)
        native_prepare=sum('agent-guard-redact-' in l and 'prepare-v1' in l for l in successes)
        native_redact=sum('agent-guard-redact-' in l and 'redact-v1' in l for l in successes)
        ok=p.returncode==0 and stdout==b'[REDACTED]\n' and not timeout
        artifacts=[compress_verified(dest/name) for name in ['stdout','stderr','exec.trace']]
        row=dict(environment=protocol['environment'],version=version,variant=variant,scanner='official',host='none',case=case,input_bytes=size,success=ok,expected_match=ok,same_work_eligible=False,classification='pass-security-cap' if ok else 'security-cap-mismatch',reason='accuracy only; deliberate full-output cap redaction, not normal masking throughput',status=p.returncode,timeout=timeout,elapsed_seconds_diagnostic=elapsed,raw_path=str(dest),native_prepare_exec_success=native_prepare,native_redact_exec_success=native_redact,artifacts=artifacts)
        rows.append(row);(out/'results.json').write_text(json.dumps(dict(**protocol,rows=rows),ensure_ascii=False,indent=2)+'\n');print(version,variant,size,ok,p.returncode,native_prepare,native_redact,flush=True)
    (out/'input-artifacts.json').write_text(json.dumps([compress_verified(inputs/str(s)) for s in SIZES],ensure_ascii=False,indent=2)+'\n')
    keys=[k for k in rows[0] if k!='artifacts']
    with (out/'results.csv').open('w') as f:
      w=csv.DictWriter(f,fieldnames=keys,extrasaction='ignore');w.writeheader();w.writerows(rows)

if __name__=='__main__':main()
