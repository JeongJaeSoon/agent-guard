# Integrations and coverage

Agent Guard keeps policy and scanning in its portable CLI. Host adapters pass
their native event to that CLI; they do not implement a second policy engine.
Use more than one layer for important repositories.

Per-tool matchers, the different output-replacement contracts of Claude and
Codex, and the timeout budgets are summarized in
[Output masking coverage](#output-masking-coverage). A matcher in this
repository does not prove that your installed copy dispatches it or that the
host accepts the replacement; run the live probes in
[Verification](verification.md).

To wire the hooks without installing a plugin, start from the manifests in
[`examples/claude/settings.project.json`](https://github.com/JeongJaeSoon/agent-guard/blob/main/examples/claude/settings.project.json)
and
[`examples/codex/hooks.json`](https://github.com/JeongJaeSoon/agent-guard/blob/main/examples/codex/hooks.json),
and point each hook command at `plugins/agent-guard/bin/agent-guard` in your
checkout. They are rendered from the same source as the plugin manifests.

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
With `AGENT_GUARD_DENY_READ_MODE=mask`, a Codex shell command that is exactly
`cat PATH` for a protected file gets the same masked view in its block reason as
a Claude `Read` (see [configuration](configuration.md#masked-view-on-a-blocked-read)).
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
/absolute/path/to/agent-guard/install.sh git-hooks
```

The installer sets `core.hooksPath=githooks` only when it will not overwrite an
existing hook setup. It scans staged added lines. Check the result with:

```sh
git config --get core.hooksPath
test -x githooks/pre-commit
```

The expected hooks path is `githooks`. A hook can be bypassed by someone who
can alter local Git configuration, so it complements rather than replaces CI.

The hook names the agent-guard executable by absolute path. If that file is
removed or moved, the hook still blocks the commit (exit 1), because the
staged-secret scan cannot run, and prints the missing path with the fix:
rerun `install.sh git-hooks` from the new installation, or remove the hook.
Rerunning `install.sh git-hooks` also adds this message to a hook installed by
an earlier release, which otherwise fails with `exec: ... not found`. To remove
the hook, run in the repository:

```sh
git config --unset core.hooksPath
rm githooks/pre-commit
```

Git then runs `.git/hooks` again, including a hook the installer had chained.
See [Removing an installation](installation.md#removing-an-installation).

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
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
      - uses: JeongJaeSoon/agent-guard@v3
        with:
          paths: "."
          gitleaks-version: "8.30.1"
          gitleaks-checksum: "551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb"
```

`@v3` is a moving major-version tag and receives compatible updates. For a
managed rollout, replace it with the exact release tag you reviewed, written as
`@vX.Y.Z`, and advance that pin through a reviewed pull request. A commit SHA
provides an even tighter immutable pin when your organization requires it.

The shown checksum is for gitleaks 8.30.1 on `linux/x64`; refresh the version
and checksum together when changing either one. Generate a matching value with
`agent-guard checksum`. `require-checksum` is `true` by default. Set it to
`false` only for local experimentation. `paths` is whitespace separated, so an
individual path cannot contain spaces. `config-path` points the scan at your own
gitleaks config instead of the bundled one.

## Limits and backstops

- Working-tree scans cover tracked additions and non-ignored untracked files.
  They do not sweep ignored files or arbitrary content outside the repository.
- A structured write target is scanned even when it is ignored or outside the
  work tree. Codex `apply_patch` paths are also directly scanned when the patch
  names them. The tracked diff, index diff, and untracked-content components
  each receive one third of the 10 MiB working-tree input budget, keeping their
  total below 10 MiB. Files requiring a direct scan have a separate 10 MiB
  aggregate budget; files covered by a successful working-tree backstop do not
  consume it. These are bounded-input policies, not measured wall-clock timeouts.
  An oversized or unreadable target is an infrastructure failure, not a clean
  scan. The 10 MiB default can only be raised, with
  `AGENT_GUARD_SCAN_INPUT_MAX_BYTES` (see [configuration](configuration.md));
  both budgets derive from it.
- Bash and MCP mutations may lack a usable named target. Their working-tree
  backstop remains useful but cannot discover every ignored or
  outside-repository write.
- When one mutation produces both a working-tree finding and sensitive tool
  output, the PostToolUse hook reserves its single stdout JSON value for the
  host-valid sanitized output. It reports the disk finding on stderr and marks
  the audit outcome `blocked`. A disk finding with no output rewrite still exits
  with status 2.
- A blocking Claude `PreToolUse`, `UserPromptSubmit` or `Stop` hook exits 2
  with the reason on stderr. On Claude Code 2.1.214 or newer, read from the
  `AI_AGENT` variable Claude Code exports, it also prints that reason as JSON.
  Claude Code then shows the reason without the hook command and leaves a
  blocked prompt out of the block message. Older or unrecognized versions get
  stderr only: before 2.1.214, an exit-2 hook whose JSON failed validation
  could stop blocking. Claude Code still lists the hook command in the ctrl+o
  view of a `Stop` hook, passes it to the model with a `Stop` block, and keeps
  blocked prompts in its local prompt history.
- A masked view of a protected file travels in that same block reason, so
  every host gets it from the same stderr and Claude Code 2.1.214+ also as
  JSON. Agent Guard does not swap a tool's output after the read instead: that
  path lets the original output through on an error, and the file has already
  been read by then.
- Shell blocking is pattern-based. Search patterns of plain `grep` and
  `rg --no-config` commands and new `openssl` key output paths are left out of the path match
  ([operations](operations.md)), but it can still block other benign
  path-shaped text, and an
  actively evasive command can avoid a fixed pattern list.
- A user-typed host shell escape is outside the tool-hook boundary. Do not print
  credentials there; use `agent-guard exec -- <command>` / `agx`, redirect both
  streams away from the transcript, or run the command through a protected host
  tool.

These are coverage boundaries, not proof that every failure mode is permissive.
Scanner infrastructure follows the explicit `AGENT_GUARD_INFRA_FAILURE_MODE`
policy described in [Configuration](configuration.md).

## Output masking coverage

Output masking rewrites a tool result before the model reads it. It runs only
on the routes below, only when the host dispatches the hook and accepts the
replacement, and `AGENT_GUARD_OUTPUT_REDACT=off` turns it off. A route listed
as covered is a candidate: prove it on your install with the live probes in
[Verification](verification.md).

| Host | Route | Masking | Note |
| --- | --- | --- | --- |
| Claude | Successful `PostToolUse` of `Write`, `Edit`, `MultiEdit`, `NotebookEdit`, `Bash`, `PowerShell`, `apply_patch`, `Read`, `NotebookRead`, `Grep`, `Glob`, `WebFetch`, `WebSearch`, `Agent`, `Task`, `Skill`, `Monitor`, `LSP`, `ListMcpResourcesTool`, `ReadMcpResourceTool` | Covered | The matcher is anchored to these exact names. |
| Claude | `mcp__*` tools | Covered | MCP results skip the built-in output schema check. |
| Claude | Code Mode results: `REPL` when a script ends or throws, `Poll` when its output is delivered | Covered | The calls a script makes are covered under their own names above. These two routes carry what the script hands back to the model, including the failed call the host appends to a thrown error. Shapes and replacement acceptance were captured on 2.1.330. The script itself still receives a failed call's output, and the part of a successful output past about 30,000 characters, unmasked (host limits). Probe: [Verification](verification.md#claude-code-code-mode). |
| Claude | Failed tool calls (`PostToolUseFailure`) | Detected, not masked (host limit) | Same matcher as `PostToolUse`. The host lets this event add context only, so the failure output reaches the model unchanged. On a finding, the hook names the category, never the value, and tells the model not to repeat or use it and to tell the user it may need rotating. `logs export` records `hook-post-tool-failure` with outcome `warned`. Host-side fix request: [anthropics/claude-code#97278](https://github.com/anthropics/claude-code/issues/97278). |
| Claude | Any other tool name | Not covered | The hook never starts. |
| Claude | A `!` shell escape you type yourself | Not covered | Outside the tool-hook boundary; use `agent-guard exec` / `agx`. |
| Claude | Image or PDF blocks | Text parts only | Binary bytes are restored unchanged; if that restore fails the payload is emptied rather than leaked. |
| Claude | Sessions with function hooks (Claude Mods) enabled | Covered | Command hooks keep running as `classic.*` events. Probed on 2.1.278. Other mods' own file and network access is not seen. |
| Codex | `Bash` / `exec_command`, `apply_patch`, `Agent`, `Task`, `mcp__*` | Covered | Codex replaces the result with hook feedback (`decision: "block"` plus `additionalContext`), not with `updatedToolOutput`. |
| Codex | `write_stdin` | No new event | The original command's `PostToolUse` may arrive when it ends. |
| Codex | Other local tools, hosted `WebSearch` | Not covered | Not a coverage claim. The Codex matcher is unanchored, so a custom tool whose name merely contains `Bash`, `Agent`, or `Task` (for example `MyTaskRunner`) may still trigger generic redaction; that incidental match is not treated as coverage. Hosted `WebSearch` is not on the hook path at all. |

Figma file keys: on an MCP server whose name contains `figma` (any case), a
22-character alphanumeric value in a `fileKey` or `file_key` field is not a
finding, in the MCP input check or in output masking, on either host. The key
names a document; opening the file still needs a Figma login with access to
it. The same value anywhere else in the event (another field, a URL query, a
key assignment) is still a finding, and masking then replaces every copy,
including the one in the file URL. A field name written with JSON Unicode
escapes, or JSON text encoded twice, is not recognized, so that value is still
scanned and masked.

What masking cannot do on either host:

- Undo the tool effect. Files, commands, and network requests already happened
  when `PostToolUse` runs; masking is a model-input boundary, not a rollback.
- Survive a timeout. A hook killed at the host budget produces no replacement.
  Keep the Git hook and CI backstops.
- Force acceptance. If a Claude built-in replacement does not match the tool's
  output schema, the host may keep the original. Agent Guard preserves the
  original JSON shape whenever it can. The last-resort fixed replacement, used
  when no parser can rewrite the response, has the tool's shape for `Bash`,
  `Read`, `Write`, `Edit`, `NotebookEdit`, `Grep`, `Glob`, `Skill`,
  `Monitor`, `REPL` and `Poll`. Claude Code 2.1.330 was observed to accept
  the `Bash`, `REPL` and `Poll` shapes; the others follow the structure
  that version records for the tool and are not yet confirmed on a live host.
  Every other tool still gets a bare `[REDACTED]` string there, which a
  built-in tool's schema check drops: that is the known exception.
- Recognize a secret that has no secret-like shape. A value under a generic
  key name with no vendor prefix (`APP_SEED=...`, or the same value bare in a
  log line, an argv list or a URL password) passes the detectors. With
  `AGENT_GUARD_DENY_READ_MODE=mask`, the values of the project's root dotenv
  files are masked as known values on every route above
  ([Known dotenv values in output](configuration.md#known-dotenv-values-in-output)).
  In `block` mode (the default), and for a secret that is not in a root dotenv
  file, this gap remains.

Hook timeouts in every shipped manifest:

| Event | Timeout |
| --- | --- |
| `PreToolUse` | 60 s |
| `PostToolUse` | 20 s |
| `PostToolUseFailure` (Claude only) | 20 s |
| `Stop` | 20 s |
| `SessionStart` | 5 s |
| `UserPromptSubmit` | 10 s |

`AGENT_GUARD_INFRA_FAILURE_MODE=closed` applies when Agent Guard itself can
decide and return exit status 2 in time. A non-empty payload that is not a JSON
object is rejected regardless of that mode; empty stdin passes with status 0.

On a Claude `PostToolUse`, exit status 2 only shows the reason: the tool has
run and its output still reaches the model. So when the hook cannot check an
output under `closed` (no scanner, no usable policy file, a written path it
cannot scan), it also prints a replacement in which every non-empty string is
`[REDACTED]` and the shape is unchanged, and Claude Code applies it beside the
exit status 2 (checked on 2.1.330 for `Bash`, `REPL` and `Poll`).
`AGENT_GUARD_OUTPUT_REDACT=off` turns that off together with output masking.
Two cases stay as they were: when no binary can be found, the launcher has no
parser and can only exit 2, and Codex takes no replacement. One case is open:
the replacement also changes a field the host reads as one of a few words,
such as `type` in a `Write` result or `mode` in a `Grep` result, and
whether the host then keeps the replacement for those tools has not been
checked.

Each plugin hook command is one short line that runs the plugin's
`hooks/launch.sh` with the host name, the hook subcommand and the plugin
directory the host selected. The launcher runs that directory's
`bin/agent-guard` when the directory is complete. If a plugin update deleted
the directory during a session, it uses `current` or the newest complete
installed version instead; it never substitutes another version for a
directory that still exists but is incomplete. When no binary can be found,
the launcher applies `AGENT_GUARD_INFRA_FAILURE_MODE`: `closed` blocks with the
reason on every call and `open` warns once per session. When no launcher can be
found at all, for example because the host did not set its plugin-root
variable, the command line applies the same mode itself and warns on every
call.

A Claude `PreToolUse` hook that the host kills at its timeout, cannot start,
exits with a status other than 0 or 2, or prints stdout that is not one valid
JSON object, blocks the tool call: the
Claude manifests set `"onFailure": "block"` on that hook, whatever
`AGENT_GUARD_INFRA_FAILURE_MODE` says. The infrastructure mode covers failures
Agent Guard detects and reports itself; a hook that never returns cannot apply
it. The 60 s budget leaves room for slow but legitimate checks, such as a long
inline script on a loaded machine. Claude Code before 2.1.295 ignores
`onFailure` and lets a timed-out `PreToolUse` hook through, and the Codex
manifests do not set it. Other events keep the host default: a timed-out
`UserPromptSubmit`, `PostToolUse`, `PostToolUseFailure`, `Stop`, or
`SessionStart` hook does not block.

A `PostToolUseFailure` hook cannot block or mask anything: the tool has already
failed, and none of `updatedToolOutput`, `decision: "block"`, or exit status 2
replaces the error text. So a scan that cannot run is reported to the
model as additional context, never as a clean result: under
`AGENT_GUARD_INFRA_FAILURE_MODE=open` at most once every 10 minutes per
session, which Claude Code also shows to you as a `systemMessage`, and on every
failed call under `closed`.
Input that is not a JSON object, or has no `error` field, passes through with
no response. `AGENT_GUARD_OUTPUT_REDACT=off` turns this check off as well.
