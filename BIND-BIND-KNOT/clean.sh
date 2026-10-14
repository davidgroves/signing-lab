#!/usr/bin/env bash
# Reset BIND-BIND-KNOT stack.
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
if [[ -d keys ]]; then
	chmod -R u+w keys 2>/dev/null || true
	find keys -type f ! -name '.gitkeep' -delete 2>/dev/null || true
	if compgen -G 'keys/K*' > /dev/null || compgen -G 'keys/*.key' > /dev/null; then
		docker run --rm -v "$ROOT/keys:/keys" alpine:3.20 \
			sh -c 'find /keys -type f ! -name .gitkeep -delete' 2>/dev/null || true
	fi
fi
rm -rf storage/distribution/* rundir/distribution/* 2>/dev/null || true
mkdir -p storage/distribution rundir/distribution zones keys
chmod -R a+rwX storage rundir zones keys 2>/dev/null || true
cp "$ROOT/config/distribution/knot.validate-off.conf" \
	"$ROOT/config/distribution/knot.conf"

echo "Done. Next: ./run-all.sh"
