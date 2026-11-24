#!/bin/sh
# See tests/colon-assignment-equivalence.py.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
exec python3 "$ROOT/tests/colon-assignment-equivalence.py"
