#!/usr/bin/env python3
"""Measure public bootstrap bytes without modifying the installer.
Cached transport phase uses an explicit curl shim; network transfers are measured separately.
The process starts inside the measured environment; wait4 CPU/RSS exclude this driver.
"""
import argparse,csv,hashlib,json,os,pathlib,shutil,subprocess,time,threading,signal
P=pathlib.Path
VERSIONS=['3.6.13','3.6.14','3.6.15','3.7.0','3.7.1','3.8.0','3.8.1']
def measure(cmd,env,log):
    with open(str(log)+'.stdout','wb') as out,open(str(log)+'.stderr','wb') as err:
        start=time.perf_counter(); p=subprocess.Popen(cmd,env=env,stdout=out,stderr=err,start_new_session=True)
        timed_out=[]
        def expire():
            timed_out.append(True)
            try:os.killpg(p.pid,signal.SIGKILL)
            except ProcessLookupError:pass
        timer=threading.Timer(120,expire);timer.start()
        pid,status,r=os.wait4(p.pid,0); p.returncode=os.waitstatus_to_exitcode(status);timer.cancel()
    return dict(wall_s=time.perf_counter()-start,cpu_s=r.ru_utime+r.ru_stime,max_child_rss_kib=r.ru_maxrss,exit_code=p.returncode,timed_out=bool(timed_out),success=p.returncode==0)
def bytes_of(root):return sum(p.stat().st_size for p in root.rglob('*') if p.is_file() and not p.is_symlink())
def write_json(p,x):p.write_text(json.dumps(x,ensure_ascii=False,indent=2)+'\n')
def main():
    ap=argparse.ArgumentParser();ap.add_argument('--work');ap.add_argument('--scenarios');ap.add_argument('--lab',default='/workspace/agent-guard-lab');ap.add_argument('--out',default='/workspace/agent-guard-bench/bench/results/public-versions-20261106/installation');ap.add_argument('--environment',default='docker-debian12-actual-4CPU-16GiB-no-host-swap; requested limits unenforced');ap.add_argument('--versions',default=','.join(VERSIONS));ap.add_argument('--rounds',type=int,default=9);ap.add_argument('--phase',choices=['cached','network'],default='cached');args=ap.parse_args()
    global_versions=args.versions.split(',');VERSIONS[:]=global_versions;lab=P(args.lab);out=P(args.out);out.mkdir(parents=True,exist_ok=True);work=P(args.work) if args.work else lab/'install'/out.name;work.mkdir(parents=True,exist_ok=True);logs=out/'logs';logs.mkdir(exist_ok=True)
    shim=work/'transport';shim.mkdir(exist_ok=True)
    (shim/'curl').write_text('''#!/usr/bin/env python3
import os,pathlib,shutil,sys
args=sys.argv[1:]; url=next((a for a in args if a.startswith('https://')),None); dest=args[args.index('-o')+1] if '-o' in args else None
if not url or not dest: raise SystemExit('unsupported cached curl invocation: '+repr(args))
name=url.rsplit('/',1)[-1]; version=os.environ['AGENT_GUARD_VERSION']; src=(pathlib.Path(os.environ['BENCH_RELEASES']).parent/'scanners/official.tar.gz') if name.startswith('gitleaks_') else pathlib.Path(os.environ['BENCH_RELEASES'])/('v'+version)/'assets'/name
if not src.is_file():raise SystemExit('missing cached public asset '+str(src))
shutil.copyfile(src,dest)
with open(os.environ['BENCH_TRANSFER_LOG'],'a') as f:f.write(str(src.stat().st_size)+' '+url+'\\n')
''');(shim/'curl').chmod(0o755)
    rows=[];orders=[]
    # Predetermined 9-round alternating rotations; no timing-based retries.
    orders=[(VERSIONS[r%len(VERSIONS):]+VERSIONS[:r%len(VERSIONS)])[::(-1 if r%2 else 1)] for r in range(args.rounds)]
    protocol={'warmups_per_version':1 if args.phase=='cached' else 0,'rounds':args.rounds,'orders':orders,'threshold_improvement_percent':10,'threshold_regression_percent':5,'phase':args.phase,'timeout':'120s fixed per installation/transfer; kill process group; retained failures; no retries','scope':'published bootstrap + checksum validation + extraction + setup dependency diagnostics + default setup-shell; existing deps ready; cached transport excludes network and bootstrap script download','environment':args.environment}
    write_json(out/('protocol-'+args.phase+'.json'),protocol)
    if args.phase=='network':protocol['scope']='actual curl public pinned archive transfer only; TLS verification on; checksum verified after timing; excludes bootstrap/checksum/dependencies/extraction/setup; proxy/CDN cache unknown'
    scenarios=['standalone-fresh-cached','standalone-update-cached','dependency-scanner-cached'] if args.phase=='cached' else ['asset-network-download']
    if args.scenarios:scenarios=args.scenarios.split(',')
    protocol['scenarios']=scenarios
    if 'standalone-fresh-network' in scenarios:protocol['scope']='actual published local reviewed bootstrap + real network archive/checksum downloads + validation/extraction/setup/default shell integration; preexisting ready dependencies; excludes initial bootstrap download; proxy/CDN cache unknown'
    write_json(out/('protocol-'+args.phase+'.json'),protocol)
    for scenario in scenarios:
      for round_num in range(-1 if args.phase=='cached' else 0,args.rounds):
        order=VERSIONS if round_num<0 else orders[round_num]
        for pos,v in enumerate(order):
          label=f'{scenario}-r{round_num}-v{v}';run=work/label
          if run.exists():raise RuntimeError('preserve existing run; refusing overwrite '+str(run))
          run.mkdir();home=run/'home';home.mkdir();tmp=run/'tmp';tmp.mkdir();transfer=run/'transfers.txt'
          env=os.environ.copy();env.update(HOME=str(home),TMPDIR=str(tmp),AGENT_GUARD_HOME=str(home/'.agent-guard'),AGENT_GUARD_BIN_DIR=str(home/'.local/bin'),AGENT_GUARD_VERSION=v,AGENT_GUARD_RELEASE_CHECK='off',AGENT_GUARD_AUDIT='off',BENCH_RELEASES=str(lab/'releases'),BENCH_TRANSFER_LOG=str(transfer))
          env['PATH']=str(shim)+':'+str(lab/'scanners/official')+':'+os.environ['PATH']
          bootstrap=lab/'releases'/('v'+v)/'assets/bootstrap.sh'
          sent='BENCH_PRESERVE_SENTINEL\n'; (home/'.bashrc').write_text(sent);settings=home/'.config/agent-guard/user-settings.txt';settings.parent.mkdir(parents=True);settings.write_text(sent)
          from_v=None
          if scenario=='standalone-update-cached':
            from_v=VERSIONS[max(0,VERSIONS.index(v)-1)];env['AGENT_GUARD_VERSION']=from_v
            setup=measure(['sh',str(lab/'releases'/('v'+from_v)/'assets/bootstrap.sh')],env,logs/(label+'-seed'))
            if not setup['success']:raise RuntimeError('seed install failed '+label)
            (home/'.agent-guard/local-preserved.txt').write_text(sent)
            # Invoke the documented installed updater, retaining its latest-bootstrap URL.
            # The cache shim maps that URL to this public target version's bootstrap bytes.
            env['AGENT_GUARD_VERSION']=v;transfer.unlink(missing_ok=True)
            cmd=[str(home/'.local/bin/agent-guard'),'update']
          elif scenario=='dependency-scanner-cached':
            env['PATH']=str(shim)+':'+os.environ['PATH']
            # No scanner on PATH or private cache in this fresh HOME.
            cmd=[str(lab/'releases'/('v'+v)/'payload/bin/agent-guard'),'setup','--install','--gitleaks-version','8.30.1','--gitleaks-checksum','551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb']
          elif scenario=='standalone-fresh-network':
            env['PATH']=str(lab/'scanners/official')+':'+os.environ['PATH']
            cmd=['sh',str(bootstrap)]
          elif scenario=='asset-network-download':
            env['PATH']=os.environ['PATH'];url=f'https://github.com/JeongJaeSoon/agent-guard/releases/download/v{v}/agent-guard-{v}.tar.gz'
            cmd=['curl','-fsSL',url,'-o',str(run/'asset.tar.gz')]
          else:cmd=['sh',str(bootstrap)]
          before=bytes_of(home);m=measure(cmd,env,logs/label);installed=bytes_of(home/'.agent-guard') if (home/'.agent-guard').exists() else None
          preserved=settings.read_text()==sent and (home/'.bashrc').read_text().startswith(sent)
          if scenario=='standalone-update-cached':preserved=preserved and (home/'.agent-guard/local-preserved.txt').read_text()==sent
          row=dict(version=v,from_version=from_v,scenario=scenario,round=round_num,position=pos,environment=protocol['environment'],scope=protocol['scope'],warmup=round_num<0,installed_bytes=(bytes_of(home) if scenario=='dependency-scanner-cached' else installed),home_delta_bytes=bytes_of(home)-before,download_bytes=sum(int(l.split()[0]) for l in transfer.read_text().splitlines()) if transfer.exists() else ((run/'asset.tar.gz').stat().st_size if (run/'asset.tar.gz').exists() else None),user_config_preserved=preserved,log_prefix='installation/logs/'+label,**m)
          if scenario not in ('asset-network-download','dependency-scanner-cached') and m['success']:
            row['installed_version']=subprocess.check_output([str(home/'.local/bin/agent-guard'),'version'],env=env,text=True).strip();row['success']=row['success'] and row['installed_version'].endswith(v) and preserved
          if scenario=='standalone-fresh-network':
            row['requested_asset_bytes']=sum((lab/'releases'/('v'+v)/'assets'/name).stat().st_size for name in [f'agent-guard-{v}.tar.gz',f'agent-guard-{v}.tar.gz.sha256'])
            row['download_bytes']=row['requested_asset_bytes'] if row['success'] else None
            if (home/'.agent-guard/bin/agent-guard').exists():
              row['installed_cli_sha256']=hashlib.sha256((home/'.agent-guard/bin/agent-guard').read_bytes()).hexdigest();row['expected_cli_sha256']=hashlib.sha256((lab/'releases'/('v'+v)/'payload/bin/agent-guard').read_bytes()).hexdigest();row['cli_matches_public']=row['installed_cli_sha256']==row['expected_cli_sha256'];row['success']=row['success'] and row['cli_matches_public']
          if scenario=='asset-network-download' and (run/'asset.tar.gz').exists():
            expected=hashlib.sha256((lab/'releases'/('v'+v)/'assets'/f'agent-guard-{v}.tar.gz').read_bytes()).hexdigest();actual=hashlib.sha256((run/'asset.tar.gz').read_bytes()).hexdigest()
            row.update(expected_sha256=expected,actual_sha256=actual,checksum_match=expected==actual);row['success']=row['success'] and expected==actual
          rows.append(row);write_json(out/('results-'+args.phase+'.json'),rows);print(json.dumps({k:row[k] for k in ['scenario','version','round','wall_s','success']}),flush=True)
    return rows
if __name__=='__main__':main()
