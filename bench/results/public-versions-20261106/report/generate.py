#!/usr/bin/env python3
"""고정된 공개 버전 실측 자료로 오프라인 한국어 리포트를 생성한다."""
import argparse
import csv
import hashlib
import html
import io
import json
import math
import statistics
from collections import defaultdict
from pathlib import Path

VERSIONS = ['v3.6.13', 'v3.6.14', 'v3.6.15', 'v3.7.0', 'v3.7.1', 'v3.8.0', 'v3.8.1']
DIMENSIONS = ['phase', 'series', 'environment', 'distribution', 'scanner', 'host', 'audit', 'case', 'variant', 'workers']
METRICS = {
    'wall_ms': ('CLI 지연', 'ms', '감소가 유리', False),
    'cpu_ms': ('CPU 시간', 'ms', '감소가 유리', False),
    'throughput_rps': ('처리량', '요청/s', '증가가 유리', True),
    'max_child_rss_kib': ('최대 개별 자식 RSS', 'KiB', '감소가 유리', False),
    'rss_sum_peak_kib': ('표본 프로세스 RSS 합의 최대', 'KiB', '감소가 유리', False),
}
INSTALL_METRICS = {
    'wall_s': ('설치 시간', 's', '감소가 유리', False),
    'cpu_s': ('설치 CPU 시간', 's', '감소가 유리', False),
    'max_child_rss_kib': ('설치 최대 개별 자식 RSS', 'KiB', '감소가 유리', False),
    'download_bytes': ('다운로드 크기', 'B', '감소가 유리', False),
    'installed_bytes': ('설치 파일 크기', 'B', '감소가 유리', False),
}


def read(path, default):
    if not path or not Path(path).exists():
        return default
    raw = Path(path).read_text()
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return [json.loads(line) for line in raw.splitlines() if line.strip()]


def rows(value):
    if isinstance(value, list):
        return value
    if isinstance(value, dict):
        for key in ['samples', 'rows', 'results', 'measurements']:
            if isinstance(value.get(key), list):
                return value[key]
    return []


def num(v):
    return isinstance(v, (float, int)) and not isinstance(v, bool) and math.isfinite(v)


def quantile(values, q):
    ordered = sorted(values)
    point = (len(ordered) - 1) * q
    lo = math.floor(point)
    hi = math.ceil(point)
    return ordered[lo] + (ordered[hi] - ordered[lo]) * (point - lo)


def delta(value, base):
    return (value / base - 1) * 100 if num(base) and base != 0 else None


def verdict(change, higher=False):
    if change is None:
        return 'N/A'
    gain = change if higher else -change
    return '개선 ≥10%' if gain >= 10 else '회귀 >5%' if gain < -5 else '기준 미만'


def set_comparison(row, reference, prefix, higher=False, paired=True):
    """서술 통계는 유지하되 요구된 9개 유효 표본/쌍 없는 개선 주장을 막는다."""
    row[prefix + '_pct'] = None
    row[prefix + '_valid_pairs'] = None
    row[prefix + '_comparison_kind'] = '동일 round의 유효쌍을 확인한 중앙값 비율' if paired else '동일 VM의 별도 버전 블록 중앙값 비율; 버전간 교대 재확인 아님'
    if reference is None:
        row[prefix + '_status'] = 'N/A — 같은 조건의 비교 기준 미측정'
        return
    if min(row['n'], reference['n']) < 9:
        row[prefix + '_status'] = 'N/A — 검증표본 9미만'
        return
    if paired:
        pairs = len(row['_valid_rounds'] & reference['_valid_rounds'])
        row[prefix + '_valid_pairs'] = pairs
        if pairs < 9:
            row[prefix + '_status'] = 'N/A — 동일 round 유효쌍 9미만'
            return
    row[prefix + '_pct'] = delta(row['median'], reference['median'])
    row[prefix + '_status'] = verdict(row[prefix + '_pct'], higher)


def fmt(v, digits=3):
    return f'{v:,.{digits}f}' if num(v) else 'N/A'


def pct(v):
    return f'{v:+.2f}%' if num(v) else 'N/A'


def pct_comparison(row, prefix):
    value = row.get(prefix + '_pct')
    if not num(value) and '9미만' in row.get(prefix + '_status', ''):
        return 'N/A (검증표본·유효쌍 9미만)'
    return pct(value)


def canonical_version(value):
    value = str(value)
    return 'v' + value if value and value[0].isdigit() else value


def csv_text(data):
    if not data:
        return ''
    fields = list(dict.fromkeys(k for row in data for k in row))
    out = io.StringIO(newline='')
    writer = csv.DictWriter(out, fieldnames=fields)
    writer.writeheader()
    writer.writerows({k: json.dumps(v, ensure_ascii=False) if isinstance(v, (list, dict)) else v for k, v in row.items()} for row in data)
    return out.getvalue()


def runtime_aggregates(raw):
    groups = defaultdict(list)
    valid_rounds = defaultdict(set)
    counts = defaultdict(lambda: [0, 0, 0])
    for original in raw:
        row = dict(original)
        row.setdefault('phase', 'runtime')
        if row['phase'] not in ['runtime', 'rss']:
            continue
        row.setdefault('environment', '미기록 — 자원 제한 추정 금지')
        row.setdefault('distribution', 'standalone')
        key = tuple(row.get(k, '') for k in DIMENSIONS) + (row.get('version'),)
        counts[key][0] += 1
        ok = row.get('success', True) and row.get('eligible', True)
        counts[key][1 if ok else 2] += 1
        if not ok:
            continue
        derived = {
            'wall_ms': row.get('wall_s', 0) * 1000 if num(row.get('wall_s')) else None,
            'cpu_ms': row.get('cpu_s', 0) * 1000 if num(row.get('cpu_s')) else None,
            'throughput_rps': row.get('requests', 1) / row['wall_s'] if num(row.get('wall_s')) and row['wall_s'] > 0 else None,
            'max_child_rss_kib': row.get('max_child_rss_kib'),
            'rss_sum_peak_kib': row.get('rss_sum_peak_kib'),
        }
        # RSS polling is a separate experiment; never mix its wall/CPU with CLI latency.
        if row['phase'] == 'rss':
            derived = {k: v for k, v in derived.items() if k in ['max_child_rss_kib', 'rss_sum_peak_kib']}
        else:
            derived.pop('rss_sum_peak_kib', None)
        for metric, value in derived.items():
            if num(value):
                groups[(key, metric)].append(value)
                if row.get('round') is not None:
                    valid_rounds[(key, metric)].add(row['round'])
    out = []
    lookup = {}
    for (key, metric), values in groups.items():
        row = dict(zip(DIMENSIONS + ['version'], key))
        label, unit, direction, higher = METRICS[metric]
        if metric in ['wall_ms', 'cpu_ms'] and int(row.get('workers', 1)) > 1:
            unit = f'ms/{row["workers"]}요청 묶음'
            label = f'{label} ({row["workers"]}요청 ' + ('완료' if metric == 'wall_ms' else '합계') + ')'
        row.update(metric=metric, label=label, unit=unit, direction=direction, n=len(values), median=statistics.median(values), p25=quantile(values, .25), p75=quantile(values, .75), minimum=min(values), maximum=max(values), total_samples=counts[key][0], excluded_samples=counts[key][2])
        row['_valid_rounds'] = valid_rounds[(key, metric)]
        out.append(row)
        lookup[(key, metric)] = row
    for row in out:
        key = tuple(row[k] for k in DIMENSIONS)
        index = VERSIONS.index(row['version']) if row['version'] in VERSIONS else -1
        prior_version = VERSIONS[index - 1] if index > 0 else None
        prior = lookup.get((key + (prior_version,), row['metric']))
        base = lookup.get((key + (VERSIONS[0],), row['metric']))
        row['previous_version'] = prior_version
        row['baseline_version'] = VERSIONS[0]
        set_comparison(row, prior, 'previous', METRICS[row['metric']][3], paired=row['series'] != 'optional')
        set_comparison(row, base, 'cumulative', METRICS[row['metric']][3], paired=row['series'] != 'optional')
        if row['variant'] == 'fused':
            default_key = tuple('default' if k == 'variant' else row[k] for k in DIMENSIONS)
            default = lookup.get((default_key + (row['version'],), row['metric']))
            set_comparison(row, default, 'optional', METRICS[row['metric']][3])
            cross_base = lookup.get((default_key + (VERSIONS[0],), row['metric']))
            set_comparison(row, cross_base, 'cross_variant_baseline', METRICS[row['metric']][3], paired=row['series'] != 'optional')
        else:
            row['optional_pct'] = None
            row['optional_status'] = 'N/A'
            row['cross_variant_baseline_pct'] = None
            row['cross_variant_baseline_status'] = 'N/A'
        row['display_cumulative_status'] = row['cross_variant_baseline_status'] if row['variant'] == 'fused' else row['cumulative_status']
    for row in out:
        del row['_valid_rounds']
    return sorted(out, key=lambda x: tuple(str(x[k]) for k in DIMENSIONS) + (VERSIONS.index(x['version']) if x['version'] in VERSIONS else 99, x['metric']))


def installation_aggregates(raw):
    groups = defaultdict(list)
    source_versions = defaultdict(set)
    valid_rounds = defaultdict(set)
    scopes = defaultdict(set)
    for row in raw:
        if row.get('warmup', False):
            continue
        if not row.get('success', True):
            continue
        row = dict(row)
        row['version'] = canonical_version(row.get('version', ''))
        if 'update' in row.get('scenario', '') and row.get('from_version') and canonical_version(row['from_version']) == row['version']:
            # A same-version reinstall is not an upgrade from the prior release.
            row['scenario'] = row['scenario'].replace('update', 'reinstall')
        key = tuple(row.get(k, '') for k in ['environment', 'scenario', 'version'])
        if row.get('scope'):
            scopes[key].add(row['scope'])
        if row.get('from_version'):
            source_versions[key].add(canonical_version(row['from_version']))
        for metric in INSTALL_METRICS:
            value = row.get('home_delta_bytes') if metric == 'installed_bytes' and row.get('scenario', '').startswith('dependency-scanner') else row.get(metric)
            if num(value):
                groups[(key, metric)].append(value)
                if row.get('round') is not None:
                    valid_rounds[(key, metric)].add(row['round'])
    out = []
    for (key, metric), values in groups.items():
        label, unit, direction, higher = INSTALL_METRICS[metric]
        scenario = key[1]
        if scenario == 'asset-network-download':
            label = {'wall_s': 'archive 다운로드 시간 (설치 제외)', 'cpu_s': 'archive 다운로드 CPU 시간', 'max_child_rss_kib': '다운로드 최대 개별 자식 RSS', 'download_bytes': '공개 archive 다운로드 크기'}.get(metric, label)
        elif scenario == 'dependency-scanner-cached':
            label = {'wall_s': 'scanner 최초 설치 시간 (네트워크 제외)', 'cpu_s': 'scanner 최초 설치 CPU 시간', 'installed_bytes': '신규 scanner 설치 파일 크기', 'download_bytes': '고정 scanner 자산 크기 (네트워크 제외)'}.get(metric, label)
        scope_display = ' / '.join(sorted(scopes[key]))
        if scenario == 'asset-network-download':
            scope_display = '고정 공개 archive의 실제 curl 전송만 계측. TLS 검증 유지. SHA-256은 계측 후 검증. bootstrap·checksum 파일 다운로드·의존성·압축 해제·setup 비용 제외. proxy/CDN 캐시 상태 미관측.'
        elif scenario == 'dependency-scanner-cached':
            scope_display = '별도 격리 HOME에서 scanner 최초 setup --install. 사전 확보한 동일 공개 scanner archive를 사용하므로 네트워크 전송 제외. OS 의존성은 준비됨. 신규 scanner 파일 크기는 기존 sentinel을 제외한 home_delta_bytes.'
        corrected = scenario in ['asset-network-download', 'dependency-scanner-cached'] and any(s.startswith('published bootstrap') for s in scopes[key])
        size_basis = 'home_delta_bytes: newly installed scanner bytes; excludes pre-existing 48 B sentinel' if key[1].startswith('dependency-scanner') else 'installed_bytes: measured installed regular-file logical sizes; exact inclusion scope in source row'
        out.append(dict(zip(['environment', 'scenario', 'version'], key), from_version=', '.join(sorted(source_versions[key])) or None, installed_bytes_basis=size_basis, scope_raw=sorted(scopes[key]), scope_display=scope_display, scope_display_corrected=corrected, scope_display_note='원본의 공통 bootstrap 설명은 보존하고 실제 scenario·계측 명령에 맞춰 표시 범위만 정정했습니다.' if corrected else '', metric=metric, label=label, unit=unit, direction=direction, n=len(values), median=statistics.median(values), p25=quantile(values, .25), p75=quantile(values, .75), minimum=min(values), maximum=max(values), _valid_rounds=valid_rounds[(key, metric)]))
    lookup = {(r['environment'], r['scenario'], r['version'], r['metric']): r for r in out}
    for r in out:
        idx = VERSIONS.index(r['version']) if r['version'] in VERSIONS else -1
        prev = VERSIONS[idx - 1] if idx > 0 else None
        previous = lookup.get((r['environment'], r['scenario'], prev, r['metric']))
        base = lookup.get((r['environment'], r['scenario'], VERSIONS[0], r['metric']))
        r.update(previous_version=prev, baseline_version=VERSIONS[0])
        set_comparison(r, previous, 'previous')
        set_comparison(r, base, 'cumulative')
    for row in out:
        del row['_valid_rounds']
    return out


def correctness_aggregates(raw):
    dimensions = ['environment', 'scope', 'dataset', 'scanner', 'host', 'version', 'variant']
    groups = {}
    for row in raw:
        key = tuple(row.get(k, '') for k in dimensions)
        if key not in groups:
            groups[key] = dict(zip(dimensions, key), n=0, passed=0, failed=0, oracle_excluded=0, classifications={})
        group = groups[key]
        if row.get('oracle_invalid', False) or row.get('included_in_accuracy_count') is False:
            group['oracle_excluded'] += 1
            continue
        group['n'] += 1
        # success covers both expected status and output. An output-only match
        # must not hide a wrong exit status or infrastructure failure.
        ok = bool(row.get('success', row.get('expected_match', False)))
        group['passed' if ok else 'failed'] += 1
        classification = row.get('classification_analysis') or row.get('classification') or ('pass' if ok else 'unclassified')
        group['classifications'][classification] = group['classifications'].get(classification, 0) + 1
    return list(groups.values())


def na_reason(condition, version, metric, raw):
    index = VERSIONS.index(version)
    variant, series, phase = (condition.get(k) for k in ['variant', 'series', 'phase'])
    if metric == 'rss_sum_peak_kib' and phase != 'rss':
        return 'RSS 합은 phase=rss·series=rss의 별도 표본 계측만 사용합니다. runtime 값은 0이 아닙니다.'
    if phase == 'rss' and metric in ['wall_ms', 'cpu_ms', 'throughput_rps']:
        return 'RSS 샘플링의 계측 비용을 CLI 지연·CPU·처리량 집계에서 제외했습니다. phase=runtime을 선택하세요.'
    if variant == 'fused' and index < 5:
        return '이 공개 버전은 선택형 출력 통합(fused)을 지원하지 않습니다. 공개 지원은 v3.8.0부터입니다.'
    if series == 'optional' and index < 5:
        return '선택형 추가 효과 비교는 지원하는 공개 v3.8.0·v3.8.1만 사전 계획하여 측정했습니다.'
    if variant == 'fused' and series in ['load', 'rss'] and index != 6:
        return '4동시 처리량·별도 RSS의 fused는 v3.8.1만 측정했습니다. v3.8.0 기능 지원을 해당 항목의 실측으로 대신하지 않습니다.'
    if series in ['direct', 'audit', 'source'] and index not in [0, 6]:
        return '이 실험 묶음은 v3.6.13·v3.8.1 직접 비교만 측정했습니다. 중간 버전은 기능 유무와 별개로 미측정입니다.'
    matching = [r for r in raw if r.get('version') == version and all(str(r.get(k, '')) == str(condition.get(k, '')) for k in DIMENSIONS)]
    if matching and not any(r.get('success', True) and r.get('eligible', True) for r in matching):
        return f'실제 표본 {len(matching)}개가 종료·출력·timeout 검증 불일치로 동일 작업 성능 집계에서 제외되었습니다. 원시 실패는 보존했습니다.'
    if matching:
        return '실행 기록은 있으나 이 지표의 유효 표본이 없습니다. 샘플링 범위·실패 원시 자료를 확인하세요.'
    return '이 선택 환경·scanner·host·audit·입력·경로 조합은 측정하지 않았습니다. 다른 환경의 숫자로 채우지 않습니다.'


def prose(value):
    return value if isinstance(value, str) else json.dumps(value, ensure_ascii=False, indent=2)


def conclusion_md(item):
    if isinstance(item, str):
        return item + ' ([집계·원시 자료](data.json))'
    text = str(item.get('text', item))
    sources = item.get('sources', [])
    return text + ' ' + ' · '.join(f'[{s.get("label", "근거")}]({s["path"]})' for s in sources if 'path' in s)


def markdown(data):
    ctx = data['context']
    chunks = ['# Agent Guard 공개 버전 실측 비교', '', '[독립형 HTML](report.ko.html) · [모든 집계 CSV](aggregates.csv) · [원시 JSON](data.json) · [재현 도구](generate.py)', '', '## ① 한눈에 보는 결론', '']
    if ctx.get('highlights'):
        chunks += ['- ' + conclusion_md(x) for x in ctx['highlights']]
        chunks += ['', '### 조건별 실측 숫자', '']
    chunks += ['- ' + conclusion_md(x) for x in ctx.get('conclusions', ['실측이 완료된 조건의 개별 결과를 확인하세요. 서로 다른 입력의 개선율을 평균하지 않습니다.'])]
    chunks += ['', '“기본 경로”는 공개 배포본의 redactor·pipeline 선택 기본값입니다. scanner·설정·audit·release check 등은 비교를 위해 통제하며, 모든 자연 기본 설정을 그대로 실행했다는 뜻이 아닙니다. 지연은 hook callback CLI 시작을 포함하고 Claude/Codex 호스트 앱 자체의 지연은 아닙니다.', '', '### 사용 권고', '']
    chunks += ['- ' + conclusion_md(x) for x in ctx.get('recommendations', ['각 입력·배포 경로별 결과와 한계를 확인한 뒤 기본/선택형 경로를 결정하세요.'])]
    chunks += ['', '지연·CPU·메모리는 감소가 유리하고 처리량은 증가가 유리합니다. 변화율은 `(현재 / 비교 기준 − 1) × 100`이며, 개선 ≥10%와 회귀 >5%를 미리 고정한 기준으로 표시합니다. 산포는 P25–P75(IQR), n은 유효 표본 수입니다. 실패·작업량 불일치 표본은 원시 자료에 보존하고 같은 작업 성능 집계에서 제외합니다. 검증 표본 9개 또는 같은 round 유효쌍 9쌍 미만이면 중앙값·IQR·n만 유지하고 변화율·개선/회귀 판정은 N/A입니다. optional 버전간 직전 비교는 동일 VM의 별도 버전 블록 중앙값 비율이며 버전간 교대 재확인이 아닙니다.', '', '## ② 버전별 변화', '', '| 공개 버전 | 관련 변경 |', '|---|---|']
    chunks += [f'| {v} | {str(ctx.get("version_changes", {}).get(v, "내용 미검증 — N/A")).replace(chr(10), " ").replace("|", "\\|")} |' for v in VERSIONS]
    chunks += ['', '변경 설명만으로 성능 인과관계가 입증되지는 않습니다. 원인 분리 계측이 없는 설명은 추정입니다.', '', '## ③ 최초 버전 대비 누적 변화', '', '기준은 각 동일 조건의 v3.6.13 실측 중앙값입니다. 직전 비교는 직전 공개 버전의 같은 조건에만 연결합니다. 중간 버전이 N/A이면 건너뛰어 개선율을 계산하지 않습니다. A(기본↔기본), B(v3.8.1 기본↔fused), C(v3.6.13 기본↔v3.8.1 fused)는 분리합니다. v3.6.13↔v3.8.1 직접 교대 실험은 `series=direct`로 유지합니다.', '', '## ④ 표와 그래프', '', '그래프는 [HTML](report.ko.html)에서 동일 조건을 선택해 볼 수 있습니다. 표의 모든 값과 변화율은 [집계 CSV](aggregates.csv)에 있습니다. 전체 CLI 표본의 지연·CPU와 별도의 RSS 표본 실험은 합치지 않습니다.', '']
    figures = ctx.get('figures', [])
    if figures:
        chunks += ['### 대표 정적 그림', '']
        for figure in figures:
            if figure.get('embed_markdown'):
                chunks += [f'![{figure.get("title", figure["path"])}]({figure["path"]})', '']
        chunks += ['### 동봉 그림 전체', '']
        chunks += [f'- [{f.get("title", f["path"])}]({f["path"]})' for f in figures]
        chunks += ['']
    groups = defaultdict(list)
    for row in data['aggregates']:
        groups[tuple(row[k] for k in DIMENSIONS) + (row['metric'],)].append(row)
    for key, values in groups.items():
        condition = dict(zip(DIMENSIONS + ['metric'], key))
        chunks += ['### ' + ' / '.join(f'{k}={condition[k]}' for k in DIMENSIONS) + ' / 지표=' + values[0]['label'], '', f'**{values[0]["label"]} ({values[0]["unit"]}; {values[0]["direction"]})**', '', '| 버전 | 중앙값 | P25–P75 | n | 직전 공개 버전 대비 | v3.6.13 대비 | 같은 버전 기본 대비(fused) | v3.6.13 기본 대비(C) | 누적 판정(A·C) |', '|---|---:|---:|---:|---:|---:|---:|---:|---|']
        byversion = {r['version']: r for r in values}
        for version in VERSIONS:
            r = byversion.get(version)
            chunks += [f'| {version} | {fmt(r["median"])} | {fmt(r["p25"])}–{fmt(r["p75"])} | {r["n"]} | {pct_comparison(r, "previous")} | {pct_comparison(r, "cumulative")} | {pct_comparison(r, "optional")} | {pct_comparison(r, "cross_variant_baseline")} | {r["display_cumulative_status"]} |' if r else f'| {version} | N/A | N/A | N/A | N/A | N/A | N/A | N/A | {na_reason(condition, version, condition["metric"], data["runtime"])} |']
        chunks += ['']
    chunks += ['### 설치 비용 — 사용 중 성능과 분리', '', 'cached 경로의 download_bytes는 고정 공개 자산의 논리 크기이며 네트워크 시간은 제외합니다. v3.6.13 동일 버전 재설치는 update와 분리한 reinstall 경로입니다. dependency-scanner 설치 크기는 home_delta_bytes를 사용하여 사전 sentinel 48 B를 제외합니다. cached 업데이트는 각 target 버전의 공개 bootstrap 바이트에 운송을 고정한 재현이며 오늘의 latest bootstrap을 이용한 중간 버전 네트워크 업데이트와 구분합니다.', '', '| 환경 | 경로 | 대상 버전 | 출발 버전 | 지표 | 중앙값 | P25–P75 | n | 직전 대비 | v3.6.13 대비 | 누적 판정 |', '|---|---|---|---|---|---:|---:|---:|---:|---:|---|']
    for r in data['installation_aggregates']:
        chunks.append(f'| {r["environment"]} | {r["scenario"]} | {r["version"]} | {r["from_version"] or "새 설치"} | {r["label"]} ({r["unit"]}) | {fmt(r["median"])} | {fmt(r["p25"])}–{fmt(r["p75"])} | {r["n"]} | {pct_comparison(r, "previous")} | {pct_comparison(r, "cumulative")} | {r["cumulative_status"]} |')
    if not data['installation_aggregates']:
        chunks += ['| N/A | 설치 자료 없음 | N/A | N/A | N/A | N/A | N/A | N/A | N/A |']
    chunks += ['', 'workers=4의 지연은 4요청 묶음 전체 완료 시간이고 CPU는 4요청 CPU 합계입니다. 단일 요청 CPU와 그대로 비교하지 않습니다. wait4 peak에 Python launcher의 fork 이전 RSS floor가 포함될 수 있어 unknown/failure 같은 짧은 경로의 peak를 제품 고유 메모리로 해석하지 않습니다. RSS 합은 표본 시점의 프로세스 RSS를 더한 값으로 공유 페이지를 중복 계산하며 고유 물리 메모리 사용량이 아닙니다. 표본 간 짧은 peak를 놓칠 수 있습니다. 설치·사용 환경이 다르면 손익분기 요청 횟수를 계산하지 않습니다.', '', '### 개선·회귀 원인 — 별도 세부 계측', '', 'scanner 준비·실행, 프로세스 생성, JSON parsing·framing·치환 계측은 CLI 전체 지연과 별개입니다. 추적 도구의 계측 비용을 사용자 성능 집계에 합치지 않습니다.', '', '```json', json.dumps(ctx.get('attribution', 'N/A — 세부 계측 자료 미제공'), ensure_ascii=False, indent=2), '```', '', '### 정확도·오탐·누락·호환성', '', '정확도 원시 자료는 [data.json](data.json)의 `correctness`와 원본 correctness 디렉터리에 보존합니다. 고정 합성 사례별 계약 검증이며 실제 사용자 분포의 오탐률·탐지율 추정치가 아닙니다. 탐지 작업량이 다른 사례는 성능 개선으로 해석하지 않습니다.', '', '```json', json.dumps(data['correctness_summary'], ensure_ascii=False, indent=2), '```', '', '```json', json.dumps(ctx.get('security_compatibility', 'N/A — 정확도 원시 자료와 한계 참조'), ensure_ascii=False, indent=2), '```', '', '## ⑤ 조건과 원시 자료', '', '### 실제 환경과 자원 제한', '', '```json', json.dumps({k: ctx.get(k, 'N/A — 증거 미제공') for k in ['environment', 'runtime_environments', 'limits', 'protocol']}, ensure_ascii=False, indent=2), '```', '', '### 공개 배포본·scanner 증거', '', '```json', json.dumps({'release_and_scanner': ctx.get('provenance', []), 'correctness_metadata': data['correctness_metadata'], 'report_input_files': data['input_files']}, ensure_ascii=False, indent=2), '```', '', '### 재현 명령', '', '```sh', '\n'.join(ctx.get('reproduction', [])), '```', '', '### 실패와 미검증 범위', '']
    chunks += ['- ' + str(x) for x in ctx.get('limitations', ['자료에 명시되지 않은 플랫폼·경로는 미검증입니다.'])]
    chunks += ['', '### 설치 범위와 한계', '', '```json', json.dumps(data['installation_summary'], ensure_ascii=False, indent=2), '```', '', f'원시 실행 표본 {len(data["runtime"])}개, 집계 행 {len(data["aggregates"])}개. 전체 JSON·CSV는 HTML에서도 오프라인으로 내려받을 수 있습니다.', '']
    chunks += ['### 정확도 조건별 사례 수 — 실사용 오탐률 추정 아님', '', '| 환경 | 범위/자료 | Scanner | Host | 버전 | 경로 | 유효 사례 | 일치 | 불일치 | oracle 제외 | 분류 |', '|---|---|---|---|---|---|---:|---:|---:|---:|---|']
    for row in data['correctness_aggregates']:
        chunks.append(f'| {row["environment"]} | {row["scope"]}/{row["dataset"]} | {row["scanner"]} | {row["host"]} | {row["version"]} | {row["variant"]} | {row["n"]} | {row["passed"]} | {row["failed"]} | {row["oracle_excluded"]} | {json.dumps(row["classifications"], ensure_ascii=False)} |')
    return '\n'.join(chunks)


HTML = r'''<!doctype html>
<html lang="ko"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Agent Guard 공개 버전 실측 비교</title>
<style>
:root{font-family:system-ui,-apple-system,"Noto Sans KR",sans-serif;color:#172237;background:#edf2f7;font-size:15px;line-height:1.6}*{box-sizing:border-box}body{margin:0}p,li,.note{overflow-wrap:anywhere}main{max-width:1500px;margin:auto;padding:28px}h1{font-size:clamp(26px,4vw,42px);line-height:1.3;letter-spacing:-1px}h2{font-size:24px;margin:0 0 18px}h3{font-size:18px}p{max-width:110ch}header{background:#12233d;color:white;padding:32px;border-radius:16px;margin-bottom:24px}header p{color:#d1e0f3}nav{display:flex;gap:15px;flex-wrap:wrap}nav a{color:#c4dfff}section{background:white;border:1px solid #d7e1ed;border-radius:14px;padding:26px;margin:20px 0;overflow:hidden}.muted{color:#526076}.small{font-size:12px}.note{border-left:4px solid #2b68a5;background:#edf5fe;padding:14px 18px;margin:16px 0}.warning{border-left-color:#aa5813;background:#fff4e5}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:12px}.card{border:1px solid #d5dfeb;border-radius:9px;padding:16px}.card b{display:block;font-size:21px}label{font-size:12px;display:block;font-weight:650}select{display:block;width:100%;margin-top:5px;background:white;padding:8px;border:1px solid #9fafc3;border-radius:6px;font:inherit;font-size:13px;color:inherit}button,.button{display:inline-block;border:0;background:#205c9b;color:white;border-radius:7px;padding:9px 14px;font:inherit;font-size:13px;cursor:pointer;text-decoration:none}button:hover{background:#153d68}button:focus,select:focus,a:focus{outline:3px solid #f4ab40;outline-offset:3px}.buttons{display:flex;gap:10px;flex-wrap:wrap;margin:15px 0}.scroll{overflow:auto}table{border-collapse:collapse;min-width:820px;width:100%;font-variant-numeric:tabular-nums;font-size:13px}th,td{text-align:left;border-bottom:1px solid #dce4ee;padding:9px 10px;vertical-align:top}th{background:#edf3fa;white-space:nowrap}td.number{text-align:right;white-space:nowrap}tbody tr:hover{background:#f5f8fc}.positive{color:#11613c}.negative{color:#9f301b}.tag{display:inline-block;background:#ecf0f5;border-radius:5px;padding:2px 7px;font-size:12px}.chart{overflow-x:auto;margin:14px 0}.chart svg{width:100%;min-width:680px;display:block}pre{white-space:pre-wrap;word-break:break-word;background:#f0f4f8;padding:16px;border-radius:8px;font-size:12px}summary{cursor:pointer;font-weight:650}footer{padding:20px;color:#526076}.legend{display:flex;gap:18px;flex-wrap:wrap;font-size:12px}.legend span:before{content:"";display:inline-block;width:12px;height:12px;background:var(--color,#3475b5);margin-right:5px}.chartlabel{font-family:system-ui,sans-serif;fill:#24364d}.empty{padding:20px;background:#fff4e5;border-radius:8px}a{color:#205c9b}.metricrow{display:flex;align-items:center;gap:15px;flex-wrap:wrap}.metricrow label{min-width:220px;flex:1}code{font-family:ui-monospace,monospace}.status{font-weight:650}.good{color:#11613c}.bad{color:#9f301b}@media(max-width:650px){main{padding:10px}section,header{padding:18px}h2{font-size:21px}}
</style>
<main>
<header><div class="small">공개 배포본 · Linux 실측 · 과거 환경 숫자 혼합 없음</div><h1>Agent Guard<br>v3.6.13 → v3.8.1 실제 비교</h1><p>공개 배포본의 기본 redactor·pipeline 경로, 선택형 출력 통합, 설치 비용, 마스킹 정확도를 구분한 한국어 실험 보고서입니다.</p><nav><a href="#conclusion">① 결론</a><a href="#versions">② 버전별 변화</a><a href="#cumulative">③ 누적 변화</a><a href="#graphs">④ 그래프</a><a href="#evidence">⑤ 조건·원시 자료</a></nav></header>
<section id="conclusion"><h2>① 한눈에 보는 결론</h2><div id="highlights"></div><details id="detailed-conclusions"><summary>조건별 실측 숫자 · 기본·선택형·비용·정확도</summary><div id="conclusions"></div></details><div class="grid" id="counts"></div><h3>사용 권고</h3><div id="recommendations"></div><div class="note">이 보고서의 “기본 경로”는 <b>공개 배포본의 redactor·pipeline 선택 기본값</b>입니다. scanner·설정·audit·release check 등은 비교를 위해 통제합니다. 전체 자연 기본 설정을 그대로 실행한 결과라는 뜻이 아닙니다. 지연은 <b>hook callback CLI</b>의 시작을 포함하며 Claude/Codex 호스트 앱 자체의 지연은 아닙니다.</div><div class="note">지연·CPU·메모리: <b>낮을수록 좋음 ↓</b> · 처리량: <b>높을수록 좋음 ↑</b><br>변화율 = (현재 / 비교 기준 − 1) × 100. <b>개선 ≥10%</b>, <b>회귀 >5%</b>를 같은 기준으로 표시합니다. 서로 다른 입력의 개선율을 임의 평균하지 않습니다.</div><div class="note warning">RSS 합은 공유 페이지를 중복 계산하는 표본 프로세스 RSS의 합입니다. <b>고유 물리 메모리 사용량이 아닙니다.</b> CLI 지연·CPU 실측과 RSS 표본 계측은 phase로 분리합니다.</div></section>
<section id="versions"><h2>② 버전별 변화</h2><p>관련 변경과 성능 인과관계는 구분합니다. 원인 분리 계측으로 확인하지 않은 설명은 추정입니다.</p><div class="scroll"><table id="changes"></table></div></section>
<section id="cumulative"><h2>③ 최초 버전 대비 누적 변화</h2><p>각 조건의 v3.6.13 실측이 기준입니다. 직전 공개 버전이 없거나 실패한 조건은 N/A입니다. A: 기본 ↔ 기본 · B: v3.8.1 기본 ↔ 선택형 fused · C: v3.6.13 기본 ↔ v3.8.1 fused. 직접 교대 비교는 <code>series=direct</code>로 확인하세요.</p><div class="grid" id="filters"></div><div id="condition-note" class="note"></div><div class="metricrow"><label>표·누적 그래프 지표<select id="metric"></select></label><span class="muted small">산포: P25–P75(IQR) · n: 성공·동일 작업 표본 수 · 비교 유효표본/쌍 9미만이면 변화율·판정 N/A</span></div><div class="scroll"><table id="runtime-table"></table></div><div class="chart" id="cumulative-chart"></div><p id="optional-comparison"></p></section>
<section id="graphs"><h2>④ 그래프 — 개선과 회귀를 같은 기준으로</h2><details><summary>동봉 정적 그림 다운로드 · 이 HTML의 내장 그래프는 추가 파일 없이 작동</summary><ul id="figure-links"></ul><p class="small muted">아래 링크는 동봉 SVG/PNG 파일을 선택해서 받는 용도입니다. 자동 로드하지 않으며 이 HTML의 표·필터·내장 그래프·JSON/CSV 다운로드에는 필요하지 않습니다.</p></details><p id="graph-condition"></p><div class="legend"><span style="--color:#3475b5">공개 배포본 중앙값</span><span style="--color:#263b54">검정 수염: P25–P75</span></div><h3>CLI 시작을 포함한 전체 지연과 CPU 시간</h3><div class="chart" id="wall-chart"></div><div class="chart" id="cpu-chart"></div><h3>단일·4동시 요청 처리량 ↑</h3><p class="small muted">같은 조건에서 workers=1과 workers=4를 분리합니다. 각각 별도 표본의 요청 수 / 전체 경과 시간입니다.</p><p class="small muted" id="throughput-source"></p><div class="chart" id="throughput-chart"></div><h3>최대 개별 자식 RSS / 표본 프로세스 RSS 합 ↓</h3><p class="small muted">최대 개별 자식 peak와 프로세스 합은 다른 측정값입니다. RSS 합은 phase=rss인 별도 계측만 사용합니다. wait4 peak에는 fork 이전 Python launcher의 RSS floor가 포함될 수 있으므로 unknown/failure 같은 짧은 경로의 값을 제품 고유 메모리로 해석하지 않습니다. floor와 scanner peak의 실제 크기는 조건별 증거를 확인하세요.</p><div class="chart" id="rss-chart"></div><div class="chart" id="rss-sum-chart"></div><h3>설치 비용 — 사용 성능과 별도</h3><p class="small muted">cached 경로의 download_bytes는 고정 공개 자산의 논리 크기이며 네트워크 전송 시간은 제외합니다. v3.6.13 동일 버전 재설치는 update와 분리한 reinstall 경로로 표시합니다. dependency-scanner 설치 크기는 home_delta_bytes로 사전 sentinel 48 B를 제외합니다. cached 업데이트는 각 target 버전의 공개 bootstrap 바이트에 운송을 고정한 재현이며 오늘의 latest bootstrap으로 중간 버전으로 이동하는 네트워크 업데이트와 구분합니다.</p><div class="grid" id="install-filters"></div><div class="note warning" id="install-condition-note"></div><div class="scroll"><table id="install-table"></table></div><div id="install-charts"></div><details><summary>설치 포함·제외 범위 / 업데이트 검증</summary><pre id="install-summary"></pre></details></section>
<section id="attribution"><h2>개선·회귀 원인 — 별도 세부 계측</h2><p>scanner 준비·실행, 프로세스 생성, JSON parsing·framing·치환 계측은 전체 CLI 지연과 별도로 해석합니다. 추적 도구의 추가 비용을 전체 사용자 경로의 성능으로 합치지 않습니다.</p><pre id="attribution-details"></pre></section>
<section id="accuracy"><h2>마스킹 정확도 · 오탐 감소 · 실패 복귀</h2><p>기존 corpus와 독립 기대값의 불일치, 정당한 버그 수정, 실제 회귀를 구분합니다. 고정 합성 사례별 계약 검증이며 실제 사용자 분포의 오탐률·탐지율을 추정하지 않습니다. 탐지 누락·과도한 마스킹·작업량 차이 표본은 동일 작업의 성능 개선으로 계산하지 않습니다.</p><p class="small muted">요약은 원본 자료의 환경·검증 범위를 유지합니다. 아래 정확도 표는 사용 성능과 별도의 환경 선택으로 봅니다.</p><details><summary>정확도 요약 원본 JSON · 전체 분류 근거</summary><pre id="correctness-summary"></pre></details><div class="grid" id="correctness-filters"></div><h3>선택 조건의 사례별 계약 검증</h3><div class="scroll"><table id="correctness-aggregate-table"></table></div><h3>원시 사례 · 실패 · 분류</h3><details><summary>보안·호환성 해석</summary><pre id="security-compatibility"></pre></details><div class="scroll"><table id="correctness-table"></table></div><p class="small muted" id="correctness-count"></p></section>
<section id="evidence"><h2>⑤ 조건과 원시 자료</h2><div class="buttons"><button id="download-json">전체 원시 JSON 다운로드</button><button id="download-csv">전체 CLI 원시 CSV</button><button id="download-aggregates">모든 집계 CSV</button><button id="download-install">설치 원시 CSV</button><button id="download-correctness">정확도 원시 CSV</button><button id="download-selected">선택 조건 집계 CSV</button><a class="button" href="README.ko.md">한국어 Markdown</a></div><h3>실제 적용 환경 · 자원 제한 · 사전 고정 절차</h3><p class="note warning">같은 2 CPU quota라도 VM의 CPU 모델이 다를 수 있습니다. 서로 다른 host/scanner 코호트의 절대 ms 차이를 프로토콜·scanner 단독 원인으로 설명하지 않습니다. 버전 효과는 같은 코호트 안에서 비교합니다.</p><div class="scroll"><table id="runtime-environment-table"></table></div><details><summary>코호트별 CPU·이미지·cgroup 원시 조건</summary><pre id="runtime-environments"></pre></details><pre id="environment"></pre><h3>버전 · 커밋 · 파일 · scanner 해시</h3><details><summary>공개 배포본·scanner·입력 파일 SHA-256 전체 보기</summary><pre id="provenance"></pre></details><h3>재현 명령</h3><pre id="reproduction"></pre><h3>실패 · 미검증 · 불확실성</h3><ul id="limitations"></ul><details><summary>원시 자료 구조와 집계 규칙</summary><p>모든 데이터는 이 HTML 안에 포함되어 있습니다. 네트워크 연결이나 외부 라이브러리는 사용하지 않습니다. 전체 원시 JSON 다운로드는 HTML과 같은 입력 자료를 내보냅니다.</p><pre id="aggregation-rules"></pre></details></section>
<footer>플랫폼과 환경을 넘어서 일반화하지 않습니다. N/A는 0이 아닙니다. 설치 비용과 사용 성능의 환경이 다르면 손익분기 횟수를 계산하지 않습니다.</footer>
</main>
<script id="report-data" type="application/json">__DATA__</script>
<script>
'use strict';
const DATA=JSON.parse(document.getElementById('report-data').textContent), VERSIONS=DATA.versions;
const E=id=>document.getElementById(id), esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const f=v=>typeof v==='number'&&Number.isFinite(v)?v.toLocaleString('ko-KR',{maximumFractionDigits:3,minimumFractionDigits:3}):'N/A';
const p=v=>typeof v==='number'&&Number.isFinite(v)?(v>=0?'+':'')+v.toFixed(2)+'%':'N/A';
const pCompare=(r,key)=>typeof r[key+'_pct']==='number'?p(r[key+'_pct']):(r[key+'_status']||'').includes('9미만')?'N/A (검증표본·유효쌍 9미만)':'N/A';
const DIM=['environment','distribution','scanner','host','audit','case','variant','series','phase','workers'];
const LABEL={environment:'환경',distribution:'배포 경로',scanner:'Scanner',host:'Host',audit:'Audit 상태',case:'입력 유형',variant:'기본 / 선택형',series:'실험 묶음',phase:'계측 종류',workers:'동시 요청 수'};
const OPTION_LABELS={case:{'small-clean':'정상 소출력 (small-clean)','many-replacement-leaves':'다수 문자열 치환 (many-replacement-leaves)','long-line':'긴 단일 줄 (long-line)','long-multiline':'긴 여러 줄 (long-multiline)','escaped-control':'여러 줄·제어 문자 (escaped-control)','dense-controls':'조밀한 제어 문자 (dense-controls)','unknown-event':'unknown 도구 통과 (unknown-event)','scanner-failure-open':'scanner 실패 복귀 (scanner-failure-open)'},variant:{default:'기본 redactor/pipeline (default)',fused:'선택형 출력 통합 (fused)'},distribution:{standalone:'독립 설치 (standalone)','source-plugin':'Git 소스 플러그인 (source-plugin)'},audit:{off:'audit 끔 (off)',warm:'audit 준비 완료 (warm)',cold:'audit 새 상태 (cold)'},series:{versions:'7버전 균형 교차 (versions)',direct:'초기↔최종 직접 비교 (direct)',optional:'선택형 추가 효과 (optional)',source:'Git 소스 플러그인 비교 (source)',audit:'audit 상태 직접 비교 (audit)',load:'4동시 처리량 (load)',rss:'별도 RSS 표본 계측 (rss)'},phase:{runtime:'전체 CLI 계측 (runtime)',rss:'별도 RSS 샘플링 (rss)'},workers:{'1':'1 — 단일 요청','4':'4 — 동시 요청'},scanner:{official:'공식 gitleaks (official)',homebrew:'실제 Homebrew scanner (homebrew)'},host:{claude:'Claude',codex:'Codex'},scenario:{'asset-network-download':'공개 자산 다운로드만 · 설치 제외','homebrew-fresh-cached':'Homebrew 새 설치 · 캐시 · 의존성 제외','homebrew-upgrade-cached':'Homebrew 지원 업그레이드 · 캐시','standalone-fresh-network':'새 설치 · 실제 네트워크 포함','standalone-fresh-cached':'새 설치 · 캐시 · 네트워크 제외','standalone-update-cached':'업데이트 · target 공개 bootstrap 운송 고정','standalone-reinstall-cached':'동일 버전 재설치 · 업데이트 아님','dependency-scanner-cached':'scanner 최초 설치 · 네트워크 제외'}};
const optionLabel=(key,value)=>OPTION_LABELS[key]?.[value]||value||'(미기록)';
const UNIQUE=(a,k)=>[...new Set(a.map(r=>String(r[k]??'')))].sort();
let selection={};
function conclusionHTML(x){if(typeof x==='string')return esc(x)+' <a href="data.json">[집계·원시 자료]</a>';return esc(x.text??JSON.stringify(x))+' '+(x.sources||[]).filter(s=>typeof s.path==='string'&&!/^(javascript|data):/i.test(s.path)).map(s=>'<a href="'+esc(s.path)+'">['+esc(s.label||'근거')+']</a>').join(' · ')}
function init(){
 const highlights=DATA.context.highlights||[];E('highlights').innerHTML=highlights.length?'<ul>'+highlights.map(x=>'<li>'+conclusionHTML(x)+'</li>').join('')+'</ul>':'<p>조건별 실제 수치와 한계를 아래에서 확인하세요.</p>';E('detailed-conclusions').open=!highlights.length;
 E('conclusions').innerHTML='<ul>'+(DATA.context.conclusions||['개별 실측 결과를 아래 동일 조건에서 확인하세요.']).map(x=>'<li>'+conclusionHTML(x)+'</li>').join('')+'</ul>';
 const failed=DATA.runtime.filter(r=>r.success===false||r.eligible===false).length;
 E('counts').innerHTML=[['공개 버전',VERSIONS.length],['원시 실행 표본',DATA.runtime.length],['성능 표본 불일치·제외',failed],['집계 행',DATA.aggregates.length]].map(([k,v])=>'<div class="card"><span>'+esc(k)+'</span><b>'+v.toLocaleString('ko-KR')+'</b></div>').join('');
 E('changes').innerHTML='<thead><tr><th>공개 버전</th><th>관련 변경 (인과 미검증 시 추정)</th></tr></thead><tbody>'+VERSIONS.map(v=>'<tr><td>'+v+'</td><td>'+esc((DATA.context.version_changes||{})[v]||'N/A — 내용 미검증')+'</td></tr>').join('')+'</tbody>';
 for(const k of DIM){const opts=UNIQUE(DATA.aggregates,k);if(!opts.length)opts.push('N/A');selection[k]=opts.includes(k==='phase'?'runtime':k==='variant'?'default':k==='series'?'versions':k==='workers'?'1':k==='audit'?'off':k==='distribution'?'standalone':k==='scanner'?'official':k==='host'?'claude':'')?(k==='phase'?'runtime':k==='variant'?'default':k==='series'?'versions':k==='workers'?'1':k==='audit'?'off':k==='distribution'?'standalone':k==='scanner'?'official':k==='host'?'claude':''):opts[0];const label=document.createElement('label');label.textContent=LABEL[k];const s=document.createElement('select');s.id='filter-'+k;s.setAttribute('aria-label',LABEL[k]);for(const o of opts)s.add(new Option(optionLabel(k,o),o));s.value=selection[k];s.onchange=()=>{selection[k]=s.value;reconcile(k);render()};label.append(s);E('filters').append(label)}
 const preferred=DATA.aggregates.find(r=>r.phase==='runtime'&&r.series==='versions'&&r.variant==='default'&&r.scanner==='official'&&r.host==='claude'&&r.audit==='off'&&r.case==='small-clean'&&String(r.workers)==='1'&&(!DATA.context.preferred_environment||r.environment===DATA.context.preferred_environment));if(preferred)for(const k of DIM){selection[k]=String(preferred[k]??'');E('filter-'+k).value=selection[k];E('filter-'+k).title=selection[k]}
 for(const [k,v]of Object.entries(DATA.metrics))E('metric').add(new Option(v[0]+' ('+v[1]+'; '+v[2]+')',k));E('metric').onchange=render;
 for(const k of ['environment','scenario']){const label=document.createElement('label');label.textContent=k==='environment'?'설치 환경':'설치 경로 / 포함 범위';const s=document.createElement('select');s.id='install-'+k;for(const o of UNIQUE(DATA.installation_aggregates,k))s.add(new Option(optionLabel(k,o),o));s.onchange=()=>{reconcileInstall(k);renderInstall()};label.append(s);E('install-filters').append(label)}
 E('recommendations').innerHTML='<ul>'+(DATA.context.recommendations||['각 입력·배포 경로별 결과와 아래 한계를 확인한 뒤 기본/선택형 경로를 결정하세요.']).map(x=>'<li>'+conclusionHTML(x)+'</li>').join('')+'</ul>';E('attribution-details').textContent=JSON.stringify(DATA.context.attribution||'N/A — 세부 원인 계측 자료 미제공',null,2);E('security-compatibility').textContent=JSON.stringify(DATA.context.security_compatibility||'N/A — 정확도 원시 자료와 한계 참조',null,2);
 const installPreferred=DATA.installation_aggregates.find(r=>r.scenario==='standalone-fresh-network'&&(!DATA.context.preferred_install_environment||r.environment===DATA.context.preferred_install_environment))||DATA.installation_aggregates.find(r=>r.scenario==='standalone-fresh-cached'&&(!DATA.context.preferred_install_environment||r.environment===DATA.context.preferred_install_environment))||DATA.installation_aggregates[0];if(installPreferred){E('install-environment').value=String(installPreferred.environment??'');E('install-scenario').value=String(installPreferred.scenario??'')}
 E('environment').textContent=JSON.stringify(Object.fromEntries(['environment','runtime_environments','limits','protocol'].map(k=>[k,DATA.context[k]??'N/A — 증거 미제공'])),null,2);
 const runtimeEnvironments=DATA.context.runtime_environments||[],envRows=Array.isArray(runtimeEnvironments)?runtimeEnvironments:Object.entries(runtimeEnvironments).map(([environment,facts])=>({environment,...(facts&&typeof facts==='object'?facts:{facts})})),envFields=['environment','scanner','host','cpu_model','image_id','cpu_max','memory_max','memory_swap_max','raw_path'];E('runtime-environments').textContent=JSON.stringify(runtimeEnvironments,null,2);E('runtime-environment-table').innerHTML='<thead><tr>'+envFields.map(k=>'<th>'+esc(k)+'</th>').join('')+'</tr></thead><tbody>'+envRows.map(r=>'<tr>'+envFields.map(k=>'<td>'+esc(typeof r[k]==='object'?JSON.stringify(r[k]):r[k]??'N/A — 원본 JSON 참조')+'</td>').join('')+'</tr>').join('')+'</tbody>';
 E('provenance').textContent=JSON.stringify({release_and_scanner:DATA.context.provenance||[],correctness_metadata:DATA.correctness_metadata,report_input_files:DATA.input_files},null,2);E('reproduction').textContent=(DATA.context.reproduction||[]).join('\n');E('limitations').innerHTML=(DATA.context.limitations||['명시되지 않은 플랫폼·경로는 미검증입니다.']).map(x=>'<li>'+esc(x)+'</li>').join('');
 for(const k of ['environment','scanner','host']){const label=document.createElement('label');label.textContent='정확도 '+(LABEL[k]||k);const s=document.createElement('select');s.id='correctness-'+k;for(const o of UNIQUE(DATA.correctness,k))s.add(new Option(optionLabel(k,o),o));s.onchange=renderCorrectness;label.append(s);E('correctness-filters').append(label)}
 const accuracyPreferred=DATA.correctness.find(r=>r.scope==='cli-independent'&&r.scanner==='official'&&r.host==='claude')||DATA.correctness.find(r=>r.scope==='cli-independent'&&r.host==='claude')||DATA.correctness.find(r=>r.host==='claude');if(accuracyPreferred)for(const k of ['environment','scanner','host'])E('correctness-'+k).value=String(accuracyPreferred[k]??'');
 E('figure-links').innerHTML=(DATA.context.figures||[]).filter(f=>typeof f.path==='string'&&/^figures\/[a-zA-Z0-9_.-]+\.(svg|png)$/.test(f.path)).map(f=>'<li><a href="'+esc(f.path)+'" download>'+esc(f.title||f.path)+'</a></li>').join('')||'<li>동봉 정적 그림 없음 — 내장 그래프는 작동합니다.</li>';
 E('install-summary').textContent=JSON.stringify(DATA.installation_summary,null,2);E('correctness-summary').textContent=JSON.stringify(DATA.correctness_summary,null,2);E('aggregation-rules').textContent=JSON.stringify(DATA.rules,null,2);
 E('download-json').onclick=()=>download('agent-guard-raw.json',JSON.stringify(DATA,null,2),'application/json');E('download-csv').onclick=()=>download('runtime-raw.csv',csv(DATA.runtime),'text/csv');E('download-aggregates').onclick=()=>download('aggregates.csv',csv(DATA.aggregates),'text/csv');E('download-install').onclick=()=>download('installation-raw.csv',csv(DATA.installation),'text/csv');E('download-correctness').onclick=()=>download('correctness-raw.csv',csv(DATA.correctness),'text/csv');E('download-selected').onclick=()=>download('selected-aggregates.csv',csv(selected()),'text/csv');
 reconcile('environment');render();renderInstall();renderCorrectness();
}
function reconcile(changed){let candidates=DATA.aggregates.filter(r=>String(r[changed]??'')===selection[changed]&&(changed==='environment'||String(r.environment??'')===selection.environment));if(!candidates.length)candidates=DATA.aggregates.filter(r=>String(r[changed]??'')===selection[changed]);let best=null,score=-1;for(const r of candidates){const points=DIM.reduce((n,k)=>n+(String(r[k]??'')===selection[k]?(k==='environment'?100:k==='series'?8:1):0),0);if(points>score){score=points;best=r}}if(best)for(const k of DIM){selection[k]=String(best[k]??'');E('filter-'+k).value=selection[k];E('filter-'+k).title=selection[k]}for(const k of ['scanner','host'])for(const o of E('filter-'+k).options)o.disabled=!DATA.aggregates.some(r=>String(r.environment??'')===selection.environment&&String(r[k]??'')===o.value)}
function selected(override={}){const s={...selection,...override};return DATA.aggregates.filter(r=>DIM.every(k=>s[k]==='*'||String(r[k]??'')===s[k]))}
function missingReason(version,metric,s=selection){const idx=VERSIONS.indexOf(version);if(metric==='rss_sum_peak_kib'&&s.phase!=='rss')return 'RSS 합은 phase=rss·series=rss에서 별도로 계측합니다. runtime 기본 표의 N/A는 0이 아닙니다.';if(s.phase==='rss'&&['wall_ms','cpu_ms','throughput_rps'].includes(metric))return 'RSS 샘플링의 계측 비용을 CLI 지연·CPU·처리량 집계에서 제외했습니다. phase=runtime을 선택하세요.';if(s.variant==='fused'&&idx<5)return '공개 선택형 출력 통합(fused) 미지원 — 지원은 v3.8.0부터입니다. 개발자 빌드로 공개 지원 기능을 추정하지 않습니다.';if(s.series==='optional'&&idx<5)return '선택형 추가 효과 비교는 지원하는 공개 v3.8.0·v3.8.1만 측정했습니다.';if(s.variant==='fused'&&['load','rss'].includes(s.series)&&idx!==6)return '4동시·별도 RSS의 fused는 v3.8.1만 측정했습니다. v3.8.0 지원을 해당 항목 실측으로 대신하지 않습니다.';if(['direct','audit','source'].includes(s.series)&&![0,6].includes(idx))return '이 실험 묶음은 v3.6.13·v3.8.1만 직접 비교했습니다. 중간 공개 버전은 미측정입니다.';if(s.variant==='fused'&&s.series==='load'&&idx!==6)return '4동시 fused는 v3.8.1만 측정했습니다. v3.8.0 기능 지원을 처리량 실측으로 대신하지 않습니다.';const raw=DATA.runtime.filter(r=>r.version===version&&DIM.every(k=>String(r[k]??'')===String(s[k]??'')));if(raw.length&&!raw.some(r=>r.success!==false&&r.eligible!==false))return '실제 표본 '+raw.length+'개 모두 종료·출력·timeout 검증 불일치로 동일 작업 집계에서 제외했습니다. 원시 실패는 보존합니다.';if(raw.length)return '실행 기록은 있으나 이 지표의 유효 표본은 없습니다. 샘플링 범위·실패 원시 자료를 확인하세요.';return '이 선택 환경·scanner·host·audit·입력·경로 조합은 미측정입니다. 다른 환경의 숫자로 채우지 않습니다.'}
function graphMissingReason(id,version,percent,row,worker){if(percent&&row&&(row.n<9||(row.variant==='fused'?row.cross_variant_baseline_status:row.cumulative_status).includes('9미만')))return '검증표본 또는 동일 round 유효쌍이 9미만이어서 변화율·개선/회귀 판정은 N/A입니다. 중앙값·IQR·n은 서술 통계로 유지합니다.';if(percent&&row)return '같은 조건의 v3.6.13 기준 표본이 없어 변화율 N/A입니다. 실제 측정값은 표에 유지합니다. fused의 C 비교는 direct 묶음에서 확인하세요.';if(id.startsWith('install-chart-')){const scenario=E('install-scenario').value;if(scenario==='homebrew-fresh-cached')return '이 Homebrew 설치 비용은 v3.6.13·v3.8.1만 실측했습니다. 중간 버전은 미측정입니다.';if(scenario==='homebrew-upgrade-cached')return '실제 Homebrew 지원 업그레이드는 v3.6.13→v3.8.1만 측정했습니다.';if(scenario.includes('reinstall'))return '동일 버전 재설치는 기준 v3.6.13만 측정했습니다. upgrade와 분리합니다.';if(scenario.includes('update')&&version==='v3.6.13')return '기준의 동일 버전 재설치는 reinstall 조건으로 분리했습니다. 이전 버전에서의 upgrade가 아닙니다.';return '선택한 설치 환경에서 이 공개 버전·비용 항목은 미측정 또는 해당하지 않습니다.'}const metric={'wall-chart':'wall_ms','cpu-chart':'cpu_ms','throughput-chart':'throughput_rps','rss-chart':'max_child_rss_kib','rss-sum-chart':'rss_sum_peak_kib'}[id]||E('metric').value,s={...selection};if(id==='rss-sum-chart'){s.phase='rss';s.series='rss'}if(id==='throughput-chart'){s.phase='runtime';s.workers=worker;s.series=worker==='4'?'load':selection.series==='load'?'versions':selection.series}return missingReason(version,metric,s)}
function table(rows,metric){const map=new Map(rows.filter(r=>r.metric===metric).map(r=>[r.version,r]));return '<thead><tr><th>공개 버전</th><th>중앙값</th><th>P25–P75</th><th>n / 제외</th><th>직전 공개 버전 대비</th><th>v3.6.13 대비</th><th>동일 버전 기본 대비(B)</th><th>v3.6.13 기본 대비(C)</th><th>누적 판정(A·C)</th></tr></thead><tbody>'+VERSIONS.map(v=>{const r=map.get(v);return r?'<tr><td>'+v+'</td><td class="number">'+f(r.median)+' '+esc(r.unit)+'</td><td class="number">'+f(r.p25)+'–'+f(r.p75)+'</td><td class="number">'+r.n+' / '+r.excluded_samples+'</td><td class="number">'+pCompare(r,'previous')+'</td><td class="number">'+pCompare(r,'cumulative')+'</td><td class="number">'+pCompare(r,'optional')+'</td><td class="number">'+pCompare(r,'cross_variant_baseline')+'</td><td class="status '+(r.display_cumulative_status.startsWith('개선')?'good':r.display_cumulative_status.startsWith('회귀')?'bad':'')+'">'+esc(r.display_cumulative_status)+'</td></tr>':'<tr><td>'+v+'</td><td colspan="8">N/A — '+esc(missingReason(v,metric))+'</td></tr>'}).join('')+'</tbody>'}
function render(){const rs=selected(),metric=E('metric').value,meta=DATA.metrics[metric],batch=Number(selection.workers)>1,batchUnit=batch?'ms/'+selection.workers+'요청 묶음':'ms',metricLabel=(rs.find(r=>r.metric===metric)||{}).label||meta[0];for(const option of E('metric').options){const m=DATA.metrics[option.value],u=batch&&['wall_ms','cpu_ms'].includes(option.value)?batchUnit:m[1];option.textContent=m[0]+' ('+u+'; '+m[2]+')'}E('condition-note').innerHTML='<b>선택 조건:</b> '+DIM.map(k=>esc(LABEL[k])+'='+esc(selection[k])).join(' · ')+'<br><b>환경이 다르면 조건이 달라집니다.</b> 같은 2 CPU quota라도 VM CPU 모델이 다를 수 있어 다른 host/scanner 코호트의 절대 ms 차이를 프로토콜·scanner 단독 원인으로 단정할 수 없습니다. 이 화면은 선택한 코호트 안에서만 비교합니다. 전체 CLI와 RSS 표본 실험은 분리합니다. workers=4의 지연·CPU는 4요청 묶음 전체 비용입니다.';E('runtime-table').innerHTML=table(rs,metric);E('graph-condition').textContent=DIM.filter(k=>!['workers','phase'].includes(k)).map(k=>LABEL[k]+'='+selection[k]).join(' · ');draw('cumulative-chart',rs.filter(r=>r.metric===metric),metricLabel+(selection.variant==='fused'?' — v3.6.13 기본 대비(C)':' — v3.6.13 대비 변화율'), '%',true);draw('wall-chart',selected({phase:'runtime'}).filter(r=>r.metric==='wall_ms'),(batch?selection.workers+'요청 묶음 완료 지연 ↓':'CLI 전체 지연 ↓'),batchUnit);draw('cpu-chart',selected({phase:'runtime'}).filter(r=>r.metric==='cpu_ms'),(batch?selection.workers+'요청 CPU 합계 ↓':'CLI CPU 시간 ↓'),batchUnit);const oneSeries=selection.series==='load'?'versions':selection.series,one=selected({phase:'runtime',workers:'1',series:oneSeries}).filter(r=>r.metric==='throughput_rps'),four=selected({phase:'runtime',workers:'4',series:'load'}).filter(r=>r.metric==='throughput_rps');E('throughput-source').textContent='단일 요청 출처: series='+oneSeries+' (requests=1), 4동시 출처: series=load (requests=4). 선택환경·배포경로·scanner·host·audit·입력·variant는 동일하게 유지합니다. 해당 묶음에 없는 입력은 N/A.';draw('throughput-chart',one.concat(four),'처리량 ↑ — 동시 요청 수별','요청/s',false,'workers');draw('rss-chart',selected({phase:'runtime'}).filter(r=>r.metric==='max_child_rss_kib'),'최대 개별 자식 RSS ↓','KiB');draw('rss-sum-chart',selected({phase:'rss',series:'rss'}).filter(r=>r.metric==='rss_sum_peak_kib'),'별도 RSS 실험(series=rss) — 프로세스 RSS 합 최대 ↓','KiB');const opt=rs.filter(r=>r.version==='v3.8.1'&&r.metric===metric&&r.variant==='fused')[0];E('optional-comparison').textContent=opt?'B: 동일 v3.8.1 기본 대비 선택형 변화 '+p(opt.optional_pct)+' ('+opt.optional_status+'). C: v3.6.13 기본 대비 '+p(opt.cross_variant_baseline_pct)+' ('+opt.cross_variant_baseline_status+').':'선택형 추가 효과는 variant=fused와 해당 기능을 지원하는 series 조건에서 확인하세요.';renderCorrectness();renderInstall()}
function draw(id,rows,title,unit,percent=false,group=''){const target=E(id);if(!rows.length){target.innerHTML='<div class="empty">N/A — '+esc(title)+': '+esc(id==='rss-sum-chart'?'RSS 합은 별도 series=rss에서 many-replacement-leaves·long-multiline 입력을 표본 계측했습니다. 현재 선택한 입력·경로 조합의 유효 실측은 없습니다. 버전별 범위는 원시 protocol과 표본을 확인하세요.':id.startsWith('install-chart-')?'현재 설치 경로에서 이 비용 항목은 측정하지 않았거나 해당하지 않습니다. 다운로드만 측정한 단계의 설치 크기는 N/A입니다.':'현재 선택 환경·실험 묶음·입력에서 이 지표는 미측정 또는 검증 불일치로 제외되었습니다.')+'</div>';return}const W=1100,H=320,L=85,R=30,T=48,B=80,plotW=W-L-R,plotH=H-T-B,groups=group==='workers'?['1','4']:group?UNIQUE(rows,group):[''];let vals=rows.map(r=>percent?(r.variant==='fused'?r.cross_variant_baseline_pct:r.cumulative_pct):r.maximum).filter(v=>typeof v==='number');if(!vals.length){target.innerHTML='<div class="empty">N/A — 같은 조건의 v3.6.13 기준 표본이 없습니다.</div>';return}const min=percent?Math.min(0,...vals)*1.12:0,max=Math.max(0,...vals)*1.12||1,range=max-min||1,y=v=>T+(max-v)/range*plotH,step=plotW/VERSIONS.length,bw=Math.min(68,step*.7/groups.length),colors=['#3475b5','#a56820','#637d49'];let svg='<svg viewBox="0 0 '+W+' '+H+'" role="img" aria-label="'+esc(title)+'"><title>'+esc(title)+'; 단위 '+esc(unit)+'; 기준 v3.6.13; 각 막대에 n 표시</title><text x="'+L+'" y="22" class="chartlabel" font-size="16" font-weight="600">'+esc(title)+' ('+esc(unit)+')</text>';for(let i=0;i<=4;i++){const value=min+range*i/4,yy=y(value);svg+='<line x1="'+L+'" y1="'+yy+'" x2="'+(W-R)+'" y2="'+yy+'" stroke="#dbe4ef"/><text x="'+(L-9)+'" y="'+(yy+4)+'" text-anchor="end" class="chartlabel" font-size="11">'+value.toFixed(percent&&range<5?2:1)+'</text>'}svg+='<line x1="'+L+'" y1="'+y(0)+'" x2="'+(W-R)+'" y2="'+y(0)+'" stroke="#63758c"/>';VERSIONS.forEach((v,i)=>{svg+='<text x="'+(L+(i+.5)*step)+'" y="'+(H-B+30)+'" text-anchor="middle" class="chartlabel" font-size="12">'+v+'</text>';groups.forEach((g,j)=>{const r=rows.find(r=>r.version===v&&(!group||String(r[group])===g)),value=r&&(percent?(r.variant==='fused'?r.cross_variant_baseline_pct:r.cumulative_pct):r.median),x=L+(i+.5)*step+(j-groups.length/2)*bw;if(!r||typeof value!=='number'){svg+='<text x="'+(x+bw/2)+'" y="'+(H-B+12)+'" text-anchor="middle" class="chartlabel" font-size="10">N/A<title>'+esc(graphMissingReason(id,v,percent,r,g))+'</title></text>';return}const yy=y(value),zero=y(0),height=Math.max(1,Math.abs(yy-zero));svg+='<rect x="'+(x+2)+'" y="'+Math.min(yy,zero)+'" width="'+(bw-4)+'" height="'+height+'" fill="'+colors[j%colors.length]+'"><title>'+esc(v+(group?' '+group+'='+g:'')+': '+f(value)+' '+unit+'; n='+r.n+(percent?'; '+(r.variant==='fused'?r.cross_variant_baseline_status:r.cumulative_status):'; P25='+f(r.p25)+', P75='+f(r.p75)))+'</title></rect>';if(!percent&&typeof r.p25==='number'){const cx=x+bw/2;svg+='<path d="M'+cx+','+y(r.p25)+'V'+y(r.p75)+'M'+(cx-5)+','+y(r.p25)+'h10M'+(cx-5)+','+y(r.p75)+'h10" stroke="#1c304a" stroke-width="1.7" fill="none"/>'}svg+='<text x="'+(x+bw/2)+'" y="'+(Math.min(yy,zero)-7)+'" text-anchor="middle" class="chartlabel" font-size="10">'+(percent?p(value):f(value))+'</text><text x="'+(x+bw/2)+'" y="'+(H-B+48)+'" text-anchor="middle" class="chartlabel" font-size="10">n='+r.n+(group?' / '+g+'동시':'')+'</text>'})});svg+='<text x="'+L+'" y="'+(H-10)+'" class="chartlabel" font-size="11">기준: v3.6.13 · '+(percent?'음수: 비용 감소, 양수: 비용 증가 (처리량은 반대)':'중앙값 · 수염: P25–P75 · 높이 0과 N/A는 다름')+'</text></svg>';target.innerHTML=svg}
function reconcileInstall(changed){const env=E('install-environment').value,scenario=E('install-scenario').value;if(DATA.installation_aggregates.some(r=>String(r.environment??'')===env&&String(r.scenario??'')===scenario))return;const candidates=DATA.installation_aggregates.filter(r=>changed==='environment'?String(r.environment??'')===env:String(r.scenario??'')===scenario),best=candidates.find(r=>r.scenario==='standalone-fresh-network')||candidates.find(r=>r.scenario==='standalone-fresh-cached')||candidates[0];if(best){E('install-environment').value=String(best.environment??'');E('install-scenario').value=String(best.scenario??'')}}
function renderInstall(){const env=E('install-environment').value,scenario=E('install-scenario').value,rs=DATA.installation_aggregates.filter(r=>String(r.environment??'')===env&&String(r.scenario??'')===scenario);E('install-condition-note').textContent='설치 환경='+env+' / 경로='+scenario+' · 현재 사용 성능 환경='+selection.environment+'. 환경 라벨이 다르면 조건이 다릅니다. 설치와 사용 성능의 비용 상쇄 횟수를 계산하지 않습니다. '+(rs[0]?.scope_display||'범위: 해당 조건 자료 없음')+' '+(rs[0]?.scope_display_note||'');E('install-table').innerHTML='<thead><tr><th>대상 버전</th><th>출발 버전</th><th>지표</th><th>중앙값</th><th>P25–P75</th><th>n</th><th>직전 대비</th><th>v3.6.13 대비</th><th>누적 판정</th></tr></thead><tbody>'+(rs.length?rs.map(r=>'<tr><td>'+esc(r.version)+'</td><td>'+esc(r.from_version||'새 설치')+'</td><td>'+esc(r.label)+'</td><td class="number">'+f(r.median)+' '+esc(r.unit)+'</td><td class="number">'+f(r.p25)+'–'+f(r.p75)+'</td><td>'+r.n+'</td><td>'+pCompare(r,'previous')+'</td><td>'+pCompare(r,'cumulative')+'</td><td class="status '+(r.cumulative_status.startsWith('개선')?'good':r.cumulative_status.startsWith('회귀')?'bad':'')+'">'+esc(r.cumulative_status)+'</td></tr>').join(''):'<tr><td colspan="9">N/A — 해당 설치 경로 결과 없음</td></tr>')+'</tbody>';E('install-charts').innerHTML='';for(const [metric,meta]of Object.entries(DATA.install_metrics)){const chart=document.createElement('div');chart.id='install-chart-'+metric;chart.className='chart';E('install-charts').append(chart);const points=rs.filter(r=>r.metric===metric),label=points[0]?.label||meta[0];draw(chart.id,points,label+' ↓ — '+scenario,meta[1])}}
function renderCorrectness(){const rs=DATA.correctness.filter(r=>['environment','scanner','host'].every(k=>String(r[k]??'')===E('correctness-'+k).value));const aggs=DATA.correctness_aggregates.filter(r=>['environment','scanner','host'].every(k=>String(r[k]??'')===E('correctness-'+k).value));E('correctness-aggregate-table').innerHTML='<thead><tr><th>검증 범위 / 자료</th><th>버전</th><th>경로</th><th>유효 사례 n</th><th>일치</th><th>불일치</th><th>oracle 제외</th><th>분류별 사례 수</th></tr></thead><tbody>'+aggs.map(r=>'<tr><td>'+esc(r.scope)+' / '+esc(r.dataset)+'</td><td>'+esc(r.version)+'</td><td>'+esc(r.variant)+'</td><td>'+r.n+'</td><td>'+r.passed+'</td><td>'+r.failed+'</td><td>'+r.oracle_excluded+'</td><td>'+esc(JSON.stringify(r.classifications))+'</td></tr>').join('')+'</tbody>';const fields=['environment','version','variant','scanner','host','case','expected_match','success','same_work_eligible','oracle_invalid','included_in_accuracy_count','classification_analysis','classification','reason','raw_path'];E('correctness-table').innerHTML='<thead><tr>'+fields.map(k=>'<th>'+esc(k)+'</th>').join('')+'</tr></thead><tbody>'+rs.slice(0,500).map(r=>'<tr>'+fields.map(k=>'<td>'+esc(typeof r[k]==='object'?JSON.stringify(r[k]):r[k]??'N/A')+'</td>').join('')+'</tr>').join('')+'</tbody>';E('correctness-count').textContent='선택한 정확도 환경/host/scanner에 해당하는 원시 행 '+rs.length+'개. 화면은 최대 500행, 전체는 원시 JSON 다운로드에 보존합니다.'}
function csv(rs){if(!rs.length)return'';const keys=[...new Set(rs.flatMap(r=>Object.keys(r)))],q=v=>'"'+String(typeof v==='object'&&v!==null?JSON.stringify(v):v??'').replace(/"/g,'""')+'"';return keys.map(q).join(',')+'\r\n'+rs.map(r=>keys.map(k=>q(r[k])).join(',')).join('\r\n')}
function download(name,text,type){const a=document.createElement('a'),url=URL.createObjectURL(new Blob([(type==='text/csv'?'\ufeff':''),text],{type:type+';charset=utf-8'}));a.href=url;a.download=name;document.body.append(a);a.click();a.remove();setTimeout(()=>URL.revokeObjectURL(url),1000)}
init();
</script></html>'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime', required=True)
    parser.add_argument('--metadata')
    parser.add_argument('--installation')
    parser.add_argument('--installation-summary')
    parser.add_argument('--correctness')
    parser.add_argument('--correctness-summary')
    parser.add_argument('--out', required=True)
    args = parser.parse_args()
    runtime = rows(read(args.runtime, []))
    install = rows(read(args.installation, []))
    correctness_doc = read(args.correctness, [])
    correctness = rows(correctness_doc)
    correctness_environment = correctness_doc.get('label', '미기록 — 환경 추정 금지') if isinstance(correctness_doc, dict) else '미기록 — 환경 추정 금지'
    correctness = [dict(row, environment=row.get('environment', correctness_environment)) for row in correctness]
    data = {'versions': VERSIONS, 'runtime': runtime, 'aggregates': runtime_aggregates(runtime), 'installation': install, 'installation_aggregates': installation_aggregates(install), 'installation_summary': read(args.installation_summary, {}), 'correctness': correctness, 'correctness_metadata': {k: v for k, v in correctness_doc.items() if k not in ['rows','samples','results','measurements']} if isinstance(correctness_doc, dict) else {}, 'correctness_summary': read(args.correctness_summary, {}), 'context': read(args.metadata, {}), 'metrics': METRICS, 'install_metrics': INSTALL_METRICS, 'rules': {'median': 'sample median', 'dispersion': 'P25–P75, linear interpolation at (n−1)q', 'delta': '(current median / comparison median − 1) × 100', 'thresholds_fixed': {'improvement_at_least_pct': 10, 'regression_above_pct': 5}, 'exclusion': 'success=false or eligible=false excluded; all raw rows preserved', 'RSS': 'max individual child peak is distinct from sampled process RSS sum; sum includes duplicate shared pages', 'phases': 'warmup/trace raw evidence only; phase=rss polling wall/CPU excluded from runtime aggregates', 'minimum_verified_comparison_samples': 9, 'paired_comparison': 'same-round verified intersections must be at least 9; optional within-version B is paired, optional previous-version ratio compares separate blocks in the same VM', 'previous': 'immediately previous public version only; no skipping N/A', 'cumulative': 'same-condition v3.6.13 median; no sum of historical percentages'}}
    source_paths = [args.runtime, args.metadata, args.installation, args.installation_summary, args.correctness, args.correctness_summary, __file__]
    data['input_files'] = [{'path': str(p), 'sha256': hashlib.sha256(Path(p).read_bytes()).hexdigest()} for p in source_paths if p and Path(p).is_file()]
    data['correctness_aggregates'] = correctness_aggregates(correctness)
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    payload = json.dumps(data, ensure_ascii=False, separators=(',', ':')).replace('<', '\\u003c').replace('>', '\\u003e').replace('&', '\\u0026')
    (out / 'report.ko.html').write_text(HTML.replace('__DATA__', payload))
    rendered_markdown = markdown(data)
    (out / 'README.ko.md').write_text(rendered_markdown)
    (out / 'data.json').write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n')
    (out / 'aggregates.csv').write_text(csv_text(data['aggregates']))
    (out / 'runtime-raw.csv').write_text(csv_text(runtime))
    (out / 'installation-aggregates.csv').write_text(csv_text(data['installation_aggregates']))
    (out / 'correctness-aggregates.csv').write_text(csv_text(data['correctness_aggregates']))
    artifact_hashes = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in out.iterdir() if p.name in ['report.ko.html', 'README.ko.md', 'data.json', 'aggregates.csv', 'runtime-raw.csv', 'installation-aggregates.csv', 'correctness-aggregates.csv']}
    (out / 'artifact-hashes.json').write_text(json.dumps(artifact_hashes, indent=2) + '\n')
    # The exact same aggregate objects back HTML, Markdown and CSV.
    embedded = json.loads((out / 'report.ko.html').read_text().split('<script id="report-data" type="application/json">', 1)[1].split('</script>', 1)[0])
    csv_rows = list(csv.DictReader(io.StringIO((out / 'aggregates.csv').read_text())))
    assert embedded == json.loads(json.dumps(data, ensure_ascii=False))
    assert len(csv_rows) == len(data['aggregates'])
    for raw, source in zip(csv_rows, data['aggregates']):
        for k in ['median', 'p25', 'p75', 'n']:
            assert float(raw[k]) == source[k]
        expected_line = f'| {source["version"]} | {fmt(source["median"])} | {fmt(source["p25"])}–{fmt(source["p75"])} | {source["n"]} | {pct_comparison(source, "previous")} | {pct_comparison(source, "cumulative")} | {pct_comparison(source, "optional")} | {pct_comparison(source, "cross_variant_baseline")} | {source["display_cumulative_status"]} |'
        assert expected_line in rendered_markdown
    install_csv = list(csv.DictReader(io.StringIO((out / 'installation-aggregates.csv').read_text())))
    assert len(install_csv) == len(data['installation_aggregates'])
    for raw, source in zip(install_csv, data['installation_aggregates']):
        for k in ['median', 'p25', 'p75', 'n']:
            assert float(raw[k]) == source[k]
        assert f'| {source["environment"]} | {source["scenario"]} | {source["version"]} | {source["from_version"] or "새 설치"} | {source["label"]} ({source["unit"]}) | {fmt(source["median"])} |' in rendered_markdown
    correctness_csv = list(csv.DictReader(io.StringIO((out / 'correctness-aggregates.csv').read_text())))
    assert len(correctness_csv) == len(data['correctness_aggregates'])
    for raw, source in zip(correctness_csv, data['correctness_aggregates']):
        for k in ['n', 'passed', 'failed', 'oracle_excluded']:
            assert int(raw[k]) == source[k]
        assert f'| {source["version"]} | {source["variant"]} | {source["n"]} | {source["passed"]} | {source["failed"]} | {source["oracle_excluded"]} |' in rendered_markdown
    verification = {'html_embedded_data_equals_json': True, 'csv_numeric_values_equal_json': True, 'markdown_all_numeric_rows_equal_rounded_json': True, 'installation_csv_numeric_values_equal_json': True, 'correctness_csv_and_markdown_counts_equal_json': True, 'runtime_rows': len(runtime), 'aggregate_rows': len(data['aggregates']), 'browser_ui_checked': False, 'note': 'Browser UI verification is a separate required step; this script does not claim it.'}
    (out / 'data-validation.json').write_text(json.dumps(verification, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(verification, ensure_ascii=False))


if __name__ == '__main__':
    main()
