#!/usr/bin/env python3
"""동일 Rust/compiler 조건의 개발자 빌드와 후보 추가 payload 비용. 공개 설치 시험이 아님."""
import gzip, hashlib, json, os, pathlib, shutil, statistics, subprocess, sys, tarfile, time
ROOT = pathlib.Path('/workspace/agent-guard-fused-evidence/install-cost-afab414')
REPO = pathlib.Path('/workspace/agent-guard-fused')
DRIVER = REPO / 'native/devtools/target/release/agent-guard-devtools'
CARGO = '/workspace/agent-guard-tools/cargo/bin/cargo'
def write(path, value): path.write_text(json.dumps(value, indent=2)+'\n')
def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()
if len(sys.argv) > 1 and sys.argv[1] == 'unpack':
    archive, expected, target = sys.argv[2:]
    archive = pathlib.Path(archive)
    assert sha(archive) == expected
    with tarfile.open(archive) as stream:
        assert all(m.name.startswith('payload/') and '..' not in pathlib.PurePosixPath(m.name).parts for m in stream)
        stream.extractall(target, filter='data')
    sys.exit(0)
ROOT.mkdir(exist_ok=False)
env = os.environ.copy()
env.update(CARGO_HOME='/workspace/agent-guard-tools/cargo', RUSTUP_HOME='/workspace/agent-guard-tools/rustup')
write(ROOT/'conditions.json', dict(scope='local developer build and synthetic packaged payload verification/unpack; not public network installation',
    candidate_head=subprocess.check_output(['git','rev-parse','HEAD'],cwd=REPO,text=True).strip(), baseline_head='e709445fb6fce9ade8cbbd2d6bcf2940e48da178',
    rustc=subprocess.check_output(['/workspace/agent-guard-tools/cargo/bin/rustc','--version'],env=env,text=True).strip(),
    cpu_max=pathlib.Path('/sys/fs/cgroup/cpu.max').read_text().strip(), memory_max=pathlib.Path('/sys/fs/cgroup/memory.max').read_text().strip(),
    build='same x86_64-unknown-linux-gnu target, empty target per sample, prepopulated dependency sources, --locked --offline; filesystem cache not dropped',
    memory='max child RSS separate from 10ms sampled process-group RSS sum; shared pages duplicated and short peaks may be missed',
    package='both synthetic gzip level6 deterministic metadata; actual v3.7.0 payload reused; candidate CLI/module plus separate GNU prepare helper, original musl redactor unchanged'))
rows=[]
def run(label, command, cwd=None, run_env=None):
    dest=ROOT/label;dest.mkdir()
    start=time.monotonic();samples=[]
    with (dest/'stdout').open('wb') as out,(dest/'stderr').open('wb') as err:
        process=subprocess.Popen([str(DRIVER),'resource-sample',str(dest/'resource.json'),*command],cwd=cwd,env=run_env,stdout=out,stderr=err,start_new_session=True)
        while process.poll() is None:
            rss=0
            for proc in pathlib.Path('/proc').iterdir():
                if not proc.name.isdigit():continue
                try:
                    st=(proc/'stat').read_text().rsplit(')',1)[1].split()
                    if int(st[2])==process.pid and int(proc.name)!=process.pid:
                        rss+=int((proc/'statm').read_text().split()[1])*os.sysconf('SC_PAGE_SIZE')//1024
                except (OSError,ValueError,IndexError):pass
            samples.append([time.monotonic()-start,rss]);time.sleep(.01)
    row=dict(label=label,command=command,exit=process.returncode,sampled_peak_rss_sum_kib=max((s[1] for s in samples),default=0))
    if (dest/'resource.json').exists():row.update(json.loads((dest/'resource.json').read_text()))
    row['cpu_seconds']=row.get('user_cpu_seconds',0)+row.get('system_cpu_seconds',0)
    write(dest/'rss-samples.json',samples);write(dest/'result.json',row);rows.append(row);write(ROOT/'results.json',rows)
    print(json.dumps(row),flush=True)
    assert process.returncode==0
for name,rev in [('baseline','e709445'),('candidate','afab414')]:
    source=ROOT/('source-'+name);(source/'src').mkdir(parents=True)
    for file in ['Cargo.toml','Cargo.lock','src/main.rs']:
        (source/file).write_bytes(subprocess.check_output(['git','show',rev+':native/redaction-core/'+file],cwd=REPO))
for trial in range(3):
    for name in (['baseline','candidate'] if trial%2==0 else ['candidate','baseline']):
        target=ROOT/f'target-{trial}-{name}'
        run_env=env.copy();run_env['CARGO_TARGET_DIR']=str(target)
        run(f'build-{trial}-{name}',[CARGO,'build','--release','--locked','--offline','--target','x86_64-unknown-linux-gnu'],ROOT/('source-'+name),run_env)
        binary=target/'x86_64-unknown-linux-gnu/release/agent-guard-redact'
        write(ROOT/f'build-{trial}-{name}'/'binary.json',dict(bytes=binary.stat().st_size,sha256=sha(binary)))
packages={}
for name in ['baseline','candidate']:
    payload=ROOT/('payload-'+name)
    shutil.copytree('/workspace/agent-guard-pipeline-evidence/public-validator-preflight/payload',payload)
    if name=='candidate':
        shutil.copy2(REPO/'plugins/agent-guard/bin/agent-guard',payload/'bin/agent-guard')
        shutil.copy2(REPO/'plugins/agent-guard/scripts/output-pipeline-experiment.sh',payload/'scripts/output-pipeline-experiment.sh')
        shutil.copy2(ROOT/'target-0-candidate/x86_64-unknown-linux-gnu/release/agent-guard-redact',payload/'libexec/agent-guard-prepare-experiment')
    archive=ROOT/(name+'.tar.gz')
    with archive.open('wb') as raw,gzip.GzipFile(fileobj=raw,mode='wb',mtime=0,filename='',compresslevel=6) as gz,tarfile.open(fileobj=gz,mode='w') as tar:
        for path in sorted(payload.rglob('*')):
            if not path.is_file():continue
            info=tarfile.TarInfo('payload/'+str(path.relative_to(payload)))
            info.mode=0o755 if os.access(path,os.X_OK) else 0o644;info.size=path.stat().st_size
            with path.open('rb') as stream:tar.addfile(info,stream)
    packages[name]=dict(archive_bytes=archive.stat().st_size,archive_sha256=sha(archive),payload_bytes=sum(p.stat().st_size for p in payload.rglob('*') if p.is_file()))
write(ROOT/'packages.json',packages)
for trial in range(7):
    for name in (['baseline','candidate'] if trial%2==0 else ['candidate','baseline']):
        run(f'unpack-{trial}-{name}',[sys.executable,__file__,'unpack',str(ROOT/(name+'.tar.gz')),packages[name]['archive_sha256'],str(ROOT/f'extracted-{trial}-{name}')])
summary={}
for kind in ['build','unpack']:
    summary[kind]={}
    for name in ['baseline','candidate']:
        values=[r for r in rows if r['label'].startswith(kind+'-') and r['label'].endswith('-'+name)]
        summary[kind][name]={k:statistics.median(r[k] for r in values) for k in ['wall_seconds','cpu_seconds','max_child_peak_rss_kib','sampled_peak_rss_sum_kib']}
write(ROOT/'summary.json',summary)
