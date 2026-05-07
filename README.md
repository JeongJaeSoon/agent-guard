# Agent Guard

Agent Guard inserts deterministic secret-scanning checks into AI coding agent hooks, native Git hooks, and GitHub Actions.

It is intentionally small. It does not teach agents how to behave, manage vaults, rotate credentials, verify live credentials, produce dashboards, or replace GitHub Secret Scanning and Push Protection.

## Quickstart

Pick the channel matching your environment. All commands resolve to the same released version.

### Prerequisites

`sh`, `git`, `jq`, and [`gitleaks`](https://github.com/gitleaks/gitleaks) (>= 8.30 recommended) on macOS or Linux. No Python, Node, npm hook manager, Docker, or other runtime is required. If `gitleaks` is missing, the first hook invocation will fail with a clear error.

### Claude Code

```text
/plugin marketplace add JeongJaeSoon/agent-guard
/plugin install agent-guard@latest
```

### Codex

```text
/plugin install JeongJaeSoon/agent-guard@latest
```

### GitHub Actions

```yaml
- uses: JeongJaeSoon/agent-guard@v1
  with:
    paths: "."
    gitleaks-checksum: "<sha256 of the gitleaks release archive>"
```

`@v1` tracks the latest 1.x release. Pin to a full commit SHA for high-security environments.

### Direct CLI install (no clone)

```sh
mkdir -p ~/.agent-guard && cd ~/.agent-guard
gh release download --repo JeongJaeSoon/agent-guard --pattern '*.tar.gz' --pattern '*.sha256'
shasum -a 256 -c agent-guard-*.tar.gz.sha256
tar -xzf agent-guard-*.tar.gz
ln -sf "$PWD/bin/agent-guard" ~/.local/bin/agent-guard
agent-guard check
```

A future minor release will bundle a one-line `curl | sh` installer; the steps above are the manual equivalent that works today.

### Native Git hook (after one of the above)

```sh
cd <your-project>
~/.agent-guard/install.sh git-hooks
```

See [Native Git hook](#native-git-hook) under Advanced setup for behavior around existing `core.hooksPath` setups.

### Verify your install

```sh
./install.sh check
```

Prints the installed `gitleaks` version alongside the dependency check. `make check` is equivalent.

## How it works

### Channels

Agent Guard offers four independent integration points. Pick whichever match your workflow — they do **not** chain. Each row lists what that channel alone can and cannot block.

| Channel | What it blocks | What it cannot see |
|---|---|---|
| Agent hook (Claude Code / Codex) | Pre-tool: deny-listed reads (`.env`, `id_rsa`, …), risky shell idioms, secrets in proposed `Write`/`Edit`/`apply_patch`, secrets in MCP tool input. Post-tool & Stop: secrets in working-tree diff & untracked files. | Edits the user makes by hand outside the agent session. |
| Native Git pre-commit hook | Secrets in staged added lines at commit time. | Reads the agent performed earlier; commits made with `--no-verify`. |
| GitHub Action | Secrets in any tracked file on a PR/push. | Anything that already merged before the workflow ran. |
| Direct CLI (`bin/agent-guard scan-*`) | Whatever you point it at, on demand. | Anything outside the invocation. |

Defense-in-depth is best, but a single channel still meaningfully reduces risk. The agent-hook channel is the only one that can stop a leak **before** the secret leaves the host.

### What it checks

- Proposed writes from `Write`, `Edit`, `MultiEdit`, and Codex `apply_patch`
- Sensitive read/search paths such as `.env*`, private keys, `.aws/credentials`, `.npmrc`, `.pypirc`
- Obvious risky shell commands such as `cat .env`, `printenv`, `op read`, `vault kv get`, `aws secretsmanager get-secret-value`
- MCP tool input JSON
- Staged added lines for `pre-commit`
- Working tree added lines and untracked file content after agent mutations

Patch and diff scans inspect added lines only so removing an existing leaked value is not blocked by the deleted line.

Detection sensitivity is bounded by the rules and allowlists shipped with the `gitleaks` binary on your machine. Short or context-free secret strings that the upstream ruleset does not recognise will pass — Agent Guard layers on top of, not in place of, GitHub Secret Scanning and Push Protection. Keep `gitleaks` up to date.

## Advanced setup

### Claude Code

As a plugin, Agent Guard loads `.claude-plugin/plugin.json`, which points at `./hooks/hooks.json`.

For local testing, adapt `examples/claude/settings.project.json` and replace `/absolute/path/to/agent-guard` with this repository path.

For marketplace distribution, `.claude-plugin/marketplace.json` points at `JeongJaeSoon/agent-guard` by default. Update the `owner` field with your publisher info before publishing.

### Codex

Codex loads `.codex-plugin/plugin.json`, which points at `./hooks/hooks.json`.

For local testing, use `examples/codex/hooks.json`. Update the `author` field in `.codex-plugin/plugin.json` with your publisher info before publishing.

The hook contract has been cross-checked against `openai/codex` schemas at `codex-rs/hooks/schema/generated/pre-tool-use.command.input.schema.json` and `codex-rs/config/src/hook_config.rs`: top-level event keys are PascalCase (`PreToolUse`, `PostToolUse`, `Stop`), the handler shape is `{ "type": "command", "command": ..., "timeout": <seconds> }`, and stdin payload keys are snake_case (`tool_name`, `tool_input`, ...). `exit 2` with a reason on stderr is Codex's documented blocking path.

#### Hook tool name coverage in Codex

Codex registers a much smaller set of hook-visible tools than Claude Code. Source of truth: `codex-rs/core/src/tools/hook_names.rs`.

| Hook `tool_name` | Codex source | Matcher aliases |
|---|---|---|
| `Bash` | `shell.rs`, `unified_exec.rs`, `local_shell.rs`, `shell_command.rs`, `sandboxing.rs` | (none) |
| `apply_patch` | `apply_patch.rs` (handler + runtime) | `Write`, `Edit` |
| (MCP tool's display name) | `mcp.rs`, `mcp_tool_call.rs` | (none) |

Agent Guard's matcher (`Write|Edit|MultiEdit|Read|NotebookRead|Grep|Glob|Bash|apply_patch|mcp__.*`) is a Claude Code-shaped superset. In Codex, `MultiEdit`, `Read`, `NotebookRead`, `Grep`, and `Glob` are silently no-ops because Codex has no tool registered under those names — they remain in the matcher only for Claude Code coverage. The genuinely active surface in Codex is therefore `Write`/`Edit` (via the `apply_patch` alias), `Bash`, `apply_patch`, and any `mcp__*` tool.

If a Codex agent tries to read a deny-listed file like `.env`, the read still has to happen through the shell (`cat .env`, `head .env`, redirects, command substitution, …), so the `Bash` matcher and `config/deny-bash-patterns.txt` close that path even though Codex lacks a dedicated `Read` tool.

#### Verifying the example configs

Both example configs drive the same `bin/agent-guard` entry points. To smoke-test them locally:

```sh
# Claude — substitute the absolute path, then drive a deny-listed read.
CLAUDE_CMD=$(sed "s#/absolute/path/to/agent-guard#$PWD#g" \
  examples/claude/settings.project.json \
  | jq -r '.hooks.PreToolUse[0].hooks[0].command')
printf '%s' '{"tool_name":"Read","tool_input":{"file_path":".env"}}' \
  | sh -c "$CLAUDE_CMD"
# expect: exit 2, "blocked sensitive file access: .env"

# Codex — relative command, run from the repo root.
CODEX_CMD=$(jq -r '.hooks.PreToolUse[0].hooks[0].command' \
  examples/codex/hooks.json)
printf '%s' '{"tool_name":"Read","tool_input":{"file_path":".env"}}' \
  | sh -c "$CODEX_CMD"
# expect: exit 2, "blocked sensitive file access: .env"
```

### GitHub Actions

The root `action.yml` lets consumers use the repository directly:

```yaml
- uses: JeongJaeSoon/agent-guard@v1
  with:
    paths: "."
    gitleaks-checksum: "<sha256 of the gitleaks release archive>"
```

The `gitleaks-checksum` input is required by default. Pin a known-good sha256 for the `gitleaks-version` you select — this stops a compromised release URL from injecting a malicious binary into your CI runner.

To opt out (local experimentation only) set `require-checksum: "false"`. Do not do this in production CI.

For high-security environments, also pin Agent Guard to a full commit SHA instead of the moving `@v1` tag.

### Native Git hook

Agent Guard uses native Git hooks. It does not require Husky, npm, or another hook manager.

```sh
./install.sh git-hooks
```

The installer sets `core.hooksPath=githooks` only when it will not overwrite an existing hook setup.

### Configuration

Agent Guard always passes the bundled `config/gitleaks.toml` unless you explicitly override it:

```sh
AGENT_GUARD_GITLEAKS_CONFIG=/path/to/gitleaks.toml bin/agent-guard scan-path .
```

Policy files:

- `config/gitleaks.toml`
- `config/deny-read-paths.txt`
- `config/deny-bash-patterns.txt`

The bundled deny-read policy is conservative, including local credential files such as `.env*`, SSH keys/config, cloud CLI credentials, and certificate bundles. If your workflow needs a different read policy, point `AGENT_GUARD_DENY_READ_PATHS` at your own deny-list file.

Project-local `.gitleaks.toml` files are not automatically trusted.

## Reference

### CLI subcommands

User-callable commands for ad-hoc scanning, used by Git hooks, GitHub Actions, and manual checks:

```sh
bin/agent-guard scan-staged
bin/agent-guard scan-working-tree
bin/agent-guard scan-path PATH...
```

### Hook entry points

Called by Claude Code, Codex, or Git — not by users directly. Each reads hook JSON from stdin:

```sh
bin/agent-guard hook-pre-tool
bin/agent-guard hook-post-tool
bin/agent-guard hook-stop
```

### Exit codes

- `0`: clean / allow
- `1`: findings for direct scan commands
- `2`: block an agent hook action or signal usage/dependency failure

## Development

### Make targets

A thin `Makefile` is provided as a discoverability layer over the same scripts:

```sh
make help          # one-screen index of every target
make check         # ./install.sh check
make install       # ./install.sh git-hooks
make test          # tests/run.sh
make scan          # bin/agent-guard scan-working-tree
make scan-staged   # bin/agent-guard scan-staged
make checksum      # how to pin a gitleaks-checksum for CI
```

`make` does not introduce orchestration logic; targets pass through to `install.sh` and `bin/agent-guard`.

### Tests

```sh
tests/run.sh
```

The default test suite uses a mock `gitleaks` to validate routing and policy behavior without downloading dependencies. If real `gitleaks` is installed, direct manual scans can be run with `bin/agent-guard scan-path .`.
