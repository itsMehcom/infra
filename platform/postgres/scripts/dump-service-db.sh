#!/bin/bash
# Logical Backup — pg_dump for individual service databases
# Usage:
#   ./dump-service-db.sh --db itsmeh_core
#   ./dump-service-db.sh --all
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${COMPOSE_DIR}/../../environments/production/postgres.env"
LOGICAL_BACKUP_DIR="${COMPOSE_DIR}/backups/logical"
TIMESTAMP="$(date +%Y-%m-%d_%H-%M-%S)"
RETAIN_DAYS=14
PG_CONTAINER="postgres"

[[ -f "$ENV_FILE" ]] && source "$ENV_FILE" || { echo "❌ $ENV_FILE not found"; exit 1; }
PG_SUPERUSER="${POSTGRES_USER:-itsmeh_admin}"

TARGET_DB="" ; DUMP_ALL=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --db) TARGET_DB="$2"; shift 2 ;;
        --all) DUMP_ALL=true; shift ;;
        --retain-days) RETAIN_DAYS="$2"; shift 2 ;;
        *) echo "Usage: $0 --db <name> | --all [--retain-days N]"; exit 1 ;;
    esac
done

dump_database() {
    local db_name="$1"
    local output_dir="${LOGICAL_BACKUP_DIR}/${db_name}"
    local output_file="${output_dir}/${TIMESTAMP}.dump"
    mkdir -p "${output_dir}"

    echo "→ Dumping '${db_name}'..."
    docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" "${PG_CONTAINER}" pg_dump \
        -U "${PG_SUPERUSER}" \
        -d "${db_name}" \
        -Fc \
        --no-owner \
        --no-privileges \
        --verbose 2>/dev/null > "${output_file}"

    local size
    size=$(du -sh "${output_file}" | cut -f1)
    echo "✅ ${db_name}: ${output_file} (${size})"

    # Rotate old dumps
    find "${output_dir}" -name "*.dump" -mtime "+${RETAIN_DAYS}" -delete 2>/dev/null
}

if [[ "$DUMP_ALL" == true ]]; then
    echo "╔═══════════════════════════════════════════════════════╗"
    echo "║  Logical Backup — All Service Databases              ║"
    echo "╚═══════════════════════════════════════════════════════╝"

    # Get all non-system databases
    DATABASES=$(docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" "${PG_CONTAINER}" psql -U "${PG_SUPERUSER}" -tAc \
        "SELECT datname FROM pg_database WHERE datistemplate = false AND datname NOT IN ('postgres');")

    for db in $DATABASES; do
        dump_database "$db"
    done
    echo "✅ All databases dumped."
elif [[ -n "$TARGET_DB" ]]; then
    dump_database "$TARGET_DB"
else
    echo "❌ Specify --db <name> or --all"
    exit 1
fi
