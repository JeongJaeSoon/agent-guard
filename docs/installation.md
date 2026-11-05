# Installing Agent Guard

English · [한국어](installation.ko.md) · [日本語](installation.ja.md)

Agent Guard has one policy CLI and separate Claude Code and Codex plugin
adapters. Choose the route that matches the boundary you want to protect:

| Route | Install | Update | Verify |
| --- | --- | --- | --- |
| Claude Code plugin | Add the Agent Guard marketplace and plugin through Claude Code | Run `agent-guard plugin update --host claude`; it prints the Claude Code marketplace commands that move to a newer release | Run the plugin-local `bin/agent-guard version` and a harmless host route |
| Codex plugin | Add the Agent Guard marketplace and plugin through Codex | Run `agent-guard plugin update --host codex`; it prints the Codex marketplace commands that move to a newer release | Run the plugin-local `bin/agent-guard version` and a harmless host route |
| Standalone CLI | Use the checksum-verified bootstrap command below | `agent-guard update` | `agent-guard version`, `agent-guard doctor`, and `agent-guard check` |
| Homebrew | Install the published tap formula | `brew upgrade JeongJaeSoon/tap/agent-guard` | `agent-guard version` |

The plugins are not replaceable by a PATH CLI: they translate Claude Code and
Codex events into the same CLI contract. A standalone installation adds the
CLI and optional shell integration; it does not register host hooks.

Without a standalone CLI, add the marketplace pinned to a release tag and
install the plugin with the host's own commands. Replace `vX.Y.Z` with the
release you reviewed:

```sh
claude plugin marketplace add JeongJaeSoon/agent-guard@vX.Y.Z --scope user
claude plugin install agent-guard@agent-guard --scope user

codex plugin marketplace add JeongJaeSoon/agent-guard@vX.Y.Z
codex plugin add agent-guard@agent-guard
```

A plugin install does not put `agent-guard` on your `PATH`, so the
`agent-guard plugin update` route in the table needs a standalone or Homebrew
CLI. Without one, move to a newer release by removing the marketplace and
repeating the commands above with the new tag; removing the marketplace also
removes its installed plugin. Restart the host afterwards.

## Optional fused output preparation (v3.8+)

The output-pipeline experiment is opt-in. It combines private staging and JSON
preparation while keeping the existing scanner, rules, policies and host output
contracts. Install the same release's prebuilt core; the existing core file
supports both preparation and redaction, so a second helper or compiler is not
required. Git marketplace installations can use the standalone helper without
editing host caches.

For Linux x64, verify the installed helper and expose both pipeline settings to the host's
launch environment:

```sh
target=x86_64-unknown-linux-musl
native_root="$HOME/.agent-guard/libexec"
if (cd "$native_root" && shasum -a 256 -c "agent-guard-redact-$target.sha256"); then
  export AGENT_GUARD_EXPERIMENTAL_OUTPUT_PIPELINE=fused
  export AGENT_GUARD_EXPERIMENTAL_OUTPUT_PREPARE_BIN="$native_root/agent-guard-redact-$target"
fi
```

Choose the matching target for your platform from the [native helper guide
(English)](https://github.com/JeongJaeSoon/agent-guard/blob/v3.8.0/docs/native-redactor.md).
For Homebrew, set `native_root="$(brew --prefix agent-guard)/libexec/libexec"`.
Standalone and Homebrew installations select their checksum-verified redactor
automatically. For source-only Git marketplace plugins, also connect redaction to
the same verified core:

```sh
if (cd "$native_root" && shasum -a 256 -c "agent-guard-redact-$target.sha256"); then
  export AGENT_GUARD_RUST_CORE_BIN="$native_root/agent-guard-redact-$target"
fi
```

These explicit paths are trusted executable overrides; only use a verified
installation. Setting only the preparation path leaves source-only plugins using
shell redaction, which differs from the measured shared-core configuration.
Missing or failing preparation falls back to the original jq
stages. A missing experimental module falls back to the original output pipeline.
The scanner and its readiness deadline do not change.

Restart Claude or Codex after changing the launch environment. Existing plugin
install/update commands remain the same. To restore the default output pipeline,
unset these settings and restart the host:

```sh
unset AGENT_GUARD_EXPERIMENTAL_OUTPUT_PIPELINE
unset AGENT_GUARD_EXPERIMENTAL_OUTPUT_PREPARE_BIN
unset AGENT_GUARD_RUST_CORE_BIN
```

This restores the existing default literal redactor selection. To disable
that native helper too, use `AGENT_GUARD_EXPERIMENTAL_REDACTOR=shell`.
The measured gain depends on the workload and scanner; it can come with a larger
sampled process RSS sum. See [verification](verification.md) before rollout.

## Runtime dependencies

The v3.7 release archive and Homebrew package include Rust literal-replacement
helpers for Linux/macOS on x64/arm64. No Rust compiler is needed. The CLI uses
the matching checksum-verified helper by default and falls back to shell/jq if
it is absent or fails. Detection, policy, PII and host adapters remain in shell;
the dependencies below are still required. To explicitly use shell:

```sh
export AGENT_GUARD_EXPERIMENTAL_REDACTOR=shell
```

Linux helpers use static musl and do not require glibc; actual execution is
tested on Ubuntu 24.04. macOS helpers target macOS 14+ and are tested on macOS 15
on both architectures. A deployment target does not prove every older OS/kernel
works; unsupported environments retain the shell fallback. Packaged checksums
detect corruption, not a malicious replacement of both the binary and checksum.

Source archives and host-managed Git marketplace plugins contain no binaries
and therefore use shell unless a trusted prebuilt helper is configured through
the existing `AGENT_GUARD_RUST_CORE_BIN` override. The standalone installation
can supply that helper without editing host caches. See the [native helper
guide](https://github.com/JeongJaeSoon/agent-guard/blob/v3.8.0/docs/native-redactor.md)
for selection, checksum verification and developer overrides.

The runtime on macOS and Linux needs `sh`, `awk`, `git`, `jq`, and gitleaks
8.30 or newer. It also needs one of `setsid` or Perl to run the gitleaks version
probe in its own process group, which is what bounds the probe's time limit and
cleans up its child processes. On Linux install `setsid` with
`sudo apt-get install -y util-linux` or `sudo dnf install -y util-linux`. The
Homebrew formula installs Perl alongside the CLI. A manual macOS install that
has neither can use `brew install perl`.

`agent-guard setup`, `doctor`, and `check` exit non-zero when no isolation tool
is present. `setup --install` checks for one before downloading anything: with
no isolation tool it does not download or overwrite gitleaks, prints the install
command for the missing tool, and re-checks full gitleaks readiness after the
install. Runtime hooks do not treat this state as a clean scan; they apply the
`open` or `closed` policy of `AGENT_GUARD_INFRA_FAILURE_MODE`.

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

The updater is intentionally unavailable from a plugin cache: the binary lives
in the cache that a marketplace removal deletes, so it cannot re-pin the
marketplace itself. Run `agent-guard plugin update --host claude` (or `--host codex`) instead.
When the installed plugin already matches the CLI, it looks up the latest
GitHub release and prints the exact host-manager `marketplace remove`,
`marketplace add ...@vX.Y.Z`, and plugin install commands that move forward;
`agent-guard doctor` and `agent-guard plugin status` report the same release
staleness. Set `AGENT_GUARD_RELEASE_CHECK=off` to skip the lookup. The shell
block resolves through the cache's `current` link, so `setup-shell` does not
need to be rerun after a plugin update.

Standalone updates are staged beside the current installation before replacement.
Checksum, extraction and commit failures leave or restore the previous install;
unrelated local files are preserved. If power loss or an unhandled termination
interrupts the final directory replacement, preserve the sibling
`.agent-guard-update.*/previous` backup and restore it to the original installation
path before retrying. Keep enough disk space for the old and new payloads.

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
