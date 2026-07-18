# Configuration

Agent Guard uses bundled policies by default. Environment variables must be present in the process that runs the CLI or hook.

## Scan policies

| Variable | Default | Purpose |
|---|---|---|
| `AGENT_GUARD_GITLEAKS_CONFIG` | Bundled `config/gitleaks.toml` | Select the gitleaks configuration. |
| `AGENT_GUARD_DENY_READ_PATHS` | Bundled `config/deny-read-paths.txt` | Select deny-listed file patterns for read tools and shell commands. |
| `AGENT_GUARD_DENY_BASH_PATTERNS` | Bundled `config/deny-bash-patterns.txt` | Select deny-listed shell command patterns. |

Repository-local `.gitleaks.toml` files are not automatically trusted. Set `AGENT_GUARD_GITLEAKS_CONFIG` explicitly to use one.

## PII filtering

| Variable | Default | Allowed values or purpose |
|---|---|---|
| `AGENT_GUARD_PII_PROVIDER` | `regex` | `regex` or `http`. |
| `AGENT_GUARD_PII_REDACT_URL` | None | Required endpoint URL for the `http` provider. |
| `AGENT_GUARD_PII_HOOK_MODE` | `off` | `off` or `block`. |

See [PII filtering](pii-filtering.md) before enabling the HTTP provider or hook blocking.

## Bootstrap installer

These variables affect `bootstrap.sh`:

| Variable | Default | Purpose |
|---|---|---|
| `AGENT_GUARD_VERSION` | Latest release | Pin the Agent Guard version. |
| `AGENT_GUARD_HOME` | `~/.agent-guard` | Set the extracted installation directory. |
| `AGENT_GUARD_BIN_DIR` | `~/.local/bin` | Set the directory for the `agent-guard` symlink. |
| `AGENT_GUARD_REPO` | `JeongJaeSoon/agent-guard` | Override the source repository, primarily for forks or testing. |

`agent-guard setup --install` places gitleaks in `~/.agent-guard/bin` by default. Override that location with `AGENT_GUARD_GITLEAKS_BIN_DIR`.

## GitHub Action inputs

| Input | Default | Purpose |
|---|---|---|
| `paths` | `.` | Space-separated paths to scan. |
| `gitleaks-version` | `8.30.1` | Version installed when gitleaks is missing. |
| `gitleaks-checksum` | None | SHA-256 for the selected gitleaks archive. |
| `require-checksum` | `true` | Fail if the checksum is omitted. |
| `config-path` | Bundled config | Optional gitleaks configuration path. |

Prefer a pinned action tag or commit and keep `require-checksum` enabled in CI.
