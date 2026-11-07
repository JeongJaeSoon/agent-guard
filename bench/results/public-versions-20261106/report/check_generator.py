#!/usr/bin/env python3
"""합성 fixture로 집계의 최소 표본·유효쌍·HTML roundtrip을 검사한다.

검증용 숫자는 제품 실측 보고서에 넣지 않는다. 임시 파일은 TemporaryDirectory에
격리하며 출력 JSON에는 검사 결과만 기록한다.
"""
import importlib.util
import json
import math
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('report_generator', ROOT / 'generate.py')
generator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(generator)


def sample(version, round_, success=True, series='direct'):
    return dict(phase='runtime', series=series, environment='SYNTHETIC_RULE_TEST_ONLY', distribution='standalone', scanner='official', host='claude', audit='off', case='small-clean', version=version, variant='default', workers=1, requests=1, round=round_, wall_s=.1 if version == 'v3.6.13' else .08, cpu_s=.05, max_child_rss_kib=1234, success=success, eligible=success)


def latency(rows):
    return next(r for r in generator.runtime_aggregates(rows) if r['version'] == 'v3.8.1' and r['metric'] == 'wall_ms')


def main():
    under_nine = [sample('v3.6.13', i) for i in range(14)] + [sample('v3.8.1', i, i < 8) for i in range(14)]
    result = latency(under_nine)
    assert result['n'] == 8 and math.isclose(result['median'], 80)
    assert result['cumulative_pct'] is None and '9미만' in result['cumulative_status']
    disjoint = [sample('v3.6.13', i, i < 9) for i in range(14)] + [sample('v3.8.1', i, i >= 5) for i in range(14)]
    result = latency(disjoint)
    assert result['n'] == 9 and result['cumulative_pct'] is None
    assert result['cumulative_valid_pairs'] == 4 and '유효쌍' in result['cumulative_status']
    blocks = [sample('v3.8.0', i, i < 9, 'optional') for i in range(14)] + [sample('v3.8.1', i, i >= 5, 'optional') for i in range(14)]
    result = latency(blocks)
    assert result['n'] == 9 and result['previous_pct'] is not None
    assert result['previous_valid_pairs'] is None and '별도 버전 블록' in result['previous_comparison_kind']
    accuracy = generator.correctness_aggregates([dict(success=False, expected_match=True, version='fixture-only')])
    assert accuracy[0]['passed'] == 0 and accuracy[0]['failed'] == 1
    with tempfile.TemporaryDirectory(prefix='agent-guard-report-generator-check-') as temp:
        temp = Path(temp)
        (temp / 'samples.json').write_text(json.dumps(under_nine))
        context = {'conclusions': ['<tag> & </script> 한글 >', 'literal \\u003c stays literal'], 'limitations': ['SYNTHETIC UI RULE TEST ONLY']}
        (temp / 'context.json').write_text(json.dumps(context))
        subprocess.run([sys.executable, str(ROOT / 'generate.py'), '--runtime', str(temp / 'samples.json'), '--metadata', str(temp / 'context.json'), '--out', str(temp / 'out')], check=True, capture_output=True, text=True)
        document = (temp / 'out/report.ko.html').read_text()
        embedded_text = document.split('<script id="report-data" type="application/json">', 1)[1].split('</script>', 1)[0]
        embedded = json.loads(embedded_text)
        assert embedded['context'] == context
        assert embedded == json.loads((temp / 'out/data.json').read_text())
        assert '<' not in embedded_text and '</script>' not in embedded_text
    proof = dict(scope='Synthetic aggregation-rule fixtures only; not product measurements', minimum_valid_n_9_guard=True, descriptive_median_iqr_n_preserved=True, same_round_pair_intersection_guard=True, optional_cross_version_separate_block_ratio_explicit=True, correctness_full_status_and_output_success_required=True, html_metadata_angle_and_literal_unicode_escape_roundtrip=True)
    (ROOT / 'generator-validation.json').write_text(json.dumps(proof, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(proof, ensure_ascii=False))


if __name__ == '__main__':
    main()
