#!/usr/bin/env bash
# BIND-KNOT-manualsigning: BIND primary (hand-signed) → Knot distribution.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMMON_ROOT="$(cd "$ROOT/../COMMON" && pwd)"
cd "$ROOT"

# shellcheck disable=SC1091
source "$COMMON_ROOT/scripts/lib-common.sh"

_PRESERVE_BIND_TAG="${BIND_TAG-}"
_PRESERVE_KNOT_TAG="${KNOT_TAG-}"
[[ -n "${_PRESERVE_BIND_TAG}" ]] && BIND_TAG="${_PRESERVE_BIND_TAG}"
[[ -n "${_PRESERVE_KNOT_TAG}" ]] && KNOT_TAG="${_PRESERVE_KNOT_TAG}"
unset _PRESERVE_BIND_TAG _PRESERVE_KNOT_TAG
BIND_TAG="${BIND_TAG:-9.20}"
KNOT_TAG="${KNOT_TAG:-latest}"

STACK_NAME=bkms
CONTAINER_PREFIX=bkms
DNSSEC_VALIDATION=on
export ALLOW_AXFR_UNAVAILABLE=1

# Two-node stack: shared helpers that expect a "signer" talk to primary.
SIGNER_HOST="${SIGNER_HOST:-$PRIMARY_HOST}"
SIGNER_PORT="${SIGNER_PORT:-$PRIMARY_PORT}"

ZONE_NAME="${ZONE_NAME:-manual.test.example}"
ZONE_FILE="${ZONE_FILE:-db.manual.test.example.signed}"
export ZONE_NAME ZONE_FILE

prepare_runtime_dirs() {
	mkdir -p "$ROOT/zones" "$ROOT/keys" \
		"$ROOT/storage/distribution" "$ROOT/rundir/distribution"
	chmod -R a+rwX "$ROOT/storage" "$ROOT/rundir" "$ROOT/zones" "$ROOT/keys" 2>/dev/null || true
}

compose_up() {
	prepare_runtime_dirs
	[[ -f "$ROOT/zones/$ZONE_FILE" ]] || die "missing signed zone $ROOT/zones/$ZONE_FILE (run build-signed-zone.sh)"
	"${COMPOSE[@]}" up -d
}

compose_fresh() {
	log "Fresh stack (compose down -v + up)"
	"${COMPOSE[@]}" down -v 2>/dev/null || true
	rm -rf "$ROOT/storage/distribution/"* "$ROOT/rundir/distribution/"* 2>/dev/null || true
	compose_up
}

knotc() {
	local role="$1"
	shift
	docker exec "${CONTAINER_PREFIX}-${role}" knotc "$@"
}

rndc() {
	local role="$1"
	shift
	case "$role" in
		distribution)
			case "${1:-}" in
				retransfer)
					knotc distribution zone-retransfer "${2:-$ZONE_NAME}"
					;;
				reload|reconfig)
					knotc distribution zone-reload "${2:-$ZONE_NAME}" 2>/dev/null || true
					;;
				*)
					knotc distribution "$@"
					;;
			esac
			;;
		*)
			docker exec "${CONTAINER_PREFIX}-${role}" rndc -c /etc/bind/rndc.conf "$@"
			;;
	esac
}

stack_ctl() {
	local role="$1"
	shift
	case "$role" in
		distribution) knotc distribution "$@" ;;
		*) rndc "$role" "$@" ;;
	esac
}

capture_status() {
	local dir="$1"
	mkdir -p "$dir"
	{
		echo "=== primary zonestatus ==="
		rndc primary zonestatus "$ZONE_NAME" || true
		echo
		echo "=== distribution zone-status ==="
		knotc distribution zone-status "$ZONE_NAME" || true
		echo
		echo "=== serials ==="
		echo -n "primary: "; soa_serial "$PRIMARY_HOST" "$PRIMARY_PORT" || echo "?"
		echo -n "distribution: "; soa_serial "$DISTRIBUTION_HOST" "$DISTRIBUTION_PORT" || echo "?"
	} >"$dir/status.txt" 2>&1 || true
	docker logs "${CONTAINER_PREFIX}-primary" >"$dir/primary.log" 2>&1 || true
	docker logs "${CONTAINER_PREFIX}-distribution" >"$dir/distribution.log" 2>&1 || true
}

# Override compose helpers that install all mid-sign starter zones.
ensure_all_starter_zones() { :; }
generate_all_zones() { die "this stack uses build-signed-zone.sh, not generate_all_zones"; }
