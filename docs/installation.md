# Installing Agent Guard

Agent Guard has one policy CLI and separate Claude Code and Codex plugin
adapters. Choose the route that matches the boundary you want to protect:

| Route | Install | Update | Verify |
| --- | --- | --- | --- |
| Claude Code plugin | Add the Agent Guard marketplace and plugin through Claude Code | Use Claude Code’s plugin update command, then reload plugins | Run the plugin-local `bin/agent-guard version` and a harmless host route |
| Codex plugin | Add the Agent Guard marketplace and plugin through Codex | Use Codex’s plugin manager | Run the plugin-local `bin/agent-guard version` and a harmless host route |
| Standalone CLI | Use the checksum-verified bootstrap command below | `agent-guard update` | `agent-guard version`, `agent-guard doctor`, and `agent-guard check` |
| Homebrew | Install the published tap formula | `brew upgrade JeongJaeSoon/tap/agent-guard` | `agent-guard version` |

The plugins are not replaceable by a PATH CLI: they translate Claude Code and
Codex events into the same CLI contract. A standalone installation adds the
CLI and optional shell integration; it does not register host hooks.

## Standalone CLI

Install the current release:

```sh
curl -fsSL https://github.com/JeongJaeSoon/agent-guard/releases/latest/download/bootstrap.sh | sh
```

The bootstrapper downloads a versioned release archive and its SHA-256 file,
checks the archive before changing the installed payload, installs under
`~/.agent-guard`, and links `agent-guard` in `~/.local/bin`. It then reports
dependency status and installs the default shell integration. Ensure
`~/.local/bin` is on `PATH`, then run:

```sh
agent-guard version
agent-guard doctor
agent-guard check
```

`check` verifies dependencies and policy availability; it is not evidence that
a host hook was dispatched. Verify a host adapter separately with a harmless
command on the route you plan to use.

Pin a release or use a non-default isolated destination when needed:

```sh
curl -fsSL https://github.com/JeongJaeSoon/agent-guard/releases/download/v3.3.0/bootstrap.sh | \
  AGENT_GUARD_VERSION=3.3.0 \
  AGENT_GUARD_HOME="$HOME/.agent-guard" \
  AGENT_GUARD_BIN_DIR="$HOME/.local/bin" sh
```

Set `AGENT_GUARD_COMMAND_WRAPPING=off` only when installing if you want the
shell integration without command wrapping.

Update a standalone installation with:

```sh
agent-guard update
agent-guard version
agent-guard doctor
agent-guard check
```

The updater is intentionally unavailable from a plugin cache. Update plugins
through their host manager, then rerun the plugin-local `setup-shell` if shell
integration reports drift.

## Homebrew

Install the released formula from the project tap:

```sh
brew tap JeongJaeSoon/tap
brew install JeongJaeSoon/tap/agent-guard
agent-guard version
```

Upgrade and verify it with:

```sh
brew upgrade JeongJaeSoon/tap/agent-guard
agent-guard version
```

The formula pins the release tarball’s SHA-256. Homebrew owns this installation;
do not run `agent-guard update` over it.

## Removing an installation

Remove each route through the manager that owns it: use the Claude Code or
Codex plugin manager for a host plugin, and `brew uninstall
JeongJaeSoon/tap/agent-guard` for Homebrew. For a standalone install, first
remove the managed shell-integration block from the shell rc file selected by
`agent-guard setup-shell`, then remove the public symlink and the installation
directory only after confirming their paths:

```sh
command -v agent-guard
readlink "$(command -v agent-guard)"
```

Do not delete a plugin-manager cache by hand: the host manages its lifecycle.
After removal, open a new shell and verify `command -v agent-guard` resolves as
expected. If another installation remains, run its `version`, `doctor`, and
`check` commands.
