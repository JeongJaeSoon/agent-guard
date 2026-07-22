---
allowed-tools: Bash
description: Install Agent Guard's default-on Claude command wrapping into the current user's shell rc.
---

# /agent-guard:setup-shell

Install or refresh the managed Agent Guard shell integration for Claude Code.
Command wrapping is enabled by default.

## Run

Use the Bash tool to run:

```sh
"${CLAUDE_PLUGIN_ROOT}/bin/agent-guard" setup-shell
```

Do not use `!` command interpolation for this step. `setup-shell` writes the
user's shell rc, so Claude's sandbox may require approval to run the Bash tool
outside the sandbox. If the host cannot request that approval, tell the user to
run the same command directly in their terminal.

## Report

- On success, tell the user to restart the shell and every Claude Code session.
- On failure, relay the exact error and the direct terminal command; leave the
  shell rc unchanged.
- To opt out later, tell the user to set `AGENT_GUARD_COMMAND_WRAPPING=off` for a runtime opt-out or run the plugin-local binary with `setup-shell --no-command-wrapping` for a persistent opt-out.
