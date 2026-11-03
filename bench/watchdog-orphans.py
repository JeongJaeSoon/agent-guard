#!/usr/bin/env python3
"""Linux-only isolated check for orphaned scanner-probe descendants."""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=ROOT / "plugins/agent-guard/bin/agent-guard")
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--scanner", type=Path, required=True)
    parser.add_argument("--runs", type=int, default=10)
    args = parser.parse_args()
    if sys.platform != "linux" or args.runs < 1:
        parser.error("Linux and a positive run count are required")
    # Adopt only this experiment's orphaned descendants, then reap them. This
    # makes the observation independent of whether PID 1 reaps children.
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(36, 1, 0, 0, 0) != 0:  # PR_SET_CHILD_SUBREAPER
        raise OSError(ctypes.get_errno(), "subreaper unavailable")
    env = dict(os.environ, AGENT_GUARD_LOG_MODE="off", AGENT_GUARD_RELEASE_CHECK="off",
               AGENT_GUARD_GITLEAKS_BIN=str(args.scanner.resolve()),
               AGENT_GUARD_GITLEAKS_CONFIG=str(ROOT / "plugins/agent-guard/config/gitleaks.toml"))
    binaries = {"baseline": args.baseline.resolve(), "candidate": args.binary.resolve()}
    report = {
        "method": "Linux subreaper; reap adopted descendants after each completed CLI check",
        "runs": args.runs,
        "binary_sha256": {name: hashlib.sha256(binary.read_bytes()).hexdigest()
                          for name, binary in binaries.items()},
        "adopted_children": {},
    }
    for name, binary in binaries.items():
        samples = []
        for _ in range(args.runs):
            subprocess.run([str(binary), "check"], env=env, stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE, check=True, timeout=10)
            adopted = 0
            deadline = time.monotonic() + 3
            while True:
                try:
                    pid, _ = os.waitpid(-1, os.WNOHANG)
                except ChildProcessError:
                    break
                if pid:
                    adopted += 1
                    continue
                if time.monotonic() >= deadline:
                    raise RuntimeError("adopted descendant did not terminate")
                time.sleep(0.01)
            samples.append(adopted)
        report["adopted_children"][name] = samples
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
