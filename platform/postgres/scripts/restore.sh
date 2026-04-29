#!/bin/bash
# PITR Restore — Restores from base backup + replays WAL
# Usage:
#   ./restore.sh --target-time "2026-04-28 12:00:00+05:30"
#   ./restore.sh --latest
#   ./restore.sh --list
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${COMPOSE_DIR}/../../environments/production/postgres.env"
BACKUP_BASE_DIR="${COMPOSE_DIR}/backups/base"
WAL_ARCHIVE_DIR="${COMPOSE_DIR}/backups/wal"
PG_CONTAINER="postgres"
PG_DATA_VOLUME="postgres_pgdata"

[[ -f "$ENV_FILE" ]] && source "$ENV_FILE" || { echo "❌ $ENV_FILE not found"; exit 1; }
PG_SUPERUSER="${POSTGRES_USER:-itsmeh_admin}"

TARGET_TIME="" ; RESTORE_LATEST=false ; LIST_ONLY=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --target-time) TARGET_TIME="$2"; shift 2 ;;
        --latest) RESTORE_LATEST=true; shift ;;
        --list) LIST_ONLY=true; shift ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done

if [[ "$LIST_ONLY" == true ]]; then
    echo "Available backups:" ; ls -1 "${BACKUP_BASE_DIR}" 2>/dev/null || echo "  None"
    echo "WAL segments: $(find "${WAL_ARCHIVE_DIR}" -type f 2>/dev/null | wc -l)"
    exit 0
fi

[[ -z "$TARGET_TIME" && "$RESTORE_LATEST" != true ]] && { echo "❌ Specify --target-time or --latest"; exit 1; }

LATEST_BACKUP=$(find "${BACKUP_BASE_DIR}" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort -r | head -1)
[[ -z "$LATEST_BACKUP" ]] && { echo "❌ No backups found"; exit 1; }

echo "⚠️  This will STOP PostgreSQL, DESTROY the data volume, and restore from backup."
echo "  Base backup: $(basename "$LATEST_BACKUP")"
[[ "$RESTORE_LATEST" == true ]] && echo "  Target: latest" || echo "  Target: ${TARGET_TIME}"
read -rp "Type 'YES' to proceed: " confirm
[[ "$confirm" != "YES" ]] && { echo "Cancelled."; exit 1; }

echo "→ Stopping PostgreSQL..."
cd "${COMPOSE_DIR}" && docker compose stop postgres
docker volume rm "${PG_DATA_VOLUME}" 2>/dev/null || true

echo "→ Restoring base backup..."
docker run --rm -v "${PG_DATA_VOLUME}:/var/lib/postgresql" \
    -v "${LATEST_BACKUP}:/backup:ro" postgres:18.3-bookworm \
    bash -c "mkdir -p /var/lib/postgresql/data/18 && cd /var/lib/postgresql/data/18 && tar xzf /backup/base.tar.gz && chown -R postgres:postgres /var/lib/postgresql"

RECOVERY_CONF="restore_command = 'cp /backups/wal/%f %p'"
[[ "$RESTORE_LATEST" != true ]] && RECOVERY_CONF="${RECOVERY_CONF}
recovery_target_time = '${TARGET_TIME}'
recovery_target_action = 'promote'"

docker run --rm -v "${PG_DATA_VOLUME}:/var/lib/postgresql" postgres:18.3-bookworm \
    bash -c "touch /var/lib/postgresql/data/18/recovery.signal && echo \"${RECOVERY_CONF}\" >> /var/lib/postgresql/data/18/postgresql.auto.conf && chown postgres:postgres /var/lib/postgresql/data/18/recovery.signal /var/lib/postgresql/data/18/postgresql.auto.conf"

echo "→ Starting PostgreSQL in recovery mode..."
docker compose up -d postgres

MAX_WAIT=300 ; WAITED=0
while ! docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" "${PG_CONTAINER}" pg_isready -U "${PG_SUPERUSER}" > /dev/null 2>&1; do
    [[ $WAITED -ge $MAX_WAIT ]] && { echo "❌ Timeout"; exit 1; }
    sleep 5 ; WAITED=$((WAITED + 5)) ; echo "  Waiting... (${WAITED}s)"
done

echo "✅ Recovery complete. Verifying..."
docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" "${PG_CONTAINER}" psql -U "${PG_SUPERUSER}" -c "\l"
echo "✅ PITR Restore finished!"
