<!-- translated-from: docs/installation.md; source-blob: bc80989bf077b0a4e493e477d498ff8c5b6319c1 -->

<a id="installing-agent-guard"></a>

# Agent Guard 설치

[English](installation.md) · 한국어 · [日本語](installation.ja.md)

이 문서는 [영어 정본](installation.md)의 한국어 번역입니다. 검증 절차는 [한국어 검증 안내](verification.ko.md)를 참고하세요. 그 외 상세 문서는 영어로 연결됩니다.

Agent Guard는 하나의 정책 CLI와 별도의 Claude Code·Codex 플러그인 adapter로 구성됩니다. 보호하려는 경계에 맞는 설치 경로를 선택하세요.

| 경로 | 설치 | 업데이트 | 검증 |
| --- | --- | --- | --- |
| Claude Code 플러그인 | Claude Code에서 Agent Guard marketplace와 플러그인 추가 | `agent-guard plugin update --host claude` 실행. 새 릴리스로 이동하는 Claude Code marketplace 명령을 출력합니다. | 플러그인 내부 `bin/agent-guard version`과 무해한 host 경로 검사 실행 |
| Codex 플러그인 | Codex에서 Agent Guard marketplace와 플러그인 추가 | `agent-guard plugin update --host codex` 실행. 새 릴리스로 이동하는 Codex marketplace 명령을 출력합니다. | 플러그인 내부 `bin/agent-guard version`과 무해한 host 경로 검사 실행 |
| 독립 CLI | 아래 체크섬 검증 bootstrap 명령 사용 | `agent-guard update` | `agent-guard version`, `agent-guard doctor`, `agent-guard check` |
| Homebrew | 공개된 tap formula 설치 | `brew upgrade JeongJaeSoon/tap/agent-guard` | `agent-guard version` |

`PATH`의 CLI만으로 플러그인을 대체할 수는 없습니다. 플러그인은 Claude Code와 Codex 이벤트를 공통 CLI 계약으로 변환합니다. 독립 설치는 CLI와 선택적인 shell integration을 추가하며 host hook을 등록하지 않습니다.

독립 CLI 없이 설치하려면 릴리스 태그에 고정한 marketplace를 추가하고 host 자체 명령으로 플러그인을 설치하세요. `vX.Y.Z`를 검토한 릴리스로 바꿉니다.

```sh
claude plugin marketplace add JeongJaeSoon/agent-guard@vX.Y.Z --scope user
claude plugin install agent-guard@agent-guard --scope user

codex plugin marketplace add JeongJaeSoon/agent-guard@vX.Y.Z
codex plugin add agent-guard@agent-guard
```

플러그인을 설치해도 `PATH`에 `agent-guard`가 추가되지는 않습니다. 따라서 표의 `agent-guard plugin update` 경로에는 독립 CLI 또는 Homebrew CLI가 필요합니다. 둘 다 없다면 marketplace를 제거하고 위 명령을 새 태그로 다시 실행해 업데이트하세요. marketplace를 제거하면 설치된 플러그인도 제거됩니다. 완료 후 host를 재시작하세요.

플러그인만 설치하면 `agent-guard`가 `PATH`에 없으므로, 플러그인의 CLI가 출력하는 안내(예: `update`, `check`, `doctor`, SessionStart 알림)는 그 실행 파일을 따옴표로 감싼 절대 경로로 적습니다. 예: `"$HOME/.claude/plugins/cache/agent-guard/agent-guard/current/bin/agent-guard" setup`. `PATH`의 `agent-guard`가 같은 설치일 때, 그리고 독립·Homebrew 설치는 `PATH`에 `agent-guard`가 있을 때 안내가 지금처럼 짧은 `agent-guard` 이름을 씁니다. `PATH`에 `agent-guard`가 없는 상태에서 경로로 실행한 독립 CLI(예: `~/.local/bin`을 추가하기 전의 `~/.agent-guard/bin/agent-guard`)도 자기 경로를 적습니다.

<a id="runtime-dependencies"></a>

<a id="optional-warm-gitleaks-helper"></a>

## 선택형 warm gitleaks helper

스캔할 때마다 새 gitleaks 프로세스가 뜨고, 그 시간 대부분이 시작 비용입니다.
warm helper는 컴파일한 gitleaks 8.30.1 detector 하나를 사용자·설정마다
메모리에 두고 모든 세션이 함께 쓰며, 10분 동안 요청이 없으면 스스로 끝납니다.
Linux x64/arm64와 macOS arm64용 별도 릴리스 asset이고, 릴리스 아카이브·Homebrew
패키지·플러그인에는 들어 있지 않습니다.

`agent-guard setup --install`은 gitleaks와 함께 helper도 설치합니다. 사용 중인
gitleaks가 공식 gitleaks 8.30.1 릴리스 빌드이면, private 디렉터리에 있든 `PATH`에
있든 helper를 내려받습니다. 예전에 그렇게 gitleaks를 설치했다면
`agent-guard setup --install`을 다시 실행해 helper를 받으세요. 이 버전의 helper가
이미 설치되어 있으면 아무것도 내려받지 않습니다. helper를 내려받지 못하거나
값이 맞지 않으면 경고만 냅니다. gitleaks는 설치되고 명령은 실패하지 않습니다.
그 밖의 gitleaks(Homebrew 빌드 같은 다른 빌드, 다른 버전,
`AGENT_GUARD_GITLEAKS_BIN`이 고른 것)를 쓰고 있으면 helper를 설치하지 않고 이유와
할 일을 한 줄로 알립니다. 그 gitleaks가 `PATH`에서 왔고 8.30.1의 checksum을 주면,
`PATH`보다 먼저 쓰이는 private 디렉터리에 공식 빌드를 설치하고, 그렇게 했다는 것과
되돌리는 방법(그 파일을 지우거나 `AGENT_GUARD_GITLEAKS_BIN`을 `PATH`의 빌드로
설정)을 알립니다. private 디렉터리에 이미 있는 gitleaks는 바꾸지 않고, `doctor`는 이
일을 하지 않습니다.
helper asset이 없는 플랫폼에서는 아무 말도 하지 않습니다. helper를 건너뛰려면
명령을 실행할 때 `AGENT_GUARD_GITLEAKS_HELPER=off`를 두세요.

helper만 설치하는 명령도 있습니다. 플러그인·Homebrew·단독 설치 모두 같고,
설치하지 못하면 실패합니다.

```sh
agent-guard setup --install-gitleaks-helper
```

두 명령 모두 두 바이너리가 이 Agent Guard 버전에 들어 있는 SHA-256 값과 모두 맞을
때만 helper를 설치합니다. 위치는 private gitleaks(기본값 `~/.agent-guard/bin`) 옆의
`gitleaks-helper`입니다. 설치하면 기본으로 사용합니다. 변수를 둘 필요가 없고,
실행 중인 호스트도 다음 스캔부터 씁니다. Agent Guard를 업데이트한 뒤에는 두 명령 중
하나를 다시 실행하세요. 다른 버전용으로 설치된 helper는 쓰지 않습니다. 끄려면 다음과
같이 합니다.

```sh
export AGENT_GUARD_GITLEAKS_HELPER=off
```

판정은 모두 CLI가 계속 내립니다. helper가 실패하면 실제 gitleaks를 실행하므로,
실패가 깨끗한 스캔으로 처리되지 않습니다. `AGENT_GUARD_GITLEAKS_BIN`을 설정했거나
`AGENT_GUARD_LOG_MODE=off`이면 helper를 쓰지 않습니다. helper는
`agent-guard setup --install`이 설치하는 공식 gitleaks 8.30.1 릴리스 바이너리에만
답하고, Go `regexp`로 빌드한 gitleaks(Homebrew, `go install`)는 늘 실제로
실행합니다. `agent-guard setup`과 `agent-guard doctor`는 설치된 helper가 답하지
않을 때 그 이유와 할 일을 한 줄로 알립니다. 선택된 gitleaks가 다른 빌드나 버전일 때,
상태 디렉터리가 깊어 helper의 소켓 경로가 103바이트를 넘거나 그 디렉터리가 내 소유의
0700 일반 절대 경로가 아닐 때, helper가 다른
Agent Guard 버전이나 플랫폼용으로 설치되었을 때, 위의 두 변수 중 하나를 설정했을 때입니다.
gitleaks 파일을 이 버전에 기록된 공식 빌드의 SHA-256과 비교하며, 아무것도 시작하거나
설치하지 않습니다. 직접 소스에서
빌드한 것을 쓰려면 `AGENT_GUARD_GITLEAKS_HELPER`를 그 `agent-guard-scan`의 절대
경로로 두세요. 같은 결과 보장, 실패 처리, 메모리, 개인정보는
[warm gitleaks helper 안내(영어)](https://github.com/JeongJaeSoon/agent-guard/blob/main/docs/gitleaks-helper.md)에
있습니다.

## 실행 의존성

릴리스 아카이브와 Homebrew 패키지에는 Linux x64/arm64와 macOS arm64용 Rust 문자열 치환기가 포함됩니다. Rust 컴파일러는 필요하지 않습니다. CLI는 해당 플랫폼의 체크섬을 검증한 치환기를 기본으로 사용하며, 바이너리가 없거나 실패하면 셸/jq로 복귀합니다. 탐지·정책·PII·호스트 어댑터는 셸에 남으므로 아래 의존성은 계속 필요합니다. 셸을 명시적으로 선택하려면 다음을 설정하세요.

```sh
export AGENT_GUARD_EXPERIMENTAL_REDACTOR=shell
```

Linux 치환기는 정적 musl을 사용해 glibc가 필요하지 않으며 Ubuntu 24.04에서 실제 실행을 검사합니다. macOS 치환기의 배포 대상은 macOS 14 이상이며 macOS 15 arm64에서 검사합니다. Intel Mac(x86_64)은 지원하지 않습니다. 릴리스는 Intel용 치환기를 배포하지 않으며 Intel에서 검사하지 않으므로, Intel 설치는 셸/jq 복귀를 사용합니다. 독립 설치 스크립트는 Intel에서 이 안내를 출력하고 업데이트 때 남아 있는 Intel 치환기를 지웁니다. Intel용 치환기가 포함된 마지막 릴리스는 3.8.2입니다. 그 릴리스에 머무르려면 설치 스크립트를 `AGENT_GUARD_VERSION=3.8.2`로 실행하세요. 배포 대상 설정만으로 모든 이전 OS·커널의 실행이 입증되지는 않습니다. 미지원 환경은 셸 복귀를 유지합니다. 배포 체크섬은 손상을 탐지하며 바이너리와 체크섬이 함께 악의적으로 교체된 경우를 인증하지는 않습니다.

소스 아카이브와 호스트가 관리하는 Git marketplace 플러그인에는 바이너리가 없으므로 `AGENT_GUARD_RUST_CORE_BIN`으로 신뢰하는 사전 빌드 치환기를 지정하지 않으면 셸을 사용합니다. 독립 설치의 치환기를 사용하면 호스트 캐시를 수정할 필요가 없습니다. 같은 버전의 독립 설치 릴리스를 설치하고 그 치환기를 검증한 뒤, 호스트를 실행하는 환경에 재정의를 설정하세요. 플랫폼에 맞는 대상(`x86_64-unknown-linux-musl`, `aarch64-unknown-linux-musl`, `aarch64-apple-darwin`)을 고르세요. 다음은 Linux x64 예시입니다.

```sh
target=x86_64-unknown-linux-musl
native_root="$HOME/.agent-guard/libexec"
(cd "$native_root" && shasum -a 256 -c "agent-guard-redact-$target.sha256") &&
  export AGENT_GUARD_RUST_CORE_BIN="$native_root/agent-guard-redact-$target"
```

Homebrew의 치환기 디렉터리는 `$(brew --prefix agent-guard)/libexec/libexec`입니다. 그 환경으로 호스트를 다시 시작하세요. 이 설정은 hook을 등록하거나 바꾸지 않습니다. 재정의 값은 실행 가능한 파일의 절대 경로여야 하며 요청마다 체크섬을 다시 확인하지 않으므로, 신뢰하는 설치만 가리키세요. 설정을 지우면 패키지에 포함된 치환기로 돌아가고, `AGENT_GUARD_EXPERIMENTAL_REDACTOR=shell`을 설정하면 네이티브 실행을 끕니다.

macOS와 Linux에서 실행하려면 `sh`, `awk`, `git`, `jq`, gitleaks 8.30 이상이 필요합니다. gitleaks 버전 확인을 별도 프로세스 그룹에서 실행하기 위한 `setsid` 또는 Perl도 필요합니다. 이 격리로 버전 확인의 시간 제한과 자식 프로세스 정리를 보장합니다. Linux에서는 `sudo apt-get install -y util-linux` 또는 `sudo dnf install -y util-linux`로 `setsid`를 설치하세요. Homebrew formula는 CLI와 함께 Perl을 설치합니다. macOS에서 수동 설치했고 두 도구가 모두 없다면 `brew install perl`을 사용할 수 있습니다.

격리 도구가 없으면 `agent-guard setup`, `doctor`, `check`는 0이 아닌 종료 상태를 반환합니다. `setup --install`은 다운로드 전에 격리 도구 유무를 확인합니다. 도구가 없으면 gitleaks를 다운로드하거나 덮어쓰지 않고 누락 도구의 설치 명령을 출력하며, 도구를 설치한 뒤 gitleaks가 완전히 준비되었는지 다시 확인합니다. 실행 중인 hook은 이 상태를 정상 검사로 취급하지 않으며 `AGENT_GUARD_INFRA_FAILURE_MODE`의 정책을 적용합니다. 이 정책은 비밀 스캔을 실행하지 못하면 기본으로 차단합니다. `open`에서는 gitleaks 없이도 PreToolUse의 보호 경로 검사와 deny 패턴 검사를 계속 실행하고 그 비밀 스캔만 건너뜁니다. 다른 hook은 지금처럼 검사 없이 통과합니다.

독립 CLI 또는 Homebrew 명령으로 `agent-guard`가 이미 설치되어 있다면 공식 host 관리 도구에 플러그인 설치를 위임할 수 있습니다.

```sh
agent-guard plugin status --host all
agent-guard plugin install --host claude
agent-guard plugin install --host codex
```

`--host all`을 지정하면 두 host에 한 번에 설치합니다. `--host`를 생략하면 `claude`와 `codex` 중 정확히 하나만 사용 가능해야 합니다. Claude Code는 `--scope user|project|local`을 지원하며 기본값은 `user`입니다. Codex는 user scope만 지원합니다. 각 marketplace는 설치를 수행하는 CLI 버전과 같은 릴리스 태그(`v<CLI version>`)에 고정됩니다. 고정된 marketplace와 설치된 플러그인이 이미 해당 CLI와 일치하면 `install`을 다시 실행해도 변경이 없고, 암묵적으로 업데이트하지 않습니다. 설치된 플러그인이 비활성화되어 있으면 `status`가 이를 보고하고 `install`은 host 관리 도구에서 활성화하도록 안내합니다. 업데이트와 제거는 명시적으로 실행합니다.

```sh
agent-guard plugin update --host all
agent-guard plugin uninstall --host claude
```

`plugin status`는 버전이 어긋나도 종료 코드 0을 반환하므로 기존 스크립트는 그대로 동작합니다. drift를 감지하려면 `--check`를 추가하세요. `agent-guard plugin status --check --host all`은 marketplace 고정 태그나 설치된 플러그인 버전이 이 CLI와 다르면(`status`가 출력하는 drift와 같습니다) 1을 반환합니다. `--check`는 `status`에만 적용됩니다. `plugin update`가 2로 종료하면 사용자 조치가 필요하다는 뜻입니다. 예를 들어 다른 릴리스에 고정된 marketplace는 host 관리 도구로 제거한 뒤 다시 추가해야 하며, 명령이 정확한 절차를 출력합니다.

이 명령은 원격 `JeongJaeSoon/agent-guard@v<CLI version>` marketplace를 사용하며 host CLI를 직접 호출합니다. 플러그인 캐시나 host 설정 파일을 직접 쓰지 않고, `sudo`를 호출하거나 host의 확인 절차를 우회하지 않습니다. 변경한 각 host를 재시작한 후 hook을 검증하세요.

`status`는 설치된 플러그인과 기대 버전의 차이를 marketplace 상태와 별도로 보고합니다. Claude Code의 JSON 상태는 설정된 marketplace ref를 노출합니다. Codex 0.153.4는 이를 노출하지 않으므로 Codex 상태에서는 태그 고정 여부를 보수적으로 미검증으로 표시합니다. `install` 또는 `update`가 기존 Codex marketplace를 재사용하기 전에 CLI는 Codex에 동일한 고정 소스를 다시 추가하도록 요청합니다. Codex는 같은 ref일 때만 이를 변경 없는 멱등 작업으로 취급하며, 고정되지 않았거나 ref가 다르면 상태 변경 없이 거부합니다.

CLI는 고정되지 않은 marketplace, 다른 릴리스에 고정된 marketplace, 이름은 같지만 출처가 다른 marketplace를 알리지 않고 교체하지 않습니다. 공식 host 관리 도구로 marketplace를 제거한 뒤 `agent-guard plugin install --host HOST`를 다시 실행하세요. marketplace 제거는 그 marketplace에서 설치한 플러그인도 제거하므로 두 명령을 하나의 복구 절차로 취급하세요. marketplace 등록이나 플러그인 설치가 중간에 실패하면 CLI는 host가 관리하는 상태 중 무엇이 남아 있는지와 안전하게 재시도할 정확한 명령을 보고합니다.

CLI의 플러그인 수명주기 명령은 직접 관리하는 설치용입니다. `managed` scope로 설치된 Claude 플러그인을 탐지하며, macOS와 Linux에서 관리자가 소유한 `managed-settings.json`과 `managed-settings.d/*.json`의 Agent Guard 항목도 읽습니다. managed marketplace만 선언되어 있고 플러그인이 아직 다운로드되지 않은 초기 상태도 포함합니다. `status`는 이 상태를 관리 대상이라고 식별하고 `install`, `update`, `uninstall`은 변경을 거부합니다. Claude의 기본 파일 다음 정렬된 drop-in 파일 순서로 병합한 뒤 Agent Guard 키를 평가합니다. 파일을 읽을 수 없거나 형식이 잘못되었거나 일반 파일로 해석되지 않는 경로라면 소유권을 안전하게 판단할 수 없으므로 이 명령은 fail-closed로 실패합니다. 빈 파일이나 관련 없는 설정만 담은 유효한 파일은 직접 관리하는 설치를 막지 않습니다. 유효한 `policyHelper`가 선언되면 실행 시 그 결과가 파일 기반 설정을 대체합니다. CLI는 helper를 실행하지 않으므로 이 경우에도 fail-closed로 실패합니다. 이 CLI 검사는 의도치 않은 수명주기 변경을 줄이는 보조 장치이며, 관리 정책을 강제하는 경계는 Claude의 managed-settings 배포입니다. Jamf 등으로 관리하는 배포에서는 관리 설정의 검토된 릴리스 태그를 변경하세요. 관리 정책 위에 user 또는 project 설치를 추가하지 마세요. [운영](operations.md#managed-claude-code-rollout)을 참고하세요.

<a id="standalone-cli"></a>

## 독립 CLI

현재 릴리스를 설치합니다.

```sh
curl -fsSL https://github.com/JeongJaeSoon/agent-guard/releases/latest/download/bootstrap.sh | sh
```

bootstrapper는 버전별 릴리스 archive와 SHA-256 파일을 다운로드하고, 설치 파일을 바꾸기 전에 archive를 검증합니다. `~/.agent-guard`에 설치하고 `~/.local/bin`에 `agent-guard` 링크를 만듭니다. 그 뒤 의존성 상태를 보고하고 기본 shell integration을 설치합니다. `~/.local/bin`이 `PATH`에 있는지 확인한 후 실행하세요.

```sh
agent-guard version
agent-guard doctor
agent-guard check
```

`check`는 의존성과 정책 파일의 사용 가능 여부를 확인할 뿐, host hook이 호출되었다는 증거는 아닙니다. 사용할 경로에서 무해한 명령으로 host adapter를 별도 검증하세요.

릴리스를 고정하려면 검토한 공개 버전을 `v` 접두사 없이 입력하세요. 배포에 필요한 기능이 포함된 버전을 선택하세요. 격리된 설치가 필요한 경우에만 아래 설치 위치를 변경합니다.

```sh
printf 'Reviewed release version (X.Y.Z): '
IFS= read -r guard_version
curl -fsSL "https://github.com/JeongJaeSoon/agent-guard/releases/download/v${guard_version}/bootstrap.sh" | \
  AGENT_GUARD_VERSION="$guard_version" \
  AGENT_GUARD_HOME="$HOME/.agent-guard" \
  AGENT_GUARD_BIN_DIR="$HOME/.local/bin" sh
```

명령 wrapping 없이 shell integration만 설치하려면 설치 시에만 `AGENT_GUARD_COMMAND_WRAPPING=off`를 설정하세요.

`agent-guard update`와 이후의 bootstrap 실행은 그 선택을 유지합니다. `AGENT_GUARD_COMMAND_WRAPPING`이 설정되지 않았으면 설치된 CLI에 `agent-guard setup-shell --print-command-wrapping`으로 묻습니다. 이 명령은 옵션 없는 `setup-shell`이 다시 쓸 rc 파일(fish는 `~/.bashrc`와 `~/.zshrc` 둘 다)의 관리 블록을 보고 `on` 또는 `off`를 출력합니다. `setup-shell --rc FILE`로 설치한 경우처럼 그 파일에 블록이 없으면, 기본 resolver 파일 없이 opt-out resolver 파일만 있을 때 `off`로 읽습니다. 선택을 바꾸려면 update할 때 `AGENT_GUARD_COMMAND_WRAPPING=on` 또는 `off`를 설정하세요. 이 확인이 없는 릴리스는 `agent-guard update` 중에 명령 wrapping을 다시 켰습니다. 이미 그렇게 됐다면 `agent-guard setup-shell --no-command-wrapping`을 한 번 다시 실행하세요. `AGENT_GUARD_VERSION`으로 그런 이전 릴리스를 고정한 bootstrap 실행도 `AGENT_GUARD_COMMAND_WRAPPING=off`를 설정하지 않으면 wrapping을 켠 상태로 설치합니다.

독립 설치는 다음과 같이 업데이트합니다.

```sh
agent-guard update
agent-guard version
agent-guard doctor
agent-guard check
```

플러그인 캐시에서는 updater를 의도적으로 사용할 수 없게 되어 있습니다. 실행 파일 자체가 marketplace 제거 시 삭제되는 캐시에 있어 스스로 marketplace의 고정 태그를 바꿀 수 없기 때문입니다. 대신 `agent-guard plugin update --host claude` 또는 `--host codex`를 실행하세요. 설치된 플러그인이 이미 CLI와 일치하면 최신 GitHub 릴리스를 조회하고, 새 버전으로 이동하는 정확한 host 관리 명령인 `marketplace remove`, `marketplace add ...@vX.Y.Z`, 플러그인 설치 명령을 출력합니다. `agent-guard doctor`와 `agent-guard plugin status`도 같은 릴리스 노후 상태를 보고합니다. 조회를 건너뛰려면 `AGENT_GUARD_RELEASE_CHECK=off`를 설정하세요.

Codex가 `PATH`에 있으면 `agent-guard doctor`는 잠깐 띄운 `codex app-server`에 `hooks/list`로 묻습니다. 현재 디렉터리에서 Codex가 agent-guard hook을 실행할지 확인하려는 것입니다. Codex는 각 hook을 hook 항목과 플러그인 내용으로 신뢰합니다. 그래서 `hooks.json`이 그대로여도 플러그인을 갱신하면 agent-guard hook이 모두 다시 검토가 필요한 상태가 될 수 있습니다. 이 hook들은 다시 신뢰할 때까지 Codex가 실행하지 않습니다.

Codex가 agent-guard hook을 검토 필요나 꺼짐으로 보고하면, `doctor`는 exit 1로 끝나고 다음 절차를 출력합니다.

1. 그 디렉터리에서 `codex`를 시작합니다.
2. **Hooks need review**에서 **Review hooks**를 고릅니다.
3. 각 hook의 Source가 `agent-guard@agent-guard`이고 명령이 예상과 같은지 확인한 뒤에만 신뢰합니다.
4. 실행 중인 Codex 세션을 다시 시작합니다.

예상되는 명령은 플러그인의 `hooks/launch.sh`를 `codex`와 그 이벤트의 hook subcommand로 실행하는 한 줄입니다. agent-guard hook 사이에서는 이 subcommand만 다릅니다. `Stop`의 명령은 다음과 같습니다.

```sh
sh -c 'r=${PLUGIN_ROOT:-}; [ -n "$r" ] && for q in "$r" "${r%/*}/current" "${r%/*}"/[0-9]*.[0-9]*.[0-9]*; do [ -f "$q/hooks/launch.sh" ] && exec sh "$q/hooks/launch.sh" codex hook-stop "$r"; done; while read -r l; do :; done; m=${AGENT_GUARD_INFRA_FAILURE_MODE:-}; case $m:hook-stop in open:*|closed:*) ;; *:hook-s*) m=open ;; *) m=unset ;; esac; a=blocking; [ $m = open ] && a=continuing; echo "agent-guard: PLUGIN_ROOT env not set or no hook launcher was found; $a because AGENT_GUARD_INFRA_FAILURE_MODE=$m" >&2; [ $m = open ] && exit 0; exit 2'
```

나머지 hook은 `hook-pre-tool`, `hook-post-tool`, `hook-session-start`, `hook-user-prompt`를 씁니다. launcher는 Codex가 신뢰하는 플러그인 내용의 일부입니다. launcher는 `bin/agent-guard`를 실행하기 전에 선택된 버전이 완전한지 확인하고, 실행 파일을 찾지 못하면 `AGENT_GUARD_INFRA_FAILURE_MODE`를 적용합니다.

Codex용 `plugin status`, `plugin install`, `plugin update`도 같은 확인 결과를 출력하지만, 종료 코드는 바꾸지 않습니다. 읽을 수 없는 응답은 ok가 아니라 unverified로 보고합니다. ok는 새 Codex 프로세스가 읽는 설정이 그렇다는 뜻이며, hook이 실제로 실행되는 것을 관찰했다는 뜻은 아닙니다. 이 확인은 Codex의 app server를 띄우므로, 여느 Codex 시작과 마찬가지로 네트워크에 접속하거나 Codex 자체 캐시를 갱신할 수 있습니다. 건너뛰려면 `AGENT_GUARD_CODEX_TRUST_CHECK=off`를 설정하세요.

`setup-shell`은 shell rc에 다음 블록을 추가하고, 검증하는 resolver를 `~/.agent-guard/shell-init.sh`에 씁니다.

```sh
# >>> agent-guard shell-init >>>
[ ! -r ~/.agent-guard/shell-init.sh ] || . ~/.agent-guard/shell-init.sh
# <<< agent-guard shell-init <<<
```

파일이 없으면 이 줄은 아무것도 하지 않고 종료 상태 0으로 끝납니다. 둘 다 캐시의 `current` 링크를 통해 실행 파일을 찾으므로 플러그인 업데이트 후 `setup-shell`을 다시 실행할 필요가 없습니다. 다시 실행하면 예전 블록을 같은 자리에서 이 블록으로 바꿉니다.

resolver 파일은 `setup-shell`을 실행한 시점의 사본이며, 첫 줄에 파일 형식을 기록합니다. `~/.zshrc`나 `~/.bashrc`에 예전 `setup-shell`이 쓴 인라인 블록이 남아 있거나, `~/.agent-guard/shell-init*.sh` 파일에 형식 줄이 없거나 더 오래된 형식 줄이 있으면 `agent-guard doctor`가 `shell integration:` 줄을 출력합니다. 그 줄이 안내하는 대로 `setup-shell`을 다시 실행하면 블록이 위의 한 줄로 바뀌고 파일이 새로 써집니다. 이 줄은 `doctor`의 종료 상태를 바꾸지 않으며, `doctor`는 두 파일 모두 고치지 않습니다. 그때까지 예전 두 형태도 그대로 로드됩니다. `--rc`로 고른 rc 파일은 `doctor`가 확인하지 않습니다.

독립 CLI 업데이트는 기존 설치 옆에 후보를 준비한 뒤 교체합니다. 체크섬·추출·
교체 실패 시 이전 설치를 유지하거나 복구하며, 관련 없는 로컬 파일도 보존합니다.
전원 손실이나 처리할 수 없는 강제 종료가 마지막 디렉터리 교체를 중단하면,
옆 디렉터리의 `.agent-guard-update.*/previous` 백업을 보존하고 원래 설치 경로로
복구한 뒤 다시 시도하세요. 이전·새 배포본을 함께 보관할 디스크 공간이 필요합니다.

<a id="homebrew"></a>

## Homebrew

프로젝트 tap에서 공개된 formula를 설치합니다.

```sh
brew tap JeongJaeSoon/tap
brew install JeongJaeSoon/tap/agent-guard
agent-guard version
```

업그레이드 후 버전을 확인합니다.

```sh
brew upgrade JeongJaeSoon/tap/agent-guard
agent-guard version
```

formula는 릴리스 tarball의 SHA-256을 고정합니다. 이 설치는 Homebrew가 관리하므로 그 위에 `agent-guard update`를 실행하지 마세요.

이 CLI로 Claude Code 또는 Codex 플러그인도 설치했다면 CLI를 업그레이드해도 host marketplace가 새 릴리스로 자동 이동하지 않습니다. `agent-guard update` 또는 `brew upgrade` 후 직접 관리하는 각 host를 명시적으로 동기화하세요.

```sh
agent-guard plugin status --host all
agent-guard plugin update --host all
```

기존 marketplace가 이전 릴리스에 고정되어 있으면 `plugin update`는 변경 전에 멈추고, 공식 host 관리 도구로 제거하고 재설치하는 정확한 명령을 출력합니다. 해당 복구 순서에 따라 실행하고 host를 재시작한 다음, 플러그인 내부 설정과 수용 검사를 다시 실행하고 변경된 Codex hook을 다시 신뢰하도록 승인하세요. 그 컴퓨터에 설치된 host만 대상으로 합니다. Jamf로 관리하는 Claude Code는 관리자 배포를 통해 managed marketplace 태그를 올리세요.

<a id="removing-an-installation"></a>

## 설치 제거

각 경로를 소유한 관리 도구로 제거하세요. host 플러그인은 Claude Code 또는 Codex 플러그인 관리 도구를, Homebrew는 `brew uninstall JeongJaeSoon/tap/agent-guard`를 사용합니다. 독립 설치는 먼저 `agent-guard setup-shell`이 선택한 shell rc 파일에서 관리되는 shell integration 블록과, 그 블록이 읽던 `~/.agent-guard/shell-init*.sh` 파일을 제거하세요. 다음 명령으로 경로를 확인한 뒤에만 공개 심볼릭 링크와 설치 디렉터리를 제거합니다.

```sh
command -v agent-guard
readlink "$(command -v agent-guard)"
```

실행 파일을 지우기 전에, `install.sh git-hooks`를 실행했던 각 저장소에서 native Git hook을 제거하세요. hook은 실행 파일을 절대 경로로 가리키므로, 그 파일이 없어지면 그 저장소의 모든 커밋을 막습니다.

```sh
cd <each-repository-with-the-hook>
git config --get core.hooksPath   # prints githooks while the hook is active
git config --unset core.hooksPath
rm githooks/pre-commit
```

`core.hooksPath`를 해제하면 Git이 다시 `.git/hooks`를 실행하므로, 설치 전에 있던 hook(agent-guard hook이 연결해 실행하던 hook)이 다시 단독으로 실행됩니다. `githooks/`에 계속 쓰는 다른 hook이 있다면 `core.hooksPath`는 그대로 두고 `githooks/pre-commit`만 지우세요. 제거하지 않은 hook은 계속 fail-closed로 동작합니다. exit 1로 끝나고, 없는 경로와 위 명령을 출력합니다. 이전 릴리스가 설치한 hook은 `exec: ... not found`만 출력합니다. 안내 문구를 넣으려면 그 저장소에서 현재 릴리스의 `install.sh git-hooks`를 다시 실행하세요.

플러그인 관리 도구의 캐시를 수동으로 삭제하지 마세요. 수명주기는 host가 관리합니다. 제거 후 새 shell을 열어 `command -v agent-guard`가 예상대로 해석되는지 확인하세요. 다른 설치가 남아 있다면 해당 설치의 `version`, `doctor`, `check`를 실행합니다.
