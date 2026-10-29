#!/usr/bin/env bash
# Reset BIND-KNOT-manualsigning stack.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

echo "Stopping containers and removing volumes..."
docker compose --env-file "$ROOT/.env" down -v --remove-orphans 2>/dev/null || true

if [[ -d artifacts ]]; then
	find artifacts -mindepth 1 ! -name '.gitkeep' -exec rm -rf {} + 2>/dev/null || true
fi
if [[ -d zones ]]; then
	docker run --rm -v "$ROOT/zones:/zones:rw" --user 0 alpine:3.20 \
		sh -c 'find /zones -type f ! -name .gitkeep -delete' 2>/dev/null || true
fi
if [[ -d keys ]]; then
	docker run --rm -v "$ROOT/keys:/keys:rw" --user 0 alpine:3.20 \
		sh -c 'find /keys -type f ! -name .gitkeep -delete' 2>/dev/null || true
fi
rm -rf storage/distribution/* rundir/distribution/* 2>/dev/null || true
mkdir -p storage/distribution rundir/distribution zones keys artifacts
chmod -R a+rwX storage rundir zones keys artifacts 2>/dev/null || true

echo "Done. Next: ./scripts/scenario-zsk-withdraw-ixfr.sh"
