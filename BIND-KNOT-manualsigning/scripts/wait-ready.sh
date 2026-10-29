#!/usr/bin/env bash
# Wait until primary answers SOA and (optionally) distribution does too.
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

TIMEOUT="${1:-300}"
NEED_DISTRIBUTION="${NEED_DISTRIBUTION:-1}"

deadline=$((SECONDS + TIMEOUT))
log "Waiting up to ${TIMEOUT}s for ${ZONE_NAME} (need_distribution=${NEED_DISTRIBUTION})"

while (( SECONDS < deadline )); do
	p=0 d=0
	zone_loaded "$PRIMARY_HOST" "$PRIMARY_PORT" && p=1
	zone_loaded "$DISTRIBUTION_HOST" "$DISTRIBUTION_PORT" && d=1
	if (( NEED_DISTRIBUTION )); then
		if (( p && d )); then
			log "Ready — serials primary=$(soa_serial "$PRIMARY_HOST" "$PRIMARY_PORT") distribution=$(soa_serial "$DISTRIBUTION_HOST" "$DISTRIBUTION_PORT")"
			exit 0
		fi
		log "waiting primary=$p distribution=$d"
	else
		if (( p )); then
			log "Ready primary serial=$(soa_serial "$PRIMARY_HOST" "$PRIMARY_PORT") distribution=$d"
			exit 0
		fi
		log "waiting primary=$p"
	fi
	sleep 2
done

die "timed out waiting for zone readiness"
