#!/usr/bin/env python3
"""독립 공개7버전 boundary/failure CLI timing; 정상 마스킹 이득 비교 제외."""
import ast,csv,hashlib,itertools,json,os,platform,shutil,sys
from pathlib import Path
import base_runtime as b
import preparation_runtime as p
OUT=b.OUT;WORK=b.WORK;PROTOCOL='public-seven-boundary-v1';ROWS=b.ROWS;ERRORS=b.ERRORS
HOST=os.environ['BENCH_HOST'];AUDIT=os.environ['BENCH_AUDIT'];CASE=os.environ['BENCH_INPUT']
assert HOST in ('claude','codex') and AUDIT in ('off','on-warm') and CASE in ('unknown-event','missing-scanner-open','missing-scanner-closed')
def save(n,x):b.save(n,x)
def keep(data):
 d=OUT/'outputs';d.mkdir(exist_ok=True);h=hashlib.sha256(data).hexdigest();(d/(h+'.txt')).write_bytes(data);return h
def validate(outputs,errors,statuses):
 if CASE=='unknown-event':return all(o==b'' for o in outputs) and all(s==0 for s in statuses)
 if CASE=='missing-scanner-closed':return all(o==b'' for o in outputs) and all(s==2 for s in statuses) and all(b'AGENT_GUARD_INFRA_FAILURE_MODE=closed' in e for e in errors)
 warnings=0
 for o,e,s in zip(outputs,errors,statuses):
  if s:return False
  if not o:
   if b'continuing because AGENT_GUARD_INFRA_FAILURE_MODE=open' in e:return False
   continue
  try:
   z=json.loads(o);h=z['hookSpecificOutput'];message=h['additionalContext']
   if h['hookEventName']!='PostToolUse' or 'continuing because AGENT_GUARD_INFRA_FAILURE_MODE=open (the default).' not in message or b'continuing because AGENT_GUARD_INFRA_FAILURE_MODE=open' not in e:return False
   warnings+=1
  except (ValueError,KeyError,TypeError):return False
 return warnings==1
def checkpoint():
 b.summarize();rows=json.loads((OUT/'summary.json').read_text())
 for r in rows:
  group=[x for x in ROWS if all(x[k]==r[k] for k in ('version','host','audit','input','mode','concurrency','measurement'))]
  r['successful']=sum(x['correct'] for x in group);r['failures']=len(group)-r['successful']
  r.update(protocol=PROTOCOL,policy_mode='fixed-v3.6.13-all-three-policies',performance_comparable=False,masking_work_comparison_eligible=False,elapsed_cpu_comparison_eligible=False,boundary_timing_comparison_eligible=r['failures']==0,exclusion_reason='unknown/no-output or unavailable-scanner boundary path; never normal successful-masking speedup')
 save('summary.json',rows)
 if rows:
  flat=[]
  for r in rows:
   q={}
   for k,v in r.items():
    if isinstance(v,dict):q.update({k+'_'+a:x for a,x in v.items()})
    else:q[k]=v
   flat.append(q)
  with (OUT/'summary.csv').open('w') as f:w=csv.DictWriter(f,fieldnames=sorted(set().union(*(r.keys() for r in flat))));w.writeheader();w.writerows(flat)
 b.make_chunks()
def series(conditions,scanner,measurement,rounds):
 for concurrency in (1,4):
  for number in range(-1,rounds):
   shift=max(number,0)%len(conditions);order=conditions[shift:]+conditions[:shift]
   if measurement=='endpoint-direct' and max(number,0)//len(conditions)%2:order=list(reversed(order))
   for position,(version,mode,base) in enumerate(order):
    home=WORK/(measurement+'-boundary-home-'+version+'-'+mode+'-'+str(concurrency));(home/'tmp').mkdir(parents=True,exist_ok=True)
    session=measurement+'-'+str(concurrency)+'-'+('warm' if number<0 else str(number))
    event={'hook_event_name':'FutureEvent','tool_name':'future_tool','session_id':session} if CASE=='unknown-event' else {'hook_event_name':'PostToolUse','tool_name':'mcp__benchmark__read','tool_response':'API_KEY=boundary-synthetic-42','session_id':session}
    payload=json.dumps(event,separators=(',',':')).encode();env=p.env_for(base,HOST,AUDIT,mode,scanner,home)
    if CASE!='unknown-event':env['AGENT_GUARD_GITLEAKS_BIN']=str(WORK/'deliberately-missing-scanner')
    if CASE=='missing-scanner-closed':env['AGENT_GUARD_INFRA_FAILURE_MODE']='closed'
    script=WORK/'boundary-batch.sh'
    if not script.exists():script.write_text('#!/bin/sh\npids=\nfor i in $(seq 1 "$4"); do ("$1" hook-post-tool < "$2" > "$3/$i.out" 2> "$3/$i.err"; code=$?; printf "%s\\n" "$code" > "$3/$i.status"; exit "$code") & pids="$pids $!"; done\nstatus=0\nfor pid in $pids; do wait "$pid" || status=1; done\nexit "$status"\n')
    input_file=home/'input.json';input_file.write_bytes(payload)
    for worker in range(1,concurrency+1):
     for suffix in ('out','err','status'):(home/f'{worker}.{suffix}').unlink(missing_ok=True)
    # Both concurrency settings use the identical outer shell accounting path.
    row,stdout,stderr=b.measure(['sh',str(script),str(base/'bin/agent-guard'),str(input_file),str(home),str(concurrency)],payload,env,home)
    outputs=[(home/f'{i}.out').read_bytes() if (home/f'{i}.out').exists() else b'' for i in range(1,concurrency+1)]
    errors=[(home/f'{i}.err').read_bytes() if (home/f'{i}.err').exists() else b'' for i in range(1,concurrency+1)]
    statuses=[int((home/f'{i}.status').read_text()) if (home/f'{i}.status').exists() else None for i in range(1,concurrency+1)]
    correct=validate(outputs,errors,statuses) and row['returncode']==(1 if CASE=='missing-scanner-closed' else 0) and not row['timeout']
    row.update(protocol=PROTOCOL,version=version,platform='linux-x86_64-cgroup2-boundary',scanner='official-gitleaks-8.30.1' if CASE=='unknown-event' else 'explicit-missing-scanner',fixed_scanner_sha256=b.sha(scanner),audit=AUDIT,host=HOST,input=CASE,mode=mode,concurrency=concurrency,sample=number,measurement=measurement,execution_order=position,correct=correct,expected_returncode=1 if CASE=='missing-scanner-closed' else 0,child_statuses=statuses,session_id=session,throughput_rps=concurrency/(row['elapsed_ms']/1000),performance_comparable=False,masking_work_comparison_eligible=False,elapsed_cpu_comparison_eligible=False,boundary_timing_comparison_eligible=True,child_stdout_sha256=[keep(x) for x in outputs],child_stderr_sha256=[keep(x) for x in errors],child_stdout_bytes=[len(x) for x in outputs],child_stderr_bytes=[len(x) for x in errors],batch_stdout_object=keep(stdout),batch_stderr_object=keep(stderr),payload_sha256=keep(payload))
    # Expected fail-closed exit remains raw returncode=1. Correctness determines
    # this boundary experiment's success, not the normal masking classifier.
    if number<0:b.jlog('warmups.jsonl',row)
    else:
     ROWS.append(row);b.jlog('samples.jsonl',row)
     if not correct:ERRORS.append({k:row[k] for k in ('version','mode','sample','measurement','concurrency','returncode','child_statuses','timeout','correct')})
    print(json.dumps(row),flush=True)
  checkpoint()
def main():
 if (OUT/'samples.jsonl').exists():raise RuntimeError('existing samples: refuse append/overwrite')
 limits={n:Path('/sys/fs/cgroup/'+n).read_text().strip() for n in ('cpu.max','memory.max','memory.swap.max')};valid=limits=={'cpu.max':'200000 100000','memory.max':'1073741824','memory.swap.max':'0'}
 save('environment.json',dict(protocol=PROTOCOL,platform=platform.platform(),uname=list(os.uname()),hostname=platform.node(),cgroup=limits,resource_limit_valid=valid,proc_swaps=Path('/proc/swaps').read_text(),sh_target=os.path.realpath('/bin/sh'),host=HOST,audit=AUDIT,input=CASE))
 if not valid:raise RuntimeError('actual cgroup limits mismatch')
 save('plan.json',dict(protocol=PROTOCOL,host=HOST,audit=AUDIT,input=CASE,versions=[r['version'] for r in b.LOCK['releases']],series_repeats=9,endpoint_repeats=12,warmup=1,timeout_seconds=b.TIMEOUT,retries=0,series_order='9 condition Latin cyclic rotations',endpoint_order='3 cyclic rotations repeated four cycles; alternate cycles reversed',concurrency=[1,4],direct_cli='hook-post-tool; FutureEvent is payload only, host dispatcher unverified',contract={'unknown-event':'each worker exit0 and empty stdout','missing-scanner-open':'new valid session per batch; exactly one warning envelope and stderr notice; remaining concurrency-1 stdout empty; all worker exit0; warmup and regular same contract','missing-scanner-closed':'all worker exit2, empty stdout, explicit closed stderr; batch exit1 expected'},normal_masking_speedup_eligible=False,retained_home='each measurement/version/mode/concurrency retains HOME for audit cache; each batch gets a new session id',all_policy='v3.6.13 three files',scanner=b.SCANNER,measurement_function='exact copied base_runtime.measure; no modification',single_measurement='same outer batch shell as four concurrency; includes wrapper overhead in all versions',thresholds={'improvement_pct':10,'regression_gt_pct':5}))
 p.PROTOCOL=PROTOCOL
 versions,_,_,_,scanner=p.prepare('performance')
 conditions=[(v,'default',root) for v,root in versions.items()]
 for v in ('3.8.0','3.8.1'):
  root=versions[v]
  if (root/'scripts/output-pipeline-experiment.sh').is_file() and (root/'libexec/agent-guard-redact-x86_64-unknown-linux-musl').is_file():conditions.append((v,'fused',root))
  else:ERRORS.append(dict(stage='optional-route',version=v,status='N/A',reason='required public module/helper absent; no build or substitution'))
 save('conditions.json',[dict(version=v,mode=m,install_root=str(root)) for v,m,root in conditions])
 if len(conditions)==9:series(conditions,scanner,'boundary-cli',9)
 else:ERRORS.append(dict(stage='series',status='N/A',reason='nine public routes unavailable; no shortened Latin replacement'))
 endpoint=[c for wanted in [('3.6.13','default'),('3.8.1','default'),('3.8.1','fused')] for c in conditions if c[:2]==wanted]
 if len(endpoint)==3:series(endpoint,scanner,'endpoint-direct',12)
 else:ERRORS.append(dict(stage='endpoint',status='N/A',reason='public endpoint route absent'))
 checkpoint()
if __name__=='__main__':
 try:main()
 except Exception as error:ERRORS.append(dict(stage='fatal',error=repr(error)));save('errors.json',ERRORS);raise
