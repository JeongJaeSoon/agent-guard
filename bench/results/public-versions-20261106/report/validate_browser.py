#!/usr/bin/env python3
"""독립형 HTML을 새 오프라인 Chromium에서 열고 실제 UI와 다운로드를 검사한다.

사용자의 브라우저 프로필·탭·로그인 세션을 사용하지 않는다. 보고서 한 개만
file:// 또는 허용된 loopback HTTP에서 열며 외부 HTTP(S) 요청을 차단한다.
성공할 때까지 재실행하지 않고
각 실행의 원시 결과와 실패를 --out 디렉터리에 남긴다.
"""
import argparse
import csv
import hashlib
import io
import json
import os
import re
import sys
import threading
import traceback
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

from playwright.sync_api import sync_playwright


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def displayed_number(text):
    # Units may contain a batch size (e.g. ms/4요청 묶음). Parse only the
    # leading numeric value rather than concatenating digits from the unit.
    match = re.match(r'[-+]?[\d,.]+', text)
    require(match is not None, 'missing leading displayed number')
    return float(match.group().replace(',', ''))


def dom_value(value):
    return '' if value is None else str(value)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--html', required=True)
    parser.add_argument('--out', required=True)
    parser.add_argument('--chromium', default='/usr/bin/chromium')
    parser.add_argument('--serve', action='store_true', help='허용된 loopback HTTP에서 보고서 한 파일만 제공; file:// 직접 열기 검증과 구분')
    parser.add_argument('--serve-port', type=int, default=31460)
    args = parser.parse_args()
    report = Path(args.html).resolve()
    out = Path(args.out).resolve()
    out.mkdir(parents=True, exist_ok=False)
    data = json.loads((report.parent / 'data.json').read_text())
    result = dict(started_at_utc=datetime.now(timezone.utc).isoformat(), html_path=str(report), html_sha256=sha(report), browser='disposable Chromium via Playwright', browser_executable=args.chromium, profile='new temporary context; no user profile', navigation_mode='loopback-http' if args.serve else 'file-url', file_url_verified=False, network='only this generated HTML over loopback HTTP is allowed; all external HTTP(S) requests blocked' if args.serve else 'HTTP(S) requests blocked; local file only', assertions=[], filter_changes=[], downloads=[], console_errors=[], page_errors=[], external_requests=[], artifact_requests=[], success=False)
    server = None
    server_thread = None
    navigation_url = report.as_uri()

    def check(condition, message):
        result['assertions'].append(dict(assertion=message, passed=bool(condition)))
        require(condition, message)

    try:
        if args.serve:
            artifact = report.read_bytes()

            class Handler(BaseHTTPRequestHandler):
                def do_GET(self):
                    result['artifact_requests'].append(self.path)
                    if self.path == '/report.ko.html':
                        self.send_response(200)
                        self.send_header('Content-Type', 'text/html; charset=utf-8')
                        self.send_header('Content-Length', str(len(artifact)))
                        self.end_headers()
                        self.wfile.write(artifact)
                    elif self.path == '/favicon.ico':
                        self.send_response(204)
                        self.end_headers()
                    else:
                        self.send_response(404)
                        self.end_headers()

                def log_message(self, *_):
                    pass

            server = HTTPServer(('127.0.0.1', args.serve_port), Handler)
            server_thread = threading.Thread(target=server.serve_forever, daemon=True)
            server_thread.start()
            navigation_url = f'http://localhost:{args.serve_port}/report.ko.html'
            result['file_url_limit'] = 'file:// navigation is blocked by managed Chromium policy; see preserved browser-tooling-failures.json. This run tests the same all-inline artifact over an allowed loopback HTTP origin and does not claim file:// verification.'
        result['navigation_url'] = navigation_url
        with sync_playwright() as pw:
            browser = pw.chromium.launch(executable_path=args.chromium, headless=True, args=['--no-sandbox', '--disable-dev-shm-usage', '--disable-background-networking', '--disable-default-apps', '--no-first-run'])
            result['browser_version'] = browser.version
            context = browser.new_context(viewport={'width': 1440, 'height': 1050}, locale='ko-KR', accept_downloads=True)

            def route_request(route):
                if route.request.url.startswith(('http://', 'https://')):
                    if args.serve and route.request.url in [navigation_url, f'http://localhost:{args.serve_port}/favicon.ico']:
                        route.continue_()
                    else:
                        result['external_requests'].append(route.request.url)
                        route.abort()
                else:
                    route.continue_()

            context.route('**/*', route_request)
            page = context.new_page()
            page.on('pageerror', lambda error: result['page_errors'].append(str(error)))
            page.on('console', lambda msg: result['console_errors'].append(msg.text) if msg.type == 'error' else None)
            page.goto(navigation_url, wait_until='load', timeout=30000)
            result['file_url_verified'] = not args.serve
            check('Agent Guard' in page.title(), 'HTML document title is visible')
            check(page.locator('h1').inner_text().startswith('Agent Guard'), 'Korean report heading rendered')
            for section in ['conclusion', 'versions', 'cumulative', 'graphs', 'evidence']:
                check(page.locator('#' + section).count() == 1, f'required section #{section} exists')
            embedded = json.loads(page.locator('#report-data').text_content())
            check(embedded == data, 'browser-parsed embedded JSON exactly equals data.json')
            environment_evidence = data['context'].get('runtime_environments') or []
            check(json.loads(page.locator('#runtime-environments').text_content()) == environment_evidence, 'cohort CPU/image/cgroup evidence rendered without mixing environments')
            check(page.locator('#runtime-environment-table tbody tr').count() == len(environment_evidence), 'cohort environment table preserves every runner')
            figures = data['context'].get('figures', [])
            if figures:
                check(page.locator('#figure-links a').count() == len(figures), 'all bundled static figure download links rendered')
                for figure in figures:
                    require((report.parent / figure['path']).is_file(), 'bundled static figure missing: ' + figure['path'])
                check(page.locator('img').count() == 0, 'standalone HTML does not auto-load bundled static figures')
            check(page.locator('#changes tbody tr').count() == 7, 'all seven public versions visible in change table')
            if data['context'].get('highlights'):
                check(page.locator('#highlights li').count() == len(data['context']['highlights']), 'short highlights rendered separately from full conclusions')
                page.locator('#detailed-conclusions summary').click()
                check(page.locator('#conclusions li').count() == len(data['context'].get('conclusions', [])), 'expanding full conclusions preserves every quantitative statement')
                page.locator('#detailed-conclusions summary').click()
            check(page.locator('#runtime-table tbody tr').count() == 7, 'all seven version positions rendered including N/A')
            check(not page.locator('#cumulative-chart text').evaluate_all("nodes => nodes.some(n => n.textContent.trim() === '-0')"), 'small percentage axis does not round negative ticks to negative zero')
            check(page.locator('#wall-chart svg').count() == 1 or not data['aggregates'], 'CLI latency SVG rendered for initial condition')
            page.screenshot(path=str(out / 'overview.png'), full_page=False)
            page.locator('#cumulative').screenshot(path=str(out / 'comparison.png'))

            def selected_aggregate_rows():
                values = {key: page.locator('#filter-' + key).input_value() for key in ['phase', 'series', 'environment', 'distribution', 'scanner', 'host', 'audit', 'case', 'variant', 'workers']}
                selected = [r for r in data['aggregates'] if all(str(r.get(k, '')) == v for k, v in values.items())]
                return values, selected

            def check_table():
                selection, selected = selected_aggregate_rows()
                metric = page.locator('#metric').input_value()
                expected = {r['version']: r for r in selected if r['metric'] == metric}
                observed = page.locator('#runtime-table tbody tr').all_inner_texts()
                for version, line in zip(data['versions'], observed):
                    cells = line.split('\t')
                    require(cells[0] == version, 'version order changed')
                    row = expected.get(version)
                    if row:
                        value = displayed_number(cells[1])
                        require(abs(value - row['median']) <= .000500001, f'displayed median mismatch: {version}')
                        require(cells[3].split(' / ')[0] == str(row['n']), f'displayed n mismatch: {version}')
                    else:
                        require('N/A' in line, f'missing version must display N/A: {version}')
                return selection

            check_table()
            result['assertions'].append(dict(assertion='initial table medians and n equal source JSON (display rounds to 0.001)', passed=True))
            # Exercise every option of every filter once. Each change uses the
            # actual DOM event handler and may reconcile dependent conditions.
            for key in ['environment', 'distribution', 'scanner', 'host', 'audit', 'case', 'variant', 'series', 'phase', 'workers']:
                options = page.locator('#filter-' + key + ' option').evaluate_all('(options)=>options.map(o=>({value:o.value,disabled:o.disabled}))')
                for item in options:
                    if page.locator('#filter-' + key + ' option').evaluate_all('(options,v)=>options.find(o=>o.value===v)?.disabled', item['value']):
                        continue
                    page.locator('#filter-' + key).select_option(item['value'])
                    selected_phase = page.locator('#filter-phase').input_value()
                    page.locator('#metric').select_option('rss_sum_peak_kib' if selected_phase == 'rss' else 'wall_ms')
                    selection, matching = selected_aggregate_rows()
                    require(bool(matching), 'filter handler left an impossible condition')
                    check_table()
                    require(selection['environment'] in page.locator('#condition-note').inner_text(), 'actual environment must remain visible')
                    require('조건이 달라' in page.locator('#condition-note').inner_text(), 'condition warning missing')
                    result['filter_changes'].append(dict(changed=key, requested=item['value'], actual=selection, matching_aggregate_rows=len(matching)))
            check(bool(result['filter_changes']) or not data['aggregates'], 'filter controls actually changed and tables validated')
            for metric in data['metrics']:
                page.locator('#metric').select_option(metric)
                check_table()
            check(True, 'all metric selectors and corresponding numeric tables checked')

            def get_download(button, name):
                with page.expect_download(timeout=30000) as info:
                    page.locator('#' + button).click()
                download = info.value
                destination = out / name
                download.save_as(str(destination))
                require(not download.failure(), 'download failed: ' + name)
                result['downloads'].append(dict(button=button, suggested_filename=download.suggested_filename, saved_as=name, bytes=destination.stat().st_size, sha256=sha(destination)))
                return destination

            downloaded_json = get_download('download-json', 'download-raw.json')
            check(json.loads(downloaded_json.read_text()) == data, 'downloaded complete raw JSON exactly equals data.json')
            aggregate_csv = get_download('download-aggregates', 'download-aggregates.csv')
            downloaded_rows = list(csv.DictReader(io.StringIO(aggregate_csv.read_text(encoding='utf-8-sig'))))
            check(len(downloaded_rows) == len(data['aggregates']), 'aggregate CSV download row count equals embedded data')
            for downloaded, source in zip(downloaded_rows, data['aggregates']):
                for field in ['median', 'p25', 'p75', 'n']:
                    require(float(downloaded[field]) == source[field], 'aggregate CSV numeric mismatch: ' + field)
            check(True, 'all downloaded aggregate CSV medians/quantiles/n equal JSON')
            for button, key, name in [('download-csv', 'runtime', 'download-runtime.csv'), ('download-install', 'installation', 'download-installation.csv'), ('download-correctness', 'correctness', 'download-correctness.csv')]:
                path = get_download(button, name)
                actual = list(csv.DictReader(io.StringIO(path.read_text(encoding='utf-8-sig'))))
                check(len(actual) == len(data[key]), key + ' CSV download row count equals JSON')
            selected_csv = get_download('download-selected', 'download-selected.csv')
            _, chosen_rows = selected_aggregate_rows()
            check(len(list(csv.DictReader(io.StringIO(selected_csv.read_text(encoding='utf-8-sig'))))) == len(chosen_rows), 'selected-condition CSV includes exactly the selected aggregate rows')
            # Installation controls and charts use a separate environment axis.
            install_conditions = sorted({(str(r['environment']), str(r['scenario'])) for r in data['installation_aggregates']})
            for environment, scenario in install_conditions:
                page.locator('#install-environment').select_option(environment)
                page.locator('#install-scenario').select_option(scenario)
                expected = [r for r in data['installation_aggregates'] if str(r['environment']) == environment and str(r['scenario']) == scenario]
                actual = page.locator('#install-table tbody tr').all_inner_texts()
                require(len(actual) == len(expected), 'installation table row count mismatch')
                for line, source in zip(actual, expected):
                    cells = line.split('\t')
                    require(cells[0] == source['version'], 'installation version mismatch')
                    displayed = displayed_number(cells[3])
                    require(abs(displayed - source['median']) <= .000500001, 'installation median mismatch')
                    require(cells[5] == str(source['n']), 'installation n mismatch')
                require(page.locator('#install-charts svg').count() > 0, 'installation charts missing')
            check(True, 'all installation environment/scenario tables, medians, n and charts checked')
            accuracy_conditions = sorted({tuple(dom_value(r.get(k, '')) for k in ['environment', 'scanner', 'host']) for r in data['correctness']})
            for environment, scanner, host in accuracy_conditions:
                for key, value in [('environment', environment), ('scanner', scanner), ('host', host)]:
                    page.locator('#correctness-' + key).select_option(value)
                expected = [r for r in data['correctness'] if dom_value(r.get('environment', '')) == environment and dom_value(r.get('scanner', '')) == scanner and dom_value(r.get('host', '')) == host]
                require(page.locator('#correctness-table tbody tr').count() == min(500, len(expected)), 'accuracy table must keep environments separate and preserve row count')
                aggregate_expected = [r for r in data['correctness_aggregates'] if dom_value(r.get('environment', '')) == environment and dom_value(r.get('scanner', '')) == scanner and dom_value(r.get('host', '')) == host]
                aggregate_actual = page.locator('#correctness-aggregate-table tbody tr').all_inner_texts()
                require(len(aggregate_actual) == len(aggregate_expected), 'accuracy aggregate table row count mismatch')
                for line, row in zip(aggregate_actual, aggregate_expected):
                    cells = line.split('\t')
                    for offset, field in enumerate(['n', 'passed', 'failed', 'oracle_excluded']):
                        require(int(cells[3 + offset]) == row[field], 'accuracy aggregate count mismatch: ' + field)
            check(True, 'accuracy environment/scanner/host filters and visible row counts checked')
            page.set_viewport_size({'width': 390, 'height': 844})
            page.locator('#conclusion').scroll_into_view_if_needed()
            page.screenshot(path=str(out / 'mobile.png'), full_page=False)
            check(page.locator('#recommendations li').evaluate_all('nodes => nodes.every(n => n.scrollWidth <= n.clientWidth + 1)'), 'mobile recommendation text including long environment variables wraps without clipping')
            check(not result['external_requests'], 'no external HTTP(S) requests made by report page')
            check(not result['page_errors'], 'no uncaught page JavaScript errors')
            check(not result['console_errors'], 'no browser console errors')
            result['success'] = True
            browser.close()
    except Exception:
        result['failure_traceback'] = traceback.format_exc()
        print(result['failure_traceback'], file=sys.stderr)
    finally:
        if server:
            server.shutdown()
            server.server_close()
        if server_thread:
            server_thread.join(timeout=5)
        result['finished_at_utc'] = datetime.now(timezone.utc).isoformat()
        (out / 'validation.json').write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
        data_validation_path = report.parent / 'data-validation.json'
        if result['success'] and data_validation_path.exists():
            current = json.loads(data_validation_path.read_text())
            current.update(browser_ui_checked=True, browser_file_url_verified=result['file_url_verified'], browser_navigation_mode=result['navigation_mode'], browser_validation_file=os.path.relpath(out / 'validation.json', report.parent), browser_html_sha256=result['html_sha256'])
            data_validation_path.write_text(json.dumps(current, ensure_ascii=False, indent=2) + '\n')
        print(json.dumps({k: result[k] for k in ['success', 'html_sha256', 'browser', 'started_at_utc', 'finished_at_utc']}, ensure_ascii=False))
    return 0 if result['success'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
