#!/bin/sh
# Keep the timing harness outside the detector and run the real hook CLI.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
python3 "$ROOT/tests/long-input-budget.py"
exec python3 "$ROOT/tests/long-input.py"
