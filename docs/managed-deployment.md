# Managed deployment for Claude Code and Codex

`managed-install.sh` packages Agent Guard for centrally managed machines. It is
usable with MDM, configuration management, shared development images, or a team
bootstrap repository; it does not require an Enterprise subscription by itself.

## Minimal organization-owned surface

Use the release-provided `managed-bootstrap.sh` when the device manager should
not maintain a copy of Agent Guard's installation logic. The organization owns
only:

- an explicitly approved Agent Guard version and independently recorded archive digest;
- its Claude managed settings and composed Codex requirements;
- the MDM schedule and rollout/pilot controls.

Agent Guard owns release/dependency download and verification, system staging,
verification, target-user detection, and default-on shell wrapping. Download
the bootstrap from the same versioned release, verify it with the adjacent
`managed-bootstrap.sh.sha256` asset, retain the reviewed digest in MDM, and run:

```sh
sudo sh ./managed-bootstrap.sh \
  --version X.Y.Z \
  --archive-sha256 <independently-recorded-release-digest>
```

The script accepts organization-provided `--jq-bin` and `--gitleaks-bin`
artifacts, otherwise it downloads Agent Guard's pinned versions and verifies
their platform-specific SHA-256 values. It records the installed release digest
under the managed prefix, skips matching downloads on later check-ins, and
retries the user phase at login. It does not own or overwrite either product's
policy files.

The remaining sections describe the lower-level/manual composition path and
the policy that must accompany either installation entrypoint.

The deployment has two ownership boundaries:

| Phase | Runs as | Purpose |
|---|---|---|
| System | administrator or device manager | Put the reviewed Agent Guard payload and optional approved dependency binaries at a stable absolute path. |
| User | the actual login user | Add the Claude Code shell integration to that user's shell rc without creating root-owned user files. |

Codex does not use Claude Code's shell snapshot or its `!` command wrapper.
Codex protection is delivered through managed hooks. Claude Code uses its
managed plugin hooks plus the user-scoped shell integration for the otherwise
unhooked `!cat`/`!head`/`!printenv` path.

## 1. Pin and stage the release (lower-level path)

Use a reviewed Agent Guard release and approved `jq` and `gitleaks` binaries.
Do not fetch an unpinned `latest` installer from a privileged MDM job. Either
vendor the release archive in the organization's deployment repository or
verify it against an independently recorded checksum before extraction.

From an extracted release or a source checkout:

```sh
sudo ./managed-install.sh system \
  --prefix /opt/agent-guard \
  --jq-bin /path/to/approved/jq \
  --gitleaks-bin /path/to/approved/gitleaks
```

The command is update-safe and does not remove unrelated files from the managed
prefix. It does not download software and does not edit either product's managed
configuration. Omitting the dependency options is supported when `jq` and
`gitleaks` are already available in the hosts' runtime `PATH`.

## 2. Enforce Codex managed hooks

Render the versioned configuration fragment:

```sh
/opt/agent-guard/managed-install.sh render-codex \
  --prefix /opt/agent-guard \
  --output /tmp/agent-guard-requirements.toml
```

Review and merge that fragment into the organization's single composed
`requirements.toml`; do not append it blindly when `[features]` or `[hooks]`
already exists. On macOS and Linux, the system location is
`/etc/codex/requirements.toml`. macOS MDM can instead deliver the composed TOML
through the `com.openai.codex:requirements_toml_base64` managed preference.

The fragment sets `[features].hooks = true`, registers `/opt/agent-guard` as the
managed hook directory, and defines Agent Guard's `SessionStart`, `PreToolUse`,
`PostToolUse`, and `Stop` handlers with absolute commands. Codex does not
distribute the scripts in `managed_dir`; the system phase above does that.

The template intentionally omits:

```toml
allow_managed_hooks_only = true
```

That option is useful for a locked-down fleet but suppresses every user,
project, session, and plugin hook. Add it only after reviewing the effect on all
other Codex integrations. Agent Guard's managed hooks work without it.

Installing the Agent Guard Codex plugin remains useful for its setup skill and
UI metadata, but is not required for the managed hook enforcement path. If both
managed and plugin hooks are loaded, avoid duplicate hook execution by deciding
which source owns hooks for the fleet.

## 3. Force-enable the Claude Code plugin

Start from [`deployment/claude-managed-settings.example.json`](../deployment/claude-managed-settings.example.json).
It pins the Agent Guard marketplace ref, force-enables the plugin, and restricts
that marketplace source. It also disables automatic marketplace refreshes so a
CSIRT-controlled version bump is required. Merge its keys into the
organization's existing managed settings instead of replacing unrelated
settings.

Claude Code marketplace sources accept a branch or tag in `ref`, but do not
accept an exact commit in `sha`. Do not add `sha` beside `ref` in
`extraKnownMarketplaces` and describe the result as commit-pinned. For a
cryptographically immutable rollout, build a reviewed plugin seed at the exact
commit with `CLAUDE_CODE_PLUGIN_CACHE_DIR`, distribute it read-only, and set
`CLAUDE_CODE_PLUGIN_SEED_DIR` on the fleet. The managed `enabledPlugins` entry
composes with that seed. A release-tag deployment is simpler, but its integrity
still depends on repository tag controls.

Managed settings locations include:

- macOS: `/Library/Application Support/ClaudeCode/managed-settings.json`
- Linux and WSL: `/etc/claude-code/managed-settings.json`

Agent Guard supports macOS and Linux. WSL is supported through its Linux
environment; native Windows is not currently supported. The PowerShell or
Intune side of a mixed fleet may distribute Claude Code settings, but it must
not report the Agent Guard runtime or Codex hooks as fully installed unless the
supported WSL phase has also completed.

The example deliberately omits `AGENT_GUARD_PII_HOOK_MODE`. PII hooks already
default to `off`; setting it in managed environment policy would also prevent
users or pilot groups from selecting `mask` or `block`.

`allowManagedHooksOnly: true` is also omitted. Claude Code exempts plugins that
are force-enabled in managed `enabledPlugins`, but the option blocks other user
and project hooks and therefore requires a separate organization-wide decision.

## 4. Install Claude shell wrapping for each user

Run the user phase in the login user's context:

```sh
/opt/agent-guard/managed-install.sh user --prefix /opt/agent-guard
```

The command refuses to run as root. It uses Agent Guard's idempotent
`setup-shell`, prepends `/opt/agent-guard/bin` in the managed rc block, and
enables command wrapping by default. This makes the managed `agent-guard`, `jq`,
and `gitleaks` binaries visible before loading the shell integration.

Restart the shell and Claude Code afterward. On managed macOS devices, schedule
this phase as a login-user action rather than running it in a root-only MDM
script; otherwise the wrong home directory or file ownership would result.

## 5. Verify every layer

Run the deterministic local checks:

```sh
/opt/agent-guard/managed-install.sh verify --prefix /opt/agent-guard
```

Then restart both hosts and run the live probes documented in the main README.
The binary smoke test proves the rules work; it does not prove that a particular
host version dispatches the current tool route to hooks.

- Claude Code: verify the managed plugin is active, ask it to read `.env`, and
  test a `!printenv` output path after restarting the shell.
- Codex: verify the managed requirements source is loaded and run the harmless
  PreToolUse and PostToolUse sentinels against the exact execution route in use.

Codex currently exposes a narrower hook boundary than Claude Code. Managed
hooks do not turn unsupported arbitrary reads or opaque host executors into
hooked tools. Keep native Git hooks and CI secret scanning as backstops.

## 6. Update and compliance loop

Deploy Agent Guard and its managed configuration as one versioned unit:

1. Stage and verify the new release and dependency artifacts.
2. Re-run `managed-install.sh system` at the same prefix.
3. Re-render and review the Codex fragment for schema changes.
4. Re-run the user phase so the Claude rc block resolves the current binary.
5. Restart both hosts and repeat the live probes.

Agent Guard's `SessionStart` hook continues to report missing dependencies and
Claude shell-integration version drift. Device management can periodically run
the non-interactive system and verify phases, while rc mutation stays scoped to
the login-user phase.

## Product documentation used by this deployment model

- [Codex managed hooks from `requirements.toml`](https://learn.chatgpt.com/docs/hooks#managed-hooks-from-requirementstoml)
- [Codex managed configuration locations and precedence](https://learn.chatgpt.com/docs/enterprise/managed-configuration#locations-and-precedence)
- [Claude Code managed marketplace restrictions](https://code.claude.com/docs/en/plugin-marketplaces#managed-marketplace-restrictions)
- [Claude Code managed settings and `enabledPlugins`](https://code.claude.com/docs/en/settings)
- [Claude Code marketplace and plugin source pinning](https://code.claude.com/docs/en/plugin-marketplaces#plugin-sources)
- [Claude Code plugin seed directories](https://code.claude.com/docs/en/plugin-marketplaces#pre-populate-plugins-for-containers)
