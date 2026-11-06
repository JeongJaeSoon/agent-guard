#!/usr/bin/env python3
"""7개 실제 공개 배포본: 정책 고정 기본 실행 경로와 선택형 경로의 독립 실측."""
import csv,itertools,json,os,platform,shutil,subprocess,sys,tarfile
from pathlib import Path
import base_runtime as b
OUT=b.OUT;WORK=b.WORK;LOCK=b.LOCK
PROTOCOL='public-seven-partitioned-policy-fixed-v1';ROUNDS=9;ENDPOINT_ROUNDS=12;INSTALL_ROUNDS=14;WARMUP=1
ROWS=b.ROWS;ERRORS=b.ERRORS;INSTALL=b.INSTALL
PLATFORM='linux-x86_64-cgroup2-partitioned';FIXED=None;PROBES={}

def save(name,value):b.save(name,value)
def env_for(base,host,audit,mode,scanner,home):
    env=b.make_env(base,host,audit,mode,scanner,FIXED/'gitleaks.toml',home)
    env['AGENT_GUARD_DENY_READ_PATHS']=str(FIXED/'deny-read-paths.txt')
    env['AGENT_GUARD_DENY_BASH_PATTERNS']=str(FIXED/'deny-bash-patterns.txt')
    env['AGENT_GUARD_WARNING_DIR']=str(home/'warnings')
    return env

def checkpoint():
    b.summarize()
    path=OUT/'summary.json'
    if path.exists():
        records=json.loads(path.read_text())
        for row in records:
            row.update(protocol=PROTOCOL,policy_mode='fixed-v3.6.13-all-three-policies',elapsed_cpu_comparison_eligible=row['measurement']!='rss-profile',native_route_status=PROBES.get(row['version']+':'+row['mode'],{}).get('route_status','unverified'))
        save('summary.json',records)
        b.make_chunks()

def outputs_keep(outputs,errors):
    import hashlib
    directory=OUT/'outputs';directory.mkdir(exist_ok=True)
    for data in outputs+errors:(directory/(hashlib.sha256(data).hexdigest()+'.txt')).write_bytes(data)

def batch_command(base,home,payload,concurrency):
    if concurrency==1:return [str(base/'bin/agent-guard'),'hook-post-tool']
    script=WORK/'batch.sh'
    if not script.exists():script.write_text('#!/bin/sh\npids=\nfor i in 1 2 3 4; do "$1" hook-post-tool < "$2" > "$3/$i.out" 2> "$3/$i.err" & pids="$pids $!"; done\nstatus=0\nfor pid in $pids; do wait "$pid" || status=1; done\nexit "$status"\n')
    input_file=home/'input.json';input_file.write_bytes(payload)
    return ['sh',str(script),str(base/'bin/agent-guard'),str(input_file),str(home)]

def timing_matrix(conditions,cases,literal,scanner,measurement,rounds,profile=False):
    import hashlib
    for host,audit,name,concurrency in itertools.product(('claude','codex'),('off','on-warm'),cases,(1,4)):
        value=cases[name];payload=json.dumps({'tool_name':'mcp__benchmark__read','tool_response':value},separators=(',',':')).encode()
        for round_no in range(-WARMUP,rounds):
            i=max(round_no,0)%len(conditions);order=conditions[i:]+conditions[:i]
            # The 9-condition main series is one Latin rotation cycle.
            # Three endpoint conditions get four cycles, alternating reversal.
            if measurement=='endpoint-direct' and max(round_no,0)//len(conditions)%2:order=list(reversed(order))
            for version,mode,base in order:
                home=WORK/(measurement+'-home-'+version+'-'+mode+'-'+host+'-'+audit+'-'+name+'-'+str(concurrency));(home/'tmp').mkdir(parents=True,exist_ok=True)
                env=env_for(base,host,audit,mode,scanner,home);cmd=batch_command(base,home,payload,concurrency)
                row,stdout,stderr=b.measure(cmd,payload,env,home,profile=profile)
                outputs=[stdout] if concurrency==1 else [(home/f'{k}.out').read_bytes() for k in range(1,5)]
                errors=[stderr] if concurrency==1 else [(home/f'{k}.err').read_bytes() for k in range(1,5)]
                row.update(version=version,platform=PLATFORM,protocol=PROTOCOL,policy_mode='fixed-v3.6.13-all-three-policies',scanner='official-gitleaks-8.30.1',audit=audit,host=host,input=name,mode=mode,concurrency=concurrency,sample=round_no,measurement=measurement,execution_order=order.index((version,mode,base)),correct=all(b.valid_output(host,value,literal,o) for o in outputs),throughput_rps=concurrency/(row['elapsed_ms']/1000),elapsed_cpu_comparison_eligible=not profile,native_route_status=PROBES.get(version+':'+mode,{}).get('route_status','unverified'),child_stdout_sha256=[hashlib.sha256(o).hexdigest() for o in outputs],child_stderr_sha256=[hashlib.sha256(o).hexdigest() for o in errors])
                outputs_keep(outputs,errors)
                if round_no<0:b.jlog('warmups.jsonl',row)
                else:
                    ROWS.append(row);b.jlog('samples.jsonl',row)
                    if not row['correct'] or row['returncode'] or row['timeout']:ERRORS.append({k:row[k] for k in ('version','host','audit','input','mode','concurrency','sample','measurement','returncode','timeout','correct')})
                # Full numeric records in console provide a second evidence path.
                print(json.dumps(row,ensure_ascii=False),flush=True)
        checkpoint()

def probe(version,mode,base,scanner,name='installed-default-path'):
    cases,literal=b.payloads();value=cases['many-replacements'];payload=json.dumps({'tool_name':'mcp__benchmark__read','tool_response':value},separators=(',',':')).encode()
    home=WORK/('probe-home-'+version+'-'+mode+'-'+name);(home/'tmp').mkdir(parents=True,exist_ok=True)
    trace_dir=OUT/'traces';trace_dir.mkdir(exist_ok=True);trace=trace_dir/(version+'-'+mode+'-'+name+'.strace')
    row,stdout,stderr=b.measure(['strace','-f','-ttt','-T','-s','160','-e','trace=execve','-o',str(trace),str(base/'bin/agent-guard'),'hook-post-tool'],payload,env_for(base,'claude','off',mode,scanner,home),home)
    text=trace.read_text(errors='replace') if trace.exists() else ''
    calls={part:sum('execve(' in line and '= 0' in line and part in line for line in text.splitlines()) for part in ('redact-v1','prepare-v1','gitleaks','sha256sum','jq','awk','perl')}
    expected_native=tuple(map(int,version.split('.'))) >= (3,7,0)
    correct=b.valid_output('claude',value,literal,stdout) and row['returncode']==0 and not row['timeout']
    verified=correct and ((calls['redact-v1']>0) if expected_native else calls['redact-v1']==0) and (mode!='fused' or calls['prepare-v1']>0)
    status=('native-verified' if expected_native else 'shell-verified') if verified else 'fallback-or-route-unverified'
    row.update(version=version,mode=mode,name=name,measurement='separate-strace-probe',performance_comparison_eligible=False,correct=correct,calls=calls,expected_native=expected_native,route_status=status,trace_file=str(trace.relative_to(OUT)),trace_sha256=b.sha(trace) if trace.exists() else None,install_root=str(base),install_root_is_semver=all(c in '0123456789.' for c in base.name),stdout=stdout.decode(errors='replace'),stderr=stderr.decode(errors='replace'))
    outputs_keep([stdout],[stderr]);b.jlog('route-probes.jsonl',row)
    if name=='installed-default-path':PROBES[version+':'+mode]=row
    return row

def prepare(stage):
    global FIXED
    scanner_archive=b.download(b.SCANNER);scan=WORK/'scanner';scan.mkdir(exist_ok=True)
    with tarfile.open(scanner_archive) as tf:tf.extractall(scan,filter='data')
    scanner=scan/'gitleaks';scanner.chmod(0o755)
    versions={};archives={};boots={};preparations=[];archive_roots={}
    for release in LOCK['releases']:
        v=release['version'];asset=next(a for a in release['assets'] if a['name']==f'agent-guard-{v}.tar.gz');archive=b.download(asset);checksum=b.download(next(a for a in release['assets'] if a['name']==asset['name']+'.sha256'))
        if b.sha(archive)!=checksum.read_text().split()[0]:raise RuntimeError('published checksum mismatch '+v)
        archives[v]=archive;boots[v]=b.download(next(a for a in release['assets'] if a['name']=='bootstrap.sh'))
        extracted=WORK/('public-archive-'+v);extracted.mkdir(exist_ok=True)
        with tarfile.open(archive) as tf:tf.extractall(extracted,filter='data')
        archive_roots[v]=extracted
        if stage=='performance':
            home=WORK/('bootstrap-preparation-home-'+v);(home/'tmp').mkdir(parents=True,exist_ok=True)
            env=dict(os.environ,HOME=str(home),SHELL='/bin/bash',AGENT_GUARD_VERSION=v,AGENT_GUARD_HOME=str(home/'payload'),AGENT_GUARD_BIN_DIR=str(home/'local-bin'),AGENT_GUARD_GITLEAKS_BIN=str(scanner),AGENT_GUARD_LOG_MODE='off',AGENT_GUARD_RELEASE_CHECK='off')
            row,out,err=b.measure(['sh',str(boots[v])],b'',env,home);row.update(version=v,stage='untimed-performance-preparation',performance_comparison_eligible=False,bootstrap_sha256=b.sha(boots[v]),stdout=out.decode(errors='replace'),stderr=err.decode(errors='replace'))
            preparations.append(row);save('preparation-installs.json',preparations)
            if row['returncode'] or row['timeout']:raise RuntimeError('official pinned bootstrap preparation failed '+v+'; no archive-only substitution')
            installed=home/'payload'
            if b.sha(installed/'bin/agent-guard')!=b.sha(extracted/'bin/agent-guard'):raise RuntimeError('bootstrap installed CLI differs from verified archive '+v)
            versions[v]=installed
        else:versions[v]=extracted
    FIXED=WORK/'fixed-policy';FIXED.mkdir(exist_ok=True)
    for name in ('gitleaks.toml','deny-bash-patterns.txt','deny-read-paths.txt'):shutil.copyfile(archive_roots['3.6.13']/'config'/name,FIXED/name)
    manifest={'protocol':PROTOCOL,'stage':stage,'scanner_sha256':b.sha(scanner),'scanner_version':subprocess.check_output([str(scanner),'version'],text=True).strip(),'fixed_policy_sha256':{p.name:b.sha(p) for p in FIXED.iterdir()},'versions':{v:{'commit':next(r['sha'] for r in LOCK['releases'] if r['version']==v),'install_root':str(base),'root_basename':base.name,'cli_sha256':b.sha(base/'bin/agent-guard'),'bundled_policy_sha256':{name:b.sha(base/'config'/name) for name in ('gitleaks.toml','deny-bash-patterns.txt','deny-read-paths.txt')},'native_files':{str(p.relative_to(base)):b.sha(p) for p in (base/'libexec').glob('*') if p.is_file()}} for v,base in versions.items()}}
    save('manifest.json',manifest)
    return versions,archive_roots,archives,boots,scanner

def installations(versions,archives,boots,scanner):
    for n in range(INSTALL_ROUNDS):
        order=list(versions);i=n%len(order);order=order[i:]+order[:i]
        if n//len(order)%2:order.reverse()
        for version in order:
            ex=WORK/('extract-'+version+'-'+str(n));ex.mkdir();row,out,err=b.measure(['tar','-xzf',str(archives[version]),'-C',str(ex)],b'',os.environ.copy(),WORK)
            row.update(version=version,platform='linux-x86_64-cgroup2-installation',protocol=PROTOCOL,sample=n,execution_order=order.index(version),stage='archive-extraction-only',installed_bytes=sum(p.stat().st_size for p in ex.rglob('*') if p.is_file()),download_bytes=archives[version].stat().st_size);INSTALL.append(row);b.jlog('installation.jsonl',row);shutil.rmtree(ex)
            home=WORK/('install-home-'+version+'-'+str(n));(home/'tmp').mkdir(parents=True);sentinel='# preserve user configuration\nexport GUARD_EXPERIMENT_PRESERVE=yes\n';(home/'.bashrc').write_text(sentinel)
            env=dict(os.environ,HOME=str(home),SHELL='/bin/bash',AGENT_GUARD_VERSION=version,AGENT_GUARD_HOME=str(home/'payload'),AGENT_GUARD_BIN_DIR=str(home/'local-bin'),AGENT_GUARD_GITLEAKS_BIN=str(scanner),AGENT_GUARD_LOG_MODE='off',AGENT_GUARD_RELEASE_CHECK='off')
            for stage in ('pinned-bootstrap-fresh','pinned-bootstrap-refresh'):
                row,out,err=b.measure(['sh',str(boots[version])],b'',env,home)
                row.update(version=version,platform='linux-x86_64-cgroup2-installation',protocol=PROTOCOL,sample=n,execution_order=order.index(version),stage=stage,installed_bytes=sum(p.stat().st_size for p in (home/'payload').rglob('*') if p.is_file()),download_bytes=archives[version].stat().st_size+next(a['size'] for r in LOCK['releases'] if r['version']==version for a in r['assets'] if a['name']==f'agent-guard-{version}.tar.gz.sha256'),user_rc_preserved=(home/'.bashrc').read_text().startswith(sentinel),bootstrap_script_sha256=b.sha(boots[version]),dependencies='preinstalled; first dependency installation excluded')
                INSTALL.append(row);b.jlog('installation.jsonl',row);directory=OUT/'installation-logs';directory.mkdir(exist_ok=True)
                (directory/(version+'-'+str(n)+'-'+stage+'.stdout')).write_bytes(out);(directory/(version+'-'+str(n)+'-'+stage+'.stderr')).write_bytes(err)
                print(json.dumps(row),flush=True)
            save('installation.json',INSTALL)
            columns=sorted(set().union(*(r.keys() for r in INSTALL)))
            with (OUT/'installation.csv').open('w') as f:w=csv.DictWriter(f,fieldnames=columns);w.writeheader();w.writerows(INSTALL)
        b.make_chunks()
    summary=[]
    for version in versions:
        for stage in ('archive-extraction-only','pinned-bootstrap-fresh','pinned-bootstrap-refresh'):
            rows=[r for r in INSTALL if r['version']==version and r['stage']==stage]
            r=dict(version=version,stage=stage,protocol=PROTOCOL,platform='linux-x86_64-cgroup2-installation',n=len(rows),failures=sum(bool(x['returncode']) or x['timeout'] for x in rows))
            for metric in ('elapsed_ms','cpu_ms','max_child_rss_kib','installed_bytes','download_bytes'):r[metric]=b.stats([x[metric] for x in rows])
            summary.append(r)
    save('installation-summary.json',summary);b.make_chunks()

def main():
    stage=sys.argv[sys.argv.index('--stage')+1] if '--stage' in sys.argv else 'performance'
    if stage not in ('performance','installation'):raise ValueError('unknown stage '+stage)
    limits={n:Path('/sys/fs/cgroup/'+n).read_text().strip() for n in ('cpu.max','memory.max','memory.swap.max')};valid=limits=={'cpu.max':'200000 100000','memory.max':'1073741824','memory.swap.max':'0'}
    dependencies={}
    for command,args in [('python3',['--version']),('jq',['--version']),('curl',['--version']),('git',['--version']),('tar',['--version']),('perl',['-e','print $^V'])]:
        dependencies[command]=subprocess.check_output([command,*args],text=True,stderr=subprocess.STDOUT).splitlines()[0]
    save('environment.json',dict(protocol=PROTOCOL,stage=stage,platform=platform.platform(),uname=list(os.uname()),hostname=platform.node(),cgroup=limits,resource_limit_valid=valid,runtime_uid=os.getuid(),cpu_count_visible=os.cpu_count(),cpu_model=next((line.split(':',1)[1].strip() for line in Path('/proc/cpuinfo').read_text().splitlines() if line.startswith('model name')),'unknown'),proc_swaps=Path('/proc/swaps').read_text(),dependencies=dependencies,sh_target=os.path.realpath('/bin/sh'),compiler_path=shutil.which('cc'),separate_stage_host=True,no_cross_host_break_even=True))
    if not valid:raise RuntimeError('required cgroup limits not actually applied')
    save('plan.json',dict(protocol=PROTOCOL,stage=stage,versions=[r['version'] for r in LOCK['releases']],series_conditions='7 public default execution routes +3.8.0 fused+3.8.1 fused',series_repeats=ROUNDS,series_order='9 Latin cyclic rotations, one occurrence per execution position; one full warmup block before measured rounds',endpoint_conditions=['3.6.13 default','3.8.1 default','3.8.1 fused'],endpoint_repeats=ENDPOINT_ROUNDS,endpoint_order='3 cyclic rotations repeated four cycles, reversing alternating cycles',endpoint_measurement='endpoint-direct; never merged with main cli series',rss_repeats=ROUNDS,rss_inputs=['small-clean','many-replacements'],rss_measurement='rss-profile; elapsed/CPU/throughput ineligible for performance comparison',installation_repeats=INSTALL_ROUNDS,installation_order='14 rounds: seven Latin rotations then reversed rotations',warmup=WARMUP,timeout_seconds=b.TIMEOUT,retries=0,policy_mode='all three v3.6.13 policy files fixed through documented environment overrides; packaged default native selection otherwise preserved',audit_state='off or on-warm; new HOME per measurement/version/mode/host/audit/input/concurrency; one warmup then retained HOME for measured rounds; different inputs/concurrency/experiments do not share state; cache expiry possible',scanner=b.SCANNER,installation_scope='fresh/refresh include archive+checksum network, verification, setup; predownloaded bootstrap and dependency first install excluded; archive-only separate; CLI update dynamic-latest path unverified',primary_install_path='official pinned bootstrap installed under a non-semver payload root before performance timing',earlier_six_run='Separate protocol/cutoff; data never merged; no retry or replacement of original samples'))
    versions,archive_roots,archives,boots,scanner=prepare(stage)
    if stage=='installation':installations(versions,archives,boots,scanner);return
    cases,literal=b.payloads();save('inputs.json',cases)
    conditions=[(v,'default',base) for v,base in versions.items()]
    for version in ('3.8.0','3.8.1'):
        base=versions[version]
        if (base/'scripts/output-pipeline-experiment.sh').is_file() and (base/'libexec/agent-guard-redact-x86_64-unknown-linux-musl').is_file():conditions.append((version,'fused',base))
        else:ERRORS.append(dict(stage='optional-route',version=version,status='N/A',reason='public module or helper missing; no developer build or version substitution'))
    # Freeze support and execution order before collecting any timing samples.
    save('conditions.json',[dict(version=v,mode=m,install_root=str(base)) for v,m,base in conditions])
    for version,mode,base in conditions:probe(version,mode,base,scanner)
    save('route-probes.json',list(PROBES.values()))
    # Exact code and a separate layout probe document the earlier path issue.
    layout=[]
    for version in ('3.6.13','3.8.0'):
        source=versions[version];text=(source/'bin/agent-guard').read_text();start=text.find('is_semver_dir()');end=text.find('# A cache directory',start)
        old=WORK/version;shutil.copytree(source,old);r=probe(version,'default',old,scanner,name='semver-layout-supplement-not-original-run');r['source_condition_excerpt']=text[start:end];r['scope']='new independent layout-validation observation only; never used as original six-run performance result';layout.append(r)
    save('layout-validation.json',layout)
    timing_matrix(conditions,cases,literal,scanner,'cli',ROUNDS)
    endpoints=[c for wanted in [('3.6.13','default'),('3.8.1','default'),('3.8.1','fused')] for c in conditions if c[:2]==wanted]
    if len(endpoints)==3:timing_matrix(endpoints,cases,literal,scanner,'endpoint-direct',ENDPOINT_ROUNDS)
    else:ERRORS.append(dict(stage='endpoint-direct',status='N/A',reason='one required actual public execution route missing; no substitution'))
    profile_cases={name:cases[name] for name in ('small-clean','many-replacements')};timing_matrix(conditions,profile_cases,literal,scanner,'rss-profile',ROUNDS,profile=True)
    state=OUT/'audit-cache-state';state.mkdir(exist_ok=True);state_manifest=[]
    for home in WORK.glob('*home-*'):
        src=home/'.local/state/agent-guard'
        if not src.is_dir():continue
        dest=state/home.name;shutil.copytree(src,dest,dirs_exist_ok=True);state_manifest.extend(dict(home=home.name,path=str(p.relative_to(dest)),sha256=b.sha(p),bytes=p.stat().st_size) for p in dest.rglob('*') if p.is_file())
    save('audit-cache-state.json',state_manifest);save('errors.json',ERRORS);checkpoint()

# Partitioning is outside every frozen measurement function. The facade limits
# only the outer Cartesian loop, retaining its original order and all samples.
_ORIGINAL_MAIN=main
_ORIGINAL_CHECKPOINT=checkpoint
_ORIGINAL_MEASURE=b.measure
_REAL_ITERTOOLS=itertools
PARTITION={}

class PartitionProduct:
    def product(self,*groups,**kwargs):
        if len(groups)!=4 or set(groups[0])!={'claude','codex'} or set(groups[1])!={'off','on-warm'}:
            raise RuntimeError('unexpected Cartesian loop; refuse a silent partition change')
        selected=(tuple(x for x in groups[0] if x==PARTITION['agent_host']),
                  tuple(x for x in groups[1] if x==PARTITION['audit']),
                  tuple(x for x in groups[2] if x==PARTITION['input']),groups[3])
        return _REAL_ITERTOOLS.product(*selected,**kwargs)

def measured_with_partition_metadata(*args,**kwargs):
    row,stdout,stderr=_ORIGINAL_MEASURE(*args,**kwargs)
    # These fields are appended after the unchanged measurement interval ended.
    row.update(execution_host=PARTITION['execution_host'],partition_id=PARTITION['partition_id'],protocol=PROTOCOL)
    return row,stdout,stderr

def decorate_outputs():
    for name in ('environment.json','plan.json','manifest.json'):
        path=OUT/name
        if not path.exists():continue
        data=json.loads(path.read_text());data.update(protocol=PROTOCOL,execution_host=PARTITION['execution_host'],partition_id=PARTITION['partition_id'],partition_input=PARTITION['input'],partition_agent_host=PARTITION['agent_host'],partition_audit=PARTITION['audit'],across_partition_aggregation_allowed=False,installation_comparison_source='existing completed seven-version installation artifact; not repeated here')
        save(name,data)
    path=OUT/'summary.json'
    if path.exists():
        records=json.loads(path.read_text())
        for row in records:row.update(protocol=PROTOCOL,execution_host=PARTITION['execution_host'],partition_id=PARTITION['partition_id'],across_partition_aggregation_allowed=False)
        save('summary.json',records)
        b.make_chunks()

def partition_checkpoint():
    _ORIGINAL_CHECKPOINT()
    decorate_outputs()

def partition_main():
    global PARTITION,itertools,checkpoint
    import argparse,hashlib
    parser=argparse.ArgumentParser(description='Frozen seven-version experiment, partitioned only by input/agent host/audit.')
    parser.add_argument('--stage',choices=['performance'],default='performance')
    parser.add_argument('--only-input',required=True,choices=['small-clean','many-replacements','long-string','control-multiline','large-output'])
    parser.add_argument('--only-host',required=True,choices=['claude','codex'])
    parser.add_argument('--only-audit',required=True,choices=['off','on-warm'])
    args=parser.parse_args()
    partition_id=args.only_input+'--'+args.only_host+'--'+args.only_audit
    execution_host=os.environ.get('AG_EXPERIMENT_EXECUTION_HOST',platform.node())
    PARTITION=dict(protocol=PROTOCOL,partition_id=partition_id,input=args.only_input,agent_host=args.only_host,audit=args.only_audit,execution_host=execution_host,container_hostname=platform.node(),filters_only=True,series_rounds=ROUNDS,endpoint_rounds=ENDPOINT_ROUNDS,rss_rounds=ROUNDS,warmup=WARMUP,timeout_seconds=b.TIMEOUT,retries=0,installation_remeasured=False,bootstrap_preparation='unchanged preparation needed to establish the real standalone payload; excluded from installation and usage comparisons',comparison_scope='versions and modes within this one partition share the same actual host; different input/agent-host/audit partitions use different VMs; do not aggregate across partitions or attribute cross-input cache effects',split_reason='Predeclared execution-tool partition after initial partial records showed monolithic job budget insufficient; product outcomes were not used to choose a rerun; original six/seven partial evidence retained separately')
    save('partition.json',PARTITION)
    itertools=PartitionProduct()
    b.measure=measured_with_partition_metadata
    checkpoint=partition_checkpoint
    try:_ORIGINAL_MAIN()
    finally:decorate_outputs()

if __name__=='__main__':
    try:partition_main()
    except Exception as e:ERRORS.append(dict(stage='fatal',error=repr(e)));save('errors.json',ERRORS);checkpoint();raise
