#!/usr/bin/env bash
# Phase 1 - raw hardware benchmark. Run on each TEST target VM (not production).
# Usage:  sudo bash phase1_hwbench.sh [loadgen_ip]
#   If loadgen_ip is given, also runs iperf3 (start `iperf3 -s` on the load-gen VM first).
set -uo pipefail
LG="${1:-}"
OUT="hwbench_$(hostname)_$(nproc)c_$(date +%Y%m%d_%H%M).txt"
T=$(nproc)
sec() { printf '\n===== %s =====\n' "$1"; }
FIO_SIZE=$([ "$(df --output=avail -BG / | tail -1 | tr -dc 0-9)" -gt 20 ] && echo 4G || echo 1G)

{
sec "SPEC"; nproc; free -m | head -2; lscpu | grep -E 'Model name|MHz'
sec "CPU steal before test"; vmstat 1 3 | tail -2

sec "sysbench CPU - 1 thread (30s)"
sysbench cpu --cpu-max-prime=20000 --threads=1 --time=30 run | grep -E 'events per second|95th'
sec "sysbench CPU - $T threads (30s)"
sysbench cpu --cpu-max-prime=20000 --threads="$T" --time=30 run | grep -E 'events per second|95th'

sec "sysbench memory - $T threads"
sysbench memory --memory-block-size=1M --memory-total-size=20G --threads="$T" run | grep -E 'transferred|events per second'

sec "fio random 4K read/write 70/30 (60s, size $FIO_SIZE)"
fio --name=rand4k --filename=/root/fio.test --size="$FIO_SIZE" --rw=randrw --rwmixread=70 --bs=4k \
    --ioengine=libaio --iodepth=32 --numjobs=4 --direct=1 --runtime=60 --time_based --group_reporting \
    | grep -E 'read:|write:|lat \(usec\): min.*avg' | head -6
sec "fio sequential read 1M (30s)"
fio --name=seqr --filename=/root/fio.test --size="$FIO_SIZE" --rw=read --bs=1M --ioengine=libaio \
    --iodepth=16 --direct=1 --runtime=30 --time_based | grep -E 'read:'
sec "fio sequential write 1M (30s)"
fio --name=seqw --filename=/root/fio.test --size="$FIO_SIZE" --rw=write --bs=1M --ioengine=libaio \
    --iodepth=16 --direct=1 --runtime=30 --time_based | grep -E 'write:'
rm -f /root/fio.test

if [ -n "$LG" ]; then
  sec "iperf3 to load-gen $LG (4 streams, 20s, both directions)"
  iperf3 -c "$LG" -P 4 -t 20 | tail -4
  iperf3 -c "$LG" -P 4 -t 20 -R | tail -4
fi
sec "CPU steal after test"; vmstat 1 3 | tail -2
} 2>&1 | tee "$OUT"

echo; echo "Done -> $OUT  (paste it back in the chat)"
