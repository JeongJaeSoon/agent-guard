#!/usr/bin/env python3
"""한 작업·환경별 실제 중앙값만 서술에 삽입한다. 개선율 합산/입력 평균 없음."""
import json,statistics,sys
from datetime import datetime
from zoneinfo import ZoneInfo
from pathlib import Path
B=Path(__file__).resolve().parents[1]
def load(p,default=None):return json.loads((B/p).read_text()) if (B/p).exists() else default
raw=load('analysis/runtime.json',[]); assert raw and all(r.get('policy_mode')=='common' for r in raw), 'strict common-policy primary only'; install=load('analysis/installation.json',[])
def med(rows,k):return statistics.median(x[k] for x in rows)
def change(a,b):return (b/a-1)*100
con=[]
def statement(text,path,label='원시 근거'):con.append(dict(text=text,sources=[dict(label=label,path=path)]))
for scanner,host in [('official','claude'),('homebrew','codex')]:
 for case,title in [('small-clean','정상 소출력'),('many-replacement-leaves','다수 문자열(4,100개 leaf 중 100개 치환)'),('long-multiline','긴 여러 줄 문자열(약 260 KB)')]:
  arms=[]
  for v,var in [('v3.6.13','default'),('v3.8.1','default'),('v3.8.1','fused')]:
   arms.append([r for r in raw if r['phase']=='runtime' and r['series']=='direct' and r['scanner']==scanner and r['host']==host and r['case']==case and r['version']==v and r['variant']==var and r['success'] and r['eligible']])
  if min(map(len,arms))<9:continue
  v=[med(r,'wall_s')*1000 for r in arms];cpu=[med(r,'cpu_s')*1000 for r in arms]
  statement(f'{scanner} scanner·{host}·audit off의 {title}: 기본 경로 지연 {v[0]:.2f}→{v[1]:.2f} ms({change(v[0],v[1]):+.2f}%), CPU {cpu[0]:.2f}→{cpu[1]:.2f} ms({change(cpu[0],cpu[1]):+.2f}%). v3.8.1에서 fused를 추가하면 지연 {v[2]:.2f} ms(동일 버전 기본 대비 {change(v[1],v[2]):+.2f}%, 최초 대비 직접 {change(v[0],v[2]):+.2f}%), CPU {cpu[2]:.2f} ms(기본 대비 {change(cpu[1],cpu[2]):+.2f}%). 각 arm n={len(arms[0])}; IQR과 모든 표본은 조건별 표에 있다.','../analysis/runtime.json')
# Memory comes only from its own instrumented cohort.
for scanner,host in [('official','claude'),('homebrew','codex')]:
 rows=[]
 for var in ['default','fused']:
  rows.append([r for r in raw if r['phase']=='rss' and r['series']=='rss' and r['scanner']==scanner and r['host']==host and r['case']=='long-multiline' and r['version']=='v3.8.1' and r['variant']==var and r['workers']==4 and r['success']])
 if min(map(len,rows))<9:continue
 a,b=[med(r,'rss_sum_peak_kib')/1024 for r in rows]
 statement(f'별도 RSS 계측의 {scanner}·{host}·긴 여러 줄·4동시: v3.8.1 기본→fused의 표본 RSS 합 최대 중앙값 {a:.2f}→{b:.2f} MiB({change(a,b):+.2f}%, 각 n={len(rows[0])}). 고유 물리 메모리가 아니며, 이 계측의 지연·CPU는 본 성능표에 넣지 않았다.','../analysis/runtime.json')
# Source-only plugin users still get shell changes, but native availability differs.
for scanner,host in [('homebrew','codex')]:
 arms=[[r for r in raw if r['phase']=='runtime' and r['series']=='source' and r['scanner']==scanner and r['host']==host and r['case']=='many-replacement-leaves' and r['version']==v and r['variant']==var and r['success']] for v,var in [('v3.6.13','default'),('v3.8.1','default'),('v3.8.1','fused')]]
 if min(map(len,arms))>=9:
  w=[med(r,'wall_s')*1000 for r in arms]
  statement(f'소스 Git 플러그인의 {scanner}·{host}·다수 문자열: 기본 shell/jq 경로만으로도 {w[0]:.2f}→{w[1]:.2f} ms({change(w[0],w[1]):+.2f}%)였다. 별도 공개 native를 지정한 fused는 {w[2]:.2f} ms지만 추가 독립 설치가 필요한 별도 구성이다. 각 arm n={len(arms[0])}. 독립 배포본 기본 결과와 합치지 않는다.','../analysis/runtime.json')
releases=load('evidence/releases/release-summary.json',[])
a,b=releases[0],releases[-1]
statement(f'배포 archive는 {a["archive_size_bytes"]:,}→{b["archive_size_bytes"]:,} B({change(a["archive_size_bytes"],b["archive_size_bytes"]):+.2f}%), 순수 payload 파일 합은 {a["payload_files_bytes"]:,}→{b["payload_files_bytes"]:,} B({change(a["payload_files_bytes"],b["payload_files_bytes"]):+.2f}%). 기본 Rust helper가 포함되는 v3.7 이후 설치 증가를 런타임 속도 이득과 분리한다.','../evidence/releases/release-summary.json')
for env,scenario,desc in [('linux-ci-install-2cpu-1g','standalone-fresh-cached','주 제한 환경, 다운로드 제외·Python 운송 shim 포함 신규 설치'),('docker-debian12-actual-4CPU-16GiB-no-host-swap; requested limits unenforced','standalone-fresh-network','실제 4 CPU·16 GiB 보조 환경의 네트워크 포함 신규 설치')]:
 arms=[[r for r in install if r.get('environment')==env and r.get('scenario')==scenario and r['version'].lstrip('v')==v and not r.get('warmup') and r['success']] for v in ['3.6.13','3.8.1']]
 if min(map(len,arms))>=9:
  w=[med(r,'wall_s') for r in arms];c=[med(r,'cpu_s') for r in arms]
  statement(f'{desc}: 지연 {w[0]:.6f}→{w[1]:.6f} s({change(*w):+.2f}%), CPU {c[0]:.6f}→{c[1]:.6f} s({change(*c):+.2f}%), 각 n={len(arms[0])}. 초기 bootstrap 스크립트 다운로드와 OS 의존성 최초 설치는 제외한다. 환경이나 운송 방식이 다른 두 결과를 합산하지 않는다.','../analysis/installation.json')
brew=[[r for r in install if r.get('scenario')=='homebrew-fresh-cached' and r['version'].lstrip('v')==v and not r.get('warmup') and r['success']] for v in ['3.6.13','3.8.1']]
if min(map(len,brew))>=9:
 w=[med(r,'wall_s') for r in brew];c=[med(r,'cpu_s') for r in brew]
 statement(f'기존 Homebrew 사용자·로컬 Debian13 실제4CPU/16GiB·cached package-only 신규 설치: {w[0]:.5f}→{w[1]:.5f} s({change(*w):+.2f}%), CPU {c[0]:.5f}→{c[1]:.5f} s({change(*c):+.2f}%), 각 n={len(brew[0])}. CPU는 >5% 회귀로 표시하지만 산포와 미검증 원인을 함께 본다. 최초 Brew/의존성/네트워크 비용은 이 값에 포함되지 않는다.','../analysis/installation.json')
statement('정확도는 32개 고정 CLI 사례×두 host에서 각 scanner·설정 cohort별 v3.6.13 52/64, v3.6.14 52/64, v3.6.15~v3.8.0 54/64, v3.8.1 64/64가 기대값과 일치했다. 메시지 본문 오탐과 env/set 치환 탐지 누락이 v3.8.1에서 해소된 사례다. 이는 선택한 합성 사례의 검사 통과 수이며 실사용 오탐률이 아니다.','../correctness/ci-summary.json')
statement('완전히 마스킹된 토큰을 사용자 프롬프트에 넣었을 때의 오탐은 일곱 공개 버전 모두 남아 있었다. 부분 마스킹 뒤 실제 형태가 남은 양성 대조군은 차단했다. 최신 main의 후속 #416 수정은 이 비교에 섞지 않았다.','../correctness/local-summary.json')
runtime_envs=[]
for run_id in ['42232755942','42227732499']:
 for artifact in sorted((B/'evidence/ci'/run_id/'extracted').glob('*')):
  envfiles=list(artifact.glob('runtime/*/environment.json'))
  if not envfiles and 'installation' not in artifact.name:continue
  prov=artifact/'provision'; cpu_file=prov/'cpuinfo.txt'
  cpu_text=cpu_file.read_text() if cpu_file.exists() else ''
  cpu=next((line.split(':',1)[1].strip() for line in cpu_text.splitlines() if line.startswith('model name')), 'N/A')
  image_file=prov/'image.json';image=json.loads(image_file.read_text())[0].get('Id') if image_file.exists() else 'N/A'
  if envfiles:
   env=json.loads(envfiles[0].read_text()); sample=envfiles[0].parent/'samples.jsonl';first=json.loads(sample.open().readline())
   runtime_envs.append(dict(environment=env['label'],scanner=first['scanner'],host=first['host'],cpu_model=cpu,image_id=image,cpu_max=env['limits']['cpu.max'],memory_max=env['limits']['memory.max'],memory_swap_max=env['limits']['memory.swap.max'],scanner_sha256=first['scanner_sha256'],config_sha256=first['config_sha256'],jq_sha256=env.get('jq_sha256'),raw_path='../raw/ci-'+run_id+'-'+artifact.name+'.zip'))
  else:
   runtime_envs.append(dict(environment='linux-ci-install-2cpu-1g',scanner='official',host='installation',cpu_model=cpu,image_id=image,cpu_max='200000 100000',memory_max='1073741824',memory_swap_max='0',raw_path='../raw/ci-'+run_id+'-'+artifact.name+'.zip'))
def pick(scanner,host,case,version,variant='default',phase='runtime',series='direct',workers=1):
 return [r for r in raw if r['scanner']==scanner and r['host']==host and r['case']==case and r['version']==version and r['variant']==variant and r['phase']==phase and r['series']==series and r['workers']==workers and r['success'] and r['eligible']]
highlights=[]
def hi(text,path):highlights.append(dict(text=text,sources=[dict(label='원시 근거',path=path)]))
examples=[]
for sc,host in [('official','claude'),('homebrew','codex')]:
 old=pick(sc,host,'many-replacement-leaves','v3.6.13');new=pick(sc,host,'many-replacement-leaves','v3.8.1')
 if min(len(old),len(new))>=9:
  examples.append(f'{sc}·{host}: 지연 {change(med(old,"wall_s"),med(new,"wall_s")):+.2f}%, CPU {change(med(old,"cpu_s"),med(new,"cpu_s")):+.2f}%')
if examples:hi('다수 문자열 치환의 기본 경로 누적 변화(4,100개 문자열 중 100개 치환, 구성별 n=14): '+ '; '.join(examples)+'. 환경별 결과이며 서로 평균 내지 않았다.','../analysis/runtime.json')
new=pick('homebrew','codex','many-replacement-leaves','v3.8.1');fused=pick('homebrew','codex','many-replacement-leaves','v3.8.1','fused')
if min(len(new),len(fused))>=9:
 hi(f'Homebrew·Codex의 같은 입력에서 fused를 켜면 기본 경로보다 지연 {change(med(new,"wall_s"),med(fused,"wall_s")):+.2f}%, CPU {change(med(new,"cpu_s"),med(fused,"cpu_s")):+.2f}%다. 이 조건의 정상 소출력·긴 문자열은 기본 경로에서 10% 개선 기준에 못 미쳤다.','../analysis/runtime.json')
a=pick('homebrew','codex','many-replacement-leaves','v3.8.1',phase='rss',series='rss',workers=4);b=pick('homebrew','codex','many-replacement-leaves','v3.8.1','fused',phase='rss',series='rss',workers=4)
if min(len(a),len(b))>=9:
 x,y=med(a,'rss_sum_peak_kib')/1024,med(b,'rss_sum_peak_kib')/1024
 hi(f'메모리 교환관계: 같은 비교군의 별도 4동시 RSS 계측에서 다수 문자열의 표본 RSS 합 최대 중앙값은 {x:.2f}→{y:.2f} MiB({change(x,y):+.2f}%, 각 n=16)였다. 공유 페이지가 중복될 수 있어 고유 물리 메모리 사용량과 구분한다.','../analysis/runtime.json')
release_rows=load('evidence/releases/release-summary.json');ra,rz=release_rows[0],release_rows[-1]
ci_install=[[r for r in install if r.get('environment')=='linux-ci-install-2cpu-1g' and r.get('scenario')=='standalone-fresh-cached' and r['version'].lstrip('v')==v and not r.get('warmup') and r['success']] for v in ['3.6.13','3.8.1']]
if min(map(len,ci_install))>=9:
 hi(f'설치 비용은 증가했다. 공개 archive는 {change(ra["archive_size_bytes"],rz["archive_size_bytes"]):+.2f}%, payload 파일 합은 {change(ra["payload_files_bytes"],rz["payload_files_bytes"]):+.2f}%다. 별도 2 CPU·1 GiB 설치군의 네트워크 제외 새 설치 시간은 {change(med(ci_install[0],"wall_s"),med(ci_install[1],"wall_s")):+.2f}%, CPU는 {change(med(ci_install[0],"cpu_s"),med(ci_install[1],"cpu_s")):+.2f}%(각 n=9)다. 네트워크 포함 경로와 기존 Homebrew 사용자의 비용은 별도 환경에서 직접 측정했다.','../analysis/installation.json')
hi('선택한 32개 CLI 사례×두 host에서 v3.8.1은 각 scanner·설정군 64/64를 통과했다. 이 CI 사례에서는 메시지 본문 오탐 감소와 env/set 탐지 누락 수정을 확인했다. 별도 로컬 4 CPU·16 GiB·jq1.6 보조 검사 42건에서는 printenv 인자의 과도한 마스킹 감소를 확인했다. 이미 마스킹된 토큰의 오탐은 v3.8.1에도 남았고, 새 lifecycle event·macOS·ARM·실제 host 앱 전체 동작은 미검증이다.','../correctness/ci-findings.ko.md')
highlights[-1]['sources'].append(dict(label='로컬 jq1.6 보조 근거', path='../correctness/local-summary.json'))
figures=[]
for scanner in ['official','homebrew']:
 for host in ['claude','codex']:
  for family,title in [('latency-cpu','기본 7버전 CLI 지연·CPU'),('throughput','단일·4동시 처리량'),('memory','최대 개별 자식 RSS·표본 RSS 합')]:
   slug=f'{scanner}-{host}-{family}'
   figures.append(dict(path='figures/'+slug+'.svg',title=f'{scanner}·{host} — {title}',embed_markdown=slug in ['official-claude-latency-cpu','homebrew-codex-latency-cpu','homebrew-codex-memory']))
figures.append(dict(path='figures/installation-ci-cached-fresh.svg',title='제한 환경의 cached 신규 설치 비용 — 네트워크 제외',embed_markdown=True))
policy_proofs=[]
for artifact in sorted((B/'evidence/ci/42232755942/extracted').glob('*')):
 p=artifact/'runtime/controlled/policy-proof.json'
 if p.exists():policy_proofs.append(dict(artifact=artifact.name,proof=json.loads(p.read_text())))
changes=load('evidence/releases/paths-and-changes.json',[])
ctx=dict(
 figures=figures,
 policy_proofs=policy_proofs,
 measured_driver=load('analysis/measured-driver.json'),
 raw_index='../raw/index.json',
 runtime_environments=runtime_envs,
 title='공개 v3.6.13~v3.8.1 동일 조건 직접 비교',
 measured_date='조사·실측 2026-11-06 21:53 JST ~ '+datetime.now(ZoneInfo('Asia/Tokyo')).strftime('%Y-%m-%d %H:%M JST')+'; 원시 timestamp는 UTC',
 environment={'primary':'각 job의 전용 Ubuntu 24.04 VM 안 Debian 12 / Python 3.12.16 container, Linux x86_64; scanner/host별 cohort 독립','local':'실제 cgroup CPU 4개 quota, 메모리 16 GiB; Docker rootless CgroupDriver=none, 요청한 2 CPU/1 GiB는 미적용. 별도 설치·정확도·component 보조 실험','scope':'공개 CLI hook callback 직접 실행. 실제 Claude/Codex 앱 및 manifest resolver 전체 지연을 재현한 결과는 아니다. 각 버전의 pipeline/redactor 기본값은 유지하고 나머지 조건을 통제했다.'},
 limits={'primary_cpu_max':'200000 100000','primary_memory_max':1073741824,'primary_memory_swap_max':0,'proof':'각 원본 artifact provision/applied-limits.txt 및 runtime/*/environment.json','host_swap':'CI /proc/swaps에는 host swap 3 GiB가 보여도 실험 cgroup memory.swap.max=0으로 사용 불가. 로컬 host swap은 없음.'},
 protocol=load('runtime/protocol.json')|{'policy_mode':'common','policy_proof':'new controlled cohort policy-proof.json, 14 version/distribution entries, all three effective policy SHA equal','rss_rounds':16,'rss_arms':'seven defaults plus v3.8.1 fused','original_public_policy_cohort':'42224583403 and RSS42224583622 kept separate, never pooled'},
 preferred_install_environment='linux-ci-install-2cpu-1g',
 highlights=highlights,
 conclusions=con,
 version_changes={r['tag']:r['change_summary_ko']+' 관련 변경의 존재는 확인했다. 아래 시점별 수치와의 인과 기여분을 독립적으로 분해했다는 뜻은 아니다.' for r in changes},
 provenance=releases,
 recommendations=[
 {'text':'입력이 여러 문자열 leaf에 걸친 다수 치환이라면 기본 경로의 직접 비교를 먼저 확인한다. 정상 소출력·긴 문자열·제어 문자·unknown tool·실패 복귀의 변화는 별도 행으로 판단한다. 모든 입력의 개선율을 평균 내어 하나의 전체 성과로 제시하지 않는다.','sources':[{'label':'기본/직접 비교','path':'../analysis/runtime.json'}]},
 {'text':'v3.7 이상 독립 배포본과 Homebrew package에는 공개 Rust helper가 기본 포함되고 사용자 컴파일러가 필요하지 않다. 소스만 있는 Git 플러그인은 기본 shell/jq를 계속 쓴다. Git 플러그인에 같은 공개 helper를 추가하려면 별도 독립 설치 전체 비용과 명시 설정을 고려한다.','sources':[{'label':'설치·배포 경로','path':'../installation/summary.json'}]},
 {'text':'fused는 v3.8.0/1에서만 별도로 검증했다. AGENT_GUARD_EXPERIMENTAL_OUTPUT_PIPELINE=fused와 검증한 공개 core의 절대 경로 AGENT_GUARD_EXPERIMENTAL_OUTPUT_PREPARE_BIN을 함께 지정한다. 소스 플러그인에는 동일 파일의 AGENT_GUARD_RUST_CORE_BIN도 지정한다. 입력별 추가 속도와 표본 RSS 합 증가를 함께 보고 선택한다.','sources':[{'label':'활성화·공개 파일 해시','path':'../evidence/releases/paths-and-changes.json'}]},
 {'text':'공통 기준 정책은 실험 재현용이다. 실사용에서는 새 배송 정책의 보안·오탐 수정과 사용자 지정 정책을 함께 검토한다. 공개 native 단일 파일을 수동 설치하고 명시 경로로 설정하는 선택지도 있지만, 그 최소 설치 경로의 시간·CPU는 측정하지 않았다. 소스 플러그인에 추가하는 비용은 여기서 직접 검증한 전체 독립 설치와 구분한다.','sources':[{'label':'공개 native 자산','path':'../evidence/releases/manifest.json'}]},
 {'text':'업데이트 전 정책은 AGENT_GUARD_GITLEAKS_CONFIG로 지정한 외부 파일에 유지한다. 기존 rc 내용과 외부 정책은 보존됐지만 배포 payload/config/gitleaks.toml 직접 수정은 새 공개 기본 정책으로 덮어써졌다.','sources':[{'label':'설정 보존 원시 대조','path':'../installation/config-preservation.json'}]}
 ],
 limitations=[
 '사용 성능에서 Homebrew 표시는 scanner의 출처다. 공개 tar의 payload/bin/agent-guard를 직접 호출했다. 설치된 PATH symlink/Brew wrapper의 추가 시작 비용은 미계측이며, 실제 Brew launcher의 기본·선택형 native 호출은 별도 4건 기능검증으로 확인했다.',
 '검증 플랫폼은 Linux x86_64뿐이다. macOS, ARM, 실제 사용자의 host plugin clone 옵션·캐시 업데이트·앱 재시작 비용으로 일반화하지 않는다.',
 '고정 unknown-event 입력은 실제로 future_tool을 CLI hook-pre-tool에 보낸 unknown tool 검사다. 실제 새 lifecycle event의 host dispatch는 generic router가 없고 host 통합이 미구성이라 전 버전 N/A다.',
 '초기 scanner통제·배송Bash정책 유지 cohort(42224583403/42224583622)는 비교조건 누락을 발견한 뒤 전량별도보존했다. 주 사용 성능 비교는42232755942의 scanner·Bash정책 공통 바이트와 동일deny-read를 검증한 새 독립코호트만 사용한다. 정확도 32개 CLI 사례는42224583403의 배송 deny-bash 정책을 유지한 별도 코호트이며 fixed/packaged는 scanner TOML 조건을 뜻한다. 두코호트사이 값 차이로 정책변경효과를 계산하지 않았다.',
 'config_sha256는 scanner용 gitleaks.toml의 해시다. deny-read의 공개 바이트는 모든 버전에 같았다. 배송 deny-bash가 바뀐 v3.8.1에서도 준비 검사가 이 파일을 읽었다. 최종 공통 모드에서는 deny-bash도 기준 파일로 지정하고, 7버전×2배포 경로의 세 정책 해시 동등성을 측정 전에 확인했다.',
 '각 VM의 CPU 모델이 다를 수 있어 Claude/Codex 또는 scanner간 절대 지연 차이를 host protocol/scanner 단독 원인으로 설명하지 않는다. 비교는 각 동일 job 안의 버전/경로 교대 값이다.',
 '전 버전 순환 비교와 endpoint 직접 교대는 서로 다른 시간대의 독립 반복이다. 두 결과의 중앙값을 강제로 같게 만들거나 한쪽 숫자로 다른 쪽을 대체하지 않는다.',
 '2 CPU/1 GiB 주 사용 성능 코호트의 지연·CPU와 같은 VM의 별도 phase=rss 계측은 계측 비용이 달라 합산하지 않는다. 4 CPU/16 GiB component·설치 값도 별도 환경으로 유지한다. 환경 사이 손익분기 요청 횟수는 계산하지 않았다.',
 '4동시 처리량은 요청 4개를 한 wave로 보내는 4/wall_s다. 지속 부하의 정상상태 처리량이 아니다. CPU와 wall은 4개 묶음 합계/완료 시간이므로 단일 요청 비용과 무표기 비교하지 않는다.',
 '짧은 프로세스의 RUSAGE_CHILDREN peak에는 fork 직전 Python launcher 메모리 약13.6 MiB 바닥값이 포함될 수 있다. 특히 scanner를 호출하지 않는 unknown/failure 경로의 제품 고유 메모리 절감은 이 수치만으로 주장할 수 없다.',
 '초기 CI는 protected0700 evidence UID 차이로 artifact 업로드가 실패했다. 회수된 취소 배치의 JSON/로그와 미회수 raw 범위를 보존하고 최종 성능 집계에서 제외했다. 업로드만 수정한 고정 프로토콜 새 batch를 사용했다.',
 '최종 공식 정확도 job은 완료한 사례 뒤 caller/parser --suite 불일치로 exit2가 났다. 완료 raw는 그대로 사용하고 미실행 기존 core corpus는 별도 로컬 보조 검증으로 분리했다. 주 성능 batch는 재실행하지 않았다.',
 'CI network 설치 raw의 scope 문자열은 cached 설명을 잘못 승계했다. scenario·실제 curl 명령·SHA로 archive-only 다운로드임을 확인했고 원본은 변경하지 않았다. 집계에서는 실제 phase 의미를 구분한다.',
 'v3.7.1의 jq1.8.1 depth2000 직렬화 복구는 이번 jq1.7.1/1.6 실험에서 재현하지 않았다. 관련 변경의 존재만 확인했다.',
 '초기 jq1.6 oracle의 snapshot-control2행은 계약을 잘못 지정했다. 원본을 보존하고 oracle_invalid로 분리했다. 본32사례는 사전 수정한 기대값을 사용했다. timeout은 CLI30초/설치120초로 고정하며 확대·성공 선별 재실행하지 않았다.',
 '원래 893MB 설치 artifact는 ID/SHA가 같은 공개 배포 파일 복사를 제외한 read-only compact export로 회수했다. 모든 원본 파일 hash와 제외 사유, 원본 만료일은 export manifest에 남는다. 계측 결과/로그/수정 설정 등 비공개 생성물은 보존했다.',
 '이 환경의 Chromium 정책이 file:// URL을 차단하므로 허용 localhost에서 실제 생성 HTML을 열어 외부 요청 없이 표·차트·필터·다운로드를 검증했다. HTML 자체는 데이터/스크립트/스타일을 내장하며 CDN과 서버 기능이 필요하지 않는다. file:// 직접 실행은 이 관리 브라우저에서 미검증이다.',
 '제공된 이전 v3.8.0 문서는 지정 commit/blob의 GitHub API 원문으로 다시 읽었으며 그 숫자는 이번 그래프나 개선율 계산에 사용하지 않았다.'
 ],
 reproduction=[
 'sh bench/results/public-versions-20261106/runtime/ci.sh /tmp/new-lab /tmp/new-evidence agent-guard-public-bench:20261106 official claude controlled',
 'sh bench/results/public-versions-20261106/runtime/ci.sh /tmp/new-rss-lab /tmp/new-rss-evidence agent-guard-public-bench:20261106 homebrew codex controlled',
 'python3 bench/results/public-versions-20261106/analysis/assemble.py --ci-roots bench/results/public-versions-20261106/evidence/ci/42232755942/extracted bench/results/public-versions-20261106/evidence/ci/42227732499/extracted --out bench/results/public-versions-20261106/analysis --require-complete --runtime-policy common --ci-correctness bench/results/public-versions-20261106/correctness/ci-analysis.json --local-install bench/results/public-versions-20261106/installation/results.json --local-correctness bench/results/public-versions-20261106/correctness/local-correctness-analysis.json',
 'python3 bench/results/public-versions-20261106/analysis/build_context.py',
 'python3 bench/results/public-versions-20261106/report/generate.py --runtime bench/results/public-versions-20261106/analysis/runtime.json --metadata bench/results/public-versions-20261106/report/context.json --installation bench/results/public-versions-20261106/analysis/installation.json --installation-summary bench/results/public-versions-20261106/installation/summary.json --correctness bench/results/public-versions-20261106/analysis/correctness.json --correctness-summary bench/results/public-versions-20261106/analysis/supplementary-correctness.json --out bench/results/public-versions-20261106/report'
 ],
 attribution={'environment':load('runtime/components-local/environment.json'),'scope':'분리 단계 실험, 각 arm n9 및 MAD 보존. CLI 전체 개선율로 합산/배분하지 않는다. 여러 알고리즘·프로세스 수 차이를 포함한 구현 비교이며 Rust 언어 자체의 순수 효과를 뜻하지 않는다.','comparisons':load('runtime/components-local/comparisons.json'),'file_size_breakdown':load('analysis/file-size-breakdown.json'),'source':'../raw/components-local.zip','trace':'별도 성공 exec/실패 시도 parser로 scanner version/stdin·jq·awk·checksum·native prepare/redact를 구분. trace의 관측 수명 합은 CPU나 전체 시간 분할이 아니다.'},
 security_compatibility={'core_summary':load('correctness/local-core-summary.json'),'large_output':'1MiB/8MiB exec 전체마스킹 cap 18건은 모두 통과, prepare/redact 호출0인 조기 cap분기다. n1정확도 보조이며 빠른 치환 성과로 세지 않는다.','cases':'32CLI사례·13scanner정책사례·기존1013core차등corpus·명시 helper fault injection·별도printenv/완전마스킹오탐/큰출력cap검증을 구분','known_remaining':'신뢰 override helper가 거짓 prepared-v1 성공 ack와 일부 데이터만 반환하면 원문 통과가 관측됐다. 기본 공개 native가 실제 거짓 성공했다는 증거와 구분하지만 malformed-success 복귀 한계는 숨기지 않는다.','source':'../correctness/ci-findings.ko.md'})
(B/'report/context.json').write_text(json.dumps(ctx,ensure_ascii=False,indent=2)+'\n')
print('conclusions',len(con))
