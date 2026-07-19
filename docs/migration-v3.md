# Migrating from Agent Guard 2.x to 3.x

Agent Guard 3.0 replaces the managed install scripts with a simpler model:
the administrator merges the managed settings example into Claude Code's
managed settings, and each developer runs the one-time setup commands. The
plugin hooks, CLI commands, policy environment variables, Git hook layout,
and release archive layout are unchanged from 2.2.

## Breaking changes

- `managed-install.sh` and the self-contained `managed-bootstrap.sh` are
  removed, along with the `managed-bootstrap.sh` and
  `managed-bootstrap.sh.sha256` release assets. Fleet tooling that downloads
  or verifies either asset must stop doing so.
- The Codex managed hook path is removed (`deployment/codex-hook` and
  `deployment/codex-requirements.toml.template`). Codex users install the
  plugin through the standard install described in the README.
- `setup-shell --prepend-path` is removed. The gitleaks resolution order
  (`AGENT_GUARD_GITLEAKS_BIN`, then `PATH`, then
  `AGENT_GUARD_GITLEAKS_BIN_DIR/gitleaks`) already makes the private
  `setup --install` destination usable without a `PATH` prepend.

## Managed fleets: what to do instead

1. **Administrator, once**: merge
   [`deployment/claude-managed-settings.example.json`](../deployment/claude-managed-settings.example.json)
   from the v3 release or tag into the organization's Claude Code managed
   settings.
2. **Each developer, once per machine**: run the setup commands described in
   [Managed deployment for Claude Code](managed-deployment.md). Developers
   who skip setup are reminded automatically at session start by the
   plugin's `SessionStart` hook.

## Direct CLI installs

Nothing changes: `bootstrap.sh`, `install.sh`, and the release archive
layout are the same as in 2.x.

## GitHub Actions

The Action itself is unchanged between 2.2 and 3.0. Move to the new moving
tag when convenient:

```diff
- uses: JeongJaeSoon/agent-guard@v2
+ uses: JeongJaeSoon/agent-guard@v3
```

`@v2` remains on the 2.x line; pin `@v2`, a full tag, or a commit SHA when
you intentionally stay on 2.x.
