# Rust 사전 빌드 배포 검증 기록

내부 검증 기록. v3.6.14의 과거 측정은 `bench/results/rust-experiment/`에
그대로 남겨 두고 이번 결과와 합산하지 않는다. v3.7.0은 실제 발행됐으며,
공개 standalone 네 플랫폼과 Homebrew 세 환경 검증을 통과했다.

이후의 실제 출력 준비 Rust 구현·공개 v3.7 비교와 macOS Intel 재관측은
[후속 실험 기록](rust-output-experiment.ko.md)에서 별도 추적한다. 아래의
v3.7 발행 증거를 후속 후보의 채택·장애 해결 근거로 재사용하지 않는다.

## 실제 릴리스 커밋의 검증과 측정

릴리스 커밋 `e709445fb6fce9ade8cbbd2d6bcf2940e48da178`과 PR #392 최종 head는
각각 필수 8개를 포함한 Actions 30개를 통과했다. [발행 실행](https://github.com/JeongJaeSoon/agent-guard/actions/runs/41832898078)은
2026-11-04 12:51:49 UTC에 [v3.7.0](https://github.com/JeongJaeSoon/agent-guard/releases/tag/v3.7.0)을
공개했다. 네 바이너리·sidecar, universal archive·체크섬, installer·formula,
출처 정보·라이선스 고지를 포함한 자산 15개를 실제 다운로드하여 SHA-256을
확인했다. 공개 네 바이너리는 릴리스 커밋 CI artifact와 바이트 단위로 같다.
`v3.7.0`과 `v3`는 위 커밋이며 기존 `v1`은 `a795c72`로 유지했다.

[릴리스 커밋 원본](../bench/results/rust-packaged/release-e709445/)은 AMD EPYC 9V74의
Linux x64에서 측정했다. 같은 입력·gitleaks 8.30.1·jq 1.7.1·설정과 실제
2 CPU·1 GiB·swap 없음 제한으로 CLI 시작·플랫폼 선택·체크섬 비용까지 포함한다.
이 실행의 교대 비교만 아래 표에 쓰며 다른 CPU 모델의 이전 표본과 합산하지 않는다.

| 지표 | 셸 | Rust | 변화 |
| --- | ---: | ---: | ---: |
| Claude 목표 CLI 지연 | 1,041.455 ms | 759.676 ms | −27.06% |
| 같은 경로 CPU | 1.059335초 | 0.794316초 | −25.02% |
| Codex 목표 CLI 지연 | 1,015.998 ms | 762.465 ms | −24.95% |
| 같은 경로 CPU | 1.049440초 | 0.782054초 | −25.48% |
| 동시 4개 처리량 | 1.203 요청/초 | 1.649 요청/초 | +37.06% |
| 동시 4개 CPU/요청 | 1.645305초 | 1.196279초 | 감소 |
| 동시 4개 표본 프로세스 RSS 합 | 300.465 MiB | 297.539 MiB | 해당 실행의 표본 |
| 동시 4개 최대 자식 RSS | 64.598 MiB | 63.660 MiB | 해당 실행의 자식 peak |

일반 경로의 지연·CPU 5% 초과 회귀는 없다. 앞서 실패한 `escaped-control`은
지연 +1.07%·CPU −0.35%로 기준 안에 있고, 정상 입력 후속 지연은 −1.93%다.
Claude/Codex 목표의 최대 자식 RSS 중앙값은 각각 63,916→63,348 KiB,
64,056→63,476 KiB다. 10 ms 표본 RSS 합은 공유 페이지 중복과 짧은 peak 누락이
가능하고 최대 자식 RSS와도 다르다. 메모리 절감이나 다른 세 플랫폼의 성능
개선을 일반화하지 않는다. 개별 부하 JSON은 실제 CPU·메모리 한도를 기록하며,
swap 없음은 동일 Docker run 함수의 실행 전 cgroup 검사로 확인했다.

네 플랫폼 모두 독립 기대값을 포함한 차등 1,024/0, 실제 scanner 호스트 90/0,
감사 116/0과 컴파일러 없는 후보 설치·업데이트를 통과했다. 공개 배포 후에는
다운로드를 대체하지 않고 네 플랫폼의 신규 설치·3.6.15→3.7.0 업데이트,
실제 scanner smoke, 정상 4건·실패 복귀 40건 및 기본값/명시적 선택을 확인했다.
공개 검증과 Homebrew 테스트 환경 수정의 기록은
[공개 원본](../bench/results/release-validation/v3.7.0-public/)에 따로 남긴다.

[공개 검증 실행](https://github.com/JeongJaeSoon/agent-guard/actions/runs/41834816697)은
verifier `d3474af`에서 7개 모두 성공했다. Linux x64/macOS x64/arm64의 공개
Homebrew 3.6.15 설치→3.7.0 업그레이드, `brew test`, 체크섬과 standalone update
거부를 확인한 뒤 정식 tap 신규 설치·`brew test`도 통과했다.
[tap #24](https://github.com/JeongJaeSoon/homebrew-tap/pull/24)는 formula CI 성공 후
`64d16f9`로 병합했으며 공개 formula와 바이트 단위로 일치한다. Linux x64에서는
버전 미지정 최신 설치와 공개 3.6.14→3.7.0 업데이트도 추가 확인했다.
[구조화된 발행 기록](../bench/results/release-validation/v3.7.0.json)에 자산 해시,
태그·PR·CI와 검증 범위를 보존한다.

초기 Homebrew 검사는 Linux의 임시 tap 커밋 작성자와 macOS의 이전 keg 정리에서
실패했다. 환경변수 작성자는 Homebrew가 초기화하므로 `tap-new --no-git` 후
해당 임시 저장소의 초기 커밋만 Git `-c user.name/user.email`로 생성했다.
업그레이드로 남은 두 테스트 버전을 정리한 뒤 정식 tap 설치를 다시 검사했다.
`initial`, `intermediate-dfe72d4`, `intermediate-285a353`, `final`을 분리해
실패를 성공으로 덮지 않았다. 공개 자산·태그·formula는 교체하지 않았다.

후속 검증 도구 [PR #393](https://github.com/JeongJaeSoon/agent-guard/pull/393)의
별도 [macOS Intel native CI](https://github.com/JeongJaeSoon/agent-guard/actions/runs/41834759669/job/126591007436)에서
호스트 복귀 출력 불일치가 한 번 발생했다. 당시 오류에 fixture 번호·양쪽 출력·
stderr가 없고 임시 데이터가 제거되어 원인을 단정할 수 없다. 고정 합성 fixture의
실패 진단과 artifact 보존을 추가하고 같은 timeout·기대값으로 macOS Intel
계약을 3회 실행하도록 했다. `bbd6a31`의 [후속 원본](../bench/results/release-validation/v3.7.0-public/post-release-diagnostics/)에서
같은 macOS Intel 계약 90건을 세 번 모두 통과했으나, 최초 원인 수정 완료를
뜻하지 않는다. 이 후속 CI는 위 릴리스 커밋·공개 배포 검증과 구분한다.
공개 검증을 통과한 `d3474af` 이후 공개 verifier와 제품 런타임은 바뀌지 않았다.

## 체크섬 비용 수정 후 후보 검증

[PR #392](https://github.com/JeongJaeSoon/agent-guard/pull/392)의 head `4a3f4e7`에서
필수 8개 포함 Actions 30개가 성공했다. [새 원본](../bench/results/rust-packaged/qualification-4a3f4e7/)은
첫 릴리스 병합의 실패와 분리했다. AMD EPYC 7763에서 같은 2 CPU·1 GiB·swap 없음
조건으로 비교했으며 앞선 EPYC 9V45의 절대 시간과 직접 비교하지 않는다.
공개 3.6.15 CLI와 비교 기준 `9a0ee9e`의 차이는 VERSION 문자열뿐이다.

Claude 목표 지연 −27.25%·CPU −25.99%, Codex −26.92%·−25.49%다.
실패했던 `escaped-control`은 지연 −0.26%·CPU −0.51%이며 일반 경로 지연·CPU
5% 초과 회귀는 없다. 동시 4개 처리량은 0.880 → 1.218 요청/초,
CPU/요청은 2.256 → 1.620초, 표본 RSS 합은 301.453 → 302.160 MiB다.
메모리 절감은 주장하지 않는다. swap 없음은 동일 Docker run 함수의 사전 실제
cgroup 검사로 확인했으며 개별 부하 JSON에는 CPU·메모리 한도만 기록한다.

네 플랫폼 모두 차등 1,024/0, 실제 scanner 호스트 90/0, 감사 116/0과
컴파일러 없는 설치·업데이트·호스트 복귀 44건을 통과했다. 같은 head의 jq 1.6·zsh·
Rust 미설치 Docker에서 packaged 44건과 전체 2,714건/실패 0도 확인했다.
병합 커밋 `e709445`와 공개 배포 검증은 별도로 진행한다.

## 첫 릴리스 PR의 최종 후보 검증

[PR #391](https://github.com/JeongJaeSoon/agent-guard/pull/391)의 최종 head
`d58cf2af97a7f75e7dee6f0ead42f43549b34f7c`에서 필수 8개를 포함한 Actions 30개가
성공했다. CI checkout `a337c4cbe19edbcd9173a064563c6ff699c9cd03`의 tree는
head와 동일한 `c11f6e5c43810e1ad70739ebf78d795afe1a4cd0`임을 확인했다.
[최종 후보 원본](../bench/results/rust-packaged/qualification-d58cf2a/)은 두 예비
측정과 분리했다. 이번에는 CPU 모델도 `cpuinfo.txt`에 보존했다.

네 플랫폼 각각 차등 1,024건/불일치 0, 실제 gitleaks 호스트 계약 90건/실패 0,
감사 로그 116건/실패 0이다. 컴파일러가 PATH에 없는 신규 설치, 실제 공개
3.6.14에서 후보로 업데이트, 기존 설치 보존, 기본값·명시적 Rust 호스트 복귀
44건 및 명시적 셸·빈 설정 선택도 모두 통과했다. 네 플랫폼의 INT/TERM·추출·
커밋·공개 링크 실패 복구 로그를 함께 보존한다.

같은 입력·스캐너·설정과 실제 2 CPU·1 GiB·swap 없음 제한에서 측정했다.
최초 9쌍과 사전 예정한 정상 입력 21쌍 후속 결과를 모두 남긴다.

| 지표 | 셸 대비 Rust 변화 |
| --- | ---: |
| Claude 목표 CLI 지연 / CPU | −22.69% / −22.45% |
| Codex 목표 CLI 지연 / CPU | −23.83% / −23.08% |
| Claude 정상 입력 후속 지연 / CPU | +0.26% / +0.04% |
| 일반 경로 지연 5% 초과 회귀 | 없음 |
| 동시 4개 처리량 | 1.597 → 2.077 요청/초 |
| 동시 4개 CPU/요청 | 1.240 → 0.949초 |
| 동시 4개 표본 프로세스 RSS 합 | 295.348 → 295.703 MiB |

단일 자식 최대 RSS 중앙값 변화는 Claude −0.20%, Codex −1.00%다. 10 ms
표본 프로세스 RSS 합은 최대 자식 RSS와 다르며 공유 페이지 중복과 짧은 peak
누락이 가능하다. 메모리 절감이나 다른 세 플랫폼의 성능 개선을 주장하지 않는다.

Rust 미설치 Docker의 jq 1.6·zsh 전체 검사는 `ff956aa`에서 2,714건/실패 0이다.
최종 head와 런타임 소스가 같고 사용한 Rust 바이너리는 최종 CI 바이너리와
바이트 단위로 일치한다. 기존 `native-suite.sh`를 사용해 Rust와 jq에 함께 실패를
주입했으며, 실제 기본 packaged 선택은 위 네 플랫폼 44건으로 별도 검증했다.
소스·이미지·바이너리·전체 로그 해시는 `local-full-suite.json`에 보존한다.

## 릴리스 커밋의 성능 회귀와 수정

첫 릴리스 병합 `3d704f4`의 [측정](https://github.com/JeongJaeSoon/agent-guard/actions/runs/41825144870)은
`escaped-control` 지연 +5.27%, CPU +5.07%로 채택 기준을 통과하지 못했다.
목표 경로의 개선과 네 플랫폼 정확도·설치 성공을 근거로 이 실패를 무시하지 않고
발행을 보류했다. 원본 artifact `13318699367`의 SHA-256은
`1608473af93ee9f4b982f35ac0955ece6af811df33b8da748f5fbb571f711d07`이다.

패키지 선택 때 매번 실행하는 Perl 기반 `shasum`의 시작 비용을 줄이기 위해,
이미 설치된 `sha256sum`이 있으면 같은 SHA-256/파일명 레코드를 비교하도록 했다.
없으면 기존 `shasum`을 사용하며 체크섬 검사·손상 시 셸 복귀는 그대로 유지한다.
로컬 원인 분석에서 같은 바이너리 100회 해시는 `shasum` 1.166초,
`sha256sum` 0.172초였지만 이 제한 없는 측정은 CLI 채택 근거로 쓰지 않는다.
수정된 최종 head와 병합 SHA에서 기존 자원 제한·입력·10%/5% 기준을 다시
통과해야만 발행한다. 최초 실패 결과는 새 결과와 분리해 보존한다.

## 기본값 전환 전 측정

[PR #389](https://github.com/JeongJaeSoon/agent-guard/pull/389)의 head
`30d7df8526215bab8249fcf5a9b59698abb5253a`와 main을 합친 CI checkout
`7e9414b58fea0575c4bdd4ea8a7404339dbf2ed7`을 측정했다.
비교 기준 `9a0ee9eb2eed1e60b78d4404f985b077149c675d`와 후보 모두
snapshot token 호환성 수정 #387을 포함한다.

GitHub Ubuntu 24.04 x64의 Docker에서 `cpu.max=200000 100000`,
`memory.max=1073741824`, `memory.swap.max=0`을 실제로 읽고 확인했다.
같은 이미지·gitleaks 8.30.1·jq 1.7.1·입력·설정 아래 실행 순서를 교대한다.
정상 CLI 시작, 플랫폼 선택과 배포 바이너리 체크섬 검증 비용을 포함한다.
Claude 21종과 Codex 3종을 각각 9쌍, 사전에 예정한 Claude 정상 입력 후속
측정을 21쌍 수행했다. 모든 출력은 독립 기대값으로 검증했다.

| 지표 | 셸 대비 Rust 변화 |
| --- | ---: |
| Claude 다수 문자열 치환 CLI 지연 | −22.20% |
| Claude 같은 경로 CPU | −20.68% |
| Codex 같은 경로 CLI 지연 | −21.96% |
| Codex 같은 경로 CPU | −21.06% |
| Claude 정상 입력 후속 지연 | +0.74% |
| 일반 경로 지연 5% 초과 회귀 | 없음 |
| 동시 4개 처리량 | 1.562 → 2.059 요청/초 (+31.84%) |
| 동시 4개 CPU/요청 | 1.270 → 0.962초 |
| 동시 4개 표본 프로세스 RSS 합 | 300.094 → 298.457 MiB |

다수 치환의 단일 자식 최대 RSS 중앙값은 Claude +0.92%, Codex +0.71%다.
표본 RSS 합은 10 ms 간격이며 공유 페이지를 중복 집계하거나 짧은 peak를
놓칠 수 있다. 이를 전체 메모리 peak나 메모리 절감 입증으로 표현하지 않는다.
다른 세 플랫폼의 성능 개선 수치는 측정하지 않았다.

[원시 자료](../bench/results/rust-packaged/qualification-30d7df8/)에는 각 표본,
CPU·RSS·프로세스 생성 추적, 12개 부하 실행, 실제 제한, 이미지·스캐너·소스
해시와 최초 결과·후속 결과를 모두 보존한다.
[CI 실행](https://github.com/JeongJaeSoon/agent-guard/actions/runs/41809579162)의
`packaged-performance` ZIP에는 빌드 로그도 있다. `provenance.json`은 ZIP 해시와
정확한 PR/checkout SHA를 구분한다. 성능 수집 성공 자체를 채택 판정으로
사용하지 않았으며 `assess-packaged.sh`로 원본을 계산해 기준 통과를 확인했다.

## 재현

### 독립적인 두 번째 실행

첫 실행의 늦은 macOS arm64 설치 job은 `native-*`로 먼저 올라온 설치 로그까지
다운로드해 바이너리로 복사하려다 실패했다. 바이너리 디렉터리를 네 target으로
명시한 `4da41c9`에서 다시 실행했다. 마스킹·설치 실행 코드와 Rust 코어는
`30d7df8`과 같고, CI 수집 및 Rust 미노출 단언만 바뀌었다.
[새 실행](https://github.com/JeongJaeSoon/agent-guard/actions/runs/41812229577)에서
네 플랫폼 모두 실제 실행, 신규 설치, 공개 3.6.14에서 업데이트와 호스트 22건
실패 복귀를 통과했다. 차등은 각 1,024/0, 실제 scanner 호스트 계약은 각 90/0이다.

같은 실행의 별도 Linux x64 성능 결과는 Claude 목표 지연 −26.97%·CPU −25.99%,
Codex 지연 −26.90%·CPU −26.26%이며 일반 경로 지연 5% 초과 회귀는 없다.
동시 4개 처리량은 셸 1.028 → Rust 1.430 요청/초다.
[두 번째 원본](../bench/results/rust-packaged/qualification-4da41c9/)을 첫 결과와
합치거나 덮어쓰지 않았다. 두 예비 실행은 CPU 모델을 기록하지 않았고 절대 시간이
다르다. 각 실행 내부의 교대 비교만 사용하며, 최종 수집에는 `cpuinfo.txt`를 추가했다.

이 조건을 확인한 뒤 v3.7 후보의 기본 선택을 Rust로 바꿨다. 빈 값과 명시적
셸 설정의 기존 선택은 보존하며, helper를 사용할 수 없는 소스 전용 설치는
셸로 복귀한다. 기본값과 명시적 Rust 각각의 실패 복귀를 검사한다. 공개 발행과
그 이후의 실제 다운로드 검증은 별도 완료 조건이다.

### 실행 명령

네이티브 x64 Linux 코어와 sidecar를 `plugins/agent-guard/libexec/`에 놓고,
컨테이너별 cgroup 제한을 적용할 수 있는 Docker에서 실행한다.

```sh
sh bench/native/run-packaged.sh /absolute/path/to/gitleaks \
  9a0ee9eb2eed1e60b78d4404f985b077149c675d /absolute/new/results-directory
```

공개 파일의 네 플랫폼 설치·업데이트와 Homebrew 검사는 일회용 Actions runner에서
재현한다. 다음 명령은 공개 릴리스를 다시 발행하거나 자산을 교체하지 않는다.

```sh
gh workflow run public-native-release.yml -R JeongJaeSoon/agent-guard \
  --ref main -f version=3.7.0 -f previous_version=3.6.15
```

완료된 실행의 `public-*` artifact에서 실제 태그 SHA, OS·아키텍처, 다운로드
체크섬, 이전 버전, scanner·호스트 복귀와 Homebrew 설치 로그를 확인한다.
과거 원본을 덮어쓰지 않도록 새 출력 디렉터리를 사용한다.

기존 출력 디렉터리는 거부한다. 판정기는 원본의 소스·스캐너·설정 해시,
배포 바이너리 경로, 독립 출력 검증과 적용된 자원 제한부터 확인한다.
목표 두 호스트에서 지연 또는 CPU 10% 개선, 일반 지연 5% 회귀 한도를
통과하지 못하면 실패한다. 판정기 단위 테스트의 인공 자료는 측정 증거가 아니다.

## 안전성과 남은 경계

배포 바이너리의 손상·부재·체크섬 불일치·실행 오류·비정상 출력은 원래
셸/jq 경로로 복귀한다. 검사한 새 설치와 업데이트는 Rust 도구를 PATH에서
제외했으며 기존 3.6.14의 실제 공개 다운로드를 사용한다. 후보 다운로드만
CI 내부에서 대체했으므로 공개 v3.7.0 검증과 구분한다.

설치 과정은 기존 디렉터리와 공개 실행 링크를 보존한다. 추출·커밋·링크 생성
오류와 TERM·INT를 주입해 복구를 확인한다. SIGKILL·전원 손실은 셸 trap으로
복구할 수 없으며 남은 `previous` 디렉터리의 수동 복구 안내를 유지한다.

`bae3c94`의 macOS 병렬 회귀 검사는 SIGINT를 무시하는 부모 상태를 상속하여
INT 주입이 전달되지 않았다. 이 실패는 [CI 로그](https://github.com/JeongJaeSoon/agent-guard/actions/runs/41817050471/job/126530332408)에
보존한다. 기존 런타임의 portable process launcher에도 쓰는 Perl로 테스트
자식의 신호 상태를 초기화하고 TERM/INT 종료 코드 143/130과 설치 보존을 함께
검사하도록 고쳤다. 신호를 무시하는 부모 아래의 로컬 재현 검사도 통과했으며,
후속 최종 SHA의 macOS CI 결과로 수정 여부를 판단한다.

로컬 전체 검사 중 임시 디렉터리 생성 실패를 다루지 않던 기존 테스트의
정리 코드가 개발 작업 트리를 지운 사건이 있었다. 당시 변경은 모두 커밋과
원격 브랜치에 보존되어 동일 소스로 복원했으며 사용자 변경은 잃지 않았다.
임시 경로 검증과 호출자 보존 회귀 검사를 추가했다. 실패 로그를 성공 증거로
쓰지 않았고 독립 Docker에서 다시 검사했다. `0922829`의 2,688건 통과는 zsh가
없는 로컬 결과이며 이후 커밋 또는 네 플랫폼 CI 완료를 대체하지 않는다.
추가로 `6cacbee` 소스를 고정한 Rust 미설치 Docker 이미지에서 zsh를 포함한 전체
2,713건/실패 0을 확인했다. 이는 기본 전환 전 릴리스 준비 코드의 결과다.
전환 이후에는 기본값·명시적 Rust 각각의 호스트 실패 복귀 44건, 명시적 셸·빈
설정 선택과 실제 공개 3.6.14→후보 3.7.0 업데이트를 별도로 확인했다.

추가 전체 검사는 Rust 미설치 Docker의 jq 1.6에서 기존 `native-suite.sh` 오류
주입 어댑터를 사용했다. `dfcd442`에서 2,709건 통과·4건 실패였으며 성공 근거로
사용하지 않는다. 실패는 셸과 Rust 모두의 `exec -- printenv`에서 재현됐다.
jq 1.6 raw slurp가 마지막 NUL을 제거해 인자 검증이 실패하고 전체 출력이
마스킹된 것이 원인이다. NUL 뒤에 고정 종료 필드를 붙여 검증한 뒤 제거하는
방식으로 인자 경계를 보존했다. 빈 값·누락 인자와 종료 코드·후속 정상 값·
후행 빈 값의 독립 기대값을 jq 1.6과 1.7.1에서 확인하고 legacy CI에 추가했다.
기존 실패 및 수정 뒤 전체 검사 로그는 별도로 보존한다.

Rust 범위는 문자열 치환 코어와 이미 이관한 개발 도구 10개다. 탐지·정책·PII·
출력 파이프라인과 호스트 어댑터는 셸에 남는다. v4의 필요성은 이 경계를
추가 이관할 구체적 이득과 호환성 유지의 한계를 측정한 뒤 판단한다.
