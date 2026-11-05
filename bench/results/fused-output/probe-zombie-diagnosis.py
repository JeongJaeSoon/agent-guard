#!/usr/bin/env python3
import os, pathlib, subprocess, signal, time, json, sys
out=pathlib.Path(sys.argv[1]);out.mkdir(exist_ok=False)
cli=pathlib.Path(sys.argv[2]).resolve()
scanner=out/'gitleaks'
scanner.write_text('''#!/bin/sh
[ "$1" = version ] || exit 9
printf '%s\\n' "$PPID" > "$PROBE_CASE/parent"
while [ ! -f "$PROBE_CASE/release" ]; do sleep .01; done
case "$PROBE_MODE" in
 ready) printf '8.30.1\\n';;
 failed) exit 7;;
 slow) sleep 8; printf '8.30.1\\n';;
esac
''');scanner.chmod(0o755)
rows=[]
for mode in ['ready','failed','slow']:
 d=out/mode;d.mkdir();env=dict(os.environ,PROBE_CASE=str(d),PROBE_MODE=mode,AGENT_GUARD_GITLEAKS_BIN=str(scanner),AGENT_GUARD_LOG_MODE='off',AGENT_GUARD_RELEASE_CHECK='off')
 with (d/'stdout').open('wb') as stdout,(d/'stderr').open('wb') as stderr:
  p=subprocess.Popen([str(cli),'check'],stdout=stdout,stderr=stderr,env=env)
  try:
   deadline=time.monotonic()+10
   while not (d/'parent').exists():
    assert time.monotonic()<deadline and p.poll() is None
    time.sleep(.01)
   parent=int((d/'parent').read_text());assert parent==p.pid,(parent,p.pid)
   os.kill(parent,signal.SIGSTOP);(d/'release').touch()
   time.sleep(.25)
   subprocess.run(['ps','-axo','pid,ppid,pgid,stat,time,comm'],stdout=(d/'processes.txt').open('w'))
   time.sleep(2.25)
   os.kill(parent,signal.SIGCONT)
   status=p.wait(timeout=15)
  finally:
   if p.poll() is None:os.kill(p.pid,signal.SIGCONT);p.kill();p.wait()
 row={'mode':mode,'status':status,'stderr':(d/'stderr').read_text()};rows.append(row);print(row,flush=True)
(out/'results.json').write_text(json.dumps(rows,indent=2))
