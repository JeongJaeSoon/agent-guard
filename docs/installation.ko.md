<!-- translated-from: docs/installation.md; source-blob: 024f7a5ea37458a155fe687ee531b30e6be3a7c0 -->

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

<a id="runtime-dependencies"></a>

## 선택형 출력 준비 통합(v3.8+)

출력 파이프라인 실험은 명시적으로 선택합니다. 기존 scanner·규칙·정책·호스트
출력 계약을 유지하며 private 중간 파일과 JSON 준비를 통합합니다. 같은 릴리스의
사전 빌드 core를 설치하세요. 기존 core 파일이 준비와 치환을 모두 지원하므로
두 번째 helper나 컴파일러가 필요하지 않습니다. Git marketplace 설치에서도
호스트 캐시를 수정하지 않고 독립 설치의 helper를 사용할 수 있습니다.

Linux x64에서는 설치된 helper를 검증하고 파이프라인의 두 설정을 호스트 시작 환경에 노출합니다.

```sh
target=x86_64-unknown-linux-musl
native_root="$HOME/.agent-guard/libexec"
if (cd "$native_root" && shasum -a 256 -c "agent-guard-redact-$target.sha256"); then
  export AGENT_GUARD_EXPERIMENTAL_OUTPUT_PIPELINE=fused
  export AGENT_GUARD_EXPERIMENTAL_OUTPUT_PREPARE_BIN="$native_root/agent-guard-redact-$target"
fi
```

플랫폼에 맞는 target은 [네이티브 helper 안내(영어)](https://github.com/JeongJaeSoon/agent-guard/blob/v3.8.0/docs/native-redactor.md)에서 선택하세요.
Homebrew에서는 `native_root="$(brew --prefix agent-guard)/libexec/libexec"`로 설정합니다.
독립 설치와 Homebrew는 체크섬을 검증한 치환기를 자동 선택합니다.
소스만 있는 Git marketplace 플러그인은 치환도 같은 검증된 core에 연결하세요.

```sh
if (cd "$native_root" && shasum -a 256 -c "agent-guard-redact-$target.sha256"); then
  export AGENT_GUARD_RUST_CORE_BIN="$native_root/agent-guard-redact-$target"
fi
```

이 명시적 경로는 신뢰하는 실행 파일 재정의이므로 검증된 설치만 지정하세요.
준비 경로만 설정하면 해당 플러그인의 치환은 셸에 남으므로, 측정한 공유 core 구성과 다릅니다.
준비 helper가 없거나 실패하면 원래 jq 단계로 복귀하고, 실험 모듈이 없으면
원래 출력 파이프라인으로 복귀합니다. scanner와 준비 제한 시간은 바뀌지 않습니다.

시작 환경을 바꾼 뒤 Claude 또는 Codex를 재시작하세요. 기존 플러그인 설치·업데이트
명령은 같습니다. 기본 출력 파이프라인으로 복구하려면 다음 설정을 지우고 호스트를
재시작합니다.

```sh
unset AGENT_GUARD_EXPERIMENTAL_OUTPUT_PIPELINE
unset AGENT_GUARD_EXPERIMENTAL_OUTPUT_PREPARE_BIN
unset AGENT_GUARD_RUST_CORE_BIN
```

기존 기본 문자열 치환기 선택으로 돌아갑니다. 해당 native helper도 끄려면
`AGENT_GUARD_EXPERIMENTAL_REDACTOR=shell`을 사용하세요. 측정된 이득은 작업과
scanner에 따라 다르며 표본 프로세스 RSS 합이 늘 수 있습니다. 적용 전
[검증 안내](verification.ko.md)를 확인하세요.

## 실행 의존성

v3.7 릴리스 아카이브와 Homebrew 패키지에는 Linux/macOS x64/arm64용 Rust 문자열 치환기가 포함됩니다. Rust 컴파일러는 필요하지 않습니다. CLI는 해당 플랫폼의 체크섬을 검증한 치환기를 기본으로 사용하며, 바이너리가 없거나 실패하면 셸/jq로 복귀합니다. 탐지·정책·PII·호스트 어댑터는 셸에 남으므로 아래 의존성은 계속 필요합니다. 셸을 명시적으로 선택하려면 다음을 설정하세요.

```sh
export AGENT_GUARD_EXPERIMENTAL_REDACTOR=shell
```

Linux 치환기는 정적 musl을 사용해 glibc가 필요하지 않으며 Ubuntu 24.04에서 실제 실행을 검사합니다. macOS 치환기의 배포 대상은 macOS 14 이상이며 두 아키텍처 모두 macOS 15에서 검사합니다. 배포 대상 설정만으로 모든 이전 OS·커널의 실행이 입증되지는 않습니다. 미지원 환경은 셸 복귀를 유지합니다. 배포 체크섬은 손상을 탐지하며 바이너리와 체크섬이 함께 악의적으로 교체된 경우를 인증하지는 않습니다.

소스 아카이브와 호스트가 관리하는 Git marketplace 플러그인에는 바이너리가 없으므로 기존 `AGENT_GUARD_RUST_CORE_BIN`으로 신뢰하는 사전 빌드 치환기를 지정하지 않으면 셸을 사용합니다. 독립 설치의 치환기를 사용하면 호스트 캐시를 수정할 필요가 없습니다. 선택·체크섬 검증·개발자 재정의는 [네이티브 치환기 안내(영어)](https://github.com/JeongJaeSoon/agent-guard/blob/v3.8.0/docs/native-redactor.md)를 참고하세요.

macOS와 Linux에서 실행하려면 `sh`, `awk`, `git`, `jq`, gitleaks 8.30 이상이 필요합니다. gitleaks 버전 확인을 별도 프로세스 그룹에서 실행하기 위한 `setsid` 또는 Perl도 필요합니다. 이 격리로 버전 확인의 시간 제한과 자식 프로세스 정리를 보장합니다. Linux에서는 `sudo apt-get install -y util-linux` 또는 `sudo dnf install -y util-linux`로 `setsid`를 설치하세요. Homebrew formula는 CLI와 함께 Perl을 설치합니다. macOS에서 수동 설치했고 두 도구가 모두 없다면 `brew install perl`을 사용할 수 있습니다.

격리 도구가 없으면 `agent-guard setup`, `doctor`, `check`는 0이 아닌 종료 상태를 반환합니다. `setup --install`은 다운로드 전에 격리 도구 유무를 확인합니다. 도구가 없으면 gitleaks를 다운로드하거나 덮어쓰지 않고 누락 도구의 설치 명령을 출력하며, 도구를 설치한 뒤 gitleaks가 완전히 준비되었는지 다시 확인합니다. 실행 중인 hook은 이 상태를 정상 검사로 취급하지 않으며 `AGENT_GUARD_INFRA_FAILURE_MODE`의 `open` 또는 `closed` 정책을 적용합니다.

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

독립 설치는 다음과 같이 업데이트합니다.

```sh
agent-guard update
agent-guard version
agent-guard doctor
agent-guard check
```

플러그인 캐시에서는 updater를 의도적으로 사용할 수 없게 되어 있습니다. 실행 파일 자체가 marketplace 제거 시 삭제되는 캐시에 있어 스스로 marketplace의 고정 태그를 바꿀 수 없기 때문입니다. 대신 `agent-guard plugin update --host claude` 또는 `--host codex`를 실행하세요. 설치된 플러그인이 이미 CLI와 일치하면 최신 GitHub 릴리스를 조회하고, 새 버전으로 이동하는 정확한 host 관리 명령인 `marketplace remove`, `marketplace add ...@vX.Y.Z`, 플러그인 설치 명령을 출력합니다. `agent-guard doctor`와 `agent-guard plugin status`도 같은 릴리스 노후 상태를 보고합니다. 조회를 건너뛰려면 `AGENT_GUARD_RELEASE_CHECK=off`를 설정하세요. shell 블록은 캐시의 `current` 링크를 통해 실행되므로 플러그인 업데이트 후 `setup-shell`을 다시 실행할 필요가 없습니다.

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

각 경로를 소유한 관리 도구로 제거하세요. host 플러그인은 Claude Code 또는 Codex 플러그인 관리 도구를, Homebrew는 `brew uninstall JeongJaeSoon/tap/agent-guard`를 사용합니다. 독립 설치는 먼저 `agent-guard setup-shell`이 선택한 shell rc 파일에서 관리되는 shell integration 블록을 제거하세요. 다음 명령으로 경로를 확인한 뒤에만 공개 심볼릭 링크와 설치 디렉터리를 제거합니다.

```sh
command -v agent-guard
readlink "$(command -v agent-guard)"
```

플러그인 관리 도구의 캐시를 수동으로 삭제하지 마세요. 수명주기는 host가 관리합니다. 제거 후 새 shell을 열어 `command -v agent-guard`가 예상대로 해석되는지 확인하세요. 다른 설치가 남아 있다면 해당 설치의 `version`, `doctor`, `check`를 실행합니다.
