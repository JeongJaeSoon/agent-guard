# Privacy and Data Handling

Last updated: 2026-07-18

Agent Guard is local by default. The project does not operate an Agent Guard
service, account system, telemetry collector, crash reporter, or analytics
endpoint. Default hook processing does not transmit inspected data and does not
retain it after the hook or command finishes.

## What the plugin processes

When enabled, Agent Guard registers hooks for `SessionStart`, `PreToolUse`,
`PostToolUse`, and `Stop`.

| Surface | Data inspected | Purpose | Persistent storage |
|---|---|---|---|
| `PreToolUse` | Matched tool names and inputs, including paths, proposed content, shell commands, URLs/search queries, and MCP arguments | Block deny-listed reads, credential-dumping commands, secret-like input, and opt-in PII classes before execution | None |
| `PostToolUse` | Matched tool outputs; after mutation tools, changed and untracked files in the current Git work tree | Mask secret-like output and opt-in PII; detect secrets written to the work tree | None |
| `Stop` | Changed and untracked files in the current Git work tree | Final working-tree secret scan | None |
| `SessionStart` | Dependency availability and Agent Guard shell-integration version marker | Report degraded setup or version drift | None |
| CLI and shell wrappers | Only stdin, paths, or command output explicitly passed by the user | On-demand scan or masking | None |

Temporary scan reports and provider responses are created under a single
per-invocation directory inside the operating system temporary directory and
removed by a cleanup trap when the operation exits — including on the
interrupting signals a host actually sends: SIGTERM when it kills a hook at its
timeout, and SIGINT on Ctrl-C. Only an un-trappable SIGKILL can bypass this,
leaving those temporary files for the operating system's temporary-directory
reaper to remove. Agent Guard does not write inspected tool content to its own
log or database. The host application may independently retain tool inputs and
outputs under its own privacy policy.

## Network behavior

Normal lifecycle hooks and the built-in `regex` PII provider make no outbound
network calls. Web and MCP tool inputs are inspected locally before the host
decides whether to execute those tools; Agent Guard does not forward them.

The following explicit actions use the network:

- `agent-guard checksum` fetches the published gitleaks checksum list from
  GitHub Releases. It sends no project or tool content.
- Approval-gated `agent-guard setup --install` downloads a versioned gitleaks
  archive from GitHub Releases and requires its SHA-256. It sends no project or
  tool content.
- The standalone `bootstrap.sh` install path downloads Agent Guard's release
  archive and checksum from this project's GitHub Releases page.
- If the user selects `AGENT_GUARD_PII_PROVIDER=pleno` or `http`,
  `agent-guard pii-filter` sends the complete text provided on stdin to the
  exact URL in `AGENT_GUARD_PII_REDACT_URL`. In
  `AGENT_GUARD_PII_HOOK_MODE=block`, supported tool-input text is sent to that
  same endpoint to determine whether it contains PII. The endpoint's operator,
  not Agent Guard, controls its collection, retention, and deletion practices.

PII hook handling defaults to `off`; the default provider is the local `regex`
adapter. `mask` mode performs input Tier-2 detection and output masking locally,
even if an HTTP provider is configured. Agent Guard never chooses or enables a
remote PII endpoint on the user's behalf.

## User controls

- Disable or uninstall the plugin to stop all Agent Guard lifecycle hooks.
- Keep `AGENT_GUARD_PII_HOOK_MODE=off` to disable PII processing in hooks.
- Use `AGENT_GUARD_PII_PROVIDER=regex` to keep `pii-filter` local.
- Set `AGENT_GUARD_OUTPUT_REDACT=off` to disable secret-like output masking.
  This reduces protection and is not recommended.
- Decline the guided setup installation prompt to prevent software downloads.

For vulnerabilities, use the private channel in [SECURITY.md](SECURITY.md).
For questions and support, see [SUPPORT.md](SUPPORT.md).
