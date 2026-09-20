# Configuration

Agent Guard reads policy from its bundled configuration and selected environment
variables. Keep custom policy files reviewable and test them with
`agent-guard smoke-test` plus an appropriate live probe.

`AGENT_GUARD_INFRA_FAILURE_MODE=closed`와 output redaction의 event별 실효 범위는
[도구 출력 마스킹의 범위와 검증 경계](output-masking-boundaries.md)를 함께
확인하세요. 특히 `PostToolUse`의 exit 2는 이미 실행된 tool effect를 되돌리지
않고, timeout 전에 응답하지 못하면 `closed` 결정 자체가 host에 도달하지 않습니다.

## Infrastructure policy

`AGENT_GUARD_INFRA_FAILURE_MODE` controls an unavailable dependency, policy, or
scanner error in a lifecycle hook:

| Value | Behavior |
| --- | --- |
| `open` (default) | Continue with one visible degraded-protection notice |
| `closed` | Refuse the hook action with exit status 2 |

This is distinct from a secret finding, which blocks. An invalid value is read
as `open`; set an explicit valid value in managed environments.

Non-empty malformed or non-object PreToolUse, PostToolUse, and Stop input is
also distinct from unavailable infrastructure. Agent Guard rejects one of
those events even if infrastructure mode is `open`.
PreToolUse and Stop can block their boundary action with exit status 2. Because
PostToolUse runs after the tool, Agent Guard first uses an independent portable
parser to recover and conservatively replace `tool_response` from a valid host
envelope that the primary validator could not handle. A non-empty malformed or
non-object PostToolUse envelope is reported with exit status 2, but that
diagnostic cannot retract a result the host already received. Malformed-input
diagnostics are not deduplicated with degraded-infrastructure notices.
Empty stdin is the documented exception: PreToolUse, PostToolUse, and Stop
return status 0 with no response. See [output masking boundaries](output-masking-boundaries.md#malformed-envelope%EB%8A%94-infrastructure-failure%EC%99%80-%EB%8B%A4%EB%A5%B4%EB%8B%A4).

## Output and prompt handling

- `AGENT_GUARD_OUTPUT_REDACT=off` disables secret-like output masking. The
  default is masking.
- A tool result too large to scan is masked fail-closed: every nonempty string
  in it is replaced. Anthropic content-block discriminators (`type`,
  `source.type`, `media_type`) survive that rewrite when the value is exactly a
  known protocol token, so the sanitized result still parses as the block shape
  the host sent. Any other string is masked, including under those keys. A
  portable secondary serializer preserves object keys, order, containers, and
  scalar types if the primary JSON rewrite cannot run; it neutralizes numeric
  and true-valued leaves while producing one host-valid replacement. This
  replacement is required because PostToolUse runs after the tool and exit
  status alone cannot retract the original result.
- Base64 image and PDF blocks (`media_type` of `image/png`, `image/jpeg`,
  `image/gif`, `image/webp` or `application/pdf`, in the Anthropic `source`
  shape, MCP's native `data`/`mimeType` shape or Claude Code's `Read` `file`
  shape) are not inspected: the scanner cannot read pixels. Their payload is
  excluded from the size cap while text siblings in the same result are still
  scanned and masked. A normal rewrite restores the original binary bytes
  unchanged after scanning. If the final restore serializer fails, Agent Guard
  instead emits the stripped block with an empty `data`/`base64` payload; this
  is secret-safe but lossy and does not re-enter the whole-leaf or fixed-string
  fallback. A base64 block of a text media type (`text/plain`, `image/svg+xml`)
  is treated as text. See [output masking boundaries](output-masking-boundaries.md).
- `AGENT_GUARD_PROMPT_GUARD_MODE=block` is the default. `warn` passes a prompt
  with a notice and `off` disables secret prompt scanning. Hosts currently do
  not provide safe prompt rewriting, so `mask` degrades to block.
- Very large prompts skip the assignment heuristic to protect the host hook
  budget. Gitleaks still runs; the skipped heuristic follows the infrastructure
  policy.

## PII handling

PII hooks are off by default. The default `regex` provider is local.

| Setting | Meaning |
| --- | --- |
| `AGENT_GUARD_PII_HOOK_MODE=off` | No PII hook processing |
| `block` | Block recognized PII in supported inputs |
| `mask` | Mask PII in supported outputs and block Tier-2 input PII |

`AGENT_GUARD_PII_PROVIDER=http` and `pleno` send supplied text to the exact
user-configured endpoint. Review its privacy/retention terms before use. See
[Privacy](../PRIVACY.md) for the data boundary and controls.

`AGENT_GUARD_PII_SKIP` is available only with the local `regex` provider. It
accepts comma- or space-separated `EMAIL`, `PHONE`, and `IP_ADDRESS`. It cannot
skip Tier-2 values such as payment cards, US SSNs, or Korean resident numbers;
an unknown or Tier-2 type is an error. `AGENT_GUARD_PII_LANGUAGE` selects the
provider language where supported, and `AGENT_GUARD_PII_TIMEOUT_SECONDS` must
be a positive integer for endpoint-backed providers.

## Environment reference

| Variable | Default / use |
| --- | --- |
| `AGENT_GUARD_DENY_READ_PATHS` | Override the deny-read policy file. |
| `AGENT_GUARD_DENY_BASH_PATTERNS` | Override the risky-shell-command policy file. |
| `AGENT_GUARD_GITLEAKS_CONFIG` | Override the gitleaks configuration file. |
| `AGENT_GUARD_GITLEAKS_BIN` | Select a gitleaks executable. |
| `AGENT_GUARD_GITLEAKS_BIN_DIR` or `AGENT_GUARD_BIN_DIR` | Select the private gitleaks install directory. |
| `AGENT_GUARD_INFRA_FAILURE_MODE` | `open` (default) or `closed` for hook infrastructure failures. |
| `AGENT_GUARD_SCAN_INPUT_MAX_BYTES` | Positive integer `>= 10485760`; default `10485760` (10 MiB, split three ways for `scan-working-tree`). It can only raise the budget: smaller, non-numeric, or overlong (19+ digit) values keep the default. A larger budget scans more input; it never excludes anything from scanning. |
| `AGENT_GUARD_OUTPUT_REDACT` | Output secret masking; set `off` only with deliberate acceptance of the reduced protection. |
| `AGENT_GUARD_PROMPT_GUARD_MODE` | `block` (default), `warn`, `off`, or the currently blocking `mask` fallback. |
| `AGENT_GUARD_PII_HOOK_MODE` | `off` (default), `block`, or `mask`. |
| `AGENT_GUARD_PII_PROVIDER` | `regex` (default), `http`, or `pleno`. |
| `AGENT_GUARD_PII_REDACT_URL` | Required user-controlled endpoint for the remote PII providers. |
| `AGENT_GUARD_PII_SKIP` | Local-regex opt-out for `EMAIL`, `PHONE`, and `IP_ADDRESS` only. |
| `AGENT_GUARD_PII_LANGUAGE` / `AGENT_GUARD_PII_TIMEOUT_SECONDS` | Provider language and positive timeout control. |
| `AGENT_GUARD_COMMAND_WRAPPING` | `off` disables shell command wrapping for the current process. |
| `AGENT_GUARD_LOG_MODE` | The post-v3.3.0 metadata log is on by default; set `off` to opt out. |

`AGENT_GUARD_HOME`, `AGENT_GUARD_BIN`, `AGENT_GUARD_HOOK_HOST`,
`AGENT_GUARD_RUNDIR`, `AGENT_GUARD_SESSION_ID`, `AGENT_GUARD_SHELL_INIT_VERSION`,
and `AGENT_GUARD_WARNING_DIR` are runtime/integration controls. Do not set them
in ordinary policy configuration unless a documented host integration requires
them.

## Policy files and shell integration

The bundled deny-read-paths, deny-Bash-patterns, and gitleaks files define the
default policy. Do not loosen them only to silence a false positive; first
confirm whether the operation is actually benign and use a structurally clear
alternative where possible.

`setup-shell` installs an explicit shell-rc block. It offers command wrapping
and a non-blocking nudge for common credential-dump commands. The wrapping is
text-only and intentionally does not turn a shell integration into a complete
security boundary.
