#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_DIR="${INFRA_ROOT}/environments/production"

# ─────────────────────────────────────────────────────────
# Load deployment configuration
# ─────────────────────────────────────────────────────────
DEPLOY_CONF="${ENV_DIR}/deploy.conf"

if [[ ! -f "$DEPLOY_CONF" ]]; then
    echo "❌ Deployment config not found: ${DEPLOY_CONF}"
    echo "   Copy deploy.conf.example → deploy.conf and configure for this environment."
    exit 1
fi

# shellcheck source=/dev/null
source "$DEPLOY_CONF"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ItsMeh Production Deployment"
echo "  Ingress Mode: ${INGRESS_MODE:-not set}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ─────────────────────────────────────────────────────────
# Pre-flight: Ingress validation
# ─────────────────────────────────────────────────────────
case "${INGRESS_MODE}" in
    direct|cloudflare_proxy|cloudflare_tunnel|custom)
        ;;
    *)
        echo "❌ Unknown INGRESS_MODE: '${INGRESS_MODE}'"
        echo "   Valid options: direct, cloudflare_proxy, cloudflare_tunnel, custom"
        exit 1
        ;;
esac

if [[ "${INGRESS_MODE}" == "cloudflare_tunnel" && "${DEPLOY_CLOUDFLARED:-false}" != "true" ]]; then
    echo "❌ INGRESS_MODE=cloudflare_tunnel requires DEPLOY_CLOUDFLARED=true in deploy.conf"
    exit 1
fi

# ─────────────────────────────────────────────────────────
# Pre-flight: Docker daemon check
# ─────────────────────────────────────────────────────────
if ! docker info >/dev/null 2>&1; then
    echo "❌ Docker daemon is not running or accessible. Please start Docker."
    exit 1
fi

# ─────────────────────────────────────────────────────────
# Pre-flight: Required Docker network
# ─────────────────────────────────────────────────────────
echo "━━━ Checking Infrastructure Prerequisites ━━━"
bash "${INFRA_ROOT}/scripts/docker-network-setup.sh"

# ─────────────────────────────────────────────────────────
# Pre-flight: Environment files check
# ─────────────────────────────────────────────────────────
MISSING_ENVS=()

if [[ "${DEPLOY_NGINX:-false}" == "true" && ! -f "${ENV_DIR}/global.env" ]]; then
    MISSING_ENVS+=("environments/production/global.env (copy from global.env.example)")
fi

if [[ "${DEPLOY_POSTGRES:-false}" == "true" && ! -f "${ENV_DIR}/postgres.env" ]]; then
    MISSING_ENVS+=("environments/production/postgres.env (copy from postgres.env.example)")
fi

if [[ "${DEPLOY_PGADMIN:-false}" == "true" && ! -f "${ENV_DIR}/pgadmin.env" ]]; then
    MISSING_ENVS+=("environments/production/pgadmin.env (copy from pgadmin.env.example)")
fi

if [[ "${DEPLOY_CLOUDFLARED:-false}" == "true" && ! -f "${ENV_DIR}/cloudflared.env" ]]; then
    MISSING_ENVS+=("environments/production/cloudflared.env (copy from cloudflared.env.example)")
fi

if [[ ${#MISSING_ENVS[@]} -gt 0 ]]; then
    echo "❌ Missing required environment file(s):"
    for env in "${MISSING_ENVS[@]}"; do
        echo "   - $env"
    done
    exit 1
fi

# ─────────────────────────────────────────────────────────
# Helper: Ensure directories exist & are writable
# Optimized O(1): Sets 0777 on directory inodes only without
# expensive recursive traversal (-R) over accumulated files.
# ─────────────────────────────────────────────────────────
ensure_writable_dirs() {
    for dir in "$@"; do
        [[ ! -d "$dir" ]] && mkdir -p "$dir"
        chmod 0777 "$dir"
    done
}

# ─────────────────────────────────────────────────────────
# Pre-flight: Ensure log directories exist & are writable
# ─────────────────────────────────────────────────────────
ensure_writable_dirs \
    "${INFRA_ROOT}/logs" \
    "${INFRA_ROOT}/logs/nginx" \
    "${INFRA_ROOT}/logs/postgres"

# ─────────────────────────────────────────────────────────
# Pre-flight: Auto-fix script & configuration permissions
# Enforces executable permissions on all entrypoint wrappers,
# maintenance scripts, and hooks, plus read permissions on
# configs mounted into containers (no manual chmod needed).
# ─────────────────────────────────────────────────────────
find "${INFRA_ROOT}" -name ".git" -prune -o -type f \( -name "*.sh" -o -name "*entrypoint*" \) -exec chmod 0755 {} +
find "${INFRA_ROOT}/platform" -name ".git" -prune -o -type f \( -name "*.conf" -o -name "*.json" \) -exec chmod 0644 {} +

# ─────────────────────────────────────────────────────────
# Pre-flight: Prevent Nginx .htpasswd directory mount trap
# ─────────────────────────────────────────────────────────
HTPASSWD_FILE="${INFRA_ROOT}/platform/reverse-proxy/nginx/.htpasswd"
if [[ "${DEPLOY_NGINX:-false}" == "true" ]]; then
    if [[ -d "$HTPASSWD_FILE" ]]; then
        echo "⚠️  Found directory at $HTPASSWD_FILE. Removing directory trap..."
        rm -rf "$HTPASSWD_FILE"
    fi
    if [[ ! -f "$HTPASSWD_FILE" ]]; then
        echo "⚠️  .htpasswd file not found. Creating placeholder file to prevent Docker volume directory trap."
        touch "$HTPASSWD_FILE"
        echo "   To set real Basic Auth credentials for Darbar, run:"
        echo "   htpasswd -c platform/reverse-proxy/nginx/.htpasswd ops_admin"
    fi
fi

echo "✅ Prerequisites validated."
echo ""

# ─────────────────────────────────────────────────────────
# Deploy: Cloudflare Tunnel (if enabled)
# ─────────────────────────────────────────────────────────
if [[ "${DEPLOY_CLOUDFLARED:-false}" == "true" ]]; then
    echo "━━━ Cloudflare Tunnel ━━━"

    cd "${INFRA_ROOT}/platform/cloudflared"

    echo "Deploying cloudflared..."
    docker compose up -d

    echo "Waiting for cloudflared to become healthy..."
    sleep 5
    if docker exec cloudflared cloudflared tunnel ready >/dev/null 2>&1; then
        echo "✅ Cloudflare Tunnel is connected."
    else
        echo "⚠️  Cloudflare Tunnel may still be connecting. Check: docker logs cloudflared"
    fi
    echo ""
else
    echo "⏭️  Skipping cloudflared (DEPLOY_CLOUDFLARED != true)"
    echo ""
fi

# ─────────────────────────────────────────────────────────
# Deploy: PostgreSQL (if enabled)
# ─────────────────────────────────────────────────────────
if [[ "${DEPLOY_POSTGRES:-false}" == "true" ]]; then
    echo "━━━ PostgreSQL Platform ━━━"

    cd "${INFRA_ROOT}/platform/postgres"

    # Ensure backup directories exist and are writable by postgres container (UID 999) for WAL archiving
    ensure_writable_dirs \
        "${INFRA_ROOT}/platform/postgres/backups" \
        "${INFRA_ROOT}/platform/postgres/backups/base" \
        "${INFRA_ROOT}/platform/postgres/backups/wal" \
        "${INFRA_ROOT}/platform/postgres/backups/logical"

    # shellcheck source=/dev/null
    source "${ENV_DIR}/postgres.env"

    echo "Deploying PostgreSQL..."
    docker compose up -d

    echo "Waiting for PostgreSQL to become healthy..."
    sleep 5
    docker exec postgres pg_isready -U "${POSTGRES_USER:-itsmeh_admin}"

    echo "✅ PostgreSQL is ready."
    echo ""
else
    echo "⏭️  Skipping PostgreSQL (DEPLOY_POSTGRES != true)"
    echo ""
fi

# ─────────────────────────────────────────────────────────
# Deploy: pgAdmin (if enabled)
# ─────────────────────────────────────────────────────────
if [[ "${DEPLOY_PGADMIN:-false}" == "true" ]]; then
    echo "━━━ pgAdmin Database Manager ━━━"

    cd "${INFRA_ROOT}/platform/pgadmin"

    # Ensure pgAdmin backup directory exists and is writable
    ensure_writable_dirs "${INFRA_ROOT}/platform/pgadmin/backups"

    echo "Deploying pgAdmin..."
    docker compose up -d

    echo "Waiting for pgAdmin to become healthy..."
    sleep 5

    echo "✅ pgAdmin is ready."
    echo ""
else
    echo "⏭️  Skipping pgAdmin (DEPLOY_PGADMIN != true)"
    echo ""
fi

# ─────────────────────────────────────────────────────────
# Deploy: Nginx Reverse Proxy (if enabled)
# ─────────────────────────────────────────────────────────
if [[ "${DEPLOY_NGINX:-false}" == "true" ]]; then
    echo "━━━ Nginx Reverse Proxy ━━━"

    cd "${INFRA_ROOT}/platform/reverse-proxy/nginx"

    echo "Validating nginx config..."
    docker compose run --rm nginx nginx -t

    echo "Deploying nginx..."
    docker compose up -d

    echo "✅ Nginx is ready."
    echo ""
else
    echo "⏭️  Skipping Nginx (DEPLOY_NGINX != true)"
    echo ""
fi

# ─────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅ Production deployment complete!"
echo ""
echo "  Ingress Mode: ${INGRESS_MODE}"
echo "  Services:"
[[ "${DEPLOY_CLOUDFLARED:-false}" == "true" ]] && echo "    ✅ cloudflared" || echo "    ⏭️  cloudflared (skipped)"
[[ "${DEPLOY_POSTGRES:-false}" == "true" ]]   && echo "    ✅ postgres"    || echo "    ⏭️  postgres (skipped)"
[[ "${DEPLOY_PGADMIN:-false}" == "true" ]]    && echo "    ✅ pgadmin"     || echo "    ⏭️  pgadmin (skipped)"
[[ "${DEPLOY_NGINX:-false}" == "true" ]]      && echo "    ✅ nginx"       || echo "    ⏭️  nginx (skipped)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
