#!/usr/bin/env python3
"""Opt-in location-only Bash observation; not a CI coverage gate."""
import collections
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / 'plugins/agent-guard/bin/agent-guard'
MANIFEST = ROOT / 'tests/selected-bash-locations.json'
# Only source path and physical line are traced. Never use BASH_COMMAND, xtrace,
# expanded arguments, fixture contents or captured application output.
DRIVER = r'''set -T
exec 9>"$AG_LOCATION_TRACE"
trap 'printf "%s:%s\n" "${BASH_SOURCE[0]:-driver}" "$LINENO" >&9' DEBUG
. "$0"
'''


def main():
    manifest = json.loads(MANIFEST.read_text())
    source_lines = SOURCE.read_text().splitlines(keepends=True)
    locations = {}
    with tempfile.TemporaryDirectory(prefix='agent-guard-bash-locations-') as directory:
        tmp = Path(directory)
        functions = tmp / 'functions'
        functions.mkdir()
        subprocess.run(['sh', str(ROOT / 'tests/helpers/extract-functions.sh'),
                        str(SOURCE), str(functions), *manifest], check=True)
        for name, entry in manifest.items():
            body = (functions / (name + '.sh')).read_bytes()
            if hashlib.sha256(body).hexdigest() != entry['body_sha256']:
                raise RuntimeError('selected function changed; review denominator: ' + name)
            start = source_lines.index(name + '() {\n') + 1
            locations[name] = {line: start + line - 1 for line in entry['relative_lines']}
        # Denominator is fixed and checked BEFORE any observation, including
        # selected valid locations that the fixtures may never reach.
        denominator = sum(len(lines) for lines in locations.values())
        observed = collections.Counter()
        controls = collections.Counter()
        suites = []

        def collect(script, counter):
            trace = tmp / 'locations'
            # Unit suites normally permit a source override for mutation tests.
            # This observation must execute the source whose hash we checked.
            env = dict(os.environ, AG_LOCATION_TRACE=str(trace),
                       AGENT_GUARD_UNIT_SOURCE=str(SOURCE))
            result = subprocess.run(['/bin/bash', '-c', DRIVER, str(script)],
                                    env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            for event in trace.read_text().splitlines():
                path, _, number = event.rpartition(':')
                name = Path(path).stem
                if name in locations and number.isdigit() and int(number) in locations[name]:
                    counter[name, int(number)] += 1
            if result.returncode:
                raise RuntimeError('instrumented test failed: ' + script.name)
            return result.stdout.decode()

        for suite in ['unit-core.sh', 'unit-framing.sh', 'unit-deny-path.sh', 'unit-probe.sh']:
            output = collect(ROOT / 'tests' / suite, observed)
            counts = [line for line in output.splitlines() if line.startswith(('passed:', 'failed:'))]
            suites.append({'suite': suite, 'counts': counts,
                           'sha256': hashlib.sha256((ROOT / 'tests' / suite).read_bytes()).hexdigest()})
        control = tmp / 'definitions-only.sh'
        control.write_text(''.join('. "' + str(functions / (name + '.sh')) + '"\n' for name in manifest))
        collect(control, controls)
        rows = []
        for name, lines in locations.items():
            rows.append({'function': name, 'eligible_source_lines': list(lines.values()),
                         'observed_source_lines': [src for rel, src in lines.items() if observed[name, rel]],
                         'missing_source_lines': [src for rel, src in lines.items() if not observed[name, rel]],
                         'definition_only_source_lines': [src for rel, src in lines.items() if controls[name, rel]]})
        result = {'source_sha256': hashlib.sha256(SOURCE.read_bytes()).hexdigest(),
                  'bash': subprocess.check_output(['/bin/bash', '--version'], text=True).splitlines()[0],
                  'denominator': denominator, 'observed': len(observed),
                  'definition_only_observed': len(controls), 'suites': suites, 'functions': rows}
        print(json.dumps(result, indent=2))
        if controls:
            raise RuntimeError('definition-only control unexpectedly reached selected locations')


if __name__ == '__main__':
    main()
