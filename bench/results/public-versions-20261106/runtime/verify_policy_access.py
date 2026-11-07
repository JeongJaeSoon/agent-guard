#!/usr/bin/env python3
"""공개 경로 그대로 policy 파일 접근을 추적한다. 성능 표본이 아닌 n=1 보조 검증."""
import argparse,collections,hashlib,json,os,re,signal,subprocess,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'correctness'))
from make_workloads import workloads
from common import payload,validate
CORE='agent-guard-redact-x86_64-unknown-linux-musl'
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def dump(p,v):Path(p).write_text(json.dumps(v,ensure_ascii=False,indent=2)+'\n')
def main():
 p=argparse.ArgumentParser();p.add_argument('--lab',default='/workspace/agent-guard-lab');p.add_argument('--out',required=True);p.add_argument('--jq-dir',default='/workspace/agent-guard-lab/component-tools');a=p.parse_args()
 lab=Path(a.lab);out=Path(a.out);out.mkdir(parents=True,exist_ok=False);proto=json.loads((ROOT/'runtime/protocol.json').read_text());cases={c['name']:c for c in workloads()};config=lab/'releases/v3.6.13/payload/config/gitleaks.toml';scanner=lab/'scanners/homebrew-relocated/gitleaks'
 arms=[('v3.6.13','default'),('v3.8.1','default'),('v3.8.1','fused')]
 files=[]
 for version in proto['versions']:
  root=lab/'releases'/version/'payload/config';files.append({'version':version,'files':[{ 'path':str(f),'name':f.name,'size':f.stat().st_size,'sha256':sha(f)} for f in sorted(root.rglob('*')) if f.is_file()]})
 dump(out/'public-policy-files.json',files)
 protocol={'role':'one traced call per main case/endpoint arm, never a timing sample','n_per_case_arm':1,'cases':proto['main_cases'],'arms':arms,'hosts':['claude'],'scanner':{'kind':'actual-homebrew-relocated','path':str(scanner),'sha256':sha(scanner)},'scanner_config':{'path':str(config),'sha256':sha(config)},'deny_policies':'unaltered per-version public defaults, not overridden','jq_dir':a.jq_dir,'timeout_s':30,'trace_command':['strace','-f','-qq','-yy','-e','trace=openat,open,read'],'environment':'same explicit main toggles: auditoff PIIoff releaseoff infraopen/outputmask; separate isolated HOME/cwd; actual local4CPU16GiB; trace overhead excluded from any performance inference'}
 dump(out/'protocol.json',protocol);rows=[]
 base={k:v for k,v in os.environ.items() if not k.startswith('AGENT_GUARD_') and k not in ['AI_AGENT','CLAUDE_PLUGIN_ROOT','PLUGIN_ROOT']}
 for name in proto['main_cases']:
  c=cases[name]
  for version,variant in arms:
   dest=out/(name+'-'+version+'-'+variant);dest.mkdir();state=dest/'state';state.mkdir();(state/'.env').write_text('SENTINEL=protected-not-executed\n');stdin=payload(c);(dest/'stdin.json').write_bytes(stdin)
   env=base|{'PATH':a.jq_dir+':'+base.get('PATH',''),'HOME':str(state),'XDG_CONFIG_HOME':str(state/'config'),'XDG_CACHE_HOME':str(state/'cache'),'XDG_STATE_HOME':str(state/'xdg-state'),'AGENT_GUARD_HOOK_HOST':'claude','AGENT_GUARD_LOG_MODE':'off','AGENT_GUARD_RELEASE_CHECK':'off','AGENT_GUARD_PII_HOOK_MODE':'off','AGENT_GUARD_OUTPUT_REDACT':'mask','AGENT_GUARD_GITLEAKS_CONFIG':str(config),'AGENT_GUARD_GITLEAKS_BIN':str(scanner),'AGENT_GUARD_INFRA_FAILURE_MODE':c.get('infra_mode','open')}
   if c.get('scanner_failure'):env['AGENT_GUARD_GITLEAKS_BIN']=str(state/'missing-scanner')
   pkg=lab/'releases'/version/'payload'
   if variant=='fused':env.update(AGENT_GUARD_EXPERIMENTAL_OUTPUT_PIPELINE='fused',AGENT_GUARD_EXPERIMENTAL_OUTPUT_PREPARE_BIN=str(pkg/'libexec'/CORE))
   cli=pkg/'bin/agent-guard';command=['strace','-f','-qq','-yy','-e','trace=openat,open,read','-o',str(dest/'files.strace'),str(cli),{'hook':'hook-post-tool','pre':'hook-pre-tool'}[c['route']]]
   dump(dest/'invocation.json',{'command':command,'overrides':{k:v for k,v in env.items() if k.startswith('AGENT_GUARD_') or k in ['HOME','XDG_CONFIG_HOME','XDG_CACHE_HOME','XDG_STATE_HOME','PATH']},'cwd':str(state),'cli_sha256':sha(cli),'input_sha256':hashlib.sha256(stdin).hexdigest()})
   proc=subprocess.Popen(command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env,cwd=str(state),start_new_session=True);timeout=False
   try:stdout,stderr=proc.communicate(stdin,timeout=30)
   except subprocess.TimeoutExpired:timeout=True;os.killpg(proc.pid,signal.SIGKILL);stdout,stderr=proc.communicate()
   (dest/'stdout').write_bytes(stdout);(dest/'stderr').write_bytes(stderr);ok,reasons,_=validate(c,'claude',stdout,stderr,proc.returncode)
   events=[];opens=collections.Counter();reads=collections.Counter();trace=(dest/'files.strace').read_text(errors='replace')
   for line in trace.splitlines():
    op=re.search(r'\b(openat|open)\((?:[^",]+, )?"([^"\\]*(?:\\.[^"\\]*)*)"',line)
    if op:
     result=re.search(r'\)\s+=\s+(-?\d+)',line);status=int(result[1]) if result else None;path=op[2]
     events.append({'syscall':op[1],'path':path,'result':status,'success':status is not None and status>=0})
     if status is not None and status>=0:opens[path]+=1
    rd=re.search(r'\bread\(\d+<([^>]+)>',line)
    if rd:
     result=re.search(r'\)\s+=\s+(\d+)',line)
     if result:reads[rd[1]]+=int(result[1])
   configs=[{'path':path,'open_successes':count,'observed_read_bytes':reads[path]} for path,count in sorted(opens.items()) if '/config/' in path or path.endswith(('.toml','deny-read-paths.txt','deny-bash-patterns.txt'))]
   policy={'deny_bash_successful_open_count':sum(v for k,v in opens.items() if k.endswith('/deny-bash-patterns.txt')),'deny_bash_read_bytes':sum(v for k,v in reads.items() if k.endswith('/deny-bash-patterns.txt')),'deny_read_successful_open_count':sum(v for k,v in opens.items() if k.endswith('/deny-read-paths.txt')),'deny_read_read_bytes':sum(v for k,v in reads.items() if k.endswith('/deny-read-paths.txt')),'gitleaks_config_successful_open_count':opens[str(config)],'gitleaks_config_read_bytes':reads[str(config)]}
   dump(dest/'file-access.json',{'successful_opened_files':dict(sorted(opens.items())),'observed_read_bytes':dict(sorted(reads.items())),'open_events':events,'config_files':configs,'policy':policy})
   row={'case':name,'version':version,'variant':variant,'host':'claude','returncode':proc.returncode,'timeout':timeout,'correct_output':ok and not timeout,'reasons':reasons,'trace':str((dest/'files.strace').relative_to(out)),'config_files':configs,'policy':policy};dump(dest/'result.json',row);rows.append(row)
   print(name,version,variant,'status',proc.returncode,'ok',ok,'policy',policy,flush=True)
 dump(out/'summary.json',rows);dump(out/'completion.json',{'complete':True,'calls':len(rows),'timeouts':sum(r['timeout'] for r in rows),'output_mismatches':sum(not r['correct_output'] for r in rows),'deny_bash_open_calls':sum(r['policy']['deny_bash_successful_open_count']>0 for r in rows)})
if __name__=='__main__':main()
