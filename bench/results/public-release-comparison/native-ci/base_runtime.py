#!/usr/bin/env python3
"""공개 배포본 실측. 제품 코드는 수정하지 않으며 모든 실패를 보존한다."""
import csv, hashlib, itertools, json, os, platform, resource, shutil, signal, statistics, subprocess, sys, tarfile, tempfile, time, urllib.request
from pathlib import Path
OUT=Path('/results'); OUT.mkdir(exist_ok=True)
WORK=Path('/tmp/public-release-experiment'); WORK.mkdir(exist_ok=True)
LOCK=json.loads((Path(__file__).parent/'release-lock.json').read_text())
SAMPLES=14; WARMUP=1; TIMEOUT=30
SCANNER={'name':'gitleaks_8.30.1_linux_x64.tar.gz','url':'https://github.com/gitleaks/gitleaks/releases/download/v8.30.1/gitleaks_8.30.1_linux_x64.tar.gz','sha256':'551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb'}
ROWS=[]; ERRORS=[]; ASSETS=[]; INSTALL=[]
def save(name,value):
    (OUT/name).write_text(json.dumps(value,ensure_ascii=False,indent=2)+'\n')
def sha(path): return hashlib.sha256(Path(path).read_bytes()).hexdigest()
def jlog(name,row):
    with (OUT/name).open('a') as f: f.write(json.dumps(row,ensure_ascii=False)+'\n')
def download(asset):
    dest=WORK/(asset.get('sha256',asset.get('digest','').removeprefix('sha256:'))[:12]+'-'+asset['name']); started=time.perf_counter(); cpu=time.process_time()
    try:
        with urllib.request.urlopen(asset.get('url',asset.get('browser_download_url')),timeout=60) as r, dest.open('wb') as f:
            shutil.copyfileobj(r,f)
        expected=asset.get('sha256',asset.get('digest','').removeprefix('sha256:'))
        actual=sha(dest)
        row={'asset':asset['name'],'url':asset.get('url'),'bytes':dest.stat().st_size,'sha256':actual,'expected_sha256':expected,'verified':actual==expected,'elapsed_ms':(time.perf_counter()-started)*1000,'controller_cpu_ms':(time.process_time()-cpu)*1000,'measurement':'one network download; not installation CPU'}
        ASSETS.append(row); save('assets.json',ASSETS)
        if actual!=expected: raise RuntimeError('download hash mismatch '+asset['name'])
        return dest
    except Exception as e:
        ERRORS.append({'stage':'download','asset':asset['name'],'error':str(e)}); save('errors.json',ERRORS); raise

def measure(cmd,payload,env,cwd,profile=False):
    # wait4 accounts all waited descendants. ru_maxrss is the maximum child RSS,
    # never a sum of RSS and never unique physical-memory usage.
    with tempfile.TemporaryFile() as inp, tempfile.TemporaryFile() as stdout, tempfile.TemporaryFile() as stderr:
        inp.write(payload); inp.seek(0)
        started=time.perf_counter()
        p=subprocess.Popen(cmd,stdin=inp,stdout=stdout,stderr=stderr,env=env,cwd=cwd,start_new_session=True)
        peak_sum=0; timed_out=False
        while True:
            pid,status,usage=os.wait4(p.pid,os.WNOHANG)
            if pid: break
            if profile:
                # Sample all processes in this private process group via /proc.
                total=0
                for item in Path('/proc').iterdir():
                    if not item.name.isdigit(): continue
                    try:
                        st=(item/'stat').read_text(); fields=st[st.rfind(')')+2:].split()
                        if int(fields[2])==p.pid: total+=int(fields[21])*os.sysconf('SC_PAGE_SIZE')/1024
                    except (OSError,ValueError,IndexError): pass
                peak_sum=max(peak_sum,total)
            if time.perf_counter()-started>TIMEOUT:
                timed_out=True; os.killpg(p.pid,signal.SIGKILL); pid,status,usage=os.wait4(p.pid,0); break
            time.sleep(.001 if not profile else .005)
        elapsed=(time.perf_counter()-started)*1000
        p.returncode=os.waitstatus_to_exitcode(status)
        stdout.seek(0); stderr.seek(0); output=stdout.read(); err=stderr.read()
        return {'elapsed_ms':elapsed,'cpu_ms':(usage.ru_utime+usage.ru_stime)*1000,'max_child_rss_kib':usage.ru_maxrss,'rss_sum_kib':peak_sum if profile else None,'returncode':p.returncode,'timeout':timed_out,'stdout_sha256':hashlib.sha256(output).hexdigest(),'stderr_sha256':hashlib.sha256(err).hexdigest()},output,err

def payloads():
    literal='performance-secret-value-42'
    texts={'small-clean':'ordinary status: build passed','many-replacements':['API_KEY='+literal]*32+['status'],'long-string':'a'*260000+' API_KEY='+literal,'control-multiline':'ordinary\nAPI_KEY='+literal+'\x1e\tcontinued\nordinary','large-output':'ordinary status: build passed\n'*12000+'API_KEY='+literal}
    return texts,literal

def valid_output(host,value,literal,output):
    expected=value if literal not in json.dumps(value) else (value.replace(literal,'[REDACTED]') if isinstance(value,str) else [v.replace(literal,'[REDACTED]') for v in value])
    if expected==value: return output==b''
    try:
        obj=json.loads(output)
        if host=='claude': return obj['hookSpecificOutput']['updatedToolOutput']==expected
        context=obj['hookSpecificOutput']['additionalContext']
        prefix='Agent Guard sanitized tool output:\n'
        return obj.get('decision')=='block' and context.startswith(prefix) and json.loads(context[len(prefix):])==expected
    except (ValueError,KeyError,TypeError): return False

def make_env(base,host,audit,mode,scanner,config,home):
    env={'PATH':'/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin','HOME':str(home),'TMPDIR':str(home/'tmp'),'LC_ALL':'C.UTF-8','LANG':'C.UTF-8',
         'AGENT_GUARD_LOG_MODE':'on' if audit=='on-warm' else audit,'AGENT_GUARD_RELEASE_CHECK':'off','AGENT_GUARD_HOOK_HOST':host,'AGENT_GUARD_PII_HOOK_MODE':'off','AGENT_GUARD_OUTPUT_REDACT':'mask','AGENT_GUARD_GITLEAKS_BIN':str(scanner),'AGENT_GUARD_GITLEAKS_CONFIG':str(config)}
    if mode=='fused':
        core=base/'libexec/agent-guard-redact-x86_64-unknown-linux-musl'
        env.update(AGENT_GUARD_EXPERIMENTAL_OUTPUT_PIPELINE='fused',AGENT_GUARD_EXPERIMENTAL_OUTPUT_PREPARE_BIN=str(core),AGENT_GUARD_RUST_CORE_BIN=str(core))
    return env

def stats(vals):
    qs=statistics.quantiles(vals,n=4,method='inclusive') if len(vals)>1 else [vals[0]]*3
    return {'median':statistics.median(vals),'q1':qs[0],'q3':qs[2],'min':min(vals),'max':max(vals)}
def summarize():
    result=[]
    keys=('version','platform','scanner','audit','host','input','mode','concurrency','measurement')
    grouped={}
    for row in ROWS: grouped.setdefault(tuple(row[k] for k in keys),[]).append(row)
    for key,rows in grouped.items():
        r=dict(zip(keys,key)); r.update(n=len(rows),successful=sum(x['returncode']==0 and x['correct'] and not x['timeout'] for x in rows),failures=sum(not x['correct'] or x['returncode']!=0 or x['timeout'] for x in rows))
        for metric in ('elapsed_ms','cpu_ms','max_child_rss_kib','throughput_rps','rss_sum_kib'):
            values=[x[metric] for x in rows if x.get(metric) is not None]
            r[metric]=stats(values) if values else None
        result.append(r)
    save('summary.json',result)
    if ROWS:
        cols=sorted(set().union(*(r.keys() for r in ROWS)))
        with (OUT/'samples.csv').open('w') as f:
            w=csv.DictWriter(f,fieldnames=cols);w.writeheader();w.writerows(ROWS)
    save('errors.json',ERRORS)
    make_chunks()


def make_chunks():
    chunks=OUT/'chunks';chunks.mkdir(exist_ok=True)
    index=[]
    for name in ('samples.jsonl','warmups.jsonl','samples.csv','summary.json','errors.json','installation.json','installation.jsonl','audit-cache-state.json'):
        source=OUT/name
        if not source.exists():continue
        text=source.read_text()
        if name.endswith('.json'):
            value=json.loads(text);records=value if isinstance(value,list) else [value];parts=[];current=[];size=2
            for record in records:
                encoded=json.dumps(record,ensure_ascii=False,separators=(',',':'));needed=len(encoded.encode())+1
                if current and size+needed>220000:parts.append(current);current=[];size=2
                current.append(record);size+=needed
            if current:parts.append(current)
            for n,part in enumerate(parts):
                target=chunks/(name+'.'+str(n).zfill(4)+'.json');target.write_text(json.dumps(part,ensure_ascii=False,separators=(',',':'))+'\n');index.append({'source':name,'chunk':str(target.relative_to(OUT)),'sha256':sha(target),'bytes':target.stat().st_size,'format':'JSON array records'})
        else:
            current=[];size=0;n=0
            for line in text.splitlines(keepends=True):
                needed=len(line.encode())
                if current and size+needed>220000:
                    target=chunks/(name+'.'+str(n).zfill(4)+'.txt');target.write_text(''.join(current));index.append({'source':name,'chunk':str(target.relative_to(OUT)),'sha256':sha(target),'bytes':target.stat().st_size,'format':'concatenate in numeric order'});n+=1;current=[];size=0
                current.append(line);size+=needed
            if current:
                target=chunks/(name+'.'+str(n).zfill(4)+'.txt');target.write_text(''.join(current));index.append({'source':name,'chunk':str(target.relative_to(OUT)),'sha256':sha(target),'bytes':target.stat().st_size,'format':'concatenate in numeric order'})
    save('chunk-index.json',index)


def main():
    limits={p:Path('/sys/fs/cgroup/'+p).read_text().strip() for p in ('cpu.max','memory.max','memory.swap.max','pids.max')}
    envinfo={'platform':platform.platform(),'uname':list(platform.uname()),'cgroup':limits,'resource_limit_valid':limits['cpu.max']=='200000 100000' and limits['memory.max']=='1073741824' and limits['memory.swap.max']=='0','cpu_count_visible':os.cpu_count(),'scanner':SCANNER,'dependencies':{c:subprocess.check_output([c,'--version'],text=True,stderr=subprocess.STDOUT).splitlines()[0] for c in ('python3','jq','curl','git')},'no_compiler_install':True}
    save('environment.json',envinfo)
    if not envinfo['resource_limit_valid']: raise RuntimeError('required cgroup limits not applied')
    save('plan.json',{'samples':SAMPLES,'warmup':WARMUP,'timeout_seconds':TIMEOUT,'premeasurement_fixture_revision':'many-replacements fixed to 32 secret leaves + 1 clean leaf before any Linux run; 400-leaf draft was not measured; independent accuracy work observed conservative whole-leaf masking on high leaf counts, so stress results remain separate from comparable-work timing','order':'condition cyclic rotations, reversing the second full cycle; 14 measured rounds for seven conditions (six defaults plus optional fused); exact condition order in each raw sample','installation':'pinned bootstrap fresh/refresh 12 balanced repetitions including archive/checksum network; predownloaded bootstrap script itself excluded and its one-off download recorded; dependencies already installed; archive extraction measured separately','rss':'wait4 max child RSS KiB; separate rss-profile has process RSS sum sampled every 5ms; profile elapsed/CPU excluded from performance comparisons','audit_state':'off or on-warm: fresh HOME for each version/mode/host/audit/input/concurrency. One warmup initializes state; 14 measured rounds retain that same HOME and audit/cache files. Different inputs and concurrency never share state. Separate RSS profile uses a distinct HOME with its own warmup. No claim that every cache lookup hits: exact cache files preserved; TTL expiration is possible.', 'scope':'public standalone archives only; fixed official scanner/config; audit off and on-warm; no aggregate input-weighted score','v3.8.1':LOCK['v381']})
    scanner_archive=download(SCANNER); scan_dir=WORK/'scanner'; scan_dir.mkdir(exist_ok=True)
    with tarfile.open(scanner_archive) as tf: tf.extractall(scan_dir,filter='data')
    scanner=scan_dir/'gitleaks'; scanner.chmod(0o755); save('scanner.json',{'type':'official','path':str(scanner),'sha256':sha(scanner),'version':subprocess.check_output([str(scanner),'version'],text=True).strip(),'archive':SCANNER})
    versions={}; archives={}; bootstraps={}
    for release in LOCK['releases']:
        v=release['version']; asset=next(a for a in release['assets'] if a['name']==f'agent-guard-{v}.tar.gz')
        archive=download(asset)
        checksum=download(next(a for a in release['assets'] if a['name']==f'agent-guard-{v}.tar.gz.sha256'))
        expected=checksum.read_text().split()[0]
        if sha(archive)!=expected: raise RuntimeError('published checksum mismatch '+v)
        dest=WORK/v;dest.mkdir(exist_ok=True)
        with tarfile.open(archive) as tf:tf.extractall(dest,filter='data')
        versions[v]=dest
        archives[v]=archive
        bootstraps[v]=download(next(a for a in release['assets'] if a['name']=='bootstrap.sh'))
    # Installation stages are balanced independently across six versions.
    for n in range(12):
        order=list(versions);shift=n%len(order);order=order[shift:]+order[:shift]
        if n>=len(order):order.reverse()
        for v in order:
            ex=WORK/('extract-'+v+'-'+str(n));ex.mkdir()
            row,out,err=measure(['tar','-xzf',str(archives[v]),'-C',str(ex)],b'',os.environ.copy(),WORK)
            row.update(version=v,sample=n,stage='archive-extraction-only',installed_bytes=sum(p.stat().st_size for p in ex.rglob('*') if p.is_file()),download_bytes=archives[v].stat().st_size,checksum_valid=True)
            INSTALL.append(row);jlog('installation.jsonl',row);shutil.rmtree(ex)
            home=WORK/('install-home-'+v+'-'+str(n));home.mkdir();(home/'tmp').mkdir()
            sentinel='# preserve this user configuration\nexport GUARD_EXPERIMENT_PRESERVE=yes\n'
            (home/'.bashrc').write_text(sentinel)
            install_env=dict(os.environ,HOME=str(home),SHELL='/bin/bash',AGENT_GUARD_VERSION=v,AGENT_GUARD_HOME=str(home/'payload'),AGENT_GUARD_BIN_DIR=str(home/'local-bin'),AGENT_GUARD_GITLEAKS_BIN=str(scanner),AGENT_GUARD_LOG_MODE='off',AGENT_GUARD_RELEASE_CHECK='off')
            for stage in ('pinned-bootstrap-fresh','pinned-bootstrap-refresh'):
                row,out,err=measure(['sh',str(bootstraps[v])],b'',install_env,home)
                row.update(version=v,sample=n,stage=stage,installed_bytes=sum(p.stat().st_size for p in (home/'payload').rglob('*') if p.is_file()),download_bytes=archives[v].stat().st_size+next(a['size'] for r in LOCK['releases'] if r['version']==v for a in r['assets'] if a['name']==f'agent-guard-{v}.tar.gz.sha256'),user_rc_preserved=(home/'.bashrc').read_text().startswith(sentinel),dependencies='preinstalled; dependency first installation excluded',bootstrap_script_sha256=sha(bootstraps[v]))
                INSTALL.append(row);jlog('installation.jsonl',row)
                evidence=OUT/'installation-logs';evidence.mkdir(exist_ok=True)
                (evidence/(v+'-'+str(n)+'-'+stage+'.stdout')).write_bytes(out)
                (evidence/(v+'-'+str(n)+'-'+stage+'.stderr')).write_bytes(err)
            save('installation.json',INSTALL)
    config=WORK/'fixed-gitleaks.toml';shutil.copyfile(versions['3.6.13']/'config/gitleaks.toml',config)
    save('manifest.json',{'versions':{v:{'commit':next(r['sha'] for r in LOCK['releases'] if r['version']==v),'cli_sha256':sha(p/'bin/agent-guard'),'default_native_files':{str(q.relative_to(p)):sha(q) for q in (p/'libexec').glob('*') if q.is_file()}} for v,p in versions.items()},'fixed_config_sha256':sha(config),'v3.8.1':'N/A: no public release/tag at locked retrieval'})
    cases,literal=payloads(); save('inputs.json',cases)
    conditions=[(v,'default') for v in versions]
    p=versions.get('3.8.0')
    if p and (p/'scripts/output-pipeline-experiment.sh').is_file() and (p/'libexec/agent-guard-redact-x86_64-unknown-linux-musl').is_file():conditions.append(('3.8.0','fused'))
    else:ERRORS.append({'stage':'fused','reason':'published archive lacks required helper or module; no local developer build substituted'})
    for host,audit,name,concurrency in itertools.product(('claude','codex'),('off','on-warm'),cases,(1,4)):
        value=cases[name]; payload=json.dumps({'tool_name':'mcp__benchmark__read','tool_response':value},separators=(',',':')).encode()
        # Rotate version order, then reverse paired rounds. The schedule is fixed before timing.
        for round_no in range(-WARMUP,SAMPLES):
            i=max(round_no,0)%len(conditions); order=conditions[i:]+conditions[:i]
            if max(round_no,0)//len(conditions)%2:order=list(reversed(order))
            for version,mode in order:
                base=versions[version];home=WORK/('home-'+version+'-'+mode+'-'+host+'-'+audit+'-'+name+'-'+str(concurrency)); (home/'tmp').mkdir(parents=True,exist_ok=True)
                env=make_env(base,host,audit,mode,scanner,config,home)
                # Four child commands execute as one batch; outer wait4 retains CPU/RSS of the batch.
                if concurrency==1:cmd=[str(base/'bin/agent-guard'),'hook-post-tool']
                else:
                    batch=WORK/'batch.sh';batch.write_text('#!/bin/sh\npids=\nfor i in 1 2 3 4; do "$1" hook-post-tool < "$2" > "$3/$i.out" 2> "$3/$i.err" & pids="$pids $!"; done\nstatus=0\nfor pid in $pids; do wait "$pid" || status=1; done\nexit "$status"\n')
                    input_file=home/'input.json';input_file.write_bytes(payload);cmd=['sh',str(batch),str(base/'bin/agent-guard'),str(input_file),str(home)]
                row,stdout,stderr=measure(cmd,payload,env,home)
                outputs=[stdout] if concurrency==1 else [(home/f'{k}.out').read_bytes() for k in range(1,5)]
                errors=[stderr] if concurrency==1 else [(home/f'{k}.err').read_bytes() for k in range(1,5)]
                correct=all(valid_output(host,value,literal,o) for o in outputs)
                row['child_stdout_sha256']=[hashlib.sha256(o).hexdigest() for o in outputs]
                row['child_stderr_sha256']=[hashlib.sha256(o).hexdigest() for o in errors]
                row.update(version=version,platform='linux-x86_64-cgroup2',scanner='official-gitleaks-8.30.1',audit=audit,host=host,input=name,mode=mode,concurrency=concurrency,sample=round_no,measurement='cli',execution_order=order.index((version,mode)),correct=correct,throughput_rps=concurrency/(row['elapsed_ms']/1000))
                if round_no<0:jlog('warmups.jsonl',row)
                if round_no>=0:
                    ROWS.append(row);jlog('samples.jsonl',row)
                    if not correct or row['returncode'] or row['timeout']:
                        ERRORS.append({k:row[k] for k in ('version','host','audit','input','mode','concurrency','sample','returncode','timeout','correct')})
                    # Unique exact outputs preserve all results without duplicating large strings.
                    evidence=OUT/'outputs';evidence.mkdir(exist_ok=True)
                    for o in outputs+errors:(evidence/(hashlib.sha256(o).hexdigest()+'.txt')).write_bytes(o)
                print(json.dumps({k:row[k] for k in ('version','host','audit','input','mode','concurrency','sample','elapsed_ms','correct')}),flush=True)
        summarize()
    # RSS-sum sampling is a separate experiment: its elapsed and CPU costs
    # must never be used as the main CLI latency/CPU result.
    profile_plan={'inputs':['small-clean','many-replacements'],'samples':SAMPLES,'warmup':WARMUP,'interval_ms':5,'elapsed_cpu_comparison_eligible':False,'rss_sum_definition':'sampled sum of RSS in private process group; shared pages can be counted repeatedly; not unique physical memory'}
    save('rss-profile-plan.json',profile_plan)
    for host,audit,name,concurrency in itertools.product(('claude','codex'),('off','on-warm'),profile_plan['inputs'],(1,4)):
        value=cases[name];payload=json.dumps({'tool_name':'mcp__benchmark__read','tool_response':value},separators=(',',':')).encode()
        for round_no in range(-WARMUP,SAMPLES):
            i=max(round_no,0)%len(conditions);order=conditions[i:]+conditions[:i]
            if max(round_no,0)//len(conditions)%2:order=list(reversed(order))
            for version,mode in order:
                base=versions[version];home=WORK/('rss-home-'+version+'-'+mode+'-'+host+'-'+audit+'-'+name+'-'+str(concurrency));(home/'tmp').mkdir(parents=True,exist_ok=True)
                env=make_env(base,host,audit,mode,scanner,config,home)
                if concurrency==1:cmd=[str(base/'bin/agent-guard'),'hook-post-tool']
                else:
                    input_file=home/'input.json';input_file.write_bytes(payload);cmd=['sh',str(WORK/'batch.sh'),str(base/'bin/agent-guard'),str(input_file),str(home)]
                row,stdout,stderr=measure(cmd,payload,env,home,profile=True)
                outputs=[stdout] if concurrency==1 else [(home/f'{k}.out').read_bytes() for k in range(1,5)]
                errors=[stderr] if concurrency==1 else [(home/f'{k}.err').read_bytes() for k in range(1,5)]
                row.update(version=version,platform='linux-x86_64-cgroup2',scanner='official-gitleaks-8.30.1',audit=audit,host=host,input=name,mode=mode,concurrency=concurrency,sample=round_no,measurement='rss-profile',execution_order=order.index((version,mode)),correct=all(valid_output(host,value,literal,o) for o in outputs),throughput_rps=concurrency/(row['elapsed_ms']/1000),elapsed_cpu_comparison_eligible=False,child_stdout_sha256=[hashlib.sha256(o).hexdigest() for o in outputs],child_stderr_sha256=[hashlib.sha256(o).hexdigest() for o in errors])
                if round_no<0:jlog('warmups.jsonl',row)
                if round_no>=0:
                    ROWS.append(row);jlog('samples.jsonl',row)
                    if not row['correct'] or row['returncode'] or row['timeout']:ERRORS.append({k:row[k] for k in ('version','host','audit','input','mode','concurrency','sample','returncode','timeout','correct','measurement')})
                    evidence=OUT/'outputs';evidence.mkdir(exist_ok=True)
                    for o in outputs+errors:(evidence/(hashlib.sha256(o).hexdigest()+'.txt')).write_bytes(o)
        summarize()
    # Preserve exact warm audit/cache state without copying request temporary files.
    state_manifest=[];state_dest=OUT/'audit-cache-state';state_dest.mkdir(exist_ok=True)
    for home in WORK.glob('*home-*'):
        source=home/'.local/state/agent-guard'
        if not source.is_dir():continue
        dest=state_dest/home.name;shutil.copytree(source,dest,dirs_exist_ok=True)
        state_manifest.extend({'home':home.name,'path':str(q.relative_to(dest)),'sha256':sha(q),'bytes':q.stat().st_size} for q in dest.rglob('*') if q.is_file())
    save('audit-cache-state.json',state_manifest)
    # Detailed process spawning evidence is deliberately outside main timing.
    traces=OUT/'traces';traces.mkdir(exist_ok=True)
    trace_rows=[]
    for version,mode in conditions:
        base=versions[version];home=WORK/('trace-'+version+'-'+mode);(home/'tmp').mkdir(parents=True,exist_ok=True)
        env=make_env(base,'claude','off',mode,scanner,config,home)
        value=cases['many-replacements'];payload=json.dumps({'tool_name':'mcp__benchmark__read','tool_response':value},separators=(',',':')).encode()
        path=traces/(version+'-'+mode+'.strace')
        row,out,err=measure(['strace','-f','-ttt','-T','-e','trace=execve','-o',str(path),str(base/'bin/agent-guard'),'hook-post-tool'],payload,env,home)
        row.update(version=version,mode=mode,measurement='strace-separate-instrumentation',correct=valid_output('claude',value,literal,out),trace_file=str(path.relative_to(OUT)))
        trace_rows.append(row)
    save('traces.json',trace_rows)
    # Endpoints absent in this locked public set remain N/A rather than becoming 3.8.0.
    save('endpoint-direct-comparison.json',{'baseline':'3.6.13','candidate':'3.8.1','status':'N/A','reason':'3.8.1 public release and tag unavailable at metadata lock; never replaced by main or 3.8.0'})
    summarize()
if __name__=='__main__':
    try:main()
    except Exception as e:
        ERRORS.append({'stage':'fatal','error':repr(e)});summarize();raise
