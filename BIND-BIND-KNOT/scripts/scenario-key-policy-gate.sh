#!/usr/bin/env bash
# RSA1024 → RSA2048 same-algorithm dnssec-policy name switch (NSEC3), then
# assert Knot distribution with dnssec-validation:on never serves an invalid
# zone (UNSIGNED / PARTLY_SIGNED / orphan RRSIG). REPORT-KEY-POLICY.md.
#
# PASS: every successful distribution AXFR is FULLY_SIGNED and orphan-clean,
#       or AXFR is unavailable (Knot refused / kept last good).
# FAIL: any distribution AXFR is UNSIGNED, PARTLY_SIGNED, or has orphan RRSIGs.
#
# Tunables:
#   ZONESIZE         zone size MiB (default 10)
#   WARMUP_TIMEOUT   wait for initial FULLY_SIGNED (default 900)
#   WATCH_TIMEOUT    post-switch observation window (default 900)
#   WATCH_INTERVAL   poll interval seconds (default 2)
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

FROM_POLICY=repro-nsec3-rsa1024
TO_POLICY=repro-nsec3-rsa2048
FROM_ALG=8

# Force NSEC3 zone for these policies.
if [[ -n "${MODE:-}" ]]; then
	set_zone_mode "$MODE"
fi
if [[ "${ZONE_NAME}" != "nsec3.test.example" && "${ZONE_NAME}" != "nsec3.test.example." ]]; then
	log "Forcing ZONE_NAME=nsec3.test.example (was ${ZONE_NAME})"
	set_zone_mode nsec3
fi

ZONESIZE="${ZONESIZE:-10}"
if ! [[ "$ZONESIZE" =~ ^[1-9][0-9]*$ ]]; then
	die "ZONESIZE must be a positive integer (megabytes), got: ${ZONESIZE}"
fi

WARMUP_TIMEOUT="${WARMUP_TIMEOUT:-900}"
WATCH_TIMEOUT="${WATCH_TIMEOUT:-900}"
WATCH_INTERVAL="${WATCH_INTERVAL:-2}"

# Knot must validate; AXFR unavailable is allowed (gate held).
install_distribution_validation on
export DNSSEC_VALIDATION=on
export ALLOW_AXFR_UNAVAILABLE=1

VTAG="validate-on"
OUT="$(artifact_dir "${ZONE_NAME%%.*}-${VTAG}-key-policy-gate")"
ORACLE="$COMMON_ROOT/scripts/check-orphan-rrsig.py"
CHECK="$ROOT/scripts/check-zone-signed.sh"

finish_fail() {
	local why="$1"
	OUT="$(finalize_artifact_dir "$OUT" FAIL)"
	log "FAIL — ${why} — $OUT"
	exit 1
}

finish_pass() {
	local why="$1"
	OUT="$(finalize_artifact_dir "$OUT" PASS)"
	log "PASS — ${why} — $OUT"
	exit 0
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

# Host-side named.conf.src edit (before compose) so the zone never boots under
# the default ecdsa policy.
SIGNER_SRC_CONF="$ROOT/config/signer/named.conf"
SOURCE_POLICY_BACKUP=""
restore_source_zone_policy() {
	[[ -n "${SOURCE_POLICY_BACKUP:-}" && -f "$SIGNER_SRC_CONF" ]] || return 0
	log "Restore source named.conf dnssec-policy on ${ZONE_NAME} -> ${SOURCE_POLICY_BACKUP}"
	set_zone_dnssec_policy_file "$SIGNER_SRC_CONF" "$ZONE_NAME" "$SOURCE_POLICY_BACKUP" || true
}

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

# Diagnose signer without affecting PASS/FAIL.
signer_orphan_diag() {
	local dest="$1"
	mkdir -p "$dest"
	if dig_at "$SIGNER_HOST" "$SIGNER_PORT" "$ZONE_NAME" AXFR \
		+noall +answer +onesoa +time=120 +tries=2 >"$dest/axfr-signer.txt" 2>"$dest/axfr-signer.err"
	then
		set +e
		python3 "$ORACLE" --axfr "$dest/axfr-signer.txt" --zone "$ZONE_NAME" \
			--out-dir "$dest" >"$dest/orphan-signer.txt" 2>&1
		echo "orphan_rc=$?" >>"$dest/orphan-signer.txt"
		set -e
	else
		echo "signer_axfr=failed" >"$dest/orphan-signer.txt"
	fi
}

log "=== scenario-key-policy-gate ${FROM_POLICY} -> ${TO_POLICY} (NSEC3, Knot validate-on) ==="
scenario_iter_init

SOURCE_POLICY_BACKUP="$(read_source_zone_policy "$SIGNER_SRC_CONF" "$ZONE_NAME")"
trap restore_source_zone_policy EXIT
log "Pre-set source policy ${SOURCE_POLICY_BACKUP} -> ${FROM_POLICY}"
set_zone_dnssec_policy_file "$SIGNER_SRC_CONF" "$ZONE_NAME" "$FROM_POLICY"

log "Generating ${ZONESIZE} MiB zones (need large nsec3 so re-sign outlasts timers)"
generate_all_zones "$ZONESIZE" 1

log "Clear persistent keys for ${ZONE_NAME} under $ROOT/keys"
docker run --rm -v "$ROOT/keys:/keys:rw" --user 0 busybox:1.36 \
	sh -c "rm -f /keys/K${ZONE_NAME%.}.* /keys/K${ZONE_NAME}.*" \
	2>/dev/null \
	|| docker run --rm -v "$ROOT/keys:/keys:rw" --user 0 alpine:3.20 \
		sh -c "rm -f /keys/K${ZONE_NAME%.}.* /keys/K${ZONE_NAME}.*"
left="$(find "$ROOT/keys" -maxdepth 1 -name "K${ZONE_NAME%.}.*" 2>/dev/null | wc -l | tr -d ' ')"
[[ "$left" == "0" ]] || die "failed to clear keys for ${ZONE_NAME} (still ${left} files)"

# Re-install validate-on after compose_fresh (down -v does not touch host knot.conf,
# but be explicit and recreate distribution with the right template).
compose_fresh
install_distribution_validation on
restart_distribution
"$ROOT/scripts/wait-ready.sh" 300

log "Waiting up to ${WARMUP_TIMEOUT}s for FULLY_SIGNED on distribution under ${FROM_POLICY}..."
warmup_deadline=$((SECONDS + WARMUP_TIMEOUT))
warmup_ok=0
while (( SECONDS < warmup_deadline )); do
	"$CHECK" --role distribution --out "$OUT/warmup" --allow-axfr-unavailable 2>/dev/null || true
	st="$(results_status "$OUT/warmup" 2>/dev/null || true)"
	if [[ "$st" == "FULLY_SIGNED" ]]; then
		warmup_ok=1
		log "Distribution FULLY_SIGNED under ${FROM_POLICY}"
		break
	fi
	log "warmup status=${st:-none}; waiting..."
	sleep 5
done
[[ "$warmup_ok" -eq 1 ]] || die "distribution never reached FULLY_SIGNED within ${WARMUP_TIMEOUT}s"

mkdir -p "$OUT/before"
cp -a "$OUT/warmup/axfr-distribution.txt" "$OUT/before/axfr-distribution.txt" 2>/dev/null || true
mapfile -t OLD_ZSKS < <(list_zsk_tags "$OUT/before/axfr-distribution.txt" "$FROM_ALG")
[[ ${#OLD_ZSKS[@]} -gt 0 ]] || die "no alg-${FROM_ALG} ZSK keytags found before policy switch"
OLD_CSV="$(IFS=,; echo "${OLD_ZSKS[*]}")"
{
	echo "from_policy=${FROM_POLICY}"
	echo "to_policy=${TO_POLICY}"
	echo "from_alg=${FROM_ALG}"
	echo "zonesize_mib=${ZONESIZE}"
	echo "dnssec_validation=on"
	echo "old_zsk_keytags=${OLD_CSV}"
	echo "pass_rule=distribution never serves UNSIGNED|PARTLY_SIGNED|orphan-RRSIG"
} | tee "$OUT/baseline.txt"
log "Old ZSK keytags (alg ${FROM_ALG}): ${OLD_CSV}"
python3 "$ORACLE" --axfr "$OUT/before/axfr-distribution.txt" --zone "$ZONE_NAME" --list-dnskey \
	| tee "$OUT/before/dnskeys.txt" || true
capture_status "$OUT/before"

log "Switch policy name ${FROM_POLICY} -> ${TO_POLICY}"
set_zone_dnssec_policy "$ZONE_NAME" "$TO_POLICY"
rndc signer reconfig || die "reconfig after ${TO_POLICY} failed"
rndc signer sign "$ZONE_NAME" || true
{
	echo "switched_at_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} | tee "$OUT/switch.txt"

# Nudge Knot to pull; gate should reject if the transfer is invalid.
rndc distribution retransfer "$ZONE_NAME" || true

deadline=$((SECONDS + WATCH_TIMEOUT))
poll=0
INVALID_SEEN=0
AXFR_UNAVAILABLE_SEEN=0
VALID_SEEN=0
SIGNER_ORPHAN_SEEN=0
mkdir -p "$OUT/watch"

while (( SECONDS < deadline )); do
	poll=$((poll + 1))
	iter="$OUT/watch/poll-$(printf '%04d' "$poll")"
	mkdir -p "$iter"

	set +e
	"$CHECK" --role distribution --out "$iter" --allow-axfr-unavailable --expect-signing
	check_rc=$?
	set -e
	st="$(results_status "$iter" 2>/dev/null || true)"

	orphan_rc=1
	if [[ -f "$iter/axfr-distribution.txt" && -s "$iter/axfr-distribution.txt" ]]; then
		set +e
		python3 "$ORACLE" --axfr "$iter/axfr-distribution.txt" --zone "$ZONE_NAME" \
			--out-dir "$iter"
		orphan_rc=$?
		set -e
	fi

	signer_orphan_diag "$iter/signer-diag"
	if grep -q '^orphan_rc=0$' "$iter/signer-diag/orphan-signer.txt" 2>/dev/null; then
		SIGNER_ORPHAN_SEEN=1
	fi

	{
		echo "poll=${poll}"
		echo "distribution_status=${st:-none}"
		echo "check_rc=${check_rc}"
		echo "orphan_rc=${orphan_rc}"
		echo "signer_orphan_seen=${SIGNER_ORPHAN_SEEN}"
		date -u +%Y-%m-%dT%H:%M:%SZ
	} >"$iter/meta.txt"

	log "poll ${poll}: distribution status=${st:-none} orphan_rc=${orphan_rc} (signer_orphan=${SIGNER_ORPHAN_SEEN})"

	if [[ "$st" == "UNSIGNED" || "$st" == "PARTLY_SIGNED" ]]; then
		INVALID_SEEN=1
		cp -a "$iter" "$OUT/invalid-hit"
		capture_status "$OUT/after-invalid"
		finish_fail "distribution served ${st} after ${FROM_POLICY} -> ${TO_POLICY}"
	fi

	if (( orphan_rc == 0 )); then
		INVALID_SEEN=1
		cp -a "$iter" "$OUT/invalid-hit"
		capture_status "$OUT/after-invalid"
		finish_fail "distribution served orphan RRSIG (keytag absent from DNSKEY)"
	fi

	if [[ "$st" == "AXFR_UNAVAILABLE" ]]; then
		AXFR_UNAVAILABLE_SEEN=1
	elif [[ "$st" == "FULLY_SIGNED" ]]; then
		VALID_SEEN=1
	fi

	# Occasional retransfer to keep pressure on the gate while signer re-signs.
	if (( poll % 5 == 0 )); then
		rndc distribution retransfer "$ZONE_NAME" || true
	fi

	sleep "$WATCH_INTERVAL"
done

capture_status "$OUT/after-watch"
{
	echo "invalid_seen=${INVALID_SEEN}"
	echo "axfr_unavailable_seen=${AXFR_UNAVAILABLE_SEEN}"
	echo "valid_seen=${VALID_SEEN}"
	echo "signer_orphan_seen=${SIGNER_ORPHAN_SEEN}"
	echo "watch_timeout=${WATCH_TIMEOUT}"
	echo "polls=${poll}"
} | tee "$OUT/verdict-inputs.txt"

if (( INVALID_SEEN == 1 )); then
	finish_fail "invalid distribution content observed during watch"
fi

why="Knot never served invalid zone for ${WATCH_TIMEOUT}s"
if (( AXFR_UNAVAILABLE_SEEN == 1 )); then
	why+="; AXFR_UNAVAILABLE observed (gate held)"
fi
if (( VALID_SEEN == 1 )); then
	why+="; some FULLY_SIGNED AXFRs remained clean"
fi
if (( SIGNER_ORPHAN_SEEN == 1 )); then
	why+="; signer showed orphan RRSIGs (diagnostic)"
fi
finish_pass "$why"
