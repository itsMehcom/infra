#!/bin/bash
# ╔═══════════════════════════════════════════════════════════╗
# ║  Onboard a new service to the PostgreSQL platform         ║
# ║  Creates a dedicated role + database with strict isolation║
# ╚═══════════════════════════════════════════════════════════╝
#
# Usage:
#   ./onboard-service.sh --service-name <name> --db-name <db> --password <pw>
#   ./onboard-service.sh --seed   (pre-seed day-one services from env)
#
# Examples:
#   ./onboard-service.sh --service-name core_api --db-name itsmeh_core --password 's3cureP@ss!'
#   ./onboard-service.sh --service-name keycloak --db-name keycloak --password 'kc_p@ss!'

set -euo pipefail

# ─────────────────────────────────────────────────────────
# Resolve paths
# ─────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${COMPOSE_DIR}/../../environments/production/postgres.env"

# Load superuser credentials
if [[ -f "$ENV_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$ENV_FILE"
else
    echo "❌ Environment file not found: $ENV_FILE"
    echo "   Copy postgres.env.example to postgres.env and fill in credentials."
    exit 1
fi

PG_SUPERUSER="${POSTGRES_USER:-itsmeh_admin}"
PG_CONTAINER="postgres"

# ─────────────────────────────────────────────────────────
# Parse arguments
# ─────────────────────────────────────────────────────────
SERVICE_NAME=""
DB_NAME=""
DB_PASSWORD=""
SEED_MODE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --service-name) SERVICE_NAME="$2"; shift 2 ;;
        --db-name)      DB_NAME="$2"; shift 2 ;;
        --password)     DB_PASSWORD="$2"; shift 2 ;;
        --seed)         SEED_MODE=true; shift ;;
        -h|--help)
            echo "Usage: $0 --service-name <name> --db-name <db> --password <pw>"
            echo "       $0 --seed"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ─────────────────────────────────────────────────────────
# Core onboarding function
# ─────────────────────────────────────────────────────────
onboard_service() {
    local svc_name="$1"
    local db_name="$2"
    local db_password="$3"

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Onboarding service: ${svc_name}"
    echo "  Database: ${db_name}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Check if role already exists
    ROLE_EXISTS=$(docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" "${PG_CONTAINER}" psql -U "${PG_SUPERUSER}" -tAc \
        "SELECT 1 FROM pg_roles WHERE rolname='${svc_name}';" 2>/dev/null || true)

    if [[ "$ROLE_EXISTS" == "1" ]]; then
        echo "⚠️  Role '${svc_name}' already exists. Skipping role creation."
    else
        echo "→ Creating role '${svc_name}'..."
        docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" "${PG_CONTAINER}" psql -U "${PG_SUPERUSER}" -c \
            "CREATE ROLE ${svc_name} WITH LOGIN PASSWORD '${db_password}' NOSUPERUSER NOCREATEDB NOCREATEROLE;"
        echo "✅ Role created."
    fi

    # Check if database already exists
    DB_EXISTS=$(docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" "${PG_CONTAINER}" psql -U "${PG_SUPERUSER}" -tAc \
        "SELECT 1 FROM pg_database WHERE datname='${db_name}';" 2>/dev/null || true)

    if [[ "$DB_EXISTS" == "1" ]]; then
        echo "⚠️  Database '${db_name}' already exists. Skipping database creation."
    else
        echo "→ Creating database '${db_name}' owned by '${svc_name}'..."
        docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" "${PG_CONTAINER}" psql -U "${PG_SUPERUSER}" -c \
            "CREATE DATABASE ${db_name} OWNER ${svc_name} ENCODING 'UTF8' LC_COLLATE 'en_US.UTF-8' LC_CTYPE 'en_US.UTF-8' TEMPLATE template0;"
        echo "✅ Database created."
    fi

    # Revoke PUBLIC access and lock down
    echo "→ Locking down permissions..."
    docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" "${PG_CONTAINER}" psql -U "${PG_SUPERUSER}" -d "${db_name}" -c "
        -- Revoke all default public access
        REVOKE ALL ON DATABASE ${db_name} FROM PUBLIC;
        REVOKE ALL ON SCHEMA public FROM PUBLIC;

        -- Grant the service role full access to its own database
        GRANT ALL ON DATABASE ${db_name} TO ${svc_name};
        GRANT ALL ON SCHEMA public TO ${svc_name};

        -- Ensure the role owns the public schema in its database
        ALTER SCHEMA public OWNER TO ${svc_name};
    "
    echo "✅ Permissions configured."

    echo ""
    echo "┌─────────────────────────────────────────────────────┐"
    echo "│  Connection Details                                 │"
    echo "├─────────────────────────────────────────────────────┤"
    echo "│  Host:     postgres  (Docker service name)          │"
    echo "│  Port:     5432                                     │"
    echo "│  Database: ${db_name}"
    echo "│  Username: ${svc_name}"
    echo "│  URL:      postgresql://${svc_name}:<password>@postgres:5432/${db_name}"
    echo "└─────────────────────────────────────────────────────┘"
    echo ""
}

# ─────────────────────────────────────────────────────────
# Seed mode — pre-configure day-one services
# ─────────────────────────────────────────────────────────
if [[ "$SEED_MODE" == true ]]; then
    echo ""
    echo "╔═══════════════════════════════════════════════════════╗"
    echo "║  Seeding day-one services                            ║"
    echo "╚═══════════════════════════════════════════════════════╝"

    if [[ -z "${SEED_DATABASES:-}" ]]; then
        echo "⚠️  No SEED_DATABASES found in environment. Nothing to seed."
        exit 0
    fi

    for seed_entry in $SEED_DATABASES; do
        # Format: role_name:db_name:PASSWORD_ENV_VAR_NAME
        role=$(echo "$seed_entry" | cut -d: -f1)
        db=$(echo "$seed_entry" | cut -d: -f2)
        pw_env=$(echo "$seed_entry" | cut -d: -f3)

        # Use indirect expansion to get the password value
        pw="${!pw_env:-}"

        if [[ -z "$pw" ]]; then
            read -rsp "Enter password for $role role ($pw_env): " pw
            echo
        fi

        onboard_service "$role" "$db" "$pw"
    done

    echo "═══════════════════════════════════════════════════════"
    echo "  ✅ All day-one services onboarded successfully!"
    echo "═══════════════════════════════════════════════════════"
    exit 0
fi

# ─────────────────────────────────────────────────────────
# Single-service mode
# ─────────────────────────────────────────────────────────
if [[ -z "$SERVICE_NAME" || -z "$DB_NAME" || -z "$DB_PASSWORD" ]]; then
    echo "❌ Missing required arguments."
    echo "Usage: $0 --service-name <name> --db-name <db> --password <pw>"
    echo "       $0 --seed"
    exit 1
fi

onboard_service "$SERVICE_NAME" "$DB_NAME" "$DB_PASSWORD"
echo "✅ Service '${SERVICE_NAME}' onboarded successfully!"
