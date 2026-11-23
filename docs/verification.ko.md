<!-- translated-from: docs/verification.md; source-blob: dc328e0916406cfacfd27d5fe19f50cad28df970 -->

<a id="verification"></a>

# 검증

[English](verification.md) · 한국어 · [日本語](verification.ja.md)

이 문서는 [영어 정본](verification.md)의 한국어 번역입니다. 설치 절차는 [한국어 설치 안내](installation.ko.md)를 참고하세요. 그 외 상세 문서는 영어로 연결됩니다.

의존성, 결정적인 동작, 실제 host의 hook 호출은 각각 별도의 증거로 확인하세요. 앞 단계의 통과가 다음 단계를 입증하지는 않습니다.

정확한 matcher, host별 치환 계약과 시간 제한은 [출력 마스킹 범위](integrations.md#output-masking-coverage)에 정리되어 있습니다. 플러그인 업데이트, hook 신뢰 변경 또는 host 업그레이드 후에는 의존하는 모든 경로에서 아래 실제 호출 검사를 다시 실행하세요.

| 증거 | 명령 또는 동작 | 입증하는 내용 | 입증하지 못하는 내용 |
| --- | --- | --- | --- |
| 의존성 확인 | `agent-guard check` 또는 `agent-guard doctor` | 필요한 로컬 명령과 정책 파일을 사용할 수 있음 | host가 hook을 호출하는지 여부 |
| 합성 검사 | `agent-guard smoke-test` | 함께 제공되는 차단·scanner·마스킹 경로가 함께 동작함 | 설치된 플러그인이나 현재 경로가 이를 사용하는지 여부 |
| 로컬 저장소 검사 | `scan-staged`, `scan-working-tree` 또는 `scan-path` | 선택한 현재 저장소 또는 경로를 검사했음 | 이후 도구 호출이나 검사 범위 밖의 무시된 경로 |
| 실제 host 검사 | 일반 host 경로를 통한 무해한 검사 | 그 정확한 경로가 기대한 hook을 호출했음 | 다른 도구, wrapper 또는 host |

<a id="plugin-acceptance"></a>

## 플러그인 수용 검사

1. host의 안내형 설정 또는 플러그인 내부의 `check`와 `smoke-test`를 실행하세요.
2. 플러그인을 업데이트할 때마다 hook이 활성화되고 신뢰되었는지 확인하세요.
3. 사용자가 실제로 쓸 경로와 같은 경로에서 도구 실행 전 검사용 sentinel을 실행하세요.

   ```sh
   printf '%s\n' 'AGENT_GUARD_LIVE_PRE_TOOL_PROBE'
   ```

   sentinel이 출력되기 전에 guard가 차단해야 합니다.

4. 같은 경로에서 도구 실행 후 검사를 실행하세요. 이 명령은 검사 대상 실행 파일에서 sentinel을 읽으므로 독립적으로 실행할 수 있습니다. 이 문서에는 별도 sentinel 복사본을 두지 않아 원본과 어긋나지 않습니다.

   ```sh
   GUARD=$(command -v agent-guard)   # or the plugin-local bin/agent-guard path
   printf '%s\n' "$(sed -n 's/^LIVE_POST_TOOL_PROBE=//p' "$GUARD" | head -1)"
   ```

   원문 sentinel이 모델에 전달되어서는 안 됩니다. 치환 결과에는 `[REDACTED]`가 남아야 하며, 로컬 진단 로그가 켜져 있으면 치환한 hook 호출도 식별해야 합니다.

   ```text
   [REDACTED] agent-guard live probe run_id=<run id>
   ```

   명령에 `[REDACTED]`를 직접 입력하지 마세요. 그렇게 하면 마스킹도 hook 호출도 검사하지 못합니다.

5. 보고된 run id를 사용자가 직접 터미널에서 진단 로그와 대조하세요.

   ```sh
   agent-guard logs export \
     | jq -c 'select(.run_id == "<run id>" and .command == "hook-post-tool")'
   ```

   `"outcome":"masked"`가 포함된 `finished` 기록은 해당 설치가 그 시점에 sentinel을 치환했음을 보여 줍니다. 이 단계만이 에이전트의 보고 내용에 의존하지 않으므로 run id에 해당하는 기록이 없으면 검사 실패로 취급하세요. 로그는 메타데이터만 담고 도구 이름은 기록하지 않습니다. 따라서 해당 기록은 PostToolUse 치환을 입증할 뿐, 어느 도구 경로를 거쳤는지까지 입증하지 않습니다. 실제로 실행한 경로와 함께 판단하세요. `AGENT_GUARD_LOG_MODE=off`에서는 인용할 로그가 없고 치환 결과도 `[REDACTED]`만 남습니다.

sentinel에는 자격 증명이 없습니다. host의 hook 호출만 검사하며, 결정적인 정책 동작은 `smoke-test`가 별도로 확인합니다.

sentinel이 들어 있는 파일을 읽는 것도 guard가 보호하는 도구 호출입니다. 따라서 설정 스킬 자체의 검사 명령 줄도 이미 치환된 채로 반환됩니다. 이는 hook이 작동한 결과이며, 저장소에 placeholder를 커밋해 둔 것이 아닙니다. 확인이 필요하면 해당 줄과 placeholder의 바이트 길이를 비교하세요.

<a id="claude-code-code-mode"></a>

## Claude Code Code Mode

Code Mode에서는 Claude가 JavaScript를 작성해 한 번에 여러 도구를 호출합니다. 코드가 호출하는 도구는 각자의 이름으로 `PreToolUse`와 `PostToolUse`를 거치므로 위 검사로 확인됩니다. 코드가 돌려주는 값은 위 검사가 다루지 않는 두 경로로 모델에 전달됩니다. 코드가 끝나거나 예외를 던질 때의 `REPL`과, 그 출력이 전달될 때의 `Poll`입니다. Claude Code 2.1.330에서 확인했습니다.

1. Claude에게 도구 실행 후 검사를 실패하는 호출로 코드에서 실행해 달라고 요청하세요. host는 실패한 호출의 출력을 어떤 hook도 치환하지 못하게 하므로 코드는 원문 sentinel을 받습니다. 그 값이 모델에 전달되는 것은 `REPL`이나 `Poll` hook만 막을 수 있습니다.

   ```js
   const guard = '/absolute/path/to/bin/agent-guard';
   const probe = await $`sed -n 's/^LIVE_POST_TOOL_PROBE=//p' ${guard} | head -1; exit 3`.nothrow();
   probe.stdout
   ```

   위 4단계와 같은 치환 결과가 나와야 합니다. 원문 sentinel이 보이면 두 hook 모두 실행되지 않은 것입니다. 설치된 `PostToolUse` matcher에 `REPL`과 `Poll`이 있는지 확인하세요.

2. 같은 명령을 `.nothrow()` 없이 실행해 코드가 예외를 던지게 하세요. Claude가 읽는 오류에는 host가 덧붙이는 실패한 호출의 출력까지 포함해 치환 결과가 들어 있어야 합니다.

3. 보고된 run id는 위 5단계와 같은 방법으로 대조하세요.

코드가 받은 값을 디스크의 파일과 비교할 때는 `wc -c < file`이나 `shasum < file`처럼 셸 통합이 감싸지 않는 명령으로 기대 크기나 해시를 계산하세요. Claude Code 안에서 `cat`과 `head`는 마스킹된 결과를 돌려주고, 마스킹된 결과끼리는 항상 일치합니다.

이 검사는 코드가 돌려준 값이 마스킹된다는 것을 보여 줍니다. host의 두 가지 한계는 그대로입니다. 실패한 호출의 출력과, 성공한 출력에서 약 30,000자를 넘는 부분은 마스킹 없이 코드에 전달됩니다. 코드가 보관한 값은 코드가 그 값을 돌려주거나 다른 도구 호출에 넘길 때에만 다시 검사됩니다.

<a id="read-results-correctly"></a>

## 결과를 올바르게 해석하기

- JSON 도구가 정상 종료해도 직렬화된 출력이 완전하다는 뜻은 아닙니다.
  PostToolUse의 중간 출력을 안전하게 치환할 수 없으면 보존된 원본 이벤트로
  보수적인 복구를 시도합니다. 독립 parser가 성공하면 중첩 응답 구조를
  유지하며, 검사 실패를 정상 검사로 취급하지 않습니다.
- 비밀 정보 탐지는 차단 또는 탐지 결과이며 scanner 오류가 아닙니다.
- `DEGRADED` 메시지나 사용할 수 없는 scanner는 정상 검사 결과가 아닙니다. 의존성을 복구하거나 문서에 명시된 인프라 정책을 선택하세요.
  `Scanner readiness: timeout.`이 함께 나오면 시간 제한이 있는 버전 확인이
  초과된 것입니다. 다른 고정 준비 코드는 지원하지 않는 버전이나 probe 실패를
  구분합니다. 진단에는 scanner 출력이나 입력 경로를 넣지 않습니다. timeout
  코드는 실패한 단계를 알려 주며, 느려진 원인까지 설명하지는 않습니다.
  SessionStart를 제외한 hook은 시간 초과된 버전 확인을 한 번 다시 시도합니다.
  따라서 그 hook에서 이 코드는 버전 확인이 연속 두 번 시간 초과했다는 뜻입니다.
- `open` 인프라 모드는 눈에 보이는 일회성 경고 후 계속 실행하며 `closed`는 차단합니다. 이는 인프라 장애에 대한 정책이며 비밀 정보를 탐지하면 차단합니다. 비어 있지 않으면서 형식이 잘못되었거나 객체가 아닌 PreToolUse·Stop 입력은 인프라 모드와 무관하게 차단합니다. PostToolUse는 먼저 독립된 parser로 유효한 host envelope를 복구하고 보수적인 치환 결과를 출력합니다. 비어 있지 않으면서 형식이 잘못되었거나 객체가 아닌 PostToolUse envelope의 종료 상태 2는 눈에 보이는 진단이며, 이미 완료된 도구 결과를 되돌릴 수는 없습니다. `closed`에서는 출력을 검사하지 못한 Claude의 PostToolUse hook이 그 출력의 비어 있지 않은 문자열을 모두 치환하고 구조는 유지합니다. 종료 상태 2만으로는 출력이 모델에 그대로 전달되기 때문입니다. 빈 stdin은 문서화된 예외입니다. PreToolUse, PostToolUse, Stop 모두 응답 없이 종료 상태 0을 반환합니다. 거부한 이벤트는 모두 보고합니다.
- host가 시간 제한에 도달한 hook을 종료하면 hook이 판단하지 못할 수 있습니다. Claude Code 2.1.295 이상은 `PreToolUse` hook의 시간 초과나 비정상 종료 시 도구 호출을 차단합니다. 다른 이벤트와 host에는 해당하지 않습니다. Git과 CI의 추가 방어를 유지하세요.

직접 검사 명령(`scan-staged`, `scan-working-tree`, `scan-path`)은 인프라 정책을 적용하는 대신 호출자에게 종료 상태를 반환합니다.

| 종료 상태 | 의미 |
| --- | --- |
| `0` | 검사한 입력에서 아무것도 탐지되지 않았습니다. |
| `1` | 비밀 정보로 보이는 값이 탐지되었습니다. 탐지 결과는 마스킹되므로 메시지는 값 대신 검사한 입력을 식별합니다. |
| `2` | `scan-path` 인자나 경로 누락 같은 사용법 오류 또는 `scan-staged`·`scan-path` 실행 중 gitleaks 오류입니다. |
| `3` | 검사를 실행하지 못했습니다. gitleaks나 gitleaks 설정이 없거나, Git 저장소가 아니거나, `git diff`가 실패했거나, 입력이 검사 예산을 넘었습니다. |

`2`와 `3`은 항상 검사하지 못한 상태로 취급하고 정상으로 간주하지 마세요.

<a id="routine-checks"></a>

## 정기 확인

warm gitleaks helper는 링크한 공식 gitleaks 릴리스와 비교해 검증합니다. 릴리스
workflow는 플랫폼별 릴리스 아카이브로 실패 경로·host·차분 테스트를 돌리고, 두
바이너리가 `plugins/agent-guard/config/gitleaks-helper.sha256`의 SHA-256 값과
맞을 때만 아카이브를 게시합니다. 이 값은
`agent-guard setup --install-gitleaks-helper`가 요구하는 값입니다. 빌드는 재현할
수 있어서, 소스 checkout에서 `sh scripts/build-gitleaks-helper.sh --print-pins`를
실행하면 같은 줄이 나옵니다. 설치된 helper를 직접 확인하려면 기록된 checksum과
비교하고, 소스 checkout에서 공식 릴리스 바이너리(helper가 일부러 거절하는
Homebrew·`go install` 빌드가 아닌 것)로 테스트를 실행하세요.

```sh
(cd "$HOME/.agent-guard/bin/gitleaks-helper" && shasum -a 256 -c SHA256SUMS)
AGENT_GUARD_TEST_HELPER_DIR="$HOME/.agent-guard/bin/gitleaks-helper" \
AGENT_GUARD_TEST_REAL_GITLEAKS="$(command -v gitleaks)" sh tests/gitleaks-helper.sh
AGENT_GUARD_TEST_HELPER_DIR="$HOME/.agent-guard/bin/gitleaks-helper" \
AGENT_GUARD_TEST_REAL_GITLEAKS="$(command -v gitleaks)" sh tests/gitleaks-helper-corpus.sh
```

helper의 상태는 `agent-guard setup`이 출력합니다. 쓰이는 동안 실행 중인 helper는
`agent-guard-gitleaks-helper serve` 프로세스
하나와 `$XDG_STATE_HOME/agent-guard/gitleaks-helper`(또는 `~/.local/state/...`)
아래의 소켓으로 보입니다. 이것이 없다는 것은 스캔이 실제 gitleaks로 돈다는 뜻일
뿐입니다.

```sh
agent-guard doctor
agent-guard smoke-test
agent-guard scan-working-tree
```

Codex에서는 hook UI에서 변경된 hook을 다시 검토하세요. Claude Code에서는 설치나 shell rc 변경 후 플러그인을 다시 로드하고 세션을 재시작하세요.
