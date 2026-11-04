# 3099293 검증 원시 자료

릴리스 후보 head `3099293be604a68e25fe706ac940c2743e98469f`의
[scanner 실험](https://github.com/JeongJaeSoon/agent-guard/actions/runs/41902550673)과
[네 플랫폼 실행](https://github.com/JeongJaeSoon/agent-guard/actions/runs/41902550881)에서
확보한 원시 파일 10,042개다. 실행 파일 12개는 원본 ZIP에 보존하고 archive의
`omitted-binaries.json`으로 크기·SHA-256을 식별한다. 내부 manifest의 파일별
해시와 archive sidecar checksum을 함께 보존한다.

목표 6개 지연 −48.20~−66.76%, CPU −47.88~−66.54%, 전체 126개 비교의
독립 출력 검증 성공, 일반 경로 5% 초과 회귀 0이었다. 네 플랫폼마다 scanner
corpus 230개·호스트 90개 실패 0이었다. 기본 경로에는 후보를 채택하지 않는다.

native differential은 플랫폼마다 1,024개, 호스트 검사는 90개다. Intel은
기존과 같은 세 번의 호스트 검사(각 90개) 및 audit를 완료했다. 새 단계별
기록에서 differential 31초, 통합 158/130/112초, audit 53초였고 전체 job은
10분 46초에 성공했다. 개별 hook 60회씩의 중앙값은 2.547/2.050/1.786초,
최대는 4.682/3.160/2.123초였다. 이는 hook 전체 시간이며 scanner readiness
시간 자체가 아니다. 각 시행이 빨라진 이유나 이전 20분 제한 초과 원인을
확정하지 않는다. 최초 실패의 stdout/stderr는 여전히 확보하지 못했다.

앞선 `1bbd6cf`의 시간 초과 metadata를 삭제하거나 이번 성공으로 대체하지
않는다. 제한시간·기대값·검사 횟수는 그대로다. 이 archive는 후속 관측 자료이며,
필수 CI 전체 성공·병합·실제 발행이 완료됐다는 기록은 아니다.
