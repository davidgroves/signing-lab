#!/usr/bin/env bash
# Reset BIND-KNOT-BIND stack.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

echo "Stopping containers and removing volumes..."
docker compose --env-file "$ROOT/.env" down -v --remove-orphans 2>/dev/null || true

if [[ -d artifacts ]]; then
	find artifacts -mindepth 1 ! -name '.gitkeep' -exec rm -rf {} + 2>/dev/null || true
fi
if [[ -d zones ]]; then
	find zones -type f ! -name '.gitkeep' ! -name '*.starter' -delete 2>/dev/null || true
fi
rm -rf storage/signer/* rundir/signer/* 2>/dev/null || true
mkdir -p storage/signer rundir/signer zones keys
chmod -R a+rwX storage rundir zones keys 2>/dev/null || true

echo "Done. Next: ./run-all.sh"
