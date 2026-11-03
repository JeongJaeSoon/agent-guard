#!/usr/bin/env python3
"""Run frozen CLI regression partitions with bounded concurrency and retain logs."""
import argparse
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', required=True, type=Path)
    parser.add_argument('--native-core', required=True, type=Path)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    source = ROOT / 'plugins/agent-guard/bin/agent-guard'
    before = hashlib.sha256(source.read_bytes()).hexdigest()
    def run(shard, native=False):
        label = ('native-' if native else 'shell-') + str(shard)
        env = dict(os.environ, AGENT_GUARD_TEST_SHARD=str(shard),
                   AGENT_GUARD_EXPERIMENTAL_REDACTOR='shell',
                   AGENT_GUARD_RUST_CORE_BIN=str(args.native_core.resolve()))
        start = time.monotonic()
        log = args.out / (label + '.log')
        with log.open('w') as output:
            result = subprocess.run(['sh', 'tests/native-suite.sh' if native else 'tests/run.sh'],
                                    env=env, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT)
        lines = log.read_text().splitlines()
        row = {'label': label, 'status': result.returncode, 'seconds': time.monotonic() - start,
               'summary': [s for s in lines if s.startswith(('passed:', 'failed:', 'not ok -'))],
               'real_scanner_skipped': any('skipped real-gitleaks' in s for s in lines)}
        print(json.dumps(row), flush=True)
        return row
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
        rows = list(executor.map(run, range(1, 6)))
    rows.append(run(4, native=True))
    after = hashlib.sha256(source.read_bytes()).hexdigest()
    report = {'before_sha256': before, 'after_sha256': after, 'stable': before == after, 'results': rows}
    (args.out / 'verification.json').write_text(json.dumps(report, indent=2))
    raise SystemExit(int(before != after or any(row['status'] for row in rows)))


if __name__ == '__main__':
    main()
