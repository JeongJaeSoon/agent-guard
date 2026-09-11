---
allowed-tools: Bash
description: Run a deterministic one-shot secret scan over the repository's pending changes (staged content, unstaged worktree edits, and untracked files; gitignored paths excluded). Use for a quick "does the current state contain secrets?" check without going through hook triggers. It is a point-in-time check, not a gate, so it does not replace the pre-commit hook. For gitignored paths or a tree outside the repository, use `agent-guard scan-path <dir>` instead.
---

# /agent-guard:verify

One-shot secret scan over everything the repository has pending: the worktree (`git diff HEAD`) and the index (`git diff --cached`), **both compared against `HEAD`**, plus untracked files. Backed by the bundled gitleaks rule set the agent-guard hooks already use.

The index is covered. Stage a secret and then restore the file on disk to its `HEAD` contents and the staged copy is still flagged, so the tracked input is a superset of what `agent-guard scan-staged` sees. Keeping `HEAD` as the base for both diffs is what makes that safe in the other direction too: stage the *removal* of a committed secret and then undo it on disk and nothing is reported, because relative to `HEAD` nothing was added. It remains a snapshot of the moment it ran, not a gate: the pre-commit hook runs `scan-staged` at commit time and is what actually blocks a commit.

What it does **not** cover:

- **gitignored paths** — deliberately. Untracked input comes from `git ls-files --others --exclude-standard`, and flagging a local `.env` every run would bury the findings that do matter. "Is there a secret anywhere in this directory?" is a different question: answer it with `agent-guard scan-path <dir>`, which reads the filesystem directly and does cover gitignored paths and trees outside the repository.
- **history** — only content that differs from `HEAD` is diffed. A secret already committed in `HEAD` or an earlier commit is not re-reported here.

## Run

!`"${CLAUDE_PLUGIN_ROOT}/bin/agent-guard" scan-working-tree`

## Interpretation

- **Exit 0, no output beyond the gitleaks summary** → no secrets detected in what was scanned. Say that, not "the directory is clean" or "safe to commit" — gitignored paths and committed history were not covered, and the result goes stale with the next edit. Then stop.
- **Non-zero exit with `agent-guard:` lines** → leaks were flagged. Report the exact file paths and rule names gitleaks emitted, verbatim. Do not propose fixes unless the user asks.
- **`required command not found: gitleaks`** → suggest `agent-guard setup --install --gitleaks-checksum <SHA>` and stop.
- **`gitleaks config not found`** → the plugin install is incomplete; suggest reinstalling or updating Agent Guard through the owning host plugin manager, then reload the host and stop. A standalone bootstrap install does not repair a plugin cache.

Stay terse: the scan output is the answer. Avoid restating what gitleaks already printed.
