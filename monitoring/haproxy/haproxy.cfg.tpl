# Self-hosted load balancer for the scale-out test (HAProxy on the monitoring server, private VPC only).
# Rendered by scripts/lb-setup.sh: __NODES__ becomes one "server" line per app node.
global
  maxconn 60000
  stats socket /run/haproxy/admin.sock mode 666 level admin   # runtime API: drain / maint / ready per node

defaults
  mode http
  log stdout format raw local0 notice
  option http-keep-alive
  timeout connect 3s
  timeout client 130s          # AI answers and voice uploads can take a while
  timeout server 130s
  timeout http-request 10s
  timeout tunnel 1h            # chat WebSockets
  retries 2
  option redispatch            # a failed connection is retried on the other node
  
frontend app
  bind :8090
  default_backend nodes

frontend stats
  bind :8405
  http-request use-service prometheus-exporter if { path /metrics }
  stats enable
  stats uri /stats
  stats refresh 5s

backend nodes
  balance leastconn
  option httpchk GET /api/health
  http-check expect status 200
  default-server inter 2s fall 2 rise 2 maxconn 3000 on-marked-down shutdown-sessions
__NODES__
