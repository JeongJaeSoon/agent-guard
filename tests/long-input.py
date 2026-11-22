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


def measure(command, data, env, limit, deadline):
    start = time.monotonic()
    limit = min(limit, deadline - start)
    if limit <= 0:
        raise SystemExit("not ok - long-input suite time budget exhausted")
    with subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, env=env, start_new_session=True) as proc:
        try:
            out, err = proc.communicate(data, timeout=limit)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            proc.communicate()
            if time.monotonic() >= deadline:
                raise SystemExit("not ok - long-input suite time budget exhausted")
            return None, time.monotonic() - start, b"", b""
        if time.monotonic() >= deadline:
            raise SystemExit("not ok - long-input suite time budget exhausted")
        return proc.returncode, time.monotonic() - start, out, err


def correct(entry, host, text, result, whole_leaf=False):
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
        # Only the large fixtures take the deliberate whole-leaf mask path.
        masked = "[REDACTED]" if whole_leaf else text.replace(VALUE, "[REDACTED]")
        response = {"stdout": masked, "stderr": "", "interrupted": False}
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


def inputs(entry, shape, size):
    if entry == "protected-path":
        tail = "/." + "env"
        candidate = (" " if shape == "whitespace" else "a") * (size - len(tail)) + tail
        control = candidate
    else:
        candidate = (" " if shape == "whitespace" else "a") * (size - len(SUFFIX)) + SUFFIX
        control = (("a" * 1100 + "\n") * (size // 1101 + 1))[:size - len(SUFFIX)] + SUFFIX
    assert len(candidate.encode()) == size == len(control.encode())
    return candidate, control


def main():
    deadline = time.monotonic() + 90
    required = os.environ.get("AGENT_GUARD_TEST_REQUIRE_AWKS", "").split()
    variants = os.environ.get("AGENT_GUARD_TEST_LONG_INPUT_AWKS", "default mawk gawk busybox").split()
    if (not variants or len(set(variants)) != len(variants)
            or set(variants) - {"default", "mawk", "gawk", "busybox"}
            or set(required) - set(variants)):
        raise SystemExit("invalid or incomplete awk selection")
    with tempfile.TemporaryDirectory(prefix="agent-guard-long-input-") as directory:
        case = Path(directory)
        subprocess.run(["sh", str(ROOT / "tests/helpers/extract-functions.sh"), str(CLI),
                        directory, "secretish_env_values"], check=True, timeout=10)
        driver = case / "assignment.sh"
        driver.write_text('. "$1/secretish_env_values.sh"\nsecretish_env_values\n')
        home = case / "home"
        home.mkdir()
        child_tmp = case / "tmp"
        child_tmp.mkdir()
        env = os.environ.copy()
        for name in ("AI_AGENT", "AGENT_GUARD_OUTPUT_REDACT", "AGENT_GUARD_KEY_NAME_REDACT"):
            env.pop(name, None)
        env.update(HOME=str(home), TMPDIR=str(child_tmp),
                   AGENT_GUARD_LOG_MODE="off", AGENT_GUARD_RELEASE_CHECK="off",
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
                if mandatory:
                    return 1
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
                        candidate, control = inputs(entry, shape, SIZE)
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
                        label = f"{variant} {host} {entry} {shape} {SIZE} bytes"
                        small_candidate, small_control = inputs(entry, shape, SIZE // 4)
                        small = measure(command, encode(small_control, True), env, 10, deadline)
                        if not correct(entry, host, small_control, small):
                            print(f"not ok - {label}: small control failed (exit {small[0]})", flush=True)
                            return 1
                        # Four times the bytes may cost at most twice as much
                        # per byte, plus one second for process-start noise.
                        scaling_limit = small[1] * 8 + 1
                        baseline = measure(command, encode(control, True), env, scaling_limit, deadline)
                        if (not correct(entry, host, control, baseline, whole_leaf=True)
                                or baseline[1] > scaling_limit):
                            print(f"not ok - {label}: large control exceeds scaling budget or has wrong output "
                                  f"({baseline[1]:.3f}s / small {small[1]:.3f}s / limit {scaling_limit:.3f}s, "
                                  f"exit {baseline[0]})", flush=True)
                            return 1
                        known = shape == "whitespace" and entry != "protected-path"
                        candidate_small_time = None
                        if known:
                            short, _ = inputs(entry, shape, 2048)
                            short_result = measure(command, encode(short), env, small[1] * 8 + 1, deadline)
                            if not correct(entry, host, short, short_result):
                                print(f"not ok - {label}: small whitespace verdict failed "
                                      f"(exit {short_result[0]})", flush=True)
                                return 1
                            print(f"ok - {variant} {host} {entry} small whitespace verdict", flush=True)
                            limit = min(baseline[1] * 3 + 1, 2)
                        else:
                            # A real file_path costs more than ignored metadata.
                            # Retain the candidate's hook, input field and shape.
                            sample = measure(command, encode(small_candidate), env, scaling_limit, deadline)
                            if not correct(entry, host, small_candidate, sample):
                                print(f"not ok - {label}: small candidate failed (exit {sample[0]})", flush=True)
                                return 1
                            candidate_small_time = sample[1]
                            limit = candidate_small_time * 8 + 1
                        result = measure(command, encode(candidate), env, limit, deadline)
                        valid = correct(entry, host, candidate, result, whole_leaf=True)
                        slow = result[0] is None or result[1] > limit
                        timing = (f"{result[1]:.3f}s / control {baseline[1]:.3f}s / limit {limit:.3f}s "
                                  f"/ small {small[1]:.3f}s / scaling limit {scaling_limit:.3f}s")
                        if candidate_small_time is not None:
                            timing += f" / candidate small {candidate_small_time:.3f}s"
                        if slow and known:
                            print(f"not ok - {label}: {timing} # TODO https://github.com/JeongJaeSoon/agent-guard/issues/585", flush=True)
                        elif slow or not valid:
                            print(f"not ok - {label}: {timing}, exit {result[0]}, valid={valid}", flush=True)
                            return 1
                        else:
                            print(f"ok - {label}: {timing}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
