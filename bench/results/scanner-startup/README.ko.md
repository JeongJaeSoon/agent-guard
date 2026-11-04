# scanner 시작 비용: 원시 근거

실험 구현·판정 범위는 [설명](../../scanner/README.ko.md)을 따른다.
기본 scanner·설치·업데이트·릴리스 선택은 바꾸지 않았다.

`local-20261104T1758Z.tar.gz`는 로컬 원시 파일 4,881개를 보존한다.
아카이브 외부 SHA-256과 내부 `SHA256SUMS`로 각각 검증할 수 있다. 과거 실패
출력도 포함하며 이전 실험 자료를 덮어쓰지 않는다. 실행 파일은 배포 자산이
아니므로 바이너리 해시·고정 소스·재빌드 방법으로 식별한다.

```sh
sha256sum -c local-20261104T1758Z.tar.gz.sha256
mkdir local-20261104T1758Z
tar -xzf local-20261104T1758Z.tar.gz -C local-20261104T1758Z
(cd local-20261104T1758Z && sha256sum -c SHA256SUMS)
```

- `local-summary.json`: 실제 공개 v3.7.0 CLI/core, 공식 scanner 대 RE2 1.13 후보.
  Claude 3입력 × 로그 off/cold/warm × 7쌍 교대 실행이다.
- `homebrew-summary.json`: 실제 공개 Homebrew bottle 대 후보. 두 호스트 3입력씩
  9쌍 교대 실행이다. 원본 bottle은 시스템 ELF loader wrapper로 실행했으며
  로그 off만 측정했다. Homebrew 설치·업데이트 완료의 근거가 아니다.
- `local-throughput.json`: 두 동시성 수준에서 8요청씩 3라운드. 최대 단일 자식
  RSS와 10 ms 표본 프로세스 RSS 합을 구분한다. RSS 합은 공유 페이지를 중복
  계산하고 짧은 peak를 놓칠 수 있다.
- `provenance.json`: 실제 바이너리·도구 해시, 소스·컴파일러·외부 cgroup 조건.
  로컬은 외부 4 CPU/16 GiB이며 개별 2 CPU/1 GiB 제한으로 표현하지 않는다.
- 아카이브의 `scanner-corpus-3`과 `homebrew-corpus`: 각각 230개 원시 입력,
  세 구현의 전체 finding·stdout·stderr·종료 상태와 독립 기대값 판정.
- `combined-prepare`: 빠른 scanner를 고정하고 기존 Rust 준비 후보를 더한
  조합 실험. 추가 효과는 목표 10%에 미달했다.
- `scanner-init`: 초기화 trace, 같은 컴파일러 대조군, 빌드·의존성 및 테스트
  실패와 수정 후 결과. 설치된 `/usr/bin/go`가 Go 컴파일러가 아니었던 초기
  시도, 차단된 모듈 다운로드, upstream 테스트 import 오류도 남긴다.
- `local-native-corpus.log`: 1,041 통과·2 실패. sandbox의 `/tmp/.git` marker로
  private allow-list fixture가 거부됐다. 검사나 기대값을 완화하지 않았다.
- `compiler-free-host*`: 초기 도구 PATH의 `cmp` 누락 실패와 수정 후 90 통과.

성능·탐지·설치 적합성은 별도 판정이다. 전체 사용자 scanner 일괄 교체는
Homebrew 경로의 회귀 때문에 기각한다. 제한 자원 CI와 네 플랫폼 결과는
각 실행 head와 job을 식별해 별도 보존한다.

`constrained-summary.json`과 `constrained-assessment.json`은 `c4e5c48`의
실제 제한 자원 결과다. 목표 6개와 전체 126개 경로를 포함한다. 이 head의
`scanner_version_execs`는 launcher argv까지 포함하는 과대 계수였으므로
off/cold의 값 2를 실제 scanner 실행 2회로 읽으면 안 된다. warm의 0과
지연·CPU·RSS·처리량 표본은 이 trace 계수 오류와 별개다.

`ci-5ff98ae.tar.gz`는 교체된 첫 head의 취소된 실행에서 확보한 원시 파일
50개다. 첫 collector가 mock을 전역 scanner override로 가린 결과 61개 실패가
남았고 실행이 취소됐다. `c4e5c48`은 scanner를 PATH에 추가해 기존 mock과 실제
scanner 테스트를 구분한다. 테스트 기대값은 바꾸지 않았다.

`ci-c4e5c48.tar.gz`는 성능 결과, 네 플랫폼의 빌드·테스트 자료와 Intel 실패를
포함한 원시 파일 4,742개다. 이 head에서 성능 job과 macOS 두 scanner contract
job은 성공했지만 Linux 두 contract job은 PATH에 남은 `go` 때문에 실패했다.
기존 native-platforms의 Intel 반복 검사도 별도로 실패했다. 전체 CI 성공이 아니다.
CI 출력 partition에는 zsh가 없어 로컬의 zsh wrapper 검사 네 개가 포함되지
않으며, 실제 scanner RSA 탐지와 두 allow-list 검사는 실행·통과했다.

CI 실행 파일은 원본 다운로드 ZIP에 그대로 보존하고, 위 아카이브에서는
`omitted-binaries.json`의 크기와 SHA-256으로 식별한다. 확보한 빌드 정보,
native helper의 라이선스, 측정·입력·출력·오류 자료는 아카이브에 포함한다.
후속 collector는 scanner 양쪽의 모듈 라이선스·notice도 함께 보존한다.

`ci-301d091.tar.gz`는 원시 파일 10,016개와 내부 manifest를 포함한다. 네 플랫폼의
230개 corpus·90개 호스트 결과, 전체 126개 제한 자원 비교, 원시 exec trace,
양쪽 scanner 모듈 라이선스·notice, 일반 CI의 깊은 JSON 실패 로그를 보존한다.
실행 파일 8개는 원본 ZIP에 보존하고 아카이브에서 크기·SHA-256으로 식별한다.
`constrained-301d091-summary.json`은 상태별 별도 runner의 쌍별 비교다.
이 head의 scanner 실험은 성공했지만 일반 CI는 실패했으며, 전체 CI 성공으로
표현하지 않는다. jq 호환성 결함과 후속 수정은 실험 설명의 별도 항목을 따른다.

`json-serialization-recovery.tar.gz`에는 최초 로컬 재현, jq 버전·stack 제한별
원시 stdout와 shell trace, 공개 v3.7.0의 회귀 검사 실패, 수정 후 세 jq 버전의
회귀 결과 및 jq 1.8.1 core partition 825 통과 로그가 있다. 공식 jq 바이너리의
해시도 기록하며, 실행 파일은 별도 원본으로 보존한다. 이 합성 입력의 trace를
실사용자 비밀값이 담긴 hook에 적용해서는 안 된다.

`synthetic-fixture-scan.tar.gz`는 `e2aa785`의 보안 CI 실패와 로컬 재현을 보존한다.
새 회귀 script의 합성 비밀번호 두 곳이 generic-api-key 규칙에 탐지됐다.
기존 suite처럼 문자열 조각을 실행 시 조립하도록 수정해 실제 입력과 기대값을
유지했고, 스캔 예외나 규칙 완화 없이 같은 설정의 전체 저장소 스캔을 통과했다.
