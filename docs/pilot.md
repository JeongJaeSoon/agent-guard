# Agent Guard 내부 파일럿 운영 매뉴얼

이 문서는 Claude Code 중심의 macOS/Linux 소규모 내부 파일럿 절차입니다. 공개
설치 안내는 [Installation](installation.md), 보장 범위는
[Integrations](integrations.md)를 기준으로 합니다. 파일럿에서 한 호스트의 성공을
다른 호스트 또는 다른 도구 경로의 성공으로 간주하지 않습니다.

## 1. 관리자 배포

1. 파일럿 대상 사용자, Claude Code 버전, 저장소를 정합니다.
2. 검토한 플러그인/Action 버전과 gitleaks 체크섬을 배포 정책에 고정합니다.
3. 각 기기에 `sh`, `awk`, `git`, `jq`, gitleaks가 있는지 확인합니다.
4. Codex를 함께 시험하는 경우 변경된 훅을 정의별로 검토하고 신뢰 처리합니다.
   플러그인 설치만으로 훅이 실행되는 것은 아닙니다.
5. 파일럿 기간에도 Git hook 또는 GitHub Actions를 저장소 backstop으로 유지합니다.

## 2. 사용자 설정

1. 사용자는 host setup을 실행합니다.
   - Claude Code: `/agent-guard:setup-agent-guard`
   - Codex: `$setup-agent-guard`
2. 의존성 설치 요청은 사용자가 검토 후 승인합니다. lifecycle hook이 임의로
   설치하지 않습니다.
3. Claude shell 통합을 쓰는 사용자는 별도로 setup-shell을 실행하고 셸과
   세션을 다시 시작합니다.
4. `doctor`와 `smoke-test` 결과를 기록합니다.

## 3. 수용 기준: 네 종류의 증거

| 구분 | 수행 | 통과 의미 |
| --- | --- | --- |
| 의존성 | `check` 또는 `doctor` | 로컬 실행 조건이 준비됨 |
| 합성 검증 | `smoke-test` | 번들 정책·스캐너·마스킹이 결정적으로 동작함 |
| 저장소 검증 | `scan-working-tree` | 선택한 현재 저장소 범위를 스캔함 |
| LIVE 호스트 검증 | 정상 작업에서 쓰는 실제 도구 경로로 harmless probe 실행 | 그 정확한 경로가 hook을 dispatch함 |

LIVE pre-tool probe는 `AGENT_GUARD_LIVE_PRE_TOOL_PROBE`를 출력하려는 harmless
명령을 차단해야 합니다. LIVE post-tool probe는 `[REDACTED]` marker가 모델에
원문 출력으로 전달되지 않는지 확인합니다. 자세한 명령은
[Verification](verification.md)를 사용합니다.

`DEGRADED`, scanner error, timeout, trust 미완료는 통과가 아닙니다. 원인을
수정하거나 `AGENT_GUARD_INFRA_FAILURE_MODE=closed` 정책으로 명시적으로
차단할지 결정합니다. 기본 `open`은 경고 후 계속하지만 clean scan 증거가
아닙니다.

## 4. 파일럿 지원 요청

다음 메타데이터만 제출합니다: Agent Guard 버전, host, command/event 분류,
outcome, 시작·종료 시각, OS/architecture, 수동으로 정리한 오류 요약. 원문
prompt, tool payload, stderr 전문, 경로, 환경 변수, session ID, 비밀값은
제출하지 않습니다.

메타데이터 로그가 제공되는 버전에서는 `agent-guard logs export`의 출력만
첨부합니다. 이 로그는 내용·경로·환경 변수·session ID·임의 tool name을
기록하지 않습니다. `pass`는 차단 없이 반환되었다는 뜻일 뿐 clean scan 또는
모든 경로의 보호를 증명하지 않습니다.

## 5. 종료 판단

관리자는 호스트별 LIVE 경로, 실패/복구 여부, Git/CI backstop, 미해결 제한을
표로 정리합니다. 검증한 경로와 검증하지 못한 경로를 분리해 다음 확대 여부를
결정합니다.
