# Agent Guard

[![Release](https://img.shields.io/github/v/release/JeongJaeSoon/agent-guard)](https://github.com/JeongJaeSoon/agent-guard/releases) [![GitHub Marketplace](https://img.shields.io/badge/Marketplace-Agent%20Guard-2EA44F?logo=github)](https://github.com/marketplace/actions/agent-guard-secret-guardrails) [![CI](https://github.com/JeongJaeSoon/agent-guard/actions/workflows/ci.yml/badge.svg)](https://github.com/JeongJaeSoon/agent-guard/actions/workflows/ci.yml) [![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

**Stop your AI coding agent from leaking secrets — in real time, before the tool call runs.**

![Agent Guard blocking an agent's read of a .env that holds a private key, then a scan flagging the leak](docs/demo.gif)

Agent Guard is a deterministic guardrail for AI coding agents (Claude Code, Codex) and the Git hooks, CI, and CLI around them. It blocks common ways an agent accidentally exposes secrets: reading `.env`, writing secret-like values, running shell commands that dump credentials, or leaving secrets in the working tree after a tool call. It uses [gitleaks](https://github.com/gitleaks/gitleaks) for detection and plain shell scripts for integration.

Unlike commit- or CI-time scanners that catch a leak *after* it lands, Agent Guard also runs at the agent's tool boundary — the `.env` read or secret write is blocked before it happens. Pair it with commit/CI scanning for defense in depth.

It is not a vault, credential rotator, or replacement for GitHub Secret Scanning / Push Protection.

## Quick start

### Claude Code

Install from the marketplace:

```text
/plugin marketplace add JeongJaeSoon/agent-guard
/plugin install agent-guard@agent-guard
/reload-plugins
/agent-guard:setup-shell
```

The last command installs the default-on Claude command wrapping into your shell rc. Restart the shell and Claude Code after it succeeds. Plugin hooks are active after reload; shell wrapping for user-typed `!` commands requires this explicit rc update because plugins cannot edit it during installation.

Verify it's live — ask the agent to read your `.env`:

```text
Please read .env
```

It should refuse:

```text
agent-guard: blocked sensitive file access: .env
```

### Codex

Add the marketplace:

```sh
codex plugin marketplace add JeongJaeSoon/agent-guard
```

Open `/plugins` in Codex and install **Agent Guard**. Then open **Settings > Hooks**, trust the **SessionStart**, **UserPromptSubmit**, **PreToolUse**, **PostToolUse**, and **Stop** hooks, and restart Codex.

Run the guided setup skill:

```text
$setup-agent-guard
```

Treat setup as complete only when the plugin-local dependency check, smoke test, and both live host probes pass. The probes confirm that the current Codex tool route actually dispatches to Agent Guard's hooks.

To install or refresh the optional Agent Guard shell integration, choose
**Set Up Agent Guard Shell** from the `/` menu or invoke:

```text
$setup-shell
```

The skill resolves the current plugin-local binary and requests approval before
updating the shell rc, so the versioned plugin-cache path does not need to be
copied into the prompt. After the rc update, start a new shell and restart any
agent sessions launched from that shell before relying on the integration.

Both plugins need `jq` and `gitleaks` on your machine (`brew install jq gitleaks`; see [Requirements](#requirements)). Using the CLI, Git hooks, or CI instead? Pick your path below.

## Pick an install path

Installation, updates, and troubleshooting are documented below. Start with
[Verification and troubleshooting](#verification-and-troubleshooting) after setup.

| Use case | Install path | Best first check |
|---|---|---|
| Claude Code agent guardrails | [Claude Code quick start](#claude-code) | Ask the agent to read `.env`; it should be blocked. |
| Codex plugin guardrails | [Codex quick start](#codex) | Run `$setup-agent-guard` and require both live hook probes to pass. |
| Codex CLI + Git backstop | [Direct CLI](#direct-cli) + [Native Git hook](#native-git-hook) | Run `agent-guard smoke-test`, then check the project hook installation below. |
| Centrally managed machines | [Managed deployment](#managed-deployment) | Merge the managed settings example, have each developer run the setup commands, then ask the agent to read `.env`. |
| Local commits | [Native Git hook](#native-git-hook) | Run `agent-guard smoke-test`, then check the project hook installation below. |
| CI / PRs | [GitHub Actions](#github-actions) | Push a test PR with a gitleaks-detectable fixture; workflow should fail. |
| Manual scans | [Direct CLI](#direct-cli) | Run `agent-guard smoke-test`. |

## Requirements

Agent Guard runs on macOS and Linux and expects:

- `sh`
- `awk`
- `git`
- `jq`
- `gitleaks` 8.30 or newer recommended

Install paths that download release archives also use `curl`, `tar`, `shasum`, and `ln`.
PII endpoint providers also use `curl`.

With a direct CLI install:

```sh
agent-guard setup   # prints dependency status and install hints
agent-guard doctor  # equivalent explicit health check for scripts and CI
agent-guard check   # strict pass/fail dependency check
agent-guard smoke-test
```

From a clone of this repo:

```sh
plugins/agent-guard/bin/agent-guard setup
make check
make smoke-test
```

The Claude Code and Codex plugin installs do not put `agent-guard` on your shell `PATH`. In Codex, invoke `$setup-agent-guard`: it uses the plugin-local binary even when a different standalone version is on `PATH`, presents the exact host-appropriate install plan, requests approval, runs `check` plus `smoke-test`, verifies hook trust, and runs live host probes. It never installs software merely because a session started. The same skill is available in Claude Code as `/agent-guard:setup-agent-guard`; Claude Code users can also run the equivalent manual commands below.

Manual macOS equivalent:

```sh
brew install jq gitleaks
```

On Debian / Ubuntu or Fedora, install `jq` with the system package manager and download `gitleaks` from its release page.

## Trust, privacy, and support

When the plugin is enabled, its `PreToolUse` and `PostToolUse` hooks run for every
matched tool call in the session. They inspect supported tool inputs and outputs
in memory, and mutation/stop backstops scan changed files in the current Git work
tree. Default hook processing is local: Agent Guard has no telemetry, developer
service, account, or analytics endpoint, and it does not retain inspected data.

PII hook handling is off by default. The built-in `regex` provider stays local.
If you explicitly select the experimental `http` adapter or the `pleno`
provider, text passed to
`pii-filter`—and supported tool-input text in PII `block` mode—is sent to the
exact endpoint in `AGENT_GUARD_PII_REDACT_URL`. Review that endpoint's privacy
and retention terms before enabling it. The generic `http` adapter does not
guarantee compatibility with any specific service.

Dependency downloads never happen from a lifecycle hook. The guided setup asks
before installing anything and requires a published SHA-256 for the gitleaks
archive. See [Privacy and data handling](PRIVACY.md), [Security](SECURITY.md),
[Support](SUPPORT.md), and [Third-party notices](THIRD_PARTY_NOTICES.md).

## Claude Code Plugin

Install and verify in the [Claude Code quick start](#claude-code). Useful slash commands once installed:

```text
/agent-guard:verify
/agent-guard:checksum [VERSION]
/agent-guard:setup-shell
```

For guided dependency diagnosis and installation, use the
`/agent-guard:setup-agent-guard` skill — the same skill Codex invokes as
`$setup-agent-guard`. SessionStart recommends it when it reports degraded
protection, but never invokes it: it only emits the warning. The skill selects
the active host's plugin-verification path and runs live probes through that
host's normal command surface. `/agent-guard:verify` remains a separate
working-tree scan and does not prove live hook dispatch.

## Codex Plugin

Start with the [Codex quick start](#codex). Re-check **Settings > Hooks** after plugin updates: a changed hook is marked **Modified** and remains inactive until you review and trust it again. SessionStart reports degraded protection when a dependency is unavailable and points Codex to `$setup-agent-guard`; installation remains approval-gated. An untrusted SessionStart hook cannot display that guidance.

The setup skill requires all three layers to pass: plugin-local `check`, plugin-local `smoke-test`, and the live host probes. For the pre-tool probe, ask Codex to run this harmless sentinel command:

```sh
printf '%s\n' 'AGENT_GUARD_LIVE_PRE_TOOL_PROBE'
```

Expected result: Agent Guard blocks the command before the sentinel is printed. For the post-tool probe, run the paired harmless sentinel and confirm that the raw marker is masked or replaced before it reaches the model:

```sh
printf '%s\n' 'AGENT_GUARD_LIVE_POST_TOOL_PROBE'
```

These sentinels test only whether the host dispatched PreToolUse and PostToolUse. The plugin-local `smoke-test` separately exercises the real deny-list and secret-redaction rules without placing sensitive-looking instructions in the setup skill.

Codex may expose shell execution through a wrapping or orchestration tool such as `functions.exec`. Agent Guard cannot replace or wrap Codex's host executor; it protects only nested operations that the current Codex release dispatches to plugin hooks. Test the exact route used in the current task. If the pre-tool marker or raw fake token appears, protection is not active on that route even when the binary smoke test passes. Use a native Git hook or CI as the backstop and do not treat the plugin setup as complete for that host route.

Codex loads the plugin's declared `codex-skills/` directory but does not use
the Claude `commands/` directory. Use `$setup-agent-guard` for dependency and hook setup,
and `$setup-shell` to install or refresh the optional shell integration. Ask
Codex to run the binary directly for other workflows:

```sh
${PLUGIN_ROOT}/bin/agent-guard scan-working-tree
${PLUGIN_ROOT}/bin/agent-guard checksum
```

## Direct CLI

Install the latest release without cloning:

```sh
curl -fsSL https://github.com/JeongJaeSoon/agent-guard/releases/latest/download/bootstrap.sh | sh
```

The installer verifies the release archive checksum, extracts to `~/.agent-guard`, links `agent-guard` into `~/.local/bin`, runs `agent-guard setup`, and installs the default-on shell integration. Set `AGENT_GUARD_COMMAND_WRAPPING=off` on the bootstrap command for a persistent command-wrapping opt-out.

Common commands:

```sh
agent-guard scan-path .
agent-guard scan-working-tree
agent-guard scan-staged
agent-guard pii-filter
agent-guard setup
agent-guard smoke-test
agent-guard checksum
```

Scan commands return `0` for a clean scan and `1` for a detection. Non-zero
errors do not clear the input: `2` covers invalid arguments and scanner
execution errors; `3` means the direct scan could not run because its scanner,
scanner configuration, Git dependency, or repository state is unavailable.
Check the error message and treat every non-zero result as uncleared.

At a host hook boundary, scanner-infrastructure failures (missing dependencies,
an inaccessible/non-repository workdir, or a scanner crash) follow
`AGENT_GUARD_INFRA_FAILURE_MODE`: `open` is the default and continues after one
clear warning per session; `closed` blocks instead. A real secret detection is
not an infrastructure failure and always blocks. Direct scan commands and the
native Git hook keep their non-zero exit status so CI and Git never mistake an
unperformed scan for a clean result.

Override install defaults with `AGENT_GUARD_VERSION`, `AGENT_GUARD_HOME`, `AGENT_GUARD_BIN_DIR`, or `AGENT_GUARD_COMMAND_WRAPPING`.

`agent-guard update` is intentionally limited to standalone installs and
delegates to the same checksum-verified `bootstrap.sh` used for first install.
Plugin installations must be updated by Claude Code or Codex; after a plugin
update, rerun `agent-guard setup-shell` if the shell integration reports drift.
The updater validates the downloaded payload before extraction and preserves the
public bin directory used to invoke it, which reduces the failure surface but
does not make the whole installation transaction atomic.

Standalone v3.1.1 shipped `update` with a symlink failure that leaves `version`
and `doctor` reporting `Too many levels of symbolic links`; v3.2.0 fixes it. Do
not run the broken version's `update` to repair itself — reinstall with
`bootstrap.sh` from a current release instead. Recovery steps for an install
already in that state are in
[#194](https://github.com/JeongJaeSoon/agent-guard/issues/194).

Homebrew requires formulas to live in a tap. Install the published formula with:

```sh
brew tap JeongJaeSoon/tap
brew trust --formula jeongjaesoon/tap/agent-guard
brew install JeongJaeSoon/tap/agent-guard
```

Homebrew 6 requires trust for third-party taps. Formula-scoped trust is narrower
than trusting the entire tap and is therefore the recommended default.

## Managed deployment

Rolling Agent Guard out to an organization takes two steps: the administrator
adds the marketplace and plugin to Claude Code's managed settings, and each
developer runs the one-time setup commands. Developers who skip setup are
reminded automatically at session start.

### 1. Add the marketplace and plugin to managed settings (administrator, once)

Merge the keys from
[`deployment/claude-managed-settings.example.json`](deployment/claude-managed-settings.example.json)
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

### 2. Run the setup commands (each developer, once per machine)

Once the managed settings land, Claude Code loads the plugin automatically.
Each developer then completes setup in a Claude Code session:

1. **Dependencies** (`jq`, `gitleaks`): run `agent-guard setup` to diagnose,
   then `agent-guard setup --install --gitleaks-version <version>
   --gitleaks-checksum <published-sha256>` — `/agent-guard:checksum` prints
   the paste-ready version/checksum pair. The plugin does not put
   `agent-guard` on `PATH`; ask Claude to run the plugin-local binary.
2. **Shell integration** (covers the unhooked `!cat`/`!head`/`!printenv`
   path): run `/agent-guard:setup-shell`, then restart the shell and Claude
   Code.
3. **Verify**: `agent-guard check` and `agent-guard smoke-test`, or
   `/agent-guard:verify` for a working-tree scan.

### 3. Missing setup is suggested automatically

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

## PII Filtering

`agent-guard pii-filter` reads text from stdin, masks detected PII, and writes the masked text to stdout. The default provider is `regex`, a built-in shell/awk adapter with no Python runtime dependency:

```sh
printf '%s\n' 'Email jane@example.com from 203.0.113.42' | agent-guard pii-filter
# Email [PII:EMAIL] from [PII:IP_ADDRESS]
```

The built-in regex provider masks common deterministic formats: email addresses, phone numbers, credit cards, US SSNs, and IP addresses. Clean text is passed through unchanged.

Choose a provider with `AGENT_GUARD_PII_PROVIDER`. Accepted values are:

- `regex` — the supported built-in local adapter, and the default. No network access.
- `http` — an experimental bring-your-own-endpoint adapter. No compatibility with a specific service is guaranteed.
- `pleno` — an opt-in adapter verified against pleno-anonymize `/api/redact`.

Any other value fails closed with the accepted-value list; PII redaction never degrades to pass-through on an unrecognised provider.

```sh
AGENT_GUARD_PII_PROVIDER=regex agent-guard pii-filter --check
```

The experimental endpoint adapter can be used with a compatible service you operate or select:

```sh
AGENT_GUARD_PII_PROVIDER=http \
AGENT_GUARD_PII_REDACT_URL=http://127.0.0.1:8080/api/redact \
agent-guard pii-filter --check

printf '%s\n' 'Customer jane@example.com' \
  | AGENT_GUARD_PII_PROVIDER=http \
    AGENT_GUARD_PII_REDACT_URL=http://127.0.0.1:8080/api/redact \
    agent-guard pii-filter
```

`http` POSTs JSON as `{"text":"..."}` and reads a redacted string from `redacted_text`, `anonymized_text`, `text`, or `data.redacted_text`. It requires `curl`, `jq`, and `AGENT_GUARD_PII_REDACT_URL`; missing tools, missing URL, HTTP errors, invalid JSON, or unexpected response shapes fail closed. This generic contract is exercised with local mock fixtures, but compatibility with a real external service is not yet part of Agent Guard's supported surface.

For pleno-anonymize, run the service separately and point Agent Guard at its
`/api/redact` endpoint:

```sh
printf '%s\n' 'Contact Alice at alice@example.com' \
  | AGENT_GUARD_PII_PROVIDER=pleno \
    AGENT_GUARD_PII_REDACT_URL=http://127.0.0.1:8080/api/redact \
    AGENT_GUARD_PII_LANGUAGE=en \
    agent-guard pii-filter
```

The `pleno` adapter was verified against upstream commit
`ba3a14bc125fd6c6eb80aa5b24c22f6b99801126`. It sends exactly `text` and an
explicit `language`, then accepts only a JSON object with a string `text`.
`AGENT_GUARD_PII_LANGUAGE` accepts `en` or `ja` and defaults to `en`; this is an
Agent Guard default, while upstream defaults to `ja`. Upstream's server default
engine is `default`; Agent Guard does not override it. Endpoint requests have a
30-second default timeout, configurable with a positive integer
`AGENT_GUARD_PII_TIMEOUT_SECONDS`. Endpoint calls made by the 10-second input
hooks are capped at 5 seconds so the CLI can fail closed before the host's hook
deadline; a smaller configured timeout remains in effect.

Agent Guard does not install, import, start, or manage pleno-anonymize, Python,
Docker, models, or a hosted service. To test an endpoint you operate with
synthetic English, Japanese, and clean text, run:

```sh
AGENT_GUARD_PII_INTEGRATION_PLENO=1 \
AGENT_GUARD_PII_REDACT_URL=http://127.0.0.1:8080/api/redact \
make test-pleno-integration
```

PII handling in hooks is off by default. Two opt-in modes:

```sh
AGENT_GUARD_PII_HOOK_MODE=block   # block tool INPUTS that contain any PII
# or
AGENT_GUARD_PII_HOOK_MODE=mask    # mask PII in tool OUTPUTS; hard-block Tier-2 inputs
```

In **block** mode, proposed `Write`, `Edit`, `MultiEdit`, `NotebookEdit`, `apply_patch`, `Bash`, `WebFetch`, `WebSearch`, and MCP inputs are blocked when any PII is detected, with guidance to run `agent-guard pii-filter` first.

In **mask** mode, PII is masked in a tool's *output* (`PostToolUse`, the same path as secret redaction) so the model never sees it. On the *input* side, mask mode hard-blocks only **Tier-2** PII — credit card, US SSN, and Korean resident registration number, which must never reach a tool — and lets **Tier-1** PII (email, phone, IPv4) through to be masked on the way out. Hooks cannot rewrite a *pending* input payload, so Tier-1 input is allowed rather than masked in place; use `agent-guard pii-filter` for input-side masking.

The regex provider recognizes email, phone (including Korean mobile), IPv4, credit card, US SSN, and Korean resident registration number.

`AGENT_GUARD_PII_SKIP` turns individual **Tier-1** types off, so masking stops hiding what you actually need to read — an IPv4 during network debugging, or the 10-digit runs inside hashes and hex tokens that the generic phone shape matches. It takes a comma- (or space-) separated list of the names that appear in the placeholders, so what to write is readable straight off the masked output:

```sh
AGENT_GUARD_PII_SKIP=IP_ADDRESS          # keep IPv4 addresses in tool output
AGENT_GUARD_PII_SKIP=IP_ADDRESS,PHONE    # …and stop masking phone-shaped digits
```

Only `EMAIL`, `PHONE`, and `IP_ADDRESS` are accepted. A Tier-2 name (`CREDIT_CARD`, `SSN`, `KR_RRN`) or an unknown name is **refused with exit 2** rather than ignored: the mask-mode input hard-block is derived from Tier-2 masking, and a fail-closed gate must not be switchable from the environment. Two consequences worth knowing:

- A skipped type is no longer treated as PII **at all**, so `AGENT_GUARD_PII_HOOK_MODE=block` also stops blocking inputs that contain it. That is the point of the switch, not a leak — but it does mean the setting is not "output-only" in `block` mode.
- Skipping never affects Tier-2. Credit card, US SSN, and Korean resident registration number stay masked on output and hard-blocked on input in `mask` mode regardless of what is skipped.
- It requires the built-in `regex` provider. An endpoint provider (`http`, `pleno`) redacts server-side and never receives the skip set, so combining the two is **refused with exit 2** rather than left as a switch that silently does nothing.

## Native Git Hook

Install from a clone or direct CLI install:

```sh
cd <your-project>
~/.agent-guard/install.sh git-hooks
```

From a clone of this repo:

```sh
./install.sh git-hooks
```

This sets `core.hooksPath=githooks` only when it will not overwrite an existing hook setup.

## GitHub Actions

Add a workflow step:

```yaml
- uses: JeongJaeSoon/agent-guard@v3
  with:
    paths: "."
    gitleaks-checksum: "<sha256 of the gitleaks release archive>"
```

`paths` is whitespace-separated, so an individual path cannot contain spaces; the default `.` scans the whole repository.

Use `@v3` for compatible 3.x updates. The `@v2` and `@v1` moving tags remain on the 2.x and 1.x lines; pin one of them, a full tag, or a commit SHA when you intentionally stay on an older line.

Get the checksum with:

```sh
agent-guard checksum
```

CI runners are usually `linux/x64`, so use the `linux/x64` value printed by the checksum command. `require-checksum` defaults to `true`; set it to `false` only for local experimentation.

## What Gets Blocked

- On Claude Code: `Read`, `NotebookRead`, `Grep`, and `Glob` access to deny-listed paths; `Write`, `Edit`, `MultiEdit`, and `NotebookEdit` secret-like content; and sensitive web/MCP inputs
- On Codex: supported hook surfaces (`Bash`, `apply_patch`, and MCP tools). Current Codex hooks do not intercept arbitrary Read/Grep/WebSearch calls, so Agent Guard does not claim coverage for them.
- risky shell commands such as `printenv`, `op read`, `vault kv get`, `aws secretsmanager get-secret-value`, `cat .env`, and `git commit --no-verify`
- PII in proposed write, shell, web, or MCP inputs — all PII when `AGENT_GUARD_PII_HOOK_MODE=block`, or only Tier-2 PII (credit card, US SSN, Korean resident registration number) when `AGENT_GUARD_PII_HOOK_MODE=mask`
- staged added lines in the native pre-commit hook
- working-tree added lines and untracked files after agent mutations

Patch and diff scans inspect added lines only. Removing an existing leaked value is allowed.

Shell blocking is deliberately conservative: it matches path-shaped text anywhere in the command string, so benign commands that merely mention a deny-listed name are blocked too. See [Known Limitations](#known-limitations) before relaxing the deny list.

Environment templates remain readable when their basename has an explicit,
final `.example`, `.sample`, `.template`, or `.dist` marker, or when
`example`, `sample`, or `template` directly prefixes an `.env`/`.envrc`
extension (for example `.env.local.example`, `sample.env`, and
`example.envrc`). Runtime-shaped names such as `.env.local`, `local.env`,
`env.local`, `env.preview`, `example.env.local`, `.flaskenv`, and
`.dev.vars.production` stay blocked. Source-module forms such as `env.ts` and
`config.env.ts` remain readable, while data/config suffixes such as
`schema.env.json` stay protected. Template exceptions never override a
non-environment deny rule, a deny-listed ancestor, or an operator-supplied
`AGENT_GUARD_DENY_READ_PATHS` policy. Template-named symlinks are resolved and
do not bypass the runtime-file rule; proposed template contents are still
scanned normally for real secrets.

Dependency checksums are exempt only for recognized hash-field shapes in
`go.sum`, `package-lock.json`, `yarn.lock`, `Cargo.lock`, and `uv.lock`. The
allowlist requires both the lockfile path and the checksum pattern; arbitrary
content in those files, including a credential added beside normal hashes, is
still scanned.

## What Gets Masked

Beyond blocking, Agent Guard **masks** secret-like values in a matched tool's output before the model sees them. Claude uses the native `updatedToolOutput` rewrite and preserves the result shape. Codex does not expose that Claude field, so Agent Guard blocks the original sensitive result and supplies a sanitized replacement through `additionalContext`. Detection combines gitleaks with an assignment-value heuristic. The heuristic masks only the quoted value or next unquoted value token of a complete secret-bearing key; it does not mask metadata keys merely beginning with a secret word, prose after a known standalone status label (`error:`, `warning:`, `info:`, `note:`, `debug:`, `fatal:`, `hint:`), or adjacent status text. Any other colon-terminated label is treated as structured output, so `response: api_key: <value>`, `response.error: api_key: <value>`, and `response/error: api_key: <value>` are masked. It is on by default; disable with `AGENT_GUARD_OUTPUT_REDACT=off`.

With `AGENT_GUARD_PII_HOOK_MODE=mask`, the same `PostToolUse` redactor also masks **PII** in tool output — email, phone (including Korean mobile), IPv4, credit card, US SSN, and Korean resident registration number become `[PII:TYPE]` placeholders in place. Secret redaction and PII masking compose into a single rewrite, so a result containing both is fully sanitized at once.

## Prompt guard (secrets pasted into the prompt)

The tool hooks never see what **you** type: a pasted `.env` file or API key in the prompt reaches the model API and the on-disk transcript unscanned. The `UserPromptSubmit` hook closes that path on both hosts. Detection reuses gitleaks plus the `KEY=value` assignment heuristic, and `AGENT_GUARD_PROMPT_GUARD_MODE` picks the response:

- `block` (default) — a detected prompt is rejected before submission with a visible reason, so it does not reach the model or the transcript. (Like every hook, this depends on the guard actually running: a missing scanner follows `AGENT_GUARD_INFRA_FAILURE_MODE`, and a hook the host kills at its timeout cannot block.)
- `mask` — reserved. **Neither host currently lets a hook rewrite the submitted prompt** (Claude Code's `UserPromptSubmit` supports only block and added context; Codex documents the same), so `mask` degrades to `block` with a message naming the degrade. It exists so a configured preference survives a future host that adds prompt rewriting; emitting a "masked" prompt the host ignores would silently leak the original.
- `warn` — the prompt passes through unchanged with a visible notice. Opt-in only; it does not prevent the leak.
- `off` — no secret scanning of prompts.

Very large prompts (over the shared ~320 KB scan cap) skip the `KEY=value` assignment heuristic — it is super-linear on a single large paste and would otherwise burn the host's hook timeout, which kills the hook and fails open. Gitleaks rules still apply at any size, and the skip follows `AGENT_GUARD_INFRA_FAILURE_MODE`: `open` (default) continues with a one-time notice, `closed` blocks the oversized prompt.

The PII input gate applies independently (even with the secret guard `off`): `AGENT_GUARD_PII_HOOK_MODE=block` blocks any PII in the prompt, and `mask` hard-blocks Tier-2 PII (credit card, US SSN, Korean resident registration number). Tier-1 PII (email/phone/IP) cannot be masked inside a prompt — there is no rewrite — so in `mask` mode it passes through; use `block` if that matters. The same detection limits as output masking apply — this is defense in depth, not a reason to paste credentials.

## Shell integration (masking `!` shell-escape output)

The `PostToolUse` redactor only ever sees the results of the agent's *tool calls*. When you type a `!`-prefixed command at the Claude Code prompt, it runs in the session shell and its **output is captured into the transcript and sent to the model** — but it is not a tool call, so **no** Agent Guard hook fires (a documented blind spot). If that output carries a credential, the model sees it unmasked.

`agent-guard exec` closes that gap. Before running anything, it verifies that the configured masking dependencies are usable; if they are not, the explicit wrapper fails closed and does not run the command. Once ready, it runs the command to completion, propagates its exit code, captures combined stdout+stderr, and prints only masked text. Capture is buffered, so this is for non-interactive info commands, not TUIs or streaming programs. `AGENT_GUARD_OUTPUT_REDACT=off` explicitly disables secret masking.

```sh
agent-guard exec -- printenv          # runs it, but the transcript gets [REDACTED] in place of secrets
```

To make this ergonomic, add the shell integration to your `~/.bashrc` / `~/.zshrc`:

```sh
eval "$(agent-guard shell-init)"
```

Or let `setup-shell` write (and later update) that line for you — idempotently, and by absolute path when `agent-guard` isn't on your `$PATH` yet:

```sh
agent-guard setup-shell
```

This defines `agx` (a thin wrapper for `agent-guard exec --`) so you can run `agx <cmd>` — in Claude Code, `!agx <cmd>` — and have the output masked before the model sees it. It also installs a **warn-only, non-blocking** nudge (a zsh `preexec` / bash `DEBUG` trap) that reminds you to use `agx` when you run a known secret-loading idiom without it. The nudge never blocks or modifies your command; pass `--bash` or `--zsh` to force a target shell.

#### fish (and other non-POSIX shells)

`shell-init` emits POSIX shell code, so fish cannot `eval` it — there is no fish rc to install into, and `agx` and the nudge are **not automatically available** at a fish prompt. A standalone install can run `agent-guard exec -- <cmd>` directly. A plugin-only install usually does not put `agent-guard` on fish's `PATH`, so use this PATH-aware function instead:

```fish
function agx
    if type -q agent-guard
        command agent-guard exec -- $argv
        return $status
    end

    set -l _ag "$HOME/.claude/plugins/cache/agent-guard/agent-guard/current/bin/agent-guard"
    if not test -x "$_ag"
        printf 'agent-guard: plugin binary not found; rerun /agent-guard:setup-shell and use the fish executable path it prints\n' >&2
        return 127
    end
    command "$_ag" exec -- $argv
end
funcsave agx
```

The `current` path above is the stable plugin-cache symlink refreshed by plugin execution. If your plugin cache is elsewhere, use the `fish executable` path printed by `setup-shell`.

The part that protects the transcript still works: Claude Code runs `!` and Bash-tool commands from a **bash or zsh** shell snapshot, and those shells do read `~/.bashrc` / `~/.zshrc`. Which of the two Claude Code picks is not visible to `setup-shell`, so it checks both the process `$SHELL` and the account login shell (`getent passwd` on Linux, `dscl UserShell` on macOS). If either says fish, it writes the managed block to **both** files and command wrapping loads either way. If account lookup fails, it safely falls back to the process `$SHELL` (then zsh for an unknown value). An explicit `--bash`, `--zsh`, or `--rc FILE` always targets a single file.

### Claude command wrapping (stable, default on)

The nudge above relies on a `preexec` / `DEBUG` hook — but Claude Code runs `!` commands from a **shell snapshot** that strips those hooks (and `unalias -a`s), so the nudge never fires for `!`. The snapshot *does* keep shell **functions**, so Agent Guard installs function overrides for the common dump commands by default.

The default `shell-init` output overrides `cat`, `head`, and `printenv` so that — **only inside Claude Code** (gated on `$CLAUDECODE`) — they route through `agent-guard exec`, masking their output before the transcript captures it. So `!cat config.txt` gets its secrets redacted automatically, without you remembering to type `agx`. In a normal terminal (`$CLAUDECODE` unset) the overrides stay inert and fall back to plain `cat` / `head` / `printenv` behavior.

Turn automatic wrapping off for one process or shell by exporting `AGENT_GUARD_COMMAND_WRAPPING=off`. For a persistent opt-out, rewrite the managed block without the automatic overrides:

```sh
export AGENT_GUARD_COMMAND_WRAPPING=off  # runtime opt-out
agent-guard setup-shell --no-command-wrapping  # persistent opt-out
```

For plugin installs, every execution refreshes a sibling
`current/bin/agent-guard` symlink and `setup-shell` records only that stable
path. Shell snippets treat a healthy `current` as authoritative even when a
higher version directory is already cached. Only when `current` is missing or
invalid do they recover through the newest complete cache payload whose
directory and embedded versions agree. Relative PATH entries and symlink
aliases cannot re-admit a rejected cache payload. This is recovery based on the
existing `current` contract; it does not read the host plugin registry or infer
which cached version the user selected. A newly host-selected plugin becomes
authoritative after that plugin binary runs and safely advances `current`.
Standalone CLI installs continue to use their stable `~/.agent-guard` /
`~/.local/bin` paths and retain an independent PATH fallback.

The managed rc block embeds this resolver. After installing a plugin version
that changes shell resolution, rerun the plugin-local `agent-guard setup-shell`
(preserving `--no-command-wrapping` if that is your choice), then start a new
shell and restart Claude Code. Updating plugin files alone does not rewrite an
older rc block. Confirm the new shell's `AGENT_GUARD_SHELL_INIT_VERSION`; do not
assume an already-running shell changed in place.

The shell resolver order is an explicit `$AGENT_GUARD_BIN`, a healthy stable
`current` path, the newest validated plugin-cache fallback only when `current`
is unavailable, then an independent `agent-guard` on `$PATH`.
Both transparent wrapping and `agx` preflight dependencies and use the same
infrastructure policy: default `open` runs the original command with one clear
`output is NOT masked` warning per shell session; set
`AGENT_GUARD_INFRA_FAILURE_MODE=closed` to refuse execution instead.

Because the plugin (auto-updated by `claude plugin update`) and the binary the integration actually resolves update independently, updating only one side can silently leave `agx` / `!`-command masking on older rules. To catch that, the `shell-init` snippet exports `AGENT_GUARD_SHELL_INIT_VERSION` — the version of the binary selected by the resolver at rc-eval time — and a Claude Code `SessionStart` hook compares that marker against the plugin's own version, showing a **non-blocking warning** on mismatch. Because the marker records what the integration resolved at shell start (not a re-derivation the hook would have to guess), it stays silent unless the integration is genuinely loaded *and* drifting: a user who has `agent-guard` on `$PATH` but never ran `setup-shell` gets no warning, and a plugin-only install pinned to a stale baked binary is still covered. It is a start-up snapshot, so if you upgrade the resolved binary *in place* inside a long-lived shell and then launch Claude Code from it without opening a new shell, the warning reflects the version from when that shell started until you re-source your rc.

The marker can only reach the hook through the environment of the shell that **launched** Claude Code, and some launches never evaluate an rc at all: a fish (or other non-POSIX) login shell, or starting Claude Code from a GUI or IDE launcher. The wrapping is still loaded in those cases — Claude Code's own bash/zsh snapshot reads the rc — so a missing marker is not evidence that setup is missing. Before reporting `command wrapping is not loaded`, `SessionStart` therefore reads the managed block out of the rc the snapshot shell uses (`~/.bashrc` when `$SHELL` ends in `bash`, otherwise `~/.zshrc`) and checks that it can still **load** ([#139](https://github.com/JeongJaeSoon/agent-guard/issues/139)).

The delimiters alone are not that proof. The block's `eval` emits nothing once the binary it resolves has disappeared — a plugin cache update or uninstall, or a hand-edited block — so neither the wrapping nor the marker is installed, and treating the delimiters as sufficient would silence the warning on exactly the sessions that are unprotected. The hook instead replays the block's own resolution order against the paths baked into it: the stable/self path, then a versioned binary under the plugin cache base, then `agent-guard` on `$PATH`. Those are `stat`-level checks — nothing is executed, no subshell is forked — so they remain a diagnostic heuristic rather than proof of the runtime choice. They do not validate payload completeness and embedded-version agreement as deeply as the shell resolver or prove which binary a new shell executed. The three outcomes are:

| rc state | `SessionStart` |
| --- | --- |
| block absent from that rc | `command wrapping is not loaded` — run setup |
| block present and still resolves a binary | silent; only the version-drift comparison is unavailable |
| block present but resolves nothing | `can no longer load` — restore the binary and rerun `setup-shell` |

When the two readings conflict, the hook warns: a false "you need to run setup" is recoverable, a false "you are protected" is not.

> **Works without the CLI on `$PATH` — but a plugin can't edit your rc.** Direct CLI bootstrap installs the default-on shell integration automatically. For a plugin-only install, run the plugin-local `agent-guard setup-shell` once — invoke it by absolute path if `agent-guard` isn't on your `$PATH`; it writes the stable `current` path — then restart your shell and any Claude Code session. See [Upgrading older installations](#upgrading-older-installations) for removed flags and managed deployment changes.

`/agent-guard:setup-shell` invokes that binary through Claude's Bash tool so a
sandboxed session can request approval before writing the shell rc. If the host
cannot grant that approval, run the displayed plugin-local command directly in
your terminal; `!` command interpolation cannot request the required write
permission.

**This is best-effort, not a security control.** It covers only those command names and is trivially bypassed by an absolute path (`/bin/cat`), `source` / `.`, `python -c 'open(...)'`, or a redirection (`< file`). Because `agent-guard exec` buffers the whole output before masking it, **streaming / follow commands would hang** — so `tail` is deliberately *not* wrapped, and you should not `agx` a `tail -f`, a pager, or any long-running program (wrap only terminating dump commands). Output is captured via shell substitution, so wrapping is **text-only** — a binary or NUL-containing read loses embedded NULs and its trailing newline, so use `command cat` / `\cat` for faithful binary output. Invalid UTF-8 is handled byte-for-byte when possible; to keep that fallback bounded and fail closed, a secret-bearing assignment dump over 64 KiB or invalid-byte output from a secret-named `printenv` request is replaced as one `[REDACTED]` result. Oversized invalid-byte output with no secret-like assignment is preserved. Each wrapped call also pays a gitleaks scan. Treat it as a convenience nudge for the common cases, not a boundary — the only channel-agnostic fix remains an egress redaction proxy or an upstream `!`-command hook.

## Known Limitations

- **Bash source and search operands can resemble protected file paths.** Host Bash hooks provide one opaque command string, so the path gate cannot safely distinguish a file operand from text inside inline code or a shell-based search pattern. Every block from this gate uses the neutral `reason=bash_protected_path_text_match`: it means only that raw command text matched a protected-path pattern, not that Agent Guard proved a file read or classified the command as a false positive. Known examples include inline JavaScript that refers to `process.env.PORT`, spreads `process.env` into a child environment, or searches for that expression with `rg`. If inspection confirms the logic neither prints the environment nor reads or transmits protected data, keep server and smoke-test logic in a reviewed source file and launch it with explicit public configuration such as `env PORT=43119 node server.mjs`. On hosts whose active matcher dispatches a structured `Grep` event, use its separate `pattern` and `path` fields for code searches; the bundled Claude matcher includes `Grep`, while the bundled Codex matcher does not. These conditional alternatives address the false-positive shape only; they are not exemptions for protected behavior. Do not disable Agent Guard or weaken the deny list to retry the blocked Bash command.

Agent Guard is a deterministic, thin guardrail — not a DLP system, EDR, or vault. It scans tracked diffs, staged changes, and untracked files with gitleaks, and blocks a fixed list of sensitive paths and shell idioms. It deliberately does **not** inspect arbitrary file contents that a command reads, and it has these blind spots by design:

- **Gitignored files are not scanned.** The working-tree and post-tool/stop backstops use `git ls-files --others --exclude-standard` and `git diff`, both of which skip `.gitignore`d paths. A secret written to a gitignored file (e.g. `secrets/` or `*.local`) is not caught by the backstop. Keep real secrets out of the repo entirely.
- **Only files inside the git work tree are covered.** The post-tool and stop hooks no-op outside a git repository, and scans are scoped to the current repo. Files outside the repo root, or written when no repo is present, get no backstop. Use `agent-guard scan-path <dir>` to scan an arbitrary tree on demand.
- **Path and command blocking use fixed lists.** Read/Grep/Glob blocking matches the paths in `deny-read-paths.txt`; shell blocking matches the idioms in `deny-bash-patterns.txt`. A secret in an unlisted path, or read by an unlisted tool or flag, is not blocked. Extend the lists with `AGENT_GUARD_DENY_READ_PATHS` / `AGENT_GUARD_DENY_BASH_PATTERNS`.
- **Bash path blocking intentionally fails closed on path-shaped text.** A `PreToolUse` hook receives the raw shell command string, not the program and operands the shell will ultimately resolve. Agent Guard therefore matches every `deny-read-paths.txt` entry against the whole command string — up to four passes (literal and shell-expanded, each before and after dequoting), bounded so `myenv` is not a match. The boundary is a shell-word or quote boundary, not a file check: any token that *ends* in a deny-listed name matches, so a benign word such as `foo.key` / `foo.pem`, a jq selector such as `.key`, a URL (`curl https://example.com/a.pem`), or even a commit message (`git commit -m 'fix foo.key parse'`) is blocked although no file exists and nothing would be read ([#99](https://github.com/JeongJaeSoon/agent-guard/issues/99)). Operands are not exempted by their apparent command name — aliases, functions, wrappers, `PATH`, pipes, and compound commands can make a token under `echo`, `printf`, or `jq` a real read target at execution time — with one narrow exception whose grammar is unambiguous: ripgrep's negative glob (`rg -g '!*.pem'`, `--glob=` / `--iglob=` forms included; `grep --exclude` and `find -name` get no such exemption). When the command is genuinely benign, use an equivalent expression that is not path-shaped (for example, `jq '.["key"]' data.json`); do not weaken the deny list merely to silence this false positive. To make that rewrite possible without guesswork, every block from this gate also names the `deny-read-paths.txt` entry that matched and the scanned text that matched it (`matched deny-read-paths entry '*.key' in scanned text 'foo.key'`), followed by a rewrite hint. The excerpt is trimmed and capped; it is a diagnosis of the text, not a claim that a file exists. The same deny list is also applied, as a whole-value match, to **every string value** of a `Read`, `NotebookRead`, `Grep`, or `Glob` tool input rather than its path fields alone, so an unfamiliar field that names a deny-listed path fails closed. The one field exempted is a `Grep` *pattern* when it is a plain string that does not start with `-`: that is the content regex handed to ripgrep, structurally separate from `path` and `glob`, so searching for the text `.key` is allowed. An option-shaped pattern such as `--file=.env`, a non-string pattern, and a `Glob` pattern (a path glob) are still checked.
- **Output masking is best-effort.** Secret-like values in a tool's output (`Bash` stdout/stderr, file reads) are masked in place by the `PostToolUse` redactor (`AGENT_GUARD_OUTPUT_REDACT`, on by default), but detection is heuristic — gitleaks plus a `KEY=value` env-assignment rule. Detection is also **entropy-gated**: a realistic high-entropy credential is masked regardless of context, but a low-entropy value is only caught when its key name looks secret-bearing (`*_TOKEN=`, `PASSWORD:`, …) or its shape carries a distinctive vendor prefix (GitHub `ghp_`/`github_pat_`, AWS `AKIA…`, Anthropic/OpenAI `sk-ant-`/`sk-proj-`, npm `npm_`, GCP `AIza…`, Slack `xox?-`, GitLab `glpat-`, DigitalOcean `dop_v1_` — matched by shape alone, with no entropy filter). A low-entropy secret under a generic variable name with no recognizable prefix passes through unmasked, non-secret-but-sensitive data (internal hostnames, base URLs, private config) is never a match at all, and other unusual or custom secret formats can still slip through. The redactor also only sees results of the agent's *tool calls*. PII masking (`AGENT_GUARD_PII_HOOK_MODE=mask`) is likewise regex-based: it can over-match (a version string read as an IPv4) or miss locale formats it has no rule for. Both the secret redactor and the PII masker walk JSON string *values* only — a secret or PII string that appears as an object *key* is left unmasked, because rewriting keys could collapse two distinct keys onto one placeholder and drop an entry. Treat output masking as defense in depth and keep real secrets and personal data out of agent sessions entirely.
- **Bash detection is pattern-based.** The denylist targets common-accident and obvious-malicious idioms; an actively-evading agent can craft a command that matches none of them. Treat shell blocking as defense in depth, not a complete adversarial boundary.
- **User-typed shell-escape commands bypass every hook.** Agent Guard works entirely through host hooks (`UserPromptSubmit` / `PreToolUse` / `PostToolUse`) and git hooks. A command the user runs directly through the host's interactive shell escape — for example a `!`-prefixed command typed at the agent prompt — never becomes a tool call, so **no** Agent Guard hook fires: neither the input block nor the output redactor. A secret that such a command prints (e.g. an env- or vault-reading CLI whose output is not redirected to `/dev/null`) lands in the session transcript unmasked. The recommended mitigation is to run such commands via `agx <cmd>` / `agent-guard exec -- <cmd>` (see [Shell integration](#shell-integration-masking--shell-escape-output)) so their output is masked *before* it reaches the model, or use the default-on [Claude command wrapping](#claude-command-wrapping-stable-default-on) for the common dump commands. Alternatively, run secret-loading commands *through* the agent's tools so the hooks apply, or redirect their output away from the transcript — both streams, since many CLIs print credentials or secret-bearing diagnostics to stderr (`>/dev/null 2>&1`).

For defense in depth, pair Agent Guard with GitHub Secret Scanning / Push Protection and a secrets manager so credentials never reach the working tree.

## Coverage benchmark

`make bench` runs a deterministic, per-channel leak-prevention benchmark against the **real** gitleaks engine, classifying each case as `blocked` / `masked` / `leaked` (plus `false-positive` for benign controls) across the read-tool, bash-read, bash-cmd, bash-output, read-output, mcp-output, and `!` bang channels. It honestly records the raw `!` channel as structurally uncovered by hooks; default command wrapping and explicit `agx` are reported as best-effort shell mitigations, not counted as hook coverage. Results are written to `bench/results.tsv`. This is a measurement, not a
pass/fail security gate: a completed measurement exits `0` even when a case
leaks; failed health checks abort with `3`. Inspect the matrix. Encoding,
chunking across calls, and native host dispatch are not proven by these cases.

## Configuration

Override bundled policies with environment variables:

```sh
AGENT_GUARD_GITLEAKS_CONFIG=/path/to/gitleaks.toml
AGENT_GUARD_GITLEAKS_BIN=/absolute/path/to/gitleaks
AGENT_GUARD_GITLEAKS_BIN_DIR=$HOME/.agent-guard/bin
AGENT_GUARD_DENY_READ_PATHS=/path/to/deny-read-paths.txt
AGENT_GUARD_DENY_BASH_PATTERNS=/path/to/deny-bash-patterns.txt
AGENT_GUARD_PII_PROVIDER=regex
AGENT_GUARD_PII_REDACT_URL=http://127.0.0.1:8080/api/redact
AGENT_GUARD_PII_HOOK_MODE=off
AGENT_GUARD_OUTPUT_REDACT=off
AGENT_GUARD_PROMPT_GUARD_MODE=block
AGENT_GUARD_INFRA_FAILURE_MODE=open
```

An `AGENT_GUARD_DENY_READ_PATHS` override is authoritative. Unlike the bundled
environment-family defaults, its entries are not relaxed for template-shaped
filenames; explicitly listing `sample.env` or `secrets/*` therefore blocks those
paths.

Output masking is on unless `AGENT_GUARD_OUTPUT_REDACT` is set to `off`; the variable is a switch, not a mode name, so any other value leaves masking enabled. Set `AGENT_GUARD_PII_HOOK_MODE` to `block` (block PII in tool inputs), `mask` (mask PII in tool outputs + hard-block Tier-2 PII inputs), or `off` (default); `AGENT_GUARD_PII_SKIP` turns individual Tier-1 types (`EMAIL`, `PHONE`, `IP_ADDRESS`) off and refuses Tier-2 names. Set `AGENT_GUARD_PROMPT_GUARD_MODE` to `block` (default), `mask` (reserved; degrades to block — no host supports prompt rewriting yet), `warn`, or `off` for secrets pasted into the user prompt.

Set `AGENT_GUARD_INFRA_FAILURE_MODE=closed` when a host hook or shell wrapper
must refuse execution if the scanner cannot run. The default is `open`, with a
deduplicated warning; detections always block in either mode.

Project-local `.gitleaks.toml` files are not automatically trusted.
Gitleaks resolution is deterministic: `AGENT_GUARD_GITLEAKS_BIN`, then `PATH`, then `AGENT_GUARD_GITLEAKS_BIN_DIR/gitleaks` (default `~/.agent-guard/bin/gitleaks`). This makes the private `setup --install` destination immediately usable without editing `PATH`.

## Checksums and Approval-Gated Install

`agent-guard setup --install` can install `gitleaks`, but only with an explicit checksum:

```sh
agent-guard checksum
agent-guard setup --install \
  --gitleaks-version 8.30.1 \
  --gitleaks-checksum <sha256-for-this-os-and-arch>
```

The checksum helper prints all supported OS / arch values and paste-ready snippets for CLI setup and GitHub Actions. The guided setup skill —
`/agent-guard:setup-agent-guard` in Claude Code, `$setup-agent-guard` in Codex —
automates the diagnosis and checksum-selection workflow, but still asks before the download or a package-manager change.

## Host Integrations

Agent Guard shares its scanner implementation across Claude Code and Codex, but keeps host wiring explicit:

- `plugins/agent-guard/bin/agent-guard`, `config/`, and `scripts/` are shared.
- Claude Code uses `.claude-plugin/plugin.json`, the default `skills/` directory,
  `commands/`, and `hooks/hooks.json`. The setup skill uses Claude's
  `disable-model-invocation: true` frontmatter.
- Codex uses `.codex-plugin/plugin.json`, which explicitly declares `hooks.json`
  and `codex-skills/`. Its setup wrappers carry Codex UI policy and read the
  canonical instructions from `skills/`, keeping Claude-only frontmatter out of
  Codex ingestion. Hook commands set `AGENT_GUARD_HOOK_HOST=codex` so output
  follows the Codex contract.
- Codex uses `$setup-agent-guard` for guided dependency setup and `$setup-shell`
  for the optional shell integration. Claude `commands/` remain Claude-specific;
  other Codex workflows use the binary directly.

Wiring the hooks yourself, without installing the plugin? `examples/` holds a
working manifest per host — [`examples/claude/settings.project.json`](examples/claude/settings.project.json),
[`examples/codex/hooks.json`](examples/codex/hooks.json), and a CI workflow in
[`examples/github/secret-guard.yml`](examples/github/secret-guard.yml). The two
hook manifests are generated by `scripts/render-hook-manifests.sh` from the same
tables as the shipped plugin manifests, so their event coverage and timeouts
cannot drift from the plugin; edit the renderer, not the files.

## Verification and troubleshooting

Use the binary belonging to the installation you are checking. For a standalone
install, run:

```sh
agent-guard version
agent-guard doctor
agent-guard check
agent-guard smoke-test
```

From a repository clone, the equivalent commands are:

```sh
plugins/agent-guard/bin/agent-guard version
plugins/agent-guard/bin/agent-guard doctor
plugins/agent-guard/bin/agent-guard check
plugins/agent-guard/bin/agent-guard smoke-test
```

`setup` and `doctor` check only local dependencies. Their
`host hook protection: unverified (dependency checks do not observe tool
dispatch)` notice is expected whether those checks pass or fail. A `setup ok
(dependencies only)` result does not establish that Claude Code or Codex is
dispatching plugin hooks.

The whole `smoke-test` command must exit `0`. Its output should include
`scan-path blocks a private-key fixture`,
`native pre-commit hook blocks staged fixture`, and `smoke-test ok`.
Internally, the dirty scan and fixture commit must fail for the smoke test to
pass. It creates synthetic data in a temporary repository and cleans it on
exit; do not substitute real keys or copy hand-written key-shaped examples.

Smoke exercises the CLI and a temporary hook. It does not prove that your
project's installer ran, that an existing Git hook chain is intact, or that a
host dispatches plugin hooks. After installing the [project hook](#native-git-hook),
check it from that project:

```sh
git config --get core.hooksPath
test -x githooks/pre-commit
```

The expected setting is `githooks`. Before changing an existing hook setup,
keep a local copy of the hook; afterward compare it locally and inspect that
the generated hook still invokes it. Confirm the next intended clean commit
runs successfully through the chain. Do not dump provider settings or enable
full command tracing to prove that a hook ran. Conflicting hook managers need
an explicit integration that invokes `agent-guard scan-staged` and propagates
failure; the installer refuses to overwrite them.

For Claude Code, reload the plugin and run `/agent-guard:setup-agent-guard`;
for Codex, start a new session and run `$setup-agent-guard`. The bundled skill
checks the plugin-local binary and runs harmless live pre/post probes through
the host's actual tool route. In Codex, review modified hooks in Settings > Hooks.
A standalone binary on `PATH` is not a substitute for the installed plugin.
Parent `Agent`/legacy `Task` calls and child tool calls depend on the host
forwarding their events; success at one boundary does not prove the other.

| Symptom | Next step |
|---|---|
| `agent-guard` not found | Plugin-only installs do not add it to `PATH`; use the setup skill or the plugin-local executable. |
| CLI works, host probe does not | Check plugin enablement and hook trust, reload/restart, and retry the exact tool route. Report it as unobserved/unknown; passing CLI checks are not dispatch evidence. |
| A host denies a read that the direct guard permits | Treat a host-identified pre-dispatch refusal as host-owned, not an Agent Guard block. A generic `PreToolUse blocked` message has unknown source unless Agent Guard hook output is also visible. Do not automatically remove deny rules. |
| An Agent Guard hook rejects the harmless probe | This is an observed Guard denial for that route. Review the reported policy match without weakening unrelated protection; it does not prove clean command completion. |
| `DEGRADED` or scanner error | A visible Agent Guard `DEGRADED` response means the hook reached an unavailable dependency or policy. Run `doctor` and `check`; this is not a clean scan. |
| A harmless probe receives a hook response | This is dispatch-only evidence for that route. Call it normal completion only after a separate harmless command on the same route actually exits `0`. |
| Different CLI, plugin, or shell versions | Update each with its owning manager. If optional shell integration is used, rerun `agent-guard setup-shell` and restart the shell and host sessions. |
| Standalone update reports a symlink loop | v3.1.1 only, fixed in v3.2.0. Reinstall with a current `bootstrap.sh` rather than repairing in place; recovery steps are in [#194](https://github.com/JeongJaeSoon/agent-guard/issues/194). Do not delete the old installation blindly. |
| Action checksum mismatch | Match the exact gitleaks version, OS, and architecture printed by `agent-guard checksum`. |

Homebrew installations use `brew upgrade JeongJaeSoon/tap/agent-guard`.
Claude plugins update through `/plugin update agent-guard@agent-guard`, followed
by `/reload-plugins`; Codex plugins update through the host's plugin manager.
Restart sessions, refresh shell setup where used, and repeat the relevant
checks. Preserve a known-good version before an upgrade; host plugin versions
must be restored through the same manager, not by editing its cache manually.

When requesting support, share versions, host/tool family, event, exit status,
and a minimal synthetic reproduction. Do not attach full settings, environment
dumps, provider patterns, or raw traces. Tool-output masking does not sanitize
files or reports saved separately, and a passing scan does not prove a report
contains no sensitive data. Use [private security reporting](SECURITY.md) for
sensitive findings.

## Upgrading older installations

- **2.x to 3.x:** `managed-install.sh`, `managed-bootstrap.sh` and its checksum
  asset, the separate Codex managed-hook deployment, and
  `setup-shell --prepend-path` were removed. Fleet tooling must stop fetching
  those assets. Use [Managed deployment](#managed-deployment) for Claude and
  the normal plugin installation for Codex. Private gitleaks installs already
  resolve without prepending `PATH`.
- **Legacy shell flags:** current source rejects `--claude-bang-guard`,
  `--experimental-bang-guard`, and unknown `shell-init` arguments with exit `2`
  and no shell snippet. Refresh old managed blocks with
  `agent-guard setup-shell` (or `--no-command-wrapping`). Until refreshed, an
  old invocation may load no `agx`, nudge, or command wrappers. Tool-call hooks
  are separate.
- **GitHub Actions:** update the major tag deliberately (`@v1` → `@v2` → `@v3`),
  or pin an exact release/commit. Scanner checksum requirements remain in place.
