# Configuration

Agent Guard reads policy from its bundled configuration and selected environment
variables. Keep custom policy files reviewable and test them with
`agent-guard smoke-test` plus an appropriate live probe.

Read [Output masking coverage](integrations.md#output-masking-coverage) for
what `AGENT_GUARD_INFRA_FAILURE_MODE=closed` and output redaction reach per
event. In particular, exit status 2 from `PostToolUse` cannot undo a tool effect
that already happened, and a `closed` decision that misses the host timeout
never reaches the host. A Claude `PreToolUse` hook that times out or crashes
blocks the tool call in either mode (Claude Code 2.1.295 and later).

## Infrastructure policy

`AGENT_GUARD_INFRA_FAILURE_MODE` controls an unavailable dependency, policy, or
scanner error in a lifecycle hook:

| Value | Behavior |
| --- | --- |
| unset (default) | `closed` for a secret scan that did not run, `open` for every other infrastructure failure |
| `open` | Continue with a degraded-protection notice that names what is missing and repeats every 10 minutes |
| `closed` | Refuse the hook action with exit status 2. A Claude `PostToolUse` hook also withholds the output it could not check |

A secret scan that did not run means text nobody checked would cross the
agent's boundary, and text the agent has read cannot be taken back. That
covers:

- a hook that could not start its checks: gitleaks missing, older than the
  supported version, failing, or not answering its version check in time (see
  the retry and the readiness cache below), or jq, awk or a policy file
  missing, since then no check runs at all;
- a hook whose plugin binary cannot be found, is not executable, or ends with
  a status other than 0 or 2 before it finishes, for the hooks that carry text
  (PreToolUse, the prompt, PostToolUse and PostToolUseFailure). The hook
  launcher decides this without the binary, so it cannot withhold the output
  of a tool that already ran (see [integrations](integrations.md));
- the text that crosses the boundary in this event, which is PreToolUse tool
  input, the prompt and PostToolUse output: a scan of it that started and
  errored, or input over a scan cap, such as a prompt too large for the
  assignment check;
- the `git commit` and `git push` gate when gitleaks itself fails on the
  staged change. A push cannot be taken back, and the gate may be the only
  check before it.

Each default block names what failed and the fix: `agent-guard doctor` to see
the failure, `agent-guard setup` (which prints the `setup --install` command)
or the setup skill to install or repair gitleaks, a retry for a version check
that only timed out, or a smaller input for a scan cap. The block does not
name the setting that would let the call through, because the model reads it.

Every other infrastructure failure keeps the open default:

- the commit gate when the directory or arguments cannot be resolved, the
  directory is not a repository, or the staged change is over the scan cap;
- the disk backstops after a tool call and at Stop: changed files or a
  written file that could not be scanned, a written path that could not be
  determined, or git itself missing. Withholding the tool output would do
  nothing for a file already on disk, and a change over the scan cap would
  otherwise block every call in that work tree until it is split;
- a Bash file operand or `<` input of a reading program (`cat`, `head`,
  `sed`, `base64` and the like) that is built from a command substitution or
  a variable the protected-path check cannot resolve
  (`reason=bash_protected_path_unresolved_operand`). The open default runs the
  command with a notice that says to name the file literally; `closed`
  blocks it. An operand the check resolves, such as a literal assignment
  earlier in the same command or a `for` loop over literal words, is matched
  against the deny list and blocks in every mode when it names a protected
  file.

Set `closed` to block those too.

Under `open`, a session's first infrastructure failure produces the notice, and
it repeats at most once every 600 seconds while failures continue; the interval
is fixed. Every infrastructure notice in a session shares that interval, so a
degraded-dependency notice can wait behind another failure's notice, such as an
unresolved `git commit`. The unresolved read operand notice keeps its own
interval, so it never hides another notice; it is added to a notice published
in the same call. A `PostToolUse` git-backstop failure is reported on
stderr only, because that hook may still have to write its redaction response. In Claude Code the notice is a `systemMessage` shown to you on
`PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `UserPromptSubmit`, and
`Stop`, and the model receives it as additional context. Codex receives it as
additional context, and on `Stop` only on stderr; whether Codex shows a
`systemMessage` from those events has not been verified, so none is sent there.
`SessionStart` reports degraded setup to both hosts on every start.

This is distinct from a secret finding, which blocks. An invalid value is read
as unset; set an explicit valid value in managed environments.

When jq, awk and both path and pattern policy files are ready but gitleaks or
its config is not, `open` still runs every PreToolUse check that needs no
scanner: the protected-path checks on Read, Grep, Glob, Bash and network tool
input, the Bash deny patterns, the `git commit`/`git push` hook-bypass refusal,
the broad Grep content refusal and the PII input gate. Only the secret scan is
skipped, so a secret that only gitleaks would find passes. The first notice of
the session that a passing call carries includes the degraded notice; a
blocked call carries only its block reason. `closed`, and the default, block
every PreToolUse call.

UserPromptSubmit needs only jq and awk for its PII input gate and its check for
secret-like `KEY=value` and `key: value` assignments, so under `open` both
still run when gitleaks is unavailable and a prompt they find is blocked. Only
the gitleaks rule scan is skipped: a secret that only gitleaks would find
passes, and stderr says on every such pass that the scan did not run, while the
notice keeps its interval. `closed`, and the default, block every prompt.
PostToolUse, PostToolUseFailure and Stop pass without running their checks
under `open` when gitleaks is unavailable. By default PostToolUse and Stop
block then, and PostToolUseFailure, which cannot block, reports the unchecked
failure on every call.

Every hook except SessionStart retries a gitleaks version probe that timed out
once before it treats gitleaks as unavailable, because a loaded machine can
miss the two-second deadline once. SessionStart probes once: its host timeout
is five seconds.

A probe that timed out does not make gitleaks unavailable when the readiness
cache still holds a verdict for the same gitleaks file that expired less than
ten minutes ago. A stalled machine holds the retry as long as it held the first
probe, so the hook takes the version from that verdict and scans without
probing again: the scan is then the proof that gitleaks runs, and a scan that
fails is reported as a failed scan. A probe that ran and failed is never
replaced this way. The cache lives in the private state directory, so with
`AGENT_GUARD_LOG_MODE=off` and no `AGENT_GUARD_SCAN_CACHE=on`, and for a
gitleaks that is a script or a version-manager shim, only the retry applies.

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
  default is masking. With `AGENT_GUARD_DENY_READ_MODE=mask` it also masks the
  values of the project's root dotenv files; see
  [Known dotenv values in output](#known-dotenv-values-in-output). It also
  turns off the Claude `PostToolUseFailure` check, which reports secret-like
  values in a failed tool's output but cannot mask them
  ([Integrations](integrations.md#output-masking-coverage)).
- A credential-like key name alone does not mask a value. The assignment
  heuristic (`password=...`, `token: ...`) still masks a quoted string and a
  bare value, whatever its entropy: `password=hunter2`, `password: admin`, a
  connection string segment. A diff marker in front of the key changes nothing:
  an added line (`+API_KEY=<value>`) is read as the line itself is. It leaves a
  value that is an identifier repeating
  the field name in a line of source code, because that names the field
  again and is not a credential:

  | Left readable | Still masked |
  | --- | --- |
  | `credential: Credential;`, `credential: Credential \| null;` | `credential: Credential` (nothing after it, as in YAML), `credential: Credential \| hunter2` |
  | `credential: CredentialSchema,`, `password: hashedPassword,` | `credential: mycredential,`, `password: SummerRain,`, `password: hashedPassword1,` |
  | `credential: input.credential,` | `credential: input.credential, port: 3306`, `password: winter.coldPassword,` |
  | `credential=credential,`, `api_key=self.api_key,` | `credential=myCredential,`, `api_key=other_key,` |
  | `self.credential = credential`, `this.credential = credential;` | `password = password`, `this.credential = "..."` |
  | `password: userPassword;` at the start of a line | `Server=db;Password=userPassword;`, `user: bob \| password: MyPassword \| host: db` |
  | `src/schema.ts:14:  credential: CredentialSchema,` (`grep -n` output), `src/schema.ts:  credential: CredentialSchema,` (`rg --no-heading` output) | `schema:  credential: CredentialSchema,` (a word, not a file path), `12:34: password: Password,` |
  | `password: HTTPSProxyPassword,`, `password: DATABASE_PASSWORD,` | `password: MyPassword,`, `secret: SecretQzxvWplm,`, `token: Promise<XkqWzp>;` (a word outside the list) |

  All of these must hold:
  - The field starts its line: only indentation, one diff marker (`+`, `-`)
    and declaration keywords such as `const` or `export` come before it. A
    field whose `:` or `=` ends more than 1024 bytes into its line is never
    one that starts it. The
    key itself may carry `-`, `.`, `$` or quotes, so `--password=...`,
    `spring.datasource.password=...` and `"password": ...` at the start of a
    line count as well. A line locator may come before all of that, as
    `grep -n`, `rg`, `git grep -n`, `cat -n` and `nl` print one:
    `src/schema.ts:14:`, `14:`, the context forms `src/schema.ts-14-` and
    `14-`, a padded number and a tab, or a number and the arrow the Read
    tool prints (`14→`). A path with no line number counts too
    (`src/schema.ts:`, as `rg --no-heading` prints it) when it holds a `/`
    or a dot and an extension that starts with a letter. The locator must
    start the line, with the same separator on both sides of the number. Its
    path part is made of letters, digits and `_ . / @ + ~ -` with at least
    one letter, and does not start with `+` or `-`.
    A bare word (`schema:`, `note:`), a clock time (`12:34:`), a date (`2024-01-15:`),
    an address and port (`10.0.0.1:5432:`), a host or pod name
    (`web-1:`), a line and column pair (`src/a.ts:14:9:`), a diff marker
    glued to the path (`+src/schema.ts:14:`) and the tail of other text
    (`Server=db;Database=app:1:`, `level=info|req=42:7:`) do not count.
  - The whole unquoted value is an identifier or a dotted chain of at most 80
    bytes with no digit; one leading `$` and one simple generic argument
    after a capitalized name (`Promise<Token>`) are allowed. A dotted chain starts at a common object
    name (`input`, `config`, `self`, `this`, ...).
  - Every word of the value is a word of the field name (`api` and `key`
    for `api_key`; its plural or singular too) or a word from a closed list
    of identifier words (`schema`, `input`, `hashed`, `user`, `promise`,
    `null`, ...), which includes the common object names a dotted chain may
    start at (`settings`, `conf`, `process`, ...). Words end at `_`, `.`, `$`, `<` and `>`, where a capital
    follows a small letter, and where an acronym ends (`HTTPCredential`).
    Any other word keeps the value masked, so random letters cannot pass by
    carrying the key word (`secret: SecretQzxvWplm,`), and neither can a
    password built around it (`password: MyPassword,`). Each operand after
    an operator is a keyword or builtin type (`null`, `undefined`, `None`,
    `string`, ...) or names the field itself with listed words
    (`?? credentialOverride,`); `password: Password ?? admin,` stays masked.
  - A `,` or `;` ends the line. After a colon field the value may first
    continue with `|`, `||`, `??`, `&&` or `=`, each followed by one more
    digit-free identifier (`Credential | null;`). A `self.` or `this.` member
    assigned with `=` may also end the line with nothing.
  - The value names the field, compared without case, digits and separators.
    After `=` the last segment of the value must be the field name. After a
    colon it is enough that both contain the same credential word when the
    value is also written as an identifier: a capital, an underscore or a
    dot past its first character.

  What this cannot tell apart, and so leaves readable: at the start of a line
  and before a line-ending `,` or `;`, a digit-free password that is its own
  key name in lower case, capitalized or all capitals (`PASSWORD=password;`,
  `password: Password,`; mixed case such as `PASSWORD=PaSsWoRd;` splits into
  other words and stays masked), or one made only of words of the field name
  and listed words (`password: userPassword,`, `password: defaultPassword;`),
  each with or without a leading `$` or a generic argument after a
  capitalized name. Lines that are not source code have this shape too when
  the key starts the line: `--password=password;`,
  `spring.datasource.password=password;`, `"password": Password,` and a YAML
  list item `- password: Password,` (read as a diff marker). A log line that
  opens like a locator has it as well (`db-host:22: password: Password,`,
  `2024-01-15T12:34: password: Password,`, and `web-1- password: Password,`,
  which reads as a context line of a file named `web`). The same goes for a value equal
  to its key name under a `self.` or `this.` key with nothing after it
  (`self.password = password`). In the other direction, an identifier with a
  word outside the list stays masked as before (`password: legacyPassword,`).
  gitleaks findings are masked regardless.
  `AGENT_GUARD_KEY_NAME_REDACT=on` turns this exemption off, so the left-hand
  column is masked again as it was before; any value other than unset, empty
  or `off` counts as `on` (including `0` and `false`). The prompt guard uses
  the same detector, so the same lines pass or block there.
- A tool result too large to scan is masked fail-closed: every nonempty string
  in it is replaced. Anthropic content-block discriminators (`type`,
  `source.type`, `media_type`) and the fields Claude Code checks in built-in
  tool output (`Read`'s `type` and page `mediaType`, `Write`'s `type`,
  `Grep`'s `mode`, `NotebookEdit`'s `cell_type`) survive that rewrite when
  the value is exactly a known protocol token, so the sanitized result still
  parses as the shape the host sent. Claude Code's other enum fields survive
  only at the top-level path the output schema gives them and only with a
  value that schema allows: `stoppedBy` and `neverRan` (`REPL`), `status`
  (`Skill`), `gitDiff.status` (`Write`, `Edit`), `provenance[].authority`
  (`Poll`), and `gitOperation.*.kind` and `.action` (`Bash`). The same
  key anywhere else, such as inside the value a Code Mode script returns, is
  ordinary data. Any other string is masked, including under those keys. On Claude Code, a `filePath` or `notebook_path` equal to
  the path in the tool input is kept too: the model wrote it. When a rewrite
  still changes a field the host checks, the hook does not report the output
  as masked, because Claude Code rejects such a replacement and passes the
  original output on unchanged. A
  portable secondary serializer preserves object keys, order, containers, and
  scalar types if the primary JSON rewrite cannot run; it neutralizes numeric
  and true-valued leaves while producing one host-valid replacement. This
  replacement is required because PostToolUse runs after the tool and exit
  status alone cannot retract the original result.
- Base64 image and PDF blocks (`media_type` of `image/png`, `image/jpeg`,
  `image/gif`, `image/webp` or `application/pdf`, in the Anthropic `source`
  shape, MCP's native `data`/`mimeType` shape, Claude Code's `Read` `file`
  shape or its PDF page images, `base64` with `mediaType`) are not inspected: the scanner cannot read pixels. Their payload is
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
- Claude Code also submits messages nobody typed through the same hook: a
  background task notification, a subagent hand-back, or another session's
  message. These are blocked like any other prompt. The block message names the
  message kind and detector (never the value), and the next prompt that passes
  carries a note telling the model what was blocked and how to recover it, for
  example by reading the task output file, where output masking applies. The
  hook input has no origin field, so the kind is read from the message frame
  and only changes the wording, never the verdict.
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
  `cat <path>`". On Codex, which reads files through shell commands, the
  line is "for a masked view, read the protected file alone with
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

### Known dotenv values in output

A secret under a generic key name with no vendor prefix (`APP_SEED=...`) has
nothing that marks it as a secret, so the output detectors alone let it
through. In `mask` mode, output masking also replaces every exact occurrence of
a value from the project's root dotenv files with `[REDACTED]`, wherever it
appears: after its own key, bare in a log line, inside an argv list, or as a
URL password. Agent Guard's own process reads the files; the model never sees
them.

```text
$ printf 'worker started, seed %s\n' "$APP_SEED" | agent-guard exec -- cat
worker started, seed [REDACTED]
```

- It runs only with `AGENT_GUARD_DENY_READ_MODE=mask`, the mode in which you
  already let Agent Guard read protected files. In `block` (the default) and
  with any invalid mode value, Agent Guard never opens a dotenv file for
  output masking, and such a value stays unmasked.
- `AGENT_GUARD_KNOWN_VALUE_REDACT=off` turns it off in `mask` mode.
  `AGENT_GUARD_OUTPUT_REDACT=off` turns it off with the rest of output masking.
- It applies wherever the shared output masking runs: Claude and Codex
  `PostToolUse` and `agent-guard exec` / `agx`.
- Files: only those directly in the project directory (the event's `cwd`; for
  `exec`, its working directory) and in that directory's Git top level. No
  subdirectory is searched. A file counts only when its name is on the
  deny-read list and mask-file reads it as dotenv (the dotenv row of the table
  above), so templates such as `.env.example`, `.env.sample` and
  `.env.template`, and `.envrc`, are skipped. Symlinks are skipped.
- Values: the dotenv subset above. Quotes are removed, an unquoted value ends
  before a ` #` comment, and a trailing CR is dropped. Values shorter than 8
  bytes, `true`/`false`/`yes`/`no`/`on`/`off` in any case, numbers, empty
  values, and values that mix fewer than two of letters, digits and other
  characters (a plain word such as `development` or `localhost`) are not used.
  So a long secret made only of letters is not a known value. Matching is exact and literal: no regex, no encoded
  variants (base64, URL encoding, a changed case).
- A file that cannot be read or is outside the dotenv subset, or is over
  64 KiB, contributes no values. One line outside the subset (a `${VAR}`
  reference, a backtick, a value over several lines) is enough: that whole
  file then contributes no values, even from its other lines. This is not an infrastructure failure: masking by
  every other rule continues as before and no warning names the file. If the
  value matcher itself fails, the output is masked conservatively, as for any
  other detector failure.
- Values are held in memory for one hook or `exec` run only. They are never
  written to the audit log, a cache, a warning or an error message.
- A value that passes these filters is masked everywhere it appears in
  output, even where it is not used as a secret (for example a host name such
  as `db.example.com`).

A secret that is not in a root dotenv file (another file, the process
environment, a nested `.env`, a secret manager) is still not covered. Neither
is one in `block` mode.

### Deny-value rules

Text that must never show, such as your organization's token format, can be
added as rules. In `mask` mode every match is replaced with `[MASKED]`, in
comments too. Rules are read from both of these, together:

- `$HOME/.config/agent-guard/mask-deny-values.txt`
- the file named by `AGENT_GUARD_MASK_DENY_VALUES`

Neither replaces the other, so a repository that sets the variable to an empty
file still gets your rules. A missing user file means no rules from it.

Each line is one POSIX extended regular expression, matched by `awk` in the C
locale; lines whose first non-blank character is `#` and blank lines are
skipped (write `[#]` for a rule that starts with `#`). Interval support
(`{n,m}`) follows the system `awk`.

```text
# organization tokens
ORGTOK-[0-9a-f]{24}
```

The read stays blocked with no view when:

- a rule file that exists, or the file the variable names, cannot be read;
- any rule is refused: more than 64 rules across both files, a rule over 256
  bytes, a back-reference (`\1` to `\9`), a repetition of something that
  already repeats (`(a+)+`, `(.*)*`, `a**`), a repeated group that contains
  `|` (`(a|aa)*`), a repetition count over 255, an invalid expression, or a
  rule that matches empty text;
- a rule matches on a line that is not a comment, outside the `[MASKED]`
  values: in a key, a section name or other structure. Rewriting that text
  would change the key, so the view is refused instead;
- `awk` takes more than 2 seconds to check the rules or 2 seconds to apply
  them, which stops shapes that only some `awk` builds take exponential time
  on (`mawk` with a long run of `a?`).

The reason names the file (`mask-deny-values.txt` or
`AGENT_GUARD_MASK_DENY_VALUES`), the line and why, never the rule text:

```text
agent-guard: no masked view: mask-deny-values.txt line 4: the rule uses a back-reference
```

Rules apply before the 6,144-byte limit and the rescan, so both see the view
that is returned; a view over the limit is refused before the rules run.
`block` mode never reads the rules. The allow list below never overrides
them: text a deny-value rule matches stays masked.

### Values to show (allow list)

Values that are not secret, such as `LOG_LEVEL` or a port, can be shown in the
view. Each line of `$HOME/.config/agent-guard/mask-allow-keys.txt` is one
POSIX extended regular expression matched against key paths, with the same
`#` and blank-line rules as above. A value is shown when a rule matches its
whole key path; every other value stays `[MASKED]`.

```text
# values safe to show
^LOG_LEVEL$
^server\.port$
```

Key paths are the ones `mask-file --key-paths` prints: `KEY` for dotenv,
`section.key` for ini (`key` outside a section), and keys joined by `.` with
array indexes as numbers for json and yaml (`server.port`, `hosts.1`).

A `.` inside a key reads the same as the `.` between keys: `{"a.b": 1}` and
`{"a": {"b": 1}}` both have the key path `a.b`. So a value is never shown when
a key on its path contains `.`, is empty, or is a json or yaml key made only of
digits (it reads like an array index). Such a value stays masked whatever the
rules say.

This list widens what an agent sees, so where it comes from is checked:

- It is read only from that one file. `XDG_CONFIG_HOME` and every other
  variable are ignored, and there is no variable that names another file: a
  host's project settings, which a repository can commit, can set the
  variables the hook runs with, and the hook cannot tell who set them.
- The file is used only when its resolved path is inside no git work tree
  (no directory above it holds a `.git`), outside the hook's working
  directory (or the current directory when the host sends none) and that
  directory's work tree, and when the file and its directory belong to the
  current user and neither is writable by group or others. Every directory
  above them must belong to the current user or root, and one that group or
  others can write must be sticky (as `/tmp` is), so no other user can swap
  the file after the check. An access control list that may let others in
  also refuses the file: on macOS any `allow` entry on the file or a directory
  above it (the `deny` entries a home directory carries are fine), elsewhere
  any POSIX ACL. A symlink is
  followed before the check, so a file kept in a dotfiles repository and
  linked into `~/.config` is not used. When git fails in a working directory
  that has a `.git` above it, the file is not used. The first check does not
  depend on the working directory, which the agent chooses: a `HOME` moved
  into a repository is refused from anywhere. A `HOME` moved into a directory
  that is not a git work tree is caught only from inside that directory; a
  setting that can change the hook's environment can already point
  `AGENT_GUARD_DENY_READ_PATHS` at an empty file, so keep host settings you
  did not write out of the hook's environment either way.

The view with every value masked is used instead, with a warning, when:

- the file does not pass the checks above, or cannot be read;
- any rule is refused for the reasons deny-value rules are refused, or does
  not start with `^` and end with an unescaped `$`, or matches the fixed probe
  key `AGENT_GUARD_PROBE_KEY_7F3A` (as `^.+$` or `^[A-Z0-9_]+$` do), or
  matches empty text (as `.*`, `^.*$` and `^` do);
- `awk` takes more than 2 seconds to check or apply the rules.

Unlike deny-value rules, none of these blocks the read: the list is dropped
and every value stays masked. The warning names the line and why, never the
rule text or a value:

```text
agent-guard: mask-allow-keys.txt line 2: the rule matches empty text; every value stays masked
```

Deny-value rules and the secret scanner win over the list. A shown value that
a deny-value rule matches (on its line) stays masked. The view with shown
values is scanned first; if the scan finds something or cannot run, or that
view is over 6,144 bytes, the view with every value masked is scanned instead,
and a finding there blocks as before. The view is never scanned more than
twice. A missing file means no list and no warning, and `block` mode never
reads it.

## Containers other sessions own

A review session often runs next to sessions that own local container stacks,
such as a demo database. Agent Guard keeps a review session out of them. The
check applies to a Bash command only in:

- a session started with `AGENT_GUARD_SESSION_ROLE=review` in its environment;
- a Claude Code agent whose `agent_type` contains `review` (a reviewer
  subagent, or `claude --agent` with such a name).

Any other session is not affected. A session that is only told to review in
its prompt carries neither marker; start it with
`AGENT_GUARD_SESSION_ROLE=review`. Nothing marks a Codex session by itself:
restrict what Codex may run with Codex's own command rules.

In those sessions a `docker`, `podman` or `nerdctl` command, their compose
forms included, is refused when:

- it names a stack listed in
  `$HOME/.config/agent-guard/protected-containers.txt`
  (`reason=bash_container_protected_stack`). Each line of the file is one
  literal name, such as a container name prefix or a compose project; blank
  lines and lines starting with `#` are ignored. A name counts when it appears
  in the command, in the directory the command runs in, or in the session's
  `COMPOSE_PROJECT_NAME`, and for any subcommand, not only `exec`. A missing
  file lists nothing. A file that exists but cannot be read refuses every
  container runtime command of these sessions
  (`reason=bash_container_policy_unreadable`).
- a container `exec` comes with a database client (`psql`, `pg_dump`,
  `mysql`, `mysqldump`, `mongosh`, `mongo`, `redis-cli`, `sqlite3`,
  `clickhouse-client` and their siblings), for any container
  (`reason=bash_container_db_client`).
- a container `exec` line holds a variable or a command substitution, or its
  target outside compose is made only of hexadecimal digits and so can be a
  container ID, so the stack it reaches cannot be read from the command
  (`reason=bash_container_unresolved_target`).

A quoted word that `grep`, `rg` or `git grep` only reads is not a command, so
searching for such text stays possible.

```text
# $HOME/.config/agent-guard/protected-containers.txt
# the demo stack
demo-stack-20260101
```

This holds a command that is written out in the Bash call: the runtime, its
options, and `exec` with the container and what it runs. The check reads that
text only. It does not ask the container runtime which containers exist, and
it does not follow a command into a script, another program, or a name the
shell works out when the command runs. Quoting and shell syntax around the
runtime's own words are read through in their common forms, not in every form
a shell accepts. It guards ordinary use and is not a sandbox: a session that must not reach a stack should also be kept away from
that stack's network and credentials. A restricted session is read
conservatively, so some harmless commands are refused as well, such as any
variable on a container `exec` line or a database client named anywhere in a
call that has a container `exec`.

## Environment reference

| Variable | Default / use |
| --- | --- |
| `AGENT_GUARD_DENY_READ_PATHS` | Override the deny-read policy file. |
| `AGENT_GUARD_DENY_READ_MODE` | `block` (default) or `mask`; `mask` adds a masked view to the reason of a blocked `Read` or `cat` of a protected file. |
| `AGENT_GUARD_TRACKED_FILE_EXCEPTION` | `on` (default) or `off`. `on` lets a file committed to the current repository be read even when its name is on the deny-read list ([Committed files](#committed-files)). Any other value, an empty one included, counts as `off`. |
| `AGENT_GUARD_MASK_DENY_VALUES` | A file of extra deny-value rules for `mask` mode, used together with `$HOME/.config/agent-guard/mask-deny-values.txt`. |
| `AGENT_GUARD_DENY_BASH_PATTERNS` | Override the risky-shell-command policy file. |
| `AGENT_GUARD_GITLEAKS_CONFIG` | Override the gitleaks configuration file. |
| `AGENT_GUARD_GITLEAKS_BIN` | Select a gitleaks executable. |
| `AGENT_GUARD_GITLEAKS_BIN_DIR` | Select the private gitleaks install directory (default `~/.agent-guard/bin`), where `setup --install` puts gitleaks. `AGENT_GUARD_BIN_DIR` is deprecated here: it is the installer's link directory, and the CLI still uses it as the gitleaks directory, with a notice, only while this variable is unset and a gitleaks or warm helper is already in it. A later release stops reading it ([CHANGELOG](https://github.com/JeongJaeSoon/agent-guard/blob/main/CHANGELOG.md)). |
| `AGENT_GUARD_GITLEAKS_HELPER` | Unset (default): use the [warm gitleaks helper](https://github.com/JeongJaeSoon/agent-guard/blob/main/docs/gitleaks-helper.md) when `agent-guard setup --install` or `agent-guard setup --install-gitleaks-helper` installed it. `off` (any value that is not an absolute path) never uses it, and `setup --install` run with the variable set does not install it. An absolute path selects your own built `agent-guard-scan`. Ignored when `AGENT_GUARD_GITLEAKS_BIN` is set or `AGENT_GUARD_LOG_MODE=off`. A helper failure runs the real gitleaks. |
| `AGENT_GUARD_GITLEAKS_HELPER_IDLE_SECONDS` / `AGENT_GUARD_GITLEAKS_HELPER_MAX_RSS_MIB` | Read when a warm helper starts: idle exit time (default `600`) and peak resident-memory cap (default `160` MiB, at least `96`). |
| `AGENT_GUARD_INFRA_FAILURE_MODE` | `open` (default) or `closed` for hook infrastructure failures. |
| `AGENT_GUARD_SCAN_INPUT_MAX_BYTES` | Positive integer `>= 10485760`; default `10485760` (10 MiB, split into thirds per producer, so `scan-staged` and each `scan-working-tree` component get 3495253 bytes by default). It can only raise the budget: smaller, non-numeric, or overlong (19+ digit) values keep the default. A larger budget scans more input; it never excludes anything from scanning. |
| `AGENT_GUARD_OUTPUT_REDACT` | Output secret masking; set `off` only with deliberate acceptance of the reduced protection. |
| `AGENT_GUARD_KEY_NAME_REDACT` | `off` (default) or `on`. `on` also masks, and blocks in a prompt, an identifier that repeats a credential-like field name (`credential: CredentialSchema,`); see [Output and prompt handling](#output-and-prompt-handling). Any value other than unset, empty or `off` counts as `on`. |
| `AGENT_GUARD_KNOWN_VALUE_REDACT` | `on` (default) or `off`. Only with `AGENT_GUARD_DENY_READ_MODE=mask`: output masking also masks the values of the project's root dotenv files ([Known dotenv values in output](#known-dotenv-values-in-output)). `off` skips it. |
| `AGENT_GUARD_PROMPT_GUARD_MODE` | `block` (default), `warn`, `off`, or the currently blocking `mask` fallback. |
| `AGENT_GUARD_PII_HOOK_MODE` | `off` (default), `block`, or `mask`. |
| `AGENT_GUARD_PII_PROVIDER` | `regex` (default), `http`, or `pleno`. |
| `AGENT_GUARD_PII_REDACT_URL` | Required user-controlled endpoint for the remote PII providers. |
| `AGENT_GUARD_PII_SKIP` | Local-regex opt-out for `EMAIL`, `PHONE`, and `IP_ADDRESS` only. |
| `AGENT_GUARD_PII_LANGUAGE` / `AGENT_GUARD_PII_TIMEOUT_SECONDS` | Provider language and positive timeout control. |
| `AGENT_GUARD_COMMAND_WRAPPING` | `off` disables shell command wrapping for the current process. For `agent-guard update` and the bootstrap installer, `on` or `off` overrides the choice recorded in the shell rc. |
| `AGENT_GUARD_LOG_MODE` | The metadata log is on by default; set `off` to opt out. `off` also turns off the local caches in the private state directory (the gitleaks readiness cache, the clean-scan cache below, and the shared protected-path regex cache, which is then rebuilt in every invocation) unless `AGENT_GUARD_SCAN_CACHE=on` is set explicitly. Without them every hook runs the gitleaks readiness check and scans a repeated Bash command again, usually one or two more gitleaks runs per hook. With `AGENT_GUARD_LOG_MODE=off` and `AGENT_GUARD_SCAN_CACHE=on`, the caches are written and no event record is. See [PRIVACY.md](../PRIVACY.md) for what each cache file holds. |
| `AGENT_GUARD_SCAN_CACHE` | `on` (default) or `off`; with `AGENT_GUARD_LOG_MODE=off` the default is off and only an explicit `on` enables it. When on, the PreToolUse Bash command-text scan (the one that repeats, such as `ls -la` or `git status`) skips gitleaks only for a command that was already scanned clean within the last 10 minutes under the same gitleaks executable (a native binary, not a script shim), configuration file contents, `GITLEAKS_CONFIG`/`GITLEAKS_CONFIG_TOML`, scan flags, and agent-guard version. Prompts, file edits, patches, MCP and network input, and `scan-staged`/`scan-working-tree` are always scanned directly. Entries are SHA-256 hashes in the private state directory, at most 256 of them; the scanned text is never stored. Findings, scanner errors, and scans that could not run are never cached. A `.gitleaksignore` in the scan directory, a configuration that names `extend` anywhere except a plain `[extend]` table holding only `useDefault` and a one-line `disabledRules` with no multiline string before or inside it, a configuration with a double-quoted key or table name, `AGENT_GUARD_LOG_MODE=off` without an explicit `AGENT_GUARD_SCAN_CACHE=on`, no root-owned, non-writable `/usr/bin/sha256sum`, `/bin/sha256sum`, or `/usr/bin/shasum` (the hash tool is never taken from `PATH`) or one that fails a known-answer check, and any value other than `on` disable it. With logging on, `off` disables only this cache. With `AGENT_GUARD_LOG_MODE=off`, only an explicit `on` prepares the private state directory, under the same ownership, mode, and symlink checks, and enables this cache together with the readiness and protected-path regex caches; no event record is written. An `AGENT_GUARD_LOG_MODE` value other than `on` or `off` leaves all three caches off whatever this variable says. |
| `AGENT_GUARD_RELEASE_CHECK` | `on` (default) or `off`; `doctor`, `plugin status`, and the `plugin update` no-op skip the latest-release lookup when off. |
| `AGENT_GUARD_CODEX_TRUST_CHECK` | `on` (default) or `off`; when off, `doctor` and the Codex `plugin status`/`install`/`update` output skip the `codex app-server` hook-trust query and report it as unverified. |
| `AGENT_GUARD_SESSION_ROLE` | Set to `review` in the environment of a review session to hold it to the container boundary ([Containers other sessions own](#containers-other-sessions-own)). Unset or any other value: no effect. |

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

### Committed files

A deny-read entry without a `/` (`*.env`, `secrets.yaml`, `*.key`) protects a
file by its name alone. A file that is committed to the repository an agent is
working in is already part of what that agent may read, so by default such an
entry does not block it. The exception applies only when all of these hold:

- the path is a regular file, not a symlink, written without a symlinked
  directory, `.` or `..` part, and inside the work tree of the repository
  that holds the event working directory;
- `git ls-files` reports it as tracked, and the file on disk is byte for byte
  the blob committed at `HEAD` under that path. A file that is untracked
  (ignored or not), only staged, or changed since the last commit stays blocked, so a
  file committed with placeholder values and filled in locally is not opened;
- no deny-read entry that names a directory matches it (`.aws/credentials`,
  `.ssh/id_*` and similar stay blocked wherever they are, tracked or not);
- for a shell command, the word is a literal operand of `cat`, `head`,
  `tail`, `wc`, `cut`, `nl`, `tac`, `sort`, `stat`, `file`, `grep`, `egrep` or
  `fgrep`: commands that open each file they are given, for reading, and no
  other file because of it. Every word of that command must
  be literal, with no redirection and no `&`, the whole line must hold no
  `$` expansion, and anything its output is piped to must be a plain text
  filter (`head`, `grep`, `sort`, `wc` and the like, without long options); its options must be plain flags
  from a short built-in table (`grep -r`, `grep -f`, `grep --include`,
  `sort -o`, `sort --files0-from`, `tail -f` and any long option keep the
  block); and the command must be the first on the
  line, or come right after one leading `cd ./DIR` or `cd /ABS/DIR` with a
  single operand and no `..` (a bare `cd DIR` can land elsewhere through
  `CDPATH`, so it keeps the block, as does a loop, a condition or any other
  command before the read). Any other command
  keeps the block: `git` (its operands also select revisions, the index and
  wildcard pathspecs), `diff` and `comm` (a directory operand makes them open
  a same-named file there), `uniq` (its second operand is written), `sed`
  and `jq` (their script word is program text that can name another file), a
  pager,
  a test runner, `ssh`, `docker exec`, `find`, `sudo`, an inline script. The
  `Read`, `NotebookRead` and `Grep` tools get the same exception for their
  own path field (`file_path`, `notebook_path`, `path`) only; a Grep `glob`
  stays checked by name, and so does a tool path with a `..` part, a
  `file://` prefix, a leading `~`, a blank or any character outside
  `A-Za-z0-9_./@%+,=-`.
- the directory relative paths are placed in is the event's own absolute
  `cwd`. A `workdir` or `cwd` inside `tool_input` counts only when the event
  has no `cwd` (the Codex shell shape) or names the same directory; for a
  shell command it must also be the directory the check itself runs in.
  Otherwise, and when the event names no directory, the block stands. On
  Codex the shell's working directory is chosen per command, so "the current
  repository" is the one that directory is in.

Git is asked only when a block is already pending, so a command that passes
costs what it did before. If git is missing or cannot answer, the block
stands.

What an agent can read this way is content the repository already holds at
`HEAD`. This adds no new way to reach a file an agent commits itself: a
command such as `git show HEAD` already prints whatever was just committed,
and the commit gate, not this exception, is what scans staged content. The
check describes the file at the moment the hook runs: a process started
earlier that replaces the file or a directory above it before the command
reads it is not seen. A tracked file inside a directory whose name matches a
name-only entry (`.env.d/notes.txt`) is opened too. A file whose working copy differs from the commit is blocked by its
name until the change is committed; the file is compared without git filters,
so a checkout that rewrites line endings or uses a clean/smudge filter keeps
the block. Set `AGENT_GUARD_TRACKED_FILE_EXCEPTION=off` to restore the
name-only block for committed files too; an empty value or anything other
than `on` does the same. With `AGENT_GUARD_DENY_READ_MODE=mask`, a file under
this exception is read as it is, not as a masked view.

`setup-shell` installs an explicit one-line shell-rc block that sources
`~/.agent-guard/shell-init.sh` (`shell-init-no-wrapping.sh` for the opt-out),
where the validating resolver lives. It offers command wrapping
and a non-blocking nudge for common credential-dump commands. The wrapping is
text-only and intentionally does not turn a shell integration into a complete
security boundary.
