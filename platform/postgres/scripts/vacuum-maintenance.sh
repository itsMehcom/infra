#!/bin/bash
# Vacuum Maintenance — Weekly VACUUM ANALYZE + bloat reporting
# Usage: ./vacuum-maintenance.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${COMPOSE_DIR}/../../environments/production/postgres.env"
PG_CONTAINER="postgres"

[[ -f "$ENV_FILE" ]] && source "$ENV_FILE" || { echo "❌ $ENV_FILE not found"; exit 1; }
PG_SUPERUSER="${POSTGRES_USER:-itsmeh_admin}"

TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S')"

echo "╔═══════════════════════════════════════════════════════╗"
echo "║  PostgreSQL Weekly Maintenance — ${TIMESTAMP}║"
echo "╚═══════════════════════════════════════════════════════╝"

# Get all non-system databases
DATABASES=$(docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" "${PG_CONTAINER}" psql -U "${PG_SUPERUSER}" -tAc \
    "SELECT datname FROM pg_database WHERE datistemplate = false AND datname NOT IN ('postgres');")

for db in $DATABASES; do
    echo ""
    echo "━━━ Database: ${db} ━━━"

    # VACUUM ANALYZE
    echo "→ Running VACUUM ANALYZE..."
    docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" "${PG_CONTAINER}" psql -U "${PG_SUPERUSER}" -d "${db}" -c "VACUUM (VERBOSE, ANALYZE);" 2>&1 | tail -5
    echo "✅ VACUUM ANALYZE complete."

    # Table bloat estimate
    echo "→ Table bloat estimate (top 5):"
    docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" "${PG_CONTAINER}" psql -U "${PG_SUPERUSER}" -d "${db}" -c "
        SELECT
            schemaname || '.' || tablename AS table,
            pg_size_pretty(pg_total_relation_size(schemaname || '.' || tablename)) AS total_size,
            pg_size_pretty(pg_relation_size(schemaname || '.' || tablename)) AS table_size,
            CASE WHEN pg_relation_size(schemaname || '.' || tablename) > 0
                THEN round(100.0 * (pg_total_relation_size(schemaname || '.' || tablename) - pg_relation_size(schemaname || '.' || tablename)) / pg_total_relation_size(schemaname || '.' || tablename), 1)
                ELSE 0
            END AS overhead_pct
        FROM pg_tables
        WHERE schemaname = 'public'
        ORDER BY pg_total_relation_size(schemaname || '.' || tablename) DESC
        LIMIT 5;
    " 2>/dev/null || echo "  (no tables)"

    # Unused indexes
    echo "→ Unused indexes (0 scans):"
    docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" "${PG_CONTAINER}" psql -U "${PG_SUPERUSER}" -d "${db}" -c "
        SELECT
            schemaname || '.' || indexrelname AS index,
            pg_size_pretty(pg_relation_size(indexrelid)) AS size,
            idx_scan AS scans
        FROM pg_stat_user_indexes
        WHERE idx_scan = 0
            AND indexrelname NOT LIKE '%_pkey'
        ORDER BY pg_relation_size(indexrelid) DESC
        LIMIT 10;
    " 2>/dev/null || echo "  (none)"
done

echo ""
echo "✅ Weekly maintenance complete."
