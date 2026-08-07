#!/usr/bin/env bash
set -euo pipefail

echo "[research-infrastructure] validating docker runtime..."
docker version
docker compose version
echo "[research-infrastructure] docker runtime OK"

