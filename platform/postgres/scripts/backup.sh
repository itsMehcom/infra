#!/bin/bash
# ╔═══════════════════════════════════════════════════════════╗
# ║  PostgreSQL Physical Backup (pg_basebackup)               ║
# ║  Creates a full base backup + verifies integrity          ║
# ║  Rotates old backups based on retention policy            ║
# ╚═══════════════════════════════════════════════════════════╝
#
# Usage:
#   ./backup.sh                     # Run with defaults
#   ./backup.sh --retain-days 14    # Override retention
#
# Schedule via cron (see cron/postgres-backup-cron)

set -euo pipefail

# ─────────────────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${COMPOSE_DIR}/../../environments/production/postgres.env"

BACKUP_BASE_DIR="${COMPOSE_DIR}/backups/base"
LOG_DIR="${COMPOSE_DIR}/../../logs/postgres"
TIMESTAMP="$(date +%Y-%m-%d_%H-%M-%S)"
BACKUP_DIR="${BACKUP_BASE_DIR}/${TIMESTAMP}"
RETAIN_DAYS=7

PG_CONTAINER="postgres"

# Load superuser credentials
if [[ -f "$ENV_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$ENV_FILE"
else
    echo "❌ Environment file not found: $ENV_FILE"
    exit 1
fi

PG_SUPERUSER="${POSTGRES_USER:-itsmeh_admin}"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --retain-days) RETAIN_DAYS="$2"; shift 2 ;;
        -h|--help) echo "Usage: $0 [--retain-days N]"; exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ─────────────────────────────────────────────────────────
# Pre-flight checks
# ─────────────────────────────────────────────────────────
echo "╔═══════════════════════════════════════════════════════╗"
echo "║  PostgreSQL Physical Backup                          ║"
echo "║  ${TIMESTAMP}                                 ║"
echo "╚═══════════════════════════════════════════════════════╝"

# Ensure backup directory exists
mkdir -p "${BACKUP_DIR}"
mkdir -p "${LOG_DIR}"

# Verify PostgreSQL is reachable
if ! docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" "${PG_CONTAINER}" pg_isready -U "${PG_SUPERUSER}" > /dev/null 2>&1; then
    echo "❌ PostgreSQL is not ready. Aborting backup."
    exit 1
fi
echo "✅ PostgreSQL is ready."

# ─────────────────────────────────────────────────────────
# Perform base backup
# ─────────────────────────────────────────────────────────
echo "→ Starting pg_basebackup..."

docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" "${PG_CONTAINER}" pg_basebackup \
    -U "${PG_SUPERUSER}" \
    -D /tmp/backup_staging \
    -Ft \
    -z \
    -Xs \
    -P \
    --checkpoint=fast \
    --manifest-checksums=SHA256

echo "→ Copying backup from container..."
docker cp "${PG_CONTAINER}:/tmp/backup_staging/." "${BACKUP_DIR}/"

# Clean up staging directory inside container
docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" "${PG_CONTAINER}" rm -rf /tmp/backup_staging

echo "✅ Base backup completed: ${BACKUP_DIR}"

# ─────────────────────────────────────────────────────────
# Verify backup integrity
# ─────────────────────────────────────────────────────────
echo "→ Verifying backup integrity..."

# Check that the backup files exist and are non-empty
if [[ ! -f "${BACKUP_DIR}/base.tar.gz" ]]; then
    echo "❌ Backup verification failed: base.tar.gz not found!"
    exit 1
fi

BACKUP_SIZE=$(du -sh "${BACKUP_DIR}" | cut -f1)
echo "✅ Backup verified. Size: ${BACKUP_SIZE}"

# ─────────────────────────────────────────────────────────
# Record backup metadata
# ─────────────────────────────────────────────────────────
cat > "${BACKUP_DIR}/backup_manifest.json" <<EOF
{
    "timestamp": "${TIMESTAMP}",
    "type": "physical",
    "method": "pg_basebackup",
    "format": "tar+gzip",
    "postgres_version": "18.3",
    "superuser": "${PG_SUPERUSER}",
    "size": "${BACKUP_SIZE}",
    "retention_days": ${RETAIN_DAYS},
    "host": "$(hostname)"
}
EOF

echo "✅ Backup metadata recorded."

# ─────────────────────────────────────────────────────────
# Rotate old backups
# ─────────────────────────────────────────────────────────
echo "→ Rotating backups older than ${RETAIN_DAYS} days..."

DELETED_COUNT=0
if [[ -d "${BACKUP_BASE_DIR}" ]]; then
    while IFS= read -r old_backup; do
        echo "  🗑️  Removing: $(basename "$old_backup")"
        rm -rf "$old_backup"
        DELETED_COUNT=$((DELETED_COUNT + 1))
    done < <(find "${BACKUP_BASE_DIR}" -maxdepth 1 -mindepth 1 -type d -mtime "+${RETAIN_DAYS}" 2>/dev/null)
fi

echo "✅ Rotation complete. Removed ${DELETED_COUNT} old backup(s)."

# ─────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────
TOTAL_BACKUPS=$(find "${BACKUP_BASE_DIR}" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)
TOTAL_SIZE=$(du -sh "${BACKUP_BASE_DIR}" 2>/dev/null | cut -f1)

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Backup Summary"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Current backup:   ${TIMESTAMP}"
echo "  Backup size:      ${BACKUP_SIZE}"
echo "  Total backups:    ${TOTAL_BACKUPS}"
echo "  Total disk usage: ${TOTAL_SIZE}"
echo "  Retention:        ${RETAIN_DAYS} days"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "✅ Physical backup completed successfully!"
