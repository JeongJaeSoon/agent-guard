# Configuration

Agent Guard reads policy from its bundled configuration and selected environment
variables. Keep custom policy files reviewable and test them with
`agent-guard smoke-test` plus an appropriate live probe.

## Infrastructure policy

`AGENT_GUARD_INFRA_FAILURE_MODE` controls an unavailable dependency, policy, or
scanner error in a lifecycle hook:

| Value | Behavior |
| --- | --- |
| `open` (default) | Continue with one visible degraded-protection notice |
| `closed` | Refuse the hook action with exit status 2 |

This is distinct from a secret finding, which blocks. An invalid value is read
as `open`; set an explicit valid value in managed environments.

## Output and prompt handling

- `AGENT_GUARD_OUTPUT_REDACT=off` disables secret-like output masking. The
  default is masking.
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
