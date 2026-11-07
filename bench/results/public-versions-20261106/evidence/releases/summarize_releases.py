#!/usr/bin/env python3
"""다운로드된 원시 자료와 tag의 소스 일치를 확인하고 선택 경로를 기록한다."""
import hashlib,io,json,pathlib,shutil,subprocess,tarfile
BASE=pathlib.Path(__file__).resolve().parent
LAB=pathlib.Path('/workspace/agent-guard-lab/releases')
manifest=json.loads((BASE/'manifest.json').read_text())
changes={
'v3.6.13':'최초 기준. 셸 최적화·Rust 전환 이전의 공개 기본 셸/jq 경로.',
'v3.6.14':'중복 jq·문자열 분할·watchdog 프로세스 정리. jq 1.6 정상 문자열 과잉 마스킹 수정, 단일 문자열 스크립트 경로 오탐 감소. 선택형 Rust 소스 추가, 공개 native 바이너리는 없음.',
'v3.6.15':'정확한 snapshotToken/snapshot_token 키와 d<n>: 값의 조합에만 면제하여 문서 draft token 과잉 마스킹 수정. 기본 실행은 셸.',
'v3.7.0':'공개 tar·Homebrew에 네 플랫폼 Rust literal 치환기를 기본 제공. 탐지·정책·PII·어댑터는 셸 유지. exec printenv 입력 끝 NUL 오인에 따른 과잉 마스킹 수정, 업데이트 트랜잭션·복구 보강.',
'v3.7.1':'깊은 JSON 직렬화 손상 시 보존된 원본에서 구조 복구, scanner 준비 실패 원인 코드. 별도 scanner 최적화 실험은 기본 릴리스에 채택되지 않음.',
'v3.8.0':'기본 문자열 framing의 연속 구간 처리, 절대 실행 경로 해석의 자식 프로세스 감소, 숫자 fallback 비용 감소, 종료 scanner readiness 경합 수정. 선택형 fused 출력 통합과 prepare-v1 추가.',
'v3.8.1':'메시지 본문의 secret-like 오탐을 줄이고 set·$(env) 환경 출력 탐지 구멍 수정(#405). 이 설명은 소스 변경 사실이며 실제 이득/회귀의 크기는 새 실측으로만 판단.'}
rows=[]
for item in manifest:
    tag=item['tag'];evidence=BASE/tag;root=LAB/tag;payload=root/'payload'
    source=root/'source';source.mkdir(exist_ok=True)
    archive=subprocess.check_output(['git','archive',tag,'plugins/agent-guard'])
    with tarfile.open(fileobj=io.BytesIO(archive)) as tar:tar.extractall(source,filter='data')
    code=(payload/'bin/agent-guard').read_text()
    src=(source/'plugins/agent-guard/bin/agent-guard').read_bytes()
    script=(payload/'bin/agent-guard').read_bytes()
    native_file=payload/'libexec/agent-guard-redact-x86_64-unknown-linux-musl'
    support={'source_rust_option':'AGENT_GUARD_EXPERIMENTAL_REDACTOR' in code,'public_native':native_file.exists(),'fused_output':'AGENT_GUARD_EXPERIMENTAL_OUTPUT_PIPELINE' in code,'prepare_v1':False}
    if native_file.exists():
        probe=subprocess.run([str(native_file),'--help'],capture_output=True)
        (evidence/'native-help.stdout').write_bytes(probe.stdout)
        (evidence/'native-help.stderr').write_bytes(probe.stderr)
        support['prepare_v1']='prepare-v1' in code
        if support['fused_output']:
            probe=subprocess.run([str(native_file),'prepare-v1'],input=b'{"protocol":1,"response":{"text":"plain"}}\n',capture_output=True)
            (evidence/'native-prepare-probe.stdout').write_bytes(probe.stdout)
            (evidence/'native-prepare-probe.stderr').write_bytes(probe.stderr)
            support['invalid_prepare_probe_returncode']=probe.returncode
            correct_input=b'{"text":"plain"}\n'
            for suffix in ['input.json','stdout','stderr']:
                prior=evidence/('native-prepare-valid.'+suffix)
                if prior.exists() and not (evidence/('native-prepare-files-not-created.'+suffix)).exists():shutil.copyfile(prior,evidence/('native-prepare-files-not-created.'+suffix))
            (evidence/'native-prepare-valid.input.json').write_bytes(correct_input)
            (evidence/'native-prepare-valid.strings').touch()
            (evidence/'native-prepare-valid.framed').touch()
            probe=subprocess.run([str(native_file),'prepare-v1',str(evidence/'native-prepare-valid.strings'),str(evidence/'native-prepare-valid.framed')],input=correct_input,capture_output=True)
            (evidence/'native-prepare-valid.stdout').write_bytes(probe.stdout)
            (evidence/'native-prepare-valid.stderr').write_bytes(probe.stderr)
            support['prepare_valid_returncode']=probe.returncode
            support['prepare_v1']=probe.returncode==0 and probe.stdout.strip()==b'prepared-v1'
    for f in (root/'assets').iterdir():
        if f.name.endswith('.sha256') or f.name in ['native-validation.json','agent-guard.rb','bootstrap.sh','install.sh']:
            shutil.copyfile(f,evidence/f.name)
    validation=root/'assets/native-validation.json'
    matches=None if not validation.exists() else json.loads(validation.read_text())['release_sha']==item['commit']
    rows.append({'tag':tag,'commit':item['commit'],'published_at':item['published_at'],'cli_sha256':hashlib.sha256(script).hexdigest(),'cli_matches_tag_source':script==src,'config_sha256':hashlib.sha256((payload/'config/gitleaks.toml').read_bytes()).hexdigest(),'bootstrap_sha256':hashlib.sha256((root/'assets/bootstrap.sh').read_bytes()).hexdigest(),'native_validation_sha_matches':matches,'support':support,'package_default':'packaged rust literal replacement; shell policy/scanning' if native_file.exists() else 'shell/jq','git_plugin_default':'shell/jq (no native binaries in tag source plugin)','fused_enable':{'AGENT_GUARD_EXPERIMENTAL_OUTPUT_PIPELINE':'fused','AGENT_GUARD_EXPERIMENTAL_OUTPUT_PREPARE_BIN':str(native_file),'AGENT_GUARD_RUST_CORE_BIN_for_source_plugin':str(native_file)} if support['fused_output'] else None,'change_summary_ko':changes[tag]})
(BASE/'paths-and-changes.json').write_text(json.dumps(rows,ensure_ascii=False,indent=2)+'\n')
print(json.dumps(rows,ensure_ascii=False,indent=2))
