#!/usr/bin/env bash
# Generate zones, start Knot stack, run every scenario for each DNSSEC mode.
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

ZONESIZE="${ZONESIZE:-10}"
if ! [[ "$ZONESIZE" =~ ^[1-9][0-9]*$ ]]; then
	die "ZONESIZE must be a positive integer (megabytes), got: ${ZONESIZE}"
fi

read -r -a RUN_MODES <<<"${MODES:-nsec nsec3 nsec3optout}"
for mode in "${RUN_MODES[@]}"; do
	[[ -n "${MODE_ZONE[$mode]:-}" ]] || die "unknown mode in MODES: $mode"
done

if (( ZONESIZE >= 500 )); then
	READY_TIMEOUT="${READY_TIMEOUT:-3600}"
else
	READY_TIMEOUT="${READY_TIMEOUT:-300}"
fi
# Scenario poll budget defaults to MAX_ITERS=1 (see COMMON lib-common.sh).
# Optional race hunting: MAX_ITERS=N or POLL_DURATION=seconds.
export MAX_ITERS="${MAX_ITERS:-1}"
[[ -n "${POLL_DURATION:-}" ]] && export POLL_DURATION
[[ -n "${INTERVAL:-}" ]] && export INTERVAL

OUT="$(artifact_dir "run-all-${ZONESIZE}m")"
SUMMARY="$OUT/summary.txt"
: >"$SUMMARY"

TOTAL_TESTS="$(count_battery_scenarios 1 "${RUN_MODES[@]}")"
init_test_progress "$TOTAL_TESTS"

run_scenario() {
	local name="$1"
	shift
	announce_running_test "$name"
	set +e
	"$@"
	local rc=$?
	set -e
	echo "$name rc=$rc" | tee -a "$SUMMARY"
	return 0
}

log "=== Knot run-all ZONESIZE=${ZONESIZE} MiB MODES=${RUN_MODES[*]} KNOT_TAG=${KNOT_TAG} tests=${TOTAL_TESTS} ==="
prepare_runtime_dirs
generate_all_zones "$ZONESIZE" 1

# Each scenario calls compose_fresh so modes do not share a warm signer.

for mode in "${RUN_MODES[@]}"; do
	set_zone_mode "$mode"
	log "======== DNSSEC mode=${mode} zone=${ZONE_NAME} ========"
	run_scenario "${mode}/initial-sign" \
		env ZONE_NAME="$ZONE_NAME" ZONE_FILE="$ZONE_FILE" \
		"$ROOT/scripts/scenario-initial-sign.sh"
	run_scenario "${mode}/reload-resign" \
		env ZONE_NAME="$ZONE_NAME" ZONE_FILE="$ZONE_FILE" \
		"$ROOT/scripts/scenario-reload-resign.sh"
	run_scenario "${mode}/serial-bump" \
		env ZONE_NAME="$ZONE_NAME" ZONE_FILE="$ZONE_FILE" \
		REGENERATE=0 SIZE_MB="$ZONESIZE" \
		"$ROOT/scripts/scenario-serial-bump-during-sign.sh"
	run_scenario "${mode}/force-transfer" \
		env ZONE_NAME="$ZONE_NAME" ZONE_FILE="$ZONE_FILE" \
		"$ROOT/scripts/scenario-force-transfer-during-sign.sh"
	if [[ "$mode" == "nsec" || "$mode" == "nsec3" ]]; then
		run_scenario "${mode}/nsec-flip-transfer" \
			env ZONE_NAME="$ZONE_NAME" ZONE_FILE="$ZONE_FILE" \
			"$ROOT/scripts/scenario-nsec-flip-transfer.sh"
	fi
done

log "Summary written to $SUMMARY"
cat "$SUMMARY"
if grep -q ' rc=1$' "$SUMMARY"; then
	OUT="$(finalize_artifact_dir "$OUT" FAIL)"
	log "One or more scenarios reported FAIL (rc=1) — $OUT"
	exit 1
fi
OUT="$(finalize_artifact_dir "$OUT" PASS)"
log "All scenarios PASS — $OUT"
exit 0
