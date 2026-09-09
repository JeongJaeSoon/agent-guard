---
allowed-tools: Bash
description: Run a deterministic one-shot secret scan over the working tree as it exists on disk (tracked changes against HEAD, plus untracked files; gitignored paths excluded). Use for a quick "does the current state contain secrets?" check without going through hook triggers. It reads the worktree, not the index, so it does not replace the pre-commit hook. For gitignored paths or a tree outside the repository, use `agent-guard scan-path <dir>` instead.
---

# /agent-guard:verify

One-shot secret scan over the working tree as it exists on disk: tracked files diffed against `HEAD`, plus untracked files. Backed by the bundled gitleaks rule set the agent-guard hooks already use.

Two things it does **not** cover:

- **gitignored paths** — deliberately. Untracked input comes from `git ls-files --others --exclude-standard`, and flagging a local `.env` every run would bury the findings that do matter. "Is there a secret anywhere in this directory?" is a different question: answer it with `agent-guard scan-path <dir>`, which reads the filesystem directly and does cover gitignored paths and trees outside the repository.
- **the index** — tracked input comes from `git diff HEAD`, which compares the worktree to `HEAD`, not `git diff --cached`. Stage a secret and then restore the file on disk to its `HEAD` contents and this scan reports clean while the staged content still holds it. The pre-commit hook runs `agent-guard scan-staged` against the index, so a clean result here does not stand in for it.

## Run

!`"${CLAUDE_PLUGIN_ROOT}/bin/agent-guard" scan-working-tree`

## Interpretation

- **Exit 0, no output beyond the gitleaks summary** → no secrets detected in what was scanned. Say that, not "the directory is clean" or "safe to commit" — gitignored paths and the index were not covered. Then stop.
- **Non-zero exit with `agent-guard:` lines** → leaks were flagged. Report the exact file paths and rule names gitleaks emitted, verbatim. Do not propose fixes unless the user asks.
- **`required command not found: gitleaks`** → suggest `agent-guard setup --install --gitleaks-checksum <SHA>` and stop.
- **`gitleaks config not found`** → the plugin install is incomplete; suggest reinstalling via `curl -fsSL https://github.com/JeongJaeSoon/agent-guard/releases/latest/download/bootstrap.sh | sh`.

Stay terse: the scan output is the answer. Avoid restating what gitleaks already printed.
