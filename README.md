# Agent Guard

[![Release](https://img.shields.io/github/v/release/JeongJaeSoon/agent-guard)](https://github.com/JeongJaeSoon/agent-guard/releases) [![GitHub Marketplace](https://img.shields.io/badge/Marketplace-Agent%20Guard-2EA44F?logo=github)](https://github.com/marketplace/actions/agent-guard-secret-guardrails) [![CI](https://github.com/JeongJaeSoon/agent-guard/actions/workflows/ci.yml/badge.svg)](https://github.com/JeongJaeSoon/agent-guard/actions/workflows/ci.yml) [![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

**Stop your AI coding agent from leaking secrets — in real time, before the tool call runs.**

![Agent Guard blocking an agent's read of a .env that holds a private key, then a scan flagging the leak](docs/demo.gif)

Agent Guard is a deterministic guardrail for AI coding agents (Claude Code, Codex) and the Git hooks, CI, and CLI around them. It blocks common ways an agent accidentally exposes secrets: reading `.env`, writing secret-like values, running shell commands that dump credentials, or leaving secrets in the working tree after a tool call. It uses [gitleaks](https://github.com/gitleaks/gitleaks) for detection and plain shell scripts for integration.

Unlike commit- or CI-time scanners that catch a leak *after* it lands, Agent Guard also runs at the agent's tool boundary — the `.env` read or secret write is blocked before it happens. Pair it with commit/CI scanning for defense in depth.

It is not a vault, credential rotator, or replacement for GitHub Secret Scanning / Push Protection.

## Quick start (Claude Code)

Install from the marketplace:

```text
/plugin marketplace add JeongJaeSoon/agent-guard
/plugin install agent-guard@agent-guard
/reload-plugins
```

Verify it's live — ask the agent to read your `.env`:

```text
Please read .env
```

It should refuse:

```text
agent-guard: blocked sensitive file access: .env
```

Detection needs `jq` and `gitleaks` on your machine (`brew install jq gitleaks`; see [Requirements](#requirements) for Linux). Using Codex, Git hooks, or CI instead? Pick your path below.

## Pick an install path

| Use case | Install path | Best first check |
|---|---|---|
| Claude Code agent guardrails | [Quick start (Claude Code)](#quick-start-claude-code) | Ask the agent to read `.env`; it should be blocked. |
| Codex stable guardrails | [Codex direct CLI + Git hook](#codex-plugin) | Run `agent-guard smoke-test`; commit a staged fixture secret, and it should fail. |
| Codex experimental plugin hooks | [Codex plugin](#codex-plugin) | Enable `plugin_hooks`, trust hooks in `/hooks`, then ask Codex to read `.env`; it should be blocked. |
| Local commits | [Native Git hook](#native-git-hook) | Commit a staged fixture secret; commit should fail. |
| CI / PRs | [GitHub Actions](#github-actions) | Push a test PR with a gitleaks-detectable fixture; workflow should fail. |
| Manual scans | [Direct CLI](#direct-cli) | Run `agent-guard smoke-test`. |

## Requirements

Agent Guard runs on macOS and Linux and expects:

- `sh`
- `awk`
- `git`
- `jq`
- `gitleaks` 8.30 or newer recommended

Install paths that download release archives also use `curl`, `tar`, `shasum`, and `ln`.
PII endpoint providers also use `curl`.

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

Install and verify in [Quick start (Claude Code)](#quick-start-claude-code). Useful slash commands once installed:

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
${PLUGIN_ROOT}/bin/agent-guard scan-working-tree
${PLUGIN_ROOT}/bin/agent-guard checksum
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
agent-guard pii-filter
agent-guard setup
agent-guard smoke-test
agent-guard checksum
```

Override install defaults with `AGENT_GUARD_VERSION`, `AGENT_GUARD_HOME`, or `AGENT_GUARD_BIN_DIR`.

## PII Filtering

`agent-guard pii-filter` reads text from stdin, masks detected PII, and writes the masked text to stdout. The default provider is `regex`, a built-in shell/awk adapter with no Python runtime dependency:

```sh
printf '%s\n' 'Email jane@example.com from 203.0.113.42' | agent-guard pii-filter
# Email [PII:EMAIL] from [PII:IP_ADDRESS]
```

The built-in regex provider masks common deterministic formats: email addresses, phone numbers, credit cards, US SSNs, and IP addresses. Clean text is passed through unchanged.

Choose a provider with `AGENT_GUARD_PII_PROVIDER`:

```sh
AGENT_GUARD_PII_PROVIDER=regex agent-guard pii-filter --check
```

Endpoint-backed providers are available for external redaction services:

```sh
AGENT_GUARD_PII_PROVIDER=pleno \
AGENT_GUARD_PII_REDACT_URL=http://127.0.0.1:8080/api/redact \
agent-guard pii-filter --check

printf '%s\n' 'Customer jane@example.com' \
  | AGENT_GUARD_PII_PROVIDER=pleno \
    AGENT_GUARD_PII_REDACT_URL=http://127.0.0.1:8080/api/redact \
    agent-guard pii-filter
```

`pleno` and `http` use the same HTTP adapter: POST JSON as `{"text":"..."}` and read a redacted string from `redacted_text`, `anonymized_text`, `text`, or `data.redacted_text`. They require `curl`, `jq`, and `AGENT_GUARD_PII_REDACT_URL`; missing tools, missing URL, HTTP errors, invalid JSON, or unexpected response shapes fail closed.

Agent Guard does not install, import, run, or manage `pleno-anonymize`, Docker, Python, or any hosted service. If you use `pleno`, run pleno-anonymize separately or point `AGENT_GUARD_PII_REDACT_URL` at a hosted compatible endpoint.

Masking is a CLI workflow. Agent hooks cannot safely rewrite pending tool payloads, so hook PII enforcement is off by default. To block tool inputs containing PII, opt in explicitly:

```sh
AGENT_GUARD_PII_HOOK_MODE=block
```

In block mode, proposed `Write`, `Edit`, `MultiEdit`, `apply_patch`, `Bash`, `WebFetch`, `WebSearch`, and MCP inputs are blocked when PII is detected, with guidance to run `agent-guard pii-filter` first. `AGENT_GUARD_PII_HOOK_MODE=mask` is rejected because hooks cannot perform safe in-flight masking.

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

### Codex Code Review

This repository also includes `.github/workflows/codex-review.yml`, which runs [openai/codex-action](https://github.com/openai/codex-action) on non-draft pull requests and posts Codex feedback as a PR comment.

To enable it, add an Actions secret named `OPENAI_API_KEY` in the GitHub repository settings. The workflow intentionally runs on `pull_request`, checks out the PR merge commit without persisted Git credentials, and runs Codex in a read-only sandbox with `drop-sudo`.

## What Gets Blocked

- `Read`, `NotebookRead`, `Grep`, and `Glob` access to deny-listed paths such as `.env*`, private keys, `.aws/credentials`, `.npmrc`, and `.pypirc`
- `Write`, `Edit`, `MultiEdit`, and Codex `apply_patch` content containing secret-like values
- `WebFetch`, `WebSearch`, and MCP tool input JSON containing secret-like values
- risky shell commands such as `printenv`, `op read`, `vault kv get`, `aws secretsmanager get-secret-value`, `cat .env`, and `git commit --no-verify`
- PII in proposed write, shell, web, or MCP inputs only when `AGENT_GUARD_PII_HOOK_MODE=block`
- staged added lines in the native pre-commit hook
- working-tree added lines and untracked files after agent mutations

Patch and diff scans inspect added lines only. Removing an existing leaked value is allowed.

## What Gets Masked

Beyond blocking, Agent Guard **masks** secret-like values in a tool's *output* before the model sees them. A `PostToolUse` redactor scans the result of `Bash` (stdout/stderr) and read-style tools (`Read`, `NotebookRead`, `Grep`, `Glob`, `WebFetch`, `WebSearch`, and `mcp__.*`) and rewrites any detected secret to `[REDACTED]` in place via `updatedToolOutput`, preserving the result's shape. This closes the gap where a command *prints* a credential the pre-tool check never saw — e.g. `cat memo.txt`, an env-printing CLI, or a tool that dumps `KEY=value` pairs. Detection combines gitleaks with a `KEY=value` env-assignment heuristic. It is on by default; disable with `AGENT_GUARD_OUTPUT_REDACT=off`.

## Known Limitations

Agent Guard is a deterministic, thin guardrail — not a DLP system, EDR, or vault. It scans tracked diffs, staged changes, and untracked files with gitleaks, and blocks a fixed list of sensitive paths and shell idioms. It deliberately does **not** inspect arbitrary file contents that a command reads, and it has these blind spots by design:

- **Gitignored files are not scanned.** The working-tree and post-tool/stop backstops use `git ls-files --others --exclude-standard` and `git diff`, both of which skip `.gitignore`d paths. A secret written to a gitignored file (e.g. `secrets/` or `*.local`) is not caught by the backstop. Keep real secrets out of the repo entirely.
- **Only files inside the git work tree are covered.** The post-tool and stop hooks no-op outside a git repository, and scans are scoped to the current repo. Files outside the repo root, or written when no repo is present, get no backstop. Use `agent-guard scan-path <dir>` to scan an arbitrary tree on demand.
- **Path and command blocking use fixed lists.** Read/Grep/Glob blocking matches the paths in `deny-read-paths.txt`; shell blocking matches the idioms in `deny-bash-patterns.txt`. A secret in an unlisted path, or read by an unlisted tool or flag, is not blocked. Extend the lists with `AGENT_GUARD_DENY_READ_PATHS` / `AGENT_GUARD_DENY_BASH_PATTERNS`.
- **Output masking is best-effort.** Secret-like values in a tool's output (`Bash` stdout/stderr, file reads) are masked in place by the `PostToolUse` redactor (`AGENT_GUARD_OUTPUT_REDACT`, on by default), but detection is heuristic — gitleaks plus a `KEY=value` env-assignment rule. Unusual or custom secret formats can still slip through, and the redactor only sees results of the agent's *tool calls*. Treat output masking as defense in depth and keep real secrets out of agent sessions entirely.
- **Bash detection is pattern-based.** The denylist targets common-accident and obvious-malicious idioms; an actively-evading agent can craft a command that matches none of them. Treat shell blocking as defense in depth, not a complete adversarial boundary.

For defense in depth, pair Agent Guard with GitHub Secret Scanning / Push Protection and a secrets manager so credentials never reach the working tree.

## Configuration

Override bundled policies with environment variables:

```sh
AGENT_GUARD_GITLEAKS_CONFIG=/path/to/gitleaks.toml
AGENT_GUARD_DENY_READ_PATHS=/path/to/deny-read-paths.txt
AGENT_GUARD_DENY_BASH_PATTERNS=/path/to/deny-bash-patterns.txt
AGENT_GUARD_PII_PROVIDER=regex
AGENT_GUARD_PII_REDACT_URL=http://127.0.0.1:8080/api/redact
AGENT_GUARD_PII_HOOK_MODE=off
AGENT_GUARD_OUTPUT_REDACT=mask
```

Set `AGENT_GUARD_OUTPUT_REDACT=off` to disable masking secret-like values in tool output (default `mask`).

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

## Host Integrations

Agent Guard shares its scanner implementation across Claude Code and Codex, but keeps host wiring explicit:

- `plugins/agent-guard/bin/agent-guard`, `config/`, and `scripts/` are shared.
- Claude Code uses `.claude-plugin/plugin.json`, `commands/`, and `hooks/hooks.json`.
- Codex uses `.codex-plugin/plugin.json` and the plugin-root `hooks.json` companion file.
- Codex does not auto-discover `commands/`, so on-demand workflows use the binary directly.

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
