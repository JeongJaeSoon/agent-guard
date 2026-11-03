#!/usr/bin/env python3
"""Generate a self-contained Korean HTML report and exportable SVG charts."""
import argparse
import html
import json
from pathlib import Path
import random
import statistics as stats

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

ROOT = Path(__file__).resolve().parents[2]
COLORS = ['#8b98aa', '#00877d']


def cpu(row, backend):
    usage = row['resource_usage'][backend]
    return stats.median(a + b for a, b in zip(usage['user_cpu_seconds']['samples'], usage['system_cpu_seconds']['samples']))


def delta(old, new):
    return 100 * (new / old - 1) if old else 0


def interval(row):
    a = row['seconds']['baseline']['samples']
    b = row['seconds']['candidate']['samples']
    rng = random.Random(60261104)
    samples = []
    for _ in range(2000):
        indices = rng.choices(range(len(a)), k=len(a))
        samples.append(delta(stats.median([a[i] for i in indices]), stats.median([b[i] for i in indices])))
    samples.sort()
    return samples[49], samples[1949]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--results', type=Path, required=True)
    parser.add_argument('--html', type=Path, default=ROOT / 'docs/rust-performance.ko.html')
    args = parser.parse_args()
    read = lambda name: json.loads((args.results / name).read_text())
    claude, codex, kernel = read('cli-claude.json'), read('cli-codex.json'), read('kernel.json')
    control = read('cli-shell-control.json')
    supplemental = read('supplemental-verification.json')
    followup = read('cli-clean-followup.json')
    verification, differential, integration = read('verification.json'), read('differential.json'), read('integration.json')
    ci_path = args.results / 'ci.json'
    ci = json.loads(ci_path.read_text()) if ci_path.exists() else {}
    required_ci = {'CI', 'Experimental native redactor', 'Legacy jq and awk contracts'}
    ci_complete = required_ci <= {w['name'] for w in ci.get('workflows', []) if w.get('conclusion') == 'success'}
    if ci:
        assert ci['cli_sha256'] == verification['before_sha256']
    legacy_integration = read('integration-jq16.json')
    assert legacy_integration['failed'] == 0
    loads = [json.loads(p.read_text()) for p in sorted(args.results.glob('load-*.json'))]
    assert len(loads) == 12 and all(x['verified'] for x in loads)
    assert verification['stable'] and all(x['status'] == 0 for x in verification['results'])
    assert differential['failed'] == integration['failed'] == supplemental['failed'] == 0
    assert all(row['verified'] for report in [claude, codex, control, kernel, followup] for row in report['cases'])
    for measured in [claude, codex, control, followup]:
        assert measured['binary_sha256']['candidate'] == verification['after_sha256']
        assert measured['binary_sha256']['baseline'] == claude['binary_sha256']['baseline']
        assert measured['scanner_sha256'] == claude['scanner_sha256']
        assert measured['config_sha256'] == claude['config_sha256']
        if measured['native_core_sha256']:
            assert measured['native_core_sha256'] == kernel['native_sha256']
    assets = args.html.parent / 'assets'
    assets.mkdir(exist_ok=True)
    plt.rcParams.update({'font.family': 'DejaVu Sans', 'font.size': 10, 'axes.spines.top': False,
                         'axes.spines.right': False, 'svg.fonttype': 'path'})
    def save(fig, name):
        path = assets / ('rust-' + name + '.svg')
        fig.savefig(path, format='svg', bbox_inches='tight', facecolor='white')
        plt.close(fig)
        text = '\n'.join(line.rstrip() for line in path.read_text().splitlines()) + '\n'
        path.write_text(text)
        return text[text.index('<svg'):]
    charts = {}
    rows = claude['cases']
    for metric in ['latency', 'cpu', 'rss']:
        ratios = []
        for row in rows:
            if metric == 'latency':
                old, new = [row['seconds'][b]['median'] for b in ['baseline', 'candidate']]
            elif metric == 'cpu':
                old, new = [cpu(row, b) for b in ['baseline', 'candidate']]
            else:
                old, new = [row['resource_usage'][b]['max_child_peak_rss_kib']['median'] for b in ['baseline', 'candidate']]
            ratios.append(new / old * 100)
        fig, ax = plt.subplots(figsize=(11, max(5, len(rows) * .3)))
        bars = ax.barh([r['name'] for r in rows], ratios, color=[COLORS[1] if r <= 100 else '#c66c38' for r in ratios])
        ax.axvline(100, color='#26394a', linestyle='--', linewidth=1)
        ax.invert_yaxis()
        ax.set_xlabel('Rust / optimized shell (%) — lower is better; baseline = 100%')
        ax.set_xlim(0, max(120, max(ratios) * 1.15))
        for bar, number in zip(bars, ratios):
            ax.text(number + 1, bar.get_y() + bar.get_height() / 2, f'{number:.1f}%', va='center', fontsize=8)
        charts[metric] = save(fig, metric)
    fig, ax = plt.subplots(figsize=(10, 3.8))
    names, gains = [], []
    for row in kernel['cases']:
        names.append(row['name'])
        gains.append(row['medians']['shell-jq']['wall_seconds'] / row['medians']['rust']['wall_seconds'])
    bars = ax.barh(names, gains, color=COLORS[1])
    ax.invert_yaxis(); ax.set_xlabel('One-shot redactor speedup (includes process startup)')
    ax.set_xlim(0, max(gains) * 1.15)
    for bar, gain in zip(bars, gains):
        ax.text(gain + .05, bar.get_y() + bar.get_height() / 2, f'{gain:.1f}x', va='center')
    charts['kernel'] = save(fig, 'kernel')
    fig, axes = plt.subplots(1, 2, figsize=(11, 3.7))
    for ax, field, title in [(axes[0], 'requests_per_second', 'Concurrent throughput (requests/s)'),
                              (axes[1], 'memory', 'Sampled sum of process RSS (MiB)')]:
        for index, backend in enumerate(['shell', 'rust']):
            values = []
            for workers in [1, 4]:
                selected = [r for r in loads if r['workers'] == workers and r['backend'] == backend]
                values.append(stats.median(r['sampled_process_rss_peak_kib'] / 1024 if field == 'memory' else r[field] for r in selected))
            positions = [0 + index * .35, 1 + index * .35]
            bars = ax.bar(positions, values, width=.35, color=COLORS[index], label=backend)
            for bar, value in zip(bars, values):
                ax.text(bar.get_x() + bar.get_width()/2, value, f'{value:.2f}', ha='center', va='bottom', fontsize=9)
            ax.margins(y=.15)
        ax.set_xticks([.175, 1.175], ['1 worker', '4 workers']); ax.set_title(title); ax.legend()
    charts['load'] = save(fig, 'load')
    load_summary = {}
    for workers in [1, 4]:
        load_summary[str(workers)] = {}
        for backend in ['shell', 'rust']:
            selected = [r for r in loads if r['workers'] == workers and r['backend'] == backend]
            load_summary[str(workers)][backend] = {
                'requests_per_second': stats.median(r['requests_per_second'] for r in selected),
                'cpu_seconds_per_request': stats.median((r['user_cpu_seconds']+r['system_cpu_seconds']) / r['requests'] for r in selected),
                'sampled_sum_rss_mib': stats.median(r['sampled_process_rss_peak_kib'] / 1024 for r in selected),
            }
    load_table = ''.join(f'<tr><td>{workers}</td><td>{backend}</td><td>{values["requests_per_second"]:.2f}</td><td>{values["cpu_seconds_per_request"]*1000:.1f}</td><td>{values["sampled_sum_rss_mib"]:.1f}</td></tr>' for workers, backends in load_summary.items() for backend, values in backends.items())
    core_hot = next(r for r in kernel['cases'] if r['name'] == 'many-leaves')
    core_note = f'다수 문자열 치환 코어: {core_hot["medians"]["shell-jq"]["wall_seconds"]*1000:.1f} → {core_hot["medians"]["rust"]["wall_seconds"]*1000:.1f} ms. 이 구간에서 줄어든 시간이 전체 CLI의 감소 폭을 대부분 설명합니다.'
    hot = next(r for r in rows if r['name'] == 'many-replacement-leaves')
    hot_wall = delta(hot['seconds']['baseline']['median'], hot['seconds']['candidate']['median'])
    hot_cpu = delta(cpu(hot, 'baseline'), cpu(hot, 'candidate'))
    hot_rss = delta(*[hot['resource_usage'][b]['max_child_peak_rss_kib']['median'] for b in ['baseline', 'candidate']])
    hot_ci = interval(hot)
    regressions = [host + '/' + r['name'] for host, report in [('Claude', claude), ('Codex', codex)] for r in report['cases'] if delta(r['seconds']['baseline']['median'], r['seconds']['candidate']['median']) > 5]
    metric_gate = (hot_wall <= -10 or hot_cpu <= -10) and not regressions
    adopt = metric_gate and ci_complete
    if adopt:
        verdict = '선택형 Rust 코어 채택 권장'
    elif metric_gate:
        verdict = 'Rust 성능 이득 확인 · CI 최종 확인 중'
    elif hot_wall <= -10 or hot_cpu <= -10:
        verdict = 'Rust 코어의 국소 이득 확인 · 회귀 항목 확인 필요'
    else:
        verdict = 'Rust 채택 보류 · 목표 수준의 실익 미확인'
    table = []
    for host, report in [('Claude', claude), ('Codex', codex)]:
        for row in report['cases']:
            old, new = [row['seconds'][b]['median'] for b in ['baseline', 'candidate']]
            row_interval = interval(row)
            table.append(f'<tr><td>{host}</td><td>{html.escape(row["name"])}</td><td>{old*1000:.1f} → {new*1000:.1f}</td><td>{delta(old,new):+.1f}%</td><td>{row_interval[0]:+.1f} ~ {row_interval[1]:+.1f}%</td><td>{cpu(row,"baseline")*1000:.1f} → {cpu(row,"candidate")*1000:.1f}</td><td>' + ' → '.join(f'{row["resource_usage"][b]["max_child_peak_rss_kib"]["median"]/1024:.1f}' for b in ['baseline','candidate']) + '</td></tr>')
    checks = ''.join(f'<li>{html.escape(r["label"])}: {html.escape(", ".join(r["summary"]))}</li>' for r in verification['results'])
    environment = html.escape((args.results / 'environment.txt').read_text())
    image_id = html.escape((args.results / 'image-id.txt').read_text().strip())
    summary = {'verdict': verdict, 'opt_in_gate_passed': adopt, 'performance_gate_passed': metric_gate, 'ci_complete': ci_complete, 'hot_latency_change_percent': hot_wall,
               'hot_cpu_change_percent': hot_cpu, 'hot_rss_change_percent': hot_rss,
               'hot_latency_bootstrap_95_percent_interval': hot_ci, 'latency_regressions_over_5_percent': regressions, 'load': load_summary}
    (args.results / 'assessment.json').write_text(json.dumps(summary, indent=2, ensure_ascii=False))
    regression_text = html.escape(', '.join(regressions)) if regressions else '없음'
    document = '''<!doctype html><html lang="ko"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>agent-guard 성능 검증 · Rust 전환 결과</title><style>
:root{color-scheme:light;--ink:#182e40;--muted:#586d7c;--teal:#007f75}*{box-sizing:border-box}body{margin:0;background:#f2f5f6;color:var(--ink);font:16px/1.7 system-ui,-apple-system,"Noto Sans KR",sans-serif}main{max-width:1160px;margin:auto;padding:48px 24px}h1{font-size:38px;line-height:1.3;letter-spacing:-1.4px;margin:12px 0}h2{font-size:23px;line-height:1.4;margin:0 0 15px}p{margin:12px 0}.eyebrow{color:var(--teal);font-size:13px;font-weight:750;letter-spacing:2px}.lead{max-width:850px;color:var(--muted);font-size:18px}.badge{display:inline-block;border:1px solid #90c6bf;background:#e6f5f1;padding:6px 13px;border-radius:8px;font-weight:700}.cards{display:grid;grid-template-columns:repeat(3,1fr);gap:16px;margin:28px 0}.card,section{background:white;border:1px solid #e1e8eb;border-radius:14px;padding:25px;margin:20px 0}.card{margin:0}.number{display:block;font-size:38px;font-weight:750;letter-spacing:-1px;color:var(--teal)}.number.neutral{color:var(--muted)}.small{font-size:13px;color:var(--muted)}.callout{padding:16px 20px;background:#eef6f5;border-left:4px solid var(--teal);margin:20px 0}.chart{overflow-x:auto}.chart svg{width:100%;min-width:700px;height:auto}.tabs{display:flex;gap:8px;flex-wrap:wrap;margin-bottom:20px}button{font:inherit;background:#eef2f5;border:0;border-radius:8px;padding:8px 20px;cursor:pointer}button[aria-selected=true]{background:var(--teal);color:white}.scroll{overflow-x:auto}table{width:100%;border-collapse:collapse;font-size:13px}td,th{padding:11px 9px;border-bottom:1px solid #e1e8eb;text-align:left;white-space:nowrap}th{background:#f4f7f8}a{color:#00786f}pre{white-space:pre-wrap;overflow-wrap:anywhere;background:#f4f7f8;padding:16px;font-size:12px}details{margin:16px 0}summary{cursor:pointer;font-weight:700}footer{color:var(--muted);font-size:13px;margin-top:24px}@media(max-width:700px){main{padding:25px 14px}h1{font-size:29px}.cards{grid-template-columns:1fr}.number{font-size:32px}section{padding:18px}}@media print{body{background:white}main{padding:0}.card,section{break-inside:avoid}.chart[hidden]{display:block}button{display:none}}
</style><main><div class="eyebrow">AGENT-GUARD · MEASURED REWRITE</div><h1>Rust 전환, 어디까지 좋아졌나</h1>
<p class="lead">마스킹 강도를 유지하면서 병목을 검증·개선하고, 측정 근거에 따라 Rust 도입 범위를 결정합니다. 최적화된 셸과 선택형 Rust 코어를 같은 Docker 환경에서 비교했습니다.</p>
'''
    document += f'<div class="badge">{verdict}</div><div class="cards"><div class="card">다수 문자열 치환 · 지연<span class="number">{hot_wall:+.1f}%</span><span class="small">{hot["seconds"]["baseline"]["median"]*1000:.1f} → {hot["seconds"]["candidate"]["median"]*1000:.1f} ms</span></div><div class="card">같은 작업 · CPU 시간<span class="number">{hot_cpu:+.1f}%</span><span class="small">{cpu(hot,"baseline")*1000:.1f} → {cpu(hot,"candidate")*1000:.1f} ms</span></div><div class="card">같은 작업 · 개별 자식 peak RSS<span class="number neutral">{hot_rss:+.1f}%</span><span class="small">개별 프로세스 최대값입니다. 작은 차이를 메모리 절감으로 해석하지 않습니다.</span></div></div>'
    document += f'<section><h2>판정과 적용 범위</h2><p>문자열 치환 코어만 Rust로 옮겼습니다. 탐지 규칙, 스캐너, PII, 정책과 호스트 envelope는 기존 구현을 사용합니다. 기본 실행은 셸이며 Rust가 없거나 실패하면 기존 jq로 복귀합니다.</p><div class="callout">핵심 경로의 목표는 지연 또는 CPU 10% 이상 개선입니다. 일반 경로의 지연 5% 초과 증가 항목: <strong>{regression_text}</strong>. 차이가 작은 항목은 표본 변동까지 확인해야 합니다.</div><p>전체 Rust 재작성이나 모든 플랫폼의 성능 향상을 입증한 결과는 아닙니다. 일반 사용자는 사전 빌드된 바이너리를 실행할 때 Rust 설치가 필요 없지만, 플랫폼별 배포·설치 통합은 아직 후속 과제입니다.</p></section>'
    document += '<section><h2>실제 CLI · 시나리오별 비교</h2><p class="small">기준 셸 = 100%. small-clean은 정상 출력, many-replacement-leaves는 다수 문자열 치환, pre-*는 입력 검사입니다. 낮을수록 사용 시간·자원이 적습니다. 두 구현은 같은 입력을 받고 매 호출의 전체 기대값을 검사합니다. Rust가 호출되지 않는 정상 경로의 차이는 코어 개선 효과로 보지 않습니다. CPU는 user + system 시간입니다.</p><div class="tabs" role="tablist">'
    for metric, label in [('latency','지연'),('cpu','CPU 시간'),('rss','개별 peak RSS')]:
        document += f'<button role="tab" aria-selected="{str(metric=="latency").lower()}" data-metric="{metric}">{label}</button>'
    document += '</div>'
    for metric in ['latency','cpu','rss']:
        document += f'<div class="chart" id="chart-{metric}"'+(' hidden' if metric!='latency' else '')+'>'+charts[metric]+'</div>'
    document += '</section><section><h2>코어 자체의 효과</h2><p class="small">15회 교대 측정 중앙값. 프로세스 시작·JSON 입출력 포함, 스캐너와 전체 셸 파이프라인 제외. 이 배수를 전체 CLI의 배수로 읽으면 안 됩니다.</p><div class="chart">'+charts['kernel']+'</div><p>' + core_note + '</p></section>'
    document += '<section><h2>동시 부하와 프로세스 메모리</h2><p class="small">실제 실행 환경은 상위 4 CPU·16 GiB 한도를 공유합니다. rootless Docker의 cgroup driver가 none이어서 요청한 컨테이너별 2 CPU·1 GiB 제한은 적용되지 않았습니다. 요청 8개를 worker 1개/4개로 실행, 각각 새 컨테이너에서 3회 교대 반복. 왼쪽은 높을수록 좋고, 오른쪽은 낮을수록 좋습니다. 메모리는 10 ms마다 컨테이너 내부 프로세스 RSS를 합산한 최대 표본입니다. 드라이버·init을 포함하고 공유 페이지는 중복 계산될 수 있으며 순간 peak는 놓칠 수 있습니다. 페이지 캐시·Docker daemon·빌드는 제외합니다. 샘플러 비용은 양쪽에 포함됩니다.</p><div class="chart">'+charts['load']+'</div><details><summary>동시 부하의 요청당 CPU·수치 보기</summary><div class="scroll"><table><tr><th>동시 작업 수</th><th>구현</th><th>요청/초</th><th>요청당 자식 CPU ms</th><th>RSS 합 MiB</th></tr>' + load_table + '</table></div></details></section>'
    document += f'<section><h2>정확성·실패 처리 검증</h2><p>검증 표본에서 불일치 0건입니다. 차등 검사 <strong>{differential["passed"]:,}건</strong>, 실제 스캐너를 사용한 두 호스트·실패 복귀 검사 <strong>{integration["passed"]}건</strong> 통과. 독립 기대값, Unicode, 제어문자, 치환 순서, 작업량 경계, 프로토콜 필드와 부분 실패를 포함합니다.</p><ul>{checks}</ul><p class="small">로컬 최종 재검증은 기존/Rust 출력·스캐너 샤드이며 CLI SHA-256을 고정했습니다. 전체 정책·호스트 회귀는 아래의 동일 CLI 소스에 대한 Linux·macOS CI로 확인합니다. 초기 검사의 root 소유 Python 캐시, 공유 /tmp, 컨테이너 계정 누락은 검증 환경에서 해결했습니다. 구형 awk 보존 오류와 jq 1.6 과도 마스킹은 별도 코드 수정과 회귀 검사로 해결했습니다. 빌드 디스크 부족은 성능 표본 시작 전에 해결했습니다.</p></section>'
    document += f'<p class="small">추가 검증: 단위 검사 {supplemental["unit_passed"]}건, Rust 모드 감사 로그 검사 {supplemental["native_audit_passed"]}건 통과.</p>'
    ci_rows = ''.join('<li>' + html.escape(w['name'] + ': ' + str(w.get('conclusion') or w['status'])) + '</li>' for w in ci.get('workflows', []))
    ci_jobs = ''.join('<li>' + html.escape(j['name'] + ': ' + str(j.get('conclusion') or j['status'])) + '</li>' for j in ci.get('jobs', []))
    document += '<section><h2>CI와 추가 호환성</h2><p>같은 CLI 소스에 대한 전체 Linux·macOS 회귀 및 선택형 Rust·구형 도구 CI입니다.</p><ul>' + ci_rows + '</ul><details><summary>운영체제별 CI 상태</summary><ul>' + ci_jobs + '</ul></details><p>jq 1.6에서도 실제 CLI의 호스트·실패 복귀 검사 ' + str(legacy_integration['passed']) + '건을 추가로 통과했습니다. 원시 코어의 NUL 차등 비교는 jq 1.7.1을 사용합니다.</p></section>'
    original_clean = next(r for r in rows if r['name'] == 'small-clean')
    original_clean_change = delta(original_clean['seconds']['baseline']['median'], original_clean['seconds']['candidate']['median'])
    clean = followup['cases'][0]
    clean_change = delta(clean['seconds']['baseline']['median'], clean['seconds']['candidate']['median'])
    clean_ci = interval(clean)
    followup_note = f'초기 small-clean 표본의 변동이 커 동일 환경에서 21쌍을 추가 측정했습니다. 재측정 지연 변화는 {clean_change:+.1f}% (95% 기술 구간 {clean_ci[0]:+.1f} ~ {clean_ci[1]:+.1f}%)입니다. 정상 입력은 Rust 치환을 호출하지 않으므로 초기 {original_clean_change:+.1f}%를 Rust 효과로 해석하지 않습니다.'
    control_rows = ''.join(f'<li>{html.escape(r["name"])}: 지연 {delta(r["seconds"]["baseline"]["median"],r["seconds"]["candidate"]["median"]):+.1f}%</li>' for r in control['cases'])
    process_rows = ''.join(f'<tr><td>{html.escape(r["name"])}</td><td>{r["process_profile"]["baseline"]["execve_calls"]} → {r["process_profile"]["candidate"]["execve_calls"]}</td><td>{r["process_profile"]["baseline"]["process_creation_calls"]} → {r["process_profile"]["candidate"]["process_creation_calls"]}</td></tr>' for r in rows if r['name'] in ['small-clean', 'many-replacement-leaves', 'pre-bash-clean'])
    document += '<section><h2>아직 남은 구조적 비용</h2><p>이번 코어 이식은 외부 명령 수를 크게 줄이지 않습니다. 많은 문자열의 jq 치환 비용을 줄이는 효과이며, 입력 검사와 나머지 셸 파이프라인은 후속 최적화 대상입니다.</p><div class="scroll"><table><tr><th>사례</th><th>exec 시도 · 셸 → Rust</th><th>프로세스 생성 시도</th></tr>' + process_rows + '</table></div><p class="small">strace를 별도 실행해 얻은 호출 시도 수입니다. 실패한 실행 시도도 포함하며 성공한 실행 파일 개수나 고유 프로세스 수와 같지 않습니다. 스레드 생성은 구분했습니다.</p></section>'
    document += '<section><h2>기본 셸 경로의 비용 확인</h2><p>Rust 기능을 끈 후보와 기준 셸을 별도로 비교했습니다. 기본 실행에 추가한 선택 분기의 비용과 측정 변동을 확인하는 대조군입니다.</p><ul>' + control_rows + '</ul><p>' + followup_note + '</p></section>'
    document += '<section><h2>원시 수치와 측정 한계</h2><details><summary>Claude·Codex 전체 표 펼치기</summary><div class="scroll"><table><thead><tr><th>호스트</th><th>사례</th><th>지연 ms</th><th>변화</th><th>지연 변화 95% 구간</th><th>CPU ms</th><th>개별 peak MiB</th></tr></thead><tbody>'+''.join(table)+'</tbody></table></div></details><p class="small">각 CLI 사례 9회, 순서를 교대합니다. 95% 구간은 같은 반복 번호를 짝지은 bootstrap 2,000회(고정 seed)의 기술 통계이며 공유 머신의 장기 변동을 보장하지 않습니다. p95로 해석하지 마세요. Linux의 fork/exec 전 메모리 때문에 Python에서 실행한 작은 코어의 자식 RSS에는 약 11 MiB 바닥값이 생길 수 있어 코어 메모리 절감의 근거로 쓰지 않았습니다. 합성 출력, cold readiness cache, PII off 조건이며 실제 모델 응답 시간·원격 PII·전체 저장소 스캔 성능으로 일반화할 수 없습니다.</p>'
    document += f'<details><summary>빌드·도구·소스 해시</summary><pre>Docker image: {image_id}\n{environment}</pre></details><p><a href="../bench/results/rust-experiment/">원시 JSON 결과</a> · <a href="../bench/native/README.md">재현 방법·측정 정의</a> · <a href="rust-experiment-goal.ko.md">목표와 완료 조건</a></p></section>'
    document += '<section><h2>호환성 수정과 PR 구분</h2><p>이전 호스트 실험의 많은 leaf 사례는 셸 최적화로 2.002 → 1.277초, CPU 2.059 → 1.343초였습니다. 그 실험과 이번 Docker 결과는 실행 환경이 달라 직접 이어 붙인 3단계 속도 그래프로 표현하지 않았습니다.</p><p><a href="reports/runtime-review.ko.md">셸 최적화 기록</a> · <a href="https://github.com/JeongJaeSoon/agent-guard/pull/377">PR #377 · 셸 최적화</a></p><p><a href="https://github.com/JeongJaeSoon/agent-guard/pull/378">PR #378 · 구형 awk 보존</a> · <a href="https://github.com/JeongJaeSoon/agent-guard/pull/379">PR #379 · jq 과도 마스킹</a> · <a href="https://github.com/JeongJaeSoon/agent-guard/pull/380">PR #380 · 선택형 Rust</a> · <a href="https://github.com/JeongJaeSoon/agent-guard/pull/381">PR #381 · 실측·그래프</a></p><p class="small">Rust 코어·검증과 실험·HTML 보고서는 각각 별도 PR 단위로 관리합니다. 선택형 실험과 기본값 전환을 구분합니다.</p></section>'
    document += '<footer>로컬에서 열 수 있는 독립 HTML입니다. 외부 CDN·분석기·네트워크 요청을 사용하지 않습니다. 그래프 원본 SVG는 docs/assets/에 함께 저장됩니다.</footer></main><script>document.querySelectorAll("[data-metric]").forEach(button=>button.addEventListener("click",()=>{document.querySelectorAll("[data-metric]").forEach(b=>b.setAttribute("aria-selected",b===button?"true":"false"));["latency","cpu","rss"].forEach(m=>document.getElementById("chart-"+m).hidden=m!==button.dataset.metric)}));</script></html>'
    args.html.write_text(document)
    print(json.dumps(summary, ensure_ascii=False))


if __name__ == '__main__':
    main()
