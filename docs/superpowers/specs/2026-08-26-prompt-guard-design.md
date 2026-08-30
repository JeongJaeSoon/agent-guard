# Prompt Guard (UserPromptSubmit) — Design

Date: 2026-08-26

## Problem

Agent Guard's PreToolUse/PostToolUse hooks stop the *agent* from reading or
emitting secrets, but nothing stops the *user* from pasting an `.env` file or
an API key directly into the prompt. Once submitted, the secret reaches the
model API and the on-disk transcript. Both supported hosts now expose a
`UserPromptSubmit` hook that fires before the prompt reaches the model:

- **Claude Code**: can block (exit 2 / `"deny"`) and add context
  (`additionalContext`); **no prompt rewriting exists** (verified against
  code.claude.com/docs/en/hooks.md during adversarial review — an earlier
  draft of this spec wrongly assumed `updatedPrompt`).
- **Codex**: can block (exit 2 / `decision: "block"`) and add
  `additionalContext`; prompt rewriting is likewise not documented.

## Decision

One new CLI entrypoint, `agent-guard hook-user-prompt`, wired into both plugin
manifests through the existing single-template renderer
(`scripts/render-hook-manifests.sh`). Detection reuses the existing machinery: gitleaks
stdin scan (`scan_text_direct`), the secret-ish `KEY=value` assignment probe,
and the PII input gate (`block_on_pii_text`).

## Modes

`AGENT_GUARD_PROMPT_GUARD_MODE` — `block` (default) | `mask` | `warn` | `off`.
Unsupported values die loudly (same contract as `AGENT_GUARD_PII_HOOK_MODE`).

| Mode | Claude | Codex |
|---|---|---|
| block | exit 2 with reason | exit 2 with reason |
| mask | **reserved — degrades to block** (no host lets a hook rewrite the prompt; emitting ignored "masked" JSON would silently leak the original) | same degrade |
| warn | pass through; `systemMessage` + `additionalContext` notice | `additionalContext`-only notice (its documented channel) |
| off | no secret scan (the PII gate below still runs) | same |

## Detection

A prompt is secret-bearing when either:

1. gitleaks finds a match in the prompt text (`scan_text_direct`, status 1), or
2. the streaming assignment probe finds a secret-ish `KEY=value` /
   `key: value` line (`frame_plaintext_leaf | secretish_env_values probe`)
   — this covers pasted `.env` content whose value formats gitleaks misses.

Scanner-infrastructure failure (status 3) routes through the existing
`AGENT_GUARD_INFRA_FAILURE_MODE` handling; missing jq/gitleaks routes through
the existing degraded-hook warning (fail-open by default, `closed` blocks).

PII: when `AGENT_GUARD_PII_HOOK_MODE` is `block`/`mask`, the existing input
gate `block_on_pii_text` runs on the prompt independently of the secret mode
(block mode blocks any PII; mask mode hard-blocks Tier-2 only — Tier-1 cannot
be masked in a prompt because no rewrite exists, a documented limitation).
The PII mode is validated in the main shell so a typo fails loud instead of
silently disabling the gate.

## Manifest wiring

`render-hook-manifests.sh` gains a `UserPromptSubmit` entry (matcher-less,
timeout 10) rendered for both hosts with `hook-user-prompt` as the
subcommand; committed manifests are regenerated.

## Testing

`tests/run.sh` ground-truth cases with the mock gitleaks, both hosts:

- must-block: `{"prompt":"AGENT_GUARD_TEST_SECRET"}` → exit 2 (default mode).
- must-block: `.env`-style `DB_PASSWORD=...` prompt with no gitleaks rule hit
  (assignment probe path).
- must-pass: benign prompt → exit 0, empty stdout.
- mask: exit 2 degrade on BOTH hosts, message names the degrade, no
  `updatedPrompt` on stdout.
- warn: exit 0 with the host-shaped notice; off: exit 0, silent.
- invalid secret mode and invalid PII mode: exit 2, loud.
- PII gate fires with the secret guard off; Tier-2 blocked in PII mask mode.
- warn survives a scanner infrastructure failure (broken gitleaks) without
  hardening into a block (regression: a shared helper clobbered the mode
  global).

## Out of scope

- Actual prompt masking on either host (no host contract supports rewriting;
  the reserved `mask` mode activates it if a host adds support).
- Scanning prompt attachments/images.
- README gets a short section; no new config files.
