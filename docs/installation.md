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

## 런타임 의존성

macOS와 Linux의 런타임에는 `sh`, `awk`, `git`, `jq`, gitleaks 8.30 이상이
필요합니다. gitleaks 버전 프로브의 제한 시간과 하위 프로세스 정리를 보장하려면
별도 프로세스 그룹을 만드는 `setsid` 또는 Perl 중 하나도 필요합니다. Linux에서는
`sudo apt-get install -y util-linux` 또는 `sudo dnf install -y util-linux`로
`setsid`를 설치하고, Homebrew 설치에서는 formula가 Perl을 함께 설치합니다.
수동 macOS 설치에서 둘 다 없다면 `brew install perl`을 사용합니다.

`agent-guard setup`, `doctor`, `check`는 격리 도구가 없으면 nonzero로 종료합니다.
`setup --install`은 격리 도구를 다운로드 전에 확인합니다. 격리 도구가 없으면
gitleaks 자체도 내려받거나 덮어쓰지 않고 해당 도구의 설치 명령만 안내하며,
설치 후에도 전체 gitleaks readiness를 다시 검증합니다. 런타임 훅은 이 상태를
clean scan으로 간주하지 않고 `AGENT_GUARD_INFRA_FAILURE_MODE`의 `open` 또는
`closed` 정책을 적용합니다.

If `agent-guard` is already installed as a standalone or Homebrew command, it
can delegate plugin installation to the official host managers:

```sh
agent-guard plugin status --host all
agent-guard plugin install --host claude
agent-guard plugin install --host codex
```

Use `--host all` to install both in one command. If `--host` is omitted,
exactly one of `claude` or `codex` must be available. Claude Code supports
`--scope user|project|local` and defaults to `user`; Codex supports user scope
only. Each marketplace is pinned to the release tag matching the CLI that
performs the installation (`v<CLI version>`). Repeating `install` is a
no-op when the pinned marketplace and installed plugin already match that CLI,
and never updates them implicitly. If an installed plugin is disabled, `status`
reports that state and `install` asks you to enable it through the host manager.
Updates and removals remain explicit:

```sh
agent-guard plugin update --host all
agent-guard plugin uninstall --host claude
```

These commands use the remote `JeongJaeSoon/agent-guard@v<CLI version>` marketplace
and call the host CLIs directly. They do not write plugin caches or host
configuration files themselves, do not invoke `sudo`, and do not bypass host
confirmation prompts. Restart each changed host before verifying its hooks.

`status` reports installed plugin version drift separately from marketplace
state. Claude Code exposes the configured marketplace ref in its JSON status;
Codex 0.153.4 does not, so Codex status conservatively labels the pin
unverified. Before `install` or `update` reuses an existing Codex marketplace,
the CLI asks Codex to add the same pinned source again. Codex treats that as an
idempotent no-op only for the same ref and rejects an unpinned or different ref
without changing state.

The CLI will not silently replace an unpinned marketplace, a marketplace pinned
to another release, or a same-name marketplace from another source. Remove the
marketplace with the official host manager, then rerun `agent-guard plugin
install --host HOST`. Marketplace removal also removes plugins installed from
that marketplace, so treat those two commands as one recovery operation. If
marketplace registration or plugin installation fails partway through, the CLI
reports which host-managed state remains and the exact command that is safe to
retry.

The CLI plugin lifecycle is for self-managed installations. It detects an
installed Claude plugin with `managed` scope and also reads Agent Guard entries
from the administrator-owned `managed-settings.json` and
`managed-settings.d/*.json` files on macOS and Linux. This covers the initial
state where the managed marketplace is declared but its plugin has not yet been
downloaded. `status` identifies that state as managed; `install`, `update`, and
`uninstall` refuse to change it. Files are merged in Claude's base-then-sorted-
drop-in order before the Agent Guard keys are evaluated. An unreadable or
malformed file, or a path that does not resolve to a regular file, makes these
commands fail closed because ownership cannot be determined safely. Empty files
and valid files that contain only unrelated settings do not block self-managed
use. If a valid `policyHelper` is declared, its result replaces the file-based
settings at runtime; the CLI does not execute the helper and therefore also
fails closed. This CLI check helps prevent accidental lifecycle changes; the
Claude managed-settings deployment remains the administrative enforcement
boundary. On Jamf or another managed deployment, change the reviewed release tag
in managed settings instead; do not add a user or project installation over the
managed policy. See [Operations](operations.md#managed-claude-code-rollout).

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

To pin a release, enter the reviewed published version (without the `v`
prefix). Choose a version containing the capabilities your rollout requires.
Change the destinations below only when you want an isolated installation:

```sh
printf 'Reviewed release version (X.Y.Z): '
IFS= read -r guard_version
curl -fsSL "https://github.com/JeongJaeSoon/agent-guard/releases/download/v${guard_version}/bootstrap.sh" | \
  AGENT_GUARD_VERSION="$guard_version" \
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

If this CLI also installed a Claude Code or Codex plugin, upgrading the CLI does
not silently move that host marketplace to a new release. After `agent-guard
update` or `brew upgrade`, synchronize each self-managed host explicitly:

```sh
agent-guard plugin status --host all
agent-guard plugin update --host all
```

When the existing marketplace is pinned to the previous release, `plugin
update` stops before mutation and prints the exact official host-manager remove
and reinstall commands. Follow that recovery sequence, restart the host, rerun
the plugin-local setup and acceptance checks, and re-trust changed Codex hooks.
Use only the hosts installed on that machine. For Jamf-managed Claude Code,
advance the managed marketplace tag through the administrator rollout instead.

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
