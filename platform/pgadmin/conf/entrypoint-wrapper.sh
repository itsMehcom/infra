#!/bin/sh
# ─────────────────────────────────────────────────────────
# pgAdmin Entrypoint Wrapper
# Generates servers.json from environment variables so that
# server definitions stay dynamic and DRY with postgres.env.
#
# Runs on every container start to keep the server list
# in sync with current environment values.
# ─────────────────────────────────────────────────────────

set -e

SERVERS_FILE="/var/lib/pgadmin/servers.json"

# Tell pgAdmin to read server definitions from the writable data directory
# (/pgadmin4/ is read-only for the pgadmin user UID 5050)
export PGADMIN_SERVER_JSON_FILE="${SERVERS_FILE}"

cat > "${SERVERS_FILE}" <<EOF
{
  "Servers": {
    "1": {
      "Name": "${PGADMIN_SERVER_NAME:-PostgreSQL}",
      "Group": "Platform",
      "Host": "${PGADMIN_SERVER_HOST:-postgres}",
      "Port": ${PGADMIN_SERVER_PORT:-5432},
      "MaintenanceDB": "postgres",
      "Username": "${POSTGRES_USER:-postgres}",
      "SSLMode": "prefer"
    }
  }
}
EOF

echo "[entrypoint-wrapper] Generated ${SERVERS_FILE} (Host=${PGADMIN_SERVER_HOST:-postgres}, User=${POSTGRES_USER:-postgres})"

# Enable server replacement on every startup so config changes take effect
export PGADMIN_REPLACE_SERVERS_ON_STARTUP=True

# Delegate to the official pgAdmin entrypoint
exec /entrypoint.sh "$@"
