# Agent Guard

Agent Guard inserts deterministic secret-scanning checks into AI coding agent hooks, native Git hooks, and GitHub Actions.

It is a thin layer — not a vault, not a credential rotator, not a replacement for GitHub Secret Scanning and Push Protection.

## Contents

- [Channels](#channels) — pick which one(s) to use
- [Install](#install) — Claude Code, Codex, GitHub Actions, Direct CLI, Native Git hook
- [Verify](#verify-your-install)
- [What it catches](#what-it-catches)
- [Configuration](#configuration)
- [Reference](#reference) — CLI subcommands, slash commands, exit codes
- [Development](#development)

## Channels

Pick one or more — they don't chain. Each row lists what that channel alone can and cannot block.

| Channel | What it blocks | What it cannot see |
|---|---|---|
| Agent hook (Claude Code / Codex) | Pre-tool: deny-listed reads (`.env`, `id_rsa`, …), risky shell idioms, secrets in proposed `Write`/`Edit`/`apply_patch`, secrets in MCP tool input. Post-tool & Stop: secrets in working-tree diff & untracked files. | Edits the user makes by hand outside the agent session. |
| Native Git pre-commit hook | Secrets in staged added lines at commit time. | Reads the agent performed earlier; commits made with `--no-verify`. |
| GitHub Action | Secrets in any tracked file on a PR/push. | Anything that already merged before the workflow ran. |
| Direct CLI (`bin/agent-guard scan-*`) | Whatever you point it at, on demand. | Anything outside the invocation. |

## Install

**Prerequisites**: `sh`, `git`, `jq`, [`gitleaks`](https://github.com/gitleaks/gitleaks) (>= 8.30 recommended) on macOS or Linux.

### Claude Code

```text
/plugin marketplace add JeongJaeSoon/agent-guard
/plugin install agent-guard@latest
```

Run `/reload-plugins` (or restart your Claude Code session) so the hooks load.

### Codex

```text
/plugin install JeongJaeSoon/agent-guard@latest
```

Restart Codex so the hooks load.

### GitHub Actions

```yaml
- uses: JeongJaeSoon/agent-guard@v1
  with:
    paths: "."
    gitleaks-checksum: "<sha256 of the gitleaks release archive>"
```

`@v1` follows minor and patch releases automatically. Pin `gitleaks-checksum` from the published `gitleaks_${version}_checksums.txt`. Use `require-checksum: "false"` only for local experimentation. For high-security CI, also pin Agent Guard to a full commit SHA.

### Direct CLI install (no clone)

```sh
curl -fsSL https://github.com/JeongJaeSoon/agent-guard/releases/latest/download/bootstrap.sh | sh
```

The script downloads the latest release, verifies its sha256, extracts to `~/.agent-guard`, symlinks `~/.local/bin/agent-guard`, and runs `agent-guard setup` to report dependency status. Override with `AGENT_GUARD_VERSION`, `AGENT_GUARD_HOME`, or `AGENT_GUARD_BIN_DIR`.

`agent-guard setup` is opt-in: nothing is installed by default. If `gitleaks` is missing it prints the exact `--install` command (which requires `--gitleaks-checksum SHA`). `jq` is left to your system package manager.

### Native Git hook

Requires `agent-guard` on disk. The Claude Code / Codex plugin install does **not** place a binary on the filesystem, so use Direct CLI install or a clone first:

```sh
cd <your-project>
~/.agent-guard/install.sh git-hooks   # after Direct CLI install
# or, from a clone of this repo:
./install.sh git-hooks
```

Sets `core.hooksPath=githooks` only when it will not overwrite an existing setup. No Husky / npm hook manager required.

## Verify your install

| Channel | How to verify |
|---|---|
| Claude Code | `/plugin list` should show `agent-guard`. Run `/agent-guard:verify` for a one-shot working-tree scan, or smoke-test the hook by asking the agent to read a deny-listed file (e.g. "read `.env`") — it should be blocked with `blocked sensitive file access: .env`. |
| Codex | Smoke-test by asking the agent to read `.env`; it should be blocked. (`/agent-guard:verify` is Claude Code only — fall back to `agent-guard scan-working-tree` directly.) |
| GitHub Actions | A workflow run reporting either "no findings" or a deliberate finding (PR you crafted with a fake high-entropy secret) confirms the channel is wired. |
| Direct CLI install | `agent-guard check` for a strict pass/fail; `agent-guard setup` for a per-dependency status report. |
| Cloned repo | `./install.sh check` or `make check`. |

## What it catches

- Proposed writes from `Write`, `Edit`, `MultiEdit`, and Codex `apply_patch`
- Sensitive read/search paths: `.env*`, private keys, `.aws/credentials`, `.npmrc`, `.pypirc`
- Risky shell commands: `printenv`, `op read`, `vault kv get`, `aws secretsmanager get-secret-value` (path-referencing forms like `cat .env` are blocked via the deny-read paths)
- MCP tool input JSON
- Staged added lines for `pre-commit`
- Working tree added lines and untracked file content after agent mutations

Patch and diff scans inspect added lines only — removing an existing leaked value is not blocked. Detection is bounded by the rules in your `gitleaks` binary; keep it up to date. Agent Guard layers on top of, not in place of, GitHub Secret Scanning and Push Protection.

## Configuration

Override the bundled policies via environment variables:

- `AGENT_GUARD_GITLEAKS_CONFIG` — gitleaks rules (default: `config/gitleaks.toml`)
- `AGENT_GUARD_DENY_READ_PATHS` — deny-list for `Read`/`NotebookRead`/`Grep`/`Glob` (default: `config/deny-read-paths.txt`)
- `AGENT_GUARD_DENY_BASH_PATTERNS` — deny-list for `Bash` (default: `config/deny-bash-patterns.txt`)

Project-local `.gitleaks.toml` files are not automatically trusted.

## Reference

### CLI subcommands

```sh
bin/agent-guard scan-staged
bin/agent-guard scan-working-tree
bin/agent-guard scan-path PATH...
bin/agent-guard check        # dependency / gitleaks version check
bin/agent-guard setup        # report dependency status; --install opts in to gitleaks download
bin/agent-guard version
```

`setup --install --gitleaks-checksum SHA [--gitleaks-version X.Y.Z]` downloads `gitleaks` to `~/.agent-guard/bin/`. The checksum must match the published value at `https://github.com/gitleaks/gitleaks/releases/download/vX.Y.Z/gitleaks_X.Y.Z_checksums.txt`. `jq` is never auto-installed.

### Slash commands

| Command | What it does |
|---|---|
| `/agent-guard:verify` | One-shot deterministic secret scan over the working tree (staged + unstaged + untracked). Claude Code only. |

### Exit codes

- `0`: clean / allow
- `1`: findings (direct scan commands)
- `2`: block agent hook action or signal usage / dependency failure

(Hook entry points `hook-pre-tool`, `hook-post-tool`, and `hook-stop` are invoked by Claude Code, Codex, or Git via `hooks/hooks.json` — not by users directly.)

## Development

```sh
make help          # one-screen index of every target
make check         # ./install.sh check
make install       # ./install.sh git-hooks
make test          # tests/run.sh
make scan          # bin/agent-guard scan-working-tree
make scan-staged   # bin/agent-guard scan-staged
make checksum      # how to pin a gitleaks-checksum for CI
```

Run `tests/run.sh` for the test suite — it uses a mock `gitleaks` to validate routing without downloading dependencies. With real `gitleaks` installed, `bin/agent-guard scan-path .` does a full scan.
