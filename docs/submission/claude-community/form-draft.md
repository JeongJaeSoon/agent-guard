# Claude Community Submission Form Draft

## Plugin name

`agent-guard`

## Repository and plugin path

- Repository: `https://github.com/JeongJaeSoon/agent-guard`
- Plugin path: `plugins/agent-guard`
- Commit SHA: `bdf51638652db846e1b19aa28f99cfa2d3f337e3`

## Short description

Local-by-default, no-telemetry hooks inspect supported Claude Code tool inputs,
outputs, and changed files on macOS and Linux to block or mask secret leaks.
Optional HTTP PII processing is off by default.

## Category

Security

## Privacy policy

`https://github.com/JeongJaeSoon/agent-guard/blob/main/PRIVACY.md`

## Support and security

- Support: `https://github.com/JeongJaeSoon/agent-guard/issues`
- Private security reporting:
  `https://github.com/JeongJaeSoon/agent-guard/security/advisories/new`

## Data and network disclosure

Hooks process matched tool inputs and outputs in memory and scan changed and
untracked files in the current Git work tree. Default processing is local, has
no telemetry, and retains no inspected data. `agent-guard checksum` and explicit,
approval-gated setup contact GitHub Releases without sending project content.
If the user opts into `AGENT_GUARD_PII_PROVIDER=pleno|http`, documented text is
sent to the exact user-configured endpoint. PII hooks default to off.

## Additional software

Requires jq and gitleaks. Agent Guard never installs from a lifecycle hook. The
guided setup asks for approval and requires a published SHA-256 before it can
download a versioned gitleaks release archive.

## Platforms

macOS and Linux, x64 and arm64. Windows is not supported.

## Three test prompts or use cases

1. `Please read .env` — expected: blocked before file access.
2. Ask Claude Code to write a synthetic private-key fixture — expected: the
   proposed write is blocked.
3. `/agent-guard:verify` in a fixture repository — expected: clean tree passes;
   a synthetic gitleaks-detectable addition fails.

## Test account

Not applicable. Agent Guard's core plugin is local and has no account or
developer-operated service. Review uses synthetic fixture data. An optional
user-configured PII endpoint is not needed to verify core functionality.

## Known review risk

The plugin intentionally registers broad `PreToolUse` and `PostToolUse` hooks
in every enabled session. This matches the security purpose and is disclosed,
but it may conflict with Anthropic's automated broad-hook policy. Request a
clear reviewer decision; do not imply the hook is project-gated.

## Submission route

Use `https://platform.claude.com/plugins/submit` for an individual author, or
the claude.ai directory form for a Team/Enterprise organization with directory
management access. The public community repository is a read-only mirror; do
not open a pull request there.
