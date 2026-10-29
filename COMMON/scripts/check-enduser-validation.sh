#!/usr/bin/env bash
# Probe end-user DNSSEC validation at the end of the zone (missing RRSIGs +
# broken NSEC/NSEC3 chain). Typically run after check-zone-signed finds
# PARTLY_SIGNED / UNSIGNED.
#
# Exit 0 = demonstrated end-user validation failure (with --expect-fail), or
#          end of zone looks valid (without --expect-fail).
# Exit 1 = opposite of the expected outcome / inconclusive.
# Exit 2 = tool error.
set -euo pipefail
_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
if [[ -f "$_SCRIPT_DIR/lib.sh" ]]; then
	source "$_SCRIPT_DIR/lib.sh"
elif [[ -n "${STACK_LIB:-}" && -f "$STACK_LIB" ]]; then
	source "$STACK_LIB"
elif [[ -n "${STACK_ROOT:-}" && -f "$STACK_ROOT/scripts/lib.sh" ]]; then
	source "$STACK_ROOT/scripts/lib.sh"
else
	# Allow AXFR-only runs without a stack lib (COMMON_ROOT inferred).
	COMMON_ROOT="$(cd "$_SCRIPT_DIR/.." && pwd)"
	ROOT="${STACK_ROOT:-$COMMON_ROOT}"
	# shellcheck disable=SC1091
	source "$COMMON_ROOT/scripts/lib-common.sh" 2>/dev/null || true
	log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
	die() { log "ERROR: $*"; exit 2; }
	dig_at() { local h="$1" p="$2"; shift 2; dig @"$h" -p "$p" "$@"; }
	ZONE_NAME="${ZONE_NAME:-nsec.test.example}"
	DISTRIBUTION_HOST="${DISTRIBUTION_HOST:-127.0.0.1}"
	DISTRIBUTION_PORT="${DISTRIBUTION_PORT:-53}"
	SIGNER_HOST="${SIGNER_HOST:-127.0.0.1}"
	SIGNER_PORT="${SIGNER_PORT:-53}"
fi

usage() {
	cat <<EOF
Usage: $0 [--role distribution|signer] [--host H] [--port P] [--axfr FILE]
          [--out DIR] [--expect-fail]

Probe highest a####### labels for missing RRSIG(A) and NSEC/NSEC3 chain gaps.
With --expect-fail (PARTLY_SIGNED path): exit 0 when end-user validation fails.
EOF
}

ROLE="distribution"
HOST=""
PORT=""
AXFR=""
OUT=""
EXPECT_FAIL=0

while [[ $# -gt 0 ]]; do
	case "$1" in
		--role) ROLE="$2"; shift 2 ;;
		--host) HOST="$2"; shift 2 ;;
		--port) PORT="$2"; shift 2 ;;
		--axfr) AXFR="$2"; shift 2 ;;
		--out) OUT="$2"; shift 2 ;;
		--expect-fail) EXPECT_FAIL=1; shift ;;
		-h|--help) usage; exit 0 ;;
		*) die "unknown arg: $1" ;;
	esac
done

case "$ROLE" in
	signer)
		HOST="${HOST:-$SIGNER_HOST}"
		PORT="${PORT:-$SIGNER_PORT}"
		;;
	distribution)
		HOST="${HOST:-$DISTRIBUTION_HOST}"
		PORT="${PORT:-$DISTRIBUTION_PORT}"
		;;
	*) die "role must be signer|distribution" ;;
esac

if [[ -z "$OUT" ]]; then
	OUT="$(artifact_dir "enduser-${ROLE}" 2>/dev/null || mktemp -d)"
fi
mkdir -p "$OUT"

PY="${COMMON_ROOT:-$_SCRIPT_DIR/..}/scripts/check-enduser-validation.py"
if [[ ! -f "$PY" ]]; then
	PY="$_SCRIPT_DIR/check-enduser-validation.py"
fi

ARGS=(--zone "$ZONE_NAME" --out "$OUT/ENDUSER_VALIDATION.md")
[[ -n "$AXFR" ]] && ARGS+=(--axfr "$AXFR")
# Live dig/delv only when explicitly useful: always with a live stack check
# (no AXFR), or when AXFR is present and the authority answers SOA.
LIVE=0
if [[ -z "$AXFR" && -n "$HOST" ]]; then
	LIVE=1
elif [[ -n "$AXFR" && -n "$HOST" ]]; then
	if dig_at "$HOST" "$PORT" "$ZONE_NAME" SOA +norecurse +short 2>/dev/null | grep -q .; then
		LIVE=1
	else
		log "Authority ${HOST}:${PORT} not answering SOA — AXFR-only end-user analysis"
	fi
fi
[[ "$LIVE" -eq 1 ]] && ARGS+=(--host "$HOST" --port "$PORT")
[[ "$EXPECT_FAIL" -eq 1 ]] && ARGS+=(--expect-fail)

log "End-user validation probe zone=${ZONE_NAME} role=${ROLE} live=${LIVE} @${HOST:-axfr-only}#${PORT:--} expect_fail=${EXPECT_FAIL}"
set +e
python3 "$PY" "${ARGS[@]}"
rc=$?
set -e

if [[ -f "$OUT/ENDUSER_VALIDATION.md" ]]; then
	log "End-user report: $OUT/ENDUSER_VALIDATION.md"
fi
exit "$rc"
