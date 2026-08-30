## v3.0.1 - 2026-07-22

- fix: handle sandboxed Agent Guard setup (#141)
- docs: surface the setup skill as a Claude Code entry point (#135)
- fix(hooks): report a scan that could not run distinctly from a detection (#137)
- fix(security): close verified scan bypasses + finish v3.0.0 release (#124)

## Unreleased

- fix(redaction): mask a `KEY=value` assignment inside a quoted string leaf
  (#178). The ordinary shape of a tool that returns a serialized log —
  `{"log":"starting with API_KEY=<value>"}` — reached the model in full on the
  heuristic path. Two causes, both needed. The enclosing string's own closing
  quote rode along on the value token, and `looks_like_reference()` tests for an
  embedded quote without position, so a terminator at the very end marked the
  token a nested reference and skipped it; a single trailing quote is now
  stripped the way trailing `}`/`]`/`)` already were, and only when the
  assignment does not itself begin with a quote, so the line-start re-scan of a
  value an outer quoted assignment already claimed cannot emit a narrower
  mapping that beats it. And `:` was not accepted as the delimiter before a
  quoted key, so the JSON form never matched at all — it joins the class away
  from `[`, since `[:` opens a POSIX character class and invalidates the whole
  regex. Credential-handling source code is unchanged: `os.environ["DB_PASSWORD"]`
  and `ENV.fetch("SESSION_KEY")` keep interior quotes and stay references.
  Display redaction and the prompt guard; the block/detect path is unchanged.
  The strip stops at the redaction sentinel: `password=[REDACTED]"` would
  otherwise lose the `]` that belongs to the marker, so `[REDACTED` was
  re-emitted as a secret and a stray `]` appended — compounding on every pass
  and making the prompt guard block text Agent Guard had itself redacted.
- fix(redaction): close the status-label display-redaction leak (#156). The
  seven-word status allowlist (`error`, `warning`, `info`, `note`, `debug`,
  `fatal`, `hint`) let a secret that gitleaks does not recognise reach the model
  unmasked whenever it sat behind one of those labels — `error: password:
  <value>` and `warning: db_password: <value>` were displayed in full. The label
  cannot settle it, because it is identical in the prose chain the allowlist
  exists to protect (`error: password: authentication is disabled`), so the
  VALUE now decides: a token whose shape reads as a credential (a digit beside a
  letter, an uppercase run starting past the first character, or a single-case
  alphabetic run longer than any ordinary word) masks, while a word, path,
  number, clock time or date stays visible. The chained shape
  (`response: error: api_key: <value>`) is covered by the same gate. Display
  redaction only; the block/detect path is unchanged. An unterminated quoted
  value (truncated output) is captured and classified when the leaf ends rather
  than skipped, so a credential-shaped one still masks. A captured value is recorded in
  both its literal and its edge-trimmed form, so a bare recurrence of a
  credential that was padded or split across a newline behind its label
  masks as well. Residual: an
  all-lowercase alphabetic secret shorter than 24 characters is indistinguishable
  from a prose word on this path and stays visible.
- docs: record why the deny-read Bash gate is NOT narrowed (#99). `echo
  foo.key`, `echo see also foo.pem` and `jq -r .key data.json` are reported as
  `blocked shell command referencing a deny-listed path` although nothing is
  read and no such file exists. A command-position narrowing that dropped word
  operands of commands which take no file operands was written, measured and
  removed again: every revision of it let a real read through. A newline or `&`
  starts another command, `|` hands the dropped word to `xargs cat`, a path- or
  quote-qualified name resolves to a different program than the one compared, an
  external binary resolves through PATH at execution time so a wrapper inherits
  the exception, and an exported Bash function named `echo` or `printf` beats
  the builtin — so even a builtin name does not identify what will run. A text
  gate that cannot name the program cannot safely drop its operands. #99 stays
  open as an accepted false positive; the counter-examples are pinned as tests
  so any re-attempt has to answer them.
- fix(hooks): drop the undefined `\"` escape from the shell-parser awk bracket
  expression (#99). gawk warned `regexp escape sequence \" is not a known
  regexp operator` on every `hook-pre-tool` run, including runs that passed. The
  class already contains a literal backslash via `\\`, so it is unchanged.
- ci: remove the `codex-review` workflow. It has never produced a review in
  this repository: with no `OPENAI_API_KEY` Actions secret every step is
  skipped, the job reports success in a few seconds, and the feedback job is
  skipped for an empty message — so it read as a passing check while doing
  nothing. Codex review on pull requests comes from the ChatGPT Codex GitHub
  app and is unaffected. Dropping the workflow also stops Dependabot raising
  version bumps for an action that never runs; the README section documenting
  it is removed with it.
- feat(detection): extend the env template marker vocabulary with `tpl`/`tmpl`
  and accept `-`/`_` marker separators (`.env-example`, `.env_sample`,
  `.env.tpl`), matching the naming conventions measured on GitHub. The marker
  must still be final and the stem must stay an env family; `.env.default(s)`
  stays blocked because dotenv-defaults loads it at runtime.
- fix(detection): allow env source modules that carry exactly one intermediate
  segment between the `env`/`envrc` stem and a code extension, so ordinary
  committed files such as `env.d.ts`, `env.server.ts`, `env.config.ts`, and `env.spec.ts`
  are readable on both the Read and Bash gates. The final extension must still
  be code: data/config suffixes (`env.json`, `env.local.json`), extension-less
  names (`env.d`), the leading-dot runtime form (`.env.d.ts`), deny-listed
  ancestors, and custom deny policies all stay authoritative.
- feat(detection): block package-manager credential leak vectors. Deny-read now
  covers Bundler (`.bundle/config`), RubyGems (`.gem/credentials` and the XDG
  `gem/credentials` location), Cargo (`.cargo/credentials*`), Composer home
  `auth.json`, Maven `.m2/settings.xml`, Gradle `.gradle/gradle.properties`,
  `pip.conf`, Poetry `pypoetry/auth.toml`, and Terraform CLI credentials
  (`.terraformrc`/`terraform.rc`). Deny-bash now blocks credential dump
  commands that print stored auth with no path or token in the command text:
  `bundle config` reads (bare/`list`/`get`/legacy dotted-key read; `set` stays
  allowed and is gitleaks-scanned), `npm config get` of protected keys,
  `yarn config get` of npmAuthToken/npmAuthIdent (and the registry/scope maps
  that nest them), `git credential fill`/any-helper `get`, `pip config
  list|get`, `composer config` on credential keys or `--list`,
  `mvn help:effective-settings -DshowPasswords`, and
  `security find-(generic|internet)-password`; `gcloud auth
  print-refresh-token` joins the existing gcloud token alternation. The
  command patterns are hardened against realistic variants an agent may emit:
  tool aliases (`bundler`, `npm c`/`npm get`), version-suffixed binaries
  (`pip3.12`), leading global options between a binary and its subcommand
  (`npm --location=user config get`, `bundle config --parseable`,
  `bundle --verbose config`, `security -q`, `gcloud --quiet`), Composer's
  documented `global <command>` wrapper, which runs the same config read
  against COMPOSER_HOME where the stored OAuth token lives
  (`composer global config`), wrapper/PHAR invocation forms (`./mvnw`,
  `php composer.phar`), the direct `git-credential-<helper> get` executable,
  `pip config debug`, and `$(...)` subshell prefixes; pnpm `config list`
  (which, unlike npm, does not mask) is blocked, and coverage extends to
  pnpm/bun. The `mvn` and `composer` patterns are anchored so prose/filenames,
  value tokens like `repositories.bearer`, and the `showPasswords=false` safe
  default do not over-block. Adds deny-read for Bun's `.bunfig.toml`; uv and
  pnpm need no new path (env/.netrc and `.npmrc` respectively already cover
  them).
- feat(hooks): add a `UserPromptSubmit` prompt guard on both hosts. Secrets
  pasted into the user prompt (gitleaks rules or `KEY=value` assignment
  heuristic) are blocked before submission by default.
  `AGENT_GUARD_PROMPT_GUARD_MODE` selects `block` (default), `mask` (reserved;
  degrades to block because neither host lets a hook rewrite the submitted
  prompt), `warn` (pass through with a host-shaped visible notice), or `off`.
  The PII input gate (`AGENT_GUARD_PII_HOOK_MODE`) applies to prompts
  independently of the secret mode, and an invalid PII mode now fails loud on
  the prompt path too. `read_stdin` uses `cat` when available and prompts over
  the shared scan cap skip the super-linear assignment probe (gitleaks still
  applies; the skip follows `AGENT_GUARD_INFRA_FAILURE_MODE`), so a large
  pasted prompt cannot burn the host hook timeout into a silent fail-open.
  A prompt-path infrastructure notice is folded into the same response object
  as the mode-specific message: a hook may write only one top-level JSON
  document, and emitting the notice separately left two concatenated objects
  that a host parsing stdout as one document rejects, dropping the warning.
  The privacy policy now discloses that with the experimental
  `AGENT_GUARD_PII_PROVIDER=http` adapter in `AGENT_GUARD_PII_HOOK_MODE=block`,
  the complete text of every submitted prompt — not just tool-input text —
  is sent to `AGENT_GUARD_PII_REDACT_URL`.

- fix(detection): allow explicitly named env templates such as `sample.env`,
  `example.envrc`, `.flaskenv.example`, and `.dev.vars.example`, while blocking
  reverse/runtime forms including `local.env`, `env.local`, `env.preview`, and
  template-looking names whose final suffix is a runtime or backup marker;
  preserve custom/non-environment deny precedence and deny-listed ancestors,
  accept safely quoted Bash template paths, and keep source modules such as
  `config.env.ts` readable without opening `schema.env.json` data files.
- fix(runtime): keep plugin hooks and Claude shell integration on the
  version-independent `current/bin/agent-guard` path. Each plugin execution
  refreshes `current`, while hook and shell entrypoints fall back to the newest
  installed semantic version when symlinks are unavailable.
- test(hooks): lock in commit/push staged scans from the tool payload's target
  work directory, including linked worktrees and hook processes launched from
  a different sandbox cwd, so stale-runtime regressions cannot reintroduce the
  Codex block.
- fix(runtime): unify scanner-infrastructure failures behind
  `AGENT_GUARD_INFRA_FAILURE_MODE=open|closed` (default `open`). Hooks, `agx`,
  and transparent Claude command wrapping now warn once per session and follow
  the same selected policy; actual secret detections still always block.
- fix(detection): allow recognized checksum fields in `go.sum`,
  `package-lock.json`, `yarn.lock`, `Cargo.lock`, and `uv.lock` only when both
  the lockfile path and checksum-line shape match. Other lockfile content,
  including embedded credentials, remains scannable.
- fix(redaction): mask only the value token of a complete secret-bearing
  assignment. Metadata keys such as `password_policy`, prose such as
  `error: password: ...`, and text adjacent to a real value are preserved.
  Suffix-qualified credential keys (`AWS_SECRET_ACCESS_KEY_ID`,
  `API_KEY_VALUE`, `DB_PASSWORD_HASH`) and whitespace-prefixed colon
  assignments in log lines still mask.
- fix(pii): make the accepted PII provider values explicit (#52).

  `regex` remains the supported, local default. `http` is an experimental
  bring-your-own-endpoint adapter with no service-specific compatibility
  guarantee. Any other value fails closed instead of falling through to
  pass-through output. Existing endpoint-backed configurations that fail
  provider validation should set `AGENT_GUARD_PII_PROVIDER=http` and keep their
  existing `AGENT_GUARD_PII_REDACT_URL`. Rejected values are now reported
  exactly once.

- fix(hooks): prefix the Claude Code setup-skill invocation with a slash
  (#151). The degraded-session warning told Claude Code users to run
  `agent-guard:setup-agent-guard`; pasted verbatim that is ordinary prompt
  text, not a skill invocation. Claude Code exposes a plugin skill on the
  slash-command surface as `/plugin:skill`, which is how this plugin already
  writes its sibling skill `/agent-guard:setup-shell`. The degraded message
  and every Claude-facing doc reference now use `/agent-guard:setup-agent-guard`.
  The Codex form `$setup-agent-guard` is unchanged.

- fix(setup-shell): support a fish login shell and stop the permanent
  "command wrapping is not loaded" false positive (#139). The marker
  `AGENT_GUARD_SHELL_INIT_VERSION` only reaches `SessionStart` through the
  environment of the shell that *launched* the agent, so a fish (or other
  non-POSIX) login shell — and any GUI/IDE launcher — could never satisfy it,
  even though the agent's own bash/zsh shell snapshot did load the wrapping from
  the same rc. `SessionStart` now reads the managed rc block on disk before
  reporting missing setup, and checks that it can still *load* — the delimiters
  alone prove nothing, because the block's `eval` emits neither the wrapping nor
  the marker once the binary it resolves is gone. It replays the block's own
  resolution order (baked stable path, newest versioned plugin-cache binary,
  `agent-guard` on `$PATH`) with `stat`-level checks only: silent when setup
  demonstrably ran and still resolves (only the version-drift comparison is
  lost), the usual setup guidance when the block is absent, and a distinct
  `can no longer load` warning when the block is present but resolves nothing
  (cache updated, uninstalled, hand-edited) — that state leaves command output
  unmasked, so it must never be silent. `setup-shell` additionally writes the
  managed block to **both** `~/.bashrc` and `~/.zshrc` when either the process
  `$SHELL` or the account login shell is fish. Account lookup uses `getent
  passwd` on Linux and `dscl UserShell` on macOS, with a non-fatal process-shell
  fallback; this covers the standard skill path where Claude's Bash tool reports
  zsh even though passwd reports fish. The CLI also says plainly that no
  automatic `agx` or nudge exists at a fish prompt and prints an executable path
  for plugin-only installs where bare `agent-guard` is not on `PATH`. No
  fish-syntax marker is written or faked: claiming protection fish cannot
  provide would be worse than the warning it replaces.
- fix(hooks): report a scan that could not run distinctly from a detection
  (#137). A scanner precondition failure and a real detection previously looked
  identical — both printed and exited 2 — so an operator could not tell whether
  agent-guard had found something in their staged changes or had never managed
  to look. The message names the directory and the action instead of an internal
  subcommand; hook handling now follows the infrastructure policy above.

  CLI behaviour change: `agent-guard scan-staged` and `agent-guard
  scan-working-tree` invoked outside a git work tree now exit **3** rather than
  2. Everything in this repo treats non-zero as failure (the native pre-commit
  hook, the `make` targets, the verify command), so no consumer changes — but
  scripts that test for exactly 2 should be updated. Direct scan commands and
  native Git hooks still treat every non-zero result as uncleared.

## v3.0.0 - 2026-07-19

- feat!: simplify managed deployment to settings merge plus developer setup (#122)

Breaking changes (see the [2.x to 3.x migration guide](docs/migration-v3.md)):

- Removed the `managed-install.sh` entrypoint and the self-contained
  `managed-bootstrap.sh`, including the `managed-bootstrap.sh` /
  `managed-bootstrap.sh.sha256` release assets.
- Removed the Codex managed hook path (`deployment/codex-hook`,
  `deployment/codex-requirements.toml.template`); Codex users install the
  plugin through the standard install.
- Removed `setup-shell --prepend-path`.

## v2.2.0 - 2026-07-18

- feat: add self-contained managed bootstrap (#119)

## v2.1.0 - 2026-07-18

- feat: add managed deployment for Claude Code and Codex (#117)
- docs: pin community submission source (#116)
- docs: prepare Claude marketplace submission review (#115)
- docs: lead quick start with Claude Code and Codex (#54)
- ci: bump hashgraph-online/ai-plugin-scanner-action from 1.2.286 to 1.2.484 (#111)
- ci: bump openai/codex-action from 1.9 to 1.11 (#107)

## v2.0.1 - 2026-07-17

- fix(hooks): scan `NotebookEdit` cell content so secrets written to notebook cells are blocked (and PII when `AGENT_GUARD_PII_HOOK_MODE=block`) (#112)

## v2.0.0 - 2026-07-14

- feat(shell)!: make Claude command wrapping stable and default-on, with `--no-command-wrapping` and `AGENT_GUARD_COMMAND_WRAPPING=off` opt-outs
- feat(install): enable command wrapping from direct bootstrap and add `/agent-guard:setup-shell` for plugin installs
- docs: add the 1.x to 2.x migration guide and move GitHub Action examples to the preserved `v2` release line
- ci(release): verify publishing `v2` does not move the existing `v1` compatibility tag

## v1.10.1 - 2026-07-14

- fix(codex): verify the plugin-local binary, hook trust, and live host dispatch during guided setup
- fix(codex): use harmless dedicated sentinels for live PreToolUse and PostToolUse probes
- docs(codex): document wrapping-tool boundaries and require pre/post live probes
- fix(shell): mask bare `printenv NAME` values with their variable-name context

## v1.10.0 - 2026-07-13

- feat(codex): add guided dependency setup and host-native hook responses
- feat(shell): graduate the Claude bang-command guard to a supported opt-in

## v1.9.0 - 2026-07-07

- feat(plugin): warn on version drift between plugin hooks and the shell-integration CLI (#104)
- feat(bench): per-channel leak-prevention benchmark (#90)

## v1.8.0 - 2026-07-06

- feat(detection): catch low-entropy vendor-prefixed tokens by shape alone (#101)
- feat(detection): allow dotenv-style template files via suffix rule (#100)

## v1.7.1 - 2026-07-03

- fix(shell): make setup-shell rc line self-healing when the CLI leaves $PATH (#96)

## v1.7.0 - 2026-07-02

- feat(shell): resolve agent-guard without a PATH install for the bang guard (#94)

## v1.6.0 - 2026-07-02

- feat(shell): experimental opt-in bang-command guard (#92)

## v1.5.0 - 2026-07-01

- feat(shell): mask ! shell-escape output via agent-guard exec + shell-init (#86)
- feat(detection): broaden output secret recall (JWT, bearer, more env keys) (#85)

## v1.4.0 - 2026-07-01

- test: harden tests/run.sh temp files with mktemp (CWE-377) (#82)
- chore(changelog): drop stale Unreleased block ahead of v1.4.0 (#81)
- ci: bump actions/github-script from 7.1.0 to 9.0.0 (#71)
- ci: bump actions/checkout from 5.0.1 to 7.0.0 (#74)
- ci: bump openai/codex-action from 1.8 to 1.9 (#76)
- ci: bump hashgraph-online/ai-plugin-scanner-action (#75)
- docs: document shell-escape hook-bypass blind spot (#80)
- feat(agent-guard): mask PII in tool output via mask mode (#78)
- feat(agent-guard): mask secret-like values in tool output (#77)
- docs(readme): lead with a Claude Code quick start to lift install conversion (#73)
- feat(plugin): add Codex composer icon for Agent Guard (#72)
- ci: add HOL plugin scanner self-scan and harden CI workflows (#68)

## v1.3.8 - 2026-06-16

- docs: separate demo steps with blank lines for readability (#66)
- docs: render README badges in a single row (#65)

## v1.3.7 - 2026-06-16

- feat(agent-guard): rename Action to a unique GitHub Marketplace name (#63)

## v1.3.6 - 2026-06-16

- feat(agent-guard): unify positioning + Action branding for Marketplace publish (#61)
- fix(agent-guard): close fail-open gaps in hook input handling and deny-read Bash scan (#60)
- fix(agent-guard): calibrate secret-detection patterns (#59)

## v1.3.5 - 2026-05-24

- Merge pull request #57 from JeongJaeSoon/codex/plugin-layout-validation-ci
- Normalize plugin validation workflow names
- Tighten plugin root variable validation
- Split plugin layout validation steps
- Add plugin layout validation CI
- Merge pull request #56 from JeongJaeSoon/codex/codex-claude-plugin-hooks
- Align Codex hooks with plugin layout
- Use host-specific plugin hooks
- Improve Codex and Claude plugin hook compatibility
- feat: add PII filtering provider adapters (#51)
- [codex] Harden agent tool input scanning (#49)
- [codex] Add Codex code review workflow (#55)
- fix install hook quoting and docs

## v1.3.4 - 2026-05-09

- docs: clarify codex plugin hook setup (#46)
- ci: use checkout v5 (#45)

## v1.3.3 - 2026-05-09

- fix: include install script in release tarball (#43)

## v1.3.2 - 2026-05-09

- Fix real user install and verification flows
- simplify: narrow PostToolUse matcher, dedupe deny-read path, guard gitleaks version drift (#40)
- docs: fix v1 raw URL for gitleaks-checksum.sh after plugin restructure (#39)

## v1.2.1 - 2026-05-08

- fix(cli): follow symlinks when resolving SCRIPT_DIR (#34)

## v1.2.0 - 2026-05-08

- docs: restructure README around user task flow (#32)
- feat: add gitleaks-checksum helper (script + subcommand + slash command) (#31)
- refactor: simplify bin/agent-guard helper functions (#30)

## v1.1.2 - 2026-05-07

- feat(plugin): add /agent-guard:verify slash command (#26)
- chore(release): make release.yml idempotent on re-dispatch (#25)
- fix(release): bump VERSION constant in bin/agent-guard on release (#24)

## v1.1.1 - 2026-05-07

- Revert "chore(release): v1.1.1 (#20)" (#22)
- fix(release): build tarball outside the directory being archived (#21)

## v1.1.0 - 2026-05-07

- Revert "chore(release): v1.1.0 (#15)" (#17)
- fix(release): exclude tarball self-reference from tar input (#16)

## v1.0.2 - 2026-05-07

- fix(release): pick latest semver tag, ignore moving major tag (#10)
- chore(release): also bump marketplace.json plugin version (#9)
- docs: add Quickstart section with plugin install paths (#8)

## v1.0.1 - 2026-05-07

- chore(release): add automated release workflow (#5)
- simplify: remove scan_text_hook, fix sub-shell exit, drop make doctor, optimize deny-pattern checks (#4)
- chore: usability and robustness pass (#3)
- [codex] Add CI and clean public-readiness scan noise (#2)
- Harden against Bash/path bypass, Codex patch parsing, symlink, and action injection (#1)
