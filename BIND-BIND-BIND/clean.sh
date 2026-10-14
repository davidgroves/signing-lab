#!/usr/bin/env bash
# Reset the repo to a just-checked-out state (no generated data, no containers).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

echo "Stopping containers and removing volumes..."
docker compose --env-file "$ROOT/.env" down -v --remove-orphans 2>/dev/null || true

echo "Removing generated artifacts, zones, keys, and local data..."
# artifacts/ (keep .gitkeep)
if [[ -d artifacts ]]; then
	find artifacts -mindepth 1 ! -name '.gitkeep' -exec rm -rf {} + 2>/dev/null || true
fi

# Generated zone files (keep *.starter + .gitkeep)
if [[ -d zones ]]; then
	find zones -type f ! -name '.gitkeep' ! -name '*.starter' -delete 2>/dev/null || true
fi

# DNSSEC keys created by the signer (often owned by container uid 53; keep .gitkeep)
if [[ -d keys ]]; then
	chmod -R u+w keys 2>/dev/null || true
	find keys -type f ! -name '.gitkeep' -delete 2>/dev/null || true
	# If host user cannot unlink bind-owned files, remove via a root container.
	if compgen -G 'keys/K*' > /dev/null || compgen -G 'keys/*.key' > /dev/null; then
		docker run --rm -v "$ROOT/keys:/keys" alpine:3.20 \
			sh -c 'find /keys -type f ! -name .gitkeep -delete' 2>/dev/null || true
	fi
fi

rm -rf data
rm -f .env.local
rm -f /tmp/repro-*.axfr /tmp/repro-*.err 2>/dev/null || true

echo "Done. BIND stack reset (starters in ../COMMON/zones)."
echo "Next: ./run-all.sh"
