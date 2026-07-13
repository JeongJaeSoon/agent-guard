---
name: setup-agent-guard
description: Diagnose, install, and verify the jq and gitleaks dependencies required by the Agent Guard plugin. Use when Agent Guard reports degraded protection, a SessionStart warning asks for setup, plugin hooks fail because a dependency is missing, or a user asks to finish or repair Agent Guard installation.
---

# Setup Agent Guard

Make Agent Guard operational without silently changing the machine. Diagnose first, request approval before package-manager or download actions, and finish with a real smoke test.

## Workflow

1. Resolve the Agent Guard executable.
   - Prefer `command -v agent-guard`.
   - If it is not on `PATH`, use the plugin binary two directories above this skill: `../../bin/agent-guard` relative to this `SKILL.md` directory.
   - Do not install a second copy of Agent Guard merely to get a command on `PATH`.

2. Run the read-only diagnosis:

   ```sh
   "<agent-guard-bin>" setup
   ```

3. If `jq` is missing, identify the available system package manager and show the exact install command. Ask for explicit user approval before running it. Do not use `sudo` unless the user explicitly approves elevated installation.

4. If `gitleaks` is missing, prefer Agent Guard's private, checksum-pinned installer:
   - Determine the target OS and architecture.
   - Fetch the official checksum list for the version reported by `agent-guard setup`.
   - Select the checksum for the exact archive name and show the version, archive, source URL, checksum, and destination.
   - Ask for explicit approval before downloading or installing.
   - After approval, run:

   ```sh
   "<agent-guard-bin>" setup --install \
     --gitleaks-version "<version>" \
     --gitleaks-checksum "<published-sha256>"
   ```

   Never substitute an unverified checksum and never bypass TLS verification.

5. Verify the installation:

   ```sh
   "<agent-guard-bin>" check
   "<agent-guard-bin>" smoke-test
   ```

   Treat `check` as dependency/config validation and `smoke-test` as the runtime proof. Report either both passing or the exact failing command and error.

6. Restart the host application after hook or dependency setup if protection was already loaded in a degraded state. In Codex, plugin hooks provide the supported command boundary; do not configure the Claude-specific bang-command shell wrapper as a Codex setup step.

## Safety And Host Boundaries

- Dependency setup is intentionally approval-gated. A SessionStart hook may diagnose and recommend this skill, but it must never install software itself.
- If installation is declined, leave the machine unchanged and state that Agent Guard is in degraded mode.
- Codex currently protects supported hook surfaces such as `Bash`, `apply_patch`, and MCP tools. Do not claim that Codex hooks intercept arbitrary read, grep, or web-search tools.
- `agent-guard setup-shell`, `agx`, and the bang-command guard are optional Claude Code shell-snapshot integrations. Only configure them when the user explicitly asks for Claude Code coverage.
- If plugin hooks are not trusted or enabled, explain that dependencies alone do not activate runtime protection; trust the plugin hooks and restart the host.
