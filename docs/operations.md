# Operations

## Managed Claude Code rollout

Merge the Agent Guard keys into existing organization JSON, rather than replacing
unrelated settings. Use `/Library/Application Support/ClaudeCode/managed-settings.json`
on macOS and `/etc/claude-code/managed-settings.json` on Linux/WSL.

Start from [`deployment/claude-managed-settings.example.json`](../deployment/claude-managed-settings.example.json).
It pins the marketplace source to a release tag, force-enables the plugin,
restricts marketplace sources, and disables automatic refreshes. Pin a reviewed
release tag; marketplace `ref` accepts a branch or tag, not a commit SHA. The
release workflow updates the canonical JSON example linked above. Merge that
file from the release you reviewed, then add the rollout's environment settings.
Change the tag only through an intentional, reviewed rollout.

The example intentionally has no `env` block. The product defaults are
`AGENT_GUARD_INFRA_FAILURE_MODE=open` and `AGENT_GUARD_PII_HOOK_MODE=off`. The
metadata-only local support log is available and default-on in v3.4.0 and later.
For a rollout that prioritizes secret protection, use
`AGENT_GUARD_INFRA_FAILURE_MODE=closed`.
PII is opt-in; do not force an
endpoint-backed provider without a separate privacy review. Set
`AGENT_GUARD_LOG_MODE=off` only in a release that contains the log and where
the metadata-only local support log is not permitted.

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

`setup-agent-guard` diagnoses the plugin-local binary and its dependencies; it
does not install a second Agent Guard CLI on `PATH`. `setup-shell` writes the
plugin's stable `current/bin` directory into the selected bash or zsh rc. After
restarting that shell, the same plugin-local executable is available as the
bare `agent-guard` command without Homebrew or the standalone bootstrap.

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

The plugin install and `setup-agent-guard` alone do not put `agent-guard` on
`PATH`. In Claude Code, run `/agent-guard:setup-shell`; it resolves the
plugin-local executable and
requests approval before changing the shell rc. If the host cannot approve that
write, run the exact plugin-local command shown by the skill in a terminal. Do
not substitute an unrelated standalone binary on `PATH`.

The following bare commands apply to a standalone install or to a bash/zsh
terminal restarted after `setup-shell`:

```sh
agent-guard setup-shell
agent-guard setup-shell --no-command-wrapping
```

Restart the shell and every Claude Code session launched from it. The default
installs command wrapping; `--no-command-wrapping` is the persistent opt-out and
`AGENT_GUARD_COMMAND_WRAPPING=off` is a runtime opt-out. The integration is
text-only and does not make interactive shell escapes a complete security
boundary.

### fish

`shell-init` emits POSIX shell code, so fish cannot evaluate it. A standalone
install can use `agent-guard exec -- <command>` directly. For a plugin-only
installation, use the stable plugin-cache resolver path printed by
`/agent-guard:setup-shell`; its normal shape is
`$HOME/.claude/plugins/cache/agent-guard/agent-guard/current/bin/agent-guard`.

```fish
function agx
    if type -q agent-guard
        command agent-guard exec -- $argv
        return $status
    end

    set -l _ag "$HOME/.claude/plugins/cache/agent-guard/agent-guard/current/bin/agent-guard"
    if not test -x "$_ag"
        printf 'agent-guard: plugin binary not found; rerun /agent-guard:setup-shell and use the fish executable path it prints\n' >&2
        return 127
    end
    command "$_ag" exec -- $argv
end
funcsave agx
```

The `current/bin/agent-guard` path is refreshed by plugin execution. If the
plugin cache is elsewhere, use the executable path printed by setup instead.

## Support evidence

Do not attach transcripts, raw stderr, `.env` files, private keys, or full hook
payloads. Include only the host, OS/architecture, Agent Guard version, command
or event category, outcome, and a manually sanitized error summary.

In v3.4.0 and later, `agent-guard logs export` provides a metadata-only JSONL
report.
It excludes content, paths, environment variables, session IDs, and arbitrary
tool names. [Support](../SUPPORT.md) has the current submission checklist.

From a restarted bash/zsh terminal after `setup-shell`, or from a standalone
installation, run:

```sh
agent-guard logs status
(umask 077; agent-guard logs export > agent-guard-support.jsonl)
```

From fish, before restart, or after failed shell setup, do not run that bare
command. Rerun the host setup skill and copy the complete plugin-local log
command it prints; this avoids selecting an unrelated standalone version. If
the path is still unavailable, report the failure without creating a substitute
diagnostic dump.

If `logs status` reports logging off, enable the approved rollout setting and
reproduce with synthetic data. If export reports that `jq` is missing, approve
the dependency repair proposed by the setup skill and retry. If storage is
unavailable, export is empty after a reproduced event, or only a start record
exists, report that state with the version, host, OS/architecture, time and time
zone, and a manually sanitized error summary. Do not replace the safe export
with a raw transcript, stderr dump, environment dump, or original
secret-bearing input.

## Staged expansion

This expansion plan applies to the managed Claude Code rollout above. Keep a
change-ticket table owned by the named rollout owner, with one row for every
device in the current cohort and no sensitive values. Start with 2–3
maintainers, then expand to cumulative cohorts of 10, 20, 50, and 100 users.
Hold each cohort for at least one business day; hold the 100-user cohort for at
least two business days before declaring the rollout stable.

Use the [rollout acceptance record](../deployment/claude-rollout-acceptance.example.md)
as the copyable evidence template.

Every device in a cohort must report the approved plugin version and managed
setting source, successful setup and smoke checks, both live hook probes, a
normal command with exit 0, and a safe log export. The export must contain the
corresponding coarse outcomes: `blocked` for the pre-tool probe, `masked` for
the post-tool probe, and `pass` for the normal command. Stop expansion on any
raw synthetic marker, `DEGRADED` result, unexpected block, missing log evidence,
or version/source drift. Record the rollback owner and previous reviewed tag
before the first cohort.

Run Codex as a separate pilot. Record per-user hook trust and live-probe results
instead of a Claude managed-setting source; this document does not claim a
central Codex managed-settings mechanism.
