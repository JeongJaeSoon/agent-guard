#!/usr/bin/env python3
"""공개 도구 구성요소의 별도 microbench. 전체 CLI 시간/인과 기여율로 합산하지 않는다."""
import argparse,csv,hashlib,json,os,resource,signal,statistics,subprocess,sys,tempfile,time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'correctness'))
from make_workloads import workloads
NAMES=['small-clean','many-replacement-leaves','long-multiline']
CORE='agent-guard-redact-x86_64-unknown-linux-musl'
def dump(p,v):Path(p).write_text(json.dumps(v,ensure_ascii=False,indent=2)+'\n')
def sha(b):return hashlib.sha256(b).hexdigest()
def encoded(v):return json.dumps(v,ensure_ascii=False,separators=(',',':')).encode()
def leaves(v):
    if isinstance(v,str):return [v]
    if isinstance(v,list):return sum((leaves(x) for x in v),[])
    if isinstance(v,dict):return sum((leaves(x) for x in v.values()),[])
    return []
def worker(spec):
    steps=[]
    for step in spec['steps']:
        steps.append((step,Path(step['input']).read_bytes(),open(step['stdout'],'wb'),open(step['stderr'],'wb')))
    statuses=[];begin=resource.getrusage(resource.RUSAGE_SELF);start=time.perf_counter()
    for step,data,out,err in steps:
        p=subprocess.Popen(step['command'],stdin=subprocess.PIPE,stdout=out,stderr=err,start_new_session=True,cwd=spec['cwd'])
        timeout=False
        try:p.communicate(data,timeout=30)
        except subprocess.TimeoutExpired:
            timeout=True;os.killpg(p.pid,signal.SIGKILL);p.communicate()
        statuses.append({'returncode':p.returncode,'timeout':timeout})
    wall=time.perf_counter()-start;child=resource.getrusage(resource.RUSAGE_CHILDREN);driver=resource.getrusage(resource.RUSAGE_SELF)
    for _,_,out,err in steps:out.close();err.close()
    dump(spec['metrics'],dict(wall_s=wall,cpu_s=child.ru_utime+child.ru_stime,user_cpu_s=child.ru_utime,system_cpu_s=child.ru_stime,max_child_rss_kib=child.ru_maxrss,wrapper_cpu_s=driver.ru_utime+driver.ru_stime-begin.ru_utime-begin.ru_stime,statuses=statuses))
def main():
    p=argparse.ArgumentParser();p.add_argument('--lab',default='/workspace/agent-guard-lab');p.add_argument('--out',required=True);p.add_argument('--jq',default='/workspace/agent-guard-lab/component-tools/jq');p.add_argument('--worker');a=p.parse_args()
    lab=Path(a.lab);out=Path(a.out);out.mkdir(parents=True,exist_ok=False);inputs=out/'inputs';inputs.mkdir();rows=[];order=0
    jq=Path(a.jq);baseline=lab/'releases/v3.6.13/payload';code=(baseline/'bin/agent-guard').read_text();config=baseline/'config/gitleaks.toml'
    shape=code.split("JQ_SHAPE_SAFE_WALK='",1)[1].split("\n'\n",1)[0]+'\n'
    func=code.split('redact_tool_response_json() {',1)[1].split('\n}\n',1)[0]
    redactor=shape+func.split('"$JQ_SHAPE_SAFE_WALK"\'',1)[1].rsplit("\n  ' 2>/dev/null",1)[0]
    framefunc=code.split('frame_json_string_leaves() {',1)[1].split('\n}\n',1)[0]
    framing=framefunc.split("jq -rj '",1)[1].rsplit("\n  '",1)[0]
    plain='if type == "string" then . else [.. | strings] | join("\\n") end'
    (inputs/'redact-v3.6.13.jq').write_text(redactor);(inputs/'frame-v3.6.13.jq').write_text(framing);(inputs/'plain.jq').write_text(plain)
    tools={'jq':str(jq),'gitleaks-official':str(lab/'scanners/official/gitleaks'),'gitleaks-homebrew':str(lab/'scanners/homebrew-relocated/gitleaks'),'native-v3.7.0':str(lab/'releases/v3.7.0/payload/libexec'/CORE),'native-v3.8.1':str(lab/'releases/v3.8.1/payload/libexec'/CORE),'true':'/usr/bin/true','sh':'/bin/sh'}
    protocol={'frozen_before_measurement':True,'warmups_per_arm':2,'paired_rounds':9,'pair_order':'AB,BA,AB,BA,AB,BA,AB,BA,AB','timeout_s':30,'cases':NAMES,'jq':str(jq),'config':'actual v3.6.13 public config bytes','measurement':'fresh Python wrapper per operation: Popen+tool startup+input piping+actual output writes included; Python wrapper interpreter startup and input-file read excluded; child user/system CPU and max individual-child RSS, wrapper CPU separately; no /proc sampler','role':'local actual 4CPU/16GiB independent component microbench; never add to/subtract from whole CLI or CI timings','pair_groups':['scanner-version official/Homebrew','scanner-stdin official/Homebrew for each case','jq two-process plain+framing/native prepare3.8.1 for each case','jq redactor3.6.13/native3.7.0 and jq redactor3.6.13/native3.8.1 for each case','direct true/shell colon spawn controls'],'files':{k:{'path':v,'sha256':sha(Path(v).read_bytes())} for k,v in tools.items()},'source_cli_sha256':sha((baseline/'bin/agent-guard').read_bytes()),'config_sha256':sha(config.read_bytes()),'extracted_redactor_sha256':sha(redactor.encode()),'extracted_framing_sha256':sha(framing.encode())}
    dump(out/'protocol.json',protocol)
    dump(out/'environment.json',dict(label='linux-local-components-actual4cpu-16g',uname=list(os.uname()),cgroup=Path('/proc/self/cgroup').read_text(),limits={k:Path('/sys/fs/cgroup'/Path(k)).read_text() for k in ['cpu.max','memory.max','memory.swap.max']},swaps=Path('/proc/swaps').read_text(),jq=subprocess.check_output([str(jq),'--version']).decode().strip(),whole_cli_comparable=False))
    for c in workloads():
        if c['name'] not in NAMES:continue
        value=c['value'];ls=leaves(value);secrets=sorted({s.split('API_KEY=',1)[1] for s in ls if s.startswith('API_KEY=')}|({'perf-literal-tail'} if any('perf-literal-tail' in s for s in ls) else set()))
        root=inputs/c['name'];root.mkdir();(root/'response.json').write_bytes(encoded(value));(root/'plain').write_bytes('\n'.join(ls).encode());(root/'framed').write_bytes(b''.join(s.encode().replace(b'\x1f',b'\x1f\x1f').replace(b'\x1e',b'\x1f\x1e')+b'\x1e\n' for s in ls));(root/'secrets.json').write_bytes(encoded(secrets));(root/'request.json').write_bytes(b'{"protocol":1,"response":'+encoded(value)+b',"secrets":'+encoded(secrets)+b'}\n');(root/'expected.json').write_bytes(encoded(c['expected']))
    empty=inputs/'empty';empty.write_bytes(b'')
    def invoke(group,case,arm,round_,phase):
        nonlocal order
        order+=1;folder=out/'raw'/f'{order:04d}-{group}-{case}-{arm}';folder.mkdir(parents=True);steps=[];root=inputs/case
        def step(command,input_,name):steps.append(dict(command=command,input=str(input_),stdout=str(folder/(name+'.stdout')),stderr=str(folder/(name+'.stderr'))))
        if group=='spawn':step([tools['true']] if arm=='true' else [tools['sh'],'-c',':'],empty,'process')
        elif group=='scanner-version':step([tools['gitleaks-'+arm],'version'],empty,'scanner')
        elif group=='scanner-stdin':step([tools['gitleaks-'+arm],'stdin','--no-banner','--config',str(config),'--report-format','json','--report-path',str(folder/'report.json')],root/'plain','scanner')
        elif group=='prepare':
            for name in ['plain','framed']:(folder/name).touch()
            if arm=='jq':
                step([tools['jq'],'-rj','-f',str(inputs/'plain.jq')],root/'response.json','plain');steps[-1]['stdout']=str(folder/'plain')
                step([tools['jq'],'-rj','-f',str(inputs/'frame-v3.6.13.jq')],root/'response.json','framed');steps[-1]['stdout']=str(folder/'framed')
            else:step([tools['native-v3.8.1'],'prepare-v1',str(folder/'plain'),str(folder/'framed')],root/'response.json','ack')
        elif group.startswith('redact-'):
            if arm=='jq':step([tools['jq'],'-c','--argjson','secrets',(root/'secrets.json').read_text(),'-f',str(inputs/'redact-v3.6.13.jq')],root/'response.json','redact')
            else:step([tools['native-'+arm],'redact-v1'],root/'request.json','redact')
        spec=dict(steps=steps,cwd=str(folder),metrics=str(folder/'metrics.json'));dump(folder/'spec.json',spec)
        subprocess.run([sys.executable,str(Path(__file__).resolve()),'--worker',str(folder/'spec.json')],check=True)
        row=json.loads((folder/'metrics.json').read_text());ok=all(not s['timeout'] and s['returncode'] in ([0,1] if group=='scanner-stdin' else [0]) for s in row['statuses']);reasons=[];signature=None
        try:
            if group=='scanner-version':ok=ok and (folder/'scanner.stdout').read_text().strip()=='8.30.1'
            elif group=='scanner-stdin':
                report=json.loads((folder/'report.json').read_text());assert isinstance(report,list)
                signature=sorted([{k:f.get(k) for k in ['RuleID','Secret','Match','StartLine','EndLine','StartColumn','EndColumn']} for f in report],key=lambda x:json.dumps(x,sort_keys=True))
            elif group=='prepare':
                for name in ['plain','framed']:
                    if (folder/name).read_bytes()!=(root/name).read_bytes():ok=False;reasons.append(name+'-byte-mismatch')
                if arm!='jq':ok=ok and (folder/'ack.stdout').read_bytes()==b'prepared-v1\n'
            elif group.startswith('redact-'):ok=ok and json.loads((folder/'redact.stdout').read_bytes())==json.loads((root/'expected.json').read_bytes())
        except (OSError,ValueError,AssertionError) as e:ok=False;reasons.append(type(e).__name__+':'+str(e))
        row.update(group=group,case=case,arm=arm,round=round_,phase=phase,order=order,success=ok,reasons=reasons,scanner_findings_signature=signature,raw=str(folder.relative_to(out)),environment='linux-local-components-actual4cpu-16g',input_sha256=sha(Path(steps[0]['input']).read_bytes()))
        rows.append(row)
        with (out/'samples.jsonl').open('a') as f:f.write(json.dumps(row,ensure_ascii=False)+'\n')
        if phase=='measured':print(group,case,arm,round_,round(row['wall_s']*1000,3),'ms',ok,flush=True)
    def pair(group,case,arms):
        for arm in arms:
            for warm in [-2,-1]:invoke(group,case,arm,warm,'warmup')
        for r in range(9):
            for arm in arms if r%2==0 else arms[::-1]:invoke(group,case,arm,r,'measured')
    pair('spawn','none',['true','sh'])
    pair('scanner-version','none',['official','homebrew'])
    for name in NAMES:
        pair('scanner-stdin',name,['official','homebrew']);pair('prepare',name,['jq','native'])
        for version in ['v3.7.0','v3.8.1']:pair('redact-'+version,name,['jq',version])
    with (out/'samples.csv').open('w') as f:
        cols=['environment','group','case','arm','phase','round','order','wall_s','cpu_s','user_cpu_s','system_cpu_s','max_child_rss_kib','wrapper_cpu_s','success','input_sha256','raw'];w=csv.DictWriter(f,fieldnames=cols,extrasaction='ignore');w.writeheader();w.writerows(rows)
    summaries=[]
    for group,case,arm in sorted({(r['group'],r['case'],r['arm']) for r in rows}):
        samples=[r for r in rows if (r['group'],r['case'],r['arm'])==(group,case,arm) and r['phase']=='measured'];summary=dict(group=group,case=case,arm=arm,n=len(samples),success_n=sum(r['success'] for r in samples))
        for metric in ['wall_s','cpu_s','user_cpu_s','system_cpu_s','max_child_rss_kib','wrapper_cpu_s']:
            nums=[r[metric] for r in samples];median=statistics.median(nums);summary[metric]=dict(median=median,min=min(nums),max=max(nums),mad=statistics.median(abs(x-median) for x in nums))
        summaries.append(summary)
    dump(out/'summary.json',summaries);dump(out/'completion.json',dict(samples=len(rows),measured=sum(r['phase']=='measured' for r in rows),failures=sum(not r['success'] for r in rows),complete=True))
if __name__=='__main__':
    if '--worker' in sys.argv:worker(json.loads(Path(sys.argv[sys.argv.index('--worker')+1]).read_text()))
    else:main()
