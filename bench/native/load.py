#!/usr/bin/env python3
"""Synthetic concurrent hook load; each invocation checks the complete output."""
import argparse
import concurrent.futures
import json
import os
from pathlib import Path
import resource
import statistics
import subprocess
import time
import threading

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True, type=Path)
    parser.add_argument('--core', type=Path)
    parser.add_argument('--scanner', required=True, type=Path)
    parser.add_argument('--workers', type=int, default=4)
    parser.add_argument('--requests', type=int, default=12)
    args = parser.parse_args()
    if args.workers < 1 or args.requests < 1:
        parser.error('workers and requests must be positive')
    env = dict(os.environ, AGENT_GUARD_LOG_MODE='off', AGENT_GUARD_RELEASE_CHECK='off',
               AGENT_GUARD_HOOK_HOST='claude', AGENT_GUARD_PII_HOOK_MODE='off',
               AGENT_GUARD_OUTPUT_REDACT='mask', AGENT_GUARD_GITLEAKS_BIN=str(args.scanner.resolve()),
               AGENT_GUARD_GITLEAKS_CONFIG=str(ROOT / 'plugins/agent-guard/config/gitleaks.toml'),
               AGENT_GUARD_EXPERIMENTAL_REDACTOR='rust' if args.core else 'shell')
    if args.core:
        env['AGENT_GUARD_RUST_CORE_BIN'] = str(args.core.resolve())
    values = ['API_KEY=perf-literal-%03d' % i for i in range(100)] + ['status'] * 4000
    expected = ['API_KEY=[REDACTED]'] * 100 + ['status'] * 4000
    payload = json.dumps({'tool_name': 'mcp__latency__read', 'tool_response': values}).encode()
    def run(_):
        start = time.perf_counter()
        result = subprocess.run([str(args.binary.resolve()), 'hook-post-tool'], input=payload,
                                env=env, capture_output=True, timeout=60)
        assert result.returncode == 0 and json.loads(result.stdout)['hookSpecificOutput']['updatedToolOutput'] == expected
        return time.perf_counter() - start
    # Docker's rootless cgroup-less mode can expose the parent cgroup. Never
    # label those counters as this container's memory. Sample only the private
    # PID namespace instead; sum RSS counts shared pages more than once.
    page_kib = os.sysconf('SC_PAGE_SIZE') / 1024
    rss_samples = []
    stop = threading.Event()
    def sample_memory():
        while not stop.is_set():
            total = 0
            for process in Path('/proc').iterdir():
                if process.name.isdigit():
                    try:
                        total += int((process / 'statm').read_text().split()[1]) * page_kib
                    except (OSError, ValueError, IndexError):
                        pass  # A child may exit between listing and reading.
            rss_samples.append(total)
            stop.wait(.01)
    sampler = threading.Thread(target=sample_memory, daemon=True)
    sampler.start()
    start = time.perf_counter()
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as executor:
        samples = list(executor.map(run, range(args.requests)))
    elapsed = time.perf_counter() - start
    stop.set()
    sampler.join()
    usage = resource.getrusage(resource.RUSAGE_CHILDREN)
    cgroup = {}
    for key in ['memory.peak', 'memory.max', 'cpu.max', 'memory.events']:
        path = Path('/sys/fs/cgroup') / key
        cgroup[key] = path.read_text().strip() if path.exists() else None
    print(json.dumps({'backend': 'rust' if args.core else 'shell', 'workers': args.workers,
        'requests': args.requests, 'verified': True, 'elapsed_seconds': elapsed,
        'requests_per_second': args.requests / elapsed, 'latency_samples': samples,
        'median_seconds': statistics.median(samples), 'max_seconds': max(samples),
        'user_cpu_seconds': usage.ru_utime, 'system_cpu_seconds': usage.ru_stime,
        'max_child_peak_rss_kib': usage.ru_maxrss, 'container_cgroup': cgroup,
        'sampled_process_rss_peak_kib': max(rss_samples), 'rss_sample_count': len(rss_samples),
        'rss_sample_interval_seconds': .01,
        'driver_cpu_seconds': resource.getrusage(resource.RUSAGE_SELF).ru_utime + resource.getrusage(resource.RUSAGE_SELF).ru_stime,
        'cgroup_isolated': os.environ.get('AGENT_GUARD_BENCH_CGROUP_ISOLATED') == '1',
        'memory_scope': '10 ms sampled sum of RSS in the private container PID namespace, including driver/init; shared pages may be counted multiple times; excludes page cache, daemon and build; sampling may miss short peaks; cgroup counters are not container-specific unless cgroup_isolated is true; ru_maxrss is max individual child peak'}))


if __name__ == '__main__':
    main()
