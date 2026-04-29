# PostgreSQL — Platform Database Service

The shared, centralized database platform for all ItsMeh services. Each service gets an isolated role + database with strict permission separation. Includes physical and logical backups, PITR, health monitoring, and maintenance automation.

---

## Architecture

```
┌────────────────────────────────────────────────────┐
│                Docker "internal" Network            │
│                                                    │
│   ┌──────────┐  ┌──────────┐                       │
│   │ Core API │  │ Keycloak │   ... other services  │
│   └────┬─────┘  └────┬─────┘                       │
│        │              │                            │
│        └──────┬───────┘                            │
│               ▼                                    │
│   ┌───────────────────┐                            │
│   │  PostgreSQL       │──── WAL ──▶ backups/wal/  │
│   │  :5432 (internal) │                            │
│   └───────────────────┘                            │
│                                                    │
│   (PgBouncer :6432 — commented out, future use)    │
│   (postgres_exporter :9187 — commented out)        │
└────────────────────────────────────────────────────┘
```

- **PostgreSQL** port is NOT exposed to the host — only reachable via the `internal` Docker network.
- Services connect directly (Phoenix manages its own connection pool).
- PgBouncer and Prometheus exporter are pre-configured but commented out.

---

## Quick Start

### 1. Create the environment file

```bash
cp environments/production/postgres.env.example environments/production/postgres.env
# Edit postgres.env — set POSTGRES_PASSWORD to a strong value
```

### 2. Ensure Docker network exists

```bash
./scripts/docker-network-setup.sh
```

### 3. Create backup directories

```bash
mkdir -p platform/postgres/backups/{base,wal,logical}
```

### 4. Start PostgreSQL

```bash
cd platform/postgres
docker compose up -d
```

### 5. Verify it's running

```bash
docker exec postgres pg_isready -U itsmeh_admin
# /var/run/postgresql:5432 - accepting connections
```

### 6. Onboard day-one services

```bash
./scripts/onboard-service.sh --seed
```

This creates the `core_api` and `keycloak` roles + databases.

---

## Onboarding a New Service

Every application that needs a database gets its own PostgreSQL role (user) and database. This provides strict isolation — one service cannot access another's data.

```bash
cd platform/postgres

# Create a new service
./scripts/onboard-service.sh \
    --service-name my_service \
    --db-name my_service_db \
    --password 'strong_password_here'
```

The script will output the connection details:

```
Host:     postgres  (Docker service name)
Port:     5432
Database: my_service_db
Username: my_service
URL:      postgresql://my_service:<password>@postgres:5432/my_service_db
```

### Connection String Format

For services on the same Docker `internal` network:

```
postgresql://<role>:<password>@postgres:5432/<database>
```

Example for Phoenix (`config/runtime.exs`):

```elixir
config :my_app, MyApp.Repo,
  url: "postgresql://core_api:#{System.fetch_env!("DB_PASSWORD")}@postgres:5432/itsmeh_core",
  pool_size: String.to_integer(System.get_env("POOL_SIZE", "10"))
```

---

## Backup Strategy

Two complementary backup methods run on automated schedules:

### Physical Backups (pg_basebackup)

| What | Details |
|------|---------|
| Method | `pg_basebackup` streaming + WAL archiving |
| Schedule | Daily at 2:00 AM IST |
| Retention | 7 days (configurable via `--retain-days`) |
| Output | `backups/base/YYYY-MM-DD_HH-MM-SS/` |
| Capabilities | Full cluster restore, Point-in-Time Recovery (PITR) |

```bash
# Manual trigger
./scripts/backup.sh

# Custom retention
./scripts/backup.sh --retain-days 14
```

### Logical Backups (pg_dump)

| What | Details |
|------|---------|
| Method | `pg_dump` in custom format (compressed) |
| Schedule | Daily at 3:00 AM IST |
| Retention | 14 days |
| Output | `backups/logical/<db_name>/YYYY-MM-DD.dump` |
| Capabilities | Per-database restore, portable to any PG instance |

```bash
# Dump a single database
./scripts/dump-service-db.sh --db itsmeh_core

# Dump all service databases
./scripts/dump-service-db.sh --all
```

### WAL Archiving

WAL (Write-Ahead Log) segments are continuously archived to `backups/wal/`. This enables Point-in-Time Recovery — restoring to any moment between backups.

The `archive_timeout = 300` setting ensures WAL is archived at least every 5 minutes, even during low-activity periods.

---

## Restore Procedures

### Full PITR Restore

Restore the entire cluster to a specific point in time:

```bash
# List available backups
./scripts/restore.sh --list

# Restore to a specific timestamp
./scripts/restore.sh --target-time "2026-04-28 12:00:00+05:30"

# Restore to the latest available point
./scripts/restore.sh --latest
```

> ⚠️ **This stops PostgreSQL, destroys the current data, and restores from backup.** The script requires interactive confirmation (`YES`).

### Single-Database Restore

Restore just one service's database from a logical dump:

```bash
# Restore from the latest dump
./scripts/restore-service-db.sh --db itsmeh_core --latest

# Restore from a specific dump file
./scripts/restore-service-db.sh --db itsmeh_core --dump-file backups/logical/itsmeh_core/2026-04-28.dump
```

> ⚠️ **This drops and recreates the target database.** Requires interactive confirmation.

---

## Disaster Recovery Runbook

### Scenario 1: Accidental Table/Data Drop

**Impact**: Single service affected.
**Recovery time**: Minutes.

1. Use logical restore for the affected database:
   ```bash
   ./scripts/restore-service-db.sh --db itsmeh_core --latest
   ```

### Scenario 2: Data Corruption

**Impact**: Potentially all services.
**Recovery time**: 15–60 minutes depending on data size.

1. Stop all application services connecting to PostgreSQL.
2. Perform PITR to the moment before corruption:
   ```bash
   ./scripts/restore.sh --target-time "2026-04-28 11:59:00+05:30"
   ```
3. Verify data integrity.
4. Restart application services.

### Scenario 3: Full Host Failure / Disk Loss

**Impact**: Total database loss.
**Recovery time**: 30–120 minutes.

1. Provision a new host with Docker.
2. Clone this infrastructure repository.
3. Copy backup files (`backups/`) from off-site storage (if available) or secondary disk.
4. Set up `postgres.env` in `environments/production/`.
5. Restore:
   ```bash
   mkdir -p platform/postgres/backups/{base,wal,logical}
   # Copy backups into place
   cd platform/postgres
   docker compose up -d
   # Wait for PostgreSQL to start
   ./scripts/restore.sh --latest
   ```
6. Re-onboard services if needed:
   ```bash
   ./scripts/onboard-service.sh --seed
   ```

### Backup Verification (Monthly)

Test your backups regularly:

```bash
# 1. Spin up a test instance on a separate port
docker run --rm -d --name pg-restore-test \
    -p 15432:5432 \
    -e POSTGRES_PASSWORD=test \
    postgres:18.3-bookworm

# 2. Restore a logical dump to the test instance
pg_restore -h localhost -p 15432 -U postgres -d postgres \
    backups/logical/itsmeh_core/latest.dump

# 3. Run queries to verify data
psql -h localhost -p 15432 -U postgres -c "SELECT count(*) FROM users;"

# 4. Clean up
docker stop pg-restore-test
```

---

## Monitoring & Health Checks

### Health Check Script

Runs hourly via cron. Checks:

| Check | Threshold |
|-------|-----------|
| PostgreSQL connectivity | Must be accepting connections |
| WAL archiving | Last archive < 30 minutes ago |
| Connection usage | < 80% of `max_connections` |
| Disk usage | < 85% |
| Backup freshness | Last backup < 25 hours ago |
| Database sizes | Reported (no threshold) |

```bash
./scripts/healthcheck.sh
```

### Prometheus Metrics (Future)

When ready, uncomment `postgres-exporter` in `docker-compose.yml` and the `PG_EXPORTER_DSN` in `postgres.env`. Metrics will be available at `:9187/metrics`.

---

## Maintenance

### Automated (Weekly)

The `vacuum-maintenance.sh` script runs every Sunday at 4:00 AM IST:
- `VACUUM ANALYZE` on all service databases
- Table bloat estimation (top 5 by size)
- Unused index detection

```bash
# Manual trigger
./scripts/vacuum-maintenance.sh
```

### Installing the Cron Schedule

```bash
# On the production server
crontab /opt/infra/platform/postgres/cron/postgres-backup-cron
```

---

## Configuration Reference

### postgresql.conf Highlights

| Setting | Value | Why |
|---------|-------|-----|
| `max_connections` | 200 | Each service pools its own connections |
| `shared_buffers` | 1GB | ~25% of 4GB RAM (adjust per server) |
| `wal_level` | replica | Supports archiving + future replication |
| `archive_mode` | on | Required for PITR |
| `archive_timeout` | 300s | Archive WAL every 5 min minimum |
| `log_min_duration_statement` | 500ms | Log slow queries |
| `autovacuum_vacuum_scale_factor` | 0.05 | More aggressive autovacuum |
| `timezone` | Asia/Kolkata | Match application timezone |

### pg_hba.conf

- Docker internal network (`172.16.0.0/12`): `scram-sha-256`
- Everything else: `reject`

---

## Troubleshooting

### PostgreSQL won't start

```bash
docker logs postgres
# Check for config errors, file permissions, or data corruption
```

### "too many connections"

```bash
# Check current connections by service
docker exec postgres psql -U itsmeh_admin -c \
    "SELECT usename, datname, count(*) FROM pg_stat_activity GROUP BY 1, 2 ORDER BY 3 DESC;"
```

### WAL archiving stopped

```bash
# Check archiver status
docker exec postgres psql -U itsmeh_admin -c "SELECT * FROM pg_stat_archiver;"

# Check if backups/wal/ is writable
docker exec postgres touch /backups/wal/test && docker exec postgres rm /backups/wal/test
```

### Backup is stale

```bash
# Check cron is running
crontab -l | grep backup

# Run backup manually
./scripts/backup.sh
```

### Service can't connect

1. Verify the service is on the `internal` Docker network.
2. Verify the role exists: `docker exec postgres psql -U itsmeh_admin -c "\du"`
3. Verify the database exists: `docker exec postgres psql -U itsmeh_admin -c "\l"`
4. Test connectivity: `docker exec postgres psql -U <role> -d <database> -c "SELECT 1;"`
