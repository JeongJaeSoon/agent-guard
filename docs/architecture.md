# Agent Guard architecture and portability contract

## Scope

Agent Guard protects tool boundaries and repository backstops. It does not
schedule, spawn, resume, or supervise agents. A host may spawn a sub-agent,
but the resulting `Agent` or legacy `Task` tool input is inspected by the same
pre-tool policy path as every other tool input. This keeps orchestration host-
specific while keeping security policy portable.

## Three layers

1. **Portable core** — `plugins/agent-guard/bin/agent-guard` implements deny
   rules, secret/PII scanning, redaction, dependency checks, exit codes, and
   infrastructure-failure policy using POSIX shell plus required tools.
2. **Host adapters** — Claude and Codex hook manifests, the native Git hook,
   and `action.yml` provide event translation only. They must resolve the
   selected complete plugin root and must not embed a second policy engine.
3. **Installation adapters** — plugin managers own plugin versions; the
   standalone bootstrap/Homebrew path owns the CLI version. `agent-guard update`
   therefore updates only standalone installs, while plugin updates remain
   host-managed.

## Minimality and safety contract

Use the smallest existing mechanism that satisfies the requirement: reuse,
POSIX/system tool, native host feature, installed dependency, then a new
dependency. This is a YAGNI rule for implementation size, not a license to
remove trust-boundary validation, cleanup, accessibility, or fail-closed
behavior.

The following states must remain distinguishable:

- clean scan: exit 0;
- detected secret/PII: exit 1 or host-specific block response;
- scan unavailable: exit 3 for direct scans, or the configured open/closed
  infrastructure response at a hook boundary.

## Portability acceptance matrix

| Surface | Adapter contract | Minimum proof |
|---|---|---|
| Claude Code | native hook JSON and response shape | pre/post/stop/prompt fixtures |
| Codex | native hook JSON and updated output shape | Agent/Task and post-tool fixtures |
| Git | staged repository scan, preserve existing hook | clean and secret commit fixtures |
| GitHub Actions | pinned scanner and action exit propagation | CI action plus real scanner check |
| Standalone | checksum-verified bootstrap/update | `doctor`, `check`, `smoke-test` |
| Homebrew tap | formula pins release URL and SHA-256 | generated formula syntax and version test |

Changes crossing more than one row require at least one fixture per affected
row. A passing unit test for the portable core alone is not proof that a host
dispatches the hook.
