#!/usr/bin/env bash
# During resign, rndc retransfer on distribution and check coverage.
# Default: one iter. Override: MAX_ITERS=N or POLL_DURATION=seconds.
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

VTAG="validate-${DNSSEC_VALIDATION:-off}"
OUT="$(artifact_dir "${ZONE_NAME%%.*}-${VTAG}-force-transfer")"
HIT=0

log "=== scenario-force-transfer-during-sign (${VTAG}) ==="
scenario_iter_init
compose_fresh
"$ROOT/scripts/wait-ready.sh" 300

log "Trigger resign on signer"
rndc signer sign "$ZONE_NAME" || true

n=0
while true; do
	n=$((n + 1))
	scenario_iter_should_run "$n" || break
	iter="$OUT/iter-$(printf '%04d' "$n")"
	rndc distribution retransfer "$ZONE_NAME" || true
	sleep 1
	export REPRO_STORY="BIND-BIND-KNOT scenario-force-transfer (${VTAG}, iteration ${n}): rndc sign + Knot zone-retransfer; dnssec-validation=${DNSSEC_VALIDATION:-off}."
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
log "No fail in scenario-force-transfer-during-sign — artifacts $OUT"
exit 0
