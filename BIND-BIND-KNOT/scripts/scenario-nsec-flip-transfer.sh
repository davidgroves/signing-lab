#!/usr/bin/env bash
# Flip zone dnssec-policy NSEC↔NSEC3, then immediately force-transfer to distribution.
# Expects ZONE_NAME in nsec/nsec3 modes. Default: one iter after the flip.
# Override: MAX_ITERS=N or POLL_DURATION=seconds.
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

FROM_MODE="$(zone_mode_of "$ZONE_NAME" || true)"
TO_MODE="$(flip_target_mode "${FROM_MODE:-}" || true)"
if [[ -z "$FROM_MODE" || -z "$TO_MODE" ]]; then
	die "scenario-nsec-flip-transfer requires ZONE_NAME in nsec|nsec3 (got ${ZONE_NAME})"
fi

VTAG="validate-${DNSSEC_VALIDATION:-off}"
OUT="$(artifact_dir "${ZONE_NAME%%.*}-${VTAG}-nsec-flip-transfer")"
HIT=0
WARMUP_TIMEOUT="${WARMUP_TIMEOUT:-600}"

cleanup() {
	restore_zone_policy || true
}
trap cleanup EXIT

log "=== scenario-nsec-flip-transfer (${VTAG}, ${FROM_MODE} -> ${TO_MODE}) ==="
scenario_iter_init
compose_fresh
"$ROOT/scripts/wait-ready.sh" 300

log "Waiting up to ${WARMUP_TIMEOUT}s for initial FULLY_SIGNED on distribution..."
warmup_deadline=$((SECONDS + WARMUP_TIMEOUT))
while (( SECONDS < warmup_deadline )); do
	"$ROOT/scripts/check-zone-signed.sh" --role distribution --out "$OUT/warmup" 2>/dev/null || true
	st="$(results_status "$OUT/warmup" 2>/dev/null || true)"
	if [[ "$st" == "FULLY_SIGNED" ]]; then
		log "Distribution fully signed before flip"
		break
	fi
	# validate-on: AXFR unavailable means Knot refused a broken zone — ready to flip.
	if [[ "${DNSSEC_VALIDATION:-off}" == "on" && "$st" == "AXFR_UNAVAILABLE" ]]; then
		log "Distribution AXFR unavailable under validate-on (not publishing broken); proceeding to flip"
		break
	fi
	if rndc signer signing -list "$ZONE_NAME" 2>/dev/null | grep -qi 'Done signing'; then
		"$ROOT/scripts/check-zone-signed.sh" --role distribution --out "$OUT/warmup" 2>/dev/null || true
		st="$(results_status "$OUT/warmup" 2>/dev/null || true)"
		[[ "$st" == "FULLY_SIGNED" || ( "${DNSSEC_VALIDATION:-off}" == "on" && "$st" == "AXFR_UNAVAILABLE" ) ]] && break
	fi
	sleep 5
done
st="$(results_status "$OUT/warmup" 2>/dev/null || true)"
if [[ "$st" != "FULLY_SIGNED" && "$st" != "AXFR_UNAVAILABLE" ]]; then
	log "WARN: distribution not ready before flip (status=${st:-none}); proceeding anyway"
fi

capture_status "$OUT/before"
grep -E 'Denial of existence|Status' "$OUT/warmup/RESULTS.md" 2>/dev/null \
	| tee "$OUT/before-doe.txt" || true

flip_zone_policy
echo "${FLIP_FROM_POLICY} -> ${FLIP_TO_POLICY}" >"$OUT/flip.txt"

log "Immediate rndc retransfer on distribution"
rndc distribution retransfer "$ZONE_NAME" || true

n=0
while true; do
	n=$((n + 1))
	scenario_iter_should_run "$n" || break
	iter="$OUT/iter-$(printf '%04d' "$n")"
	if (( n > 1 )); then
		rndc distribution retransfer "$ZONE_NAME" || true
		sleep 1
	fi
	export REPRO_STORY="BIND-BIND-KNOT scenario-nsec-flip-transfer (${VTAG}, iteration ${n}): flipped ${FLIP_FROM_POLICY} -> ${FLIP_TO_POLICY}; Knot dnssec-validation=${DNSSEC_VALIDATION:-off}."
	if ! "$ROOT/scripts/check-zone-signed.sh" --role distribution --out "$iter" --expect-signing; then
		if results_is_fail "$iter"; then
			log "FAIL on iteration $n"
			HIT=1
			cp -a "$iter/." "$OUT/"
			break
		fi
	fi
	"$ROOT/scripts/check-zone-signed.sh" --role signer --out "$iter-signer" || true
	scenario_iter_sleep "$n"
done

capture_status "$OUT"
if (( HIT )); then
	OUT="$(finalize_artifact_dir "$OUT" FAIL)"
	log "REPRODUCED — artifacts $OUT"
	exit 1
fi
OUT="$(finalize_artifact_dir "$OUT" PASS)"
log "No fail in scenario-nsec-flip-transfer — artifacts $OUT"
exit 0
