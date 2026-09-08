---
allowed-tools: Bash
description: Run a deterministic one-shot secret scan over the current working tree (staged + unstaged + untracked, excluding gitignored paths). Use to confirm "is the current state safe to commit?" without going through hook triggers. For gitignored paths or a tree outside the repository, use `agent-guard scan-path <dir>` instead.
---

# /agent-guard:verify

One-shot secret scan over what a commit from here would carry: staged changes, unstaged changes, and untracked files. Backed by the bundled gitleaks rule set the agent-guard hooks already use, so a clean verify here implies the same thing the hooks would say at commit time.

Scope follows that question, so **gitignored paths are deliberately excluded** — a local `.env` is not going to be committed, and flagging it every run would bury the findings that do matter. "Is there a secret anywhere in this directory?" is a different question: answer it with `agent-guard scan-path <dir>`, which reads the filesystem directly and does cover gitignored paths and trees outside the repository.

## Run

!`"${CLAUDE_PLUGIN_ROOT}/bin/agent-guard" scan-working-tree`

## Interpretation

- **Exit 0, no output beyond the gitleaks summary** → no secrets detected in the committable working tree. Say that, not "the directory is clean" — gitignored paths were not scanned. Then stop.
- **Non-zero exit with `agent-guard:` lines** → leaks were flagged. Report the exact file paths and rule names gitleaks emitted, verbatim. Do not propose fixes unless the user asks.
- **`required command not found: gitleaks`** → suggest `agent-guard setup --install --gitleaks-checksum <SHA>` and stop.
- **`gitleaks config not found`** → the plugin install is incomplete; suggest reinstalling via `curl -fsSL https://github.com/JeongJaeSoon/agent-guard/releases/latest/download/bootstrap.sh | sh`.

Stay terse: the scan output is the answer. Avoid restating what gitleaks already printed.
