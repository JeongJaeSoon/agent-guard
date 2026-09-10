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

## Policy files and shell integration

The bundled deny-read-paths, deny-Bash-patterns, and gitleaks files define the
default policy. Do not loosen them only to silence a false positive; first
confirm whether the operation is actually benign and use a structurally clear
alternative where possible.

`setup-shell` installs an explicit shell-rc block. It offers command wrapping
and a non-blocking nudge for common credential-dump commands. The wrapping is
text-only and intentionally does not turn a shell integration into a complete
security boundary.
