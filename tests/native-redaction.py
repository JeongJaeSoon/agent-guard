#!/usr/bin/env python3
"""Differential contracts against the production jq redactor; synthetic data only."""
import argparse
import json
import os
from pathlib import Path
import random
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def reference_program(source):
    text = Path(source).read_text()
    walk = text.split("JQ_SHAPE_SAFE_WALK='", 1)[1].split("\n'", 1)[0]
    function = text.split('redact_tool_response_json() {', 1)[1].split('\n}\n', 1)[0]
    program = function.split('"$JQ_SHAPE_SAFE_WALK"\'', 1)[1].rsplit("' 2>/dev/null", 1)[0]
    return walk + '\n.secrets as $secrets | .response | ' + program


def cases():
    yield 'longest', ['abcd-long abcd', {'type': 'text', 'abcd': 'abcd'}], ['abcd', 'abcd-long']
    yield 'ties-cascade', ['aaaa bbbb'], [{'literal': 'aaaa', 'replacement': 'bbbb'}, {'literal': 'bbbb', 'replacement': 'done'}]
    yield 'context-adjacency', ['ababZ', 'ab\rab', 'ab\nab', 'ab\u00a0Z', 'ab,ab;ab\tab', 'ab'], [{'literal': 'ab', 'replacement': 'X', 'contextual': True}]
    tokens = ['text', 'image', 'document', 'search_result', 'browser_state', 'tool_reference', 'tool_use', 'tool_result', 'thinking', 'redacted_thinking', 'base64', 'url', 'file', 'content', 'pdf', 'image/png', 'image/jpeg', 'image/gif', 'image/webp', 'application/pdf', 'text/plain']
    yield 'protocol', [{k: t for k in ['type', 'media_type', 'mimeType', 'encoding', 'text']} for t in tokens] + [{'type': tokens}], tokens
    yield 'invalid-specs', ['', None, False, 7, 'clean'], ['', 7, None, {}, {'literal': 'clean'}, {'literal': 'clean', 'replacement': 'ok', 'contextual': 1}]
    for count in (255, 256, 257):
        yield 'count-' + str(count), {'type': 'text', 'text': 'clean', 'empty': '', 'n': 7}, ['missing'] * count
    for size in (31248, 31249, 31250):
        yield 'work-' + str(size), 'a' * size, ['missing'] * 256
    value = 'secret'
    for _ in range(200):
        value = [value]
    yield 'depth-200', value, ['secret']
    yield 'nul-unicode', {'😀': '😀é\x00中\nsecret'}, ['😀', '\x00', '中', 'secret']
    rng = random.Random(60261104)
    alphabet = ['a', 'b', 'text', '😀', 'é', 'é', '中', '\x00', '\x1e', '\n', '\t', '\r', ',', ';', ' ', '\\', '"']
    def word():
        return ''.join(rng.choices(alphabet, k=rng.randrange(0, 8)))
    for index in range(1000):
        specs = []
        leaves = [word() for _ in range(rng.randrange(1, 12))]
        for _ in range(rng.randrange(0, 12)):
            literal = rng.choice(leaves) if rng.random() < .7 else word()
            specs.append(literal if rng.random() < .4 else {'literal': literal, 'replacement': word(), 'contextual': rng.choice([True, False, None, 1])})
        yield 'generated-' + str(index), {'type': rng.choice(['text', word()]), 'encoding': leaves, 'nested': [{'text': leaf, 'n': 1234567890123456789, 'b': True} for leaf in leaves]}, specs


def invoke(command, payload):
    return subprocess.run(command, input=payload, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--core', required=True, type=Path)
    parser.add_argument('--source', type=Path, default=ROOT / 'plugins/agent-guard/bin/agent-guard')
    args = parser.parse_args()
    native = [str(args.core.resolve()), 'redact-v1']
    count = 0
    with tempfile.TemporaryDirectory() as directory:
        reference = Path(directory) / 'reference.jq'
        reference.write_text(reference_program(args.source))
        for name, response, secrets in cases():
            payload = json.dumps({'protocol': 1, 'response': response, 'secrets': secrets}, ensure_ascii=False).encode()
            old = invoke(['jq', '-c', '-f', str(reference)], payload)
            new = invoke(native, payload)
            assert old.returncode == new.returncode == 0, (name, old.stderr, new.stderr)
            assert json.loads(old.stdout) == json.loads(new.stdout), name
            count += 1
        # Malformed input must never publish a partial response (or echo secrets).
        for payload in [b'{"protocol":1,"response":{"$serde_json::private::Number":"123"},"secrets":[]}', b'{"protocol":1,"response":{"\\u0024serde_json::private::Number":"123"},"secrets":[]}', b'[' * 1025 + b'0' + b']' * 1025, b'', b' ', b'{', b'{}', b'{"protocol":2,"response":"secret","secrets":[]}', b'{"protocol":1,"response":"secret","secrets":null}', b'{"protocol":1,"response":"secret","secrets":[]}{}', b'{"protocol":1,"response":"\xff","secrets":[]}']:
            new = invoke(native, payload)
            assert new.returncode != 0 and new.stdout == b'' and b'secret' not in new.stderr
            count += 1
    print(json.dumps({'passed': count, 'failed': 0, 'generated_seed': 60261104}))


if __name__ == '__main__':
    main()
