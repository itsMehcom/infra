#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ─────────────────────────────────────────────────────────
# 1. Deploy PostgreSQL Platform
# ─────────────────────────────────────────────────────────
echo "━━━ PostgreSQL Platform ━━━"

cd "${INFRA_ROOT}/platform/postgres"

echo "Deploying PostgreSQL..."
docker compose up -d

echo "Waiting for PostgreSQL to become healthy..."
sleep 5
docker exec postgres pg_isready -U "${POSTGRES_USER:-itsmeh_admin}"

echo "✅ PostgreSQL is ready."
echo ""

# ─────────────────────────────────────────────────────────
# 2. Deploy Reverse Proxy (Nginx)
# ─────────────────────────────────────────────────────────
echo "━━━ Nginx Reverse Proxy ━━━"

cd "${INFRA_ROOT}/platform/reverse-proxy/nginx"

echo "Validating nginx config..."
docker compose run --rm nginx nginx -t

echo "Deploying nginx..."
docker compose up -d

echo "✅ Nginx is ready."
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅ Production deployment complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"