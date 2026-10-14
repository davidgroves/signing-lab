#!/usr/bin/env bash
# Wait until primary, signer, and distribution answer SOA for the active zone(s).
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

TIMEOUT="${1:-300}"
ZONES=()
if [[ -n "${WAIT_ALL_ZONES:-}" || "${1:-}" == "--all" ]]; then
	shift || true
	TIMEOUT="${1:-300}"
	for mode in "${ALL_MODES[@]}"; do
		ZONES+=("${MODE_ZONE[$mode]}")
	done
else
	ZONES=("$ZONE_NAME")
fi

deadline=$((SECONDS + TIMEOUT))
log "Waiting up to ${TIMEOUT}s for zone(s): ${ZONES[*]}"

while (( SECONDS < deadline )); do
	ok=1
	for z in "${ZONES[@]}"; do
		ZONE_NAME="$z"
		p=0 s=0 d=0
		zone_loaded "$PRIMARY_HOST" "$PRIMARY_PORT" && p=1
		zone_loaded "$SIGNER_HOST" "$SIGNER_PORT" && s=1
		zone_loaded "$DISTRIBUTION_HOST" "$DISTRIBUTION_PORT" && d=1
		if (( !(p && s && d) )); then
			ok=0
			log "waiting $z primary=$p signer=$s distribution=$d"
			break
		fi
	done
	if (( ok )); then
		for z in "${ZONES[@]}"; do
			ZONE_NAME="$z"
			log "Ready $z — serials primary=$(soa_serial "$PRIMARY_HOST" "$PRIMARY_PORT") signer=$(soa_serial "$SIGNER_HOST" "$SIGNER_PORT") distribution=$(soa_serial "$DISTRIBUTION_HOST" "$DISTRIBUTION_PORT")"
		done
		exit 0
	fi
	sleep 2
done

die "timed out waiting for zone readiness"
