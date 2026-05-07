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
	@printf '  make checksum [VERSION=X.Y.Z]   Fetch the gitleaks-checksum to pin in CI.\n'

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
	@sh scripts/gitleaks-checksum.sh $(VERSION)
