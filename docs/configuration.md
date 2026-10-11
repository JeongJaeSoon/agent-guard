# Configuration

Agent Guard reads policy from its bundled configuration and selected environment
variables. Keep custom policy files reviewable and test them with
`agent-guard smoke-test` plus an appropriate live probe.

Read [Output masking coverage](integrations.md#output-masking-coverage) for
what `AGENT_GUARD_INFRA_FAILURE_MODE=closed` and output redaction reach per
event. In particular, exit status 2 from `PostToolUse` cannot undo a tool effect
that already happened, and a `closed` decision that misses the host timeout
never reaches the host.

## Infrastructure policy

`AGENT_GUARD_INFRA_FAILURE_MODE` controls an unavailable dependency, policy, or
scanner error in a lifecycle hook:

| Value | Behavior |
| --- | --- |
| `open` (default) | Continue with one visible degraded-protection notice |
| `closed` | Refuse the hook action with exit status 2 |

This is distinct from a secret finding, which blocks. An invalid value is read
as `open`; set an explicit valid value in managed environments.

Non-empty malformed or non-object PreToolUse, PostToolUse, and Stop input is
also distinct from unavailable infrastructure. Agent Guard rejects one of
those events even if infrastructure mode is `open`.
PreToolUse and Stop can block their boundary action with exit status 2. Because
PostToolUse runs after the tool, Agent Guard first uses an independent portable
parser to recover and conservatively replace `tool_response` from a valid host
envelope that the primary validator could not handle. A non-empty malformed or
non-object PostToolUse envelope is reported with exit status 2, but that
diagnostic cannot retract a result the host already received. Malformed-input
diagnostics are not deduplicated with degraded-infrastructure notices.
Empty stdin is the documented exception: PreToolUse, PostToolUse, and Stop
return status 0 with no response. See [Output masking coverage](integrations.md#output-masking-coverage).

## Output and prompt handling

- `AGENT_GUARD_OUTPUT_REDACT=off` disables secret-like output masking. The
  default is masking.
- A tool result too large to scan is masked fail-closed: every nonempty string
  in it is replaced. Anthropic content-block discriminators (`type`,
  `source.type`, `media_type`) survive that rewrite when the value is exactly a
  known protocol token, so the sanitized result still parses as the block shape
  the host sent. Any other string is masked, including under those keys. A
  portable secondary serializer preserves object keys, order, containers, and
  scalar types if the primary JSON rewrite cannot run; it neutralizes numeric
  and true-valued leaves while producing one host-valid replacement. This
  replacement is required because PostToolUse runs after the tool and exit
  status alone cannot retract the original result.
- Base64 image and PDF blocks (`media_type` of `image/png`, `image/jpeg`,
  `image/gif`, `image/webp` or `application/pdf`, in the Anthropic `source`
  shape, MCP's native `data`/`mimeType` shape or Claude Code's `Read` `file`
  shape) are not inspected: the scanner cannot read pixels. Their payload is
  excluded from the size cap while text siblings in the same result are still
  scanned and masked. A normal rewrite restores the original binary bytes
  unchanged after scanning. If the final restore serializer fails, Agent Guard
  instead emits the stripped block with an empty `data`/`base64` payload; this
  is secret-safe but lossy and does not re-enter the whole-leaf or fixed-string
  fallback. A base64 block of a text media type (`text/plain`, `image/svg+xml`)
  is treated as text. See [Output masking coverage](integrations.md#output-masking-coverage).
- `AGENT_GUARD_PROMPT_GUARD_MODE=block` is the default. `warn` passes a prompt
  with a notice and `off` disables secret prompt scanning. Hosts currently do
  not provide safe prompt rewriting, so `mask` degrades to block.
- Very large prompts skip the assignment heuristic to protect the host hook
  budget. Gitleaks still runs; the skipped heuristic follows the infrastructure
  policy.

## PII handling

PII hooks are off by default. The default `regex` provider is local.

| Setting | Meaning |
| --- | --- |
| `AGENT_GUARD_PII_HOOK_MODE=off` | No PII hook processing |
| `block` | Block recognized PII in supported inputs |
| `mask` | Mask PII in supported outputs and block Tier-2 input PII |

`AGENT_GUARD_PII_PROVIDER=http` and `pleno` send supplied text to the exact
user-configured endpoint. Review its privacy/retention terms before use. See
[Privacy](../PRIVACY.md) for the data boundary and controls.

`AGENT_GUARD_PII_SKIP` is available only with the local `regex` provider. It
accepts comma- or space-separated `EMAIL`, `PHONE`, and `IP_ADDRESS`. It cannot
skip Tier-2 values such as payment cards, US SSNs, or Korean resident numbers;
an unknown or Tier-2 type is an error. `AGENT_GUARD_PII_LANGUAGE` selects the
provider language where supported (default `en`; `pleno` accepts `en` or `ja`),
and `AGENT_GUARD_PII_TIMEOUT_SECONDS` must be a positive integer for
endpoint-backed providers (default `30`).

Mode values are checked. An unrecognized `AGENT_GUARD_PROMPT_GUARD_MODE` or
`AGENT_GUARD_PII_HOOK_MODE` is an error: the affected hook exits with status 2
and blocks until the value is fixed. An unrecognized `AGENT_GUARD_PII_PROVIDER`
is an error only where the provider is called: `pii-filter` and
`AGENT_GUARD_PII_HOOK_MODE=block`. `mask` mode does not call the provider, so
it ignores the value.
`AGENT_GUARD_INFRA_FAILURE_MODE` is the exception: an unrecognized value falls
back to `open`.

## Masked file views

`agent-guard mask-file [--key-paths] FILE` prints a copy of a configuration file
with every value replaced by `[MASKED]`. Keys, section headers, comments, blank
lines and nesting stay as written. `--key-paths` prints the key path of each
masked value instead, one per line. With `AGENT_GUARD_DENY_READ_MODE=mask` the
hooks put this view in the reason of a blocked read (see below).

The format comes from the file name after symlinks are resolved, never from the
content. The first matching row wins:

| Format | File names |
| --- | --- |
| json | `*.json` |
| yaml | `*.yaml`, `*.yml` |
| ini | `*.ini`, `*.cfg`, `*.cnf`, `*.conf`, `.npmrc`, `.pypirc`, and `credentials` or `config` directly inside a `.aws` directory |
| dotenv | `.env`, `.env.*`, `*.env`, `.flaskenv`, `.flaskenv.*`, `.dev.vars`, `.dev.vars.*`, except a name ending in `.envrc` |

Each format accepts only a subset:

- dotenv: `KEY=value` and `export KEY=value` lines with optional spaces around
  `=`, keys matching `[A-Za-z_][A-Za-z0-9_.]*`, unquoted values, single- or
  double-quoted values that close on the same line, empty values, comment lines
  and blank lines. A comment after a value is masked with the value. Shapes a
  shell sourcing the file would continue onto the next line fail: a value ending
  in a backslash, a quote, backslash, backtick, `(` or `<` (a heredoc) in an
  unquoted value before its comment, and a backtick, `$(`, `${` or `$[` in a double-quoted
  value. Key path: `KEY`.
- ini: `[section]` headers, `key = value` split at the first `=`, `;` and `#`
  comment lines and blank lines. Keys may contain `/`; only in `.npmrc` may
  they contain `:` (as in `//registry.example/:_authToken`), because most other
  ini readers also split at `:`. Lines without `=`, indented lines and values
  ending in a backslash fail. Key path:
  `section.key`, or `key` before the first section.
- json: one object or array document parsed by `jq`; every string, number, boolean and null
  becomes `"[MASKED]"`, printed with `jq`'s default indentation. Key path: keys
  joined by `.`, array elements by index (`servers.0.host`).
- yaml: space-indented block mappings and sequences, one-line plain or quoted
  scalars, quoted keys, comments, blank lines and one leading `---`. A
  double-quoted key with a backslash escape fails, so a key path is always the
  key itself. Tabs in
  indentation, block scalars (`|`, `>`), flow collections (`{`, `[`), anchors,
  aliases, tags, merge keys (`<<`), complex keys (`?`), a second document
  (`---`, `...`), directives (`%`) and multi-line scalars fail. Key paths as for
  json.

In dotenv, ini and yaml an empty value stays empty and has no key path. Every
other case fails: a name
outside the table (`.envrc` and `*.envrc`, which only a shell reads, `*.pem`,
`*.key`, `.netrc`, `*.toml`, `*.tfvars`, an
extensionless `.kube/config`, and so on), content outside the format's subset, a
file over 64 KiB, or anything that is not a readable regular file. A failure
exits non-zero, prints nothing on stdout, and writes one fixed line to stderr
that quotes neither the path nor the content. A caller must treat any non-zero
status as "no masked view" and keep blocking.

### Masked view on a blocked read

`AGENT_GUARD_DENY_READ_MODE` is `block` (the default) or `mask`. In both modes
a read of a deny-listed file is blocked and the tool never reads it. In `mask`
mode the block reason also carries the masked view, so an agent can see the
keys and structure without the values:

```text
agent-guard: blocked sensitive file access: /home/me/project/.env
agent-guard: masked view follows (values replaced with [MASKED]; the file itself was not read by the tool)
DB_HOST=[MASKED]
DB_PASSWORD=[MASKED]
```

The path is the resolved file, so a `Read` and a `cat` of the same file give
the same reason byte for byte. The mode is checked only when a read is
blocked: any value other than `block` or `mask` blocks without a view, and the
reason names the variable, not its value.

Only two reads get a view:

- `Read` whose `file_path` is absolute and is the only deny-listed string in
  its input. `Grep`, `Glob`, `NotebookRead`, a relative `file_path` and a
  deny-listed path in another field block as in `block` mode.
- A shell command that is exactly `cat PATH` or `cat -- PATH` after leading and
  trailing spaces and tabs are trimmed, where `PATH` is one word made only of
  `A-Z a-z 0-9 . _ / ~ + @ -`, starts with `~` only as `~` or `~/`, and is not
  `-`. A relative path is resolved against the event's `workdir` or `cwd`. Any
  other command that names a deny-listed path (quotes, `$`, globs, several
  paths, pipes, redirections, `;`, `&&`, a newline, an environment prefix,
  `head`, `sed -n` and so on) blocks as in `block` mode, with one more line:
  "for a masked view, read the protected file alone with the read tool or
  `cat <path>`".

Before the view is returned, the whole view is scanned again with gitleaks.
The read stays blocked with no view, whatever `AGENT_GUARD_INFRA_FAILURE_MODE`
says, when:

- the file cannot be masked (see the failures above);
- the view is over 6,144 bytes ("too large for a masked view"). It is never
  cut, and the limit keeps it below the size at which hosts move hook output
  to a file;
- the rescan finds something, such as a token left in a comment, or cannot
  run.

Keys and comments are shown as written. If key names are sensitive too, keep
`block`. The view covers the whole file; `Read`'s `offset` and `limit` are
ignored.

## Environment reference

| Variable | Default / use |
| --- | --- |
| `AGENT_GUARD_DENY_READ_PATHS` | Override the deny-read policy file. |
| `AGENT_GUARD_DENY_READ_MODE` | `block` (default) or `mask`; `mask` adds a masked view to the reason of a blocked `Read` or `cat` of a protected file. |
| `AGENT_GUARD_DENY_BASH_PATTERNS` | Override the risky-shell-command policy file. |
| `AGENT_GUARD_GITLEAKS_CONFIG` | Override the gitleaks configuration file. |
| `AGENT_GUARD_GITLEAKS_BIN` | Select a gitleaks executable. |
| `AGENT_GUARD_GITLEAKS_BIN_DIR` or `AGENT_GUARD_BIN_DIR` | Select the private gitleaks install directory. |
| `AGENT_GUARD_INFRA_FAILURE_MODE` | `open` (default) or `closed` for hook infrastructure failures. |
| `AGENT_GUARD_SCAN_INPUT_MAX_BYTES` | Positive integer `>= 10485760`; default `10485760` (10 MiB, split into thirds per producer, so `scan-staged` and each `scan-working-tree` component get 3495253 bytes by default). It can only raise the budget: smaller, non-numeric, or overlong (19+ digit) values keep the default. A larger budget scans more input; it never excludes anything from scanning. |
| `AGENT_GUARD_OUTPUT_REDACT` | Output secret masking; set `off` only with deliberate acceptance of the reduced protection. |
| `AGENT_GUARD_PROMPT_GUARD_MODE` | `block` (default), `warn`, `off`, or the currently blocking `mask` fallback. |
| `AGENT_GUARD_PII_HOOK_MODE` | `off` (default), `block`, or `mask`. |
| `AGENT_GUARD_PII_PROVIDER` | `regex` (default), `http`, or `pleno`. |
| `AGENT_GUARD_PII_REDACT_URL` | Required user-controlled endpoint for the remote PII providers. |
| `AGENT_GUARD_PII_SKIP` | Local-regex opt-out for `EMAIL`, `PHONE`, and `IP_ADDRESS` only. |
| `AGENT_GUARD_PII_LANGUAGE` / `AGENT_GUARD_PII_TIMEOUT_SECONDS` | Provider language and positive timeout control. |
| `AGENT_GUARD_COMMAND_WRAPPING` | `off` disables shell command wrapping for the current process. |
| `AGENT_GUARD_LOG_MODE` | The post-v3.3.0 metadata log is on by default; set `off` to opt out. |
| `AGENT_GUARD_RELEASE_CHECK` | `on` (default) or `off`; `doctor`, `plugin status`, and the `plugin update` no-op skip the latest-release lookup when off. |

`AGENT_GUARD_HOME`, `AGENT_GUARD_BIN`, `AGENT_GUARD_HOOK_HOST`,
`AGENT_GUARD_RUNDIR`, `AGENT_GUARD_SESSION_ID`, `AGENT_GUARD_SHELL_INIT_VERSION`,
and `AGENT_GUARD_WARNING_DIR` are runtime/integration controls. Do not set them
in ordinary policy configuration unless a documented host integration requires
them.

## Policy files and shell integration

The bundled deny-read-paths, deny-Bash-patterns, and gitleaks files define the
default policy. Do not loosen them only to silence a false positive; first
confirm whether the operation is actually benign and use a structurally clear
alternative where possible.

`setup-shell` installs an explicit shell-rc block. It offers command wrapping
and a non-blocking nudge for common credential-dump commands. The wrapping is
text-only and intentionally does not turn a shell integration into a complete
security boundary.
