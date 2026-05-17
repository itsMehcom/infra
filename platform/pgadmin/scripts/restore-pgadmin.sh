#!/bin/bash
# ─────────────────────────────────────────────────────────
# pgAdmin Volume Restore
#
# Restores the pgAdmin Docker volume from a backup archive.
# This preserves all user accounts, preferences, and
# query history for lossless migration between hosts.
#
# Usage:
#   ./restore-pgadmin.sh --latest                       # restore latest backup
#   ./restore-pgadmin.sh --list                         # list available backups
#   ./restore-pgadmin.sh backups/pgadmin-YYYY-MM-DD.tar.gz  # restore specific backup
# ─────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/../docker-compose.yml"
BACKUP_DIR="${SCRIPT_DIR}/../backups"
VOLUME_NAME="pgadmin_pgadmin_data"

# ─── Parse arguments ───
if [[ $# -eq 0 ]]; then
    echo "Usage:"
    echo "  restore-pgadmin.sh --latest                   Restore from the most recent backup"
    echo "  restore-pgadmin.sh --list                     List available backups"
    echo "  restore-pgadmin.sh <backup-file>              Restore from a specific file"
    exit 1
fi

if [[ "$1" == "--list" ]]; then
    echo "━━━ Available pgAdmin Backups ━━━"
    if ls -1 "${BACKUP_DIR}"/pgadmin-*.tar.gz &>/dev/null; then
        ls -lhtr "${BACKUP_DIR}"/pgadmin-*.tar.gz
    else
        echo "  (none found in ${BACKUP_DIR})"
    fi
    exit 0
fi

if [[ "$1" == "--latest" ]]; then
    BACKUP_FILE="$(ls -t "${BACKUP_DIR}"/pgadmin-*.tar.gz 2>/dev/null | head -1)"
    if [[ -z "${BACKUP_FILE}" ]]; then
        echo "❌ No backups found in ${BACKUP_DIR}" >&2
        exit 1
    fi
else
    BACKUP_FILE="$1"
fi

if [[ ! -f "${BACKUP_FILE}" ]]; then
    echo "❌ Backup file not found: ${BACKUP_FILE}" >&2
    exit 1
fi

# ─── Confirmation ───
echo "━━━ pgAdmin Volume Restore ━━━"
echo ""
echo "  ⚠️  This will:"
echo "    1. STOP pgAdmin"
echo "    2. DESTROY the current data volume"
echo "    3. RESTORE from backup"
echo "    4. RESTART pgAdmin"
echo ""
echo "  Backup: ${BACKUP_FILE}"
echo "  Volume: ${VOLUME_NAME}"
echo ""
read -p "Type YES to proceed: " CONFIRM
if [[ "${CONFIRM}" != "YES" ]]; then
    echo "Aborted."
    exit 1
fi

# ─── Restore ───
echo ""
echo "Stopping pgAdmin..."
docker compose -f "${COMPOSE_FILE}" down

echo "Removing old volume..."
docker volume rm "${VOLUME_NAME}" 2>/dev/null || true

echo "Creating fresh volume..."
docker volume create "${VOLUME_NAME}"

echo "Restoring data from backup..."
BACKUP_BASENAME="$(basename "${BACKUP_FILE}")"
BACKUP_FULLDIR="$(cd "$(dirname "${BACKUP_FILE}")" && pwd)"

docker run --rm \
    -v "${VOLUME_NAME}":/data \
    -v "${BACKUP_FULLDIR}":/backup:ro \
    alpine tar xzf "/backup/${BACKUP_BASENAME}" -C /data

echo "Starting pgAdmin..."
docker compose -f "${COMPOSE_FILE}" up -d

echo ""
echo "✅ Restore complete."
echo "   All users, preferences, and query history have been restored."
echo "   Server connections will be regenerated from environment variables."
