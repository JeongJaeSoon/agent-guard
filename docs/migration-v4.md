# Migrating from Agent Guard 3.x to 4.x

## Breaking changes

- The hidden 1.x compatibility flags `--claude-bang-guard` and
  `--experimental-bang-guard` are removed from `shell-init` and `setup-shell`.
  Both commands now reject them (exit 2), and `shell-init` emits no snippet for
  a rejected invocation. Since 2.0 the flags were silent no-ops: command
  wrapping is on by default and `--no-command-wrapping` is the only opt-out.
- `shell-init` now fails loudly (exit 2, no snippet) on any unknown argument.
  Previously it printed the error but still emitted the full snippet with
  exit 0, so a typo in a managed rc line went unnoticed.

## What to do

If your shell rc still passes one of the removed flags, re-run the managed
setup once — it writes the current default invocation:

```sh
agent-guard setup-shell
```

To keep command wrapping disabled, run `agent-guard setup-shell
--no-command-wrapping` instead. Then restart your shell and any Claude
Code/Codex sessions launched from it.

Until the rc is updated, an un-migrated line loads **no shell integration**:
`agx`, the preexec nudge, and the `cat`/`head`/`printenv` command wrappers are
absent, so `!`-command output is not masked (the documented `!` blind spot —
no plugin hook fires for it). The plugin's tool-call hooks (PreToolUse /
PostToolUse / Stop) are unaffected. On Claude Code the SessionStart hook warns
that command wrapping is not loaded until the rc is fixed; Codex sessions get
no such warning because they do not use this shell boundary.
