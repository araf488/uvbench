#!/usr/bin/env python3
"""Exports the benchmark time series from Prometheus to CSV (one file per metric) for the final report.
Run on the monitoring server:   python3 scripts/export-results.py --since 30d --step 5m --out /root/results
No third-party packages needed."""
import argparse
import csv
import json
import pathlib
import time
import urllib.parse
import urllib.request

QUERIES = {
    "cost_per_hour": "max by (tier) (uvbench_cost_per_hour_usd)",
    "requests_per_sec": "tier:http_requests:rate1m",
    "cost_per_1k_requests": "tier:cost_per_1k_requests:usd",
    "cpu_used": "tier:cpu_used:ratio",
    "cpu_steal": "tier:cpu_steal:ratio",
    "mem_used": "tier:mem_used:ratio",
    "swap_used_bytes": "tier:swap_used:bytes",
    "api_p95_seconds": "tier:api_latency:p95",
    "error_ratio": "tier:http_errors:ratio",
    "ai_stage_p95_seconds": "tier:ai_stage:p95",
    "stt_rtf_p50": "tier:stt_rtf:p50",
    "llm_tokens_per_sec": "avg by (tier) (llamacpp:predicted_tokens_seconds)",
    "ai_queue_waiting": "sum by (tier, queue) (uvbench_queue_depth{state=\"waiting\"})",
    "k6_vus": "sum by (tier) (k6_vus)",
    "k6_p95_seconds_by_action": "max by (tier, name) (k6_http_req_duration_p95{name!=\"\"})",
}


def parse_duration(s):
    return int(s[:-1]) * {"m": 60, "h": 3600, "d": 86400}[s[-1]]


def query_range(prom, expr, start, end, step):
    qs = urllib.parse.urlencode({"query": expr, "start": start, "end": end, "step": step})
    with urllib.request.urlopen(f"{prom}/api/v1/query_range?{qs}", timeout=120) as r:
        return json.load(r)["data"]["result"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--prom", default="http://127.0.0.1:9090")
    ap.add_argument("--since", default="30d")
    ap.add_argument("--step", default="5m")
    ap.add_argument("--out", default="results")
    a = ap.parse_args()
    out = pathlib.Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    end = int(time.time())
    total = parse_duration(a.since)
    chunk = 7 * 86400  # Prometheus limits points per query; fetch a week at a time
    for name, expr in QUERIES.items():
        rows = []
        for s in range(end - total, end, chunk):
            for series in query_range(a.prom, expr, s, min(s + chunk, end), a.step):
                labels = ";".join(f"{k}={v}" for k, v in sorted(series["metric"].items()))
                rows += [(int(t), labels, v) for t, v in series["values"]]
        with open(out / f"{name}.csv", "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["timestamp_utc", "series", "value"])
            for t, lab, v in sorted(rows):
                w.writerow([time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime(t)), lab, v])
        print(f"{name:28s} {len(rows):7d} points")


if __name__ == "__main__":
    main()
