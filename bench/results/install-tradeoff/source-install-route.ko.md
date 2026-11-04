# Git marketplace와 같은 소스 설치 경로의 추가 관측

공개 v3.7.0 커밋 e709445의 깨끗한 소스 checkout에는 libexec 바이너리가 없다.
동일 CLI·설정에서 공식 scanner와 후보만 교대해 다중 문자열 입력을 두 호스트에
각 9쌍 실행했다. 로컬 실제 외부 제한은 4 CPU/16 GiB이며 2 CPU/1 GiB CI가
아니다. 입력은 secret 100개 leaf와 정상 status 4,000개 leaf, 로그는 off다.

| 호스트 | 지연 | CPU | 최대 자식 RSS |
| --- | ---: | ---: | ---: |
| Claude | 1.564 → 0.824 s (−47.29%) | 1.638 → 0.843 s (−48.54%) | 60.54 → 34.09 MiB |
| Codex | 1.485 → 0.824 s (−44.54%) | 1.551 → 0.848 s (−45.36%) | 60.98 → 33.90 MiB |

모든 표본의 독립 출력 기대값을 통과했다. 별도 합성 입력의 exec trace에서는
기본 환경 선택을 사용했고 양쪽 모두 native helper 실행 0회와 독립 기대값
일치를 확인했다. trace의 전체 execve 시도는 각각 80회지만 PATH 검색 실패를
포함할 수 있어 프로세스 생성 횟수로 쓰지 않는다. trace는 성능 표본과 별개다.

측정 driver는 양쪽에 packaged dispatch를 요청하도록 flags를 켰지만 실제
소스에는 helper가 없어 셸로 복귀한다. 원시 JSON의 native_dispatch 문자열은
요청 flags를 나타내며 실제 native 실행 증거가 아니다. native_core_sha256도
제공한 참조 파일의 식별자일 뿐 실행한 파일이 아니다. 이 한계를 숨기지 않고
실제 helper 부재와 별도 기본 선택 trace를 함께 보존한다.

Rust 코어가 없는 소스 설치에서도 scanner 초기화 개선 가능성을 확인했다.
실제 Claude/Codex 앱에 marketplace를 설치한 end-to-end 검증은 아니며,
하나의 목표 fixture의 로컬 관측이다. 패키지 경로 CI의 48–67%를 이 경로에
그대로 적용하지 않는다. Homebrew 회귀와 공급/업데이트 검증 문제 때문에
기존 scanner 후보 일괄 교체 기각 판단도 유지한다.
