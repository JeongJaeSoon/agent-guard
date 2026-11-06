# 실측 하네스 독립 검토

검토 대상: `run.py`의 CLI 계측, 동일 조건, 처리량, RSS, 순서와 trace. 제품 코드 변경은 하지 않았다.

## 발견 사항과 부모의 수정 확인

1. 초기 동시 실행에서는 `timed.append`의 완료 순서와 `<request index>.stdout`의 요청 순서가 달랐다. 실패 상태와 출력의 연결이 바뀔 수 있어 요청 index의 고정 배열로 수정되었다.
2. 최초 요청별 `latency_s`는 Popen 다음에 시계를 시작했다. 부모가 Popen 앞으로 옮겨 CLI 프로세스 시작을 포함했다. 전체 worker wall에는 원래 CLI 생성이 포함되어 있었다.
3. 최초 worker wall에 raw stdout/stderr 파일 쓰기가 들어 있었다. 현재 버전은 출력 저장·해시 계산을 측정 뒤로 옮겼다. CLI stdout/stderr의 파이프 수집과 메모리 보관은 양쪽에 동일하게 포함된다.
4. 7개 버전의 14회 회전·역회전은 각 위치에 두 번씩 배치된다. 8개 arm의 load에 같은14회를 적용하면 불균형하므로 별도16회가 필요하다고 보고했고 부모가 수정하기로 했다.
5. 최초 단순 trace 문자열 수는 실패한 clone3 시도도 프로세스 생성으로 세었다. 별도 `trace_attribution.py`는 성공한 생성·실패 시도, 성공 exec·실패 PATH 탐색을 구분한다. 이 자료는 주 latency/CPU와 합치지 않는다.

## 적절한 포함 범위와 해석 한계

- fresh Python worker마다 RUSAGE_CHILDREN을 읽으므로 이전 표본 CPU와 최대 RSS가 누적되지 않는다. `cpu_s`는 CLI와 회수된 자손들의 CPU 합이며 Python driver CPU는 별도다. 주 wall은 ThreadPool 생성·스케줄링·Popen·CLI·파이프 수집을 포함하고 worker Python interpreter 시작은 제외한다. 작은 요청에서는 고정 driver 비용의 비중을 유의해야 한다.
- `max_child_rss_kib`는 Linux RUSAGE_CHILDREN의 가장 큰 개별 자식 peak RSS로, 동시 요청들의 RSS 합이 아니다. 표본 프로세스 RSS 합은 /proc을 읽는 phase=rss에서만 얻는다. driver를 제외하지만 공유 페이지를 중복 합산할 수 있고 짧은 peak를 놓칠 수 있다. /proc scan 뒤10ms 대기이므로 정확히 매10ms 순간을 측정한 것은 아니다.
- 4동시 처리량은 표본마다 요청4개를 한 wave로 실행한 4/wall이다. 장시간 지속 부하의 정상상태 처리량 측정이라고 표현하지 않는다.
- audit=off에서는 AG_AUDIT_START/AG_STATE_DIR가 비활성이라 scanner version 준비 cache를 매번 우회한다. 즉 주 off 측정은 scanner readiness가 포함된다. warm은2회 warmup 이후 같은 HOME/state를 사용하고 cold는 매호출 새 state를 만든다. cache TTL은600초이므로 긴 warm block에서는 실제 age를 확인해야 한다. cold는 audit/readiness 상태의 cold이며 OS page cache 전체를 비운다는 의미가 아니다.
- source-plugin과 standalone CLI의 libexec 선택이 다르므로 결과를 같은 경로로 합치면 안 된다. 공통 v3.6.13 scanner config는 버전별 새 allowlist 정책 차이를 배제하므로 자연 배포 config의 정확도 개선과 별도 해석한다.
- 실패 policy의 기존 validate는 status와 DEGRADED 경고를 확인하며 stdout 내용을 상세 검증하지 않았다. 그 사실을 부모에게 보고했다. 이 사례만으로 민감 입력 실패 복귀의 모든 보안 계약을 입증할 수 없다.
- timeout 표본은 종료를 위한 SIGKILL 때 회수되지 못한 자손 CPU를 놓칠 수 있다. timeout·불일치는 원시로 보존하고 동일 작업의 성능 개선에서 제외해야 한다.

`trace_attribution.py` parser는 합성 fixture로 성공/실패 exec, clone3 ENOSYS, unfinished/resumed clone, scanner version 분류를 검사해 통과했다. 이 검사는 제품 성능 표본이 아니며 trace의 관측 수명은 CPU 시간이나 인과 기여율이 아니다.
