# 실제 프로세스 호출: 주 성능표와 분리한 보조 증거

최종 공통 정책 CI의 네 환경에서 각각 9개 `phase=trace` 표본을 분류했다. 원문은 `raw/ci-42232755942-public-version-controlled-linux-*.zip`, 분류 전체는 [traces/](traces/)에 있다. 각 조건 n=1인 추적 자료이므로 시간 개선율이나 CPU 기여율을 추정하지 않는다.

다수 문자열 입력의 성공한 자식 프로세스 생성 수는 다음과 같다. 성공한 `clone/fork/vfork` 중 스레드를 제외했고 실패한 syscall 시도는 제외했다. 프로세스 생성 수는 성공한 exec 횟수와 다르다.

| host protocol | v3.6.13 기본 | v3.8.1 기본 | v3.8.1 fused |
|---|---:|---:|---:|
| Claude | 126 | 130 | 107 |
| Codex | 129 | 133 | 110 |

이 수는 official·Homebrew scanner 두 비교군에서 각각 같았다. 기본 endpoint가 빨라진 이유를 단순히 전체 프로세스 수 감소로 설명할 수 없다. fused에서는 같은 버전 기본보다 23개 적은 프로세스 생성을 관측했지만, 모든 입력이나 프로세스 하나당 비용으로 일반화하지 않는다.

네 환경의 이 입력 모두 scanner 준비 `gitleaks version` 1회와 실제 `gitleaks stdin` 1회를 실행했다. v3.6.13 기본에는 native 호출이 없고, v3.8.1 기본에는 `redact-v1` 1회, fused에는 `prepare-v1`과 `redact-v1`이 각각 1회 있었다. 따라서 공개 native 선택과 선택형 통합의 실제 실행을 확인했다.

셸 subprocess와 JSON 파싱·framing·치환은 일부 겹친다. jq/awk 명령은 trace 문자열 상한 때문에 필터가 잘릴 수 있어 세부 JSON 작업별 시간으로 정밀 분할하지 않았다. `exec_to_exit_wall_sum_s`에는 자식 대기·스케줄링·ptrace 비용이 포함되며 CPU 시간이 아니다. 별도 [component 실험](../runtime/components-local/README.ko.md)의 작은 작업 계측은 실제 4 CPU·16 GiB 환경이고, 2 CPU·1 GiB 전체 CLI와 합산하지 않는다.
