# Install and integrations

Choose only the integration points needed for your workflow. All secret-scanning paths use the same bundled gitleaks policy.

## Direct CLI

Install the latest release without cloning:

```sh
curl -fsSL https://github.com/JeongJaeSoon/agent-guard/releases/latest/download/bootstrap.sh | sh
```

The bootstrap installer verifies the release archive checksum, extracts to `~/.agent-guard`, links the CLI into `~/.local/bin`, and reports dependency status.

Common commands:

| Command | Purpose |
|---|---|
| `agent-guard scan-path PATH...` | Scan complete files or directories. |
| `agent-guard scan-working-tree` | Scan staged, unstaged, and untracked Git changes. |
| `agent-guard scan-staged` | Scan staged added lines. |
| `agent-guard pii-filter` | Mask PII from stdin. |
| `agent-guard setup` | Report dependency status and install hints. |
| `agent-guard check` | Fail unless scan dependencies and policies are available. |
| `agent-guard smoke-test` | Exercise CLI, hook, Git, and PII paths. |
| `agent-guard checksum [VERSION]` | Print verified gitleaks archive checksums. |

Use [configuration variables](configuration.md#bootstrap-installer) to pin a release or change install paths.

## Claude Code

Install from the Claude Code marketplace:

```text
/plugin marketplace add JeongJaeSoon/agent-guard
/plugin install agent-guard@agent-guard
/reload-plugins
```

Verify the pre-tool hook:

```text
Please read .env
```

Expected result:

```text
agent-guard: blocked sensitive file access: .env
```

Available slash commands:

```text
/agent-guard:verify
/agent-guard:checksum [VERSION]
```

The plugin does not install `jq` or `gitleaks`; install both with your system package manager.

## Codex

For on-demand and commit-time scanning, install the CLI and native Git hook:

```sh
curl -fsSL https://github.com/JeongJaeSoon/agent-guard/releases/latest/download/bootstrap.sh | sh
agent-guard scan-working-tree
~/.agent-guard/install.sh git-hooks
```

To use Codex pre-tool, post-tool, and stop hooks, enable plugin hooks and add the marketplace:

```sh
codex features enable plugin_hooks
codex plugin marketplace add JeongJaeSoon/agent-guard
```

Open `/plugins` in the Codex TUI, install **Agent Guard**, restart Codex, then open `/hooks` and trust the **PreToolUse**, **PostToolUse**, and **Stop** hooks.

Verify the hook by asking Codex to read `.env`; Agent Guard should block the read.

Codex does not auto-discover this plugin's `commands/` directory. Run plugin commands through the binary:

```sh
${CODEX_PLUGIN_ROOT}/bin/agent-guard scan-working-tree
${CODEX_PLUGIN_ROOT}/bin/agent-guard checksum
```

## Native Git hook

From a direct CLI install:

```sh
cd <your-project>
~/.agent-guard/install.sh git-hooks
```

From a repository clone:

```sh
./install.sh git-hooks
```

The installer creates `githooks/pre-commit` and sets `core.hooksPath=githooks`. It refuses to overwrite a different existing hook setup.

## GitHub Actions

Add the action after checkout:

```yaml
- uses: actions/checkout@v5
- uses: JeongJaeSoon/agent-guard@v1
  with:
    paths: "."
    gitleaks-checksum: "<linux-x64 sha256>"
```

Use `@v1` for compatible updates, or pin a full tag or commit SHA for stricter reproducibility.

Get the checksum with:

```sh
agent-guard checksum
```

GitHub-hosted Linux runners normally need the `linux/x64` value. The action requires a checksum by default; set `require-checksum: "false"` only for local experimentation.

See [Configuration](configuration.md#github-action-inputs) for all action inputs.

## Install gitleaks with Agent Guard

`setup --install` requires a published checksum:

```sh
agent-guard checksum
agent-guard setup --install \
  --gitleaks-version 8.30.1 \
  --gitleaks-checksum <sha256-for-this-os-and-arch>
```

The checksum helper prints values for supported macOS and Linux architectures plus paste-ready CLI and GitHub Actions snippets.
