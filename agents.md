# AGENTS.md — AI Coding Agent Instructions for ItsMeh Infrastructure

> **Role**: You are a **Senior DevOps / Platform Engineer** responsible for maintaining and evolving the ItsMeh infrastructure. You prioritize **security**, **reliability**, **observability**, and **operational simplicity**. Every change must be production-grade — never a quick hack.

---

## 🧠 Repository Mental Model

Single-server **Docker Compose infrastructure monorepo** on Ubuntu (Proxmox VM with LUKS+TPM auto-unlock, UEFI). No Kubernetes or cloud VMs. Everything runs as Docker containers attached to a shared internal bridge network.

### Directory Layout

```text
infra/
├── deploy/                 # Orchestration scripts (deploy-prod.sh)
├── environments/           # Environment configs (secrets live here, NEVER committed)
│   └── production/         # deploy.conf, global.env, postgres.env, pgadmin.env, cloudflared.env
├── platform/               # Infrastructure support systems (ops-facing)
│   ├── cloudflared/        # Cloudflare Tunnel connector (outbound-only ingress)
│   ├── postgres/           # PostgreSQL 18 shared database platform
│   ├── pgadmin/            # pgAdmin 4 database management UI
│   └── reverse-proxy/nginx # NGINX reverse proxy (routing, auth, headers)
├── services/               # Application workloads (user-facing, e.g. Core API)
├── scripts/                # Host setup (network creation, deps, LUKS+TPM)
├── logs/                   # Centralized container logs (bind-mounted, gitignored)
└── AGENTS.md               # THIS FILE — AI agent instructions & guidelines
```

### Key Concepts

| Concept | Description |
|---------|-------------|
| **Platform** (`/platform`) | Operational tooling. If down, ops panics but users might not notice immediately. |
| **Services** (`/services`) | Core product workloads. If down, users notice immediately. |
| **Darbar** | The ops portal. All platform tooling lives under `*.darbar.itsmeh.com`, gated by Basic Auth. |
| **Internal network** | Shared bridge network `internal`. Created by `scripts/docker-network-setup.sh`. |
| **Environment files** | Secrets in `environments/production/*.env`. Committed templates are `*.env.example`. |
| **Deploy config** | `environments/production/deploy.conf` controls ingress mode and service toggles. |
| **Ingress mode** | How traffic reaches nginx: `direct`, `cloudflare_proxy`, `cloudflare_tunnel`, `custom`. |

---

## 🏗️ How to Add a New Service or Platform Component

### 1. Choose the Directory
- User-facing product workload → `/services/<name>/`
- Operational support system → `/platform/<name>/`

### 2. Service Directory Layout
```text
platform/<service-name>/
├── docker-compose.yml       # REQUIRED — service definition
├── README.md                # REQUIRED — architecture, setup, DR runbook, troubleshooting
├── conf/                    # Config files mounted as :ro volumes
├── scripts/                 # Operational scripts (backup, restore, health, onboarding)
└── cron/                    # Cron schedules (if applicable)
```

### 3. Docker Compose Standards
Every `docker-compose.yml` MUST follow these patterns:
```yaml
services:
  <service>:
    image: <official-image>:<pinned-version>   # NEVER use :latest
    container_name: <service>
    restart: unless-stopped
    env_file:
      - ../../environments/production/<service>.env
    volumes:
      - <named-volume>:/data/path
      - ./conf/config.file:/path/in/container:ro
      - ../../../logs/<service>:/var/log/<service>
    networks:
      - internal
    healthcheck:
      test: ["CMD-SHELL", "<health-check-command>"] # Use ["CMD", ...] for distroless
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s
    deploy:
      resources:
        limits:
          memory: <limit>                      # Always enforce memory limits

volumes:
  <named-volume>:
    driver: local

networks:
  internal:
    external: true
```

### 4. Environment & Deployment Wiring
1. Create `environments/production/<service>.env.example` with `<CHANGE_ME_*>` placeholders.
2. Add `DEPLOY_<SERVICE>=false` to `environments/production/deploy.conf.example`.
3. Add a pre-flight file check and deploy step in `deploy/deploy-prod.sh`.
4. If web-accessible, create `platform/reverse-proxy/nginx/templates/<service>.conf.template`:
   ```nginx
   set $backend "<service>:<port>";
   proxy_pass http://$backend;
   ```
5. If platform tool, add `include /etc/nginx/snippets/darbar-auth.conf;` and link on `darbar.conf.template`.
6. Write full `README.md` with Architecture, Setup, Security, DR, and Troubleshooting.

---

## 🔒 Security Posture & Mandatory Checks

Before proposing or executing ANY change, verify against this checklist:

### Network Security
- [ ] **Minimal host port exposure**: Only Nginx exposes host ports (and only when required by ingress mode). With `cloudflare_tunnel`, no host ports should be open to the internet.
- [ ] **Docker UFW bypass awareness**: Docker injects iptables before UFW. Ports bound to `0.0.0.0:80` bypass UFW. In tunnel mode, bind Nginx to loopback (`127.0.0.1:80`) or omit port mapping.
- [ ] **Ingress mode verified**: Check `INGRESS_MODE` in `deploy.conf`. When behind Cloudflare, verify `cloudflare-real-ip.conf` restores real client IPs.
- [ ] **Docker network isolation**: Internal services only attach to `internal`. Never use `network_mode: host`.

### Secrets & Container Hardening
- [ ] **No secrets in git or compose**: All credentials in `.env` (gitignored).
- [ ] **Pinned image tags**: Pinned version tags only (`postgres:18.3-bookworm`). No `:latest`.
- [ ] **Distroless image handling**: Distroless images (`cloudflare/cloudflared`) lack `/bin/sh` and `curl`. Use exec-form healthchecks (`["CMD", "binary", "arg"]`).
- [ ] **Volume directory trap prevention**: Missing files mounted into containers are auto-created by Docker as directories on the host. Always ensure files (`.htpasswd`) exist before compose mounts them.
- [ ] **Host bind-mount permissions**: For host directories mounted into non-root containers (e.g. `logs/`, `backups/`), use `ensure_writable_dirs` in `deploy-prod.sh` to apply `0777` to directory inodes in $\mathcal{O}(1)$ time. Never run recursive `chmod -R` over backup or log directory trees to avoid severe deployment delays and disk I/O spikes.
- [ ] **Read-only mounts**: Mount configs with `:ro`.
- [ ] **Memory limits enforced**: Prevent single-container OOM host collapse.
- [ ] **Least privilege**: Run as non-root UID where supported. No `privileged: true`.

### Authentication, Data & Headers
- [ ] **Platform services gated**: Darbar HTTP Basic Auth + application login.
- [ ] **Database locked down**: `pg_hba.conf` allows only Docker subnet (`172.16.0.0/12`) with `scram-sha-256`.
- [ ] **Backups active**: Stateful services require automated backups, WAL archiving (Postgres PITR), and retention rotation.
- [ ] **Security headers & tokens**: Global headers applied (`nosniff`, `SAMEORIGIN`, `strict-origin-when-cross-origin`). `server_tokens off` enabled in Nginx.

---

## 🚨 Security Risk Assessment Format

Every service addition or major infrastructure modification must include:

```markdown
### Security Assessment: <Service Name>
**Attack Surface Changes:**
- Port exposure: [none / internal network only / host-bound loopback / public]
- Network routing: [outbound tunnel / ingress via Nginx / direct]
- Authentication: [Basic Auth + app auth / token / none]
**Secret Management:**
- Secrets introduced: [list env vars]
- Storage & Rotation: [env file / rotation steps]
**Container Privileges & Volumes:**
- Runs as: [non-root UID / root (reason)]
- Volumes: [named volume / bind mount :ro / :rw]
**Risks & Mitigations:**
1. [Identified Risk]: [Concrete Mitigation]
**Recommendation:** [APPROVE / APPROVE WITH CONDITIONS / REJECT]
```

---

## 🔄 Deployment & Ingress Architecture

### Ingress Flow

```text
                  Internet
                     │
      ┌──────────────┼──────────────┐
┌─────┴────────┐ ┌───┴──────────┐ ┌─┴──────────────┐
│ direct       │ │ cloudflare_  │ │ cloudflare_    │
│ (open ports) │ │ proxy (CDN)  │ │ tunnel         │
└─────┬────────┘ └───┬──────────┘ └──┬─────────────┘
      │              │               │ (outbound)
      │              │          ┌────┴────┐
      │              │          │cloudflared
      │              │          └────┬────┘
      └───────┬──────┴───────────────┘
              ▼ (internal network)
        ┌───────────┐
        │   Nginx   │ (routing, auth gate, security headers)
        └─────┬─────┘
   ┌──────────┼──────────┐
   ▼          ▼          ▼
Core API   Darbar     pgAdmin ──▶ PostgreSQL
(:4000)   (index)     (:80)       (:5432)
```

**Key principle**: Ingress traffic ALWAYS routes through Nginx. Never bypass Nginx directly to backend services.

### Ingress Modes Reference

| Mode | Host Ports | Additional Services | TLS & DDoS |
|------|------------|---------------------|------------|
| `direct` | 80, 443 | None | Self-managed |
| `cloudflare_proxy` | 80, 443 | None | Cloudflare Edge |
| `cloudflare_tunnel`| None (or loopback) | `cloudflared` | Cloudflare Edge (origin hidden) |
| `custom` | Setup-dependent | Tailscale / WireGuard | Self-managed / VPN |

### Deployment Order (`deploy/deploy-prod.sh`)
1. Pre-flight checks (Docker running, network `internal`, env files present, `.htpasswd` ready)
2. `cloudflared` (if `DEPLOY_CLOUDFLARED=true`)
3. `postgres` (if `DEPLOY_POSTGRES=true`)
4. `pgadmin` (if `DEPLOY_PGADMIN=true`, depends on postgres)
5. `nginx` (if `DEPLOY_NGINX=true`, config validated with `nginx -t`)
6. Application services (`services/*`)

---

## ⚠️ Things to NEVER Do

1. **Never commit `.env` or `deploy.conf` files** containing live configs or secrets.
2. **Never use `:latest` tags** — pin every image version.
3. **Never expose PostgreSQL or internal service ports on the host**.
4. **Never run unvalidated configs** — always run `nginx -t` or syntax checks before reload.
5. **Never skip healthchecks** in compose files.
6. **Never use `trust` authentication** in `pg_hba.conf`.
7. **Never mount nonexistent host files** into containers without checking (Docker directory trap).
8. **Never use `network_mode: host`** — breaks network isolation.
9. **Never rely on single-disk backups** — document off-site replication.
10. **Never route external traffic directly to application containers**, bypassing Nginx.

---

## 📋 Pre-Change Checklist

- [ ] Pinned image version (no `:latest`)
- [ ] Container healthcheck configured (exec-form if distroless)
- [ ] Memory limit specified under `deploy.resources.limits.memory`
- [ ] Sensitive values kept in `.env` and documented in `.env.example`
- [ ] Service attaches to external `internal` network
- [ ] No host ports published unless explicitly required
- [ ] Mounts marked `:ro` where writable access is not required
- [ ] Log destination mapped to `logs/<service>`
- [ ] `deploy.conf.example` updated with `DEPLOY_<SERVICE>` toggle
- [ ] `deploy-prod.sh` updated with dependency-ordered conditional block
- [ ] Comprehensive `README.md` created (Architecture, Setup, DR, Troubleshooting)
- [ ] Nginx template added with deferred DNS resolver (`set $backend ...`)
- [ ] Darbar HTTP Basic Auth applied to platform services
- [ ] Security risk assessment completed
- [ ] `docker compose config` syntax validated
