"""Relative hook latency with bounded subprocess groups and synthetic inputs."""

import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]
CLI = Path(os.environ.get("AGENT_GUARD_TEST_BINARY", ROOT / "plugins/agent-guard/bin/agent-guard"))
CAP = int(re.search(r"^OUTPUT_SCAN_MAX_BYTES=(\d+)$", CLI.read_text(), re.M)[1])
VALUE = "q7" + "synthetic" * 2
SUFFIX = " API_KEY=" + VALUE
# Leave room for response-object framing and escaped control newlines: the
# output cap applies to serialized response JSON, not just its stdout leaf.
SIZE = CAP - 1024


def event(entry, text, control=False):
    if entry == "protected-path":
        fields = {"file_path": text}
        if control:
            fields = {"file_path": "." + "env", "description": text}
        return "hook-pre-tool", {"tool_name": "Read", "tool_input": fields}
    if entry == "prompt":
        return "hook-user-prompt", {"prompt": text}
    return "hook-post-tool", {
        "tool_name": "Bash", "tool_input": {"command": "cat dump.txt"},
        "tool_response": {"stdout": text, "stderr": "", "interrupted": False},
    }


def measure(command, data, env, limit):
    start = time.monotonic()
    with subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, env=env, start_new_session=True) as proc:
        try:
            out, err = proc.communicate(data, timeout=limit)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.communicate()
            return None, time.monotonic() - start, b"", b""
        return proc.returncode, time.monotonic() - start, out, err


def correct(entry, host, text, result):
    status, _, out, err = result
    if entry == "assignment":
        return status == 0 and out.decode().splitlines() == [json.dumps(VALUE)] and not err
    if VALUE.encode() in out + err:
        return False
    if entry == "protected-path":
        return status == 2 and b"blocked sensitive file access" in err
    if entry == "prompt":
        return status == 2 and not out and b"blocked user prompt: it contains secret-like values" in err
    if status != 0:
        return False
    try:
        obj = json.loads(out)
        # Large secret-bearing responses deliberately mask the whole leaf;
        # every other response field must survive unchanged.
        response = {"stdout": "[REDACTED]", "stderr": "", "interrupted": False}
        if host == "claude":
            return obj == {"hookSpecificOutput": {
                "hookEventName": "PostToolUse", "updatedToolOutput": response}}
        else:
            context = obj["hookSpecificOutput"]["additionalContext"]
            prefix = "Agent Guard sanitized tool output:\n"
            return (context.startswith(prefix)
                    and json.loads(context[len(prefix):]) == response
                    and obj == {
                        "decision": "block",
                        "reason": "Agent Guard blocked the original tool output because it contained sensitive values; use the sanitized replacement in additionalContext.",
                        "hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": context},
                    })
    except (ValueError, KeyError, TypeError):
        return False


def main():
    failed = 0
    required = os.environ.get("AGENT_GUARD_TEST_REQUIRE_AWKS", "").split()
    variants = os.environ.get("AGENT_GUARD_TEST_LONG_INPUT_AWKS", "default mawk gawk busybox").split()
    if (not variants or len(set(variants)) != len(variants)
            or set(variants) - {"default", "mawk", "gawk", "busybox"}
            or set(required) - set(variants)):
        raise SystemExit("invalid or incomplete awk selection")
    with tempfile.TemporaryDirectory(prefix="agent-guard-long-input-") as directory:
        case = Path(directory)
        subprocess.run(["sh", str(ROOT / "tests/helpers/extract-functions.sh"), str(CLI),
                        directory, "secretish_env_values"], check=True)
        driver = case / "assignment.sh"
        driver.write_text('. "$1/secretish_env_values.sh"\nsecretish_env_values\n')
        home = case / "home"
        home.mkdir()
        env = os.environ.copy()
        for name in ("AI_AGENT", "AGENT_GUARD_OUTPUT_REDACT", "AGENT_GUARD_KEY_NAME_REDACT"):
            env.pop(name, None)
        env.update(HOME=str(home), AGENT_GUARD_LOG_MODE="off", AGENT_GUARD_RELEASE_CHECK="off",
                   AGENT_GUARD_PII_HOOK_MODE="off", AGENT_GUARD_PROMPT_GUARD_MODE="block",
                   AGENT_GUARD_INFRA_FAILURE_MODE="closed",
                   AGENT_GUARD_GITLEAKS_BIN=str(ROOT / "tests/fixtures/mock-gitleaks"),
                   AGENT_GUARD_GITLEAKS_CONFIG=str(ROOT / "plugins/agent-guard/config/gitleaks.toml"),
                   AGENT_GUARD_WARNING_DIR=str(case / "warnings"))
        for variant in variants:
            executable = shutil.which("awk" if variant == "default" else variant)
            if executable is None:
                mandatory = variant in required
                print(f"{'not ok' if mandatory else 'ok'} - {variant} unavailable"
                      + ("" if mandatory else " # SKIP"), flush=True)
                failed += mandatory
                continue
            bindir = case / variant
            bindir.mkdir()
            shim = bindir / "awk"
            shim.write_text('#!/bin/sh\nexec "' + executable + '" '
                            + ('awk ' if variant == "busybox" else '') + '"$@"\n')
            shim.chmod(0o755)
            env["PATH"] = str(bindir) + os.pathsep + os.environ["PATH"]
            for entry in ("protected-path", "prompt", "assignment", "output"):
                hosts = ("claude",) if entry == "assignment" else ("claude", "codex")
                for host in hosts:
                    for shape in ("line", "whitespace"):
                        if entry == "protected-path":
                            tail = "/." + "env"
                            candidate = (" " if shape == "whitespace" else "a") * (SIZE - len(tail)) + tail
                            control = candidate
                        else:
                            candidate = (" " if shape == "whitespace" else "a") * (SIZE - len(SUFFIX)) + SUFFIX
                            control = (("a" * 1100 + "\n") * (SIZE // 1101 + 1))[:SIZE - len(SUFFIX)] + SUFFIX
                        assert len(candidate.encode()) == SIZE == len(control.encode())
                        if entry == "output":
                            for text in (candidate, control):
                                response = event(entry, text)[1]["tool_response"]
                                assert CAP - 2048 < len(json.dumps(response).encode()) < CAP
                        env["AGENT_GUARD_HOOK_HOST"] = host
                        if entry == "assignment":
                            command = ["sh", str(driver), directory]
                            encode = lambda text, control=False: text.encode() + b"\x1e\n"
                        else:
                            subcommand, _ = event(entry, candidate)
                            command = [str(CLI), subcommand]
                            encode = lambda text, control=False: json.dumps(event(entry, text, control)[1]).encode()
                        baseline = measure(command, encode(control, True), env, 10)
                        label = f"{variant} {host} {entry} {shape} {SIZE} bytes"
                        if not correct(entry, host, control, baseline):
                            print(f"not ok - {label}: control failed (exit {baseline[0]})", flush=True)
                            failed += 1
                            continue
                        # Match #584's runner-relative allowance; the watchdog bounds
                        # regressions without leaving a detector child behind.
                        limit = baseline[1] * 3 + 5
                        result = measure(command, encode(candidate), env, limit)
                        valid = correct(entry, host, candidate, result)
                        slow = result[0] is None or result[1] > limit
                        known = shape == "whitespace" and entry != "protected-path"
                        timing = f"{result[1]:.3f}s / control {baseline[1]:.3f}s / limit {limit:.3f}s"
                        if slow and known:
                            print(f"not ok - {label}: {timing} # TODO https://github.com/JeongJaeSoon/agent-guard/issues/585", flush=True)
                        elif slow or not valid:
                            print(f"not ok - {label}: {timing}, exit {result[0]}, valid={valid}", flush=True)
                            failed += 1
                        else:
                            print(f"ok - {label}: {timing}", flush=True)
    return bool(failed)


if __name__ == "__main__":
    raise SystemExit(main())
