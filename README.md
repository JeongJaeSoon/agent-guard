# Agent Guard

Agent Guard inserts deterministic secret-scanning checks into AI coding agent hooks, native Git hooks, and GitHub Actions.

It is a thin layer — not a vault, not a credential rotator, not a replacement for GitHub Secret Scanning and Push Protection.

## Quickstart

Pick the channel matching your environment. All commands resolve to the same released version.

### Prerequisites

`sh`, `git`, `jq`, and [`gitleaks`](https://github.com/gitleaks/gitleaks) (>= 8.30 recommended) on macOS or Linux.

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

`@v1` is a moving major tag — patch and minor releases are picked up automatically. The `gitleaks-checksum` input is required by default; pin a known-good sha256 from `gitleaks_${version}_checksums.txt`. Set `require-checksum: "false"` for local experimentation only. For high-security CI, also pin Agent Guard to a full commit SHA.

### Direct CLI install (no clone)

```sh
curl -fsSL https://github.com/JeongJaeSoon/agent-guard/releases/latest/download/bootstrap.sh | sh
```

The bootstrap script downloads the latest release, verifies its sha256, extracts to `~/.agent-guard`, symlinks `~/.local/bin/agent-guard`, and runs `agent-guard setup` to report dependency status. Override with `AGENT_GUARD_VERSION`, `AGENT_GUARD_HOME`, or `AGENT_GUARD_BIN_DIR`.

`agent-guard setup` is opt-in: it never installs anything by default. If `gitleaks` is missing it prints the exact `--install` command (which requires `--gitleaks-checksum SHA`). `jq` is left to your system package manager — `setup` prints the appropriate `brew`/`apt-get`/`dnf` command for your OS.

### Native Git hook

Adding the native Git hook channel requires `agent-guard` on disk. The Claude Code / Codex plugin install does **not** place a binary on the filesystem, so use Direct CLI install or a clone first:

```sh
cd <your-project>
~/.agent-guard/install.sh git-hooks   # after Direct CLI install
# or, from a clone of this repo:
./install.sh git-hooks
```

The installer sets `core.hooksPath=githooks` only when it will not overwrite an existing hook setup. Agent Guard does not require Husky, npm, or another hook manager.

### Verify your install

The right verification depends on the channel you used.

| Channel | How to verify |
|---|---|
| Claude Code | `/plugin list` should show `agent-guard`. Run `/agent-guard:verify` for a one-shot working-tree scan, or smoke-test the hook by asking the agent to read a deny-listed file (e.g. "read `.env`") — it should be blocked with `blocked sensitive file access: .env`. |
| Codex | Smoke-test by asking the agent to read `.env`; it should be blocked. (`/agent-guard:verify` is Claude Code only — fall back to `agent-guard scan-working-tree` directly.) |
| GitHub Actions | The action runs on PR/push. A run that reports either "no findings" or a deliberate finding (PR you crafted with a fake high-entropy secret) confirms the channel is wired. |
| Direct CLI install | `agent-guard check` for a strict pass/fail; `agent-guard setup` for a per-dependency status report. |
| Cloned repo | `./install.sh check` or `make check`. |

## How it works

### Channels

Agent Guard offers four independent integration points. Pick whichever matches your workflow — they do **not** chain. Each row lists what that channel alone can and cannot block.

| Channel | What it blocks | What it cannot see |
|---|---|---|
| Agent hook (Claude Code / Codex) | Pre-tool: deny-listed reads (`.env`, `id_rsa`, …), risky shell idioms, secrets in proposed `Write`/`Edit`/`apply_patch`, secrets in MCP tool input. Post-tool & Stop: secrets in working-tree diff & untracked files. | Edits the user makes by hand outside the agent session. |
| Native Git pre-commit hook | Secrets in staged added lines at commit time. | Reads the agent performed earlier; commits made with `--no-verify`. |
| GitHub Action | Secrets in any tracked file on a PR/push. | Anything that already merged before the workflow ran. |
| Direct CLI (`bin/agent-guard scan-*`) | Whatever you point it at, on demand. | Anything outside the invocation. |

### What it checks

- Proposed writes from `Write`, `Edit`, `MultiEdit`, and Codex `apply_patch`
- Sensitive read/search paths such as `.env*`, private keys, `.aws/credentials`, `.npmrc`, `.pypirc`
- Risky shell commands such as `cat .env`, `printenv`, `op read`, `vault kv get`, `aws secretsmanager get-secret-value`
- MCP tool input JSON
- Staged added lines for `pre-commit`
- Working tree added lines and untracked file content after agent mutations

Patch and diff scans inspect added lines only — removing an existing leaked value is not blocked by the deleted line.

Detection is bounded by the rules in your `gitleaks` binary, so keep it up to date. Agent Guard layers on top of, not in place of, GitHub Secret Scanning and Push Protection.

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

`setup` is the dependency bootstrap entry point. By default it only reports status. Pass `--install --gitleaks-checksum SHA [--gitleaks-version X.Y.Z]` to download `gitleaks` into `~/.agent-guard/bin/`; the checksum must match the value published at `https://github.com/gitleaks/gitleaks/releases/download/vX.Y.Z/gitleaks_X.Y.Z_checksums.txt`. `jq` is never auto-installed.

### Plugin slash commands

| Command | What it does |
|---|---|
| `/agent-guard:verify` | One-shot deterministic secret scan over the working tree (staged + unstaged + untracked). Claude Code only. |

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
