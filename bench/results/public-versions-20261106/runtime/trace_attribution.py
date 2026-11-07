#!/usr/bin/env python3
"""strace 보조 자료를 집계한다. trace의 시간은 주 CLI 성능 표에 합치지 않는다."""
import argparse,collections,csv,json,re
from pathlib import Path
LINE=re.compile(r'^\s*(?P<pid>\d+)\s+(?P<clock>\d{2}:\d{2}:\d{2}\.\d+)\s+(?P<body>.*)$')
EXEC=re.compile(r'\b(execve|execveat)\("([^"\\]*(?:\\.[^"\\]*)*)"')
CALL=re.compile(r'^(clone3|clone|fork|vfork)\(')
RESUMED=re.compile(r'^<\.\.\. (\w+) resumed>')
RESULT=re.compile(r'\)\s+=\s+(-?\d+)')
EXIT=re.compile(r'^\+\+\+ (exited with (\d+)|killed by (\w+))')
EXIT_SYSCALL=re.compile(r'^(exit_group|exit)\((-?\d+)\)')
def seconds(clock):
    h,m,s=clock.split(':');return int(h)*3600+int(m)*60+float(s)
def role(path,args):
    name=Path(path).name
    if name=='gitleaks':
        if re.search(r'\["[^\"]+", "(?:version|--version)"',args):return 'scanner-readiness-version'
        if '"stdin"' in args:return 'scanner-stdin-execution'
        return 'scanner-other'
    if name.startswith('agent-guard-redact'):
        if '"prepare-v1"' in args:return 'native-json-framing-prepare'
        if '"redact-v1"' in args:return 'native-literal-replacement'
        return 'native-other'
    if name=='jq':return 'jq-json-processing'
    if name=='awk' or name in ('gawk','mawk'):return 'awk-framing-or-policy'
    if name in ('sha256sum','shasum'):return 'packaged-native-checksum'
    if name in ('setsid','perl','sleep','kill','ps'):return 'watchdog-or-readiness-support'
    if name=='agent-guard':return 'cli-shell'
    return 'other-process'
def parse_trace(path):
    pending={};execs=[];creations=[];active={};leaders={};lifetimes=[];unparsed=[]
    for line in path.read_text(errors='replace').splitlines():
        match=LINE.match(line)
        if not match:
            if line.strip():unparsed.append(line)
            continue
        pid=int(match['pid']);stamp=seconds(match['clock']);body=match['body']
        resumed=RESUMED.match(body)
        if resumed and pid in pending:
            previous=pending.pop(pid);body=previous['body']+body[resumed.end():];stamp=previous['start']
        if '<unfinished ...>' in body:
            pending[pid]={'body':body.replace('<unfinished ...>',''),'start':stamp};continue
        result=RESULT.search(body);value=int(result[1]) if result else None
        ex=EXEC.search(body)
        if ex:
            kind=role(ex[2],body);event={'pid':pid,'path':ex[2],'role':kind,'result':value,'success':value==0,'start_clock_s':stamp}
            execs.append(event)
            if value==0:active[pid]=event;leaders.setdefault(pid,pid)
            continue
        create=CALL.match(body)
        if create:
            is_thread=bool(re.search(r'\bCLONE_THREAD\b',body))
            creations.append({'pid':pid,'syscall':create[1],'result':value,'success':value is not None and value>0,'thread':is_thread})
            if value is not None and value>0:leaders[value]=leaders.get(pid,pid) if is_thread else value
        exit_=EXIT.match(body);exit_call=EXIT_SYSCALL.match(body)
        target=leaders.get(pid,pid) if exit_call and exit_call[1]=='exit_group' else pid
        if (exit_ or exit_call) and target in active:
            event=active.pop(target);duration=stamp-event['start_clock_s']
            if duration<0:duration+=86400
            lifetimes.append(event|{'exec_to_exit_wall_s':duration,'exit_status':int(exit_call[2]) if exit_call else int(exit_[2]) if exit_[2] else None,'signal':exit_[3] if exit_ else None})
    counted=collections.Counter();duration=collections.Counter()
    for e in execs:counted[(e['role'],'success' if e['success'] else 'failure')]+=1
    for e in lifetimes:duration[e['role']]+=e['exec_to_exit_wall_s']
    groups=[]
    for k in sorted({e['role'] for e in execs}):
        groups.append({'role':k,'successful_execs':counted[(k,'success')],'failed_exec_attempts':counted[(k,'failure')],'exec_to_exit_wall_sum_s':duration[k],'completed_processes':sum(e['role']==k for e in lifetimes)})
    return {'groups':groups,'exec_events':execs,'creation_events':creations,'lifetimes':lifetimes,'successful_process_creations':sum(e['success'] and not e['thread'] for e in creations),'failed_creation_attempts':sum(not e['success'] and not e['thread'] for e in creations),'successful_thread_creations':sum(e['success'] and e['thread'] for e in creations),'unfinished_syscalls':pending,'unparsed_lines':unparsed}
def main():
    parser=argparse.ArgumentParser();parser.add_argument('--runtime',required=True);parser.add_argument('--out',required=True);args=parser.parse_args()
    root=Path(args.runtime);out=Path(args.out);out.mkdir(parents=True,exist_ok=False)
    samples=[json.loads(x) for x in (root/'samples.jsonl').read_text().splitlines() if x.strip()];rows=[];detail=[]
    for sample in samples:
        if sample['phase']!='trace':continue
        path=root/sample['trace_file'];data=parse_trace(path)
        meta={k:sample[k] for k in ['environment','scanner','host','audit','case','version','variant','distribution','round','success']}
        detail.append(meta|{'trace_file':sample['trace_file']}|data)
        for group in data['groups']:rows.append(meta|group|{'successful_process_creations':data['successful_process_creations'],'failed_creation_attempts':data['failed_creation_attempts'],'trace_file':sample['trace_file']})
    (out/'attribution.json').write_text(json.dumps(detail,ensure_ascii=False,indent=2)+'\n')
    if rows:
        with (out/'attribution.csv').open('w') as f:
            writer=csv.DictWriter(f,fieldnames=rows[0]);writer.writeheader();writer.writerows(rows)
    (out/'README.ko.md').write_text('''# 프로세스 trace 보조 계측\n\n이 자료는 strace가 붙은 별도 phase=trace이며, 주 CLI wall/CPU 표와 섞지 않는다. `successful_execs`는 성공한 exec만, `failed_exec_attempts`는 PATH 탐색 실패 등을 별도로 센다. 프로세스 생성도 clone3 미지원·실패를 실제 생성으로 세지 않는다. 같은 프로세스의 재exec는 새 프로세스 생성이 아니다.\n\n`scanner-readiness-version`은 실제 gitleaks version 실행, `scanner-stdin-execution`은 실제 stdin 스캔, `native-json-framing-prepare`와 `native-literal-replacement`는 실제 helper의 명령 인자로 구분한다. jq와 awk는 필터/코드가 strace 기본 문자열 상한으로 잘릴 수 있으므로 JSON 파싱·치환·framing의 정확한 세부 시간으로 분해하지 않는다. 이 분류로 shell 정책 비용 전체를 Rust 효과라고 부를 수 없다.\n\n`exec_to_exit_wall_sum_s`는 성공한 exec 시점부터 프로세스 종료까지의 관측 경과시간을 역할별로 합한 참고값이다. CPU 시간이 아니며 자식 대기·스케줄링·strace overhead가 포함된다. 여러 프로세스가 겹치므로 합이 전체 지연보다 커질 수 있다. 역할별 인과 기여율이나 전체 시간의 분할로 해석하지 않는다. 마지막 exec만 수명을 귀속하므로 재exec 전 구간은 별도 귀속되지 않는다. strace -qq가 종료 메시지를 생략하므로 exit/exit_group syscall도 읽으며, CLONE_THREAD의 종료는 thread leader에 연결한다. 실패나 출력 불일치가 있는 sample도 success=false와 함께 보존한다.\n\n재현: `python runtime/trace_attribution.py --runtime <run.py output dir> --out <new output dir>`\n''')
    print(json.dumps({'trace_samples':len(detail),'role_rows':len(rows)}))
if __name__=='__main__':main()
