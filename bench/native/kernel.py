#!/usr/bin/env python3
"""Paired one-shot JSON redactor measurement, including process startup."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import statistics
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('contracts', ROOT / 'tests/native-redaction.py')
contracts = importlib.util.module_from_spec(spec)
spec.loader.exec_module(contracts)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--core', type=Path, required=True)
    parser.add_argument('--runs', type=int, default=15)
    args = parser.parse_args()
    if args.runs < 1:
        parser.error('runs must be positive')
    core = args.core.resolve()
    cases = [
        ('small', 'API_KEY=secret', ['secret']),
        ('long', 'a' * 260000 + 'secret', ['secret']),
        ('many-leaves', ['API_KEY=perf-%03d' % i for i in range(100)] + ['status'] * 4000, ['perf-%03d' % i for i in range(100)]),
        ('unicode', ['é中😀 secret' * 100] * 100, ['secret', '😀']),
        ('budget-fallback', ['visible'] * 1000, ['missing'] * 257),
    ]
    report = {'runs': args.runs, 'native_sha256': hashlib.sha256(core.read_bytes()).hexdigest(),
              'jq_version': subprocess.check_output(['jq', '--version'], text=True).strip(),
              'scope': 'one process, stdin JSON, includes startup; no scanner or shell pipeline', 'cases': []}
    with tempfile.TemporaryDirectory() as directory:
        directory = Path(directory)
        reference = directory / 'reference.jq'
        reference.write_text(contracts.reference_program(ROOT / 'plugins/agent-guard/bin/agent-guard'))
        metrics = directory / 'metrics.json'
        for name, response, secrets in cases:
            payload = json.dumps(dict(protocol=1, response=response, secrets=secrets), ensure_ascii=False).encode()
            commands = {'shell-jq': ['jq', '-c', '-f', str(reference)], 'rust': [str(core), 'redact-v1']}
            expected = json.loads(subprocess.check_output(commands['shell-jq'], input=payload))
            samples = {k: [] for k in commands}
            # One unmeasured warm-up per candidate; every measured output is checked.
            for command in commands.values():
                assert json.loads(subprocess.check_output(command, input=payload)) == expected
            for repeat in range(args.runs):
                order = list(commands)
                if repeat % 2:
                    order.reverse()
                for label in order:
                    command = [sys.executable, str(ROOT / 'bench/resource-sample.py'), str(metrics), *commands[label]]
                    result = subprocess.run(command, input=payload, capture_output=True, timeout=30)
                    assert result.returncode == 0 and json.loads(result.stdout) == expected, (name, label)
                    samples[label].append(json.loads(metrics.read_text()))
            report['cases'].append({'name': name, 'verified': True, 'samples': samples,
                'medians': {label: {key: statistics.median(s[key] for s in values) for key in values[0]} for label, values in samples.items()}})
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
