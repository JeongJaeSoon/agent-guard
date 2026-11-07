#!/usr/bin/env python3
"""고정 합성 입력과 CLI와 독립적으로 지정한 기대값. 실행 전에 생성한다."""
import json
from pathlib import Path

def workloads():
    out=[]
    def add(name,value,expected=None,route='hook',status=0,**extra):
        out.append(dict(name=name,route=route,value=value,expected=value if expected is None else expected,status=status,**extra))
    suffix=' API_KEY=perf-literal-tail'
    for name,text in [('small-clean','ordinary status: build passed'),('long-line','a'*260000+suffix),('long-multiline','a'*260000+'\n'+suffix),('escaped-control','a'*130000+'\x1e'+'b'*130000+suffix),('many-lines','ordinary status: build passed\n'*8000+suffix)]:
        add(name,text,text.replace('perf-literal-tail','[REDACTED]'))
    add('many-replacement-leaves',['API_KEY=perf-literal-%03d'%i for i in range(100)]+['status']*4000,['API_KEY=[REDACTED]']*100+['status']*4000)
    add('dense-controls','a\x1f'*40000+suffix,'[REDACTED]')
    for name,text in [('placeholder-control','API_KEY=example_token'),('metadata-control','password_policy=strict token_name=counter'),('prose-control','error: password: authentication is disabled'),('snapshot-control','snapshot_token=draft-token'),('unicode-clean','한국어 日本語 🙂 완료'),('literal-truncation-marker','documentation: <skipped: too deep>')]:
        add(name,text)
    add('nul-precise',{'stdout':'prefix\0secret','clean':'visible','nested':['safe','\0']},{'stdout':'[REDACTED]','clean':'visible','nested':['safe','[REDACTED]']})
    add('multiline-quoted','PASSWORD="framing-first\nframing-second"\nvisible','PASSWORD="[REDACTED]"\nvisible')
    add('vendor-positive','ghp_'+'Ab3dE5fG7hI9jK1lM3nO5pQ7rS9tU1vW3xY5','[REDACTED]')
    add('vendor-placeholder','ghp_'+'x'*36)
    add('structure',{'type':'text','stdout':'API_KEY=perf-literal-tail','clean':'visible','number':42,'flag':False},{'type':'text','stdout':'API_KEY=[REDACTED]','clean':'visible','number':42,'flag':False})
    add('exec-clean','ordinary status: build passed',route='exec')
    add('exec-multiline','a'*260000+'\n'+suffix,('a'*260000+'\n'+suffix).replace('perf-literal-tail','[REDACTED]'),route='exec')
    add('exec-long-quoted-secret'," API_KEY='"+'a'*30000+'\n'+'b'*30000+"'"," API_KEY='[REDACTED]'",route='exec')
    for name,cmd,status in [
        ('message-body-fp','gh pr create --title "stop reading .env" --body "do not read state.env here"',0),
        ('commit-message-fp','git commit -m "drop state.env reads"',0),
        ('env-prose-fp','orca orchestration send --to lead --body "blocked: printenv and gh auth token were refused"',0),
        ('protected-file-positive','cat .env',2),
        ('message-file-positive','gh issue create -F .env',2),
        ('env-substitution-positive','orca orchestration send --body "$(env)"',2),
        ('set-substitution-positive','echo "$(set)"',2),
    ]:
        add(name,{'tool_name':'Bash','tool_input':{'command':cmd}},'',route='pre',status=status,category='false-positive' if name.endswith('fp') else 'security-positive')
    add('unknown-event',{'tool_name':'future_tool','tool_input':{'opaque':'visible'}},'',route='pre')
    add('prompt-clean',{'prompt':'Explain the build output'},'',route='prompt')
    for mode,status in [('open',0),('closed',2)]:
        add('scanner-failure-'+mode,{'tool_name':'Bash','tool_input':{'command':'printf clean'}},None,route='pre',status=status,infra_mode=mode,scanner_failure=True,category='failure-policy')
    return out

if __name__=='__main__':
    dest=Path(__file__).with_name('workloads.json')
    dest.write_text(json.dumps(workloads(),ensure_ascii=False,indent=2)+'\n')
    print(dest)
