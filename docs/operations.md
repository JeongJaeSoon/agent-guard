# Operations

## Managed team rollout

An administrator should publish a reviewed plugin marketplace source, install or
enable the plugin through the organization’s approved host mechanism, and make
the runtime dependencies available on each managed machine. Installing a plugin
does not itself trust or deploy its hook scripts on every host; follow each
host’s trust and device-management policy.

Each developer then runs the host-appropriate setup skill, approves any
dependency installation, restarts the host/session when asked, and completes
the live probes in [Verification](verification.md). Keep managed policy changes
small and repeat this acceptance path after an update.

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

## Support evidence

Do not attach transcripts, raw stderr, `.env` files, private keys, or full hook
payloads. Include only the host, OS/architecture, Agent Guard version, command
or event category, outcome, and a manually sanitized error summary.

When available, `agent-guard logs export` provides a metadata-only JSONL report.
It excludes content, paths, environment variables, session IDs, and arbitrary
tool names. [Support](../SUPPORT.md) has the current submission checklist.
