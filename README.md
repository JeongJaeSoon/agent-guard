# Agent Guard

[![Release](https://img.shields.io/github/v/release/JeongJaeSoon/agent-guard)](https://github.com/JeongJaeSoon/agent-guard/releases)
[![CI](https://github.com/JeongJaeSoon/agent-guard/actions/workflows/ci.yml/badge.svg)](https://github.com/JeongJaeSoon/agent-guard/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

> Deterministic secret-scanning guardrails for AI coding agents, native Git hooks, and GitHub Actions.

Agent Guard intercepts AI coding agents (Claude Code, Codex) before they read sensitive files, propose writes containing secrets, or run risky shell commands — and re-scans the working tree after every change. Backed by [gitleaks](https://github.com/gitleaks/gitleaks); no Python, Node, Docker, or vault account required.

```text
> Please read .env to set up the project

agent-guard: blocked sensitive file access: .env
```

It is a thin layer — not a vault, not a credential rotator, not a replacement for GitHub Secret Scanning and Push Protection.

## Contents

- [Channels](#channels) — pick which integration(s) to use
- [Quick start (Claude Code)](#quick-start-claude-code) — 3 commands, ~1 minute
- [Install other channels](#install-other-channels) — Codex, GitHub Actions, Direct CLI, Native Git hook
- [Dependencies & setup](#dependencies--setup) — check `jq` / `gitleaks`, auto-install, fetch a `gitleaks-checksum`
- [Verify the install](#verify-the-install)
- [What it catches](#what-it-catches)
- [Configuration](#configuration)
- [Reference](#reference)
- [Development](#development)

## Channels

Pick one or more — they don't chain. Each row lists what that channel alone can and cannot block.

| Channel | What it blocks | What it cannot see |
|---|---|---|
| Agent hook (Claude Code / Codex) | Pre-tool: deny-listed reads (`.env`, `id_rsa`, …), risky shell idioms, secrets in proposed `Write`/`Edit`/`apply_patch`, secrets in MCP tool input. Post-tool & Stop: secrets in working-tree diff & untracked files. | Edits the user makes by hand outside the agent session. |
| Native Git pre-commit hook | Secrets in staged added lines at commit time. | Reads the agent performed earlier; commits made with `--no-verify`. |
| GitHub Action | Secrets in any tracked file on a PR/push. | Anything that already merged before the workflow ran. |
| Direct CLI (`bin/agent-guard scan-*`) | Whatever you point it at, on demand. | Anything outside the invocation. |

## Quick start (Claude Code)

**Prerequisites**: `git`, `jq`, `gitleaks` (>= 8.30 recommended) on macOS or Linux. Missing something? Jump to [Dependencies & setup](#dependencies--setup) — `agent-guard setup` will tell you exactly what to install.

1. **Install the plugin and reload**:

   ```text
   /plugin marketplace add JeongJaeSoon/agent-guard
   /plugin install agent-guard@latest
   /reload-plugins
   ```

2. **Smoke-test** by asking the agent to read `.env`. The hook should block it:

   ```text
   agent-guard: blocked sensitive file access: .env
   ```

   If the read goes through silently, see [Dependencies & setup](#dependencies--setup) — `gitleaks` is most likely missing.

That's it. From here, every `Read`, `Write`, `Edit`, `Bash`, and MCP tool call goes through the guard.

## Install other channels

### Codex

```text
/plugin install JeongJaeSoon/agent-guard@latest
```

Restart Codex so the hooks load. Codex does not auto-discover the `commands/` directory, so `/agent-guard:checksum` and `/agent-guard:verify` are not available — ask Codex to run `${CODEX_PLUGIN_ROOT}/bin/agent-guard checksum` (or `scan-working-tree`) directly when you need them.

### GitHub Actions

```yaml
- uses: JeongJaeSoon/agent-guard@v1
  with:
    paths: "."
    gitleaks-checksum: "<sha256 of the gitleaks release archive>"
```

**Pinning options for `@v1`:**
- `@v1` — moving major tag, picks up minor / patch releases automatically (recommended default)
- `@v1.1.2` — pin to a specific release for fully reproducible CI
- `@<full-commit-sha>` — pin to a commit for the strictest security posture

**Filling in `gitleaks-checksum`:** the helper prints the linux/x64 value pre-formatted for paste. Pick the path that matches what you have on hand:

```sh
# (a) inside Claude Code (after plugin install)
/agent-guard:checksum

# (b) with agent-guard on disk (Direct CLI install or clone)
agent-guard checksum

# (c) no install — one-liner suitable for adoption-time:
curl -fsSL https://raw.githubusercontent.com/JeongJaeSoon/agent-guard/v1/scripts/gitleaks-checksum.sh | sh
```

Use `require-checksum: "false"` only for local experimentation; never in production CI.

### Direct CLI install (no clone)

```sh
curl -fsSL https://github.com/JeongJaeSoon/agent-guard/releases/latest/download/bootstrap.sh | sh
```

The script downloads the latest release, verifies its sha256, extracts to `~/.agent-guard`, symlinks `~/.local/bin/agent-guard`, and runs `agent-guard setup` to report dependency status. Override with `AGENT_GUARD_VERSION`, `AGENT_GUARD_HOME`, or `AGENT_GUARD_BIN_DIR`.

### Native Git hook

Requires `agent-guard` on disk. The Claude Code / Codex plugin install does **not** place a binary on the filesystem, so use Direct CLI install or a clone first:

```sh
cd <your-project>
~/.agent-guard/install.sh git-hooks   # after Direct CLI install
# or, from a clone of this repo:
./install.sh git-hooks
```

Sets `core.hooksPath=githooks` only when it will not overwrite an existing setup. No Husky / npm hook manager required.

## Dependencies & setup

Agent Guard requires `sh`, `git`, `jq`, and `gitleaks` (>= 8.30 recommended) on macOS or Linux. The right setup path depends on whether you have the `agent-guard` binary on disk.

### With `agent-guard` on disk (Direct CLI install or clone)

```sh
agent-guard check       # strict pass/fail (exit 2 if anything is missing)
agent-guard setup       # per-dependency status with install hints
```

`agent-guard setup` is opt-in: by default it only reports status, never installs. To download `gitleaks` automatically with checksum verification:

```sh
agent-guard setup --install \
  --gitleaks-checksum <sha256-from-published-checksums.txt> \
  [--gitleaks-version 8.30.1]
```

The checksum is required. The fastest way to get it: run [`agent-guard checksum [VERSION]`](#fetching-a-gitleaks-checksum) — it prints every supported OS / arch with paste-ready snippets for both `--gitleaks-checksum` (CLI) and `gitleaks-checksum:` (GitHub Actions YAML).

`jq` is never auto-installed; `setup` prints the right `brew` / `apt-get` / `dnf` command for your OS.

### Fetching a `gitleaks-checksum`

Looking up the right sha256 by hand is the most common chore around dependency setup. The bundled helper does it for you and prints every supported platform — so the value is correct regardless of where you run it from (e.g. on macOS for a Linux CI runner).

```sh
agent-guard checksum             # uses the version pinned in action.yml (8.30.1)
agent-guard checksum 8.30.0      # specific version
```

Output (paste-ready):

```
gitleaks v8.30.1 — sha256 by OS/arch

  darwin/arm64: <hex-a>   <- this machine
  darwin/x64:   <hex-b>
  linux/arm64:  <hex-c>
  linux/x64:    <hex-d>

GitHub Actions workflow (CI runners are typically linux/x64):
  gitleaks-checksum: "<hex-d>"

agent-guard setup CLI (this machine: darwin/arm64):
  agent-guard setup --install --gitleaks-checksum <hex-a> --gitleaks-version 8.30.1
```

Equivalent surfaces — pick whichever matches your channel:

| You have | How to invoke |
|---|---|
| Claude Code plugin | `/agent-guard:checksum [VERSION]` (slash command, calls the same script under the plugin path) |
| Codex plugin | Ask Codex to run `${CODEX_PLUGIN_ROOT}/bin/agent-guard checksum [VERSION]` (no automatic slash command) |
| Direct CLI install / Native hook (binary on PATH) | `agent-guard checksum [VERSION]` |
| Clone of this repo | `make checksum [VERSION=X.Y.Z]` or `scripts/gitleaks-checksum.sh [VERSION]` |
| Nothing installed yet (e.g. preparing a GitHub Actions workflow) | `curl -fsSL https://raw.githubusercontent.com/JeongJaeSoon/agent-guard/v1/scripts/gitleaks-checksum.sh \| sh` (`v1` is the moving major tag — substitute a full commit SHA or a specific minor-version tag for stricter reproducibility) |

### Without `agent-guard` on disk (Claude Code / Codex plugin only)

The plugin install does not place a binary on the filesystem — install dependencies with your package manager:

| OS | Command |
|---|---|
| macOS | `brew install jq gitleaks` |
| Debian / Ubuntu | `sudo apt-get install -y jq` &nbsp;+ download `gitleaks` from its [releases page](https://github.com/gitleaks/gitleaks/releases) |
| Fedora | `sudo dnf install -y jq` &nbsp;+ download `gitleaks` from its [releases page](https://github.com/gitleaks/gitleaks/releases) |

After dependencies are in place, run `/reload-plugins` in Claude Code (or restart Codex) and re-run the smoke test. Plugin users can still reach the [`gitleaks-checksum` helper](#fetching-a-gitleaks-checksum) from inside their session — no PATH binary required (Claude Code: `/agent-guard:checksum`; Codex: ask the agent to run `${CODEX_PLUGIN_ROOT}/bin/agent-guard checksum`).

## Verify the install

| Channel | How to verify |
|---|---|
| Claude Code | `/plugin list` should show `agent-guard`. Run `/agent-guard:verify` for a one-shot working-tree scan, or smoke-test the hook by asking the agent to read `.env` (should be blocked with `blocked sensitive file access: .env`). |
| Codex | Smoke-test by asking the agent to read `.env`; it should be blocked. (`/agent-guard:verify` is Claude Code only — fall back to `agent-guard scan-working-tree` directly.) |
| GitHub Actions | A workflow run reporting either "no findings" or a deliberate finding (PR you crafted with a fake high-entropy secret) confirms it. |
| Direct CLI install | `agent-guard check` for a strict pass/fail. |
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
- `AGENT_GUARD_DENY_READ_PATHS` — deny-list for `Read` / `NotebookRead` / `Grep` / `Glob` (default: `config/deny-read-paths.txt`)
- `AGENT_GUARD_DENY_BASH_PATTERNS` — deny-list for `Bash` (default: `config/deny-bash-patterns.txt`)

Project-local `.gitleaks.toml` files are not automatically trusted.

## Reference

### CLI subcommands

```sh
bin/agent-guard scan-staged
bin/agent-guard scan-working-tree
bin/agent-guard scan-path PATH...
bin/agent-guard check              # dependency / gitleaks version check
bin/agent-guard setup              # report dependency status; --install opts in to gitleaks download
bin/agent-guard checksum [VERSION] # fetch the gitleaks-checksum for every supported OS/arch
bin/agent-guard version
```

### Slash commands

| Command | What it does |
|---|---|
| `/agent-guard:verify` | One-shot deterministic secret scan over the working tree (staged + unstaged + untracked). Claude Code only. |
| `/agent-guard:checksum [VERSION]` | Fetch the gitleaks release sha256 for every supported OS / arch and emit paste-ready snippets for both GitHub Actions YAML and `agent-guard setup --install`. Claude Code only — Codex / GitHub Action / no-install paths are listed in [Fetching a gitleaks-checksum](#fetching-a-gitleaks-checksum). |

### Exit codes

- `0` — clean / allow
- `1` — findings (direct scan commands)
- `2` — block agent hook action or signal usage / dependency failure

(Hook entry points `hook-pre-tool`, `hook-post-tool`, and `hook-stop` are invoked by Claude Code, Codex, or Git via `hooks/hooks.json` — not by users directly.)

## Development

```sh
make help          # one-screen index of every target
make check         # ./install.sh check
make install       # ./install.sh git-hooks
make test          # tests/run.sh
make scan          # bin/agent-guard scan-working-tree
make scan-staged   # bin/agent-guard scan-staged
make checksum      # fetch the gitleaks-checksum for every supported OS/arch (override with VERSION=X.Y.Z)
```

`tests/run.sh` uses a mock `gitleaks` to validate routing without downloading dependencies. With real `gitleaks` installed, `bin/agent-guard scan-path .` does a full scan.
