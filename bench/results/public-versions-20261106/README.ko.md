# Agent Guard 공개 7버전 직접 비교

공개 v3.6.13, v3.6.14, v3.6.15, v3.7.0, v3.7.1, v3.8.0, v3.8.1의 실제 배포 파일을 실행했다. 제품 코드는 변경하지 않았다.

- [독립형 한국어 HTML](report/report.ko.html): 환경·scanner·host·입력·기본/선택형 경로를 골라 표와 그래프를 확인한다. 데이터·코드·스타일을 내장하며 외부 CDN이 없다.
- [한국어 Markdown 리포트](report/README.ko.md)
- [원시 자료와 SHA-256 인덱스](raw/index.json), [전체 파일 체크섬](raw/SHA256SUMS)
- [재현 방법](REPRODUCE.ko.md), [증거 패킹·복원](analysis/EVIDENCE-PACKAGING.ko.md)
- [공개 릴리스·파일 해시](evidence/releases/release-summary.json)
- [전체 개선·회귀 판정 CSV](analysis/changes.csv), [회귀 원문 JSON](analysis/regressions.json): 서로 다른 조건·지표·비교 유형은 독립 행이며 개수를 실사용 회귀율로 해석하지 않는다.
- [실제 복원·원본 대조](analysis/final-evidence-original-comparison.json), [최종 증거 패킹 검증](analysis/final-evidence-packaging-summary.json)
- [실제 브라우저 검증 자료](report/browser-evidence.zip), [별도 프로세스 trace 해석](analysis/TRACE-FINDINGS.ko.md)·[전체 분류](analysis/traces/)
- [저장소 CI의 양성 fixture 탐지와 바이트 보존 패키징](analysis/CI-PACKAGING.ko.md)

## 비교 조건

주 성능 자료는 `42232755942`의 **공통 정책 비교군**이다. 각 독립 VM에서 모든 버전·경로를 같은 scanner 바이트, jq 1.7.1, 입력, 설정, audit 상태와 계측으로 실행한다. 세 유효 정책 파일의 해시가 7버전×2배포 경로에서 같은지 측정 전에 검사한다. 기본 redactor/pipeline 선택은 배포본 그대로이며, 선택형 fused는 지원하는 v3.8.0/1에서 분리한다.

컨테이너에서 `cpu.max=200000 100000`, `memory.max=1073741824`, `memory.swap.max=0`을 확인해야 시작한다. `--cpus=2` 등의 옵션만 보고 제한 적용을 주장하지 않는다. 각 VM의 CPU 모델이 다를 수 있어 host/scanner 사이 절대 지연 차이를 그 한 요소의 효과로 해석하지 않는다.

기본 7버전은 14회 순환·역순 배치, endpoint 직접 비교는 14회 교대, 4동시 처리량과 버전별 RSS는 16회 균형 배치다. 각 구성 2회 warmup, CLI timeout 30초를 고정했다. 지연·CPU·RSS는 감소가, 처리량은 증가가 유리하다. 개선 ≥10%, 회귀 >5% 기준을 바꾸지 않았다.

## 공개 정책 비교군과 공통 정책 비교군

초기 실행 `42224583403`과 별도 RSS 실행 `42224583622`는 scanner 설정을 고정했지만 각 배포본의 Bash 정책을 유지했다. v3.8.1의 Bash 정책도 바뀐 사실과 준비 검사에서 파일을 읽는 사실을 확인하여, 이 숫자를 주 공통 정책 비교에 합치지 않았다. 이전 자료는 전부 별도 원시 ZIP으로 보존했다.

공통 정책은 최적화 효과를 같은 조건에서 비교하기 위한 실험 설정이다. 실제 배송 정책에서의 오탐·보안 차이는 별도 정확도 비교로 검증했다. 실사용에서 옛 정책을 고정하라는 권고가 아니다.

## 설치·정확도·메모리의 범위

설치 비교는 네트워크 없는 로컬 단계, 실제 archive 다운로드, scanner 첫 설치, 실제 네트워크를 포함한 신규 설치, 기존 Homebrew 사용자의 cached 설치/업그레이드를 구분한다. 다른 환경·방법의 설치 시간과 사용 지연으로 손익분기 요청 횟수를 계산하지 않았다.

정확도는 32개 독립 CLI 사례, 13개 scanner 정책 사례, 기존 1,013개 native 치환 차등 corpus, printenv/이미 마스킹된 토큰/큰 출력 cap, helper fault injection을 각각 유지한다. 검사 통과 수는 실사용 오탐률이 아니다. 기존 버전의 정당한 버그 수정과 실제 불일치를 구분하고, 탐지·마스킹 작업이 다른 표본은 같은 작업의 성능 이득으로 계산하지 않는다.

최대 개별 자식 RSS와 표본 RSS 합은 다른 지표다. RSS 합은 공유 페이지를 중복 계산할 수 있고 짧은 peak를 놓친다. 고유 물리 메모리 사용량으로 표현하지 않는다. RSS sampling·process trace·component 실험의 지연/CPU는 주 CLI 성능에 합치지 않는다.

## 실패와 미검증

초기 업로드 권한 오류, caller/parser 옵션 불일치, V1 oracle 오류, ptrace 도구 실패와 계측 timeout, 중단된 자료, 남아 있는 오탐과 helper의 거짓 성공 한계를 원문·이유와 함께 보존했다. 성공할 때까지 같은 제품 호출을 재시도하거나 timeout을 늘리지 않았다.

검증 플랫폼은 Linux x86_64다. 실제 Claude/Codex 앱 전체 지연, 새 lifecycle event dispatch, 사용자의 실제 plugin Git clone 옵션은 미검증이다. `unknown-event`라는 고정 case 이름의 실제 입력은 unknown tool이다. 관리 Chromium의 file:// 차단 정책은 바꾸지 않았고, 허용된 localhost에서 실제 HTML의 표·그래프·필터·다운로드와 외부 요청 0건을 검증한다.
