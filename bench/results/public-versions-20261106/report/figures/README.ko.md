# 독립 그래프 산출물

각 SVG는 외부 폰트/CDN 없이 열리도록 글꼴을 path로 포함한다. 선은 중앙값, 수염은 P25–P75(IQR)이다. 지연·CPU·메모리·설치 비용은 감소가 유리하고 처리량은 증가가 유리하다. G/R 텍스트와 선/점 모양을 사용하므로 색만으로 판정을 구분하지 않는다. G는 기준 v3.6.13 대비10% 이상 개선, R은5% 초과 회귀다. N/A를0으로 채우지 않는다.

같은2CPU·1GiB라도 cohort별 CPU 모델이 다르므로 서로 다른 그림의 절대 ms 차이를 scanner/host 단독 원인으로 설명하지 않는다. 메모리는 별도 RSS phase만 사용하며 표본 RSS 합은 고유 물리 메모리가 아니다. 기본 지연·CPU 그림에는 optional 경로를 섞지 않았고, RSS에서만 동일 block의 최종 fused를 별도 endpoint로 표시했다.

[선택 집계 JSON 및 원시 표본 id](figure-data.json) · [선택 집계 CSV](figure-data.csv) · [독립 재계산·도구 검증](figure-validation.json) · [파일 해시](figure-hashes.json)

재현: `python analysis/plot_figures.py --data report/data.json --out <new figures directory>`

- [homebrew-claude-latency-cpu](homebrew-claude-latency-cpu.svg): 기본 7버전 CLI 지연·CPU
- [homebrew-claude-throughput](homebrew-claude-throughput.svg): 기본 7버전 단일·4동시 처리량
- [homebrew-claude-memory](homebrew-claude-memory.svg): 별도 RSS 계측과 선택형 최종 경로
- [homebrew-codex-latency-cpu](homebrew-codex-latency-cpu.svg): 기본 7버전 CLI 지연·CPU
- [homebrew-codex-throughput](homebrew-codex-throughput.svg): 기본 7버전 단일·4동시 처리량
- [homebrew-codex-memory](homebrew-codex-memory.svg): 별도 RSS 계측과 선택형 최종 경로
- [official-claude-latency-cpu](official-claude-latency-cpu.svg): 기본 7버전 CLI 지연·CPU
- [official-claude-throughput](official-claude-throughput.svg): 기본 7버전 단일·4동시 처리량
- [official-claude-memory](official-claude-memory.svg): 별도 RSS 계측과 선택형 최종 경로
- [official-codex-latency-cpu](official-codex-latency-cpu.svg): 기본 7버전 CLI 지연·CPU
- [official-codex-throughput](official-codex-throughput.svg): 기본 7버전 단일·4동시 처리량
- [official-codex-memory](official-codex-memory.svg): 별도 RSS 계측과 선택형 최종 경로
- [installation-ci-cached-fresh](installation-ci-cached-fresh.svg): CI cached 새 설치: 시간·CPU·설치/운송 크기
