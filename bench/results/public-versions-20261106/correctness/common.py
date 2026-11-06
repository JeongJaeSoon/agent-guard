"""모든 버전에서 같은 CLI 입력 및 호스트 응답 검증 규칙."""
import json

def payload(case):
    value=case['value']
    if case['route']=='hook':
        value={'tool_name':'mcp__latency__read','tool_response':value}
    return json.dumps(value,ensure_ascii=False,separators=(',',':')).encode()

def decode(case,host,stdout):
    if case['route']=='exec':
        return stdout.decode('utf-8').removesuffix('\n')
    if case['route'] in ('pre','prompt'):
        return stdout.decode('utf-8')
    if not stdout.strip():
        return case['value']
    envelope=json.loads(stdout)
    if host=='codex':
        if envelope.get('decision')!='block':
            raise ValueError('Codex sensitive output must block original')
        context=envelope['hookSpecificOutput']['additionalContext']
        prefix='Agent Guard sanitized tool output:\n'
        if not context.startswith(prefix):
            raise ValueError('missing Codex sanitized output prefix')
        return json.loads(context[len(prefix):])
    return envelope['hookSpecificOutput']['updatedToolOutput']

def validate(case,host,stdout,stderr=b'',status=0):
    reasons=[]
    if status!=case.get('status',0):
        reasons.append('exit-status')
    if case.get('scanner_failure'):
        if b'DEGRADED' not in stderr:
            reasons.append('missing-degraded-diagnostic')
        return not reasons, reasons, None
    try:
        actual=decode(case,host,stdout)
        if actual!=case['expected']:
            reasons.append('output-mismatch')
    except (ValueError,KeyError,TypeError,UnicodeDecodeError) as e:
        actual={'decode_error':str(e)}
        reasons.append('invalid-output')
    return not reasons,reasons,actual
