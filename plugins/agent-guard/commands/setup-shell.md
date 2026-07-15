---
allowed-tools: Bash
description: Install Agent Guard's default-on Claude command wrapping into the current user's shell rc.
---

# /agent-guard:setup-shell

Install or refresh the managed Agent Guard shell integration for Claude Code.
Command wrapping is enabled by default in Agent Guard 2.x.

## Run

!`"${CLAUDE_PLUGIN_ROOT}/bin/agent-guard" setup-shell`

## Report

- On success, tell the user to restart the shell and every Claude Code session.
- On failure, relay the exact error and leave the shell rc unchanged.
- To opt out later, tell the user to set `AGENT_GUARD_COMMAND_WRAPPING=off` for a runtime opt-out or run the plugin-local binary with `setup-shell --no-command-wrapping` for a persistent opt-out.
