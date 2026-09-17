# 도구 출력 마스킹의 범위와 검증 경계

이 문서는 Agent Guard의 도구 출력 마스킹이 어디까지 도달하고, 어떤
조건에서 보호가 성립하며, 무엇을 별도로 실기기에서 확인해야 하는지에
대한 단일 사실원이다. 호스트의 훅 계약은 바뀔 수 있으므로 플러그인 업데이트,
훅 trust 변경, 호스트 업그레이드 뒤에는 [검증 절차](#검증-절차)를 다시 수행한다.

## 증거 라벨

| 라벨 | 의미 |
| --- | --- |
| **REPOSITORY-VERIFIED** | 현재 `scripts/render-hook-manifests.sh`, 생성된 네 manifest, CLI 구현, `tests/run.sh`로 확인한 저장소 내부 사실 |
| **OFFICIAL-CONTRACT** | 2026-09-18에 확인한 [Claude Code hooks](https://code.claude.com/docs/en/hooks) 또는 [Codex hooks](https://learn.chatgpt.com/docs/hooks)가 명시한 호스트 계약 |
| **IMPLEMENTATION-GUARANTEED** | 해당 matcher가 실제로 선택되고 훅 프로세스가 timeout이나 강제 종료 없이 끝까지 실행될 때 Agent Guard 구현이 보장하는 동작 |
| **LIVE-UNVERIFIED** | 설치본 선택, enable/trust, 정확한 route dispatch, 호스트의 응답 수용, 저장 형식, compaction 이후 표현, timeout 시그널 순서처럼 저장소 테스트만으로 확정할 수 없는 사실 |

`REPOSITORY-VERIFIED`는 실기기 dispatch 증거가 아니고,
`OFFICIAL-CONTRACT`는 현재 설치본이 그 계약을 실제로 적용했다는 증거가 아니다.

## 현재 도달 범위

### 빠른 route 판별표

아래 표의 “적용 후보”는 matcher와 저장소 구현이 해당 event를 처리하도록
구성되었다는 뜻이다. `AGENT_GUARD_OUTPUT_REDACT=off`이면 secret output masking은
꺼지고, 설치본의 enable/trust, 실제 dispatch와 host의 replacement 수용은 여전히
live probe가 필요한 별도 경계다.

| Host | Route | Output masking 도달 여부 | 주의점 |
| --- | --- | --- | --- |
| Claude | anchored `PostToolUse`의 exact built-in success route: `Write`, `Edit`, `MultiEdit`, `NotebookEdit`, `Bash`, `PowerShell`, `apply_patch`, `Read`, `NotebookRead`, `Grep`, `Glob`, `WebFetch`, `WebSearch`, `Agent`, `Task`, `Skill`, `Monitor`, `LSP`, `ListMcpResourcesTool`, `ReadMcpResourceTool` | 적용 후보 | matcher가 선택되고 훅이 끝까지 실행되며 host가 replacement를 수용해야 함 |
| Claude | `mcp__.*` success route | 적용 후보 | MCP namespace match. built-in과 schema validation 계약이 다름 |
| Claude | failed route / `PostToolUseFailure` | 미적용 | 별도 event이며 Agent Guard manifest에 등록되지 않음 |
| Claude | `PostToolUse` matcher 밖 tool | 미적용 | host가 event를 지원해도 이 manifest가 handler를 시작하지 않음 |
| Claude | 사용자가 직접 입력한 `!` shell escape | 미적용 | tool-hook 경계 밖. 선택적 shell integration 또는 [`agent-guard exec` / `agx`](integrations.md#limits-and-backstops)를 사용 |
| Claude | image/PDF binary block | event는 도달, payload bytes는 text-scan 제외 | 정상 restore는 원 bytes를 재삽입. 최종 restore serializer 실패는 raw bytes 대신 empty payload를 유지하는 lossy replacement |
| Codex | `Bash` / `exec_command` | 명시적 적용 의도 | non-zero command도 공식 `PostToolUse` 대상 |
| Codex | `apply_patch` | 명시적 적용 의도 | output redaction과 별도로 mutation/disk backstop 경계가 있음 |
| Codex | `Agent`, `Task` | 명시적 적용 의도 | delegation result가 generic output redaction 후보 |
| Codex | `mcp__.*` namespace | 명시적 적용 의도 | MCP result가 generic output redaction 후보 |
| Codex | `write_stdin` | 새 event가 아님 | 원 unified-exec command가 끝날 때 그 호출의 `PostToolUse`가 올 수 있음 |
| Codex | 그 밖의 local function tool | 명시적 coverage 아님 | host는 관찰할 수 있어도 manifest가 의존하지 않음. unanchored incidental overmatch는 coverage로 세지 않음 |
| Codex | hosted `WebSearch` | 미적용 | 공식 local function-tool hook path에 도달하지 않음 |
| Codex | specialized opt-out path | 보장 안 함 | host가 default hook path에서 제외할 수 있으므로 exact-route live probe 필요 |

### Claude Code

**REPOSITORY-VERIFIED.** `PreToolUse` matcher는 다음 값이다.

```text
Write|Edit|MultiEdit|NotebookEdit|Read|NotebookRead|Grep|Glob|Bash|WebFetch|WebSearch|apply_patch|Agent|Task|mcp__.*
```

`PostToolUse` matcher는 전체 문자열을 anchor한 다음 값이다.

```text
^(Write|Edit|MultiEdit|NotebookEdit|Bash|PowerShell|apply_patch|Read|NotebookRead|Grep|Glob|WebFetch|WebSearch|Agent|Task|Skill|Monitor|LSP|ListMcpResourcesTool|ReadMcpResourceTool|mcp__.*)$
```

Claude Code는 정규식 문자가 포함된 matcher를 JavaScript 정규식으로 평가한다.
따라서 `^`와 `$`는 새 built-in 이름의 substring 과매치를 막고,
`mcp__.*`는 MCP namespace를 포함한다. 위 `PostToolUse` matcher에 정확히
일치해 성공적으로 끝난 route는 모두 출력 redaction 후보가 된다.

반면 `PreToolUse` 문자열은 `mcp__.*` 때문에 전체가 unanchored JavaScript
정규식으로 평가된다. 위 이름들은 Agent Guard가 명시적으로 의존하는 route지만,
anchor가 없는 대안의 substring과 우연히 일치하는 unknown 이름까지 절대 배제하는
allowlist는 아니다.

출력 redaction과 디스크 backstop은 서로 다른 경계다.

- 모든 matched `PostToolUse` route는 `tool_response`의 text 값을 대상으로
  secret/선택적 PII redaction을 시도한다.
- working-tree backstop은
  `Write|Edit|MultiEdit|NotebookEdit|apply_patch|Bash|mcp__.*` mutation
  classification에 적용된다.
- direct-target backstop은 그중 경로를 추출할 수 있는
  `Write|Edit|MultiEdit|NotebookEdit|apply_patch`에만 적용된다. `apply_patch`는
  patch envelope에서 유효한 대상 경로를 추출할 수 있어야 한다.
- `PowerShell`은 현재 mutation classification이 아니다. 따라서 출력 redaction
  후보이지만, 그 호출이 만든 파일에 대한 working-tree/direct-target backstop은
  이 event에서 실행되지 않는다. `Skill`, `Monitor`, `LSP`, read/web 계열도 같은
  이유로 출력 경계와 디스크 경계를 혼동하면 안 된다.

**OFFICIAL-CONTRACT.** Claude의 `PostToolUse`는 성공한 도구 호출 뒤에 실행되고,
실패한 호출은 별도 `PostToolUseFailure` event로 전달된다. Agent Guard manifest에는
`PostToolUseFailure`가 등록되어 있지 않으므로 failed route의 출력은 이
`hook-post-tool` 경계에 도달하지 않는다.

Claude의 공식 계약은 다음을 명시한다.

- `updatedToolOutput`은 모델에 보내기 전에 도구 출력을 교체하며, built-in 도구의
  native output shape와 일치해야 한다.
- built-in replacement가 schema와 맞지 않으면 replacement는 무시되고 원본 출력이
  사용된다. MCP 결과는 같은 built-in schema validation을 받지 않는다.
- top-level `decision: "block"`만으로는 원본을 숨기지 않는다. Claude는 원본 출력도
  보고, `reason`을 결과 옆에 받는다.
- 파일 쓰기, 명령 실행, 네트워크 요청 같은 tool effect는 `PostToolUse` 전에 이미
  발생했다. OpenTelemetry span과 analytics도 훅보다 먼저 원본 출력을 캡처한다.

**IMPLEMENTATION-GUARANTEED.** Agent Guard는 Claude에서 정상 rewrite가 가능하면
원래 JSON shape를 보존한 `hookSpecificOutput.updatedToolOutput`을 한 번만
출력한다. primary validator, secret detector, PII transform 또는 serializer가
실패하면 먼저 독립 parser와 shape-preserving whole-leaf replacement를 사용한다.
이 보장은 프로세스가 끝까지 실행되어 호스트가 응답을 읽는 경우에만 성립한다.

모든 serializer가 실패했을 때의 최종 Claude fallback은 고정 문자열
`updatedToolOutput: "[REDACTED]"`이다. 이것은 secret-free이지만 structured
built-in의 native shape를 보존하지 않는다. 공식 계약상 호스트가 이를 무시하고
원본을 사용할 수 있으므로 이 last-resort 경로의 실제 수용은
**LIVE-UNVERIFIED**이며 알려진 schema 위험이다.

**LIVE-UNVERIFIED.** 현재 설치본의 matcher dispatch, 플러그인 enable 상태,
정확한 `updatedToolOutput` schema 수용, host version별 transcript 저장 표현과
compaction 이후 표현은 live probe 없이는 확정하지 않는다.

### Codex

**REPOSITORY-VERIFIED.** Codex `PreToolUse`와 `PostToolUse` manifest 문자열은
모두 정확히 다음 값이다.

```text
Bash|apply_patch|Agent|Task|mcp__.*
```

**OFFICIAL-CONTRACT.** Codex는 matcher를 정규식으로 평가한다. 현재 문자열은
anchor가 없으므로 Agent Guard가 명시적으로 의존하는 `Bash`, `apply_patch`,
`Agent`, `Task`, MCP namespace 외에도 substring이 맞는 unknown 이름을 과매치할
수 있다. 따라서 이 값은 anchored exact-name allowlist가 아니다. 과매치된 unknown
tool에는 이름별 input/mutation branch가 적용되지 않지만, matched `PostToolUse`의
generic output redaction은 여전히 실행될 수 있다. 의도한 route와 우연히 match된
route를 coverage 주장에 합치지 않는다.

Codex 자체는 `Bash`, `apply_patch`, MCP 외의 다른 local
function tool도 `PreToolUse`/`PostToolUse` 경로에서 관찰할 수 있다. 그러나 Agent
Guard manifest가 위 이름을 match하지 않으면 그 기능은 Agent Guard에 도달하지
않는다. hosted `WebSearch`는 공식 local function-tool 훅 경로 자체를 사용하지
않는다. 일부 specialized tool path는 opt-out할 수 있다.

`exec_command`는 `Bash`로 match한다. `write_stdin`은 이미 열린 unified-exec
session의 transport라서 별도 `PreToolUse`를 다시 실행하지 않으며, 명령이 끝났을
때 최초 호출의 `PostToolUse`를 전달할 수 있다. 따라서 poll/input 한 번마다 새
검사가 일어난다고 가정하면 안 된다.

Codex는 `Bash`가 non-zero로 끝난 경우에도 `PostToolUse`를 실행한다고 공식
문서가 명시한다. 이는 성공 호출과 `PostToolUseFailure`를 분리하는 Claude 계약과
같다고 가정할 수 없는 또 하나의 host 차이다.

Codex의 `PostToolUse` 계약은 Claude와 다르다.

- `decision: "block"`은 이미 끝난 tool effect를 되돌리지 않지만 원래 tool result를
  hook feedback으로 교체하고 모델을 그 메시지에서 계속한다.
- `hookSpecificOutput.additionalContext`는 extra developer context다.
- code mode의 nested tool call에서 `decision: "block"` 또는 exit 2가 발생하면
  도구 실행 뒤 nested promise가 hook reason으로 reject된다.
- `updatedMCPToolOutput`과 `suppressOutput`은 parse되지만 지원되지 않는다. 사용하면
  hook failure가 기록되고 원본 tool result가 정상 처리된다.

**IMPLEMENTATION-GUARANTEED.** Agent Guard는 Codex에 Claude용
`updatedToolOutput`을 보내지 않는다. 대신 `decision: "block"`과 sanitized
replacement를 담은 `hookSpecificOutput.additionalContext`를 출력한다. serializer가
shape-preserving replacement를 만들지 못하면 secret-free 고정 feedback을
사용한다. 이 경로를 Claude와 동일한 output-replacement schema라고 해석하면 안
된다.

**LIVE-UNVERIFIED.** 정확한 local function route, plugin trust hash, code mode nested
promise 동작, 모델이 받은 replacement/feedback은 현재 설치본에서 route별 harmless
probe로 확인해야 한다.

## `closed`가 보장하는 것과 보장하지 않는 것

`AGENT_GUARD_INFRA_FAILURE_MODE=closed`는 실행 중인 Agent Guard가 infrastructure
failure를 판정하고 exit 2를 호스트에 반환할 수 있을 때의 정책이다. 이미 실행된
도구의 effect를 rollback하거나, timeout으로 응답을 내지 못한 프로세스를 대신해
결정을 만들어 주는 설정이 아니다.

| 경계 | `open` | `closed` | 실효 한계 |
| --- | --- | --- | --- |
| manifest wrapper가 plugin root의 binary/config를 찾지 못함 | one-time warning, exit 0 | warning, exit 2 | event별 host 계약이 exit 2를 block으로 존중해야 실효가 있음. `SessionStart` exit 2는 action을 막지 않고 host error로만 보고됨 |
| `PreToolUse`/`PostToolUse`/`Stop`/`UserPromptSubmit` handler 초기 dependency/policy failure | degraded warning 후 계속 | 즉시 exit 2, replacement 없음 | `SessionStart` handler는 아래 별도 행. finding과 infrastructure failure는 별도 상태 |
| later Git/direct-target scanner failure | warning 후 가능한 후속 처리 계속 | 즉시 exit 2, replacement 없음 | disk backstop failure이며 output redaction failure와 같은 상태가 아님 |
| output validator/detector/serializer failure | shape-preserving conservative replacement 우선 | 동일 | `closed`의 효과가 아니라 별도 fail-closed 구현. 최종 fixed-string fallback의 Claude schema 위험은 남음 |
| `PreToolUse` / `UserPromptSubmit` | infrastructure failure면 호스트가 원래 action을 계속할 수 있음 | infrastructure failure면 exit 2, 그 외 ordinary verdict | matcher가 선택되고 host가 block 계약을 존중할 때만 원 action을 막음 |
| `PostToolUse` | 가능한 경우 sanitized replacement 또는 degraded 진단 | infrastructure failure면 exit 2 | tool effect는 되돌릴 수 없음. Claude는 exit 2만으로 원본을 숨기지 않고, Codex는 공식 계약상 원본 result를 feedback으로 교체하므로 모델-visible output 효과는 host별로 다름 |
| `Stop` | infrastructure failure면 종료 흐름 계속 | infrastructure failure면 exit 2, 그 외 ordinary verdict | 대화를 계속시킬 수 있어도 앞선 mutation을 취소하지 못함 |
| `SessionStart` handler | readiness/shell drift를 report | 동일하게 report | handler 자체에는 block/replay/restore 로직이 없음. 단, binary가 없어 wrapper가 실패한 경우에는 wrapper의 open/closed 규칙이 별도로 적용됨 |

**OFFICIAL-CONTRACT.** Claude에서 exit 2는 matched `PreToolUse`와
`UserPromptSubmit`을 막고, `Stop`에서는 대화를 계속시킨다. Codex도 지원 event의
exit 2/결정 계약을 적용하지만, trust되지 않았거나 match되지 않은 훅은 실행하지
않는다. 따라서 표의 저장소 동작만으로 live block을 주장하지 않는다.

### Malformed envelope는 infrastructure failure와 다르다

**REPOSITORY-VERIFIED / IMPLEMENTATION-GUARANTEED.** non-empty이면서 JSON
object로 해석할 수 없는 malformed/non-object host payload는 `open`으로 낮추지
않는다.

- `PreToolUse`와 `Stop`: exit 2로 거부한다.
- `PostToolUse`: primary validator 실패 뒤 독립 parser로 `tool_response`를 복구하고
  전체 string leaf를 보수적으로 교체한다. 복구 가능한 valid envelope에는 하나의
  host-specific replacement를 출력한다.
- 독립 parser도 envelope를 복구하지 못하면 exit 2와 진단만 가능하다. 이미 끝난
  도구의 effect를 되돌릴 수 없고, Agent Guard가 sanitized replacement를 보장할
  수 없다. 모델-visible 원본에 대한 exit 2의 효과는 위 Claude/Codex 계약처럼
  host별로 다르다.
- empty stdin은 검증된 예외다. `hook-pre-tool`, `hook-post-tool`, `hook-stop` 모두
  status 0과 빈 response로 통과한다. “malformed payload는 exit 2”라는 설명에 empty
  input을 포함하면 현재 구현과 테스트 계약보다 넓은 주장이다.

## 출력 마스킹의 명시적 한계

- `AGENT_GUARD_OUTPUT_REDACT=off`이면 secret-like output masking을 끈다.
- image/PDF binary payload는 text scanner가 검사하지 않는다. 정상 rewrite에서는
  payload를 임시로 strip한 뒤 원 image/PDF bytes를 정확히 재삽입하고, 같은 결과의
  text sibling은 계속 검사한다. 다만 마지막 binary restore serializer가 실패하면
  구현은 raw bytes를 추측해 재도입하지 않고 stripped `data`/`base64`의 empty 값을
  유지한 secret-safe but lossy replacement를 출력한다. 이 경로는 whole-leaf 또는
  fixed-string fallback으로 다시 들어가지 않는다.
- Claude built-in replacement의 native shape가 host schema와 맞지 않으면 공식 계약상
  원본 fallback 위험이 있다. 보통의 whole-leaf fallback은 shape를 보존하지만,
  모든 serializer가 실패한 뒤의 fixed-string fallback은 structured shape와 맞지
  않을 수 있다. 설치된 host의 실제 수용을 대신 증명하지 않는다.
- matcher가 선택됐다는 사실은 결과의 모든 byte를 검사했다는 뜻이 아니다. binary
  payload, 검사 cap, host가 제공하지 않은 field와 route는 각자의 경계를 가진다.
- `PostToolUse` 시점에는 tool effect가 이미 발생했다. output masking은 모델 입력
  경계이지 filesystem/network rollback 경계가 아니다.
- 정확한 host runtime acceptance는 secret-bearing 실험이 아니라 harmless live
  sentinel로 확인한다.

## 세션, resume, compaction, 저장

**REPOSITORY-VERIFIED.** 네 manifest 모두 `SessionStart` matcher가
`startup|resume|clear|compact`이고 timeout은 5초다. `hook-session-start` handler는
dependency readiness와 Claude shell-integration drift를 report할 뿐, 과거 출력의
replay, transcript 복원, redaction 재실행을 수행하지 않는다.

Agent Guard audit log는 metadata-only 진단 기록이다. command, outcome, exit_code,
duration, run id 같은 provenance를 남기지만 conversation/tool output 저장소가 아니고,
resume나 compaction 입력을 복원하지 않는다.

**OFFICIAL-CONTRACT.** Claude는 `additionalContext`로 주입된 text를 session
transcript에 저장하고, mid-session event의 과거 값은 resume 시 훅을 다시 실행하지
않고 저장된 값을 replay한다. 반면 이 문서에서 사용한 공식 근거는
`updatedToolOutput`이 transcript와 compaction에 어떤 정확한 형태로 보존되는지까지
규정하지 않는다.

Codex의 `transcript_path`는 편의 경로이고 transcript format은 안정된 hook
interface가 아니며 바뀔 수 있다고 공식 문서가 명시한다. 따라서 두 호스트 모두
sanitized output의 정확한 저장/compaction representation은 **LIVE-UNVERIFIED**로
남긴다. 이를 확인하려고 실제 secret을 넣는 실험은 하지 않는다.

## Timeout과 종료 시그널

**REPOSITORY-VERIFIED.** renderer가 생성한 plugin/example 네 manifest의 budget은
모두 같다.

| Event | timeout |
| --- | --- |
| `PreToolUse` | 10초 |
| `PostToolUse` | 20초 |
| `Stop` | 20초 |
| `SessionStart` | 5초 |
| `UserPromptSubmit` | 10초 |

host budget은 CLI 내부 작업의 wall-clock 상한 보장이 아니다. 여러 subprocess,
host scheduling, cancellation 전달 지연을 포함한 전체 경계에서 host가 적용하는
제한이다. CLI는 `INT`와 `TERM`을 각각 130과 143으로 종료하도록 trap하고,
`SIGKILL`은 trap하거나 cleanup할 수 없다.

**OFFICIAL-CONTRACT.** Claude 문서는 synchronous command hook이 timeout에
도달하면 cancel되고 출력이 폐기되며, timed-out `PreToolUse` command hook은 tool
call을 막지 않는다고 명시한다. Codex 문서는 manifest timeout budget과 active
execution timeout을 명시한다. 어느 근거도 각 플랫폼에서 정확히 어떤 signal을
어떤 순서로 parent/descendant process에 전달하는지 보장하지 않는다. 그 sequencing은
**LIVE-UNVERIFIED**다.

`closed`도 프로세스가 결정을 출력하기 전에 강제 종료되면 효력이 없다. local Git
hook과 CI scan을 유지해 interactive hook timeout의 후방 경계를 보완한다.

## 검증 절차

| 단계 | 방법 | 증명하는 것 | 증명하지 못하는 것 |
| --- | --- | --- | --- |
| Deterministic repository test | `sh scripts/render-hook-manifests.sh --check`, `/bin/dash tests/run.sh` | renderer/manifest parity, CLI response shape, open/closed 및 malformed fixture | 설치본 enable/trust, host dispatch/acceptance |
| Dependency test | `agent-guard check`, `agent-guard doctor`, `agent-guard smoke-test` | 선택된 binary/config/dependency와 synthetic policy 경로 | 특정 tool route의 실제 훅 호출 |
| Exact-route live probe | [verification.md](verification.md)의 harmless pre/post sentinel을 실제 사용할 route로 실행하고 metadata run id 확인 | 그 설치본에서 그 route가 그 순간 dispatch 및 replacement를 수행함 | 다른 도구, wrapper, specialized opt-out, 향후 session |
| Lifecycle probe | `startup`, `resume`, `clear`, `compact` 각각에서 harmless message와 hook log 확인 | 해당 source의 실제 `SessionStart` dispatch | 과거 `updatedToolOutput`의 정확한 transcript/compaction 저장 형태 |

실기기 절차는 다음 순서로 수행한다.

1. 설치된 plugin version과 선택된 `agent-guard` binary를 확인한다.
2. Claude에서는 plugin enable 상태를, Codex에서는 현재 hook definition의 trust를
   확인한다.
3. 검사하려는 정확한 route에서 secret이 아닌 pre/post sentinel을 실행한다.
4. 모델-visible replacement와 metadata-only run id를 함께 확인한다.
5. 다른 route를 보장하려면 그 route에서도 별도로 반복한다.
6. plugin update, matcher 변경, trust hash 변경, host upgrade 후 다시 수행한다.

실제 credential, PII, private transcript를 live probe에 사용하지 않는다.
