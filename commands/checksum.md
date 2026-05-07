---
allowed-tools: Bash
description: Print the gitleaks release sha256 for a version, formatted for direct paste into a GitHub Actions workflow or `agent-guard setup --install`. Pass an optional VERSION arg, e.g. `/agent-guard:checksum 8.30.1`.
---

# /agent-guard:checksum

Fetches the published `gitleaks_<VER>_checksums.txt` from the gitleaks releases page and emits the sha256 for every supported OS / arch (darwin x64+arm64, linux x64+arm64) plus paste-ready snippets — so users don't have to open the releases page and grep by hand.

## Run

!`sh "${CLAUDE_PLUGIN_ROOT:-.}/scripts/gitleaks-checksum.sh" $ARGUMENTS`

## Interpretation

- **Exit 0** — the script prints all platform `sha256:` entries and emits both the `gitleaks-checksum:` YAML snippet and the `agent-guard setup --install` command; surface them verbatim.
- **`failed to fetch`** — the version probably does not exist. Suggest the user double-check the version on https://github.com/gitleaks/gitleaks/releases.
- **`missing one or more required entries`** — gitleaks doesn't publish a binary for one of the four supported platforms at that version. The script lists the available archive names; relay them.
- **`curl is required`** — instruct the user to install `curl`, then re-run.

Stay terse: the script's output is already shaped for a copy-paste workflow. Avoid restating it.
