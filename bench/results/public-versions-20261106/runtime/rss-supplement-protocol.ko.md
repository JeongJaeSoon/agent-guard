# 버전별 표본 RSS 합 보충 실험

주 실험의 고정 프로토콜은 끝점(v3.6.13 기본, v3.8.1 기본·fused)에만 표본 RSS 합을 포함했다. 중간 버전의 RSS 합 요구사항을 채우기 위해 **결과를 보기 전** 별도 보충 실험을 정한다. 이미 시작한 주 실험을 취소하거나 교체하지 않는다.

- 입력·설정·공개 배포본·scanner 바이트·RSS 계측법·2 CPU quota·1 GiB·swap 0 검증 방식은 주 실험의 같은 scanner/host 조건과 같다.
- 모든 일곱 공개 버전의 기본 경로와 v3.8.1 공개 fused 경로, 총 8개 arm을 측정한다. v3.8.0 fused의 RSS 합은 이 보충 실험에 포함하지 않으며 N/A로 표시한다. 공개 helper가 없는 기능도 N/A다.
- 워밍업 후 각 조건 16회를 사전에 고정한 8개 순환 순서와 그 역순으로 반복한다. 실제 순서는 각 실행의 `protocol.json` 및 모든 원시 row에 남긴다.
- RSS 표본 계측은 전체 지연·CPU 주 비교와 분리한다. 표본 RSS 합은 공유 페이지를 중복 계산할 수 있고 짧은 peak를 놓칠 수 있어 고유 물리 메모리로 표현하지 않는다.
- 각 scanner×host는 새 GitHub runner에서 실행한다. 같은 자원 quota라도 CPU 모델·runner·시점이 달라질 수 있으므로 `linux-ci-rss-…` 환경으로 구분한다. 주 실험의 끝점 RSS와 섞어서 하나의 버전 곡선을 만들지 않는다.
- 원시 실패·불일치도 보존한다. 실패를 성공할 때까지 재실행하거나 기존 자료를 덮어쓰지 않는다.

실행은 `Public version RSS supplement` 워크플로 또는 `runtime/ci.sh LAB EVIDENCE IMAGE SCANNER HOST rss`이며, `run.py --series rss --rss-all-versions --require-limits`를 사용한다. 이 문서는 추가 실험의 이유와 범위를 기록하며 결과값을 예측하지 않는다.
