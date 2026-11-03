#!/usr/bin/env python3
"""Isolate per-invocation child resource accounting (POSIX developer tool)."""
import json
from pathlib import Path
import resource
import subprocess
import sys
import time


def main():
    destination = Path(sys.argv[1])
    start = time.perf_counter()
    result = subprocess.run(sys.argv[2:])
    elapsed = time.perf_counter() - start
    usage = resource.getrusage(resource.RUSAGE_CHILDREN)
    # Each worker waits for exactly one CLI tree. A fresh worker avoids the
    # cumulative high-water mark from earlier benchmark samples. This is the
    # maximum individual child RSS, NOT simultaneous process-tree memory.
    rss_kib = usage.ru_maxrss / 1024 if sys.platform == "darwin" else usage.ru_maxrss
    destination.write_text(json.dumps({
        "wall_seconds": elapsed,
        "user_cpu_seconds": usage.ru_utime,
        "system_cpu_seconds": usage.ru_stime,
        "max_child_peak_rss_kib": rss_kib,
        "voluntary_context_switches": usage.ru_nvcsw,
        "involuntary_context_switches": usage.ru_nivcsw,
    }))
    # Preserve signal termination for the benchmark's status gate.
    return result.returncode if result.returncode >= 0 else 128 - result.returncode


if __name__ == "__main__":
    sys.exit(main())
