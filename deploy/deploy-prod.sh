#!/bin/bash
set -e

cd ../platform/reverse-proxy/nginx

echo "Validating nginx config..."
docker compose run --rm nginx nginx -t

echo "Deploying nginx..."
docker compose up -d

echo "Done."