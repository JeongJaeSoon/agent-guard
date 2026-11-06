#!/usr/bin/env python3
"""One actual Homebrew launcher call per host/variant; functional proof only."""
import argparse,csv,hashlib,json,os,re,signal,subprocess,sys
from pathlib import Path
CORE='agent-guard-redact-x86_64-unknown-linux-musl'
def sha(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()
def dump(path,value):Path(path).write_text(json.dumps(value,ensure_ascii=False,indent=2)+'\n')
def native_events(text,core):
 events=[];lines=text.splitlines()
 for i,line in enumerate(lines):
  match=re.match(r'^(\d+)\s+execve\("([^"\n]+)", (.*)',line)
  if not match or match[2]!=str(core):continue
  pid=match[1];api='prepare-v1' if '"prepare-v1"' in match[3] else 'redact-v1' if '"redact-v1"' in match[3] else 'other';continuation=None
  if '<unfinished ...>' in line:
   for later in lines[i+1:]:
    if not re.match(r'^'+re.escape(pid)+r'\s+',later):continue
    if '<... execve resumed>' in later:continuation=later;break
    if 'execve(' in later or '+++ exited' in later:break
  completed=continuation if continuation is not None else line
  events.append({'pid':int(pid),'api':api,'exec_success':bool(re.search(r'=\s*0$',completed)),'exit0':bool(re.search(r'^'+re.escape(pid)+r'\s+\+\+\+ exited with 0 \+\+\+$',text,re.M)),'execve_line':line,'execve_resume_line':continuation})
 return events

def main():
 p=argparse.ArgumentParser();p.add_argument('--lab',default='/lab');p.add_argument('--prefix',default='/workspace/agb');p.add_argument('--out',default='/results');a=p.parse_args();lab=Path(a.lab);prefix=Path(a.prefix);out=Path(a.out)
 if (out/'protocol.json').exists():raise SystemExit('refusing to overwrite previous functional proof')
 out.mkdir(parents=True,exist_ok=True)
 launcher=prefix/'bin/agent-guard';keg=prefix/'Cellar/agent-guard/3.8.1';cli=keg/'libexec/bin/agent-guard';core=keg/'libexec/libexec'/CORE;published=lab/'releases/v3.8.1/payload/libexec'/CORE;canonical=lab/'releases/v3.6.13/payload/config';scanner=lab/'scanners/official/gitleaks'
 assert core.read_bytes()==published.read_bytes(),'actual Homebrew core differs from public3.8.1 helper'
 assert cli.read_bytes()==(lab/'releases/v3.8.1/payload/bin/agent-guard').read_bytes()
 assert (keg/'libexec/config/deny-read-paths.txt').read_bytes()==(canonical/'deny-read-paths.txt').read_bytes()
 expected_checksum=(core.with_suffix(core.suffix+'.sha256')).read_text().strip()
 assert expected_checksum==sha(core)+'  '+CORE,'packaged core checksum differs'
 original={str(f):sha(f) for f in keg.rglob('*') if f.is_file() and not f.is_symlink()}
 original_links={str(f):os.readlink(f) for f in [launcher] if f.is_symlink()}
 response={'stdout':'API_KEY=perf-literal-tail','clean':'visible','number':42,'flag':False};expected={'stdout':'API_KEY=[REDACTED]','clean':'visible','number':42,'flag':False};request={'tool_name':'mcp__latency__read','tool_response':response};input_bytes=json.dumps(request,separators=(',',':')).encode()
 protocol={'role':'n1functionalperhostvariant; process-strace overhead; no latency/CPU/throughput inference or merging into Homebrew cached install benchmarks','n_per_condition':1,'arms':[[host,variant] for host in ['claude','codex'] for variant in ['default','fused']],'timeout_s':30,'trace_syscalls':'process only; no open/read/write traces','launcher':str(launcher),'launcher_resolved':str(launcher.resolve()),'launcher_sha256':sha(launcher),'product_cli':str(cli),'product_cli_sha256':sha(cli),'core':str(core),'core_sha256':sha(core),'public_core_sha256':sha(published),'core_bytes_equal_public381':True,'scanner':str(scanner),'scanner_sha256':sha(scanner),'gitleaks_config':str(canonical/'gitleaks.toml'),'gitleaks_config_sha256':sha(canonical/'gitleaks.toml'),'deny_bash_sha256':sha(canonical/'deny-bash-patterns.txt'),'deny_read_sha256':sha(canonical/'deny-read-paths.txt'),'deny_read_packaged_equal_baseline':True,'native_core_override':'absent; actual packaged autodiscovery','expected_sanitized_response':expected,'read_only_mounts':[line for line in Path('/proc/self/mountinfo').read_text().splitlines() if line.split()[4] in ['/workspace/agb','/lab','/bench','/results']]}
 dump(out/'protocol.json',protocol);dump(out/'input.json',request);dump(out/'expected.json',expected);dump(out/'environment.json',{'uname':list(os.uname()),'cgroup':Path('/proc/self/cgroup').read_text(),'limits':{name:(Path('/sys/fs/cgroup')/name).read_text().strip() for name in ['cpu.max','memory.max','memory.swap.max']},'jq':subprocess.check_output(['jq','--version'],text=True).strip(),'strace':subprocess.check_output(['strace','-V'],text=True).splitlines()[0]})
 base={k:v for k,v in os.environ.items() if not k.startswith('AGENT_GUARD_') and k not in ['AI_AGENT','CLAUDE_PLUGIN_ROOT','PLUGIN_ROOT']};rows=[]
 for host,variant in protocol['arms']:
  dest=out/(host+'-'+variant);dest.mkdir();state=dest/'state';state.mkdir();tmp=state/'tmp';tmp.mkdir();env=base|{'HOME':str(state),'TMPDIR':str(tmp),'XDG_CONFIG_HOME':str(state/'config'),'XDG_CACHE_HOME':str(state/'cache'),'XDG_STATE_HOME':str(state/'xdg-state'),'AGENT_GUARD_HOOK_HOST':host,'AGENT_GUARD_LOG_MODE':'off','AGENT_GUARD_RELEASE_CHECK':'off','AGENT_GUARD_PII_HOOK_MODE':'off','AGENT_GUARD_OUTPUT_REDACT':'mask','AGENT_GUARD_INFRA_FAILURE_MODE':'open','AGENT_GUARD_GITLEAKS_BIN':str(scanner),'AGENT_GUARD_GITLEAKS_CONFIG':str(canonical/'gitleaks.toml'),'AGENT_GUARD_DENY_BASH_PATTERNS':str(canonical/'deny-bash-patterns.txt'),'AGENT_GUARD_WARNING_DIR':str(state/'warnings')}
  if variant=='fused':env.update(AGENT_GUARD_EXPERIMENTAL_OUTPUT_PIPELINE='fused',AGENT_GUARD_EXPERIMENTAL_OUTPUT_PREPARE_BIN=str(core))
  trace=dest/'process.strace';command=['strace','-f','-s','512','-e','trace=process','-o',str(trace),str(launcher),'hook-post-tool'];dump(dest/'invocation.json',{'command':command,'cwd':str(state),'overrides':{k:v for k,v in env.items() if k.startswith('AGENT_GUARD_') or k in ['HOME','TMPDIR','XDG_CONFIG_HOME','XDG_CACHE_HOME','XDG_STATE_HOME']}})
  proc=subprocess.Popen(command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env,cwd=state,start_new_session=True);timeout=False
  try:stdout,stderr=proc.communicate(input_bytes,timeout=30)
  except subprocess.TimeoutExpired:timeout=True;os.killpg(proc.pid,signal.SIGKILL);stdout,stderr=proc.communicate()
  (dest/'stdout').write_bytes(stdout);(dest/'stderr').write_bytes(stderr);actual=None;reasons=[]
  try:
   envelope=json.loads(stdout)
   if host=='codex':
    assert envelope.get('decision')=='block','original Codex output must be blocked'
    context=envelope['hookSpecificOutput']['additionalContext'];start='Agent Guard sanitized tool output:\n';assert context.startswith(start);actual=json.loads(context[len(start):])
   else:actual=envelope['hookSpecificOutput']['updatedToolOutput']
   if actual!=expected:reasons.append('independent-expected-output-mismatch')
  except (ValueError,KeyError,TypeError,AssertionError) as e:reasons.append('invalid-host-envelope:'+str(e))
  text=trace.read_text(errors='replace');events=native_events(text,core)
  calls={api:sum(e['api']==api for e in events) for api in ['prepare-v1','redact-v1']};wanted={'prepare-v1':1 if variant=='fused' else 0,'redact-v1':1}
  if calls!=wanted:reasons.append('native-call-count-mismatch')
  if not all(e['exec_success'] and e['exit0'] for e in events):reasons.append('native-exec-or-exit-not-zero')
  if proc.returncode!=0:reasons.append('launcher-exit-not-zero')
  if timeout:reasons.append('fixed30s-timeout')
  row={'version':'v3.8.1','distribution':'actual-homebrew-launcher','host':host,'variant':variant,'n':1,'functional_only':True,'success':not reasons,'exit_code':proc.returncode,'timeout':timeout,'actual':actual,'expected':expected,'native_calls':calls,'expected_native_calls':wanted,'native_events':events,'reasons':reasons,'raw_path':dest.name,'stdout_sha256':hashlib.sha256(stdout).hexdigest()};dump(dest/'result.json',row);rows.append(row);dump(out/'results.json',rows);print(host,variant,'success',row['success'],'calls',calls,flush=True)
 unchanged=all(sha(Path(name))==value for name,value in original.items()) and all(os.readlink(name)==value for name,value in original_links.items());dump(out/'completion.json',{'calls':len(rows),'successes':sum(r['success'] for r in rows),'failures':sum(not r['success'] for r in rows),'prefix_product_files_unchanged':unchanged,'read_only_source_mounts':True,'performance_samples':False,'wrapper_latency':'N/A; no uninstrumented timing benchmark of actual Homebrew launcher'})
 assert unchanged,'read-only installed product changed'
if __name__=='__main__':main()
