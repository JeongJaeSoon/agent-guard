#!/usr/bin/env python3
"""합성 fixture로 readiness 지연을 진단한다. 제품 timeout/기대값을 바꾸지 않는다."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import resource
import shutil
import subprocess
import time

p = argparse.ArgumentParser()
p.add_argument('--scanner', required=True)
p.add_argument('--out', required=True)
p.add_argument('--rounds', type=int, default=6)
a = p.parse_args()
root = Path(__file__).resolve().parents[2]
out = Path(a.out).resolve()
out.mkdir(parents=True, exist_ok=False)
scanner = str(Path(a.scanner).resolve())
plugin = root / 'plugins/agent-guard'
copy = out / 'instrumented'
shutil.copytree(plugin, copy)
cli = copy / 'bin/agent-guard'
source = cli.read_text()
needle = '  AG_GITLEAKS_PROBE_GROUP=\n  ag_gl_probe_bytes='
assert source.count(needle) == 1
source = source.replace(needle, '''  # Diagnostic copy only, after the child and watchdog have both been reaped.
  printf 'status=%s\\ntimeout=' "$ag_gl_probe_status" >"$AG_READINESS_DIAG/probe-status"
  cat "$ag_gl_probe_timeout" >>"$AG_READINESS_DIAG/probe-status"
  cp "$ag_gl_probe_output" "$AG_READINESS_DIAG/probe-output"
''' + needle)
cli.write_text(source)
payload = json.dumps({'tool_name': 'Read', 'tool_input': {}, 'tool_response': {
    'stdout': 'API_KEY=perf-literal-tail', '$serde_json::private::Number': '123'
}}).encode()
expected = {'hookSpecificOutput': {'hookEventName': 'PostToolUse',
    'updatedToolOutput': {'stdout': 'API_KEY=[REDACTED]', '$serde_json::private::Number': '123'}}}
(out / 'input.json').write_bytes(payload)
(out / 'expected.json').write_text(json.dumps(expected))
(out / 'identity.json').write_text(json.dumps({
    'cli_sha256': hashlib.sha256((plugin / 'bin/agent-guard').read_bytes()).hexdigest(),
    'scanner_sha256': hashlib.sha256(Path(scanner).read_bytes()).hexdigest(),
    'machine': os.uname()._asdict() if hasattr(os.uname(), '_asdict') else list(os.uname()),
    'scope': 'diagnostic only; original 2 second readiness deadline, no retry acceptance; fixed synthetic fixture'
}, indent=2))
rows = []

def run(label, argv, env, data=b'', hook=False):
    folder = out / label
    folder.mkdir()
    env = dict(env, AG_READINESS_DIAG=str(folder))
    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    start = time.monotonic()
    with (folder / 'stdout').open('wb') as stdout, (folder / 'stderr').open('wb') as stderr:
        process = subprocess.run(argv, input=data, env=env, stdout=stdout, stderr=stderr, timeout=35)
    elapsed = time.monotonic() - start
    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    actual = (folder / 'stdout').read_bytes()
    row = dict(label=label, status=process.returncode, seconds=elapsed,
        user_cpu_seconds=after.ru_utime-before.ru_utime,
        system_cpu_seconds=after.ru_stime-before.ru_stime,
        load_average=os.getloadavg())
    if hook:
        try:
            row['independent_expected'] = json.loads(actual) == expected
        except ValueError:
            row['independent_expected'] = False
        row['readiness_timeout'] = b'Scanner readiness: timeout' in actual
    else:
        row['version_expected'] = process.returncode == 0 and actual.strip() == b'8.30.1'
    rows.append(row)
    (out / 'results.json').write_text(json.dumps(rows, indent=2) + '\n')
    print(json.dumps(row), flush=True)

base = dict(os.environ, AGENT_GUARD_LOG_MODE='off', AGENT_GUARD_RELEASE_CHECK='off',
    AGENT_GUARD_GITLEAKS_BIN=scanner, AGENT_GUARD_GITLEAKS_CONFIG=str(plugin/'config/gitleaks.toml'),
    AGENT_GUARD_PII_HOOK_MODE='off', AGENT_GUARD_OUTPUT_REDACT='mask',
    AGENT_GUARD_HOOK_HOST='claude', AGENT_GUARD_RUST_CORE_BIN='relative-path')
for key in ['GODEBUG', 'GOMAXPROCS', 'AGENT_GUARD_EXPERIMENTAL_OUTPUT_PIPELINE',
            'AGENT_GUARD_EXPERIMENTAL_OUTPUT_PREPARE_BIN']:
    base.pop(key, None)
assert a.rounds > 0
for i in range(a.rounds):
    for mode in (['default', 'single'] if i % 2 == 0 else ['single', 'default']):
        env = dict(base)
        if mode == 'single':
            env['GOMAXPROCS'] = '1'
        run(f'version-{i}-{mode}', [scanner, 'version'], env)
        for variant, executable in [('original', plugin/'bin/agent-guard'), ('instrumented', cli)]:
            run(f'hook-{i}-{mode}-{variant}', [str(executable), 'hook-post-tool'], env, payload, True)
for mode in ['default', 'single']:
    env = dict(base, GODEBUG='inittrace=1')
    if mode == 'single':
        env['GOMAXPROCS'] = '1'
    # Direct process only: inittrace exceeds the production probe's output cap.
    run(f'inittrace-{mode}', [scanner, 'version'], env)
