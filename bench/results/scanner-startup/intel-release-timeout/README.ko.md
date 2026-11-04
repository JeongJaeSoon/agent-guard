# 릴리스 후보 Intel 제한시간 초과 조사

- head: `1bbd6cfe2604c05b4d22d187b6c391a47fd09972`, PR #398.
- run: https://github.com/JeongJaeSoon/agent-guard/actions/runs/41894129150
- job: `126798961523`, macOS Intel, 2026-11-04 19:25:08–19:50:08 UTC.
- annotation: `The job has exceeded the maximum execution time of 20m0s`.
  종료까지 25분은 20분 제한과 취소 유예를 포함한다.
- build는 19:26:33에 완료했다. 단일 `Compiler-free differential and host
  contracts` 단계에서 종료되어 differential, 호스트 3회, audit 중 어디서
  정체했는지 현재 metadata만으로는 알 수 없다.
- 완료 후 job log 요청은 19:52 및 19:58 UTC에도 `404 BlobNotFound`였다.
  Intel artifact는 업로드되지 않았다. 최초 stdout/stderr를 확보한 것으로
  표현하지 않는다. 다른 세 플랫폼 실행과 일반 CI는 성공했다.

이전 `fd19553` 성공은 이 head의 필수 CI를 대체하지 않는다. 이전의 clean
fixture 출력 불일치와 이번 시간 초과가 동일 원인이라는 증거도 없다.
누적 지연, scanner 준비 지연, audit의 동시 hook 또는 FIFO 처리 정체를
아직 구분할 수 없다. 배포는 보류한다.

후속 변경은 원인 수정이 아니라 관측 보강이다. 같은 runner와 순서, 모든
fixture, Intel 3회 검사를 유지하고 단계별 완료 자료를 별도 checkpoint로
업로드한다. routine stderr에는 host/fixture/variant 번호, 시간, 종료 상태만
남긴다. audit 출력을 진행 중에도 노출하며 pipefail로 실패를 유지한다.
20분 job 제한, scanner 준비 제한, 출력 기대값은 바꾸지 않는다.
`checkpoint-*`는 설치 검증에서 받는 `native-*`와 구별하고, 전체 성공 전에는
릴리스 적합성을 주장하지 않는다. 보강 후 성공하더라도 원인은 미확정이다.

로컬 Linux에서 보강된 driver와 공개 v3.7.0 core, 공식 scanner로 90개 검사를
통과했다. stderr 진행 기록과 JSON 결과를 보존한다. Rust fmt·clippy와
pinned actionlint 1.7.7도 통과했다. 최초 로컬 명령은 존재하지 않는 core 경로로
종료했고, 경로를 실제 공개 자산으로 수정한 결과이며 제품 실패가 아니다.
