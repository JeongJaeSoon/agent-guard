#!/usr/bin/env python3
"""Actual isolated Homebrew public formula installation; no manual ELF patching.
Dependencies must already exist. Formula bytes are copied unchanged to an isolated
local tap solely to pin the public endpoint releases. Cache preparation is outside
timing. Existing HOME / prefix outside --lab are never changed.
"""
import argparse,csv,hashlib,importlib.util,json,os,pathlib,shutil,subprocess,time
P=pathlib.Path

def main():
 ap=argparse.ArgumentParser();ap.add_argument('--prefix');ap.add_argument('--lab',required=True);ap.add_argument('--out',required=True);ap.add_argument('--rounds',type=int,default=9);args=ap.parse_args();lab=P(args.lab);out=P(args.out);out.mkdir(parents=True,exist_ok=True)
 spec=importlib.util.spec_from_file_location('install_driver',P(__file__).with_name('measure_install.py'));driver=importlib.util.module_from_spec(spec);spec.loader.exec_module(driver)
 prefix=P(args.prefix) if args.prefix else lab/'homebrew';brew=prefix/'bin/brew';tap=prefix/'Library/Taps/bench/homebrew-public-guard';formula=tap/'Formula/agent-guard.rb';formula.parent.mkdir(parents=True,exist_ok=True);logs=out/'homebrew-logs';logs.mkdir(exist_ok=True)
 isolated_home=lab/'install/homebrew-functional-home';isolated_home.mkdir(parents=True,exist_ok=True)
 env=os.environ.copy();env['HOME']=str(isolated_home);env['HOMEBREW_USER_CONFIG_HOME']=str(isolated_home/'.config/homebrew');env['PATH']=str(prefix/'bin')+':'+env['PATH'];env.update(HOMEBREW_NO_AUTO_UPDATE='1',HOMEBREW_NO_ANALYTICS='1',HOMEBREW_NO_INSTALL_FROM_API='1',HOMEBREW_CACHE=str(lab/'homebrew-cache'),HOMEBREW_LOGS=str(lab/'homebrew-logs'))
 formula_name='bench/public-guard/agent-guard'
 def invoke(arguments,label):
  return driver.measure([str(brew)]+arguments,env,logs/label)
 def pin(version):
  src=lab/'releases'/('v'+version)/'assets/agent-guard.rb';shutil.copyfile(src,formula)
  assert hashlib.sha256(src.read_bytes()).digest()==hashlib.sha256(formula.read_bytes()).digest()
 def uninstall(label):
  if (prefix/'opt/agent-guard').exists():
   result=invoke(['uninstall','--formula',formula_name],label)
   if not result['success']:raise RuntimeError('unmeasured uninstall failed: '+label)
 def package_bytes():
  root=prefix/'Cellar/agent-guard';return sum(p.stat().st_size for p in root.rglob('*') if p.is_file() and not p.is_symlink())
 def save(rows):
  (out/'results-homebrew.json').write_text(json.dumps(rows,ensure_ascii=False,indent=2)+'\n')
  with open(out/'results-homebrew.csv','w') as f:
   writer=csv.DictWriter(f,fieldnames=list(dict.fromkeys(k for row in rows for k in row)));writer.writeheader();writer.writerows(rows)
 # Test existing compiler availability separately; prebuilt formula has no compilation step.
 protocol={'environment':'local-host-debian13-homebrew-actual-4CPU-16GiB-no-host-swap','prefix':str(prefix),'rounds':args.rounds,'warmups':1,'versions':['3.6.13','3.8.1'],'fresh_order':'even round baseline/latest, odd round latest/baseline','upgrade':'3.6.13 to 3.8.1 repeated; seed outside timing','scope':'actual brew install/upgrade with unchanged public formula pinned in isolated local tap; dependencies and download already cached; normal cleanup included; initial brew/dependencies/scanner setup excluded','timeout_s':120,'threshold_improvement_percent':10,'threshold_regression_percent':5}
 (out/'protocol-homebrew.json').write_text(json.dumps(protocol,ensure_ascii=False,indent=2)+'\n')
 pin('3.6.13')
 trust=invoke(['trust','--formula',formula_name],'trust-public-formula')
 if not trust['success']:raise RuntimeError('isolated public formula trust failed')
 # Prepare the fixed public tarballs using actual Homebrew fetch and validate normally.
 for v in protocol['versions']:
  pin(v);r=invoke(['fetch','--formula',formula_name],f'prepare-fetch-{v}')
  (out/f'homebrew-fetch-{v}.json').write_text(json.dumps(r,indent=2)+'\n')
  if not r['success']:raise RuntimeError('public formula fetch failed '+v)
 rows=[]
 for round_num in range(-1,args.rounds):
  order=['3.6.13','3.8.1'] if round_num%2==0 or round_num<0 else ['3.8.1','3.6.13']
  for pos,v in enumerate(order):
   label=f'fresh-r{round_num}-v{v}';uninstall(label+'-reset');pin(v)
   m=invoke(['install','--formula',formula_name],label)
   observed=subprocess.run([str(prefix/'bin/agent-guard'),'version'],env=env,capture_output=True,text=True) if m['success'] else None
   row=dict(version=v,scenario='homebrew-fresh-cached',round=round_num,position=pos,warmup=round_num<0,environment=protocol['environment'],scope=protocol['scope'],installed_bytes=package_bytes(),download_bytes=(lab/'releases'/('v'+v)/'assets'/f'agent-guard-{v}.tar.gz').stat().st_size,log_prefix='installation/homebrew-logs/'+label,**m)
   row['installed_version']=observed.stdout.strip() if observed else None;row['success']=row['success'] and observed.returncode==0 and row['installed_version'].endswith(v)
   rows.append(row);save(rows);print(json.dumps({k:row[k] for k in ['scenario','round','version','wall_s','success']}),flush=True)
 for round_num in range(-1,args.rounds):
  label=f'upgrade-r{round_num}-v3.8.1';uninstall(label+'-reset');pin('3.6.13');seed=invoke(['install','--formula',formula_name],label+'-seed')
  if not seed['success']:raise RuntimeError('seed installation failed '+label)
  before=package_bytes();pin('3.8.1');m=invoke(['upgrade','--formula',formula_name],label)
  observed=subprocess.run([str(prefix/'bin/agent-guard'),'version'],env=env,capture_output=True,text=True) if m['success'] else None
  row=dict(version='3.8.1',from_version='3.6.13',scenario='homebrew-upgrade-cached',round=round_num,position=0,warmup=round_num<0,environment=protocol['environment'],scope=protocol['scope'],installed_bytes=package_bytes(),home_delta_bytes=package_bytes()-before,download_bytes=(lab/'releases/v3.8.1/assets/agent-guard-3.8.1.tar.gz').stat().st_size,log_prefix='installation/homebrew-logs/'+label,**m)
  row['installed_version']=observed.stdout.strip() if observed else None;row['success']=row['success'] and observed.returncode==0 and row['installed_version'].endswith('3.8.1');rows.append(row);save(rows);print(json.dumps({k:row[k] for k in ['scenario','round','version','wall_s','success']}),flush=True)
 # Real package refuses the standalone updater; its supported manager is Homebrew.
 check=invoke(['info','--json=v2',formula_name],'final-brew-info')
 guarded=subprocess.run([str(prefix/'bin/agent-guard'),'update'],env=env,capture_output=True,text=True)
 (out/'homebrew-update-manager-guard.json').write_text(json.dumps(dict(exit_code=guarded.returncode,stdout=guarded.stdout,stderr=guarded.stderr),ensure_ascii=False,indent=2)+'\n')

if __name__=='__main__':main()
