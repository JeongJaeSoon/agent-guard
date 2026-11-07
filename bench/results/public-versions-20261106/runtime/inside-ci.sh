#!/bin/sh
# Every measured process executes beneath the cgroup checked here.
set -eu
action=${1:?runtime, installation or correctness}
scanner=${2:?scanner kind}
host=${3:?host or config mode}
base=/repo/bench/results/public-versions-20261106
limits=$(cat /sys/fs/cgroup/cpu.max /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory.swap.max)
printf '%s\n' "$limits" | tee /results/provision/applied-limits.txt
[ "$limits" = "200000 100000
1073741824
0" ] || { printf 'resource limits not applied\n' >&2; exit 2; }
{ uname -a; cat /proc/self/cgroup; cat /proc/swaps; jq --version; /usr/bin/jq --version; python --version; cat /etc/os-release; } > /results/provision/measured-environment.txt
cat /proc/cpuinfo > /results/provision/cpuinfo.txt
dpkg-query -W > /results/provision/dpkg-versions.txt
sha256sum /bin/dash /usr/bin/awk /usr/bin/jq /usr/local/bin/jq /usr/bin/time /usr/bin/strace /usr/local/bin/python3 > /results/provision/tool-checksums.txt
case "$action" in
  runtime)
    exec python "$base/runtime/run.py" --lab /lab --out /results/runtime/ci \
      --environment "linux-ci-$scanner-$host-2cpu-1g" --scanners "$scanner" --hosts "$host" --require-limits
    ;;
  controlled)
    exec python "$base/runtime/run.py" --lab /lab --out /results/runtime/controlled \
      --environment "linux-ci-controlled-$scanner-$host-2cpu-1g" --scanners "$scanner" --hosts "$host" \
      --policy-mode common --rss-all-versions --require-limits
    ;;
  rss)
    exec python "$base/runtime/run.py" --lab /lab --out /results/runtime/rss-supplement \
      --environment "linux-ci-rss-$scanner-$host-2cpu-1g" --scanners "$scanner" --hosts "$host" \
      --series rss --rss-all-versions --require-limits
    ;;
  installation)
    python "$base/installation/measure_install.py" --lab /lab --out /results/installation/cached \
      --phase cached --rounds 9 --work /results/installation-work/cached --environment linux-ci-install-2cpu-1g
    exec python "$base/installation/measure_install.py" --lab /lab --out /results/installation/network \
      --phase network --rounds 9 --work /results/installation-work/network --environment linux-ci-install-2cpu-1g
    ;;
  correctness)
    python "$base/correctness/run.py" --releases /lab/releases --scanner "/lab/scanners/$scanner/gitleaks" \
      --scanner-name "$scanner" --out "/results/correctness/$scanner-jq171-$host" --variants default,fused \
      --config-mode "$host" --label "linux-ci-$scanner-jq171-$host-2cpu-1g"
    if [ "$host" = fixed ]; then
      python "$base/correctness/scanner_config.py" --releases /lab/releases \
        --scanner "/lab/scanners/$scanner/gitleaks" --scanner-name "$scanner" \
        --out "/results/correctness/$scanner-scanner-config"
      python "$base/correctness/fallback.py" --releases /lab/releases \
        --scanner "/lab/scanners/$scanner/gitleaks" --scanner-name "$scanner" \
        --out "/results/correctness/$scanner-fallback"
    fi
    if [ "$scanner:$host" = official:fixed ]; then
      mkdir /tmp/jq16-bin
      ln -s /usr/bin/jq /tmp/jq16-bin/jq
      PATH="/tmp/jq16-bin:$PATH" python "$base/correctness/run.py" --releases /lab/releases \
        --scanner /lab/scanners/official/gitleaks --scanner-name official \
        --out /results/correctness/official-jq16-focused --variants default,fused --config-mode fixed \
        --cases small-clean,long-line,many-replacement-leaves,placeholder-control,metadata-control,unknown-event \
        --label linux-ci-official-jq16-fixed-focused-2cpu-1g
      PATH="/tmp/jq16-bin:$PATH" python "$base/correctness/run.py" --releases /lab/releases \
        --scanner /lab/scanners/official/gitleaks --scanner-name official \
        --out /results/correctness/official-jq16-printenv --variants default --config-mode fixed \
        --suite compatibility --label linux-ci-official-jq16-printenv-2cpu-1g
      python "$base/correctness/existing_corpus.py" --repo /repo --releases /lab/releases \
        --out /results/correctness/existing-core-corpus
    fi
    ;;
  *) echo 'unknown experiment' >&2; exit 2 ;;
esac
