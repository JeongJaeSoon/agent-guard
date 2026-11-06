# 실제 공개 CLI `update` 호환성 smoke

7개 공개 배포본의 실제 standalone CLI를 한 번의 연속 chain으로 업데이트한다.
초기 .13 설치 후 .14/.15/.7.0/.7.1/.8.0/.8.1을 각각 다음 target으로 지정한다.
각 단계는 실제 public symlink의 `agent-guard update` 명령이며, 제품 소스를
패치하거나 CLI update를 직접 bootstrap 실행으로 대체하지 않는다.

환경변수 `AGENT_GUARD_VERSION=<target>`은 CLI가 내려받아 실행하는 bootstrap에
상속된다. 실제로 어느 archive/checksum URL과 bytes를 사용했는지 기록하며 고정
release-lock의 digest와 대조하고, 최종 `version` 명령도 target과 같은지 검사한다.
지원되지 않거나 상속되지 않으면 원래 실패 출력 및 불일치를 보존하고 chain을
중단한다. timeout120초·재시도0을 유지한다. 성공까지 재실행하거나 기대값을 바꾸지
않는다. 초기 bootstrap만 공개 .13 자산 digest로 독립 검증하여 직접 실행한다.
이 초기 준비는 actual CLI update 결과에 포함하지 않는다.

actual `update`는 latest bootstrap을 동적으로 받는다. private PATH의 curl wrapper는
원래 `/usr/bin/curl`에 인자를 그대로 전달하고 stdio·exit code를 보존한 뒤, 내려받은
bootstrap 및 checksum 원문을 보관하고 모든 다운로드 파일의 SHA-256/크기를 기록한다.
이 wrapper는 파일 복사·해시와 Python 프로세스를 추가한다. 따라서 **성능 결과는
전부 N/A**이며 각 단계 n1의 호환성 관찰만 보고한다. 속도·CPU 개선율을 계산하지
않는다. archive/checksum URL과 해시는 target의 공개 lock에 일치해야 한다.

기존 제한 환경 Dockerfile을 재사용하고 runner UID/GID로 실행한다. 실제 cgroup
2CPU/1GiB/swap0과 compiler 부재를 검사한다. scanner는 공식8.30.1 고정 bytes다.
사용자 HOME/설치는 container 안에서 격리한다. rc prefix와 사용자 추가 payload config,
외부 custom config, unrelated payload 파일, public symlink를 보존하는지 검사한다.
배포본 소유 canonical config 교체를 유실 회귀로 판단하지 않는다. 각 단계 전후 전체
file path/size/hash 및 native core/sidecar 해시를 보존한다. 실제 native core 호출을
검사하는 출력 성능·마스킹 실험은 이 compatibility smoke의 범위가 아니다.

독립 branch `bench/public-seven-cli-update-smoke-20261106`의
`bench/results/public-release-comparison/cli-update-smoke-ci/**`만 trigger한다.
기존 seven-update primary 도구·실측은 변경하지 않는다. 원시 자료는
`linux-cli-update-smoke/`의 summary, steps, errors, environment, scanner, curl-downloads,
downloaded bootstrap 원문, 단계별 stdout/stderr·before/after tree 및 final tree다.
