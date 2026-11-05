#!/usr/bin/env python3
"""두 실제 공개 배포본의 오프라인 bootstrap 설치 비용; 네트워크 비용 제외."""
import hashlib, json, os, pathlib, statistics, subprocess, sys

root = pathlib.Path(sys.argv[1]).resolve()
assert not root.exists(), '원시 기록 덮어쓰기 거부'
root.mkdir()
published = pathlib.Path(sys.argv[2]).resolve()
release_sha = sys.argv[3]
assert len(release_sha)==40 and all(c in '0123456789abcdef' for c in release_sha)
assert json.loads((published/'native-validation.json').read_text())['release_sha']==release_sha
public = pathlib.Path('/workspace/agent-guard-pipeline-evidence/public-validator-preflight')
artifacts = published
for release_dir, tag in [(public, 'v3.7.0'), (published, 'v3.8.0')]:
    metadata = json.loads((release_dir/'metadata.json').read_text())
    assert metadata['tag_name'] == tag and not metadata['draft'] and not metadata['prerelease']
    for name in ['bootstrap.sh', f'agent-guard-{tag[1:]}.tar.gz']:
        asset = next(a for a in metadata['assets'] if a['name'] == name)
        assert asset['digest'] == 'sha256:' + hashlib.sha256((release_dir/name).read_bytes()).hexdigest(), name
driver = pathlib.Path('/workspace/agent-guard-fused/native/devtools/target/release/agent-guard-devtools')
env = {k: v for k, v in os.environ.items() if k not in ['DOCKER_HOST','DOCKER_CONTEXT','DOCKER_TLS','DOCKER_TLS_VERIFY','DOCKER_CERT_PATH']}
docker = ['docker','--host=unix:///var/run/docker.sock']
def write(path, value): path.write_text(json.dumps(value, indent=2)+'\n')
def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()
versions = {'baseline':'3.7.0','candidate':'3.8.0'}
for arm, version in versions.items():
    folder = root/arm; folder.mkdir()
    archive = folder/f'agent-guard-{version}.tar.gz'
    if arm == 'baseline':
        archive.write_bytes((public/archive.name).read_bytes())
        assert sha(archive) == 'd6ff2d398643f789d0259c782f7760504836f4495471dba613e3abc46dc2bf3d'
        (folder/'bootstrap.sh').write_bytes((public/'bootstrap.sh').read_bytes())
    else:
        archive.write_bytes((published/archive.name).read_bytes())
        expected=(published/(archive.name+'.sha256')).read_text().split()
        assert expected==[sha(archive),archive.name]
        (folder/'bootstrap.sh').write_bytes((published/'bootstrap.sh').read_bytes())
    (folder/(archive.name+'.sha256')).write_text(f'{sha(archive)}  {archive.name}\n')
    write(folder/'identity.json', {'archive_bytes':archive.stat().st_size,'archive_sha256':sha(archive),'bootstrap_sha256':sha(folder/'bootstrap.sh')})
(root/'http-bin').mkdir()
stub = root/'http-bin/curl'
stub.write_text('''#!/bin/sh
set -eu
out= url=
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift; out=$1 ;; https://*) url=$1 ;; -fsSL) ;; *) exit 2 ;; esac
  shift
done
case "$url" in
  "https://github.com/JeongJaeSoon/agent-guard/releases/download/v$AGENT_GUARD_VERSION/agent-guard-$AGENT_GUARD_VERSION.tar.gz"|"https://github.com/JeongJaeSoon/agent-guard/releases/download/v$AGENT_GUARD_VERSION/agent-guard-$AGENT_GUARD_VERSION.tar.gz.sha256") cp "/payload/${url##*/}" "$out" ;;
  *) exit 2 ;;
esac
'''); stub.chmod(0o755)
command = '''set -eu
! command -v cargo
! command -v rustc
! command -v go
! command -v cc
export PATH=/http-bin:/scanner:/usr/bin:/bin
export AGENT_GUARD_HOME=/tmp/installed AGENT_GUARD_BIN_DIR=/tmp/public-bin
export AGENT_GUARD_RELEASE_CHECK=off AGENT_GUARD_LOG_MODE=off
/driver resource-sample /out/resource.json sh /payload/bootstrap.sh > /out/stdout 2> /out/stderr
/tmp/public-bin/agent-guard version > /out/version.txt
find /tmp/installed -type f -printf '%s\n' | awk '{sum += $1} END {print sum}' > /out/installed-bytes.txt
test -L /tmp/public-bin/agent-guard
grep -q 'Managed by' /root/.bashrc
'''
write(root/'conditions.json', {'scope':'actual bootstrap fresh installation with locally substituted asset HTTP; excludes network and Docker startup; both payloads and bootstraps are actual public releases; HTTP is locally substituted','candidate_head':release_sha,'core_source':'actual published v3.8.0 assets','image':subprocess.check_output(docker+['image','inspect','agent-guard-public-install:20261104','--format','{{.Id}}'],env=env,text=True).strip(),'cpu_max':pathlib.Path('/sys/fs/cgroup/cpu.max').read_text().strip(),'memory_max':pathlib.Path('/sys/fs/cgroup/memory.max').read_text().strip(),'runs':9,'order':'alternating baseline/candidate; filesystem cache not dropped','rss':'maximum individual child RSS; not simultaneous process RSS sum','core_sha256':{p.name:sha(p) for p in artifacts.glob('agent-guard-redact-*') if not p.name.endswith('.sha256')}})
rows=[]
for trial in range(9):
    for arm in (['baseline','candidate'] if trial%2==0 else ['candidate','baseline']):
        out=root/f'{trial}-{arm}'; out.mkdir()
        process=subprocess.run(docker+['run','--rm','--network=none','-e','AGENT_GUARD_VERSION='+versions[arm],'-v',f'{root/arm}:/payload:ro','-v',f'{root/"http-bin"}:/http-bin:ro','-v',f'{out}:/out','-v',f'{driver}:/driver:ro','-v','/workspace/agent-guard-tools/gitleaks:/scanner/gitleaks:ro','agent-guard-public-install:20261104','sh','-c',command],env=env,capture_output=True)
        (out/'container.stdout').write_bytes(process.stdout); (out/'container.stderr').write_bytes(process.stderr)
        assert process.returncode==0, (arm,trial,process.returncode,process.stderr)
        assert (out/'version.txt').read_text().strip()=='agent-guard '+versions[arm]
        row=json.loads((out/'resource.json').read_text()); row.update(arm=arm,trial=trial,installed_bytes=int((out/'installed-bytes.txt').read_text()))
        row['cpu_seconds']=row['user_cpu_seconds']+row['system_cpu_seconds']
        rows.append(row);write(root/'results.json',rows)
        print(json.dumps(row),flush=True)
summary={arm:{key:statistics.median(r[key] for r in rows if r['arm']==arm) for key in ['wall_seconds','cpu_seconds','max_child_peak_rss_kib','installed_bytes']} for arm in versions}
write(root/'summary.json',summary);print(json.dumps(summary,indent=2))
