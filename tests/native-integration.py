#!/usr/bin/env python3
"""Native opt-in, fallback and host-envelope contracts using the real scanner."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--core', type=Path, required=True)
    parser.add_argument('--scanner', type=Path, required=True)
    args = parser.parse_args()
    core = str(args.core.resolve())
    count = 0
    env = dict(os.environ, AGENT_GUARD_LOG_MODE='off', AGENT_GUARD_RELEASE_CHECK='off',
               AGENT_GUARD_GITLEAKS_BIN=str(args.scanner.resolve()),
               AGENT_GUARD_GITLEAKS_CONFIG=str(ROOT / 'plugins/agent-guard/config/gitleaks.toml'),
               AGENT_GUARD_PII_HOOK_MODE='off', AGENT_GUARD_OUTPUT_REDACT='mask')
    with tempfile.TemporaryDirectory() as directory:
        directory = Path(directory)
        marker = directory / 'used'
        wrapper = directory / 'core'
        wrapper.write_text('#!/bin/sh\nprintf x >> "$NATIVE_MARKER"\nexec "$NATIVE_REAL_CORE" "$@"\n')
        wrapper.chmod(0o755)
        failing = directory / 'failing'
        failing.write_text('#!/bin/sh\nprintf \'{"partial":"unmasked"}\'\nexit 2\n')
        failing.chmod(0o755)
        env.update(NATIVE_MARKER=str(marker), NATIVE_REAL_CORE=core)
        variants = [core, str(wrapper), str(failing), str(directory / 'missing'), 'relative-path']
        values = [
            'API_KEY=perf-literal-tail',
            {'stdout': 'API_KEY=perf-literal-tail', 'clean': 'visible', 'type': 'text'},
            {'stdout': 'API_KEY=perf-literal-tail\x00tail', 'clean': 'visible'},
            {'stdout': 'API_KEY=perf-literal-tail', '$serde_json::private::Number': '123'},
            'ordinary build status',
        ]
        for host in ['claude', 'codex']:
            for response in values:
                payload = json.dumps({'tool_name': 'Read', 'tool_input': {}, 'tool_response': response}).encode()
                base_env = dict(env, AGENT_GUARD_HOOK_HOST=host, AGENT_GUARD_EXPERIMENTAL_REDACTOR='shell')
                command = [str(ROOT / 'plugins/agent-guard/bin/agent-guard'), 'hook-post-tool']
                old = subprocess.run(command, input=payload, env=base_env, capture_output=True, timeout=30)
                assert old.returncode == 0, old.stderr
                for binary in variants:
                    new_env = dict(base_env, AGENT_GUARD_EXPERIMENTAL_REDACTOR='rust', AGENT_GUARD_RUST_CORE_BIN=binary)
                    new = subprocess.run(command, input=payload, env=new_env, capture_output=True, timeout=30)
                    assert (old.returncode, old.stdout) == (new.returncode, new.stdout), (host, binary, response, old.stdout, new.stdout)
                    count += 1
        assert marker.exists() and marker.stat().st_size > 0, 'native helper was never used'
        for binary in variants:
            test_env = dict(env, AGENT_GUARD_EXPERIMENTAL_REDACTOR='rust', AGENT_GUARD_RUST_CORE_BIN=binary)
            run = subprocess.run(['sh', str(ROOT / 'tests/redaction-plan.sh')], env=test_env, capture_output=True, timeout=30)
            assert run.returncode == 0, run.stderr
            count += 8
    print(json.dumps({'passed': count, 'failed': 0, 'native_invocation_verified': True}))


if __name__ == '__main__':
    main()
