# Integrations and coverage

Agent Guard keeps policy and scanning in its portable CLI. Host adapters pass
their native event to that CLI; they do not implement a second policy engine.
Use more than one layer for important repositories.

## Claude Code

The plugin hooks inspect supported reads, writes, shell commands, web/MCP input,
and tool output. `PostToolUse` and `Stop` scan working-tree additions and
untracked files; a named write target also receives a direct post-write scan.
`UserPromptSubmit` scans prompts before they enter the model transcript.

The optional shell integration protects common `!` command-output cases by
running them through `agent-guard exec`. It needs an explicit shell-rc update.
It is a convenience layer, not a complete command interceptor; use normal host
tools, `agx`, Git hooks, or CI for a stronger backstop.

## Codex

The Codex plugin matches `Bash`, `apply_patch`, `Agent`, `Task`, and MCP tools.
It scans proposed patch additions before `apply_patch`, then scans changed files
after mutation and at stop. A patch envelope does not reliably identify a write
target, so it does not receive the direct named-file scan used by structured
write tools.

Codex does not promise interception of arbitrary `Read`, `Grep`, or web tools.
Its hooks also run only after their current definitions have been reviewed and
trusted. Official documentation covers plugin-hook trust and `PLUGIN_ROOT`:
[Codex Hooks](https://learn.chatgpt.com/docs/hooks). Test the exact tool route;
an orchestration wrapper can bypass the route a probe tested.

## Native Git hook

Install the supplied pre-commit hook from a standalone installation or a clone:

```sh
cd <your-project>
~/.agent-guard/install.sh git-hooks

# From an Agent Guard source checkout instead:
./install.sh git-hooks
```

The installer sets `core.hooksPath=githooks` only when it will not overwrite an
existing hook setup. It scans staged added lines. Check the result with:

```sh
git config --get core.hooksPath
test -x githooks/pre-commit
```

The expected hooks path is `githooks`. A hook can be bypassed by someone who
can alter local Git configuration, so it complements rather than replaces CI.

## GitHub Actions

Use the Action on pull requests and pushes to scan a checkout in CI. It is the
repository backstop for paths and host routes that an interactive plugin does
not observe.

```yaml
name: Agent Guard

on:
  pull_request:
  push:

jobs:
  secret-guard:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
      - uses: JeongJaeSoon/agent-guard@v3
        with:
          paths: "."
          gitleaks-checksum: "<sha256 of the gitleaks release archive>"
```

Get the matching checksum with `agent-guard checksum`; CI is usually
`linux/x64`, so use that printed value. `require-checksum` is `true` by default.
Set it to `false` only for local experimentation. `paths` is whitespace
separated, so an individual path cannot contain spaces.

## Limits and backstops

- Working-tree scans cover tracked additions and non-ignored untracked files.
  They do not sweep ignored files or arbitrary content outside the repository.
- A structured write target is scanned even when it is ignored or outside the
  work tree. Codex `apply_patch` paths are also directly scanned when the patch
  names them. Direct targets and each working-tree scan component have a 10 MiB
  byte budget; it is a bounded-input policy, not a measured wall-clock timeout.
  An oversized or unreadable target is an infrastructure failure, not a clean
  scan.
- Bash and MCP mutations may lack a usable named target. Their working-tree
  backstop remains useful but cannot discover every ignored or
  outside-repository write.
- Shell blocking is pattern-based. It can block benign path-shaped text and an
  actively evasive command can avoid a fixed pattern list.
- A user-typed host shell escape is outside the tool-hook boundary. Do not print
  credentials there; use `agent-guard exec -- <command>` / `agx`, redirect both
  streams away from the transcript, or run the command through a protected host
  tool.

These are coverage boundaries, not proof that every failure mode is permissive.
Scanner infrastructure follows the explicit `AGENT_GUARD_INFRA_FAILURE_MODE`
policy described in [Configuration](configuration.md).
