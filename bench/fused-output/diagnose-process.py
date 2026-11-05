#!/usr/bin/env python3
"""고정 합성 입력의 준비 timeout 원시 조사. 통과 판정이나 제품 설정 변경이 아니다."""
import argparse, hashlib, json, os, platform, shutil, subprocess, threading, time
from pathlib import Path
p=argparse.ArgumentParser()
p.add_argument('--scanner',required=True)
p.add_argument('--core',required=True)
p.add_argument('--out',required=True)
p.add_argument('--rounds',type=int,default=4)
a=p.parse_args()
root=Path(__file__).resolve().parents[2]
out=Path(a.out).resolve();out.mkdir(parents=True,exist_ok=False)
plugin=root/'plugins/agent-guard'; instrumented=out/'instrumented'
shutil.copytree(plugin,instrumented)
cli=instrumented/'bin/agent-guard'; source=cli.read_text()
needle='  AG_GITLEAKS_PROBE_GROUP=\n  ag_gl_probe_bytes='
assert source.count(needle)==1
source=source.replace(needle,'''  # Diagnostic copy: both probe and watchdog have already been reaped.
  printf 'pid=%s\\nstatus=%s\\ntimeout=' "$AG_GITLEAKS_PROBE_GROUP" "$ag_gl_probe_status" >"$AG_READINESS_DIAG/probe-status"
  cat "$ag_gl_probe_timeout" >>"$AG_READINESS_DIAG/probe-status"
  cp "$ag_gl_probe_output" "$AG_READINESS_DIAG/probe-output"
'''+needle)
cli.write_text(source)
scanner=str(Path(a.scanner).resolve());core=str(Path(a.core).resolve())
payload=json.dumps({'tool_name':'Read','tool_input':{},'tool_response':{'stdout':'API_KEY=perf-literal-tail','clean':'visible','type':'text'}}).encode()
sanitized={'stdout':'API_KEY=[REDACTED]','clean':'visible','type':'text'}
expected={'claude':{'hookSpecificOutput':{'hookEventName':'PostToolUse','updatedToolOutput':sanitized}},'codex':{'decision':'block','reason':'Agent Guard blocked the original tool output because it contained sensitive values; use the sanitized replacement in additionalContext.','hookSpecificOutput':{'hookEventName':'PostToolUse','additionalContext':'Agent Guard sanitized tool output:\n'+json.dumps(sanitized,separators=(',',':'))}}}
(out/'input.json').write_bytes(payload)
(out/'expected.json').write_text(json.dumps(expected,indent=2))
workers=min(4,os.cpu_count() or 1)
identity={'scope':'fixed 4 rounds, idle versus explicit CPU pressure; original versus post-wait diagnostic copy; collection success is not qualification; unchanged 2 second deadline and independent outputs','machine':platform.platform(),'cpu_count':os.cpu_count(),'pressure_workers':workers,'rounds':a.rounds,'source_sha256':hashlib.sha256((plugin/'bin/agent-guard').read_bytes()).hexdigest(),'scanner_sha256':hashlib.sha256(Path(scanner).read_bytes()).hexdigest(),'core_sha256':hashlib.sha256(Path(core).read_bytes()).hexdigest()}
(out/'identity.json').write_text(json.dumps(identity,indent=2))
base=dict(os.environ,AGENT_GUARD_LOG_MODE='off',AGENT_GUARD_RELEASE_CHECK='off',AGENT_GUARD_GITLEAKS_BIN=scanner,AGENT_GUARD_GITLEAKS_CONFIG=str(plugin/'config/gitleaks.toml'),AGENT_GUARD_PII_HOOK_MODE='off',AGENT_GUARD_OUTPUT_REDACT='mask',AGENT_GUARD_EXPERIMENTAL_REDACTOR='rust',AGENT_GUARD_RUST_CORE_BIN=str(out/'missing'),AGENT_GUARD_EXPERIMENTAL_OUTPUT_PIPELINE='fused',AGENT_GUARD_EXPERIMENTAL_OUTPUT_PREPARE_BIN=core)
for k in ['GODEBUG','GOMAXPROCS']:base.pop(k,None)
rows=[]
def sample(pid,stop,folder):
    samples=[]
    while not stop.is_set():
        start=time.monotonic()
        ps=subprocess.run(['ps','-axo','pid=,ppid=,pgid=,state=,time=,comm='],capture_output=True,text=True)
        processes=[]
        for line in ps.stdout.splitlines():
            cols=line.split(None,5)
            if len(cols)==6 and cols[0].isdigit() and cols[1].isdigit():processes.append(cols)
        selected={pid}
        while True:
            children={int(x[0]) for x in processes if int(x[1]) in selected}
            if children<=selected:break
            selected|=children
        samples.append({'monotonic':start,'processes':[x for x in processes if int(x[0]) in selected]})
        stop.wait(.05)
    (folder/'process-samples.json').write_text(json.dumps(samples,indent=2))
def run(label,argv,env,host=None):
    folder=out/label;folder.mkdir();env=dict(env,AG_READINESS_DIAG=str(folder))
    started=time.monotonic();timed_out=False
    with (folder/'stdout').open('wb') as stdout,(folder/'stderr').open('wb') as stderr,(out/'input.json').open('rb') as stdin:
        proc=subprocess.Popen(argv,stdin=stdin if host else subprocess.DEVNULL,stdout=stdout,stderr=stderr,env=env)
        stop=threading.Event();monitor=threading.Thread(target=sample,args=(proc.pid,stop,folder));monitor.start()
        try:status=proc.wait(timeout=35)
        except subprocess.TimeoutExpired:
            timed_out=True;proc.kill();status=proc.wait()
        finally:stop.set();monitor.join()
    data=(folder/'stdout').read_bytes()
    row={'label':label,'exit_status':status,'elapsed_seconds':time.monotonic()-started,'outer_timeout':timed_out,'load_average':os.getloadavg()}
    if host:
        try:row['independent_expected']=json.loads(data)==expected[host]
        except ValueError:row['independent_expected']=False
        row['readiness_timeout']=b'Scanner readiness: timeout' in data
    else:row['version_expected']=status==0 and data.strip()==b'8.30.1'
    rows.append(row);(out/'results.json').write_text(json.dumps(rows,indent=2));print(json.dumps(row),flush=True)
assert 0<a.rounds<=4
for i in range(a.rounds):
    for pressure in ([False,True] if i%2==0 else [True,False]):
        loads=[]
        try:
            if pressure:
                for _ in range(workers):loads.append(subprocess.Popen(['python3','-c','while True: pass'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL))
            run(f'version-{i}-{pressure}',[scanner,'version'],base)
            for host in ['claude','codex']:
                variants=[('original',plugin/'bin/agent-guard'),('instrumented',cli)]
                if i%2:variants.reverse()
                for variant,exe in variants:
                    run(f'hook-{i}-{pressure}-{host}-{variant}',[str(exe),'hook-post-tool'],dict(base,AGENT_GUARD_HOOK_HOST=host),host)
        finally:
            for proc in loads:proc.terminate()
            for proc in loads:proc.wait()
