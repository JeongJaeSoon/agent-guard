#!/usr/bin/env python3
"""실제 main 커밋의 native 산출물과 독립 검사를 검증한다."""
import hashlib, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
source = sys.argv[2]
assert len(source) == 40 and all(c in '0123456789abcdef' for c in source)
out = root / 'main-native-provenance.json'
assert not out.exists(), '기록 덮어쓰기 거부'
previous = pathlib.Path('/workspace/agent-guard-fused-evidence/ci-c3cfb40-native')
records = []
for target in ['x86_64-unknown-linux-musl', 'aarch64-unknown-linux-musl', 'x86_64-apple-darwin', 'aarch64-apple-darwin']:
    folder = root / ('native-' + target)
    name = 'agent-guard-redact-' + target
    assert (folder / (name + '.build.txt')).read_text().splitlines()[0] == source
    core = (folder / name).read_bytes()
    digest = hashlib.sha256(core).hexdigest()
    assert (folder / (name + '.sha256')).read_text().split() == [digest, name]
    differential = json.loads((folder / 'differential.json').read_text())
    integration = json.loads((folder / 'integration.json').read_text())
    assert differential['passed'] == 1024 and differential['failed'] == 0
    assert integration == {'passed': 90, 'failed': 0, 'native_invocation_verified': True}
    assert (folder / 'audit.log').read_text().rstrip().endswith('116 audit log checks passed, 0 failed')
    if target == 'x86_64-apple-darwin':
        for index in [2, 3]:
            assert json.loads((folder / f'integration-{index}.json').read_text()) == integration
    same = core == (previous / ('native-' + target) / name).read_bytes()
    assert same, '승인된 PR 바이너리와 다른 경우 별도 조사 필요'
    records.append(dict(target=target, source=source, sha256=digest, same_bytes_as_qualified_pr=same, differential=differential, integration=integration))
result = dict(scope='actual main-push native artifacts; workflow success checked separately before publication', source=source, platforms=records)
out.write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result, indent=2))
