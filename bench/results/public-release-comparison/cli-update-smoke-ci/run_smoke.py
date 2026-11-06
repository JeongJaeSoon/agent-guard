#!/usr/bin/env python3
"""공개 standalone의 실제 CLI update 호환성 smoke. 성능 측정이 아니다."""
import hashlib,json,os,platform,shutil,signal,subprocess,tarfile,time,traceback,urllib.request
from pathlib import Path

OUT=Path('/results-cli-update');WORK=Path('/tmp/public-cli-update-smoke')
LOCK_PATH=Path(__file__).parent/'release-lock.json';LOCK=json.loads(LOCK_PATH.read_text())
VERSIONS=[r['version'] for r in LOCK['releases']]
assert VERSIONS==['3.6.13','3.6.14','3.6.15','3.7.0','3.7.1','3.8.0','3.8.1']
TIMEOUT=120;ROWS=[];ERRORS=[]
SCANNER={'url':'https://github.com/gitleaks/gitleaks/releases/download/v8.30.1/gitleaks_8.30.1_linux_x64.tar.gz','sha256':'551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb'}

def sha(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()
def save(name,data):(OUT/name).write_text(json.dumps(data,ensure_ascii=False,indent=2)+'\n')
def asset(version,name):return next(a for r in LOCK['releases'] if r['version']==version for a in r['assets'] if a['name']==name)
def manifest(root):
    return [{'path':str(p.relative_to(root)),**({'symlink':os.readlink(p)} if p.is_symlink() else {'bytes':p.stat().st_size,'sha256':sha(p)})} for p in sorted(root.rglob('*')) if p.is_file() or p.is_symlink()]
def execute(command,env,cwd,prefix):
    # No latency/CPU/RSS values: evidence wrapper changes execution overhead.
    with (OUT/(prefix+'.stdout')).open('wb') as out,(OUT/(prefix+'.stderr')).open('wb') as err:
        proc=subprocess.Popen(command,env=env,cwd=cwd,stdout=out,stderr=err,start_new_session=True)
        timeout=False
        try:status=proc.wait(timeout=TIMEOUT)
        except subprocess.TimeoutExpired:
            timeout=True;os.killpg(proc.pid,signal.SIGKILL);status=proc.wait()
    return {'command':command,'returncode':status,'timeout':timeout,'stdout_path':prefix+'.stdout','stderr_path':prefix+'.stderr','performance':'N/A: compatibility only, n1; curl evidence wrapper adds overhead'}
def curl_wrapper(directory):
    directory.mkdir()
    wrapper=directory/'curl'
    wrapper.write_text('''#!/usr/bin/python3
import hashlib,json,os,pathlib,shutil,subprocess,sys,time
args=sys.argv[1:]
status=subprocess.call(['/usr/bin/curl',*args])
record={'args':args,'returncode':status,'step':os.environ.get('GUARD_SMOKE_STEP'),'real_executable':'/usr/bin/curl'}
target=None
for i,arg in enumerate(args):
 if arg in ('-o','--output') and i+1<len(args):target=pathlib.Path(args[i+1])
 elif arg.startswith('--output='):target=pathlib.Path(arg.split('=',1)[1])
out=pathlib.Path(os.environ['GUARD_SMOKE_EVIDENCE'])
if target is not None and target.is_file() and str(target)!='/dev/null':
 data=target.read_bytes();digest=hashlib.sha256(data).hexdigest()
 record.update(output_path=str(target),bytes=len(data),sha256=digest)
 if target.name.endswith('bootstrap.sh') or target.name.endswith('.sha256'):
  saved=out/'downloaded'/str(digest+'-'+target.name);saved.parent.mkdir(exist_ok=True)
  saved.write_bytes(data);record['saved_path']=str(saved.relative_to(out))
with (out/'curl-downloads.jsonl').open('a') as log:log.write(json.dumps(record)+'\\n')
sys.exit(status)
''')
    wrapper.chmod(0o755);return wrapper
def downloads():
    path=OUT/'curl-downloads.jsonl'
    return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
def main():
    OUT.mkdir(exist_ok=True);WORK.mkdir(exist_ok=False);(OUT/'steps').mkdir();(OUT/'downloaded').mkdir()
    cgroup={x:Path('/sys/fs/cgroup/'+x).read_text().strip() for x in ('cpu.max','memory.max','memory.swap.max','pids.max')}
    compilers={x:shutil.which(x) for x in ('cc','gcc','clang','rustc','cargo')}
    environment={'platform':platform.platform(),'uname':list(platform.uname()),'uid':os.getuid(),'gid':os.getgid(),'cgroup':cgroup,
                 'compiler_paths':compilers,'compiler_absence_verified':not any(compilers.values()),'release_lock_sha256':sha(LOCK_PATH),
                 'resource_limits_valid':cgroup['cpu.max']=='200000 100000' and cgroup['memory.max']=='1073741824' and cgroup['memory.swap.max']=='0'}
    save('environment.json',environment)
    if not environment['resource_limits_valid'] or not environment['compiler_absence_verified']:raise RuntimeError('required environment not applied')
    save('plan.json',{'versions':VERSIONS,'steps':list(zip(VERSIONS,VERSIONS[1:])),'samples_per_step':1,'timeout_seconds':TIMEOUT,'retries':0,
                     'cohort':'one sequential actual public standalone CLI update chain',
                     'pin':'AGENT_GUARD_VERSION is inherited by the downloaded bootstrap; target is verified after each actual CLI update',
                     'command':'<isolated public-bin>/agent-guard update',
                     'wrapper':'/usr/bin/curl invoked with identical arguments and inherited stdio; after return, downloaded bootstrap/checksum text copied and every output file hashed; original returncode preserved',
                     'timing':'N/A; wrapper adds execution, copying and hashing overhead; no percentages or performance claims',
                     'failure':'stop the dependent chain at first failure; preserve original output, no expectation relaxation or timeout change'})
    scanner_archive=WORK/'scanner.tar.gz'
    with urllib.request.urlopen(SCANNER['url'],timeout=60) as response,scanner_archive.open('wb') as out:shutil.copyfileobj(response,out)
    if sha(scanner_archive)!=SCANNER['sha256']:raise RuntimeError('scanner archive hash mismatch')
    scan_dir=WORK/'scanner';scan_dir.mkdir()
    with tarfile.open(scanner_archive) as archive:archive.extractall(scan_dir,filter='data')
    scanner=scan_dir/'gitleaks';scanner.chmod(0o755);save('scanner.json',dict(SCANNER,binary_sha256=sha(scanner),version=subprocess.check_output([str(scanner),'version'],text=True).strip()))
    case=WORK/'isolated-user';case.mkdir();(case/'tmp').mkdir();payload=case/'payload';public=case/'public-bin'
    rc=case/'.bashrc';sentinel='# existing user rc must survive CLI update\nexport CLI_UPDATE_SMOKE_PRESERVE=yes\n';rc.write_text(sentinel)
    wrapper=curl_wrapper(WORK/'evidence-bin')
    env=dict(os.environ,HOME=str(case),TMPDIR=str(case/'tmp'),SHELL='/bin/bash',PATH=str(wrapper.parent)+':'+os.environ['PATH'],
             AGENT_GUARD_VERSION=VERSIONS[0],AGENT_GUARD_HOME=str(payload),AGENT_GUARD_BIN_DIR=str(public),
             AGENT_GUARD_GITLEAKS_BIN=str(scanner),AGENT_GUARD_LOG_MODE='off',AGENT_GUARD_RELEASE_CHECK='off',
             GUARD_SMOKE_EVIDENCE=str(OUT),GUARD_SMOKE_STEP='prepare')
    first_boot=WORK/'initial-bootstrap.sh';first=asset(VERSIONS[0],'bootstrap.sh')
    with urllib.request.urlopen(first['url'],timeout=60) as response,first_boot.open('wb') as out:shutil.copyfileobj(response,out)
    if sha(first_boot)!=first['digest'].removeprefix('sha256:'):raise RuntimeError('initial published bootstrap hash mismatch')
    shutil.copyfile(first_boot,OUT/'initial-bootstrap.sh')
    prep=execute(['sh',str(first_boot)],env,case,'preparation')
    initial_archive=asset(VERSIONS[0],f'agent-guard-{VERSIONS[0]}.tar.gz')
    initial_records=[r for r in downloads() if initial_archive['url'] in r['args']]
    initial_version=subprocess.check_output([str(public/'agent-guard'),'version'],env=env,text=True,timeout=10).strip() if prep['returncode']==0 else None
    prep.update(initial_bootstrap_sha256=sha(first_boot),initial_archive_records=initial_records,
                initial_archive_lock_verified=len(initial_records)==1 and initial_records[0].get('sha256')==initial_archive['digest'].removeprefix('sha256:'),
                initial_cli_version=initial_version,initial_cli_sha256=sha(payload/'bin/agent-guard') if (payload/'bin/agent-guard').is_file() else None)
    save('preparation.json',prep)
    if prep['returncode'] or prep['timeout'] or not prep['initial_archive_lock_verified'] or initial_version!='agent-guard '+VERSIONS[0]:raise RuntimeError('initial standalone preparation failed')
    local=payload/'local-user-settings.txt';local.write_text('preserved unrelated local settings\n')
    custom=payload/'config/custom-user.toml';custom.write_text('# preserved user-added config\n')
    external=case/'external-gitleaks.toml';shutil.copyfile(payload/'config/gitleaks.toml',external)
    with external.open('a') as out:out.write('\n# preserve external custom policy\n')
    env['AGENT_GUARD_GITLEAKS_CONFIG']=str(external)
    for step,(old,new) in enumerate(zip(VERSIONS,VERSIONS[1:])):
        prefix=f'steps/{step}-{old}-to-{new}';before=manifest(payload)
        source_cli_sha256=sha(payload/'bin/agent-guard')
        source_version=subprocess.check_output([str(public/'agent-guard'),'version'],env=env,text=True,timeout=10).strip()
        preserved_before={str(p.relative_to(case)):sha(p) for p in (local,custom,external)}
        link_before=os.readlink(public/'agent-guard');rc_before=rc.read_bytes()
        env.update(AGENT_GUARD_VERSION=new,GUARD_SMOKE_STEP=str(step));offset=len(downloads())
        row=execute([str(public/'agent-guard'),'update'],env,case,prefix)
        observed=downloads()[offset:]
        try:final_version=subprocess.check_output([str(public/'agent-guard'),'version'],env=env,text=True,timeout=10).strip()
        except Exception as exc:final_version=repr(exc)
        preserved_after={str(p.relative_to(case)):sha(p) if p.is_file() else None for p in (local,custom,external)}
        final_tree=manifest(payload);save(prefix+'-tree-before.json',before);save(prefix+'-tree-after.json',final_tree)
        dynamic=[r for r in observed if any('releases/latest/download/bootstrap.sh' in a for a in r['args'])]
        dynamic_matches=[release['version'] for release in LOCK['releases'] for a in release['assets']
                         if a['name']=='bootstrap.sh' and len(dynamic)==1 and a['digest'].removeprefix('sha256:')==dynamic[0].get('sha256')]
        native_checks=[]
        for sidecar in (payload/'libexec').glob('*.sha256'):
            binary=sidecar.with_name(sidecar.name.removesuffix('.sha256'))
            expected=sidecar.read_text().split()[0]
            actual=sha(binary) if binary.is_file() else None
            native_checks.append({'binary':str(binary.relative_to(payload)),'expected':expected,'actual':actual,'verified':actual==expected})
        expected_native_count=4 if tuple(map(int,new.split('.'))) >= (3,7,0) else 0
        target_archive=asset(new,f'agent-guard-{new}.tar.gz');target_checksum=asset(new,f'agent-guard-{new}.tar.gz.sha256')
        archive_records=[r for r in observed if target_archive['url'] in r['args']]
        checksum_records=[r for r in observed if target_checksum['url'] in r['args']]
        archive_valid=len(archive_records)==1 and archive_records[0].get('sha256')==target_archive['digest'].removeprefix('sha256:')
        checksum_valid=len(checksum_records)==1 and checksum_records[0].get('sha256')==target_checksum['digest'].removeprefix('sha256:')
        row.update(step=step,from_version=old,to_version=new,source_cli_sha256=source_cli_sha256,source_cli_observed_version=source_version,
                   from_commit=next(r['sha'] for r in LOCK['releases'] if r['version']==old),
                   to_commit=next(r['sha'] for r in LOCK['releases'] if r['version']==new),final_version=final_version,
                   dynamic_bootstrap_records=dynamic,dynamic_bootstrap_matching_locked_releases=dynamic_matches,
                   native_core_checksum_verification=native_checks,expected_native_core_count=expected_native_count,
                   native_core_count_valid=len(native_checks)==expected_native_count,
                   downloads=observed,archive_lock_verified=archive_valid,checksum_lock_verified=checksum_valid,
                   rc_prefix_preserved=rc.is_file() and rc.read_bytes().startswith(sentinel.encode()),rc_byte_unchanged=rc.is_file() and rc.read_bytes()==rc_before,
                   custom_files_preserved=preserved_before==preserved_after,preserved_before=preserved_before,preserved_after=preserved_after,
                   public_symlink_preserved=(public/'agent-guard').is_symlink() and os.readlink(public/'agent-guard')==link_before,
                   native_core_bindings={r['path']:r['sha256'] for r in final_tree if r['path'].startswith('libexec/') and 'sha256' in r},
                   scanner_sha256=sha(scanner),curl_wrapper_sha256=sha(wrapper))
        row['correct']=row['returncode']==0 and not row['timeout'] and source_version=='agent-guard '+old and final_version=='agent-guard '+new and len(dynamic)==1 and bool(dynamic_matches) and dynamic[0].get('saved_path') is not None and archive_valid and checksum_valid and row['native_core_count_valid'] and all(r['verified'] for r in native_checks) and row['rc_prefix_preserved'] and row['custom_files_preserved'] and row['public_symlink_preserved']
        ROWS.append(row);save(prefix+'-result.json',row);save('steps.json',ROWS)
        print(json.dumps({'step':step,'from':old,'to':new,'returncode':row['returncode'],'correct':row['correct']}),flush=True)
        if not row['correct']:
            ERRORS.append({'stage':'actual-cli-update','step':step,'result_path':prefix+'-result.json'});break
    save('summary.json',{'steps_expected':6,'steps_attempted':len(ROWS),'steps_correct':sum(r['correct'] for r in ROWS),'performance':'N/A: compatibility n1 only','completed_chain':len(ROWS)==6 and all(r['correct'] for r in ROWS)})
    save('final-tree.json',manifest(payload));save('errors.json',ERRORS)
    if ERRORS:raise RuntimeError('actual CLI update compatibility failure retained; dependent chain stopped')

if __name__=='__main__':
    try:main()
    except Exception as exc:
        OUT.mkdir(exist_ok=True);ERRORS.append({'stage':'fatal','error':repr(exc),'traceback':traceback.format_exc()});save('errors.json',ERRORS);save('steps.json',ROWS);raise
