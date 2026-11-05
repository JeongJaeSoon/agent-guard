# 고정 A/A 대조와 CPU 배치 진단

f49740f의 일반 경로에서 CPU 감소와 wall 지연 증가가 동시에 관측됐다. 이를 실제 구현 회귀와 측정 환경 변동으로 구분하기 위한 독립 진단이며 기존 실패를 합격으로 바꾸지 않는다.

- A/A: 실제 공개 v3.7.0의 정확히 같은 실행 파일·설치 core·scanner·설정. 두 label 모두 packaged checksum dispatch이며 fused는 꺼져 있다.
- A/B: 같은 공개 redactor를 양쪽에 유지한 기존 기여도 분리 구성. 후보 CLI는 f49740f와 동일하며 prepare helper만 현재 소스의 GNU 빌드다.
- 두 조건: 기존 2CPU quota/1GiB/swap0, 그리고 같은 제한에 CPU 두 개의 affinity만 추가한 조건. cpu.max·memory.max·swap.max·cpuset/프로세스 affinity를 보존한다.
- 각 조건의 A/A와 A/B를 사전에 정한 순서로 3회 실행한다. 매회 두 호스트·5개 fixture·9쌍 교대다. 총 120개 비교/2160회 CLI를 수집한다. 실패 여부에 따라 횟수를 늘리거나 성공할 때까지 재실행하지 않는다.
- fixture: exec 8MiB 상한, 긴 quoted secret, pre-read-clean, small-clean, many-replacement-leaves. 기존 독립 출력 기대값과 실제 scanner 바이트를 유지한다.
- 각 CLI 전후의 cgroup CPU period/throttling 카운터를 추가 기록한다. snapshot 읽기는 CLI wall 측정 밖이며 카운터에는 driver의 주변 작업도 포함된다. CLI CPU 시간과 합치지 않는다.

각 9쌍 결과와 3회 전체의 변동을 모두 보고한다. A/A의 5% 초과 차이도 원시로 남긴다. 이 진단의 수집 성공은 후보 채택이나 기존 기준 완화를 의미하지 않는다. 데이터가 측정 방법의 문제를 지지하지 않으면 회귀 원인을 구현에서 계속 찾아야 한다.
