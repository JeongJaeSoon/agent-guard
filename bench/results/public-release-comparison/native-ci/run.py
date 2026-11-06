#!/usr/bin/env python3
"""공개 package/native 정확도·호환성 전용; 성능 재실험이나 개발자 빌드가 아니다."""
import csv,hashlib,json,os,shutil,subprocess,tarfile
from pathlib import Path
import base_runtime as b
HERE=Path(__file__).parent;OUT=b.OUT;WORK=b.WORK;LOCK=b.LOCK
CASES=json.loads((HERE/'source-cases.json').read_text())+json.loads((HERE/'supplement-cases.json').read_text())
ROWS=[];ERRORS=[];TIMEOUT=20
b.TIMEOUT=TIMEOUT

def save(name,value):b.save(name,value)
def expected_actual(host,response,stdout):
    if not stdout.strip():return response
    obj=json.loads(stdout)
    if host=='claude':return obj['hookSpecificOutput']['updatedToolOutput']
    prefix='Agent Guard sanitized tool output:\n';context=obj['hookSpecificOutput']['additionalContext']
    if not context.startswith(prefix):raise ValueError('unexpected Codex additionalContext prefix')
    return json.loads(context[len(prefix):])

def keep(row,stdout,stderr):
    row.update(stdout=stdout.decode('utf-8',errors='replace'),stderr=stderr.decode('utf-8',errors='replace'),stdout_sha256=hashlib.sha256(stdout).hexdigest(),stderr_sha256=hashlib.sha256(stderr).hexdigest())
    ROWS.append(row)
    b.jlog('correctness-raw.jsonl',row)
    # Also retain exact bytes in case a malformed response is not UTF-8.
    directory=OUT/'exact-outputs';directory.mkdir(exist_ok=True)
    for content in (stdout,stderr):(directory/(hashlib.sha256(content).hexdigest()+'.bin')).write_bytes(content)
    save('correctness-raw.json',ROWS)
    fields=['version','host','case','mode','route','scanner','audit','kind','passed','classification','returncode','timeout','actual_route_verified','trace_file','cli_sha256']
    with (OUT/'correctness-summary.csv').open('w') as f:
        w=csv.DictWriter(f,fieldnames=fields,extrasaction='ignore');w.writeheader();w.writerows(ROWS)
    summaries=[]
    for version in sorted({r['version'] for r in ROWS}):
        for mode in sorted({r['mode'] for r in ROWS if r['version']==version}):
            subset=[r for r in ROWS if r['version']==version and r['mode']==mode]
            summaries.append(dict(version=version,mode=mode,route='public_standalone_archive',scanner='official_gitleaks_8.30.1_linux_x64',platform='linux-x86_64-cgroup2',n=len(subset),passed=sum(r.get('passed') is True for r in subset),failed=sum(r.get('passed') is False for r in subset),na=sum(r.get('passed') is None for r in subset),cases=[{k:r.get(k) for k in ('host','case','kind','passed','classification','actual_route_verified','trace_file')} for r in subset]))
    save('correctness-combined-summary.json',summaries)
    chunks=OUT/'chunks';chunks.mkdir(exist_ok=True);index=[]
    for name in ('correctness-raw.jsonl','correctness-raw.json','correctness-combined-summary.json'):
        source=OUT/name
        if name.endswith('.jsonl'):
            parts=[];part=[];size=0
            for line in source.read_text().splitlines(keepends=True):
                if part and size+len(line.encode())>220000:parts.append(''.join(part));part=[];size=0
                part.append(line);size+=len(line.encode())
            if part:parts.append(''.join(part))
        else:
            parts=[];part=[];size=2
            for record in json.loads(source.read_text()):
                needed=len(json.dumps(record,ensure_ascii=False).encode())+1
                if part and size+needed>220000:parts.append(json.dumps(part,ensure_ascii=False));part=[];size=2
                part.append(record);size+=needed
            if part:parts.append(json.dumps(part,ensure_ascii=False))
        for i,text in enumerate(parts):
            target=chunks/(name+'.'+str(i).zfill(4)+'.txt');target.write_text(text);index.append(dict(source=name,chunk=str(target.relative_to(OUT)),sha256=b.sha(target),bytes=target.stat().st_size))
    save('chunk-index.json',index)
    print(json.dumps({k:row.get(k) for k in ('version','host','case','mode','kind','passed','classification','actual_route_verified')}),flush=True)

def invoke(version,base,host,mode,case,response,expected,sensitive,scanner,config,variant=None,command='hook-post-tool',raw_payload=None,infra='open',contract=None,trace=False):
    home=WORK/('correctness-home-'+version+'-'+mode+'-'+host+'-'+case);(home/'tmp').mkdir(parents=True,exist_ok=True)
    env=b.make_env(base,host,'off','fused' if 'fused' in mode else 'default',scanner,config,home)
    env['AGENT_GUARD_WARNING_DIR']=str(home/'warnings');env['AGENT_GUARD_INFRA_FAILURE_MODE']=infra
    if not mode.startswith('bundled-'):
        env['AGENT_GUARD_DENY_READ_PATHS']=str(versions_policy_base/'config/deny-read-paths.txt')
        env['AGENT_GUARD_DENY_BASH_PATTERNS']=str(versions_policy_base/'config/deny-bash-patterns.txt')
    if variant:env.update(variant)
    payload=raw_payload if raw_payload is not None else json.dumps({'tool_name':'mcp__report__read','tool_input':{},'tool_response':response,'session_id':'accuracy-fixed'},ensure_ascii=False).encode()
    cmd=[str(base/'bin/agent-guard'),command];trace_file=None
    if trace:
        directory=OUT/'traces';directory.mkdir(exist_ok=True);trace_file=directory/(version+'-'+host+'-'+mode+'-'+case+'.strace')
        cmd=['strace','-f','-ttt','-T','-s','160','-e','trace=execve','-o',str(trace_file),*cmd]
    metrics,stdout,stderr=b.measure(cmd,payload,env,home)
    row=dict(version='v'+version,host=host,case=case,mode=mode,route='public_standalone_archive',scanner='official_gitleaks_8.30.1_linux_x64' if 'GITLEAKS_BIN' not in json.dumps(variant or {}) else 'fault_injected_scanner',audit='off',kind='separate_instrumentation' if trace else 'fault_or_compatibility' if contract else 'independent_semantic_accuracy',input=payload.decode('utf-8',errors='replace'),expected=expected,sensitive=sensitive,cli_sha256=b.sha(base/'bin/agent-guard'),returncode=metrics['returncode'],timeout=metrics['timeout'],sample_count=1,performance_comparison_eligible=False,policy_mode='bundled-3.8.1' if mode.startswith('bundled-') else 'common-v3.8.0',config_sha256=b.sha(config),trace_file=str(trace_file.relative_to(OUT)) if trace_file else None,actual_route_verified=None)
    try:
        if contract:
            if contract=='infra-open':passed=metrics['returncode']==0 and b'AGENT_GUARD_INFRA_FAILURE_MODE=open' in stderr
            elif contract=='infra-closed':passed=metrics['returncode']==2 and b'closed' in stderr.lower()
            elif contract=='malformed-reject':passed=metrics['returncode']==2 and bool(stderr.strip())
            elif contract=='unknown-tool-pass-through':passed=metrics['returncode']==0 and not stdout.strip()
            else:raise ValueError('unknown fixed contract '+contract)
            row['contract']=contract
        else:
            actual=expected_actual(host,response,stdout);row['actual']=actual;passed=metrics['returncode']==0 and actual==expected
        row['passed']=passed and not metrics['timeout']
        row['classification']='pass' if row['passed'] else ('timeout' if metrics['timeout'] else 'false_positive_or_overmask' if not sensitive else 'masking_or_shape_or_contract_mismatch')
    except Exception as e:row.update(passed=False,classification='protocol_or_harness_error',error=repr(e))
    if trace and trace_file.exists():
        text=trace_file.read_text(errors='replace');row['trace_sha256']=b.sha(trace_file)
        # These are process-call observations, never timing attribution.
        row['observed_calls']={name:sum(name in line and 'execve(' in line and '= 0' in line for line in text.splitlines()) for name in ('prepare-v1','redact-v1','gitleaks','jq','wrong-prepare')}
        if mode=='fused':row['actual_route_verified']=row['observed_calls']['prepare-v1']>0 and row['observed_calls']['redact-v1']>0
        elif mode=='fused-wrong-prepare':row['actual_route_verified']=row['observed_calls']['wrong-prepare']>0 and row['observed_calls']['jq']>0
        elif mode=='fused-missing-module':row['actual_route_verified']=row['observed_calls']['prepare-v1']==0 and row['observed_calls']['redact-v1']>0
        elif mode=='fused-missing-redactor':row['actual_route_verified']=row['observed_calls']['prepare-v1']>0 and row['observed_calls']['redact-v1']==0 and row['observed_calls']['jq']>0
        elif mode=='fused-missing-prepare':row['actual_route_verified']=row['observed_calls']['prepare-v1']==0 and row['observed_calls']['redact-v1']>0 and row['observed_calls']['jq']>0
        else:row['actual_route_verified']=row['observed_calls']['redact-v1']>0 if (base/'libexec/agent-guard-redact-x86_64-unknown-linux-musl').is_file() else row['observed_calls']['redact-v1']==0
    keep(row,stdout,stderr)

def main():
    global versions_policy_base
    limits={n:Path('/sys/fs/cgroup/'+n).read_text().strip() for n in ('cpu.max','memory.max','memory.swap.max')}
    valid=limits=={'cpu.max':'200000 100000','memory.max':'1073741824','memory.swap.max':'0'}
    save('environment.json',dict(platform=list(os.uname()),cgroup=limits,resource_limit_valid=valid,runtime_uid=os.getuid(),kind='correctness_only_not_performance',timeout_seconds=TIMEOUT,retries=0))
    if not valid:raise RuntimeError('actual resource limits do not match required protocol')
    save('plan.json',dict(case_count=len(CASES),sample_count_per_cell=1,timeout_seconds=TIMEOUT,retries=0,kind='public_archive_correctness_only',independent_expectations='unchanged 15 original + 4 corpus-shaped semantic cases from macOS source correctness; copied files and hashes preserved',source_case_sha256=b.sha(HERE/'source-cases.json'),supplement_case_sha256=b.sha(HERE/'supplement-cases.json'),scanner=b.SCANNER,config='v3.8.0 public archive common bytes across all versions (matches source accuracy config)',hosts=['claude','codex'],native_versions='seven real public archives; default helper auto selection; optional fused on3.8.0/3.8.1 only when module+core exist; non-semver install directories to avoid plugin-cache semantics',fallback_faults=['missing prepare path','invalid prepare acknowledgement','missing redactor path','missing module in isolated untracked installed copy'],compatibility=['unknown tool PreToolUse empty pass-through','malformed Pre/PostToolUse JSON reject','scanner readiness infrastructure open/closed'],unknown_native_host_event='N/A: Claude/Codex applications not installed; manifest unknown event registration inspected but no actual host dispatcher available',v381=LOCK['v381']))
    save('accuracy_cases.json',CASES)
    scanner_archive=b.download(b.SCANNER);scan=WORK/'scanner';scan.mkdir(exist_ok=True)
    with tarfile.open(scanner_archive) as tf:tf.extractall(scan,filter='data')
    scanner=scan/'gitleaks';scanner.chmod(0o755);versions={}
    for r in LOCK['releases']:
        version=r['version'];asset=next(a for a in r['assets'] if a['name']==f'agent-guard-{version}.tar.gz');archive=b.download(asset);checksum=b.download(next(a for a in r['assets'] if a['name']==asset['name']+'.sha256'))
        if b.sha(archive)!=checksum.read_text().split()[0]:raise RuntimeError('published archive checksum mismatch '+version)
        dest=WORK/('public-package-'+version);dest.mkdir(exist_ok=True)
        with tarfile.open(archive) as tf:tf.extractall(dest,filter='data')
        versions[version]=dest
    versions_policy_base=versions['3.8.0']
    config=WORK/'common-gitleaks.toml';shutil.copyfile(versions_policy_base/'config/gitleaks.toml',config)
    manifest={'scanner_sha256':b.sha(scanner),'scanner_version':subprocess.check_output([str(scanner),'version'],text=True).strip(),'common_config_sha256':b.sha(config),'bundled_381_config_sha256':b.sha(versions['3.8.1']/'config/gitleaks.toml'),'common_deny_read_sha256':b.sha(versions_policy_base/'config/deny-read-paths.txt'),'common_deny_bash_sha256':b.sha(versions_policy_base/'config/deny-bash-patterns.txt'),'versions':{v:{'commit':next(r['sha'] for r in LOCK['releases'] if r['version']==v),'cli_sha256':b.sha(base/'bin/agent-guard'),'native_files':{str(p.relative_to(base)):b.sha(p) for p in (base/'libexec').glob('*') if p.is_file()}} for v,base in versions.items()}}
    core_paths=[versions[v]/'libexec/agent-guard-redact-x86_64-unknown-linux-musl' for v in ('3.8.0','3.8.1')]
    manifest['same_native_core_bytes_380_381']=(b.sha(core_paths[0])==b.sha(core_paths[1])) if all(p.is_file() for p in core_paths) else None
    save('manifest.json',manifest)
    conditions=[(v,'default',base) for v,base in versions.items()]
    fused_versions=[]
    for version in ('3.8.0','3.8.1'):
        base=versions[version];core=base/'libexec/agent-guard-redact-x86_64-unknown-linux-musl';module=base/'scripts/output-pipeline-experiment.sh'
        if core.is_file() and module.is_file():conditions.append((version,'fused',base));fused_versions.append(version)
        else:ERRORS.append(dict(stage='fused',version=version,status='N/A',reason='module or native helper missing from public archive; no developer build substituted'))
    for host in ('claude','codex'):
        for case in CASES:
            for version,mode,base in conditions:invoke(version,base,host,mode,case['case'],case['response'],case['expected'],case['sensitive'],scanner,config)
    bundled_config=versions['3.8.1']/'config/gitleaks.toml'
    for host in ('claude','codex'):
        for case in CASES:
            for mode in ('bundled-default','bundled-fused'):
                if mode=='bundled-fused' and '3.8.1' not in fused_versions:continue
                invoke('3.8.1',versions['3.8.1'],host,mode,case['case'],case['response'],case['expected'],case['sensitive'],scanner,bundled_config)
    for version,base in versions.items():
        for host in ('claude','codex'):
            invoke(version,base,host,'default','unknown-tool-pre',None,None,False,scanner,config,command='hook-pre-tool',raw_payload=b'{"tool_name":"UnknownFutureTool","tool_input":{},"session_id":"unknown-fixed"}',contract='unknown-tool-pass-through')
            for command in ('hook-pre-tool','hook-post-tool'):invoke(version,base,host,'default','malformed-'+command,None,None,True,scanner,config,command=command,raw_payload=b'{"tool_name":',contract='malformed-reject')
            for infra in ('open','closed'):invoke(version,base,host,'default','scanner-readiness-failure-'+infra,None,None,True,scanner,config,variant={'AGENT_GUARD_GITLEAKS_BIN':'/bin/false'},command='hook-pre-tool',raw_payload=b'{"tool_name":"UnknownFutureTool","tool_input":{},"session_id":"failure-fixed"}',infra=infra,contract='infra-'+infra)
        for host,path in (('claude',base/'hooks/hooks.json'),('codex',base/'hooks.json')):
            data=json.loads(path.read_text()) if path.is_file() else {};keep(dict(version='v'+version,host=host,case='unknown-native-hook-event',mode='default',route='public_standalone_archive',scanner='official_gitleaks_8.30.1_linux_x64',audit='off',kind='host_dispatch_unverified',passed=None,classification='N/A actual Claude/Codex runtime not installed',registered_unknown_event='UnknownFutureEvent' in data.get('hooks',{}),returncode=None,timeout=False,actual_route_verified=False),b'',b'')
    # Default native selection is verified in separate representative calls,
    # after semantic/fault checks and outside any performance measurement.
    selected={'response':{'rows':['PASSWORD=precision-Secret-472962']*32,'clean':'visible'},'expected':{'rows':['PASSWORD=[REDACTED]']*32,'clean':'visible'}}
    for version,installed in versions.items():
        for host in ('claude','codex'):invoke(version,installed,host,'default','assignment-default-trace',selected['response'],selected['expected'],True,scanner,config,trace=True)
    for version in fused_versions:
        base=versions[version]
        wrong=WORK/'wrong-prepare';wrong.write_text("#!/bin/sh\nprintf '%s\\n' wrong-prepare-ack\n");wrong.chmod(0o755)
        altered=WORK/('public-package-'+version+'-module-missing');shutil.copytree(base,altered);(altered/'scripts/output-pipeline-experiment.sh').unlink()
        selected={'response':{'rows':['PASSWORD=precision-Secret-472962']*32,'clean':'visible'},'expected':{'rows':['PASSWORD=[REDACTED]']*32,'clean':'visible'}}
        variants=[('fused',base,None),('fused-missing-prepare',base,{'AGENT_GUARD_EXPERIMENTAL_OUTPUT_PREPARE_BIN':str(WORK/'does-not-exist-prepare')}),('fused-wrong-prepare',base,{'AGENT_GUARD_EXPERIMENTAL_OUTPUT_PREPARE_BIN':str(wrong)}),('fused-missing-redactor',base,{'AGENT_GUARD_RUST_CORE_BIN':str(WORK/'does-not-exist-redactor')}),('fused-missing-module',altered,None)]
        for host in ('claude','codex'):
            for mode,installed,variant in variants:invoke(version,installed,host,mode,'assignment-fallback-trace',selected['response'],selected['expected'],True,scanner,config,variant=variant,trace=True)
    # Verify no bytes in any original public installation were modified.
    save('installation-preservation.json',{v:{'cli_unchanged':b.sha(base/'bin/agent-guard')==manifest['versions'][v]['cli_sha256'],'native_unchanged':all(b.sha(base/name)==digest for name,digest in manifest['versions'][v]['native_files'].items())} for v,base in versions.items()})
    save('errors.json',ERRORS)
if __name__=='__main__':
    try:main()
    except Exception as e:ERRORS.append(dict(stage='fatal',error=repr(e)));save('errors.json',ERRORS);raise
