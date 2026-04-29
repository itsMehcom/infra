#!/bin/bash
# Logical Restore — pg_restore for individual service databases
# Usage:
#   ./restore-service-db.sh --db itsmeh_core --dump-file backups/logical/itsmeh_core/2026-04-28.dump
#   ./restore-service-db.sh --db itsmeh_core --latest
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${COMPOSE_DIR}/../../environments/production/postgres.env"
LOGICAL_BACKUP_DIR="${COMPOSE_DIR}/backups/logical"
PG_CONTAINER="postgres"

[[ -f "$ENV_FILE" ]] && source "$ENV_FILE" || { echo "❌ $ENV_FILE not found"; exit 1; }
PG_SUPERUSER="${POSTGRES_USER:-itsmeh_admin}"

TARGET_DB="" ; DUMP_FILE="" ; USE_LATEST=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --db) TARGET_DB="$2"; shift 2 ;;
        --dump-file) DUMP_FILE="$2"; shift 2 ;;
        --latest) USE_LATEST=true; shift ;;
        *) echo "Usage: $0 --db <name> --dump-file <path> | --latest"; exit 1 ;;
    esac
done

[[ -z "$TARGET_DB" ]] && { echo "❌ --db is required"; exit 1; }

# Find the dump file
if [[ "$USE_LATEST" == true ]]; then
    DUMP_FILE=$(find "${LOGICAL_BACKUP_DIR}/${TARGET_DB}" -name "*.dump" -type f 2>/dev/null | sort -r | head -1)
    [[ -z "$DUMP_FILE" ]] && { echo "❌ No dumps found for '${TARGET_DB}'"; exit 1; }
    echo "→ Using latest dump: $(basename "$DUMP_FILE")"
elif [[ -z "$DUMP_FILE" ]]; then
    echo "❌ Specify --dump-file or --latest"
    exit 1
fi

[[ ! -f "$DUMP_FILE" ]] && { echo "❌ Dump file not found: $DUMP_FILE"; exit 1; }

echo "⚠️  This will DROP and RECREATE database '${TARGET_DB}'."
read -rp "Type 'YES' to proceed: " confirm
[[ "$confirm" != "YES" ]] && { echo "Cancelled."; exit 1; }

# Find the owner of the database
DB_OWNER=$(docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" "${PG_CONTAINER}" psql -U "${PG_SUPERUSER}" -tAc \
    "SELECT pg_catalog.pg_get_userbyid(d.datdba) FROM pg_catalog.pg_database d WHERE d.datname = '${TARGET_DB}';" 2>/dev/null)
[[ -z "$DB_OWNER" ]] && DB_OWNER="${TARGET_DB}"

echo "→ Dropping database '${TARGET_DB}'..."
docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" "${PG_CONTAINER}" psql -U "${PG_SUPERUSER}" -c \
    "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '${TARGET_DB}' AND pid <> pg_backend_pid();" 2>/dev/null
docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" "${PG_CONTAINER}" psql -U "${PG_SUPERUSER}" -c "DROP DATABASE IF EXISTS ${TARGET_DB};"

echo "→ Creating empty database '${TARGET_DB}'..."
docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" "${PG_CONTAINER}" psql -U "${PG_SUPERUSER}" -c \
    "CREATE DATABASE ${TARGET_DB} OWNER ${DB_OWNER} ENCODING 'UTF8' LC_COLLATE 'en_US.UTF-8' LC_CTYPE 'en_US.UTF-8' TEMPLATE template0;"

echo "→ Restoring from dump..."
docker cp "${DUMP_FILE}" "${PG_CONTAINER}:/tmp/restore.dump"
docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" "${PG_CONTAINER}" pg_restore \
    -U "${PG_SUPERUSER}" \
    -d "${TARGET_DB}" \
    --no-owner \
    --no-privileges \
    --verbose \
    /tmp/restore.dump 2>/dev/null || true
docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" "${PG_CONTAINER}" rm -f /tmp/restore.dump

echo "→ Re-applying permissions..."
docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" "${PG_CONTAINER}" psql -U "${PG_SUPERUSER}" -d "${TARGET_DB}" -c "
    REVOKE ALL ON DATABASE ${TARGET_DB} FROM PUBLIC;
    REVOKE ALL ON SCHEMA public FROM PUBLIC;
    GRANT ALL ON DATABASE ${TARGET_DB} TO ${DB_OWNER};
    GRANT ALL ON SCHEMA public TO ${DB_OWNER};
    ALTER SCHEMA public OWNER TO ${DB_OWNER};
"

echo "✅ Database '${TARGET_DB}' restored successfully!"
echo "→ Table count:"
docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" "${PG_CONTAINER}" psql -U "${PG_SUPERUSER}" -d "${TARGET_DB}" -tAc \
    "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public';"
