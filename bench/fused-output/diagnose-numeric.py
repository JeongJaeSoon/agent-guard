#!/usr/bin/env python3
"""기존 거대 숫자 fallback fixture의 원본/계측 경로를 각각 한 번 보존한다."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time

source, destination = map(Path, sys.argv[1:3])
destination.mkdir(parents=True, exist_ok=False)
source = source.resolve()
destination = destination.resolve()
fixture = destination / "response.json"
fixture.write_text("[" + ",".join(["9876543210123456,true"] * 480000) + "]")
envelope = destination / "envelope.json"
envelope.write_text('{"tool_name":"Read","tool_input":{},"tool_response":[]}')
wrapper = destination / "tools"
wrapper.mkdir()
real_jq = shutil.which("jq")
assert real_jq
(wrapper / "jq").write_text('''#!/bin/sh
case "$*" in
  *".tool_response // empty"*) cat "$AGENT_GUARD_TEST_RESPONSE_FILE"; exit 0 ;;
  *'(index("\\u0000") != null)'*) exit 2 ;;
esac
case " $* " in *"length > 0"*) exit 2 ;; esac
exec "$AGENT_GUARD_TEST_REAL_JQ" "$@"
''')
(wrapper / "jq").chmod(0o755)
if os.environ.get("AG_NUMERIC_TIME_CHILDREN") == "1":
    timed = destination / "child-times"
    timed.mkdir()
    time_flags = "-l" if sys.platform == "darwin" else "-v"
    for tool in ["awk", "jq"]:
        real = shutil.which(tool)
        assert real
        target = wrapper / ("timed-jq" if tool == "jq" else "awk")
        target.write_text(f'''#!/bin/sh
/usr/bin/time {time_flags} "{real}" "$@" 2>"{timed}/{tool}-$$.log"
''')
        target.chmod(0o755)
    real_jq = str(wrapper / "timed-jq")
text = (source / "bin/agent-guard").read_text()
functions = ["redact_tool_output", "redact_nul_response_json",
             "rewrite_response_conservatively", "redact_response_whole_leaf_fail_closed",
             "redact_nonempty_response_strings", "redact_response_values_awk",
             "emit_post_tool_replacement", "output_scan_input_exceeds_cap"]
if re.search(r"^redact_response_values_awk_current\(\)", text, re.M):
    functions.append("redact_response_values_awk_current")
if re.search(r"^rewrite_current_response_conservatively\(\)", text, re.M):
    functions.append("rewrite_current_response_conservatively")
for name in functions:
    pattern = rf"^{name}\(\) ([{{(])"
    match = re.search(pattern, text, re.M)
    assert match, name
    locale_before = ""
    locale_after = ""
    if name == "redact_tool_output":
        locale_before = '  printf "locale-before=%s\\n" "${LC_ALL-unset}" >>"$AG_DIAGNOSTIC_STAGES"\n'
        locale_after = '  printf "locale-after=%s\\n" "${LC_ALL-unset}" >>"$AG_DIAGNOSTIC_STAGES"\n'
    wrapper_text = f'''{name}() {{
{locale_before}\
  printf '%s enter {name}\\n' "$(date +%s)" >>"$AG_DIAGNOSTIC_STAGES"
  ag_diagnostic_real_{name} "$@"
  ag_diagnostic_status_{name}=$?
{locale_after}\
  printf '%s leave {name} status=%s\\n' "$(date +%s)" "$ag_diagnostic_status_{name}" >>"$AG_DIAGNOSTIC_STAGES"
  return "$ag_diagnostic_status_{name}"
}}
ag_diagnostic_real_{name}() {match[1]}'''
    text = text[:match.start()] + wrapper_text + text[match.end():]
copy = destination / "instrumented"
shutil.copytree(source, copy, ignore=shutil.ignore_patterns("target", ".git"))
(copy / "bin/agent-guard").write_text(text)
env = os.environ.copy()
env.pop("AI_AGENT", None)
env.update(AGENT_GUARD_TEST_RESPONSE_FILE=str(fixture), AGENT_GUARD_TEST_REAL_JQ=real_jq,
           AGENT_GUARD_LOG_MODE="off", AGENT_GUARD_RELEASE_CHECK="off",
           AGENT_GUARD_OUTPUT_REDACT="mask", AGENT_GUARD_PII_HOOK_MODE="off",
           AGENT_GUARD_HOOK_HOST="claude", PATH=str(wrapper) + ":" + env["PATH"])
rows = []
for mode, plugin in [("original", source), ("instrumented", copy)]:
    stages = destination / f"{mode}-stages.log"
    env["AG_DIAGNOSTIC_STAGES"] = str(stages)
    with envelope.open("rb") as stdin, (destination / f"{mode}.stdout").open("wb") as out, \
         (destination / f"{mode}.stderr").open("wb") as err:
        start = time.monotonic()
        process = subprocess.Popen([str(plugin / "bin/agent-guard"), "hook-post-tool"],
                                   stdin=stdin, stdout=out, stderr=err, env=env, cwd=destination)
        _, status, usage = os.wait4(process.pid, 0)
        process.returncode = os.waitstatus_to_exitcode(status)
        elapsed = time.monotonic() - start
    diagnostic_error = None
    try:
        output = json.loads((destination / f"{mode}.stdout").read_text())
        values = output["hookSpecificOutput"]["updatedToolOutput"]
        correct = (len(values) == 960000 and all(type(v) is int and v == 0 if i % 2 == 0
                                               else v is False for i, v in enumerate(values)))
    except (ValueError, KeyError, TypeError) as error:
        correct = False
        diagnostic_error = str(error)
    rows.append(dict(mode=mode, wall_seconds=elapsed, user_cpu_seconds=usage.ru_utime,
                     system_cpu_seconds=usage.ru_stime,
                     max_child_peak_rss_kib=usage.ru_maxrss / (1024 if sys.platform == "darwin" else 1),
                     status=process.returncode, independent_expected=correct, diagnostic_error=diagnostic_error,
                     within_original_20_seconds=elapsed < 20,
                     cli_sha256=hashlib.sha256((plugin / "bin/agent-guard").read_bytes()).hexdigest()))
    (destination / "results.json").write_text(json.dumps(rows, indent=2) + "\n")
    print(json.dumps(rows[-1]), flush=True)
    assert correct and process.returncode == 0
    if mode == "instrumented":
        lines = stages.read_text().splitlines()
        before = [line.removeprefix("locale-before=") for line in lines if line.startswith("locale-before=")]
        after = [line.removeprefix("locale-after=") for line in lines if line.startswith("locale-after=")]
        assert before and before == after, "caller locale changed"
