#!/usr/bin/env python3
"""동일 공개 배포본 CLI 측정. 제품 변경/빌드 없음; 원시 실패도 보존."""
import argparse,concurrent.futures,csv,gzip,hashlib,json,os,resource,signal,subprocess,sys,tempfile,time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'correctness'))
from make_workloads import workloads
from common import payload,validate
VERS=['v3.6.13','v3.6.14','v3.6.15','v3.7.0','v3.7.1','v3.8.0','v3.8.1']
CORE='agent-guard-redact-x86_64-unknown-linux-musl'
def sha(b):return hashlib.sha256(b).hexdigest()
def write(p,v):Path(p).write_text(json.dumps(v,ensure_ascii=False,indent=2)+'\n')
def rss_sum(pids):
    # Only request process trees. The separate sampler/driver is excluded.
    stats={}
    for p in Path('/proc').glob('[0-9]*/stat'):
        try:
            s=p.read_text(); fields=s[s.rindex(')')+2:].split(); stats[int(p.parent.name)]=(int(fields[1]),int(fields[21])*os.sysconf('SC_PAGE_SIZE')/1024)
        except (OSError,ValueError,IndexError):pass
    wanted=set(pids)
    for _ in range(30):
        children={p for p,(parent,_) in stats.items() if parent in wanted}
        if children<=wanted:break
        wanted|=children
    return sum(stats[p][1] for p in wanted if p in stats)
def worker(spec):
    cmd=spec['command']; env=spec['env']; data=Path(spec['input']).read_bytes(); folder=Path(spec['result']); folder.mkdir(parents=True,exist_ok=True)
    processes=[]; sample=[]; timed=[None]*spec['requests']; outputs=[None]*spec['requests']
    start=time.perf_counter(); driver0=resource.getrusage(resource.RUSAGE_SELF)
    def request(i):
        t=time.perf_counter();p=subprocess.Popen(cmd,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env,cwd=spec['cwd'],start_new_session=True); processes.append(p)
        timeout=False
        try:stdout,stderr=p.communicate(data,timeout=30)
        except subprocess.TimeoutExpired:
            timeout=True; os.killpg(p.pid,signal.SIGKILL); stdout,stderr=p.communicate()
        timed[i]={'status':p.returncode,'timeout':timeout,'latency_s':time.perf_counter()-t};outputs[i]=(stdout,stderr)
    with concurrent.futures.ThreadPoolExecutor(max_workers=spec['workers']) as pool:
        futures=[pool.submit(request,i) for i in range(spec['requests'])]
        while not all(f.done() for f in futures):
            if spec['sample_rss']:sample.append(rss_sum([p.pid for p in processes if p.poll() is None]))
            # Main timing does not poll /proc; futures block on subprocess I/O.
            if spec['sample_rss']:time.sleep(.01)
            else:
                concurrent.futures.wait(futures)
        for f in futures:f.result()
    wall=time.perf_counter()-start
    u=resource.getrusage(resource.RUSAGE_CHILDREN); d=resource.getrusage(resource.RUSAGE_SELF)
    for i,(stdout,stderr) in enumerate(outputs):
        (folder/f'{i}.stdout').write_bytes(stdout);(folder/f'{i}.stderr').write_bytes(stderr)
        timed[i].update(stdout_sha256=sha(stdout),stderr_sha256=sha(stderr))
    write(folder/'metrics.json',dict(wall_s=wall,cpu_s=u.ru_utime+u.ru_stime,user_cpu_s=u.ru_utime,system_cpu_s=u.ru_stime,max_child_rss_kib=u.ru_maxrss,rss_sum_peak_kib=max(sample) if sample else None,rss_sample_count=len(sample),driver_cpu_s=d.ru_utime+d.ru_stime-driver0.ru_utime-driver0.ru_stime,requests=spec['requests'],workers=spec['workers'],processes=timed))
def main():
    p=argparse.ArgumentParser();p.add_argument('--lab',default='/lab');p.add_argument('--out',required=True);p.add_argument('--environment',required=True);p.add_argument('--scanners',default='official,homebrew');p.add_argument('--hosts',default='claude,codex');p.add_argument('--series',default='versions,direct,optional,source,audit,load,rss,trace');p.add_argument('--require-limits',action='store_true');p.add_argument('--rss-all-versions',action='store_true');p.add_argument('--policy-mode',choices=['shipped','common'],default='shipped');p.add_argument('--worker');a=p.parse_args()
    out=Path(a.out);out.mkdir(parents=True,exist_ok=False);lab=Path(a.lab); proto=json.loads((ROOT/'runtime/protocol.json').read_text()); cases={c['name']:c for c in workloads()}; selected=a.series.split(',')
    proto.update(policy_mode=a.policy_mode,policy_scope='gitleaks fixed; deny-read public bytes identical; deny-bash baseline override only in common mode')
    if a.rss_all_versions:proto.update(rss_rounds=16,rss_arms='all seven public defaults plus v3.8.1 fused',rss_order='8 forward rotations then 8 reversed rotations',rss_supplement=True)
    limits={n:Path('/sys/fs/cgroup/'+n).read_text().strip() for n in ['cpu.max','memory.max','memory.swap.max']};limits['proc_swaps']=Path('/proc/swaps').read_text();limits['verified_requested']=all(limits[k]==v for k,v in {'cpu.max':'200000 100000','memory.max':'1073741824','memory.swap.max':'0'}.items())
    write(out/'environment.json',dict(label=a.environment,limits=limits,uname=list(os.uname()),python=sys.version,jq=subprocess.check_output(['jq','--version']).decode().strip(),jq_sha256=sha(Path(subprocess.check_output(['sh','-c','command -v jq']).decode().strip()).read_bytes()),protocol=proto))
    if a.require_limits and not limits['verified_requested']:raise SystemExit('required cgroup limits NOT enforced; measurements refused')
    write(out/'protocol.json',proto)
    # Verify all effective policy bytes before any CLI timing. Deny-read stays
    # on the public default path because an override toggles custom-policy mode.
    canonical=lab/'releases/v3.6.13/payload/config'
    proof=[]
    for version in VERS:
        for dist,root in [('standalone',lab/'releases'/version/'payload'),('source-plugin',lab/'releases'/version/'source/plugins/agent-guard')]:
            effective={'gitleaks.toml':canonical/'gitleaks.toml','deny-read-paths.txt':root/'config/deny-read-paths.txt','deny-bash-patterns.txt':canonical/'deny-bash-patterns.txt' if a.policy_mode=='common' else root/'config/deny-bash-patterns.txt'}
            proof.append(dict(version=version,distribution=dist,files={key:dict(path=str(path),sha256=sha(path.read_bytes())) for key,path in effective.items()}))
    equal={key:len({entry['files'][key]['sha256'] for entry in proof})==1 for key in ['gitleaks.toml','deny-read-paths.txt','deny-bash-patterns.txt']}
    write(out/'policy-proof.json',dict(mode=a.policy_mode,identical_across_all_versions_and_distributions=equal,rows=proof))
    if a.policy_mode=='common' and not all(equal.values()):raise SystemExit('effective policy bytes differ; controlled measurements refused')
    base={k:v for k,v in os.environ.items() if not k.startswith('AGENT_GUARD_') and k not in ['AI_AGENT','CLAUDE_PLUGIN_ROOT','PLUGIN_ROOT']}
    state_root=out/'state';state_root.mkdir(); blobs=out/'blobs';blobs.mkdir(); inp=out/'inputs';inp.mkdir(); rows=[];seq=0; skipped=[]
    for c in cases.values():(inp/(c['name']+'.json')).write_bytes(payload(c))
    config=lab/'releases/v3.6.13/payload/config/gitleaks.toml'
    def blob(data):
        h=sha(data);path=blobs/(h+'.gz')
        if not path.exists():path.write_bytes(gzip.compress(data,mtime=0))
        return h
    def invoke(meta,c,version,variant,dist,round_,workers=1,phase='runtime',measure=True):
        nonlocal seq
        seq+=1; key='-'.join([meta['series'],meta['scanner'],meta['host'],meta['audit'],c['name'],version,variant,dist,str(workers)])
        state=state_root/key
        if meta['audit']=='cold':state=state/str(seq)
        state.mkdir(parents=True,exist_ok=True);(state/'.env').write_text('SENTINEL=protected-not-executed\n')
        env=base|{'HOME':str(state),'XDG_CONFIG_HOME':str(state/'config'),'XDG_CACHE_HOME':str(state/'cache'),'XDG_STATE_HOME':str(state/'xdg-state'),'AGENT_GUARD_HOOK_HOST':meta['host'],'AGENT_GUARD_LOG_MODE':'off' if meta['audit']=='off' else 'on','AGENT_GUARD_RELEASE_CHECK':'off','AGENT_GUARD_PII_HOOK_MODE':'off','AGENT_GUARD_OUTPUT_REDACT':'mask','AGENT_GUARD_GITLEAKS_CONFIG':str(config),'AGENT_GUARD_GITLEAKS_BIN':str(lab/'scanners'/meta['scanner']/'gitleaks'),'AGENT_GUARD_INFRA_FAILURE_MODE':c.get('infra_mode','open')}
        if a.policy_mode=='common':env['AGENT_GUARD_DENY_BASH_PATTERNS']=str(canonical/'deny-bash-patterns.txt')
        if c.get('scanner_failure'):env['AGENT_GUARD_GITLEAKS_BIN']=str(state/'missing-scanner')
        pkg=lab/'releases'/version/'payload'; cli=pkg/'bin/agent-guard' if dist=='standalone' else lab/'releases'/version/'source/plugins/agent-guard/bin/agent-guard'
        if variant=='fused':
            env.update(AGENT_GUARD_EXPERIMENTAL_OUTPUT_PIPELINE='fused',AGENT_GUARD_EXPERIMENTAL_OUTPUT_PREPARE_BIN=str(pkg/'libexec'/CORE))
            if dist!='standalone':env['AGENT_GUARD_RUST_CORE_BIN']=str(pkg/'libexec'/CORE)
        cmd=[str(cli),{'hook':'hook-post-tool','pre':'hook-pre-tool','prompt':'hook-user-prompt','exec':'exec'}[c['route']]];input_=inp/(c['name']+'.json')
        if c['route']=='exec':
            source=state/'synthetic-output';source.write_text(c['value']);cmd+=['--','cat',str(source)];input_=state/'empty';input_.write_bytes(b'')
        requests=workers
        with tempfile.TemporaryDirectory(dir=out) as temp:
            spec=dict(command=cmd,env=env,input=str(input_),cwd=str(state),workers=workers,requests=requests,sample_rss=phase=='rss',result=temp+'/result')
            if phase=='trace' and measure:
                dest=out/'traces';dest.mkdir(exist_ok=True); trace=dest/(key+'-'+str(seq)+'.strace');spec['command']=['strace','-f','-qq','-tt','-T','-e','trace=process','-o',str(trace)]+cmd
            sp=Path(temp)/'spec.json';write(sp,spec)
            subprocess.run([sys.executable,str(Path(__file__).resolve()),'--worker',str(sp)],check=True)
            metrics=json.loads((Path(spec['result'])/'metrics.json').read_text()); checks=[];hashes=[]
            for i in range(requests):
                stdout=(Path(spec['result'])/f'{i}.stdout').read_bytes();stderr=(Path(spec['result'])/f'{i}.stderr').read_bytes();proc=metrics['processes'][i]
                ok,reasons,_=validate(c,meta['host'],stdout,stderr,proc['status']); ok=ok and not proc['timeout'];checks.append(dict(ok=ok,reasons=reasons,timeout=proc['timeout'],status=proc['status']));hashes.append(dict(stdout=blob(stdout),stderr=blob(stderr)))
            success=all(x['ok'] for x in checks)
            row=meta|metrics|dict(policy_mode=a.policy_mode,deny_bash_sha256=sha(Path(env.get('AGENT_GUARD_DENY_BASH_PATTERNS',str(cli.parent.parent/'config/deny-bash-patterns.txt'))).read_bytes()),deny_read_sha256=sha((cli.parent.parent/'config/deny-read-paths.txt').read_bytes()),phase=phase if measure else 'warmup',environment=a.environment,version=version,variant=variant,distribution=dist,case=c['name'],round=round_,order=seq,success=success,eligible=success,checks=checks,outputs=hashes,cli_sha256=sha(cli.read_bytes()),config_sha256=sha(config.read_bytes()),scanner_sha256=sha((lab/'scanners'/meta['scanner']/'gitleaks').read_bytes()))
            if phase=='trace' and measure:
                s=trace.read_text(); row['execve_calls']=s.count('execve(')+s.count('execveat(');row['process_creations']=sum(any(k in line for k in ['clone(','clone3(','fork(','vfork(']) and 'CLONE_THREAD' not in line for line in s.splitlines());row['prepare_v1_calls']=s.count('"prepare-v1"');row['redact_v1_calls']=s.count('"redact-v1"');row['trace_file']=str(trace.relative_to(out))
            rows.append(row)
            with (out/'samples.jsonl').open('a') as f:f.write(json.dumps(row,ensure_ascii=False)+'\n')
            if measure:print(f'{seq} {meta} {version} {variant} {dist} {c["name"]} w{workers} {phase} {metrics["wall_s"]:.4f}s ok={success}',flush=True)
    def schedule(meta,names,arms,rounds=14,workers=1,phase='runtime',rotation=False):
        for name in names:
            c=cases[name]
            for version,variant,dist in arms:
                for warmup in range(2):invoke(meta,c,version,variant,dist,-1-warmup,workers,phase,False)
            for r in range(rounds):
                if rotation:
                    order=arms[r%len(arms):]+arms[:r%len(arms)]
                    if r>=len(arms):order=order[::-1]
                else:order=arms if r%2==0 else arms[::-1]
                for version,variant,dist in order:invoke(meta,c,version,variant,dist,r,workers,phase)
    for scanner in a.scanners.split(','):
        if not (lab/'scanners'/scanner/'gitleaks').is_file():skipped.append(dict(scanner=scanner,reason='actual scanner unavailable; no substitute'));continue
        for host in a.hosts.split(','):
            def meta(series,audit='off'):return dict(series=series,scanner=scanner,host=host,audit=audit)
            allarms=[(v,'default','standalone') for v in VERS]
            endpoints=[(VERS[0],'default','standalone'),(VERS[-1],'default','standalone'),(VERS[-1],'fused','standalone')]
            if 'versions' in selected:schedule(meta('versions'),proto['main_cases'],allarms,rotation=True)
            if 'direct' in selected:schedule(meta('direct'),proto['main_cases'],endpoints)
            if 'optional' in selected:
                for v in ['v3.8.0','v3.8.1']:schedule(meta('optional'),proto['throughput_cases'],[(v,'default','standalone'),(v,'fused','standalone')])
            if 'source' in selected:schedule(meta('source'),proto['throughput_cases'],[(VERS[0],'default','source-plugin'),(VERS[-1],'default','source-plugin'),(VERS[-1],'fused','source-plugin')])
            if 'audit' in selected:
                for audit in ['warm','cold']:schedule(meta('audit',audit),proto['audit_endpoint_cases'],endpoints)
            if 'load' in selected:schedule(meta('load'),proto['throughput_cases'],allarms+[(VERS[-1],'fused','standalone')],rounds=16,workers=4,rotation=True)
            if 'rss' in selected:
                for workers in [1,4]:
                    rss_arms=allarms+[(VERS[-1],'fused','standalone')] if a.rss_all_versions else endpoints
                    schedule(meta('rss'),['many-replacement-leaves','long-multiline'],rss_arms,rounds=16 if a.rss_all_versions else 9,workers=workers,phase='rss',rotation=a.rss_all_versions)
            if 'trace' in selected:schedule(meta('trace'),['small-clean','many-replacement-leaves','long-multiline'],endpoints,rounds=1,phase='trace')
    write(out/'unavailable.json',skipped)
    fields=['phase','policy_mode','deny_bash_sha256','deny_read_sha256','environment','series','scanner','host','audit','case','version','variant','distribution','round','order','workers','requests','wall_s','cpu_s','user_cpu_s','system_cpu_s','max_child_rss_kib','rss_sum_peak_kib','rss_sample_count','driver_cpu_s','success','eligible','cli_sha256','config_sha256','scanner_sha256']
    with (out/'samples.csv').open('w') as f:
        w=csv.DictWriter(f,fieldnames=fields,extrasaction='ignore');w.writeheader();w.writerows(rows)
    write(out/'completion.json',dict(rows=len(rows),measured=sum(r['phase']!='warmup' for r in rows),failed=sum(not r['success'] for r in rows),complete=True))
if __name__=='__main__':
    if '--worker' in sys.argv:worker(json.loads(Path(sys.argv[sys.argv.index('--worker')+1]).read_text()))
    else:main()
