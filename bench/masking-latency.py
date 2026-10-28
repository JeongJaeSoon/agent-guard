#!/usr/bin/env python3
"""Opt-in paired latency measurement with synthetic output correctness gates."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import signal
import statistics
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent


def fixtures():
    literal = "perf-literal-tail"
    suffix = " API_KEY=" + literal
    texts = {
        "small-clean": "ordinary status: build passed",
        "long-line": "a" * 260000 + suffix,
        "long-multiline": "a" * 260000 + "\n" + suffix,
        "escaped-control": "a" * 130000 + "\x1e" + "b" * 130000 + suffix,
        "many-lines": "ordinary status: build passed\n" * 8000 + suffix,
    }
    cases = []
    for name, value in texts.items():
        expected = value.replace(literal, "[REDACTED]")
        cases.append((name, "hook", value, expected))
    values = ["API_KEY=perf-literal-%03d" % i for i in range(100)] + ["status"] * 4000
    expected = ["API_KEY=[REDACTED]"] * 100 + ["status"] * 4000
    cases.append(("many-replacement-leaves", "hook", values, expected))
    # Above the existing large-assignment threshold, the safe result is one
    # whole-leaf replacement. Timing still includes the complete framing probe.
    cases.append(("dense-controls", "hook", "a\x1f" * 40000 + suffix, "[REDACTED]"))
    cases.append(("exec-multiline", "exec", texts["long-multiline"],
                  texts["long-multiline"].replace(literal, "[REDACTED]")))
    return cases


def invoke(command, payload, env, directory, timeout):
    start = time.perf_counter()
    process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, env=env, cwd=directory,
                               start_new_session=True)
    try:
        stdout, _ = process.communicate(payload, timeout=timeout)
    except BaseException as error:
        # Also reap the private process group when the measurement is interrupted.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.communicate()
        if isinstance(error, subprocess.TimeoutExpired):
            raise RuntimeError("measurement timed out") from None
        raise
    elapsed = time.perf_counter() - start
    if process.returncode != 0:
        raise RuntimeError("command exited with status %s" % process.returncode)
    return elapsed, stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=ROOT / "plugins/agent-guard/bin/agent-guard")
    parser.add_argument("--baseline", type=Path)
    parser.add_argument("--scanner", type=Path, default=shutil.which("gitleaks"))
    parser.add_argument("--runs", type=int, default=5)
    parser.add_argument("--timeout", type=float, default=30)
    args = parser.parse_args()
    if args.runs < 1 or args.timeout <= 0:
        parser.error("runs and timeout must be positive")
    if args.scanner is None or not shutil.which("jq"):
        parser.error("real gitleaks and jq are required")
    binaries = {"candidate": args.binary.resolve()}
    if args.baseline:
        binaries = {"baseline": args.baseline.resolve(), **binaries}
    scanner = Path(args.scanner).resolve()
    env = dict(os.environ, AGENT_GUARD_LOG_MODE="off", AGENT_GUARD_RELEASE_CHECK="off",
               AGENT_GUARD_HOOK_HOST="claude",
               AGENT_GUARD_PII_HOOK_MODE="off", AGENT_GUARD_OUTPUT_REDACT="mask",
               AGENT_GUARD_GITLEAKS_BIN=str(scanner),
               AGENT_GUARD_GITLEAKS_CONFIG=str(ROOT / "plugins/agent-guard/config/gitleaks.toml"))
    report = {
        "platform": platform.platform(), "runs": args.runs,
        "scanner_version": subprocess.check_output([str(scanner), "version"], text=True).strip(),
        "binary_sha256": {name: hashlib.sha256(path.read_bytes()).hexdigest()
                          for name, path in binaries.items()},
        "readiness_cache": "disabled with audit logging", "cases": [],
    }
    with tempfile.TemporaryDirectory(prefix="agent-guard-masking-latency-") as directory:
        for name, route, value, expected in fixtures():
            samples = {label: [] for label in binaries}
            payload = json.dumps({"tool_name": "mcp__latency__read", "tool_response": value},
                                 separators=(",", ":")).encode()
            source = Path(directory) / "synthetic-output"
            if route == "exec":
                source.write_text(value)
            for sample in range(args.runs):
                # Alternate order so warm filesystem state does not always favor
                # the candidate; every measured invocation must verify output.
                order = list(binaries.items())
                if sample % 2:
                    order.reverse()
                for label, binary in order:
                    command = [str(binary), "hook-post-tool"] if route == "hook" else [
                        str(binary), "exec", "--", "cat", str(source)]
                    elapsed, output = invoke(command, payload if route == "hook" else b"",
                                             env, directory, args.timeout)
                    if route == "exec":
                        valid = output == (expected + "\n").encode()
                    elif expected == value:
                        valid = output == b""
                    else:
                        try:
                            valid = json.loads(output)["hookSpecificOutput"]["updatedToolOutput"] == expected
                        except (ValueError, KeyError, TypeError):
                            valid = False
                    if not valid:
                        raise RuntimeError(label + ": incorrect masking output for " + name)
                    samples[label].append(elapsed)
                    print("%s %s %.3fs" % (label, name, elapsed), file=sys.stderr, flush=True)
            row = {"name": name, "route": route,
                   "input_bytes": len(payload) if route == "hook" else len(value.encode()),
                   "verified": True, "seconds": {}}
            for label, times in samples.items():
                row["seconds"][label] = {"median": statistics.median(times), "max": max(times),
                                         "samples": times}
            if "baseline" in samples:
                row["speedup"] = statistics.median(samples["baseline"]) / statistics.median(samples["candidate"])
            report["cases"].append(row)
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
