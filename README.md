# UVBench: 30-day Vultr capacity, cost and AI benchmark

This repo holds the test application, load tests, monitoring and automation for the 30-day benchmark (Full option)
described in `VPS_30Day_Benchmark_Plan_v3.pdf`.

| Folder | What it is |
|---|---|
| `app/web` | Next.js 16 (React 19) frontend with server-side rendering (SSR) and ISR |
| `app/api` | Node.js 22 Fastify API (REST + WebSocket chat), Node cluster, BullMQ AI worker, Prometheus metrics |
| `ai/stt`, `ai/tts` | Self-hosted speech-to-text (faster-whisper) and text-to-speech (Piper) services |
| (image) | LLM and embeddings run on the official `llama.cpp` server image (Qwen2.5 + nomic-embed) |
| `db` | PostgreSQL 16 + pgvector schema and seed (100k users, 1M products, 500k orders) |
| `compose` | Docker Compose stack for a test server, with Nginx and the metric exporters |
| `tiers` | Per-tier settings: `1c`, `2c`, `4c`, `8c` |
| `loadtest` | k6 scripts (mixed users, ladder, spike, soak, 24 h diurnal, AI-only), voice clips, systemd 24/7 units |
| `monitoring` | Prometheus (60-day retention, k6 remote write) + Grafana dashboards + recording rules |
| `scripts` | One-command server setup, model download, hardware bench, Prometheus targets, CSV export |
| `.github/workflows` | CI (tests + image build to GHCR) and manual deploy |

No external AI APIs are used. Every model is open-source and runs on the server CPU.

## Servers (Vultr, Silicon Valley, all attached to one VPC)

| Role | Plan | Days |
|---|---|---|
| Reference target (24/7) | vx1-g-8c-32g-480s | 1-30 |
| Tier 1c / 2c / 4c | vhp-1c-2gb / vx1-g-2c-8g-120s / vx1-g-4c-16g-240s | 7 each |
| 2nd 4c (horizontal test) | vx1-g-4c-16g-240s | 5 |
| HA: 2nd 8c + DB node + LB | vx1-g-8c-32g-480s, vx1-g-2c-8g-120s, Load Balancer | 12 |
| Load generator(s) | vc2-4c-8gb | 30 (+12) |
| Monitoring | vc2-2c-4gb | 30 |

When creating each one: Ubuntu 24.04, your SSH key, **enable VPC network**, automatic backups **off**.

## Day 1 runbook

Copy the repo to each server (`git clone`, or `scp -r` from your Mac), then as root from the repo folder:

```bash
# 1. monitoring server
bash scripts/bootstrap-monitor.sh <loadgen-private-ip>

# 2. 8c reference target (about 15-25 min: Docker, models, build, 1M-row seed, knowledge base)
bash scripts/bootstrap-target.sh 8c
bash scripts/hwbench.sh <loadgen-private-ip>          # hardware score (run iperf3 -s on the load generator first)

# 3. register the target with Prometheus (on the monitoring server)
bash scripts/monitor-add-target.sh 8c <8c-private-ip>

# 4. load generator
bash scripts/bootstrap-loadgen.sh <monitor-private-ip>
bash /opt/uvbench/loadtest/run.sh 8c <8c-private-ip> smoke
```

Open Grafana at `http://<monitor-public-ip>:3000` (allow your IP first: `ufw allow from <your-ip> to any port 3000`).
Use the **UVBench - capacity, cost & AI** dashboard.

## Test commands (on the load generator)

```bash
R=/opt/uvbench/loadtest/run.sh
bash $R 8c 10.x.x.x smoke                                  # 2 users, 1 min
bash $R 8c 10.x.x.x ladder -e START_VUS=50                 # +10% users every 5 min until the break point (stops itself)
bash $R 8c 10.x.x.x steady -e VUS=400 -e DURATION=1h
bash $R 8c 10.x.x.x spike  -e VUS=200                      # 5x jump for 2 min
bash $R 8c 10.x.x.x soak   -e VUS=300 -e DURATION=168h     # 7-day soak
bash $R 8c 10.x.x.x ai -e KIND=voice                       # AI only: 1,2,4,8,16 concurrent voice requests
# 24/7 continuous load: set CONT_TARGET and CONT_PEAK_VUS in /etc/uvbench/loadgen.env, then
systemctl enable --now uvbench-continuous uvbench-spike.timer
```

Results: every run writes a JSON summary and log to `/var/lib/uvbench/results/<tier>/` and streams to Prometheus.
For the final report: `python3 scripts/export-results.py --since 30d --out /root/results` on the monitoring server.

## Model profiles

| Tier | Speech-to-text | LLM | Notes |
|---|---|---|---|
| 1c | whisper tiny | Qwen2.5-0.5B | "lite": also try the standard profile once to record the failure point |
| 2c / 4c / 8c | whisper base | Qwen2.5-1.5B | identical models, so the results compare like for like |
| 8c "max" (days 15-21) | whisper small | Qwen2.5-7B | `bash scripts/models.sh qwen7`, edit `.env`, `docker compose up -d llm stt` |

Bangla voice: Whisper auto-detects the language. Bangla accuracy improves a lot with `small`/`medium`; the report compares them.

## CI/CD

* **CI** runs on every push: API integration test (real Postgres + Redis, mocked AI), Next.js build, script/config checks,
  k6 parse. On `main` it builds the `api`, `web`, `stt`, `tts` images and pushes them to `ghcr.io/<owner>/uvbench/*`.
* **Deploy** (Actions -> Deploy -> Run workflow): copies the repo to a server, pulls the images and restarts services
  one at a time. Needs the `DEPLOY_SSH_KEY` secret (see the workflow header).
* To make servers pull CI images instead of building: set `IMAGE_PREFIX=ghcr.io/<owner>/uvbench` in `tiers/common.env`.

## Local development

```bash
cd app/api && npm ci && bash test/integration.sh   # needs local Postgres (with pgvector) + Redis, see the script header
cd app/web && npm ci && npm run dev
```
