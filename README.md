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

`@v1` is a moving major tag — patch and minor releases are picked up automatically with no workflow edit. To upgrade across a major (`v1` → `v2`), bump the tag explicitly. Pin to a full commit SHA for high-security environments.

The `gitleaks-checksum` is integrity metadata, not a credential — commit it directly to your workflow file. Storing it as a GitHub Secret would hide the audit trail without adding security: the value is the public SHA-256 of a public release archive, and the whole point of pinning is that reviewers can see *what* you are pinning to.

### Direct CLI install (no clone)

```sh
curl -fsSL https://github.com/JeongJaeSoon/agent-guard/releases/latest/download/bootstrap.sh | sh
```

The bootstrap script:

- resolves the latest release version via the GitHub `releases/latest` redirect (override with `AGENT_GUARD_VERSION=1.2.3`),
- downloads `agent-guard-X.Y.Z.tar.gz` and the published `.sha256`, verifies the checksum, and extracts to `~/.agent-guard` (override with `AGENT_GUARD_HOME`),
- symlinks `~/.local/bin/agent-guard` (override with `AGENT_GUARD_BIN_DIR`),
- runs `agent-guard setup` so you immediately see per-dependency status and any install hints.

`agent-guard setup` is opt-in: it does *not* install anything by default. If `gitleaks` is missing, it prints the exact `--install` command (which requires `--gitleaks-checksum SHA` from the published gitleaks release). `jq` is left to your system package manager — `setup` prints the appropriate `brew`/`apt-get`/`dnf` command for your OS.

<details>
<summary>Manual equivalent (no <code>curl | sh</code>)</summary>

```sh
mkdir -p ~/.agent-guard && cd ~/.agent-guard
gh release download --repo JeongJaeSoon/agent-guard --pattern '*.tar.gz' --pattern '*.sha256'
shasum -a 256 -c agent-guard-*.tar.gz.sha256
tar -xzf agent-guard-*.tar.gz
ln -sf "$PWD/bin/agent-guard" ~/.local/bin/agent-guard
agent-guard setup
```

</details>

### Native Git hook

Adding the native Git hook channel requires `agent-guard` on disk. The Claude Code / Codex plugin install does **not** place a binary on the filesystem, so use Direct CLI install or a clone first:

```sh
cd <your-project>
~/.agent-guard/install.sh git-hooks   # after Direct CLI install
# or, from a clone of this repo:
./install.sh git-hooks
```

See [Native Git hook](#native-git-hook) under Advanced setup for behavior around existing `core.hooksPath` setups.

### Verify your install

The right verification depends on the channel you used.

| Channel | How to verify |
|---|---|
| Claude Code | `/plugin list` should show `agent-guard`. To smoke-test the hook, ask the agent to read a deny-listed file (e.g. "read `.env`") — the agent should be blocked with `blocked sensitive file access: .env`. |
| Codex | Same shape as Claude Code; the agent should be blocked when asked to read `.env`. |
| GitHub Actions | The action runs on PR/push. A workflow run that reports either "no findings" (clean repo) or a deliberate finding (PR you crafted with a fake high-entropy secret) confirms the channel is wired. |
| Direct CLI install | `agent-guard check` for a strict pass/fail; `agent-guard setup` for a per-dependency status report (and install hints if anything is missing). |
| Cloned repo | `./install.sh check` or `make check` from the repo root. |

Both `agent-guard check` and `./install.sh check` print the resolved `gitleaks` version alongside the dependency check.

> The plugin channels currently rely on triggering the hook to verify. A future plugin-native slash command (`/agent-guard:verify`) will provide a one-step check directly inside Claude Code / Codex; tracked separately from this restructure.

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

User-callable commands, used by Git hooks, GitHub Actions, and manual checks:

```sh
bin/agent-guard scan-staged
bin/agent-guard scan-working-tree
bin/agent-guard scan-path PATH...
bin/agent-guard check        # dependency / gitleaks version check
bin/agent-guard setup        # report dependency status; --install opts in to gitleaks download
bin/agent-guard version
```

`setup` is the dependency bootstrap entry point. By default it only reports status and prints install hints. Pass `--install --gitleaks-checksum SHA [--gitleaks-version X.Y.Z]` to actually download `gitleaks` into `~/.agent-guard/bin/`. The checksum is required (no implicit fetch) and must match the value published in the gitleaks release's `gitleaks_X.Y.Z_checksums.txt`. `jq` is never auto-installed — `setup` prints the appropriate package-manager command for your OS instead, since `jq` belongs with the system package manager.

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
