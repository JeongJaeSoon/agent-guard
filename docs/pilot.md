# Agent Guard 소규모 조직 배포 매뉴얼

이 문서는 Claude Code 중심의 macOS/Linux 소규모 내부 파일럿 절차입니다. 공개
설치 안내는 [Installation](installation.md), 보장 범위는
[Integrations](integrations.md)를 기준으로 합니다. 한 호스트 또는 한 도구 경로의
성공을 다른 경로의 성공으로 간주하지 않습니다.

## 1. 관리자 배포

1. 파일럿 대상 사용자, Claude Code 버전, 저장소를 정합니다.
2. macOS는 `/Library/Application Support/ClaudeCode/managed-settings.json`,
   Linux/WSL은 `/etc/claude-code/managed-settings.json`에
   [`deployment/claude-managed-settings.example.json`](../deployment/claude-managed-settings.example.json)의
   키를 기존 JSON과 병합합니다.
3. marketplace `ref`는 위 배포 예제 JSON에 기록된 검토한 release tag로 고정합니다. `ref`는
   branch/tag만 지원하므로 commit SHA를 넣지 않습니다. 자동 업데이트는 끄고,
   다음 tag 변경은 별도 변경으로 검토합니다.
4. 비밀값 보호를 우선하는 파일럿은 managed settings의 `env`에
   `AGENT_GUARD_INFRA_FAILURE_MODE=closed`를 명시합니다. 제품 기본값은
   `open`이므로 설정을 생략하면 검사 인프라가 실패해도 계속 진행할 수 있습니다.
   `AGENT_GUARD_PII_HOOK_MODE=off`는 유지합니다. metadata log는 v3.3.0 이후
   release에 도입되며, 포함된 release에서만 default-on입니다. PII endpoint는 별도
   개인정보 검토와 동의 없이 켜지 않습니다. log가 포함된 release에서 로그를
   금지해야 하는 조직만 `AGENT_GUARD_LOG_MODE=off`를 설정합니다.
5. 각 기기에 `sh`, `awk`, `git`, `jq`, gitleaks가 있는지 확인합니다.
6. Codex를 함께 시험하는 경우 변경된 훅을 정의별로 검토하고 신뢰 처리합니다.
   플러그인 설치만으로 훅이 실행되는 것은 아닙니다.
7. 파일럿 기간에도 Git hook 또는 GitHub Actions를 저장소 backstop으로 유지합니다.

기존 managed settings에 병합할 파일럿 환경 설정은 다음과 같습니다.

```json
{
  "env": {
    "AGENT_GUARD_INFRA_FAILURE_MODE": "closed",
    "AGENT_GUARD_PII_HOOK_MODE": "off"
  }
}
```

## 2. 사용자 설정

1. 사용자는 host setup을 실행합니다.
   - Claude Code: `/agent-guard:setup-agent-guard`
   - Codex: `$setup-agent-guard`
2. 의존성 설치 요청은 사용자가 검토 후 승인합니다. lifecycle hook이 임의로
   설치하지 않습니다.
3. Claude shell 통합을 쓰는 사용자는 `/agent-guard:setup-shell`을 실행합니다.
   이 skill은 plugin-local binary를 사용하므로 PATH의 다른 CLI를 쓰지
   않습니다. host가 rc write를 승인할 수 없으면 skill이 보여 준 정확한
   plugin-local 명령을 terminal에서 실행합니다. 이후 셸과 Claude session을
   다시 시작합니다.
4. `doctor`와 `smoke-test` 결과를 기록합니다.

## 3. 수용 기준: 네 종류의 증거

| 구분 | 수행 | 통과 의미 |
| --- | --- | --- |
| 의존성 | `check` 또는 `doctor` | 로컬 실행 조건이 준비됨 |
| 합성 검증 | `smoke-test` | 번들 정책·스캐너·마스킹이 결정적으로 동작함 |
| 저장소 검증 | `scan-working-tree` | 선택한 현재 저장소 범위를 스캔함 |
| LIVE 호스트 검증 | 실제 도구 경로로 harmless probe 실행 | 그 정확한 경로가 hook을 dispatch함 |

LIVE pre-tool probe는 `AGENT_GUARD_LIVE_PRE_TOOL_PROBE`를 출력하려는 harmless
명령을 차단해야 합니다. LIVE post-tool probe는 setup skill이 제공하는 synthetic
raw test token을 출력하고, 모델에는 `[REDACTED]`가 포함된 sanitized replacement만
도착해야 합니다. literal `[REDACTED]`를 숨기는 시험으로 해석하지 않습니다.
자세한 명령은 [Verification](verification.md)를 사용합니다.

`DEGRADED`, scanner error, timeout, trust 미완료는 통과가 아닙니다. 원인을
수정한 뒤 다시 검증합니다. 이 파일럿의 `closed` 정책을 `open`으로 낮춰 수용
검사를 통과 처리하지 않습니다. 호스트가 hook을 timeout으로 종료하는 경우에는
`closed` 설정만으로 실행을 통제할 수 없으므로 확대를 중단합니다.

## 4. 파일럿 지원 요청

다음 메타데이터만 제출합니다: Agent Guard 버전, host, command/event 분류,
outcome, start/finish 시각, OS/architecture, run_id, 수동으로 정리한 오류 요약.
원문 prompt, tool payload, stderr 전문, 경로, 환경 변수, host session ID,
비밀값은 제출하지 않습니다.

metadata log는 v3.3.0 이후 release에서 제공됩니다. 해당 버전에서는
`agent-guard logs export`의 출력만
첨부하고 `agent-guard logs status`로 상태를 확인합니다. 로그에는 random local
invocation correlation용 run_id가 있지만 host session ID는 없습니다. 내용·경로·
환경 변수·임의 tool name은 기록하지 않습니다. `pass`는 차단 없이 반환되었다는
뜻일 뿐 clean scan 또는 모든 경로의 보호를 증명하지 않습니다.

### 복사해 보낼 공지

> Agent Guard 파일럿을 시작합니다. Claude Code에서
> `/agent-guard:setup-agent-guard`와 `/agent-guard:setup-shell`을 실행한 뒤
> `doctor`, `smoke-test`, LIVE pre/post probe를 완료해 주세요. `DEGRADED`, timeout,
> 또는 raw probe 출력은 통과가 아닙니다. 지원 요청에는 `agent-guard logs export`
> 출력과 수동으로 정리한 요약만 보내고, prompt·transcript·stderr 전문·경로·비밀값은
> 보내지 마세요.

### 결과 템플릿

| Tester | OS / host | Dependency | Synthetic | LIVE pre | LIVE post | Git/CI backstop | Decision |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 이름 | macOS/Linux, Claude Code version | pass/fail | pass/fail | pass/fail | pass/fail | 확인 결과 | continue/hold |

## 5. 단계적 확대와 중단

1. 2–3명의 pilot에서 위 표의 네 증거를 채웁니다.
2. Claude Code primary route가 모두 통과하고 Git/CI backstop이 확인되면 다음
   소규모 그룹으로 확대합니다.
3. raw probe가 보이거나, hook trust가 풀리거나, `DEGRADED`가 복구되지 않거나,
   secret detection이 예상 밖으로 우회되면 확대를 중단합니다.
4. rollback은 managed settings의 Agent Guard marketplace/plugin keys를 이전
   검토 release tag로 되돌린 뒤 host를 restart합니다. 사용자 shell 통합은
   `agent-guard setup-shell --no-command-wrapping`으로 wrapping을 끄거나,
   plugin update를 owning host manager로 되돌린 후 setup-shell을 다시 실행합니다.
   Git/CI backstop은 rollback 중에도 유지합니다.
