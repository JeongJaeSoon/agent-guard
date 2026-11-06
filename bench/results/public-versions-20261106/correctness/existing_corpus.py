#!/usr/bin/env python3
"""기존 동결 1,013건 코어 corpus: baseline jq 계약과 공개 native 바이너리 비교.
이 검사는 scanner/host dispatch가 없으며 독립 기대값 CLI 검증과 구분한다.
"""
import argparse,base64,gzip,hashlib,json,subprocess
from pathlib import Path

def main():
    p=argparse.ArgumentParser();p.add_argument('--repo',required=True);p.add_argument('--releases',required=True);p.add_argument('--out',required=True)
    a=p.parse_args();root=Path(a.repo);releases=Path(a.releases);out=Path(a.out);out.mkdir(exist_ok=False,parents=True)
    corpus_path=root/'tests/fixtures/native-contracts.json'; corpus=json.loads(corpus_path.read_text())
    text=(releases/'v3.6.13/payload/bin/agent-guard').read_text()
    walk=text.split("JQ_SHAPE_SAFE_WALK='")[1].split("\n'")[0]
    function=text.split('redact_tool_response_json() {')[1].split('\n}\n')[0]
    program=function.split('"$JQ_SHAPE_SAFE_WALK"\'')[1].rsplit("' 2>/dev/null",1)[0]
    reference=out/'reference.jq';reference.write_text(walk+'\n.secrets as $secrets | .response | '+program)
    expected=[];reference_failures=[];reference_raw=[]
    for name,response,secrets in corpus:
        payload=json.dumps(dict(protocol=1,response=response,secrets=secrets),ensure_ascii=False).encode()
        timeout=False
        try:
            p=subprocess.run(['jq','-c','-f',str(reference)],input=payload,capture_output=True,timeout=15)
            stdout,stderr,status=p.stdout,p.stderr,p.returncode
        except subprocess.TimeoutExpired as e:
            stdout,stderr,status=e.stdout or b'',e.stderr or b'',None;timeout=True
        reference_raw.append(dict(case=name,input_sha256=hashlib.sha256(payload).hexdigest(),status=status,timeout=timeout,stdout_base64=base64.b64encode(stdout).decode(),stderr_base64=base64.b64encode(stderr).decode()))
        try:expect=json.loads(stdout) if status==0 else None;valid=status==0 and not timeout
        except (ValueError,UnicodeDecodeError):valid=False;expect=None
        if not valid:
            dest=out/'reference-failures'/name;dest.mkdir(parents=True);(dest/'input.json').write_bytes(payload);(dest/'stdout').write_bytes(stdout);(dest/'stderr').write_bytes(stderr);reference_failures.append(name);continue
        expected.append((name,payload,expect))
    with gzip.open(out/'reference-raw.jsonl.gz','wt',encoding='utf-8') as f:
        for row in reference_raw:f.write(json.dumps(row,ensure_ascii=False)+'\n')
    with gzip.open(out/'reference-raw.jsonl.gz','rt',encoding='utf-8') as f:
        if [json.loads(line) for line in f]!=reference_raw:raise RuntimeError('reference raw gzip roundtrip failed')
    rows=[]
    for version in ['v3.6.13','v3.6.14','v3.6.15','v3.7.0','v3.7.1','v3.8.0','v3.8.1']:
        core=releases/version/'payload/libexec/agent-guard-redact-x86_64-unknown-linux-musl'
        if not core.exists():
            rows.append(dict(version=version,status='N/A',reason='no public native binary'));continue
        passed=0;failures=[];samples=[];raw_records=[]
        for name,payload,expect in expected:
            timeout=False
            try:
                p=subprocess.run([str(core),'redact-v1'],input=payload,capture_output=True,timeout=15)
                actual=json.loads(p.stdout) if p.returncode==0 else None
                ok=p.returncode==0 and actual==expect
                stdout=p.stdout;stderr=p.stderr;status=p.returncode
            except subprocess.TimeoutExpired as e:
                ok=False;stdout=e.stdout or b'';stderr=e.stderr or b'';status=None;timeout=True
            except (ValueError,UnicodeDecodeError):
                ok=False;stdout=p.stdout;stderr=p.stderr;status=p.returncode
            samples.append(dict(case=name,success=ok,status=status,timeout=timeout,stdout_sha256=hashlib.sha256(stdout).hexdigest()))
            raw_records.append(dict(case=name,input_sha256=hashlib.sha256(payload).hexdigest(),status=status,timeout=timeout,stdout_base64=base64.b64encode(stdout).decode(),stderr_base64=base64.b64encode(stderr).decode()))
            if ok: passed+=1
            else:
                dest=out/version/name;dest.mkdir(parents=True);(dest/'input.json').write_bytes(payload);(dest/'stdout').write_bytes(stdout);(dest/'stderr').write_bytes(stderr);(dest/'expected.json').write_text(json.dumps(expect,ensure_ascii=False));failures.append(name)
        (out/(version+'-samples.json')).write_text(json.dumps(samples,ensure_ascii=False,indent=2)+'\n')
        raw_path=out/(version+'-raw.jsonl.gz')
        with gzip.open(raw_path,'wt',encoding='utf-8') as f:
            for row in raw_records:f.write(json.dumps(row,ensure_ascii=False)+'\n')
        with gzip.open(raw_path,'rt',encoding='utf-8') as f:
            if [json.loads(line) for line in f]!=raw_records:raise RuntimeError('raw gzip roundtrip failed')
        rows.append(dict(version=version,core_sha256=hashlib.sha256(core.read_bytes()).hexdigest(),status='measured',passed=passed,failed=len(failures),n=len(expected),failures=failures,raw_jsonl_gz=str(raw_path),raw_jsonl_gz_sha256=hashlib.sha256(raw_path.read_bytes()).hexdigest()))
        print(version,passed,len(failures),flush=True)
    (out/'results.json').write_text(json.dumps(dict(environment='linux-local-actual4CPU16GiB-jq1.7.1',scope='core-only existing frozen differential corpus; separate from independent CLI expected-value checks',timeout_seconds=15,corpus_sha256=hashlib.sha256(corpus_path.read_bytes()).hexdigest(),corpus_input_n=len(corpus),reference_failures=reference_failures,reference_raw_jsonl_gz_sha256=hashlib.sha256((out/'reference-raw.jsonl.gz').read_bytes()).hexdigest(),rows=rows),ensure_ascii=False,indent=2)+'\n')

if __name__=='__main__':main()
