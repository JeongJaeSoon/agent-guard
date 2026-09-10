# Operations

## Managed Claude Code rollout

Merge the Agent Guard keys into existing organization JSON, rather than replacing
unrelated settings. Use `/Library/Application Support/ClaudeCode/managed-settings.json`
on macOS and `/etc/claude-code/managed-settings.json` on Linux/WSL.

Start from [`deployment/claude-managed-settings.example.json`](../deployment/claude-managed-settings.example.json).
It pins the marketplace source to a release tag, force-enables the plugin,
restricts marketplace sources, and disables automatic refreshes. Pin a reviewed
release tag such as `v3.3.0`; marketplace `ref` accepts a branch or tag, not a
commit SHA. Change the tag only through an intentional, reviewed rollout.

```json
{
  "extraKnownMarketplaces": {
    "agent-guard": {
      "source": {
        "source": "github",
        "repo": "JeongJaeSoon/agent-guard",
        "ref": "v3.3.0"
      },
      "autoUpdate": false
    }
  },
  "enabledPlugins": { "agent-guard@agent-guard": true },
  "strictKnownMarketplaces": [{
    "source": "github",
    "repo": "JeongJaeSoon/agent-guard",
    "ref": "v3.3.0"
  }]
}
```

The example intentionally has no `env` block. Keep the default local policy:
`AGENT_GUARD_INFRA_FAILURE_MODE=open`, `AGENT_GUARD_PII_HOOK_MODE=off`, and
metadata logging enabled. For a stricter pilot, set
`AGENT_GUARD_INFRA_FAILURE_MODE=closed`. PII is opt-in; do not force an
endpoint-backed provider without a separate privacy review. Set
`AGENT_GUARD_LOG_MODE=off` only where the metadata-only local support log is
not permitted.

After policy delivery, each developer runs the host setup skill, approves any
dependency installation, restarts the host/session when asked, and completes
the live probes in [Verification](verification.md). Repeat this acceptance path
after every version or policy update.

In Claude Code, the user-facing sequence is:

```text
/agent-guard:setup-agent-guard
/agent-guard:setup-shell
/agent-guard:verify
```

The first skill resolves the installed plugin-local binary, so it remains
correct when a different standalone version is present on `PATH`. The last
command is a working-tree scan; it does not prove hook dispatch. Complete both
live probes after it.

For Codex, hooks are reviewed by their exact current definition. A changed hook
must be reviewed/trusted again before it runs. See official [Codex Hooks](https://learn.chatgpt.com/docs/hooks).

## Troubleshooting

| Symptom | Meaning and next action |
| --- | --- |
| `DEGRADED` | A dependency or policy could not be verified. Run `doctor`, then setup; it is not a clean scan. |
| `setup ok (dependencies only)` | Local dependencies are available. Run the live route probes. |
| Probe prints its raw marker | The tested route did not dispatch the expected hook. Check trust, restart, and retain Git/CI backstops. |
| A benign command is blocked as a protected path | The shell matcher saw path-shaped text. Use a clearly non-path-shaped expression after reviewing the command. |
| Post-write scan is unavailable | Treat it as infrastructure failure under the configured policy; do not claim the file was clean. |

## Claude shell integration

Plugin installs deliberately do not put `agent-guard` on `PATH`. In Claude Code,
run `/agent-guard:setup-shell`; it resolves the plugin-local executable and
requests approval before changing the shell rc. If the host cannot approve that
write, run the exact plugin-local command shown by the skill in a terminal. Do
not substitute an unrelated standalone binary on `PATH`.

```sh
agent-guard setup-shell
agent-guard setup-shell --no-command-wrapping
```

Restart the shell and every Claude Code session launched from it. The default
installs command wrapping; `--no-command-wrapping` is the persistent opt-out and
`AGENT_GUARD_COMMAND_WRAPPING=off` is a runtime opt-out. The integration is
text-only and does not make interactive shell escapes a complete security
boundary.

## Support evidence

Do not attach transcripts, raw stderr, `.env` files, private keys, or full hook
payloads. Include only the host, OS/architecture, Agent Guard version, command
or event category, outcome, and a manually sanitized error summary.

The metadata log is introduced after v3.3.0. When available,
`agent-guard logs export` provides a metadata-only JSONL report.
It excludes content, paths, environment variables, session IDs, and arbitrary
tool names. [Support](../SUPPORT.md) has the current submission checklist.
