# 원시 증거 보존

`package_evidence.py`의 기본 동작은 계획 출력뿐이다. 모든 측정·다운로드·상태 기록이 종료되고 부모 작업이 최종 패킹을 지시한 뒤에만 `--execute`를 사용한다. 원본 파일을 이동·삭제·수정하지 않는다.

```sh
python3 analysis/package_evidence.py --base .
python3 analysis/package_evidence.py --base . --controlled-run 42232755942 --execute
```

벤치마크 결과 디렉터리에서 실행한다. 다른 경로에서는 `--base`에 그 절대 경로를 준다. 기본 결과는 `raw/`이며 이미 존재하면 덮어쓰지 않는다. 처리 도중 원본 크기·mtime·파일 집합이 바뀌거나, 최종 CI artifact가 빠졌거나, 공개 artifact metadata의 SHA256/크기와 실제 ZIP이 다르면 중단한다. 원본을 수정하지 않고 임시 staging 디렉터리를 정리한다.

- `local-installation.zip`: 설치의 모든 시도, 이전 하네스, 준비 실패, 진단·표본 로그와 원시 JSON/CSV.
- `local-correctness.zip`: V1/V2 입력·실패·수정 이유, 기존 corpus와 native gzip 원시 자료를 포함한 전체 정확도 자료.
- `components-local.zip`: 전체 세부 계측 입력·샘플·trace·요약. CLI 전체 성능과 섞지 않는다.
- `runtime-local.zip`: 로컬 pilot·attribution·policy-access의 ptrace 실패/timeout/부분 중단과 전체 trace, common-policy-proof 원문 및 runtime의 재현 py/sh/protocol/docs. 최종 CI 전체 성능과 섞지 않는다.
- `ci-attempts.zip`: 모든 CI 상태·취소·실패·metadata·원문 로그. exploded `extracted*`/`recovered*` 트리는 중복 제외한다.
- `ci-RUN-ARTIFACT.zip`: 최종 세 run의 원본 artifact ZIP을 byte-for-byte 복사한다. 기존4개 shipping-policy runtime·4개 correctness·4개 shipping-policy RSS·1개 compact installation과 새4개 controlled runtime(42232755942), 총17개를 모두 요구한다. index의 cohort가 shipping-policy와 common-policy를 구분하며 controlled4개만 새 공통정책 주 비교다.
- `cancelled-or-partial-ci-*`: 이전 취소·부분 자료의 원본 ZIP. primary와 명확히 분리한다.

모든 ZIP의 각 비디렉터리 member는 `manifests/*.members.csv`에 이름·일반파일/심볼릭링크 구분·원래 크기·SHA256을 기록한다. 심볼릭 링크는 따라가지 않으며 target 문자열 바이트를 보존·hash한다. 생성 후 ZIP을 다시 열어 member hash를 모두 검증한다. CI 원본 ZIP은 archive 자체의 공개 metadata SHA256/크기도 확인한다. `raw/index.json`과 CSV는 run ID, artifact ID, source URL, expiry, ZIP 및 member manifest hash를 연결한다. `raw/SHA256SUMS`는 자신을 제외한 최종 산출물 전체를 hash한다.

```sh
cd raw
sha256sum -c SHA256SUMS
```

893MB 설치 원본은 각 표본에 같은 공개 payload를 반복 복사한 자료다. 이를 compact export한 ZIP에는 모든 측정 행·로그·transfer·사용자 설정 sentinel과 8,712개 원본 파일의 path/hash/size 목록이 남아 있다. export는 재측정하지 않았다. `compact-installation-source-artifact.json`, `compact-installation-work-file-manifest.csv`, `compact-installation-provenance.json`에 원본 URL·hash·만료일과 제외 범위를 동봉한다. 만료 후 원본 GitHub artifact 접근을 보장하지 않는다.

로컬 ZIP member 경로는 벤치마크 base에 상대적이다. CI 원본 ZIP은 index의 `extraction_root` 아래에서 확인한다. 취소/부분 artifact를 primary 경로에 풀거나 최종 측정과 합치지 않는다. `__pycache__`와 Python bytecode만 비증거 임시 파일로 제외한다. 재현용 `.py`, curated summary, 프로토콜을 Git에서 계속 추적할 수 있는 ignore 제안은 `evidence-ignore-proposal.txt`에 남겼고 부모 승인 후 task base의 `.gitignore`만 적용했다. `evidence-ignore-validation.json`이 raw trace/poll 제외와 curated JSON/CSV/py/README/GZ/ZIP 추적 가능 여부를 검사한다.

CI metadata/로그에서 credential 형식·서명 다운로드 URL을 사전 검사한다. 발견 시 값은 출력하지 않고 경로와 검사 종류만 알린 뒤 중단한다. corpus의 공개 synthetic token을 활성 인증정보로 오인하지 않도록 exploded fixture 입력은 이 검사에서 제외하고 원본 ZIP으로 보존한다. 이 검사는 인증정보가 절대로 없다는 보증이 아니다.

## 오프라인 안전 복원

```sh
python3 analysis/restore_evidence.py --raw raw --base /tmp/agent-guard-evidence-restored
python3 analysis/restore_evidence.py --raw raw --base /tmp/agent-guard-evidence-restored --execute
python3 analysis/check_evidence_tools.py
```

복원 기본 동작은 전체 hash 검증과 계획뿐이다. `--execute`는 raw/index·SHA256SUMS·member manifest·보존한 CI artifact metadata의 SHA/ID/크기를 먼저 재검증한다. 로컬 member는 benchmark base의 원래 상대 경로로, CI ZIP은 `evidence/ci/<run>/extracted/<artifact-name>/`으로 복원한다. 취소 자료는 `extracted-cancelled`로 분리한다. 모든 재현 스크립트가 필요로 하는 offline raw 자료를 준비하며 공개 release payload/source fixture 자체는 고정된 공개 manifest와 별개다.

다른 내용의 기존 파일·symlink·디렉터리는 덮어쓰지 않고 사전 단계에서 실패한다. 동일한 기존 bytes는 inode·mtime·권한을 바꾸지 않고 재사용한다. 절대 경로·`..`·Windows drive/backslash 형태·symlink 부모 경유 및 충돌하는 member 경로를 거부한다. 신규 일반 파일을 먼저 stage한 뒤 `dirfd`/`O_NOFOLLOW`/exclusive hard link로 게시하고 symlink는 마지막에 복원하므로 기존 자료를 덮어쓰거나 링크를 따라 외부에 쓰지 않는다. 경계 테스트의 외부/깨진 symlink는 링크 객체만 보존하며 대상은 읽거나 수정하지 않는다. 마지막에 복원본과 raw 원문의 SHA를 다시 검증한다.

이 도구는 Linux에서 독립 fixture로 검증했다. 모든 플랫폼·파일시스템으로 일반화하지 않는다. 검사 결과는 `evidence-restore-tool-validation.json`에 있다. 동일 파일 재사용, 다른 기존 파일 보존, 기존 symlink 부모 거부, hash가 자체 일치하는 악성 ZipSlip도 거부, CI metadata ID 불일치 거부를 확인했다. 실제 raw 증거의 최종 패킹과 복원은 부모의 최종 신호 전에는 수행하지 않았다.
