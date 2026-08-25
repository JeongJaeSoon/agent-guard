# Prompt Guard (UserPromptSubmit) — Design

Date: 2026-08-26

## Problem

Agent Guard's PreToolUse/PostToolUse hooks stop the *agent* from reading or
emitting secrets, but nothing stops the *user* from pasting an `.env` file or
an API key directly into the prompt. Once submitted, the secret reaches the
model API and the on-disk transcript. Both supported hosts now expose a
`UserPromptSubmit` hook that fires before the prompt reaches the model:

- **Claude Code**: can block (exit 2 / `"deny"`), and can rewrite the prompt
  via `hookSpecificOutput.updatedPrompt`.
- **Codex**: can block (exit 2 / `decision: "block"`) and add
  `additionalContext`; prompt rewriting is not documented.

## Decision

One new CLI entrypoint, `agent-guard hook-user-prompt`, wired into both plugin
manifests through the existing single-template renderer
(`scripts/render-hook-manifests.sh`). Detection and masking reuse the existing
machinery: gitleaks stdin scan (`scan_text_direct`), the secret-ish
`KEY=value` assignment probe, the literal-redaction bundle
(`detect_output_secret_bundle` + `redact_tool_response_json`), and the PII
input gate (`block_on_pii_text`) / masker (`mask_pii_response_json`).

## Modes

`AGENT_GUARD_PROMPT_GUARD_MODE` — `block` (default) | `mask` | `warn` | `off`.
Unsupported values die loudly (same contract as `AGENT_GUARD_PII_HOOK_MODE`).

| Mode | Claude | Codex |
|---|---|---|
| block | exit 2 with reason | exit 2 with reason |
| mask | emit `updatedPrompt` with secret literals replaced by `[REDACTED]` (PII also masked when `AGENT_GUARD_PII_HOOK_MODE=mask`) | **degrades to block** with a message naming the degrade |
| warn | pass through; emit `systemMessage` + `additionalContext` notice | same JSON notice |
| off | no scan | no scan |

Fail-closed rule for mask: a prompt that was detected as secret-bearing but
whose rewrite fails (jq error, empty result, unchanged output) is blocked, not
passed through.

## Detection

A prompt is secret-bearing when either:

1. gitleaks finds a match in the prompt text (`scan_text_direct`, status 1), or
2. the streaming assignment probe finds a secret-ish `KEY=value` /
   `key: value` line (`frame_json_string_leaves | secretish_env_values probe`)
   — this covers pasted `.env` content whose value formats gitleaks misses.

Scanner-infrastructure failure (status 3) routes through the existing
`AGENT_GUARD_INFRA_FAILURE_MODE` handling; missing jq/gitleaks routes through
the existing degraded-hook warning (fail-open by default, `closed` blocks).

PII: when `AGENT_GUARD_PII_HOOK_MODE` is `block`/`mask`, the existing input
gate `block_on_pii_text` runs on the prompt (block mode blocks any PII; mask
mode hard-blocks Tier-2 only, Tier-1 is masked in the mask-mode rewrite).

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
- mask/claude: exit 0, stdout contains `updatedPrompt`, `[REDACTED]`, and not
  the secret literal.
- mask/codex: exit 2 (degrade).
- warn: exit 0 with notice JSON; off: exit 0, silent.
- invalid mode: non-zero, loud.

## Out of scope

- Codex-side masking (host contract does not document prompt rewrite; the
  degrade path picks it up automatically if we later confirm support).
- Scanning prompt attachments/images.
- README gets a short section; no new config files.
