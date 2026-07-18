# Agent Guard

[![Release](https://img.shields.io/github/v/release/JeongJaeSoon/agent-guard)](https://github.com/JeongJaeSoon/agent-guard/releases)
[![CI](https://github.com/JeongJaeSoon/agent-guard/actions/workflows/ci.yml/badge.svg)](https://github.com/JeongJaeSoon/agent-guard/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Deterministic secret-scanning guardrails for AI coding agents, Git hooks, GitHub Actions, and direct CLI scans.

Agent Guard blocks sensitive-file reads, secret-like tool inputs, risky credential-dumping commands, and secrets left in Git changes. It uses [gitleaks](https://github.com/gitleaks/gitleaks) for secret detection and plain shell scripts for integration.

It is not a vault, credential rotator, or replacement for GitHub Secret Scanning and Push Protection.

## Quick start

### Claude Code

Install Agent Guard from the Claude Code marketplace:

```text
/plugin marketplace add JeongJaeSoon/agent-guard
/plugin install agent-guard@agent-guard
/reload-plugins
```

### Codex

Enable plugin hooks and add the marketplace:

```sh
codex features enable plugin_hooks
codex plugin marketplace add JeongJaeSoon/agent-guard
```

Open `/plugins` in the Codex TUI, install **Agent Guard**, restart Codex, then open `/hooks` and trust its **PreToolUse**, **PostToolUse**, and **Stop** hooks.

### Verify

Ask Claude Code or Codex:

```text
Please read .env
```

Agent Guard should block the request:

```text
agent-guard: blocked sensitive file access: .env
```

## Other integrations

| Use case | Integration | Verification |
|---|---|---|
| Manual scans | [Direct CLI](docs/integrations.md#direct-cli) | Run `agent-guard smoke-test`. |
| Local commits | [Native pre-commit hook](docs/integrations.md#native-git-hook) | Commit a staged fixture secret; the commit should fail. |
| CI and pull requests | [GitHub Actions](docs/integrations.md#github-actions) | Push a fixture secret; the workflow should fail. |

## Protection scope

| Stage | Behavior |
|---|---|
| Before an agent tool runs | Blocks deny-listed reads, risky shell commands, and secret-like write, web, or MCP inputs. |
| After mutation tools and when the agent stops | Scans working-tree additions and untracked files. |
| Before a commit | Scans staged added lines. |
| In CI or the CLI | Scans the requested paths or Git changes. |

Deny-listed paths include `.env*`, private keys, `.aws/credentials`, `.npmrc`, and `.pypirc`. Patch and diff scans inspect added lines only, so removing an existing leak is allowed.

Policies are bundled and do not automatically trust a repository's local `.gitleaks.toml`. See [Configuration](docs/configuration.md) to override them explicitly.

## PII filtering

`pii-filter` is an optional, separate workflow that masks text from stdin:

```sh
printf '%s\n' 'Email jane@example.com from 203.0.113.42' | agent-guard pii-filter
# Email [PII:EMAIL] from [PII:IP_ADDRESS]
```

The supported providers are `regex` (local and default) and `http` (a compatible redaction endpoint). Agent hook enforcement is off by default and can only block PII; hooks cannot rewrite tool payloads.

See [PII filtering](docs/pii-filtering.md) for provider contracts, validation, limitations, and hook mode.

## Requirements

- Secret scans: `sh`, gitleaks 8.30 or newer recommended, and `git` for Git-based scans
- Agent hooks: `jq`
- Local PII filtering: `awk`
- HTTP PII filtering: `curl` and `jq`
- Bootstrap install: `curl`, `tar`, `shasum`, and `ln`

Plugin installs do not add `agent-guard` to the shell `PATH`. They still require `jq` and `gitleaks` for hooks.

## Documentation

- [Install and integration guide](docs/integrations.md)
- [PII filtering](docs/pii-filtering.md)
- [Configuration reference](docs/configuration.md)

## Development

```sh
make help
make test
make smoke-test
make scan
```

`make test` runs the deterministic routing suite. `make smoke-test` uses real `git`, `jq`, and `gitleaks` in temporary repositories.
