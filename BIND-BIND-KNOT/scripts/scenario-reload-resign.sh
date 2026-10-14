#!/usr/bin/env bash
# After zone is loaded, force resign and check AXFR from distribution.
# Default: one iter. Override: MAX_ITERS=N or POLL_DURATION=seconds.
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

VTAG="validate-${DNSSEC_VALIDATION:-off}"
OUT="$(artifact_dir "${ZONE_NAME%%.*}-${VTAG}-reload-resign")"
HIT=0

log "=== scenario-reload-resign (${VTAG}) ==="
scenario_iter_init
compose_fresh
"$ROOT/scripts/wait-ready.sh" 300

log "Waiting for initial signing progress..."
for _ in $(seq 1 60); do
	if rndc signer signing -list "$ZONE_NAME" 2>/dev/null | grep -qi 'Done signing'; then
		break
	fi
	sleep 5
done

capture_status "$OUT/before"
log "Triggering rndc sign / loadkeys"
rndc signer sign "$ZONE_NAME" || true
rndc signer loadkeys "$ZONE_NAME" || true

n=0
while true; do
	n=$((n + 1))
	scenario_iter_should_run "$n" || break
	iter="$OUT/iter-$(printf '%04d' "$n")"
	dig_at "$SIGNER_HOST" "$SIGNER_PORT" "$ZONE_NAME" AXFR +tcp +time=60 +tries=1 \
		>"$iter-signer-axfr.txt" 2>/dev/null &
	pid=$!
	export REPRO_STORY="BIND-BIND-KNOT scenario-reload-resign (${VTAG}, iteration ${n}): rndc sign/loadkeys on BIND signer; Knot distribution dnssec-validation=${DNSSEC_VALIDATION:-off}."
	if ! "$ROOT/scripts/check-zone-signed.sh" --role distribution --out "$iter" --expect-signing; then
		if results_is_fail "$iter"; then
			log "FAIL on iteration $n"
			HIT=1
			cp -a "$iter/." "$OUT/"
			wait "$pid" || true
			break
		fi
	fi
	wait "$pid" || true
	scenario_iter_sleep "$n"
done

capture_status "$OUT"
if (( HIT )); then
	OUT="$(finalize_artifact_dir "$OUT" FAIL)"
	log "REPRODUCED — artifacts $OUT"
	exit 1
fi
OUT="$(finalize_artifact_dir "$OUT" PASS)"
log "No fail in scenario-reload-resign — artifacts $OUT"
exit 0
