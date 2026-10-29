#!/usr/bin/env bash
# Switch dnssec-policy by name after FULLY_SIGNED and watch for orphan RRSIGs
# (RRSIG keytag absent from DNSKEY) — REPORT-KEY-POLICY.md.
#
# ROLLOVER=size  — repro-rsa1024 → repro-rsa2048 (same alg, length change)
#                  Expect HAZARD (exit 1) once old ZSK leaves DNSKEY while
#                  some RRsets are still only signed with the old keytag.
# ROLLOVER=alg   — repro-alg8 → repro-alg13 (true algorithm change)
#                  Expect CLEAN (exit 0): old DNSKEY retained / no orphans
#                  through the short-timer observation window.
#
# Tunables:
#   WARMUP_TIMEOUT   wait for initial FULLY_SIGNED (default 900)
#   WATCH_TIMEOUT    post-switch observation window (default 900)
#   WATCH_INTERVAL   poll interval seconds (default 15)
#   ZONESIZE         used by callers that regenerate before invoke
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

ROLLOVER="${ROLLOVER:?ROLLOVER required: size|alg}"
case "$ROLLOVER" in
	size)
		FROM_POLICY=repro-rsa1024
		TO_POLICY=repro-rsa2048
		FROM_ALG=8
		EXPECT_HAZARD=1
		;;
	alg)
		FROM_POLICY=repro-alg8
		TO_POLICY=repro-alg13
		FROM_ALG=8
		EXPECT_HAZARD=0
		;;
	*) die "unknown ROLLOVER=$ROLLOVER (want size|alg)" ;;
esac

# These policies are NSEC-only; keep the zone on nsec.test.example.
if [[ "${ZONE_NAME}" != "nsec.test.example" && "${ZONE_NAME}" != "nsec.test.example." ]]; then
	log "WARN: key-policy scenarios expect nsec.test.example (got ${ZONE_NAME})"
fi

WARMUP_TIMEOUT="${WARMUP_TIMEOUT:-900}"
WATCH_TIMEOUT="${WATCH_TIMEOUT:-900}"
# Poll signer AXFR quickly — orphan window is a mid-delete quantum.
WATCH_INTERVAL="${WATCH_INTERVAL:-2}"
OUT="$(artifact_dir "${ZONE_NAME%%.*}-key-policy-${ROLLOVER}")"
ORACLE="$COMMON_ROOT/scripts/check-orphan-rrsig.py"

finish_hazard() {
	local why="$1"
	OUT="$(finalize_artifact_dir "$OUT" FAIL)"
	log "HAZARD — ${why} — $OUT"
	exit 1
}

finish_clean() {
	local why="$1"
	OUT="$(finalize_artifact_dir "$OUT" PASS)"
	log "CLEAN — ${why} — $OUT"
	exit 0
}

axfr_snapshot() {
	local dest="$1"
	# Prefer signer: orphan RRSIGs appear between delete quanta before/during
	# BITW notify. Fall back to distribution.
	dig_at "$SIGNER_HOST" "$SIGNER_PORT" "$ZONE_NAME" AXFR \
		+noall +answer +onesoa +time=120 +tries=2 >"$dest" 2>/dev/null \
		|| dig_at "$DISTRIBUTION_HOST" "$DISTRIBUTION_PORT" "$ZONE_NAME" AXFR \
			+noall +answer +onesoa +time=120 +tries=2 >"$dest"
}

list_zsk_tags() {
	local axfr="$1"
	local alg="${2:-}"
	if [[ -n "$alg" ]]; then
		python3 "$ORACLE" --axfr "$axfr" --zone "$ZONE_NAME" --list-zsk --alg "$alg"
	else
		python3 "$ORACLE" --axfr "$axfr" --zone "$ZONE_NAME" --list-zsk
	fi
}

# Patch the host-side signer named.conf.src *before* compose so the zone never
# boots under the default ecdsa policy (foreign-alg keys stick without DS
# signalling and poison the size-change baseline).
SIGNER_SRC_CONF="$ROOT/config/signer/named.conf"
SOURCE_POLICY_BACKUP=""
restore_source_zone_policy() {
	[[ -n "${SOURCE_POLICY_BACKUP:-}" && -f "$SIGNER_SRC_CONF" ]] || return 0
	log "Restore source named.conf dnssec-policy on ${ZONE_NAME} -> ${SOURCE_POLICY_BACKUP}"
	set_zone_dnssec_policy_file "$SIGNER_SRC_CONF" "$ZONE_NAME" "$SOURCE_POLICY_BACKUP" || true
}

# Edit a named.conf on the host (not the running container copy).
set_zone_dnssec_policy_file() {
	local conf="$1" zone="$2" policy="$3"
	local zone_fqdn="${zone%.}."
	python3 - "$conf" "$zone_fqdn" "$policy" <<'PY'
import re, sys
path, zone, policy = sys.argv[1:4]
text = open(path, encoding="utf-8").read()
zone_re = re.compile(
    r'(zone\s+"' + re.escape(zone) + r'"\s*\{)(.*?)(\n\};)',
    re.S,
)
def repl(m):
    head, body, tail = m.group(1), m.group(2), m.group(3)
    body2, n = re.subn(
        r'dnssec-policy\s+"[^"]+"',
        f'dnssec-policy "{policy}"',
        body,
        count=1,
    )
    if n != 1:
        raise SystemExit(f"dnssec-policy not found in zone {zone}")
    return head + body2 + tail
new, n = zone_re.subn(repl, text, count=1)
if n != 1:
    raise SystemExit(f"zone block not found: {zone}")
open(path, "w", encoding="utf-8").write(new)
PY
}

read_source_zone_policy() {
	local conf="$1" zone="$2"
	local zone_fqdn="${zone%.}."
	python3 - "$conf" "$zone_fqdn" <<'PY'
import re, sys
path, zone = sys.argv[1:3]
text = open(path, encoding="utf-8").read()
m = re.search(
    r'zone\s+"' + re.escape(zone) + r'"\s*\{(.*)\n\};',
    text,
    re.S,
)
if not m:
    raise SystemExit(f"zone not found: {zone}")
pm = re.search(r'dnssec-policy\s+"([^"]+)"', m.group(1))
if not pm:
    raise SystemExit("dnssec-policy missing")
print(pm.group(1))
PY
}

log "=== scenario-key-policy-change ROLLOVER=${ROLLOVER} ${FROM_POLICY} -> ${TO_POLICY} ==="
scenario_iter_init

SOURCE_POLICY_BACKUP="$(read_source_zone_policy "$SIGNER_SRC_CONF" "$ZONE_NAME")"
trap restore_source_zone_policy EXIT
log "Pre-set source policy ${SOURCE_POLICY_BACKUP} -> ${FROM_POLICY} (avoid ecdsa leftovers)"
set_zone_dnssec_policy_file "$SIGNER_SRC_CONF" "$ZONE_NAME" "$FROM_POLICY"

# ./keys is a bind mount (bind-owned) and survives compose down -v. Wipe this
# zone's keys as root via docker so we do not inherit prior-algorithm material
# (otherwise FULLY_SIGNED can be satisfied by stale foreign-alg RRSIGs).
log "Clear persistent keys for ${ZONE_NAME} under $ROOT/keys"
docker run --rm -v "$ROOT/keys:/keys:rw" --user 0 busybox:1.36 \
	sh -c "rm -f /keys/K${ZONE_NAME%.}.* /keys/K${ZONE_NAME}.*" \
	2>/dev/null \
	|| docker run --rm -v "$ROOT/keys:/keys:rw" --user 0 alpine:3.20 \
		sh -c "rm -f /keys/K${ZONE_NAME%.}.* /keys/K${ZONE_NAME}.*"
left="$(find "$ROOT/keys" -maxdepth 1 -name "K${ZONE_NAME%.}.*" 2>/dev/null | wc -l | tr -d ' ')"
[[ "$left" == "0" ]] || die "failed to clear keys for ${ZONE_NAME} (still ${left} files)"

compose_fresh
"$ROOT/scripts/wait-ready.sh" 300

wait_distribution_fully_signed "$WARMUP_TIMEOUT" || true
mkdir -p "$OUT/before"
axfr_snapshot "$OUT/before/axfr.txt"
if ! distribution_is_fully_signed; then
	log "WARN: baseline not FULLY_SIGNED — continuing"
fi
# Only track FROM_ALG ZSKs.
mapfile -t OLD_ZSKS < <(list_zsk_tags "$OUT/before/axfr.txt" "$FROM_ALG")
[[ ${#OLD_ZSKS[@]} -gt 0 ]] || die "no alg-${FROM_ALG} ZSK keytags found before policy switch"
OLD_CSV="$(IFS=,; echo "${OLD_ZSKS[*]}")"
{
	echo "rollover=${ROLLOVER}"
	echo "from_policy=${FROM_POLICY}"
	echo "to_policy=${TO_POLICY}"
	echo "from_alg=${FROM_ALG}"
	echo "expect_hazard=${EXPECT_HAZARD}"
	echo "old_zsk_keytags=${OLD_CSV}"
} | tee "$OUT/baseline.txt"
log "Old ZSK keytags (alg ${FROM_ALG}): ${OLD_CSV}"
python3 "$ORACLE" --axfr "$OUT/before/axfr.txt" --zone "$ZONE_NAME" --list-dnskey \
	| tee "$OUT/before/dnskeys.txt" || true
capture_status "$OUT/before"

log "Switch policy name ${FROM_POLICY} -> ${TO_POLICY}"
set_zone_dnssec_policy "$ZONE_NAME" "$TO_POLICY"
rndc signer reconfig || die "reconfig after ${TO_POLICY} failed"
rndc signer sign "$ZONE_NAME" || true
{
	echo "switched_at_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} | tee "$OUT/switch.txt"

deadline=$((SECONDS + WATCH_TIMEOUT))
poll=0
HAZARD_SEEN=0
OLD_GONE=0
mkdir -p "$OUT/watch"

while (( SECONDS < deadline )); do
	poll=$((poll + 1))
	iter="$OUT/watch/poll-$(printf '%04d' "$poll")"
	mkdir -p "$iter"
	axfr_snapshot "$iter/axfr.txt" || true
	mapfile -t NOW_ZSKS < <(list_zsk_tags "$iter/axfr.txt" 2>/dev/null || true)
	NOW_CSV="$(IFS=,; echo "${NOW_ZSKS[*]}")"
	echo "zsk_now=${NOW_CSV}" >"$iter/zsk.txt"

	gone=1
	for tag in "${OLD_ZSKS[@]}"; do
		if printf '%s\n' "${NOW_ZSKS[@]}" | grep -qx "$tag"; then
			gone=0
			break
		fi
	done

	set +e
	python3 "$ORACLE" --axfr "$iter/axfr.txt" --zone "$ZONE_NAME" \
		--only-keytags "$OLD_CSV" --out-dir "$iter"
	orc=$?
	set -e

	{
		echo "poll=${poll}"
		echo "old_zsk_gone=${gone}"
		echo "orphan_rc=${orc}"
		date -u +%Y-%m-%dT%H:%M:%SZ
	} >"$iter/meta.txt"

	if (( gone == 1 )); then
		OLD_GONE=1
		log "poll ${poll}: old ZSK(s) absent from DNSKEY (now=${NOW_CSV:-none})"
	else
		log "poll ${poll}: old ZSK still published (now=${NOW_CSV})"
	fi

	if (( orc == 0 )); then
		HAZARD_SEEN=1
		cp -a "$iter" "$OUT/hazard-hit"
		log "poll ${poll}: ORPHAN RRSIG detected for old keytag(s)"
		# Size-change: first hazard is enough to call FAIL.
		if (( EXPECT_HAZARD == 1 )); then
			capture_status "$OUT/after-hazard"
			finish_hazard "size-change: old keytag RRSIG without DNSKEY (ROLLOVER=size)"
		fi
	fi

	# Alg contrast: if old keys are gone and still no orphans, that is also OK
	# (full re-sign beat the window). Keep watching until timeout either way.
	sleep "$WATCH_INTERVAL"
done

capture_status "$OUT/after-watch"
{
	echo "hazard_seen=${HAZARD_SEEN}"
	echo "old_zsk_gone=${OLD_GONE}"
	echo "expect_hazard=${EXPECT_HAZARD}"
	echo "watch_timeout=${WATCH_TIMEOUT}"
} | tee "$OUT/verdict-inputs.txt"

if (( EXPECT_HAZARD == 1 )); then
	if (( HAZARD_SEEN == 1 )); then
		finish_hazard "orphan RRSIG seen during watch"
	fi
	finish_clean "size-change: no orphan RRSIG within ${WATCH_TIMEOUT}s (hazard not reproduced)"
fi

# ROLLOVER=alg — PASS only if we never saw orphans.
if (( HAZARD_SEEN == 1 )); then
	finish_hazard "alg-change: unexpected orphan RRSIG (contrast failed)"
fi
if (( OLD_GONE == 1 )); then
	finish_clean "alg-change: old ZSK left DNSKEY with no orphan RRSIGs"
fi
finish_clean "alg-change: old ZSK retained through ${WATCH_TIMEOUT}s watch (no orphans)"
