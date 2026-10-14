#!/usr/bin/env bash
# Reset the Knot stack to a just-checked-out state.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

echo "Stopping Knot containers and removing volumes..."
docker compose --env-file "$ROOT/.env" down -v --remove-orphans 2>/dev/null || true

echo "Removing generated artifacts, zones, storage, rundir..."
if [[ -d artifacts ]]; then
	find artifacts -mindepth 1 ! -name '.gitkeep' -exec rm -rf {} + 2>/dev/null || true
fi
if [[ -d zones ]]; then
	find zones -type f ! -name '.gitkeep' ! -name '*.starter' -delete 2>/dev/null || true
fi
rm -rf storage/primary/* storage/signer/* storage/distribution/* 2>/dev/null || true
rm -rf rundir/primary/* rundir/signer/* rundir/distribution/* 2>/dev/null || true
# Recreate empties
mkdir -p storage/primary storage/signer storage/distribution \
	rundir/primary rundir/signer rundir/distribution zones
chmod -R a+rwX storage rundir zones 2>/dev/null || true

echo "Done. Next: ./run-all.sh"
