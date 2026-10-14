#!/usr/bin/env bash
# Bump primary SOA serial, reload, overlap inbound/outbound xfer.
# Default: one iter. Override: MAX_ITERS=N or POLL_DURATION=seconds.
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

REGENERATE="${REGENERATE:-0}"
SIZE_MB="${SIZE_MB:-${ZONE_SIZE_MB:-10}}"
OUT="$(artifact_dir "${ZONE_NAME%%.*}-serial-bump")"
HIT=0

log "=== scenario-serial-bump-during-sign ==="
scenario_iter_init
compose_fresh
"$ROOT/scripts/wait-ready.sh" 300

ZONE_PATH="$ZONES_DIR/$ZONE_FILE"
[[ -f "$ZONE_PATH" ]] || die "missing $ZONE_PATH"

old_serial="$(awk '/SOA/,/)/ { for (i=1;i<=NF;i++) if ($i ~ /^[0-9]+$/) { print $i; exit } }' "$ZONE_PATH")"
old_serial="${old_serial:-1}"
new_serial=$((old_serial + 1))

if [[ "$REGENERATE" == "1" ]]; then
	log "Regenerating zone ~${SIZE_MB} MiB with serial $new_serial"
	python3 "$COMMON_ROOT/scripts/generate-zone.py" --size-mb "$SIZE_MB" --serial "$new_serial" --output "$ZONE_PATH"
else
	log "Bumping serial $old_serial -> $new_serial in $ZONE_PATH"
	python3 - "$ZONE_PATH" "$new_serial" <<'PY'
import re, sys
path, serial = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8").read()
new, count = re.subn(
    r'(SOA\b[\s\S]*?\()([\s\S]*?)(\))',
    lambda m: m.group(1) + re.sub(r'\b\d+\b', serial, m.group(2), count=1) + m.group(3),
    text,
    count=1,
    flags=re.IGNORECASE,
)
if count != 1:
    sys.exit("failed to patch SOA serial")
open(path, "w", encoding="utf-8").write(new)
print(f"patched serial to {serial}")
PY
fi

rndc primary reload "$ZONE_NAME"
rndc distribution retransfer "$ZONE_NAME" || true

n=0
while true; do
	n=$((n + 1))
	scenario_iter_should_run "$n" || break
	iter="$OUT/iter-$(printf '%04d' "$n")"
	export REPRO_STORY="Scenario scenario-serial-bump-during-sign.sh (iteration ${n}): bumped primary SOA serial to ${new_serial} (REGENERATE=${REGENERATE}, SIZE_MB=${SIZE_MB}), rndc reload on primary, rndc retransfer on distribution, then checked distribution AXFR during overlapping inbound unsigned transfer + outbound signed resign."
	if ! "$ROOT/scripts/check-zone-signed.sh" --role distribution --out "$iter" --expect-signing; then
		if results_is_fail "$iter"; then
			log "FAIL on iteration $n"
			HIT=1
			cp -a "$iter/." "$OUT/"
			break
		fi
	fi
	dig_at "$SIGNER_HOST" "$SIGNER_PORT" "$ZONE_NAME" AXFR +tcp +time=30 +tries=1 \
		>"$OUT/pressure-axfr.txt" 2>/dev/null || true
	scenario_iter_sleep "$n"
done

capture_status "$OUT"
if (( HIT )); then
	OUT="$(finalize_artifact_dir "$OUT" FAIL)"
	log "REPRODUCED — artifacts $OUT"
	exit 1
fi
OUT="$(finalize_artifact_dir "$OUT" PASS)"
log "No fail in scenario-serial-bump-during-sign — artifacts $OUT"
exit 0
