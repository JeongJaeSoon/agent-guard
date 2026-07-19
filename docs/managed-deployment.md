# Managed deployment for Claude Code

Rolling Agent Guard out to an organization takes two steps: the administrator
adds the marketplace and plugin to Claude Code's managed settings, and each
developer runs the one-time setup commands. Developers who skip setup are
reminded automatically at session start.

## 1. Add the marketplace and plugin to managed settings (administrator, once)

Merge the keys from
[`deployment/claude-managed-settings.example.json`](../deployment/claude-managed-settings.example.json)
into the organization's existing managed settings instead of replacing
unrelated settings:

- macOS: `/Library/Application Support/ClaudeCode/managed-settings.json`
- Linux and WSL: `/etc/claude-code/managed-settings.json`

The example registers the Agent Guard marketplace pinned to a release tag,
force-enables the plugin for every developer, restricts the marketplace
source, and disables automatic marketplace refreshes so version bumps stay
intentional. The release workflow re-pins the example's `ref` on every
release, so copy it from the matching release or tag.

Marketplace sources accept a branch or tag in `ref` but not an exact commit;
do not add `sha` beside `ref` and describe the result as commit-pinned.

## 2. Run the setup commands (each developer, once per machine)

Once the managed settings land, Claude Code loads the plugin automatically.
Each developer then completes setup in a Claude Code session:

1. **Dependencies** (`jq`, `gitleaks`): run the `setup-agent-guard` skill —
   it diagnoses first and asks approval before installing. Equivalent CLI:
   `agent-guard setup` to diagnose, then
   `agent-guard setup --install --gitleaks-checksum <published-sha256>`.
2. **Shell integration** (covers the unhooked `!cat`/`!head`/`!printenv`
   path): run `/agent-guard:setup-shell`, then restart the shell and Claude
   Code.
3. **Verify**: `agent-guard check` and `agent-guard smoke-test`, or
   `/agent-guard:verify` for a working-tree scan.

## 3. Missing setup is suggested automatically

The plugin's `SessionStart` hook checks every session start and posts a
session message with the exact command to run:

- when `jq`, `git`, `gitleaks`, or a policy file is unavailable, it reports
  degraded protection and points at the `setup-agent-guard` skill /
  `agent-guard setup`;
- when the shell integration is not loaded (or its version drifted from the
  plugin), it suggests `/agent-guard:setup-shell`.

No fleet-side enforcement is required for these reminders; they ship with the
force-enabled plugin.

Codex has no separate managed path: Codex users install the plugin through
the standard install described in the README.
