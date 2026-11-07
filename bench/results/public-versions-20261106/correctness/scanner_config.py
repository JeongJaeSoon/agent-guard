#!/usr/bin/env python3
"""배포본 config의 오탐 개선 및 인접 보안 대조군. scanner-only, host 성능과 분리."""
import argparse,hashlib,json,subprocess
from pathlib import Path

def cases():
    uuid='7b32f9a1-6c08-4d73-a9b2-1e50f6c8d947'
    return [
      ('orca-repo-id','model-key.md --repo id:'+uuid,False),
      ('orca-quoted-repo-id',"model-key.md --repo 'id:"+uuid+"' --name x",False),
      ('uuid-key-colon','model-key: '+uuid,True),
      ('uuid-key-assignment','MODEL_KEY='+uuid,True),
      ('uuid-auth-id','Authorization: token id:'+uuid,True),
      ('uuid-other-option','model-key --name id:'+uuid,True),
      ('uuid-uppercase','model-key --repo id:'+uuid.upper(),True),
      ('uuid-suffixed','model-key --repo id:'+uuid+'abcd',True),
      ('uuid-adjacent-secret','model-key --repo id:'+uuid+' api_key='+uuid,True),
      ('api-key-uuid','api_key='+uuid,True),
      ('vendor-shape-positive','ghp_'+'Ab3dE5fG7hI9jK1lM3nO5pQ7rS9tU1vW3xY5',True),
      ('vendor-placeholder','ghp_'+'x'*36,False),
      ('documented-placeholder','API_KEY=example_token',False),
    ]

def main():
    p=argparse.ArgumentParser();p.add_argument('--releases',required=True);p.add_argument('--scanner',required=True);p.add_argument('--scanner-name',required=True);p.add_argument('--out',required=True)
    a=p.parse_args();out=Path(a.out);out.mkdir(parents=True,exist_ok=False);rows=[]
    for version in ['v3.6.13','v3.6.14','v3.6.15','v3.7.0','v3.7.1','v3.8.0','v3.8.1']:
        config=Path(a.releases)/version/'payload/config/gitleaks.toml'
        for name,text,finding_expected in cases():
            dest=out/version/name;dest.mkdir(parents=True);report=dest/'report.json';(dest/'input.txt').write_text(text)
            p=subprocess.run([a.scanner,'stdin','--no-banner','--config',str(config),'--report-format','json','--report-path',str(report)],input=text.encode(),capture_output=True,timeout=15)
            (dest/'stdout').write_bytes(p.stdout);(dest/'stderr').write_bytes(p.stderr)
            try:
                findings=json.loads(report.read_bytes()); valid=p.returncode in [0,1] and isinstance(findings,list)
            except (ValueError,OSError):findings=[];valid=False
            has_finding=bool(findings)
            rows.append(dict(version=version,scanner=a.scanner_name,case=name,expected_finding=finding_expected,actual_finding=has_finding,success=valid and has_finding==finding_expected,status=p.returncode,classification='pass' if valid and has_finding==finding_expected else ('false-positive' if has_finding and not finding_expected else 'detection-miss' if valid else 'scanner-error'),config_sha256=hashlib.sha256(config.read_bytes()).hexdigest(),raw_path=str(dest)))
    (out/'results.json').write_text(json.dumps(dict(scope='scanner-only; packaged config; 13 predeclared security/false-positive cases; not CLI latency',scanner_sha256=hashlib.sha256(Path(a.scanner).read_bytes()).hexdigest(),rows=rows),ensure_ascii=False,indent=2)+'\n')
    print('rows',len(rows),'failed',sum(not r['success'] for r in rows))

if __name__=='__main__':main()
