# Agent Guard

Agent Guard inserts deterministic secret-scanning checks into AI coding agent hooks, native Git hooks, and GitHub Actions.

It is intentionally small. It does not teach agents how to behave, manage vaults, rotate credentials, verify live credentials, produce dashboards, or replace GitHub Secret Scanning and Push Protection.

## Requirements

- `sh`
- `jq`
- `git`
- `gitleaks`
- standard macOS/Linux Unix utilities

No Python, Node, npm hook manager, Docker, Go/Rust runtime, skills, prompts, or reporting layer is required.

## Commands

```sh
bin/agent-guard hook-pre-tool
bin/agent-guard hook-post-tool
bin/agent-guard hook-stop
bin/agent-guard scan-staged
bin/agent-guard scan-working-tree
bin/agent-guard scan-path PATH...
```

Hook commands read Claude Code or Codex hook JSON from stdin. Direct scan commands are used by Git hooks, GitHub Actions, and manual checks.

Exit codes:

- `0`: clean / allow
- `1`: findings for direct scan commands
- `2`: block an agent hook action or signal usage/dependency failure

## What It Checks

- Proposed writes from `Write`, `Edit`, `MultiEdit`, and Codex `apply_patch`
- Sensitive read/search paths such as `.env*`, private keys, `.aws/credentials`, `.npmrc`, `.pypirc`
- Obvious risky shell commands such as `cat .env`, `printenv`, `op read`, `vault kv get`, `aws secretsmanager get-secret-value`
- MCP tool input JSON
- Staged added lines for `pre-commit`
- Working tree added lines and untracked file content after agent mutations

Patch and diff scans inspect added lines only so removing an existing leaked value is not blocked by the deleted line.

## Install Checks

```sh
./install.sh check
```

## Native Git Hook

Agent Guard uses native Git hooks. It does not require Husky, npm, or another hook manager.

```sh
./install.sh git-hooks
```

The installer sets `core.hooksPath=githooks` only when it will not overwrite an existing hook setup.

## Claude Code

As a plugin, Agent Guard loads `.claude-plugin/plugin.json`, which points at `./hooks/hooks.json`.

For local testing, adapt `examples/claude/settings.project.json` and replace `/absolute/path/to/agent-guard` with this repository path.

For marketplace distribution, `.claude-plugin/marketplace.json` points at `JeongJaeSoon/agent-guard` by default.

## Codex

Codex loads `.codex-plugin/plugin.json`, which points at `./hooks/hooks.json`.

For local testing, use `examples/codex/hooks.json` or install the plugin through a marketplace entry after replacing the placeholder owner metadata.

## GitHub Actions

The root `action.yml` lets consumers use the repository directly:

```yaml
- uses: JeongJaeSoon/agent-guard@v1
  with:
    paths: "."
```

For high-security environments, pin to a full commit SHA instead of a moving tag.

## Configuration

Agent Guard always passes the bundled `config/gitleaks.toml` unless you explicitly override it:

```sh
AGENT_GUARD_GITLEAKS_CONFIG=/path/to/gitleaks.toml bin/agent-guard scan-path .
```

Policy files:

- `config/gitleaks.toml`
- `config/deny-read-paths.txt`
- `config/deny-bash-patterns.txt`

Project-local `.gitleaks.toml` files are not automatically trusted.

## Tests

```sh
tests/run.sh
```

The default test suite uses a mock `gitleaks` to validate routing and policy behavior without downloading dependencies. If real `gitleaks` is installed, direct manual scans can be run with `bin/agent-guard scan-path .`.
