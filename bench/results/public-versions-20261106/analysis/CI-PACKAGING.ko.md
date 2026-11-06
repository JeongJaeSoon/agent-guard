# 보고서 제출 후 저장소 CI의 양성 fixture 탐지

첫 보고서 commit `3866c16ef5ebcb34ac4f6c37e3d72560bb5a2bb0`의 저장소 CI `42251460656`에서 Agent Guard가 exit 1을 반환했고, 이에 의존하는 test shard는 실행되지 않았다. 동일한 공개 scanner·저장소 정책으로 깨끗한 Git archive를 별도 검사하여 다섯 파일의 가짜 양성 token에서 10개 finding을 재현했다. 실제 자격증명은 아니며 측정용 양성 fixture와 공개 Homebrew formula의 테스트 문자열이다.

탐지 정책이나 기대값을 완화하지 않았다. 다음 원문을 인접한 `.gz`에 바이트 그대로 보존하고 일반 텍스트 중복 사본만 Git 추적에서 제외했다. 원래 보고서 commit과 기존 raw ZIP도 그대로 남는다.

- `correctness/masked-token-protocol.json.gz`
- `correctness/workloads.json.gz`
- `correctness/workloads.v1.json.gz`
- `installation/homebrew-gitleaks.rb.gz`
- `installation/homebrew-gitleaks-actual-tap.rb.gz`

독립 검토나 수동 설치 재현에 원문이 필요하면 `gzip -dk <file.gz>`로 복원한다. [raw 복원](EVIDENCE-PACKAGING.ko.md)도 원래 경로에 같은 바이트를 복원한다. 새 CI 실험은 `make_workloads.py`로 입력을 먼저 생성한다. 압축 해제 후 저장소 전체 보안 검사를 직접 실행하면 이 의도적인 양성 fixture를 다시 탐지할 수 있다.

[원문·압축 SHA와 실패 자료](pr-ci-packaging.json)를 보존했다. 최종 HTML/Markdown/JSON/CSV와 모든 실측·오탐·누락 판정은 변경하지 않았다. 이 조정은 원문 증거의 배포 방식이며 제품 코드·정책 예외 추가가 아니다.
