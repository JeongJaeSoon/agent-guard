# Agent Guard

[![Release](https://img.shields.io/github/v/release/JeongJaeSoon/agent-guard)](https://github.com/JeongJaeSoon/agent-guard/releases)
[![CI](https://github.com/JeongJaeSoon/agent-guard/actions/workflows/ci.yml/badge.svg)](https://github.com/JeongJaeSoon/agent-guard/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Deterministic secret-scanning guardrails for Claude Code, Codex, Git hooks, GitHub Actions, and direct CLI scans.

Agent Guard blocks common ways an AI coding agent can accidentally expose secrets: reading `.env`, writing secret-like values, running shell commands that dump credentials, or leaving secrets in the working tree after a tool call. It uses [gitleaks](https://github.com/gitleaks/gitleaks) for detection and plain shell scripts for integration.

It is not a vault, credential rotator, or replacement for GitHub Secret Scanning / Push Protection.

## Pick an install path

| Use case | Install path | Best first check |
|---|---|---|
| Claude Code agent guardrails | [Claude Code plugin](#claude-code-plugin) | Ask the agent to read `.env`; it should be blocked. |
| Codex stable guardrails | [Codex direct CLI + Git hook](#codex-plugin) | Run `agent-guard smoke-test`; commit a staged fixture secret, and it should fail. |
| Codex experimental plugin hooks | [Codex plugin](#codex-plugin) | Enable `plugin_hooks`, trust hooks in `/hooks`, then ask Codex to read `.env`; it should be blocked. |
| Local commits | [Native Git hook](#native-git-hook) | Commit a staged fixture secret; commit should fail. |
| CI / PRs | [GitHub Actions](#github-actions) | Push a test PR with a gitleaks-detectable fixture; workflow should fail. |
| Manual scans | [Direct CLI](#direct-cli) | Run `agent-guard smoke-test`. |

## Requirements

Agent Guard runs on macOS and Linux and expects:

- `sh`
- `git`
- `jq`
- `gitleaks` 8.30 or newer recommended

Install paths that download release archives also use `curl`, `tar`, `shasum`, and `ln`.

The PII filter has a built-in regex backend for common identifiers. The optional
[pleno-anonymize](https://github.com/plenoai/pleno-anonymize) backend calls a
self-hosted `/api/redact` HTTP endpoint with `curl`; it does not add a Python
runtime dependency to Agent Guard.

With a direct CLI install:

```sh
agent-guard setup   # prints dependency status and install hints
agent-guard check   # strict pass/fail dependency check
agent-guard smoke-test
```

From a clone of this repo:

```sh
plugins/agent-guard/bin/agent-guard setup
make check
make smoke-test
```

The Claude Code and Codex plugin installs do not put `agent-guard` on your shell `PATH`; install `jq` and `gitleaks` with your package manager for those paths:

```sh
brew install jq gitleaks
```

On Debian / Ubuntu or Fedora, install `jq` with the system package manager and download `gitleaks` from its release page.

## Claude Code Plugin

Install from the marketplace:

```text
/plugin marketplace add JeongJaeSoon/agent-guard
/plugin install agent-guard@agent-guard
/reload-plugins
```

Smoke test:

```text
Please read .env
```

Expected result:

```text
agent-guard: blocked sensitive file access: .env
```

Useful Claude Code slash commands:

```text
/agent-guard:verify
/agent-guard:checksum [VERSION]
```

## Codex Plugin

Use the direct CLI plus the native Git hook as the stable Codex path:

```sh
curl -fsSL https://github.com/JeongJaeSoon/agent-guard/releases/latest/download/bootstrap.sh | sh
agent-guard scan-working-tree
~/.agent-guard/install.sh git-hooks
```

That path gives you on-demand scans and commit-time blocking.

Codex plugin hooks are still behind an under-development Codex feature flag. If you accept that warning and want pre-tool read/write/bash guardrails, enable plugin hooks and install from the marketplace:

```sh
codex features enable plugin_hooks
codex plugin marketplace add JeongJaeSoon/agent-guard
```

Then open `/plugins` in the Codex TUI, install **Agent Guard**, restart Codex, open `/hooks`, and trust the **PreToolUse**, **PostToolUse**, and **Stop** hooks.

Smoke test:

```text
Please read .env
```

Expected result:

```text
agent-guard: blocked sensitive file access: .env
```

Codex does not currently auto-discover this plugin's `commands/` directory. Ask Codex to run the binary directly when you need those workflows:

```sh
${CODEX_PLUGIN_ROOT}/bin/agent-guard scan-working-tree
${CODEX_PLUGIN_ROOT}/bin/agent-guard checksum
```

## Direct CLI

Install the latest release without cloning:

```sh
curl -fsSL https://github.com/JeongJaeSoon/agent-guard/releases/latest/download/bootstrap.sh | sh
```

The installer verifies the release archive checksum, extracts to `~/.agent-guard`, links `agent-guard` into `~/.local/bin`, and runs `agent-guard setup`.

Common commands:

```sh
agent-guard scan-path .
agent-guard scan-working-tree
agent-guard scan-staged
agent-guard setup
agent-guard smoke-test
agent-guard pii-filter
agent-guard checksum
```

Override install defaults with `AGENT_GUARD_VERSION`, `AGENT_GUARD_HOME`, or `AGENT_GUARD_BIN_DIR`.

## Native Git Hook

Install from a clone or direct CLI install:

```sh
cd <your-project>
~/.agent-guard/install.sh git-hooks
```

From a clone of this repo:

```sh
./install.sh git-hooks
```

This sets `core.hooksPath=githooks` only when it will not overwrite an existing hook setup.

## GitHub Actions

Add a workflow step:

```yaml
- uses: JeongJaeSoon/agent-guard@v1
  with:
    paths: "."
    gitleaks-checksum: "<sha256 of the gitleaks release archive>"
```

Use `@v1` for compatible updates, or pin a full tag / commit SHA for stricter reproducibility.

Get the checksum with:

```sh
agent-guard checksum
```

CI runners are usually `linux/x64`, so use the `linux/x64` value printed by the checksum command. `require-checksum` defaults to `true`; set it to `false` only for local experimentation.

## What Gets Blocked

- `Read`, `NotebookRead`, `Grep`, and `Glob` access to deny-listed paths such as `.env*`, private keys, `.aws/credentials`, `.npmrc`, and `.pypirc`
- `Write`, `Edit`, `MultiEdit`, and Codex `apply_patch` content containing secret-like values
- `WebFetch`, `WebSearch`, and MCP tool input JSON containing secret-like values
- risky shell commands such as `printenv`, `op read`, `vault kv get`, `aws secretsmanager get-secret-value`, `cat .env`, and `git commit --no-verify`
- staged added lines in the native pre-commit hook
- working-tree added lines and untracked files after agent mutations
- optional PII in proposed tool input when `AGENT_GUARD_PII_HOOK_MODE=block`

Patch and diff scans inspect added lines only. Removing an existing leaked value is allowed.

## PII Filtering

Use `pii-filter` when text should be masked before it leaves the local workflow:

```sh
printf '%s\n' 'Contact jane.doe@example.com at 090-1234-5678' \
  | agent-guard pii-filter
```

Default output uses deterministic placeholders such as `<EMAIL_ADDRESS>` and
`<PHONE_NUMBER>`. For stronger Japanese / English PII detection, run a local
pleno-anonymize service and point Agent Guard at its redaction endpoint:

```sh
AGENT_GUARD_PII_REDACT_URL=http://127.0.0.1:8080/api/redact \
AGENT_GUARD_PII_LANGUAGE=ja \
agent-guard pii-filter --backend pleno < prompt.txt
```

Agent hooks cannot safely rewrite a pending tool call in place. For that reason
PII masking is a CLI preprocessing flow, while hook enforcement is block-only:

```sh
AGENT_GUARD_PII_HOOK_MODE=block
```

When enabled, proposed writes, shell commands, WebFetch/WebSearch inputs, and
MCP tool inputs are checked for PII after the normal secret scan. If PII is
detected, the hook blocks and points the agent back to `agent-guard pii-filter`
so the text can be masked explicitly.

## Configuration

Override bundled policies with environment variables:

```sh
AGENT_GUARD_GITLEAKS_CONFIG=/path/to/gitleaks.toml
AGENT_GUARD_DENY_READ_PATHS=/path/to/deny-read-paths.txt
AGENT_GUARD_DENY_BASH_PATTERNS=/path/to/deny-bash-patterns.txt
AGENT_GUARD_PII_HOOK_MODE=off|block
AGENT_GUARD_PII_BACKEND=regex|pleno
AGENT_GUARD_PII_REDACT_URL=http://127.0.0.1:8080/api/redact
AGENT_GUARD_PII_LANGUAGE=en
```

Project-local `.gitleaks.toml` files are not automatically trusted.

## Checksums and Auto-Install

`agent-guard setup --install` can install `gitleaks`, but only with an explicit checksum:

```sh
agent-guard checksum
agent-guard setup --install \
  --gitleaks-version 8.30.1 \
  --gitleaks-checksum <sha256-for-this-os-and-arch>
```

The checksum helper prints all supported OS / arch values and paste-ready snippets for CLI setup and GitHub Actions.

## Development

```sh
make help
make test
make smoke-test
make scan
make scan-staged
make checksum
```

`make smoke-test` uses real `git`, `jq`, and `gitleaks` in temporary projects. `make test` is the faster deterministic routing suite and uses a mock scanner for some cases.
