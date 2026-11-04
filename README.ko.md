<!-- translated-from: README.md; source-blob: f5b84578e7b4a21fc467c55f0d61fda258c7b9a7 -->

<p align="center">
  <a href="https://github.com/JeongJaeSoon/agent-guard/releases"><img src="docs/assets/icon.png" alt="Agent Guard icon" width="128" height="128"></a>
</p>

<h1 align="center">Agent Guard</h1>

<p align="center">
  <a href="https://github.com/JeongJaeSoon/agent-guard/actions/workflows/ci.yml"><img src="https://github.com/JeongJaeSoon/agent-guard/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/JeongJaeSoon/agent-guard/releases/latest"><img src="https://img.shields.io/github/v/release/JeongJaeSoon/agent-guard" alt="Latest release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/JeongJaeSoon/agent-guard" alt="MIT license"></a>
</p>

[English](README.md) · 한국어 · [日本語](README.ja.md)

**AI 코딩 에이전트의 비밀 정보 유출을 막는 로컬 우선 보호 도구입니다.**

> 위험한 `.env` 읽기를 차단하고, 비밀 정보로 보이는 출력을 마스킹하며, 변경 내용이 Git에 들어가기 전에 검사합니다. 호스팅 계정과 원격 분석 수집 기능이 없습니다.

이 문서는 [영어 정본](README.md)의 한국어 번역입니다. 아래 설치·검증 안내는 한국어로 제공하며, 그 외 상세 문서는 영어로 연결됩니다.

---

Agent Guard는 Claude Code, Codex, Git hook, GitHub Actions와 직접 실행하는 shell 명령에 적용하는 로컬 우선 보호 도구입니다. 지원하는 도구의 실행 전에 흔한 비밀 정보 노출 경로를 차단하고, 지원하는 도구 출력을 마스킹하며, 파일을 수정한 뒤 변경 파일을 검사합니다. `gitleaks`와 이식 가능한 shell을 사용하며, 호스팅 계정·원격 분석 수집기·개발자 서비스가 없습니다.

여러 방어 계층 중 하나로 사용하세요. GitHub Secret Scanning, Push Protection, 리뷰와 일반적인 자격 증명 관리도 계속 유지해야 합니다. Agent Guard는 비밀 저장소, DLP 시스템, EDR 또는 자격 증명 교체 도구가 아닙니다.

![Claude Code의 Agent Guard: 에이전트가 Bash의 `cat`과 Read로 비밀 키가 든 .env를 읽으려 하면 차단되며, shell integration을 활성화한 상태에서 사용자가 직접 실행한 `! cat .env`는 키를 [REDACTED]로 표시합니다](docs/demo.gif)

<a id="keep-secrets-out-of-git"></a>

## 비밀 정보가 Git에 들어가기 전에 차단

키가 커밋에 들어가면 파일에서 지워도 Git 이력에 오래 남습니다. Agent Guard는 hook이 적용되는 커밋 경로 앞에서 gitleaks 검사를 실행합니다. API 키, 토큰 또는 `.env` 값이 탐지되면 이력에 들어가기 전에 차단하고, CI가 그 뒤에서 추가 방어를 제공합니다.

| 커밋 주체 | 유출을 막는 방식 |
| --- | --- |
| Claude Code 또는 Codex의 에이전트 | 에이전트의 `git commit` 또는 `git push` 실행 전에 스테이징된 추가 줄을 검사하고, 비밀 정보로 보이는 값이 있으면 명령을 차단합니다. 해당 명령의 `--no-verify`와 `--no-gpg-sign`도 거부하므로 에이전트가 플래그로 검사를 끌 수 없습니다. |
| 사용자 또는 에이전트가 실행하는 모든 로컬 커밋 | [네이티브 pre-commit hook](docs/integrations.md#native-git-hook)을 설치하면 Git이 커밋 대상 전체를 스테이징한 뒤 추가 줄을 검사하며, 탐지되거나 검사를 실행할 수 없으면 커밋을 중단합니다. Git은 `git commit --no-verify`에서 hook을 건너뜁니다. 플러그인은 에이전트의 해당 플래그 사용을 거부하고, 나머지는 CI가 보완합니다. |
| 누구든 push한 뒤 | [GitHub Action](docs/integrations.md#github-actions)이 실행 대상 push 또는 pull request에서 체크아웃된 파일을 저장소의 추가 방어 계층으로 검사합니다. |

플러그인은 커밋에 포함될 내용을 검사합니다. 인덱스뿐 아니라 `git commit -a`, `--patch`, `git commit <path>` 같은 pathspec, `--include`, `--only`에서 Git이 직접 스테이징하는 추적 파일 변경과 `--interactive`로 추가할 수 있는 미추적 파일도 포함합니다. `git commit $FLAGS`처럼 인자가 실행 시점에 결정되거나 같은 명령이 먼저 `git add`를 실행하면, 추적 파일의 모든 변경과 미추적 파일을 검사합니다. `git add -f`로 추가하는 무시 파일도 포함합니다. `bash -c`, `sh -c`, here-string, `env -S`, `eval`에 전달한 shell 코드도 명령 자체처럼 검사합니다. Git alias가 확장하는 명령은 해당 실행이 읽을 설정에서 가져와 검사합니다. 코드, Git 하위 명령, alias 또는 작업 디렉터리가 실행 시점에만 결정되면 커밋 대상을 판단할 수 없으므로 아래 인프라 정책을 적용합니다. `!` shell alias, `help.autoCorrect`가 실행할 수 있는 추정 명령, 같은 명령의 앞부분에서 변경했을 수 있는 alias도 여기에 해당합니다.

플러그인은 명령이 시작될 때의 파일을 검사합니다. 같은 명령의 앞부분에서 파일을 쓰거나 다른 저장소로 이동하면 그 결과를 보지 못하므로 네이티브 hook도 설치하세요. push 검사는 이미 존재하는 커밋 대신 스테이징된 내용을 확인합니다. 이 hook 밖에서 커밋된 비밀 정보는 체크아웃된 트리에 남아 있는 동안 CI가 탐지합니다.

검사를 실행하지 못한 상태를 정상으로 취급하지 않습니다. Claude Code와 Codex 플러그인의 기본 동작은 보호 수준 저하를 경고한 뒤 명령을 계속 실행하는 것이며, `AGENT_GUARD_INFRA_FAILURE_MODE=closed`를 설정하면 차단합니다([설정](docs/configuration.md) 참고). 네이티브 hook과 Action은 이 설정과 무관하게 검사를 실행할 수 없으면 실패합니다. Claude Code 2.1.295 이상에서는 검사 결정 전에 hook이 시간 초과되거나 비정상 종료되어도 두 모드 모두 도구 호출을 차단합니다.

<a id="choose-your-path"></a>

## 필요한 안내 선택

| 필요한 작업 | 시작할 문서 |
| --- | --- |
| Claude Code·Codex 플러그인, CLI, Git hook 또는 Action 설치 | [설치](docs/installation.ko.md) |
| host별 지원 범위와 연동 설정 이해 | [연동](docs/integrations.md) |
| 출력 마스킹이 적용되는 도구 경로와 host별 차이 확인 | [출력 마스킹 범위](docs/integrations.md#output-masking-coverage) |
| 설치 검증과 결과가 입증하는 범위 이해 | [검증](docs/verification.ko.md) |
| 정책·PII·마스킹·인프라 동작 설정 | [설정](docs/configuration.md) |
| 조직 배포 또는 환경 문제 해결 | [운영](docs/operations.md). [한국어·일본어 배포 안내](https://agent-guard-guide.jaesoon.chatgpt.site/)는 현재 공개된 보조 설명입니다. |

<a id="quick-use"></a>

## 빠른 사용

플러그인 설치 후 안내형 설정을 실행하세요.

```text
# Claude Code
/agent-guard:setup-agent-guard

# Codex
$setup-agent-guard
```

이 설정은 로컬 의존성을 확인하고 합성 검사를 실행합니다. 현재 host의 도구 경로가 hook을 호출한다는 증거는 아닙니다. 플러그인의 보호 경계에 의존하기 전에 [검증](docs/verification.ko.md)의 무해한 실제 호출 검사를 완료하세요.

저장소를 직접 검사하려면 다음을 실행합니다.

```sh
agent-guard scan-working-tree
agent-guard scan-staged
agent-guard scan-path .
```

<a id="support-log"></a>

## 지원용 로그

다음 명령으로 메타데이터만 담긴 로컬 지원 로그를 저장합니다.

```sh
agent-guard logs export --output agent-guard-support.jsonl
```

상위 디렉터리가 미리 존재해야 합니다. Agent Guard는 권한이 0600인 새 파일을 만들고 기존 파일이나 심볼릭 링크를 덮어쓰지 않습니다. 플러그인만 설치해 `PATH`에서 `agent-guard`를 찾을 수 없으면 설정 스킬이 출력하는 플러그인 내부 실행 파일을 사용하세요. 제출할 정보는 [지원 안내](SUPPORT.md)를 참고하세요.

<a id="requirements-and-scope"></a>

## 요구 사항과 범위

릴리스 아카이브와 Homebrew 패키지는 체크섬 검증과 셸 복귀를 갖춘 사전 빌드 Rust 문자열 치환기를 사용합니다. Rust는 실행 의존성이 아니며 탐지·정책·호스트 어댑터는 셸에 남습니다. Git marketplace 플러그인은 소스로만 배포합니다. 플랫폼 조건, 명시적 셸 선택과 사전 빌드 치환기 사용은 [설치 안내](docs/installation.ko.md)를 참고하세요.

지원 플랫폼은 x64·arm64의 macOS와 Linux입니다. 실행 의존성은 `sh`, `awk`, `git`, `jq`, gitleaks 8.30 이상입니다. 현재 Windows는 지원하지 않습니다. gitleaks 버전 확인을 별도 프로세스 그룹에서 실행하려면 Linux `util-linux`의 `setsid` 또는 Perl 중 하나도 필요합니다. `agent-guard doctor`는 격리 도구가 없으면 플랫폼별 설치 명령을 표시합니다.

기본 처리는 로컬에서 일시적으로 이루어집니다. 엔드포인트를 사용하는 PII 제공자를 활성화하기 전에 [개인정보 처리](PRIVACY.md)를 읽으세요. 책임 있는 취약점 제보는 [보안 정책](SECURITY.md), 안전한 문제 보고는 [지원 안내](SUPPORT.md)를 참고하세요.

<a id="project-documents"></a>

## 프로젝트 문서

- [개인정보와 데이터 처리](PRIVACY.md)
- [보안 정책](SECURITY.md)
- [지원](SUPPORT.md)
- [서드파티 고지](THIRD_PARTY_NOTICES.md)
- [변경 이력](CHANGELOG.md)
- [알려진 한계](docs/integrations.md#limits-and-backstops)

Agent Guard가 대화 기록에 비밀 정보가 남는 일을 막아 줬다면 [개발 후원](https://github.com/sponsors/JeongJaeSoon)을 고려해 주세요.
