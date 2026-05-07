---
allowed-tools: Bash
description: Run a deterministic one-shot secret scan over the current working tree (staged + unstaged + untracked). Use to confirm "is the current state safe to commit?" without going through hook triggers.
---

# /agent-guard:verify

One-shot secret scan over everything currently on disk: staged changes, unstaged changes, and untracked files. Backed by the bundled gitleaks rule set the agent-guard hooks already use, so a clean verify here implies the same thing the hooks would say at commit time.

## Run

!`"${CLAUDE_PLUGIN_ROOT:-.}/bin/agent-guard" scan-working-tree`

## Interpretation

- **Exit 0, no output beyond the gitleaks summary** → no secrets detected. Tell the user the working tree is clean and stop.
- **Non-zero exit with `agent-guard:` lines** → leaks were flagged. Report the exact file paths and rule names gitleaks emitted, verbatim. Do not propose fixes unless the user asks.
- **`required command not found: gitleaks`** → suggest `agent-guard setup --install --gitleaks-checksum <SHA>` and stop.
- **`gitleaks config not found`** → the plugin install is incomplete; suggest reinstalling via `curl -fsSL https://github.com/JeongJaeSoon/agent-guard/releases/latest/download/bootstrap.sh | sh`.

Stay terse: the scan output is the answer. Avoid restating what gitleaks already printed.
