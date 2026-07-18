# Curator change description draft

> Use only after an Anthropic maintainer provides an official-marketplace
> inclusion path. This is not a request to bypass the submission policy.

## Summary

- add `agent-guard` as a SHA-pinned `git-subdir` external plugin
- provide local, deterministic secret-leak protection at the Claude Code tool
  boundary, with Git-hook and CI backstops
- support macOS and Linux on x64 and arm64

## User-visible behavior

Agent Guard registers `SessionStart`, `PreToolUse`, `PostToolUse`, and `Stop`
hooks. The pre/post hooks inspect every matched tool call in each enabled
session. They block deny-listed sensitive reads, secret-bearing writes and
commands, mask secret-like tool output, and scan current work-tree changes.

Normal hooks are local and have no telemetry. PII hook handling is off by
default. Users who explicitly select the HTTP PII provider send documented text
to their own configured endpoint. Lifecycle hooks never install software.
Approval-gated setup can download a versioned gitleaks archive only with a
published SHA-256.

## Security and privacy review notes

- expected flags: `may_make_external_network_calls=true` and
  `may_download_additional_software=true`
- no default outbound hook calls, analytics, crash reporting, or developer
  service
- full hook/data scope, optional PII transport, retention, and opt-outs are in
  the shipped `PRIVACY.md`
- known blocker requiring curator decision: the current marketplace scan policy
  rejects ungated `PreToolUse`/`PostToolUse`, while always-on coverage is Agent
  Guard's stated purpose
- MIT license; gitleaks and jq are separately installed and not vendored
- private vulnerability reporting and public support channels are documented

## Validation

- `make test`
- `make smoke-test`
- `scripts/validate-plugin-layout.sh --all`
- `make submission-check`
- `claude plugin validate ./plugins/agent-guard`
- `claude plugin validate .`
- `git diff --check`

## Reviewer examples

1. Ask Claude Code to read `.env`; Agent Guard should block before the read.
2. Ask Claude Code to write a synthetic private-key fixture; Agent Guard should
   block the proposed write.
3. Run `/agent-guard:verify` in a clean fixture repository, then add a synthetic
   gitleaks-detectable fixture and verify that the second scan fails.

Use only synthetic fixtures. Never expose a real credential during review.
