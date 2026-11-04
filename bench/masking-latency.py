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
    cases.append(("exec-clean", "exec", texts["small-clean"], texts["small-clean"]))
    # Exercise framing rather than only its small, single-line secret records.
    value = " API_KEY='" + "a" * 30000 + "\n" + "b" * 30000 + "'"
    cases.append(("exec-long-quoted-secret", "exec", value, " API_KEY='[REDACTED]'"))
    # Benign controls must stay byte-for-byte unchanged, even next to keywords.
    for name, value in {
        "placeholder-control": "API_KEY=example_token",
        "metadata-control": "password_policy=strict token_name=counter",
        "prose-control": "error: password: authentication is disabled",
    }.items():
        cases.append((name, "hook", value, value))
    # The scan cap applies AFTER exec captures output. These cases measure
    # that existing memory constraint without changing its masking policy.
    for size in (1048576, 8388608):
        cases.append(("exec-over-cap-%d" % size, "exec", "a" * size, "[REDACTED]"))
    return cases


def boundary_fixtures():
    return [
        ("pre-read-clean", "pre", {"tool_name": "Read", "tool_input": {"file_path": "README.md"}}, ""),
        ("pre-read-placeholder", "pre", {"tool_name": "Read", "tool_input": {"file_path": ".env.example"}}, ""),
        ("pre-bash-clean", "pre", {"tool_name": "Bash", "tool_input": {"command": "printf 'build passed'"}}, ""),
        ("pre-git-status", "pre", {"tool_name": "Bash", "tool_input": {"command": "git status"}}, ""),
        ("pre-unknown-tool", "pre", {"tool_name": "future_tool", "tool_input": {}}, ""),
        ("prompt-clean", "prompt", {"prompt": "Explain the build output"}, ""),
    ]


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
    parser.add_argument("--native-core", type=Path, help="opt candidate into Rust; baseline stays shell")
    parser.add_argument("--host", choices=("claude", "codex"), default="claude")
    parser.add_argument("--scanner", type=Path, default=shutil.which("gitleaks"))
    parser.add_argument("--runs", type=int, default=5)
    parser.add_argument("--timeout", type=float, default=30)
    parser.add_argument("--resources", action="store_true",
                        help="isolate each CLI tree and collect POSIX CPU/RSS accounting")
    parser.add_argument("--include-boundaries", action="store_true",
                        help="also measure benign pre-tool and user-prompt boundaries")
    parser.add_argument("--trace-processes", action="store_true",
                        help="collect a separate Linux strace sample; never time traced runs")
    parser.add_argument("--case", action="append", dest="selected_cases",
                        help="run only this named fixture; repeat to select several")
    args = parser.parse_args()
    if args.runs < 1 or args.timeout <= 0:
        parser.error("runs and timeout must be positive")
    if args.scanner is None or not shutil.which("jq"):
        parser.error("real gitleaks and jq are required")
    if args.trace_processes and (sys.platform != "linux" or not shutil.which("strace")):
        parser.error("process tracing requires Linux and strace")
    binaries = {"candidate": args.binary.resolve()}
    if args.baseline:
        binaries = {"baseline": args.baseline.resolve(), **binaries}
    scanner = Path(args.scanner).resolve()
    env = dict(os.environ, AGENT_GUARD_LOG_MODE="off", AGENT_GUARD_RELEASE_CHECK="off",
               AGENT_GUARD_HOOK_HOST=args.host,
               AGENT_GUARD_PII_HOOK_MODE="off", AGENT_GUARD_OUTPUT_REDACT="mask",
               AGENT_GUARD_GITLEAKS_BIN=str(scanner),
               AGENT_GUARD_GITLEAKS_CONFIG=str(ROOT / "plugins/agent-guard/config/gitleaks.toml"))
    report = {
        "platform": platform.platform(), "runs": args.runs, "host": args.host,
        "native_core_sha256": hashlib.sha256(args.native_core.read_bytes()).hexdigest() if args.native_core else None,
        "scanner_version": subprocess.check_output([str(scanner), "version"], text=True).strip(),
        "binary_sha256": {name: hashlib.sha256(path.read_bytes()).hexdigest()
                          for name, path in binaries.items()},
        "scanner_sha256": hashlib.sha256(scanner.read_bytes()).hexdigest(),
        "config_sha256": hashlib.sha256(Path(env["AGENT_GUARD_GITLEAKS_CONFIG"]).read_bytes()).hexdigest(),
        "jq_version": subprocess.check_output(["jq", "--version"], text=True).strip(),
        "python_version": platform.python_version(),
        "logical_cpu_count": os.cpu_count(),
        "readiness_cache": "disabled with audit logging", "cases": [],
        "resources": ("CPU includes waited-for descendants; RSS is the maximum individual "
                      "child peak, not simultaneous tree memory") if args.resources else None,
    }
    with tempfile.TemporaryDirectory(prefix="agent-guard-masking-latency-") as directory:
        cases = fixtures() + (boundary_fixtures() if args.include_boundaries else [])
        if args.selected_cases:
            missing = set(args.selected_cases) - {case[0] for case in cases}
            if missing:
                parser.error("unknown fixtures: " + ", ".join(sorted(missing)))
            cases = [case for case in cases if case[0] in args.selected_cases]
        for name, route, value, expected in cases:
            samples = {label: [] for label in binaries}
            resources = {label: [] for label in binaries}
            processes = {}
            event = {"tool_name": "mcp__latency__read", "tool_response": value} if route == "hook" else value
            payload = json.dumps(event,
                                 separators=(",", ":")).encode()
            source = Path(directory) / "synthetic-output"
            if route == "exec":
                source.write_text(value)
            for sample in range(args.runs + int(args.trace_processes)):
                tracing = sample == args.runs
                # Alternate order so warm filesystem state does not always favor
                # the candidate; every measured invocation must verify output.
                order = list(binaries.items())
                if sample % 2:
                    order.reverse()
                for label, binary in order:
                    subcommand = {"hook": "hook-post-tool", "pre": "hook-pre-tool",
                                  "prompt": "hook-user-prompt"}.get(route)
                    command = [str(binary), subcommand] if subcommand else [
                        str(binary), "exec", "--", "cat", str(source)]
                    resource_file = Path(directory) / "resources.json"
                    trace_file = Path(directory) / "processes.trace"
                    if tracing:
                        command = ["strace", "-f", "-qq", "-e", "trace=process",
                                   "-o", str(trace_file), *command]
                    elif args.resources:
                        resource_file.unlink(missing_ok=True)
                        command = [sys.executable, str(ROOT / "bench/resource-sample.py"),
                                   str(resource_file), *command]
                    try:
                        run_env = dict(env)
                        run_env["AGENT_GUARD_EXPERIMENTAL_REDACTOR"] = "shell"
                        if label == "candidate" and args.native_core:
                            run_env.update(AGENT_GUARD_EXPERIMENTAL_REDACTOR="rust",
                                           AGENT_GUARD_RUST_CORE_BIN=str(args.native_core.resolve()))
                        elapsed, output = invoke(command, payload if route != "exec" else b"",
                                                 run_env, directory, args.timeout)
                    except RuntimeError as error:
                        raise RuntimeError(label + ": " + name + ": " + str(error)) from None
                    if args.resources and not tracing:
                        usage = json.loads(resource_file.read_text())
                        elapsed = usage.pop("wall_seconds")
                        resources[label].append(usage)
                    if route == "exec":
                        valid = output == (expected + "\n").encode()
                    elif route in ("pre", "prompt"):
                        valid = output == expected.encode()
                    elif expected == value:
                        valid = output == b""
                    else:
                        try:
                            envelope = json.loads(output)
                            if args.host == "codex":
                                context = envelope["hookSpecificOutput"]["additionalContext"]
                                prefix = "Agent Guard sanitized tool output:\n"
                                valid = (envelope["decision"] == "block" and context.startswith(prefix)
                                         and json.loads(context[len(prefix):]) == expected)
                            else:
                                valid = envelope["hookSpecificOutput"]["updatedToolOutput"] == expected
                        except (ValueError, KeyError, TypeError):
                            valid = False
                    if not valid:
                        raise RuntimeError(label + ": incorrect masking output for " + name)
                    if tracing:
                        # Count attempted execs, and separate runtime threads
                        # from process creation. strace output may split calls
                        # into unfinished/resumed lines; count only call starts.
                        trace = trace_file.read_text()
                        processes[label] = {
                            "execve_calls": trace.count("execve(") + trace.count("execveat("),
                            "process_creation_calls": sum(
                                any(call in line for call in ("clone(", "clone3(", "fork(", "vfork("))
                                and "CLONE_THREAD" not in line for line in trace.splitlines()),
                            "thread_creation_calls": sum(
                                any(call in line for call in ("clone(", "clone3("))
                                and "CLONE_THREAD" in line for line in trace.splitlines()),
                        }
                        trace_file.unlink()
                        continue
                    samples[label].append(elapsed)
                    print("%s %s %.3fs" % (label, name, elapsed), file=sys.stderr, flush=True)
            row = {"name": name, "route": route,
                   "input_bytes": len(payload) if route != "exec" else len(value.encode()),
                   "verified": True, "seconds": {}}
            for label, times in samples.items():
                row["seconds"][label] = {"median": statistics.median(times), "max": max(times),
                                         "samples": times}
            if "baseline" in samples:
                row["speedup"] = statistics.median(samples["baseline"]) / statistics.median(samples["candidate"])
            if args.resources:
                row["resource_usage"] = {
                    label: {metric: {"median": statistics.median(s[metric] for s in values),
                                     "max": max(s[metric] for s in values),
                                     "samples": [s[metric] for s in values]}
                            for metric in values[0]}
                    for label, values in resources.items()
                }
            if args.trace_processes:
                row["process_profile"] = processes
            report["cases"].append(row)
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
