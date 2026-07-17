# Migrating from Agent Guard 1.x to 2.x

Agent Guard 2.0 makes Claude command wrapping stable and default-on. The plugin
hooks, `agent-guard exec`, `agx`, policy environment variables, Git hook layout,
and release archive layout remain compatible with 1.x.

## Breaking changes

- `shell-init` and `setup-shell` now enable the Claude `cat`, `head`, and
  `printenv` wrappers by default. In 1.10.x, these wrappers required an opt-in
  flag.
- The supported opt-out surface is now `--no-command-wrapping` for a persistent
  managed-rc setting and `AGENT_GUARD_COMMAND_WRAPPING=off` for a runtime
  setting.
- The old bang-guard names are no longer documented or shown in CLI help. The
  2.0 binary still accepts the 1.x stable and experimental flags as hidden
  upgrade shims, then `setup-shell` rewrites the managed block without them.
- GitHub Actions examples move from `JeongJaeSoon/agent-guard@v1` to `@v2`.
  The `v1` moving tag is retained for users who intentionally stay on 1.x.

Command wrapping is best-effort and remains scoped to Claude Code shell
snapshots. The overrides are inert outside Claude Code, fail open with a warning
when transparent masking is unavailable, and do not cover absolute paths,
redirections, sourced files, arbitrary interpreters, binary output, or streaming
commands. `agx` remains the explicit fail-closed wrapper.

## Direct CLI upgrade

Upgrade to the latest release:

```sh
curl -fsSL https://github.com/JeongJaeSoon/agent-guard/releases/latest/download/bootstrap.sh | sh
```

The 2.x bootstrap refreshes the managed shell block with command wrapping on.
To keep automatic wrapping off during the upgrade:

```sh
curl -fsSL https://github.com/JeongJaeSoon/agent-guard/releases/latest/download/bootstrap.sh \
  | AGENT_GUARD_COMMAND_WRAPPING=off sh
```

Restart the shell and every Claude Code session, then verify:

```sh
agent-guard version
agent-guard check
agent-guard smoke-test
```

## Claude Code plugin upgrade

Update and reload the plugin, then refresh the managed shell block:

```text
/plugin update agent-guard@agent-guard
/reload-plugins
/agent-guard:setup-shell
```

Restart the shell and Claude Code. If SessionStart reports different plugin and
shell-integration versions, update the older installation and run
`/agent-guard:setup-shell` again. An existing 1.x managed block using either old
flag continues to load under 2.0 and is normalized on this setup run.

For a persistent opt-out, invoke the installed plugin binary by absolute path:

```sh
<plugin-root>/bin/agent-guard setup-shell --no-command-wrapping
```

For a temporary opt-out, export `AGENT_GUARD_COMMAND_WRAPPING=off` before
starting Claude Code.

## Codex plugin upgrade

Update Agent Guard from Codex's plugin UI. Open **Settings > Hooks**, review the
updated `SessionStart`, `PreToolUse`, `PostToolUse`, and `Stop` hooks, trust each
one again when Codex marks it **Modified**, and restart Codex. Run
`$setup-agent-guard`; completion requires both plugin-local checks and the live
PreToolUse/PostToolUse probes.

Claude command wrapping is not a Codex command boundary and should not be added
as part of Codex-only setup.

## GitHub Actions migration

Change the moving tag in workflows:

```diff
- uses: JeongJaeSoon/agent-guard@v1
+ uses: JeongJaeSoon/agent-guard@v2
```

The Action inputs and checksum requirement are unchanged. Staying on `@v1` is
supported for the 1.x line but does not opt into 2.x behavior.
