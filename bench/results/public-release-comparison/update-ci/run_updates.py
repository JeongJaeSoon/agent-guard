#!/usr/bin/env python3
"""공개 pinned bootstrap의 인접 릴리스 업그레이드만 실측한다.

구형 설치 준비와 scanner 최초 준비는 별도 원시 로그로 보존하되 업그레이드
시간에 합산하지 않는다. 제품 코드/사용자 설치를 수정하지 않는다.
"""
import csv, hashlib, json, os, platform, shutil, signal, statistics, subprocess, tarfile, time, traceback, urllib.request
from pathlib import Path

OUT=Path('/results-update'); WORK=Path('/tmp/public-upgrade-experiment')
LOCK_PATH=Path(__file__).parent/'release-lock.json'
LOCK=json.loads(LOCK_PATH.read_text())
RELEASES=LOCK['releases']; VERSIONS=[r['version'] for r in RELEASES]
PAIRS=list(zip(VERSIONS,VERSIONS[1:])); SAMPLES=12; TIMEOUT=120
SCANNER={'name':'gitleaks_8.30.1_linux_x64.tar.gz','url':'https://github.com/gitleaks/gitleaks/releases/download/v8.30.1/gitleaks_8.30.1_linux_x64.tar.gz','sha256':'551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb'}
ROWS=[]; ERRORS=[]; PREPARATION=[]

def sha(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()
def save(name,value):
    (OUT/name).write_text(json.dumps(value,ensure_ascii=False,indent=2)+'\n')
def append(name,value):
    with (OUT/name).open('a') as f:f.write(json.dumps(value,ensure_ascii=False)+'\n')
def asset(version,name):return next(a for r in RELEASES if r['version']==version for a in r['assets'] if a['name']==name)
def measured(command,env,cwd,prefix):
    started=time.perf_counter(); timeout=False
    with (OUT/(prefix+'.stdout')).open('wb') as out,(OUT/(prefix+'.stderr')).open('wb') as err:
        child=subprocess.Popen(command,env=env,cwd=cwd,stdout=out,stderr=err,start_new_session=True)
        while True:
            pid,status,usage=os.wait4(child.pid,os.WNOHANG)
            if pid:break
            if time.perf_counter()-started>TIMEOUT:
                timeout=True;os.killpg(child.pid,signal.SIGKILL);pid,status,usage=os.wait4(child.pid,0);break
            time.sleep(.001)
        child.returncode=os.waitstatus_to_exitcode(status)
    return {'elapsed_ms':(time.perf_counter()-started)*1000,'cpu_ms':(usage.ru_utime+usage.ru_stime)*1000,
            'user_ms':usage.ru_utime*1000,'system_ms':usage.ru_stime*1000,
            'max_child_rss_kib':usage.ru_maxrss,'returncode':child.returncode,'timeout':timeout,
            'stdout_path':prefix+'.stdout','stderr_path':prefix+'.stderr'}
def summary():
    save('updates.json',ROWS);save('preparation.json',PREPARATION);save('errors.json',ERRORS)
    if ROWS:
        keys=sorted(set().union(*(r.keys() for r in ROWS)))
        with (OUT/'updates.csv').open('w',newline='') as f:
            writer=csv.DictWriter(f,fieldnames=keys);writer.writeheader();writer.writerows(ROWS)
    groups=[]
    for old,new in PAIRS:
        rows=[x for x in ROWS if x['from_version']==old and x['to_version']==new]
        good=[x for x in rows if x['correct'] and not x['timeout'] and x['returncode']==0]
        item={'from_version':old,'to_version':new,'n_attempted':len(rows),'n_valid':len(good),'failures':len(rows)-len(good)}
        for metric in ('elapsed_ms','cpu_ms','max_child_rss_kib','installed_bytes_before','installed_bytes_after','installed_bytes_increment','expected_download_bytes'):
            values=[x[metric] for x in good]
            if not values:item[metric]=None;continue
            q=statistics.quantiles(values,n=4,method='inclusive') if len(values)>1 else [values[0]]*3
            item[metric]={'median':statistics.median(values),'q1':q[0],'q3':q[2],'min':min(values),'max':max(values)}
        groups.append(item)
    save('summary.json',groups)
def tree_bytes(path):return sum(p.stat().st_size for p in path.rglob('*') if p.is_file() and not p.is_symlink())
def payload_manifest(path):
    records=[]
    for p in path.rglob('*'):
        if p.is_symlink():records.append({'path':str(p.relative_to(path)),'symlink':os.readlink(p)})
        elif p.is_file():records.append({'path':str(p.relative_to(path)),'bytes':p.stat().st_size,'sha256':sha(p)})
    return records
def invoke_script(version,env,cwd,prefix):
    """Measured network includes bootstrap itself, archive, checksum; no retries."""
    boot=asset(version,'bootstrap.sh');expected=boot['digest'].removeprefix('sha256:')
    script=WORK/'download-and-bootstrap.sh'
    if not script.exists():
        script.write_text('''#!/bin/sh
set -eu
curl -fsSL "$1" -o "$2"
printf '%s  %s\\n' "$3" "$2" | sha256sum -c - >&2
sh "$2"
''')
    target=cwd/('bootstrap-'+version+'.sh')
    return measured(['sh',str(script),boot['url'],str(target),expected],env,cwd,prefix)
def main():
    OUT.mkdir(exist_ok=True);WORK.mkdir(exist_ok=False)
    limits={x:Path('/sys/fs/cgroup/'+x).read_text().strip() for x in ('cpu.max','memory.max','memory.swap.max','pids.max')}
    compilers={x:shutil.which(x) for x in ('cc','gcc','clang','rustc','cargo')}
    environment={'platform':platform.platform(),'uname':list(platform.uname()),'cgroup':limits,
                 'resource_limit_valid':limits['cpu.max']=='200000 100000' and limits['memory.max']=='1073741824' and limits['memory.swap.max']=='0',
                 'compiler_paths':compilers,'compiler_absence_verified':not any(compilers.values()),
                 'uid':os.getuid(),'gid':os.getgid(),'release_lock_sha256':sha(LOCK_PATH)}
    save('environment.json',environment)
    if not environment['resource_limit_valid']:raise RuntimeError('required resource limits not applied')
    if not environment['compiler_absence_verified']:raise RuntimeError('compiler present in runtime image')
    # Ten blocks give each pair every position twice; final two rotated blocks
    # leave every pair at each position either two or three times, fixed a priori.
    orders=[]
    for n in range(SAMPLES):
        shift=n%len(PAIRS);order=PAIRS[shift:]+PAIRS[:shift]
        if n//len(PAIRS)%2:order=list(reversed(order))
        orders.append(order)
    save('plan.json',{'samples_per_adjacent_pair':SAMPLES,'pairs':PAIRS,'orders':orders,
                     'warmup':0,'timeout_seconds':TIMEOUT,'retries':0,
                     'measurement':'pinned public bootstrap upgrade; startup+bootstrap download+hash verify+archive/checksum download+staging+dependency check+shell setup included',
                     'preparation_excluded':'fresh old-version bootstrap installation and official scanner preparation; raw preparation logs retained',
                     'dependencies':'already installed; no first dependency installation included',
                     'network':'uncontrolled real GitHub network; download bytes are pinned expected payload bytes, not on-wire TLS/retry bytes; curl has no retry flag',
                     'preservation':'user rc prefix, unrelated payload local file, payload custom config, external custom config and stable public symlink',
                     'rss':'Linux wait4 maximum individual child RSS KiB; not sampled sum/PSS/unique physical memory',
                     'updater_choice':'documented pinned bootstrap route with same existing installation destination; latest-based agent-guard update is not silently pinned or patched',
                     'v3.8.1':LOCK['v381']})
    scanner_archive=WORK/SCANNER['name']
    with urllib.request.urlopen(SCANNER['url'],timeout=60) as response,scanner_archive.open('wb') as out:shutil.copyfileobj(response,out)
    if sha(scanner_archive)!=SCANNER['sha256']:raise RuntimeError('scanner archive hash mismatch')
    scan_dir=WORK/'scanner';scan_dir.mkdir()
    with tarfile.open(scanner_archive) as archive:archive.extractall(scan_dir,filter='data')
    scanner=scan_dir/'gitleaks';scanner.chmod(0o755)
    save('scanner.json',dict(SCANNER,binary_sha256=sha(scanner),version=subprocess.check_output([str(scanner),'version'],text=True).strip()))
    for block,order in enumerate(orders):
        for position,(old,new) in enumerate(order):
            case=WORK/f'block-{block}-{old}-to-{new}';case.mkdir();(case/'tmp').mkdir()
            payload=case/'payload';public_bin=case/'local-bin';rc=case/'.bashrc'
            sentinel=f'# retained user settings; pair {old} to {new}\nexport GUARD_UPGRADE_PRESERVE=yes\n'
            rc.write_text(sentinel)
            env=dict(os.environ,HOME=str(case),TMPDIR=str(case/'tmp'),SHELL='/bin/bash',
                     AGENT_GUARD_VERSION=old,AGENT_GUARD_HOME=str(payload),AGENT_GUARD_BIN_DIR=str(public_bin),
                     AGENT_GUARD_GITLEAKS_BIN=str(scanner),AGENT_GUARD_LOG_MODE='off',AGENT_GUARD_RELEASE_CHECK='off')
            prefix=f'logs/{block:02d}-{old}-to-{new}'
            (OUT/'logs').mkdir(exist_ok=True)
            prep=invoke_script(old,env,case,prefix+'-prepare-old')
            prep.update(block=block,from_version=old,to_version=new,stage='old-version-install-unmeasured-preparation')
            PREPARATION.append(prep);append('preparation.jsonl',prep)
            if prep['returncode'] or prep['timeout']:
                ERRORS.append({'stage':'old-install-preparation',**prep});summary();continue
            local=payload/'local-settings.txt';local.write_text('unrelated installed user file retained\n')
            custom=payload/'config/custom-user.toml';custom.write_text('# custom user policy retained\n')
            external=case/'external-gitleaks.toml';shutil.copyfile(payload/'config/gitleaks.toml',external)
            with external.open('a') as out:out.write('\n# external user configuration sentinel\n')
            before={str(p.relative_to(case)):sha(p) for p in (local,custom,external)}
            before_bytes=tree_bytes(payload);rc_before=rc.read_bytes();link_before=os.readlink(public_bin/'agent-guard')
            env.update(AGENT_GUARD_VERSION=new,AGENT_GUARD_GITLEAKS_CONFIG=str(external))
            row=invoke_script(new,env,case,prefix+'-upgrade-measured')
            after={str(p.relative_to(case)):sha(p) if p.is_file() else None for p in (local,custom,external)}
            try:version=subprocess.check_output([str(payload/'bin/agent-guard'),'version'],env=env,text=True,timeout=10).strip()
            except Exception as exc:version=str(exc)
            link_after=os.readlink(public_bin/'agent-guard') if (public_bin/'agent-guard').is_symlink() else None
            expected_bytes=sum(asset(new,name)['size'] for name in ('bootstrap.sh',f'agent-guard-{new}.tar.gz',f'agent-guard-{new}.tar.gz.sha256'))
            row.update(block=block,execution_order=position,from_version=old,to_version=new,
                       from_commit=next(r['sha'] for r in RELEASES if r['version']==old),to_commit=next(r['sha'] for r in RELEASES if r['version']==new),
                       stage='pinned-bootstrap-adjacent-upgrade',expected_download_bytes=expected_bytes,
                       installed_bytes_before=before_bytes,installed_bytes_after=tree_bytes(payload),
                       installed_bytes_increment=tree_bytes(payload)-before_bytes,final_version=version,
                       rc_prefix_preserved=rc.read_text().startswith(sentinel),rc_byte_unchanged=rc.read_bytes()==rc_before,
                       custom_files_preserved=before==after,sentinel_hashes_before=before,sentinel_hashes_after=after,
                       public_link_preserved=link_before==link_after,public_link_target_after=link_after,
                       bootstrap_sha256=sha(case/('bootstrap-'+new+'.sh')) if (case/('bootstrap-'+new+'.sh')).is_file() else None,
                       expected_bootstrap_sha256=asset(new,'bootstrap.sh')['digest'].removeprefix('sha256:'))
            row['correct']=row['returncode']==0 and not row['timeout'] and version=='agent-guard '+new and row['rc_prefix_preserved'] and row['custom_files_preserved'] and row['public_link_preserved'] and row['bootstrap_sha256']==row['expected_bootstrap_sha256']
            ROWS.append(row);append('updates.jsonl',row)
            save(prefix+'-preservation.json',{'before':before,'after':after,'rc_before':rc_before.decode(),'rc_after':rc.read_text(),'link_before':link_before,'link_after':link_after})
            if not row['correct']:
                ERRORS.append({'stage':'upgrade',**row})
                save(prefix+'-failed-payload-manifest.json',payload_manifest(payload))
                failure_text=OUT/(prefix+'-failed-text');failure_text.mkdir()
                for item in (case/('bootstrap-'+new+'.sh'),rc,local,custom,external):
                    if item.is_file():shutil.copyfile(item,failure_text/item.name)
            summary()
            print(json.dumps({k:row[k] for k in ('block','from_version','to_version','elapsed_ms','returncode','correct')}),flush=True)
            shutil.rmtree(case)
    summary()
    if ERRORS:raise RuntimeError(f'{len(ERRORS)} failed preparations/upgrades retained')

if __name__=='__main__':
    try:main()
    except Exception as exc:
        OUT.mkdir(exist_ok=True);ERRORS.append({'stage':'fatal','error':repr(exc),'traceback':traceback.format_exc()});summary();raise
