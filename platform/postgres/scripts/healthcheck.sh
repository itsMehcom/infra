#!/bin/bash
# Health Check — Comprehensive PostgreSQL platform health verification
# Usage: ./healthcheck.sh
# Exit codes: 0 = healthy, 1 = issues found
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${COMPOSE_DIR}/../../environments/production/postgres.env"
BACKUP_BASE_DIR="${COMPOSE_DIR}/backups/base"
WAL_ARCHIVE_DIR="${COMPOSE_DIR}/backups/wal"
PG_CONTAINER="postgres"

[[ -f "$ENV_FILE" ]] && source "$ENV_FILE" || { echo "❌ $ENV_FILE not found"; exit 1; }
PG_SUPERUSER="${POSTGRES_USER:-itsmeh_admin}"

ISSUES=0
TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S')"

echo "╔═══════════════════════════════════════════════════════╗"
echo "║  PostgreSQL Health Check — ${TIMESTAMP}       ║"
echo "╚═══════════════════════════════════════════════════════╝"

# 1. PostgreSQL connectivity
echo -n "  [1/6] PostgreSQL connectivity............"
if docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" "${PG_CONTAINER}" pg_isready -U "${PG_SUPERUSER}" > /dev/null 2>&1; then
    echo " ✅ OK"
else
    echo " ❌ FAIL"
    ISSUES=$((ISSUES + 1))
fi

# 2. WAL archiving status
echo -n "  [2/6] WAL archiving......................"
ARCHIVE_STATUS=$(docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" "${PG_CONTAINER}" psql -U "${PG_SUPERUSER}" -tAc \
    "SELECT CASE WHEN last_archived_time > now() - interval '30 minutes' THEN 'OK' ELSE 'STALE' END FROM pg_stat_archiver;" 2>/dev/null || echo "UNKNOWN")
ARCHIVE_STATUS=$(echo "$ARCHIVE_STATUS" | tr -d '[:space:]')
if [[ "$ARCHIVE_STATUS" == "OK" ]]; then
    echo " ✅ OK"
elif [[ "$ARCHIVE_STATUS" == "STALE" ]]; then
    echo " ⚠️  Last archive > 30min ago"
    ISSUES=$((ISSUES + 1))
else
    echo " ⚠️  Could not determine (may be idle)"
fi

# 3. Active connections
echo -n "  [3/6] Connection usage..................."
CONN_INFO=$(docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" "${PG_CONTAINER}" psql -U "${PG_SUPERUSER}" -tAc \
    "SELECT count(*) || '/' || current_setting('max_connections') FROM pg_stat_activity;" 2>/dev/null || echo "?/?")
CONN_INFO=$(echo "$CONN_INFO" | tr -d '[:space:]')
ACTIVE=$(echo "$CONN_INFO" | cut -d'/' -f1)
MAX=$(echo "$CONN_INFO" | cut -d'/' -f2)
if [[ -n "$ACTIVE" && -n "$MAX" && "$ACTIVE" -lt $((MAX * 80 / 100)) ]] 2>/dev/null; then
    echo " ✅ ${CONN_INFO}"
else
    echo " ⚠️  ${CONN_INFO} (high usage)"
    ISSUES=$((ISSUES + 1))
fi

# 4. Disk usage
echo -n "  [4/6] Data directory disk usage.........."
DISK_PCT=$(docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" "${PG_CONTAINER}" df /var/lib/postgresql/data 2>/dev/null | tail -1 | awk '{print $5}' | tr -d '%')
if [[ -n "$DISK_PCT" && "$DISK_PCT" -lt 85 ]] 2>/dev/null; then
    echo " ✅ ${DISK_PCT}%"
else
    echo " ❌ ${DISK_PCT:-?}% (threshold: 85%)"
    ISSUES=$((ISSUES + 1))
fi

# 5. Backup freshness
echo -n "  [5/6] Backup freshness..................."
if [[ -d "${BACKUP_BASE_DIR}" ]]; then
    LATEST_BACKUP=$(find "${BACKUP_BASE_DIR}" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort -r | head -1)
    if [[ -n "$LATEST_BACKUP" ]]; then
        BACKUP_AGE_HOURS=$(( ( $(date +%s) - $(stat -c %Y "$LATEST_BACKUP" 2>/dev/null || echo 0) ) / 3600 ))
        if [[ "$BACKUP_AGE_HOURS" -lt 25 ]]; then
            echo " ✅ ${BACKUP_AGE_HOURS}h ago"
        else
            echo " ❌ ${BACKUP_AGE_HOURS}h ago (stale!)"
            ISSUES=$((ISSUES + 1))
        fi
    else
        echo " ❌ No backups found!"
        ISSUES=$((ISSUES + 1))
    fi
else
    echo " ❌ Backup directory missing!"
    ISSUES=$((ISSUES + 1))
fi

# 6. Database sizes
echo -n "  [6/6] Database sizes....................."
DB_SIZES=$(docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" "${PG_CONTAINER}" psql -U "${PG_SUPERUSER}" -tAc \
    "SELECT string_agg(datname || '=' || pg_size_pretty(pg_database_size(datname)), ', ') FROM pg_database WHERE datistemplate = false;" 2>/dev/null || echo "?")
echo " ${DB_SIZES}"

# Summary
echo ""
if [[ $ISSUES -eq 0 ]]; then
    echo "  ✅ All checks passed!"
    exit 0
else
    echo "  ⚠️  ${ISSUES} issue(s) detected. Review above."
    exit 1
fi
