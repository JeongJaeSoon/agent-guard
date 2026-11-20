#!/usr/bin/env python3
"""Measure the opt-in warm gitleaks helper (#537): hook latency and memory.

    python3 -I bench/gitleaks-helper/measure.py --gitleaks /abs/gitleaks \
        --helper-dir /abs/build [--runs 9] [--out result.json]

Hook latency is measured three ways for each hook: helper off (today's path,
one gitleaks process per scan), on and cold (no helper running: the hook runs
the real gitleaks and starts one), and on and warm. Memory is the helper's
resident set (Linux /proc) when idle, after large inputs and while several
sessions share it, next to the peak resident set of the gitleaks processes
today's path starts. Synthetic inputs only, under a temporary HOME.
"""
import argparse
import json
import os
import shutil
import signal
import statistics
import subprocess
import sys
import tempfile
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
GUARD = os.path.join(ROOT, "plugins", "agent-guard", "bin", "agent-guard")
CFG = os.path.join(ROOT, "plugins", "agent-guard", "config", "gitleaks.toml")


def fill(n, seed):
    return (seed * (n // len(seed) + 1))[:n]


class Bench:
    def __init__(self, args):
        self.args = args
        self.case = tempfile.mkdtemp(prefix="aghb.", dir="/tmp")
        self.home = os.path.join(self.case, "home")
        self.state = os.path.join(self.case, "xs", "agent-guard")
        self.lib = os.path.join(self.case, "lib")
        self.bin = os.path.join(self.case, "bin")
        self.repo = os.path.join(self.case, "repo")
        for d in (self.home, self.state, self.lib, self.bin, os.path.join(self.case, "empty")):
            os.makedirs(d, mode=0o700, exist_ok=True)
        os.chmod(os.path.join(self.case, "xs"), 0o700)
        for name in ("agent-guard-scan", "agent-guard-gitleaks-helper"):
            shutil.copy2(os.path.join(args.helper_dir, name), self.lib)
        shutil.copy2(args.gitleaks, os.path.join(self.bin, "gitleaks"))
        self.client = os.path.join(self.lib, "agent-guard-scan")
        self.env = {
            "HOME": self.home,
            "XDG_STATE_HOME": os.path.join(self.case, "xs"),
            "PATH": self.bin + ":/usr/bin:/bin:/usr/local/bin",
            "AGENT_GUARD_GITLEAKS_BIN_DIR": os.path.join(self.case, "empty"),
            "AGENT_GUARD_RELEASE_CHECK": "off",
            "LC_ALL": "C",
        }
        self.make_repo()
        self.counter = 0

    def make_repo(self):
        os.makedirs(os.path.join(self.repo, "src"))
        os.makedirs(os.path.join(self.repo, "docs"))
        git = ["git", "-C", self.repo]
        run_env = dict(self.env, GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_SYSTEM="/dev/null")
        subprocess.run(["git", "init", "-q", self.repo], check=True, env=run_env)
        source = "".join(f"def handler_{i}(request):\n    return render(request, 'page_{i}.html')\n" for i in range(150))
        with open(os.path.join(self.repo, "src", "app.py"), "w") as f:
            f.write(source)
        subprocess.run(git + ["add", "."], check=True, env=run_env)
        subprocess.run(git + ["-c", "user.email=b@example.test", "-c", "user.name=b", "commit", "-qm", "base"], check=True, env=run_env)
        # 60 changed source lines and an untracked 40-line document.
        changed = source.replace("render(request", "render_template(request", 60)
        with open(os.path.join(self.repo, "src", "app.py"), "w") as f:
            f.write(changed)
        with open(os.path.join(self.repo, "docs", "notes.md"), "w") as f:
            f.write("".join(f"- Note {i}: the handler renders its page template.\n" for i in range(40)))

    def fixture(self, hook):
        self.counter += 1
        n = self.counter
        out2k = "".join(f"line {i} of the build output for step {n}\n" for i in range(60))[:2048]
        if hook == "Bash PreToolUse":
            return "hook-pre-tool", {"hook_event_name": "PreToolUse", "tool_name": "Bash",
                                     "tool_input": {"command": f"git log --oneline -5 -- src/app.py # {n}"}}
        if hook == "Edit PreToolUse":
            new = "".join(f"    value_{i} = compute_{n}({i})\n" for i in range(10))
            return "hook-pre-tool", {"hook_event_name": "PreToolUse", "tool_name": "Edit",
                                     "tool_input": {"file_path": os.path.join(self.repo, "src", "app.py"),
                                                    "old_string": "return", "new_string": new}}
        if hook == "UserPromptSubmit":
            return "hook-user-prompt", {"hook_event_name": "UserPromptSubmit",
                                        "prompt": f"Please refactor the handlers in src/app.py so each one uses the shared template helper, and keep the tests passing ({n})."}
        if hook == "PostToolUse Read":
            return "hook-post-tool", {"hook_event_name": "PostToolUse", "tool_name": "Read",
                                      "tool_input": {"file_path": "src/app.py"},
                                      "tool_response": {"type": "text", "file": {"filePath": "src/app.py", "content": out2k}}}
        if hook == "PostToolUse Bash":
            return "hook-post-tool", {"hook_event_name": "PostToolUse", "tool_name": "Bash",
                                      "tool_input": {"command": "make test"},
                                      "tool_response": {"stdout": out2k, "stderr": "", "interrupted": False}}
        if hook == "PostToolUse Edit":
            return "hook-post-tool", {"hook_event_name": "PostToolUse", "tool_name": "Edit",
                                      "tool_input": {"file_path": os.path.join(self.repo, "src", "app.py"),
                                                     "old_string": "return", "new_string": f"return  # {n}"},
                                      "tool_response": {"filePath": os.path.join(self.repo, "src", "app.py"), "structuredPatch": []}}
        raise ValueError(hook)

    def helper_pids(self):
        out = subprocess.run(["pgrep", "-f", f"agent-guard-gitleaks-helper serve --state-dir {self.state}"],
                             capture_output=True, text=True).stdout
        return [int(p) for p in out.split()]

    def stop_helpers(self):
        for pid in self.helper_pids():
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        deadline = time.time() + 5
        while self.helper_pids() and time.time() < deadline:
            time.sleep(0.05)
        hdir = os.path.join(self.state, "gitleaks-helper")
        if os.path.isdir(hdir):
            for name in os.listdir(hdir):
                os.unlink(os.path.join(hdir, name))

    def wait_helper(self):
        hdir = os.path.join(self.state, "gitleaks-helper")
        deadline = time.time() + 10
        while time.time() < deadline:
            if os.path.isdir(hdir) and any(n.endswith(".sock") for n in os.listdir(hdir)):
                return True
            time.sleep(0.02)
        return False

    def run_hook(self, hook, helper):
        command, payload = self.fixture(hook)
        env = dict(self.env)
        if helper:
            env["AGENT_GUARD_GITLEAKS_HELPER"] = self.client
        start = time.perf_counter()
        proc = subprocess.run([GUARD, command], input=json.dumps(payload).encode(), cwd=self.repo,
                              env=env, capture_output=True)
        elapsed = (time.perf_counter() - start) * 1000
        return elapsed, proc.returncode

    def latency(self, hooks, runs):
        table = {}
        for hook in hooks:
            row = {}
            self.stop_helpers()
            # Prime the probe cache and the CLI's own caches the same way for all modes.
            self.run_hook(hook, False)
            row["off"] = statistics.median(self.run_hook(hook, False)[0] for _ in range(runs))
            cold = []
            for _ in range(runs):
                self.stop_helpers()
                cold.append(self.run_hook(hook, True)[0])
                self.wait_helper()
            row["on_cold"] = statistics.median(cold)
            self.stop_helpers()
            self.run_hook(hook, True)
            self.wait_helper()
            self.run_hook(hook, True)
            row["on_warm"] = statistics.median(self.run_hook(hook, True)[0] for _ in range(runs))
            table[hook] = {k: round(v, 1) for k, v in row.items()}
            print(f"{hook:18s} off {row['off']:7.1f}  cold {row['on_cold']:7.1f}  warm {row['on_warm']:7.1f} ms", flush=True)
        return table

    def rss_kib(self, pid):
        values = {}
        with open(f"/proc/{pid}/status") as f:
            for line in f:
                key, _, value = line.partition(":")
                if key in ("VmRSS", "VmHWM"):
                    values[key] = int(value.split()[0])
        return values

    def client_scan(self, data, cwd=None, regular=True):
        argv = [self.client, "--gitleaks", os.path.join(self.bin, "gitleaks"), "--gitleaks-version", "8.30.1",
                "--state-dir", self.state, "--", "stdin", "--redact", "--no-banner", "--no-color",
                "--log-level", "error", "--config", CFG, "--exit-code", "1"]
        env = dict(self.env, AGENT_GUARD_GITLEAKS_HELPER_TRACE=os.path.join(self.case, "trace"))
        if regular:
            path = os.path.join(self.case, f"input.{threading.get_ident()}")
            with open(path, "wb") as f:
                f.write(data)
            with open(path, "rb") as stdin:
                return subprocess.run(argv, stdin=stdin, env=env, cwd=cwd or self.case, capture_output=True).returncode
        return subprocess.run(argv, input=data, env=env, cwd=cwd or self.case, capture_output=True).returncode

    def peak_child_rss(self, argv, data):
        """Peak resident set (KiB) of one process, from wait4's rusage."""
        path = os.path.join(self.case, "peak-input")
        with open(path, "wb") as f:
            f.write(data)
        with open(path, "rb") as stdin:
            proc = subprocess.Popen(argv, stdin=stdin, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=self.env)
            _, _, usage = os.wait4(proc.pid, 0)
        return usage.ru_maxrss if sys.platform != "darwin" else usage.ru_maxrss // 1024

    def memory(self):
        result = {}
        small = b"".join(b"line %d of the build output\n" % i for i in range(70))
        clean_1m = b"".join(b"padding line %d of a large clean log file\n" % i for i in range(24000))[: (1 << 20) - 64]
        pat = ("gh" + "p_" + fill(36, "a1B2c3D4e5F6g7H8i9J0")).encode()
        dense = b"".join(b"key_%d = %s%d\n" % (i, pat[:-4], 1000 + i % 9000) for i in range(6000))[: 300 * 1024]
        gl = os.path.join(self.bin, "gitleaks")
        real_args = [gl, "stdin", "--redact", "--no-banner", "--no-color", "--log-level", "error", "--config", CFG, "--exit-code", "1"]
        # A forked child's peak includes this Python process until exec, so
        # report that floor too; values at the floor are not the child's own.
        result["peak_floor_kib_true"] = self.peak_child_rss(["/bin/true"], b"")
        result["per_call_gitleaks_peak_kib"] = {
            "2KB": self.peak_child_rss(real_args, small),
            "1MiB clean": self.peak_child_rss(real_args, clean_1m),
            "300KB dense secrets": self.peak_child_rss(real_args, dense),
        }
        self.stop_helpers()
        self.client_scan(small)
        self.wait_helper()
        self.client_scan(small)
        pid = self.helper_pids()[0]
        result["client_peak_kib"] = self.peak_child_rss(
            [self.client, "--gitleaks", gl, "--gitleaks-version", "8.30.1", "--state-dir", self.state, "--"] + real_args[1:], small)
        time.sleep(1)
        result["helper_idle_after_first_scans"] = self.rss_kib(pid)
        for _ in range(50):
            self.client_scan(small)
        result["helper_after_50_small_scans"] = self.rss_kib(pid)
        for _ in range(5):
            self.client_scan(clean_1m)
        result["helper_after_5_x_1MiB_clean"] = self.rss_kib(pid)
        for _ in range(3):
            self.client_scan(dense)
        result["helper_after_3_x_300KB_dense"] = self.rss_kib(pid)
        time.sleep(2)
        result["helper_idle_2s_later"] = self.rss_kib(pid)

        def session(index):
            work = os.path.join(self.case, f"session{index}")
            os.makedirs(work, exist_ok=True)
            for i in range(25):
                self.client_scan(small + b"%d %d\n" % (index, i), cwd=work)
        threads = [threading.Thread(target=session, args=(i,)) for i in range(4)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        result["helpers_after_4_sessions"] = len(self.helper_pids())
        result["helper_after_4_sessions_x_25_scans"] = self.rss_kib(pid)
        result["helper_same_process_throughout"] = self.helper_pids() == [pid]
        with open(os.path.join(self.case, "trace")) as f:
            words = f.read().split()
        result["trace_counts"] = {w: words.count(w) for w in sorted(set(words))}
        self.stop_helpers()
        return result

    def startup(self, runs):
        """Time from spawn to a listening socket, and the first warm answer."""
        ready, first = [], []
        small = b"ls -la\n"
        for _ in range(runs):
            self.stop_helpers()
            start = time.perf_counter()
            self.client_scan(small)
            self.wait_helper()
            ready.append((time.perf_counter() - start) * 1000)
            start = time.perf_counter()
            self.client_scan(small)
            first.append((time.perf_counter() - start) * 1000)
        self.stop_helpers()
        return {"spawn_to_socket_ms": round(statistics.median(ready), 1),
                "first_warm_scan_ms": round(statistics.median(first), 1)}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--gitleaks", required=True)
    parser.add_argument("--helper-dir", required=True)
    parser.add_argument("--runs", type=int, default=9)
    parser.add_argument("--out")
    args = parser.parse_args()
    bench = Bench(args)
    try:
        hooks = ["Bash PreToolUse", "Edit PreToolUse", "UserPromptSubmit",
                 "PostToolUse Read", "PostToolUse Bash", "PostToolUse Edit"]
        result = {
            "machine": " ".join(os.uname()),
            "cpus": os.cpu_count(),
            "runs": args.runs,
            "latency_ms_median": bench.latency(hooks, args.runs),
            "startup": bench.startup(5),
        }
        if sys.platform.startswith("linux"):
            result["memory"] = bench.memory()
        text = json.dumps(result, indent=1)
        print(text)
        if args.out:
            with open(args.out, "w") as f:
                f.write(text + "\n")
    finally:
        bench.stop_helpers()
        shutil.rmtree(bench.case, ignore_errors=True)


if __name__ == "__main__":
    main()
