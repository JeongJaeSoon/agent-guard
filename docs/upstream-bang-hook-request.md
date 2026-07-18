# Upstream feature request draft — a hook (or output redaction) for `!` bang commands

> **Status: draft.** Agent Guard 2.x mitigates common dump commands with default-on
> command wrapping, but a native upstream hook is still required for complete coverage.
> This is a ready-to-file issue for `anthropics/claude-code`; filing remains a
> maintainer decision.

---

**Title:** Provide a hook (or output-redaction point) for `!` bash-mode / shell-escape commands

**Body:**

### Summary

Claude Code's `!`-prefixed bash-mode commands run in the session shell and their output is
injected into the model's context (wrapped in `<bash-input>` / `<bash-stdout>`), but they
fire **no hook** — not `PreToolUse`, not `PostToolUse`, not `UserPromptSubmit`. This leaves a
gap that hook-based security/guardrail tooling cannot close: a `!`-command that prints a
credential (e.g. `!cat .env`, `!printenv`, `!op read …`) lands in the transcript unmasked,
even when the user has a guardrail that blocks or redacts the exact same access through the
`Bash`/`Read` tools.

### Repro

1. Install any `PreToolUse`/`PostToolUse` hook that blocks or redacts secret access (e.g. a
   hook that blocks `Read`/`Bash` access to `.env` and redacts secrets in tool output).
2. At the prompt, type `!cat .env` (a file containing a secret).
3. Observe: the hook does **not** fire; the raw secret appears in the transcript / model
   context. The same `cat .env` issued as a `Bash` tool call *is* intercepted.

### Why existing extension points don't cover it

- `PreToolUse` / `PostToolUse` — bang commands are not tool calls, so neither fires.
- `UserPromptSubmit` — does not fire for bash-mode input.
- Permission rules (`deny`) — apply to tool calls, not the shell escape.
- Shell-level mitigations (a `preexec`/`DEBUG` trap, or aliasing `cat`) do not work: the trap
  can only warn (it cannot cancel the command or rewrite its captured output), and aliases are
  not applied to bang-command execution.

### Requested options (either would close it)

1. **A pre-exec hook for bang input** — e.g. a `PreBashInput` (or extend `UserPromptSubmit`
   to bash-mode) event that receives the command string and can block with a non-zero exit,
   mirroring `PreToolUse`.
2. **Output redaction for bang output** — run bang stdout/stderr through a
   `PostToolUse`-style `updatedToolOutput` transform before it enters context, so a hook can
   redact secrets in the captured output.

Either makes the `!` channel consistent with the tool channels that hooks already govern.

### Context

This is a known, industry-wide blind spot for hook-based coding-agent guardrails. Related:
[anthropics/claude-code#44868](https://github.com/anthropics/claude-code/issues/44868)
covers tool-path `.env` echoing into the transcript, but does not address the bash-mode
escape specifically — this request is net-new on that axis.
