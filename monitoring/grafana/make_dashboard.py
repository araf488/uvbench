"""Generates dashboards/uvbench-overview.json (run: python3 make_dashboard.py). Kept as code so it is easy to edit."""
import json
import pathlib

PANELS = [
    # title, unit, expressions [(expr, legend)], width
    ("Cost per hour (USD)", "currencyUSD", [("max by (tier) (uvbench_cost_per_hour_usd)", "{{tier}}")], 6),
    ("Cost per 1,000 requests (USD)", "currencyUSD", [("tier:cost_per_1k_requests:usd", "{{tier}}")], 6),
    ("Requests / second", "reqps", [("tier:http_requests:rate1m", "{{tier}}")], 6),
    ("Virtual users (k6)", "short", [("sum by (tier) (k6_vus)", "{{tier}}")], 6),
    ("CPU used", "percentunit", [("tier:cpu_used:ratio", "{{tier}}")], 8),
    ("CPU steal", "percentunit", [("tier:cpu_steal:ratio", "{{tier}}")], 8),
    ("RAM used", "percentunit", [("tier:mem_used:ratio", "{{tier}}")], 8),
    ("API + web p95 latency", "s", [("tier:api_latency:p95", "{{tier}}")], 12),
    ("Error rate (5xx)", "percentunit", [("tier:http_errors:ratio", "{{tier}}")], 12),
    ("AI p95 by stage", "s", [("tier:ai_stage:p95{stage=~\"total|stt|llm|llm_first_token|tts\"}", "{{tier}} {{kind}} {{stage}}")], 12),
    ("AI queue (waiting / active)", "short", [("sum by (tier, queue, state) (uvbench_queue_depth{state=~\"waiting|active\"})", "{{tier}} {{queue}} {{state}}")], 12),
    ("LLM generation speed (tokens/s)", "short", [("avg by (tier) (llamacpp:predicted_tokens_seconds)", "{{tier}}")], 8),
    ("Speech-to-text real-time factor (p50)", "short", [("tier:stt_rtf:p50", "{{tier}}")], 8),
    ("AI requests rejected (back-pressure) / min", "short", [("sum by (tier, kind) (rate(uvbench_ai_rejected_total[5m])) * 60", "{{tier}} {{kind}}")], 8),
    ("k6 p95 by action", "s", [("max by (tier, name) (k6_http_req_duration_p95{name!=\"\"})", "{{tier}} {{name}}")], 12),
    ("Swap used", "bytes", [("tier:swap_used:bytes", "{{tier}}")], 6),
    ("PostgreSQL active connections", "short", [("sum by (tier) (pg_stat_activity_count{state=\"active\"})", "{{tier}}")], 6),
]


def panel(i, title, unit, exprs, w, x, y):
    return {
        "id": i, "type": "timeseries", "title": title,
        "datasource": {"type": "prometheus", "uid": "prometheus"},
        "gridPos": {"h": 8, "w": w, "x": x, "y": y},
        "fieldConfig": {"defaults": {"unit": unit, "custom": {"lineWidth": 2, "fillOpacity": 8}}, "overrides": []},
        "options": {"legend": {"displayMode": "list", "placement": "bottom"}, "tooltip": {"mode": "multi"}},
        "targets": [{"refId": chr(65 + k), "expr": e, "legendFormat": lg} for k, (e, lg) in enumerate(exprs)],
    }


panels, x, y = [], 0, 0
for i, (t, u, ex, w) in enumerate(PANELS, 1):
    if x + w > 24:
        x, y = 0, y + 8
    panels.append(panel(i, t, u, ex, w, x, y))
    x += w

dash = {
    "uid": "uvbench-overview", "title": "UVBench - capacity, cost & AI", "tags": ["uvbench"],
    "timezone": "utc", "refresh": "30s", "schemaVersion": 39, "time": {"from": "now-6h", "to": "now"},
    "templating": {"list": []}, "panels": panels,
}
out = pathlib.Path(__file__).parent / "dashboards" / "uvbench-overview.json"
out.write_text(json.dumps(dash, indent=1))
print(f"wrote {out} ({len(panels)} panels)")
