#!/usr/bin/env bash
# Cold start: compose_fresh (empty volumes) and check AXFR during first sign.
# Default: one iter. Override: MAX_ITERS=N or POLL_DURATION=seconds.
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

OUT="$(artifact_dir "${ZONE_NAME%%.*}-initial-sign")"
HIT=0

log "=== scenario-initial-sign ==="
scenario_iter_init
compose_fresh
"$ROOT/scripts/wait-ready.sh" 180 || true

rndc distribution retransfer "$ZONE_NAME" || true

n=0
while true; do
	n=$((n + 1))
	scenario_iter_should_run "$n" || break
	iter="$OUT/iter-$(printf '%04d' "$n")"
	mkdir -p "$iter"
	export REPRO_STORY="BIND-KNOT-BIND scenario-initial-sign (iteration ${n}): retransfer on BIND distribution while Knot signer may still process on-secondary signing; expect no UNSIGNED/PARTLY_SIGNED (Knot never publishes half-signed)."
	if ! "$ROOT/scripts/check-zone-signed.sh" --role distribution --out "$iter"; then
		if results_is_fail "$iter"; then
			if dig_at "$SIGNER_HOST" "$SIGNER_PORT" "$ZONE_NAME" DNSKEY +short | grep -q .; then
				log "FAIL on iteration $n (signer has DNSKEY, distribution not fully signed)"
				HIT=1
				cp -a "$iter/." "$OUT/"
				break
			fi
		fi
	fi
	scenario_iter_sleep "$n"
done

capture_status "$OUT"
if (( HIT )); then
	OUT="$(finalize_artifact_dir "$OUT" FAIL)"
	log "REPRODUCED — artifacts $OUT"
	exit 1
fi
OUT="$(finalize_artifact_dir "$OUT" PASS)"
log "No fail in scenario-initial-sign — artifacts $OUT"
exit 0
