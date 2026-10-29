#!/usr/bin/env bash
# After a FULLY_SIGNED stable zone, apply a VERY LARGE primary change and watch
# whether the BITW signer ships PARTLY_SIGNED zones to distribution.
#
# Methods (METHOD=...):
#   ddns-giant   — one nsupdate process with large TCP update chunks
#   ddns-burst   — one nsupdate process with many tiny rapid sends
#   reload-file  — rewrite zone file on disk + rndc reload <zone>
#
# Tunables:
#   LARGE_CHANGE_COUNT  how many a####### owners to rewrite (default 5000;
#                       0 = all for reload-file / ddns)
#   WARMUP_TIMEOUT      wait for FULLY_SIGNED (default 600)
#   MAX_ITERS / POLL_DURATION / INTERVAL — post-change poll budget
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

METHOD="${METHOD:?METHOD required: ddns-giant|ddns-burst|reload-file}"
case "$METHOD" in
	ddns-giant|ddns-burst|reload-file) ;;
	*) die "unknown METHOD=$METHOD (want ddns-giant|ddns-burst|reload-file)" ;;
esac

LARGE_CHANGE_COUNT="${LARGE_CHANGE_COUNT:-5000}"
WARMUP_TIMEOUT="${WARMUP_TIMEOUT:-600}"
OUT="$(artifact_dir "${ZONE_NAME%%.*}-large-change-${METHOD}")"
HIT=0

finish_hit() {
	OUT="$(finalize_artifact_dir "$OUT" FAIL)"
	log "REPRODUCED — large change shipped broken zone — $OUT"
	exit 1
}

finish_pass() {
	OUT="$(finalize_artifact_dir "$OUT" PASS)"
	log "No fail after large primary change (${METHOD}) — $OUT"
	exit 0
}

log "=== scenario-large-primary-change METHOD=${METHOD} count=${LARGE_CHANGE_COUNT} ==="
scenario_iter_init
compose_fresh
"$ROOT/scripts/wait-ready.sh" 300

wait_distribution_fully_signed "$WARMUP_TIMEOUT" || true
mkdir -p "$OUT/before-stable"
if distribution_is_fully_signed; then
	baseline_status="FULLY_SIGNED"
	# Full evidence capture once stable.
	"$ROOT/scripts/check-zone-signed.sh" --role distribution --out "$OUT/before-stable" || true
else
	baseline_status="NOT_FULLY_SIGNED"
	log "WARN: baseline not FULLY_SIGNED — continuing anyway"
fi
capture_status "$OUT/before"
{
	echo "baseline_status=${baseline_status}"
	echo "method=${METHOD}"
	echo "large_change_count=${LARGE_CHANGE_COUNT}"
} | tee "$OUT/baseline.txt"

ZONE_PATH="$ZONES_DIR/$ZONE_FILE"
[[ -f "$ZONE_PATH" ]] || die "missing $ZONE_PATH"

old_serial="$(awk '/SOA/,/)/ { for (i=1;i<=NF;i++) if ($i ~ /^[0-9]+$/) { print $i; exit } }' "$ZONE_PATH")"
old_serial="${old_serial:-1}"
new_serial=$((old_serial + 1000))

prepare_ddns() {
	local mode="$1" # giant|burst
	local script="$OUT/nsupdate-${mode}.txt"
	local chunk_args=()
	if [[ "$mode" == "burst" ]]; then
		chunk_args=(--burst-size "${DDNS_BURST_SIZE:-10}")
	else
		chunk_args=(--giant-chunk "${DDNS_GIANT_CHUNK:-150}")
	fi
	python3 "$COMMON_ROOT/scripts/make-large-ddns.py" \
		--zone-file "$ZONE_PATH" \
		--zone "$ZONE_NAME" \
		--server "$PRIMARY_HOST" \
		--port "$PRIMARY_PORT" \
		--count "$LARGE_CHANGE_COUNT" \
		--mode "$mode" \
		"${chunk_args[@]}" \
		-o "$script"
	echo "$script"
}

ensure_zone_writable() {
	# named may rewrite/chown the zone after DDNS (root-owned on the bind mount).
	if [[ -w "$ZONE_PATH" ]]; then
		return 0
	fi
	log "Zone file not writable by host — fixing mode via docker"
	docker run --rm -v "$ZONES_DIR:/z:rw" --user 0 \
		busybox:1.36 chmod a+rw "/z/$(basename "$ZONE_PATH")" 2>/dev/null \
		|| docker run --rm -v "$ZONES_DIR:/z:rw" --user 0 \
			alpine:3.20 chmod a+rw "/z/$(basename "$ZONE_PATH")"
	[[ -w "$ZONE_PATH" ]] || die "cannot make $ZONE_PATH writable"
}

apply_reload_file() {
	# allow-update makes the zone "dynamic"; freeze → edit → thaw (not plain reload).
	log "Freezing primary, mutating zone file (serial ${old_serial} -> ${new_serial}), thawing"
	rndc primary freeze "$ZONE_NAME"
	ensure_zone_writable
	python3 "$COMMON_ROOT/scripts/mutate-zone-large.py" \
		--zone-file "$ZONE_PATH" \
		--serial "$new_serial" \
		--count "$LARGE_CHANGE_COUNT"
	rndc primary thaw "$ZONE_NAME"
	rndc distribution retransfer "$ZONE_NAME" || true
}

# Apply change, then poll (for DDNS: poll concurrently while nsupdate runs).
CHANGE_PID=""
case "$METHOD" in
	ddns-giant|ddns-burst)
		ddns_mode="${METHOD#ddns-}"
		script="$(prepare_ddns "$ddns_mode")"
		log "Starting nsupdate -v ($ddns_mode) in background → ${PRIMARY_HOST}:${PRIMARY_PORT}"
		nsupdate -v "$script" >"$OUT/nsupdate-${ddns_mode}.out" 2>"$OUT/nsupdate-${ddns_mode}.err" &
		CHANGE_PID=$!
		;;
	reload-file)
		apply_reload_file
		;;
esac

poll_once() {
	local n="$1" iter="$2"
	rndc distribution retransfer "$ZONE_NAME" || true
	dig_at "$SIGNER_HOST" "$SIGNER_PORT" "$ZONE_NAME" AXFR +tcp +time=20 +tries=1 \
		>"$iter/pressure-signer-axfr.txt" 2>/dev/null &
	local press_pid=$!
	export REPRO_STORY="Scenario scenario-large-primary-change.sh METHOD=${METHOD} (iteration ${n}): waited for FULLY_SIGNED baseline (${baseline_status}), applied large primary change (LARGE_CHANGE_COUNT=${LARGE_CHANGE_COUNT}), then polled distribution AXFR for UNSIGNED/PARTLY_SIGNED during BITW resign."
	set +e
	"$ROOT/scripts/check-zone-signed.sh" --role distribution --out "$iter" --expect-signing
	local crc=$?
	set -e
	wait "$press_pid" 2>/dev/null || true
	if [[ "$crc" -ne 0 ]] && results_is_fail "$iter"; then
		return 0 # hit
	fi
	return 1
}

n=0
while true; do
	n=$((n + 1))
	scenario_iter_should_run "$n" || break
	iter="$OUT/iter-$(printf '%04d' "$n")"
	mkdir -p "$iter"
	if poll_once "$n" "$iter"; then
		log "FAIL on iteration $n (broken zone shipped after large primary change)"
		HIT=1
		cp -a "$iter/." "$OUT/"
		break
	fi
	# If background nsupdate finished with error, record and keep polling briefly.
	if [[ -n "$CHANGE_PID" ]] && ! kill -0 "$CHANGE_PID" 2>/dev/null; then
		set +e
		wait "$CHANGE_PID"
		nsupdate_rc=$?
		set -e
		echo "nsupdate_rc=${nsupdate_rc}" | tee -a "$OUT/baseline.txt"
		if [[ "$nsupdate_rc" -ne 0 ]]; then
			log "WARN: nsupdate exited rc=${nsupdate_rc} (see nsupdate-*.err)"
			head -20 "$OUT"/nsupdate-*.err >&2 || true
		else
			log "nsupdate finished OK"
		fi
		CHANGE_PID=""
	fi
	scenario_iter_sleep "$n"
done

if [[ -n "$CHANGE_PID" ]]; then
	set +e
	wait "$CHANGE_PID"
	nsupdate_rc=$?
	set -e
	echo "nsupdate_rc=${nsupdate_rc}" | tee -a "$OUT/baseline.txt"
fi

echo -n "primary_soa_after=" | tee -a "$OUT/baseline.txt"
soa_serial "$PRIMARY_HOST" "$PRIMARY_PORT" | tee -a "$OUT/baseline.txt" || true

capture_status "$OUT"
if (( HIT )); then
	finish_hit
fi
finish_pass
