# Agent Guard

Agent Guard is a local-first guardrail for Claude Code, Codex, Git hooks,
GitHub Actions, and direct shell use. It blocks common secret-exposure paths
before a supported tool runs, redacts supported tool output, and scans changed
files after mutations. It uses `gitleaks` and portable shell; it has no hosted
account, telemetry collector, or developer service.

It is a defense-in-depth boundary. Keep GitHub Secret Scanning, Push
Protection, review, and normal credential management in place. Agent Guard is
not a vault, DLP system, EDR, or credential rotator.

![Agent Guard blocking an agent's read of a .env that holds a private key, then a scan flagging the leak](docs/demo.gif)

## Keep secrets out of Git

A key that lands in a commit lives in history long after you delete the file.
Agent Guard puts a gitleaks scan in front of the commit routes it hooks, so a
detected API key, token, or `.env` value is stopped before it enters history,
with CI behind it as a backstop:

| Who commits | What stops the leak |
| --- | --- |
| An agent in Claude Code or Codex | Before the agent's `git commit` or `git push` runs, the plugin scans the staged added lines and blocks the command on a secret-like value. It also refuses `--no-verify` and `--no-gpg-sign` on those commands, so the agent cannot switch the check off with a flag. |
| Any local commit, yours or an agent's | Once installed, the [native pre-commit hook](docs/integrations.md#native-git-hook) scans the staged added lines after Git has staged everything the commit will include, and aborts the commit on a finding or when the scan cannot run. Git skips it for `git commit --no-verify`; the plugin refuses that flag for agents, and CI covers the rest. |
| Anyone, after a push | The [GitHub Action](docs/integrations.md#github-actions) scans the checked-out files of each push or pull request it runs on, as the repository backstop. |

The plugin scans what the commit would contain. That covers the index and also
the tracked changes Git stages by itself for `git commit -a`, `--patch`, or a
pathspec such as `git commit <path>`, `--include`, or `--only`, and the
untracked files that `--interactive` can add. When an argument is only known at
run time, such as `git commit $FLAGS`, or the same command runs `git add` first,
the plugin scans every tracked change and untracked file, including ignored
files after `git add -f`. Shell code the command line passes to `bash -c`,
`sh -c`, a here-string, `env -S`, or `eval` is checked like the command
itself. When that code, the git subcommand, or the working directory is only
known at run time, the plugin cannot tell what the command commits, and the
infrastructure policy below decides.

The plugin scans the files as they are when the command starts. If an earlier
part of the same command writes a file, or changes into another repository,
the plugin does not see the result, so install the native hook as well. The
push gate checks what is staged, not commits that already exist. A secret
committed outside these hooks is caught by CI while it is still in the
checked-out tree.

A scan that could not run is not treated as clean. In the Claude Code and Codex
plugins, the default warns that protection is degraded and lets the command
continue, and `AGENT_GUARD_INFRA_FAILURE_MODE=closed` blocks it instead (see
[Configuration](docs/configuration.md)). The native hook and the Action fail on
an unavailable scan regardless of that setting.

## Choose your path

| I need to… | Start here |
| --- | --- |
| Install a Claude Code or Codex plugin, CLI, Git hook, or Action | [Installation](docs/installation.md) |
| Understand host coverage and configure an integration | [Integrations](docs/integrations.md) |
| Know which tool routes output masking reaches and how hosts differ | [Output masking coverage](docs/integrations.md#output-masking-coverage) |
| Verify a setup and understand what the result proves | [Verification](docs/verification.md) |
| Configure policy, PII, redaction, or infrastructure behavior | [Configuration](docs/configuration.md) |
| Deploy for a managed team or troubleshoot an environment | [Operations](docs/operations.md); the [Korean/Japanese deployment guide](https://agent-guard-guide.jaesoon.chatgpt.site/) is a supplementary, currently published walkthrough |

## Quick use

After installing a plugin, run its guided setup:

```text
# Claude Code
/agent-guard:setup-agent-guard

# Codex
$setup-agent-guard
```

The setup flow checks local dependencies and runs synthetic checks. It does not
prove that your current host tool route dispatches hooks; complete the harmless
live probes in [Verification](docs/verification.md) before relying on a plugin
boundary.

For a direct repository check:

```sh
agent-guard scan-working-tree
agent-guard scan-staged
agent-guard scan-path .
```

## Support log

Save the metadata-only local support log with one command:

```sh
agent-guard logs export --output agent-guard-support.jsonl
```

The parent directory must already exist. Agent Guard creates a new mode-0600
file and refuses to replace an existing file or symlink. Use the plugin-local
executable printed by the setup skill when a plugin-only installation does not
provide `agent-guard` on `PATH`. See [Support](SUPPORT.md) for what to submit.

## Requirements and scope

Supported platforms are macOS and Linux on x64 and arm64. Runtime dependencies
are `sh`, `awk`, `git`, `jq`, and gitleaks 8.30 or newer. Windows is not
currently supported. One of `setsid` (from `util-linux` on Linux) or Perl is
also required to run the gitleaks version probe in its own process group.
`agent-guard doctor` reports a missing isolation tool with the install command
for your platform.

Default processing is local and ephemeral. Read [Privacy](PRIVACY.md) before
enabling an endpoint-backed PII provider. Read [Security](SECURITY.md) for
responsible disclosure and [Support](SUPPORT.md) for safe reports.

## Project documents

- [Privacy and data handling](PRIVACY.md)
- [Security policy](SECURITY.md)
- [Support](SUPPORT.md)
- [Third-party notices](THIRD_PARTY_NOTICES.md)
- [Changelog](CHANGELOG.md)
- [Known limitations](docs/integrations.md#limits-and-backstops)
