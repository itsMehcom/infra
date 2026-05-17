#!/bin/bash
# ─────────────────────────────────────────────────────────
# pgAdmin Volume Backup
#
# Backs up the pgAdmin Docker volume containing:
#   - User accounts & authentication (pgadmin4.db)
#   - Query history and preferences
#   - User file storage
#
# Usage:
#   ./backup-pgadmin.sh                  # default 7-day retention
#   ./backup-pgadmin.sh --retain-days 14 # custom retention
# ─────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="${SCRIPT_DIR}/../backups"
VOLUME_NAME="pgadmin_pgadmin_data"
TIMESTAMP="$(date +%Y-%m-%d_%H-%M-%S)"
BACKUP_FILE="pgadmin-${TIMESTAMP}.tar.gz"
RETAIN_DAYS=7

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --retain-days) RETAIN_DAYS="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

mkdir -p "${BACKUP_DIR}"

echo "━━━ pgAdmin Volume Backup ━━━"
echo "  Volume:    ${VOLUME_NAME}"
echo "  Output:    ${BACKUP_DIR}/${BACKUP_FILE}"
echo "  Retention: ${RETAIN_DAYS} days"
echo ""

# Verify volume exists
if ! docker volume inspect "${VOLUME_NAME}" &>/dev/null; then
    echo "❌ Volume '${VOLUME_NAME}' not found. Is pgAdmin running?" >&2
    exit 1
fi

echo "Backing up volume..."
docker run --rm \
    -v "${VOLUME_NAME}":/data:ro \
    -v "${BACKUP_DIR}":/backup \
    alpine tar czf "/backup/${BACKUP_FILE}" -C /data .

echo "✅ Backup saved: ${BACKUP_DIR}/${BACKUP_FILE}"

# Apply retention policy
echo ""
echo "Applying retention (keeping last ${RETAIN_DAYS} days)..."
find "${BACKUP_DIR}" -name "pgadmin-*.tar.gz" -mtime "+${RETAIN_DAYS}" -delete 2>/dev/null || true

REMAINING=$(ls -1 "${BACKUP_DIR}"/pgadmin-*.tar.gz 2>/dev/null | wc -l)
echo "  ${REMAINING} backup(s) on disk."
echo ""
echo "━━━ Backup complete ━━━"
