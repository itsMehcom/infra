# pgAdmin 4 — Platform Database Manager

A web-based database administration tool for PostgreSQL. Part of the **Darbar** platform services gateway, accessible at `pgadmin.darbar.itsmeh.com`.

---

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                   Docker "internal" Network                   │
│                                                              │
│   ┌───────────────────┐       ┌───────────────────┐          │
│   │  Nginx            │       │  PostgreSQL       │          │
│   │  :80 (public)     │       │  :5432 (internal) │          │
│   └────┬──────────────┘       └────────▲──────────┘          │
│        │                               │                     │
│        │  proxy_pass                   │  Direct connection   │
│        ▼                               │                     │
│   ┌───────────────────┐                │                     │
│   │  pgAdmin          │────────────────┘                     │
│   │  :80 (internal)   │                                      │
│   └───────────────────┘                                      │
│                                                              │
└──────────────────────────────────────────────────────────────┘

User → darbar.itsmeh.com (index) → pgadmin.darbar.itsmeh.com
         ↓                              ↓
       Basic Auth                     Basic Auth + pgAdmin Login
```

- **pgAdmin** port is NOT exposed to the host — only reachable via the `internal` Docker network through Nginx.
- Server connections are pre-registered dynamically from environment variables.
- Access is gated by HTTP Basic Auth (shared Darbar credentials) + pgAdmin's own login.

---

## Quick Start

### 1. Create the environment file

```bash
cp environments/production/pgadmin.env.example environments/production/pgadmin.env
# Edit pgadmin.env — set PGADMIN_DEFAULT_EMAIL and PGADMIN_DEFAULT_PASSWORD
```

### 2. Ensure Docker network exists

```bash
./scripts/docker-network-setup.sh
```

### 3. Ensure Darbar gateway credentials exist

```bash
# First time — creates .htpasswd with an initial user
htpasswd -c platform/reverse-proxy/nginx/.htpasswd ops_admin

# Add more users later
htpasswd platform/reverse-proxy/nginx/.htpasswd another_user
```

### 4. Start pgAdmin

```bash
cd platform/pgadmin
docker compose up -d
```

### 5. Verify it's running

```bash
docker exec pgadmin wget -qO- http://localhost:80/misc/ping
# PING
```

### 6. Access the UI

Navigate to `http://pgadmin.darbar.itsmeh.com` (or your configured domain).

1. Enter Darbar Basic Auth credentials.
2. Log in with the `PGADMIN_DEFAULT_EMAIL` / `PGADMIN_DEFAULT_PASSWORD` from your env file.
3. The PostgreSQL server should be pre-registered in the left panel — click to connect.

---

## Dynamic Server Registration

Server connections are **not hardcoded** in a static JSON file. Instead, a custom entrypoint wrapper generates `servers.json` at container startup from environment variables:

| Variable | Source | Purpose |
|----------|--------|---------|
| `PGADMIN_SERVER_NAME` | `pgadmin.env` | Display name in pgAdmin sidebar |
| `PGADMIN_SERVER_HOST` | `pgadmin.env` | PostgreSQL hostname (Docker service name) |
| `PGADMIN_SERVER_PORT` | `pgadmin.env` | PostgreSQL port |
| `POSTGRES_USER` | `postgres.env` | PostgreSQL username (shared, DRY) |

The entrypoint runs on **every container start**, ensuring server definitions stay in sync with current environment values. No manual re-registration needed after config changes.

### Adding More Servers

To register additional PostgreSQL instances, extend the `entrypoint-wrapper.sh` to generate additional server entries, or add them manually in pgAdmin (they'll persist in the Docker volume).

---

## Backup & Restore

### What Gets Persisted

| Data | Location | Importance |
|------|----------|------------|
| User accounts & auth | `pgadmin4.db` (SQLite) | **Critical** for multi-user setups |
| Query history | `pgadmin4.db` | Nice to have |
| User preferences | `pgadmin4.db` | Nice to have |
| Server connections | Generated from env vars | **Always recoverable** (no backup needed) |
| Session files | `/var/lib/pgadmin/sessions/` | Disposable |

### Backup

```bash
cd platform/pgadmin

# Default backup (7-day retention)
./scripts/backup-pgadmin.sh

# Custom retention
./scripts/backup-pgadmin.sh --retain-days 14
```

Output: `backups/pgadmin-YYYY-MM-DD_HH-MM-SS.tar.gz`

### Restore

```bash
# List available backups
./scripts/restore-pgadmin.sh --list

# Restore from the most recent backup
./scripts/restore-pgadmin.sh --latest

# Restore from a specific file
./scripts/restore-pgadmin.sh backups/pgadmin-2026-05-17_14-00-00.tar.gz
```

> ⚠️ **This stops pgAdmin, destroys the current data volume, and restores from backup.** Requires interactive confirmation (`YES`).

---

## Disaster Recovery Runbook

### Scenario 1: Container Crash

**Impact**: None — auto-recovers.
**Recovery**: `restart: unless-stopped` handles this automatically.

### Scenario 2: Volume Corruption

**Impact**: Lose user accounts, preferences, query history.
**Recovery time**: 1 minute.

```bash
cd platform/pgadmin
docker compose down
docker volume rm pgadmin_pgadmin_data
docker compose up -d
# Servers auto-register. Recreate user accounts manually.
```

### Scenario 3: Host Migration

**Impact**: Full pgAdmin data loss without backup.
**Recovery time**: 5 minutes.

**On the source host:**
```bash
./scripts/backup-pgadmin.sh
# Copy backups/pgadmin-*.tar.gz to the new host
```

**On the destination host:**
```bash
# 1. Clone repo, set up env files
# 2. Copy backup file to platform/pgadmin/backups/
# 3. Start pgAdmin
cd platform/pgadmin
docker compose up -d
# 4. Restore from backup (preserves all users)
./scripts/restore-pgadmin.sh --latest
```

All user accounts, preferences, and query history are restored.

---

## Configuration Reference

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PGADMIN_DEFAULT_EMAIL` | *(required)* | Initial admin login email |
| `PGADMIN_DEFAULT_PASSWORD` | *(required)* | Initial admin login password |
| `PGADMIN_DISABLE_POSTFIX` | `true` | Disable built-in mail server |
| `PGADMIN_CONFIG_ENHANCED_COOKIE_PROTECTION` | `True` | Security hardening |
| `PGADMIN_CONFIG_LOGIN_BANNER` | *(set)* | Login page warning banner |
| `PGADMIN_CONFIG_CONSOLE_LOG_LEVEL` | `10` | Logging verbosity |
| `PGADMIN_SERVER_NAME` | `ItsMeh PostgreSQL` | Server display name |
| `PGADMIN_SERVER_HOST` | `postgres` | PostgreSQL Docker hostname |
| `PGADMIN_SERVER_PORT` | `5432` | PostgreSQL port |

### Docker Volumes

| Volume | Mount Point | Purpose |
|--------|-------------|---------|
| `pgadmin_data` | `/var/lib/pgadmin` | Config DB, user files, sessions |

---

## Troubleshooting

### pgAdmin won't start

```bash
docker logs pgadmin
# Check for entrypoint errors, permission issues, or port conflicts
```

### Can't reach pgAdmin through nginx

1. Verify pgAdmin is healthy: `docker exec pgadmin wget -qO- http://localhost:80/misc/ping`
2. Verify nginx can resolve pgAdmin: `docker exec nginx nslookup pgadmin`
3. Verify `.htpasswd` exists: `docker exec nginx cat /etc/nginx/conf.d/.htpasswd`
4. Check nginx logs: `tail -f logs/nginx/error.log`

### Server not showing in pgAdmin

1. Check entrypoint output: `docker logs pgadmin | grep entrypoint-wrapper`
2. Verify env vars: `docker exec pgadmin env | grep -E 'POSTGRES_USER|PGADMIN_SERVER'`
3. Check servers.json was generated: `docker exec pgadmin cat /pgadmin4/servers.json`

### "Permission denied" errors

pgAdmin runs as UID 5050. Ensure the log directory is writable:

```bash
sudo chown -R 5050:5050 logs/pgadmin
```
