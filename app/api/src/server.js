// API entry: Node cluster with N processes + one aggregated Prometheus endpoint.
import cluster from 'node:cluster';
import http from 'node:http';
import { config } from './config.js';
import { client, registry } from './metrics.js';

if (cluster.isPrimary) {
  const aggregator = new client.AggregatorRegistry();
  for (let i = 0; i < config.workers; i++) cluster.fork();
  cluster.on('exit', (w, code) => {
    console.error(`api worker ${w.process.pid} exited (${code}), restarting`);
    cluster.fork();
  });
  http.createServer(async (req, res) => {
    if (req.url !== '/metrics') { res.writeHead(404).end(); return; }
    try {
      const body = await aggregator.clusterMetrics();
      res.writeHead(200, { 'content-type': aggregator.contentType }).end(body);
    } catch (e) {
      res.writeHead(500).end(String(e));
    }
  }).listen(config.metricsPort, '0.0.0.0');
  console.log(`api primary ${process.pid}: ${config.workers} workers, metrics on :${config.metricsPort}`);
  const stop = () => { for (const w of Object.values(cluster.workers)) w.process.kill('SIGTERM'); setTimeout(() => process.exit(0), 10000).unref(); };
  process.on('SIGTERM', stop); process.on('SIGINT', stop);
} else {
  client.AggregatorRegistry.setRegistries([registry]);
  new client.AggregatorRegistry(); // installs the worker-side listener that answers the primary's metrics requests
  const { buildApp } = await import('./app.js');
  const app = await buildApp();
  await app.listen({ port: config.port, host: '0.0.0.0' });
  // graceful shutdown: finish in-flight requests (zero-downtime deploys)
  process.on('SIGTERM', async () => { await app.close(); process.exit(0); });
}
