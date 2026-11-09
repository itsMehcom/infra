# Cloudflare Tunnel (cloudflared) — Secure Ingress

Provides a secure, outbound-only tunnel from this server to Cloudflare's edge network. Eliminates the need to expose any ports to the public internet — all traffic enters through Cloudflare's proxy and is routed to internal services via the tunnel.

---

## Architecture

```
                              Internet
                                 │
                          ┌──────┴──────┐
                          │  Cloudflare │  DNS + CDN + WAF + DDoS
                          │  Edge       │  TLS termination
                          └──────┬──────┘
                                 │
                    Outbound-only connection
                    (no inbound ports needed)
                                 │
┌────────────────────────────────┼────────────────────────────┐
│           Docker "internal" Network                         │
│                                │                            │
│                      ┌─────────┴─────────┐                  │
│                      │   cloudflared     │                  │
│                      │   (connector)     │                  │
│                      └─────────┬─────────┘                  │
│                                │                            │
│                      ┌─────────┴─────────┐                  │
│                      │     Nginx         │                  │
│                      │     :80           │                  │
│                      └─────────┬─────────┘                  │
│                                │                            │
│              ┌─────────────────┼─────────────────┐          │
│              │                 │                 │          │
│         ┌────┴───┐       ┌────┴───┐        ┌────┴───┐      │
│         │  App   │       │pgAdmin │        │  ...   │      │
│         │ :4000  │       │  :80   │        │        │      │
│         └────────┘       └────────┘        └────────┘      │
│                                                             │
└─────────────────────────────────────────────────────────────┘

Key: All connections from cloudflared → Nginx/services are internal Docker traffic.
     NO inbound ports open on the host firewall.
```

- **cloudflared** maintains a persistent outbound connection to Cloudflare's edge.
- **Ingress rules** are configured in the Cloudflare dashboard (Zero Trust → Tunnels), NOT locally.
- **Nginx** remains the internal reverse proxy — cloudflared routes to `http://nginx:80`.
- **No ports need to be exposed** on the host machine's firewall.

---

## Quick Start

### 1. Create a Cloudflare Tunnel

1. Log in to [Cloudflare Dashboard](https://dash.cloudflare.com)
2. Navigate to **Zero Trust** → **Networks** → **Tunnels**
3. Click **Create a tunnel** → choose **Cloudflared** connector type
4. Name the tunnel (e.g., `itsmeh-prod`)
5. On the **Install connector** step, copy the **tunnel token** (the long string after `--token`)

### 2. Configure Tunnel Ingress Rules (in Cloudflare Dashboard)

Add public hostnames pointing to your internal nginx:

| Public Hostname | Service | Description |
|----------------|---------|-------------|
| `itsmeh.com` | `http://nginx:80` | Main domain |
| `api.itsmeh.com` | `http://nginx:80` | Core API |
| `darbar.itsmeh.com` | `http://nginx:80` | Platform services portal |
| `pgadmin.darbar.itsmeh.com` | `http://nginx:80` | Database management |

> **Important**: All routes point to `http://nginx:80` because nginx handles the vhost routing internally. Do NOT point individual hostnames directly to backend services — nginx enforces auth, headers, and rate limiting.

### 3. Create the environment file

```bash
cp environments/production/cloudflared.env.example environments/production/cloudflared.env
# Edit cloudflared.env — paste your tunnel token
```

### 4. Ensure Docker network exists

```bash
./scripts/docker-network-setup.sh
```

### 5. Start cloudflared

```bash
cd platform/cloudflared
docker compose up -d
```

### 6. Verify the tunnel is connected

```bash
# Check container health status (uses built-in "cloudflared tunnel ready")
docker inspect cloudflared --format='{{.State.Health.Status}}'
# Expected: healthy

# Or check readiness directly via cloudflared CLI
docker exec cloudflared cloudflared tunnel ready
# Exit code 0 indicates tunnel is ready

# Check Cloudflare dashboard
# Zero Trust → Tunnels → your tunnel should show "HEALTHY"
```

---

## Security Considerations

### What This Solves

| Before (Direct Exposure) | After (Tunnel) |
|--------------------------|----------------|
| Ports 80/443 open on host firewall | No inbound ports needed |
| Public IP directly reachable | Server IP hidden behind Cloudflare |
| DDoS hits your server directly | Cloudflare absorbs DDoS at edge |
| TLS cert management on server | Cloudflare handles TLS termination |
| WAF rules managed locally | Cloudflare WAF at edge |

### Security Posture

- **Outbound-only**: cloudflared initiates all connections to Cloudflare's edge. No inbound firewall rules needed.
- **No ports exposed**: The container exposes nothing to the host. Only the internal metrics endpoint (20241) is available within the container and internal network for healthchecks and Prometheus scraping.
- **Non-root execution**: The official cloudflared image runs as UID 65532 (nonroot).
- **Token-based auth**: The tunnel token authenticates the connector. Treat it as a secret — never commit it.
- **Cloudflare Access (recommended)**: For platform services, consider adding Cloudflare Access policies on top of Darbar Basic Auth for zero-trust access control.

### Risks & Mitigations

| Risk | Severity | Mitigation |
|------|----------|------------|
| Tunnel token leak → attacker can impersonate connector | **Critical** | Token in `.env` (gitignored). Rotate via Cloudflare dashboard if compromised. |
| Cloudflare outage → all traffic blocked | **High** | Monitor Cloudflare status. Keep nginx port exposure as a documented fallback (do NOT enable by default). |
| Tunnel misconfiguration → bypass nginx auth | **Medium** | Always route through nginx, never directly to backends. Review ingress rules in dashboard. |
| Stale Cloudflare IP ranges in nginx config | **Low** | Update `snippets/cloudflare-real-ip.conf` periodically. Consider automating with a cron job. |
| Metrics endpoint information disclosure | **Low** | Port 20241 is only available on the internal Docker network (not exposed to the host). |

---

## Post-Installation: Harden Host Firewall

Once cloudflared is confirmed working, **close ports 80 and 443 on the host firewall**:

```bash
# UFW example (Ubuntu)
sudo ufw deny 80/tcp
sudo ufw deny 443/tcp
sudo ufw reload

# Verify only SSH (or your management port) remains open
sudo ufw status
```

> ⚠️ **Do this AFTER confirming the tunnel is healthy.** Keep SSH access open for management. Consider using Cloudflare Access for SSH too (via `cloudflared access`).

Optionally, remove the host port bindings from `platform/reverse-proxy/nginx/docker-compose.yml`:

```yaml
# Before (ports exposed to host):
ports:
  - "80:80"
  - "443:443"

# After (internal only — cloudflared routes traffic):
# ports:
#   - "80:80"
#   - "443:443"
```

> **Note**: Keep the port bindings commented out (not deleted) so they can be re-enabled as a fallback.

---

## Configuration Reference

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `TUNNEL_TOKEN` | *(required)* | Tunnel authentication token from Cloudflare dashboard |
| `TUNNEL_METRICS` | `0.0.0.0:20241` | Address for the metrics/readiness endpoint |

### Metrics Endpoint

The metrics endpoint at `:20241` provides:

| Path | Description |
|------|-------------|
| `/ready` | Returns 200 when tunnel is connected and healthy |
| `/metrics` | Prometheus-format metrics (connections, errors, latency) |

When Prometheus/Grafana is deployed, add this as a scrape target:
```yaml
# In prometheus.yml
- job_name: 'cloudflared'
  static_configs:
    - targets: ['cloudflared:20241']
```

---

## Operational Procedures

### Rotating the Tunnel Token

1. Go to Cloudflare Dashboard → Zero Trust → Tunnels
2. Select your tunnel → **Configure** → **Token** → **Regenerate token**
3. Update `environments/production/cloudflared.env` with the new token
4. Restart the container:
   ```bash
   cd platform/cloudflared
   docker compose down && docker compose up -d
   ```

### Updating cloudflared Version

1. Check the [cloudflared releases](https://github.com/cloudflare/cloudflared/releases)
2. Update the image tag in `docker-compose.yml`
3. Pull and restart:
   ```bash
   cd platform/cloudflared
   docker compose pull
   docker compose up -d
   ```
4. Verify health: `docker inspect cloudflared --format='{{.State.Health.Status}}'`

### Monitoring Tunnel Health

```bash
# Quick status
docker inspect cloudflared --format='{{.State.Health.Status}}'

# Detailed logs
docker logs cloudflared --tail 50

# Metrics (scraped via internal network e.g. from Prometheus or a debug container)
docker run --rm --network internal curlimages/curl:latest http://cloudflared:20241/metrics
```

---

## Disaster Recovery

### Scenario 1: Container Crash

**Impact**: None — auto-recovers.
**Recovery**: `restart: unless-stopped` handles this. Cloudflare will retry connections from edge.

### Scenario 2: Tunnel Token Revoked

**Impact**: All traffic stops flowing through the tunnel.
**Recovery time**: 5 minutes.

1. Create a new tunnel or regenerate the token in Cloudflare dashboard.
2. Update `cloudflared.env` with the new token.
3. Restart: `docker compose down && docker compose up -d`

### Scenario 3: Host Migration

**Impact**: Tunnel disconnects.
**Recovery time**: 10 minutes.

1. On the new host: clone repo, set up env files.
2. Copy `cloudflared.env` (or re-create with the same token).
3. Start cloudflared: `docker compose up -d`
4. The tunnel reconnects automatically — no Cloudflare dashboard changes needed (the token is portable).

---

## Troubleshooting

### Tunnel not connecting

```bash
# Check container logs for auth errors
docker logs cloudflared --tail 30

# Common causes:
# - Invalid or expired tunnel token
# - DNS resolution failure (container can't reach Cloudflare)
# - Network policy blocking outbound connections
```

### Sites unreachable through tunnel

1. Verify tunnel is healthy: `docker exec cloudflared cloudflared tunnel ready`
2. Verify ingress rules in Cloudflare dashboard match your domains
3. Verify nginx is reachable on internal network: `docker run --rm --network internal curlimages/curl:latest http://nginx:80/ping`
4. Check nginx logs: `tail -f logs/nginx/error.log`

### Metrics endpoint not responding

```bash
# Verify TUNNEL_METRICS is set
docker exec cloudflared env | grep TUNNEL_METRICS
# Should show: TUNNEL_METRICS=0.0.0.0:9090
```
