# Agent Guard — discoverability layer for the existing scripts.
# Each target is a thin pass-through to install.sh or bin/agent-guard.

.PHONY: help check install test scan scan-staged checksum

help:
	@printf 'Agent Guard — make targets\n'
	@printf '\n'
	@printf '  make help          Show this list (default).\n'
	@printf '  make check         Verify deps and print installed gitleaks version.\n'
	@printf '  make install       Configure the native git pre-commit hook.\n'
	@printf '  make test          Run the test suite (uses a mock gitleaks).\n'
	@printf '  make scan          Scan the working tree for secrets.\n'
	@printf '  make scan-staged   Scan staged changes only.\n'
	@printf '  make checksum      How to pin a gitleaks-checksum for CI.\n'

check:
	@./install.sh check

install:
	@./install.sh git-hooks

test:
	@tests/run.sh

scan:
	@bin/agent-guard scan-working-tree

scan-staged:
	@bin/agent-guard scan-staged

checksum:
	@printf 'To pin gitleaks-checksum for the GitHub Action input:\n'
	@printf '  1. Pick a gitleaks release (e.g. 8.30.1) — see action.yml default.\n'
	@printf '  2. Download the checksums file from:\n'
	@printf '       https://github.com/gitleaks/gitleaks/releases/download/v<VER>/gitleaks_<VER>_checksums.txt\n'
	@printf '  3. Find the line matching gitleaks_<VER>_<os>_<arch>.tar.gz and copy its sha256.\n'
	@printf '  4. Pass that sha256 as the gitleaks-checksum input in your workflow.\n'
