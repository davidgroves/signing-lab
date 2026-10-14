#!/usr/bin/env bash
# Cold start: compose_fresh (empty volumes) and check AXFR during first sign.
# Default: one iter. Override: MAX_ITERS=N or POLL_DURATION=seconds.
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

VTAG="validate-${DNSSEC_VALIDATION:-off}"
OUT="$(artifact_dir "${ZONE_NAME%%.*}-${VTAG}-initial-sign")"
HIT=0

log "=== scenario-initial-sign (${VTAG}) ==="
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
	export REPRO_STORY="BIND-BIND-KNOT scenario-initial-sign (${VTAG}, iteration ${n}): BIND inline-signing signer, Knot distribution dnssec-validation=${DNSSEC_VALIDATION:-off}; retransfer while signer may still be signing."
	if ! "$ROOT/scripts/check-zone-signed.sh" --role distribution --out "$iter"; then
		if results_is_fail "$iter"; then
			if rndc signer signing -list "$ZONE_NAME" 2>/dev/null | tee "$iter/signing-list.txt" | grep -Eiq 'signing|Done|key'; then
				log "FAIL on iteration $n"
				HIT=1
				cp -a "$iter/." "$OUT/"
				break
			fi
			if dig_at "$SIGNER_HOST" "$SIGNER_PORT" "$ZONE_NAME" DNSKEY +short | grep -q .; then
				if [[ "$(results_status "$iter")" == "UNSIGNED" ]]; then
					log "FAIL on iteration $n (signer has DNSKEY, distribution AXFR unsigned)"
					HIT=1
					cp -a "$iter/." "$OUT/"
					break
				fi
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
