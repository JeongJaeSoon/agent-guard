---
allowed-tools: Bash
description: Print the gitleaks release sha256 for a version, formatted for direct paste into a GitHub Actions workflow or `agent-guard setup --install`. Pass an optional VERSION arg, e.g. `/agent-guard:checksum 8.30.1`.
---

# /agent-guard:checksum

Fetches the published `gitleaks_<VER>_checksums.txt` from the gitleaks releases page and emits the sha256 entry matching the user's OS / arch — so they don't have to open the releases page and grep by hand.

## Run

!`"${CLAUDE_PLUGIN_ROOT:-.}/bin/agent-guard" checksum $ARGUMENTS`

## Interpretation

- **Exit 0** — the script printed `sha256: <hex>` plus a `gitleaks-checksum:` YAML snippet and an `agent-guard setup --install` command line. Surface both snippets to the user verbatim. Do not modify them.
- **`failed to fetch`** — the version probably does not exist. Suggest the user double-check the version on https://github.com/gitleaks/gitleaks/releases.
- **`no entry for ...`** — the user's OS / arch is not among gitleaks' prebuilt releases. The script lists the available archive names; relay them.
- **`curl is required`** — instruct the user to install `curl`, then re-run.

Stay terse: the script's output is already shaped for a copy-paste workflow. Avoid restating it.
