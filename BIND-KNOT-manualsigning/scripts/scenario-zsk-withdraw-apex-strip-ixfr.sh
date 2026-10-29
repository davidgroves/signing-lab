#!/usr/bin/env bash
# Variant of scenario-zsk-withdraw-ixfr.sh:
#   Remove ZSK DNSKEY *and* all apex RRSIGs signed by that ZSK keytag
#   (SOA / NS / NSEC3PARAM / DNSKEY-by-ZSK). Non-apex RRSIGs stay →
#   lingering orphan signatures on www/app/NSEC3/…
#
# PASS: Knot never serves the hazard serial; then accepts offline restore.
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

ZONE_NAME="${ZONE_NAME:-manual.test.example}"
ZONE="${ZONE_NAME%.}"
export ZONE_NAME
ZONE_FILE="db.${ZONE}.signed"
export ZONE_FILE
SIGNED="$ROOT/zones/$ZONE_FILE"

WARMUP_TIMEOUT="${WARMUP_TIMEOUT:-180}"
WATCH_TIMEOUT="${WATCH_TIMEOUT:-60}"
RESTORE_TIMEOUT="${RESTORE_TIMEOUT:-60}"
WATCH_INTERVAL="${WATCH_INTERVAL:-2}"

OUT="$(artifact_dir "zsk-withdraw-apex-strip-ixfr")"
ORACLE="$COMMON_ROOT/scripts/check-orphan-rrsig.py"
CHECK="$ROOT/scripts/check-zone-signed.sh"
META="$ROOT/keys/zsk-withdraw-meta.txt"

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

# Remove ZSK DNSKEY + apex RRSIGs with that ZSK keytag; bump SOA serial.
# Leaves non-apex RRSIGs (orphans once ZSK DNSKEY is gone).
withdraw_zsk_and_strip_apex_rrsigs() {
	local zonefile="$1"
	local flags="$2" proto="$3" alg="$4" keymat="$5"
	local zsk_keytag="$6"
	local apex="$7"
	local out="$8"
	python3 - "$zonefile" "$flags" "$proto" "$alg" "$keymat" "$zsk_keytag" "$apex" "$out" <<'PY'
import re, sys
from pathlib import Path

path, flags, proto, alg, keymat, keytag_s, apex, out_path = sys.argv[1:9]
keymat = re.sub(r"\s+", "", keymat)
zsk_keytag = int(keytag_s)
apex = apex.rstrip(".").lower() + "."
text = Path(path).read_text(encoding="utf-8")
lines = text.splitlines(keepends=True)

def owner_of(line: str, current: str | None) -> str | None:
    # Absolute owner at start of line, else blank-owner inherits current.
    m = re.match(r"^(\S+)\s+", line)
    if not m:
        return current
    tok = m.group(1)
    if tok.startswith("$") or tok.startswith(";"):
        return current
    return tok.lower() if tok.endswith(".") else (tok.lower() + ".")

removed_dnskey = 0
removed_apex_rrsig = 0
out_lines: list[str] = []
i = 0
current_owner: str | None = None
while i < len(lines):
    line = lines[i]
    current_owner = owner_of(line.split(";", 1)[0], current_owner)

    left = line.split(";", 1)[0]
    # --- strip matching ZSK DNSKEY (not RRSIG covering DNSKEY) ---
    if re.search(r"\bDNSKEY\b", left, re.I) and not re.search(r"\bRRSIG\b", left, re.I):
        block = [line]
        j = i + 1
        if "(" in left:
            while j < len(lines):
                block.append(lines[j])
                if ")" in lines[j].split(";", 1)[0]:
                    j += 1
                    break
                j += 1
        blob = "".join(x.split(";", 1)[0] for x in block)
        blob = re.sub(r"[\s()]+", "", blob)
        m = re.search(
            rf"DNSKEY{re.escape(flags)}{re.escape(proto)}{re.escape(alg)}"
            rf"([A-Za-z0-9+/=]+)",
            blob,
            re.I,
        )
        if m and m.group(1) == keymat:
            removed_dnskey += 1
            i = j
            continue
        out_lines.extend(block)
        i = j
        continue

    # --- strip apex RRSIGs signed by ZSK keytag ---
    if current_owner == apex and re.search(r"\bRRSIG\b", left, re.I):
        block = [line]
        j = i + 1
        if "(" in line.split(";", 1)[0]:
            while j < len(lines):
                block.append(lines[j])
                if ")" in lines[j].split(";", 1)[0]:
                    j += 1
                    break
                j += 1
        # RRSIG <type> <alg> <labels> <ttl> ( <exp> <inc> <keytag> <signer>
        flat = " ".join(x.split(";", 1)[0] for x in block)
        flat = re.sub(r"[()]", " ", flat)
        m = re.search(
            r"\bRRSIG\s+\S+\s+\d+\s+\d+\s+\d+\s+(\d+)\s+(\d+)\s+(\d+)\s+",
            flat,
            re.I,
        )
        if m and int(m.group(3)) == zsk_keytag:
            removed_apex_rrsig += 1
            i = j
            continue
        out_lines.extend(block)
        i = j
        continue

    out_lines.append(line)
    i += 1

if removed_dnskey < 1:
    raise SystemExit(f"ZSK DNSKEY not found in {path}")
if removed_apex_rrsig < 1:
    raise SystemExit(
        f"no apex RRSIG with keytag {zsk_keytag} removed from {path}"
    )

joined = "".join(out_lines)
soa_re = re.compile(r"(\bSOA\b\s+\S+\s+\S+\s*\(\s*)(\d+)", re.I | re.S)
m = soa_re.search(joined)
if not m:
    soa_re2 = re.compile(
        r"(\bSOA\b\s+\S+\s+\S+\s+)(\d+)(\s+\d+\s+\d+\s+\d+\s+\d+)", re.I
    )
    m2 = soa_re2.search(joined)
    if not m2:
        raise SystemExit("SOA serial not found")
    new_serial = int(m2.group(2)) + 1
    joined = soa_re2.sub(
        lambda mo: f"{mo.group(1)}{new_serial}{mo.group(3)}", joined, count=1
    )
else:
    new_serial = int(m.group(2)) + 1
    joined = soa_re.sub(lambda mo: f"{mo.group(1)}{new_serial}", joined, count=1)

Path(out_path).write_text(joined, encoding="utf-8")
print(f"removed_zsk_dnskey={removed_dnskey}")
print(f"removed_apex_zsk_rrsig={removed_apex_rrsig}")
print(f"zsk_keytag={zsk_keytag}")
print(f"new_serial={new_serial}")
PY
}

axfr_soa_serial() {
	local axfr="$1"
	[[ -f "$axfr" ]] || return 1
	awk 'BEGIN{IGNORECASE=1} $4=="SOA"{print $7; exit}' "$axfr"
}

# Classify orphan RRSIGs at apex vs non-apex from a dig-style AXFR.
classify_orphans() {
	local axfr="$1"
	python3 - "$axfr" "$ZONE_NAME" <<'PY'
import base64, re, struct, sys
from pathlib import Path

axfr, zone = sys.argv[1:3]
apex = zone.rstrip(".").lower() + "."

def keytag(flags: int, proto: int, alg: int, key: bytes) -> int:
    rdata = struct.pack("!HBB", flags, proto, alg) + key
    ac = 0
    for i, b in enumerate(rdata):
        ac += (b << 8) if (i & 1) == 0 else b
    ac += (ac >> 16) & 0xFFFF
    return ac & 0xFFFF

present: set[int] = set()
rrsigs: list[tuple[str, str, int]] = []
dnskey_re = re.compile(
    r"^(\S+)\s+\d+\s+IN\s+DNSKEY\s+(\d+)\s+(\d+)\s+(\d+)\s+(.+)$", re.I
)
rrsig_re = re.compile(
    r"^(\S+)\s+\d+\s+IN\s+RRSIG\s+(\S+)\s+(\d+)\s+(\d+)\s+(\d+)\s+"
    r"(\S+)\s+(\S+)\s+(\d+)\s+(\S+)\s+",
    re.I,
)
for raw in Path(axfr).read_text(encoding="utf-8", errors="replace").splitlines():
    line = raw.strip()
    if not line or line.startswith(";"):
        continue
    m = dnskey_re.match(line)
    if m:
        owner = m.group(1).rstrip(".").lower() + "."
        if owner == apex:
            try:
                key = base64.b64decode(re.sub(r"\s+", "", m.group(5)))
                present.add(keytag(int(m.group(2)), int(m.group(3)), int(m.group(4)), key))
            except Exception:
                pass
        continue
    m = rrsig_re.match(line)
    if m:
        owner = m.group(1).rstrip(".").lower() + "."
        covers = m.group(2).upper()
        tag = int(m.group(8))
        rrsigs.append((owner, covers, tag))

apex_orph = [(o, c, t) for o, c, t in rrsigs if o == apex and t not in present]
other_orph = [(o, c, t) for o, c, t in rrsigs if o != apex and t not in present]
print(f"apex_orphan_rrsig={len(apex_orph)}")
print(f"non_apex_orphan_rrsig={len(other_orph)}")
print(f"dnskey_keytags={sorted(present)}")
print(f"apex_orphan_detail={apex_orph[:8]}")
if len(other_orph) < 1:
    raise SystemExit("expected lingering non-apex orphan RRSIGs")
PY
}

poll_distribution_gate() {
	local iter="$1"
	mkdir -p "$iter"
	set +e
	"$CHECK" --role distribution --out "$iter" --allow-axfr-unavailable --expect-signing
	_poll_check_rc=$?
	set -e
	_poll_st="$(results_status "$iter" 2>/dev/null || true)"
	_poll_serial=""
	_poll_orphan_rc=1
	if [[ -f "$iter/axfr-distribution.txt" && -s "$iter/axfr-distribution.txt" ]]; then
		_poll_serial="$(axfr_soa_serial "$iter/axfr-distribution.txt" || true)"
		set +e
		python3 "$ORACLE" --axfr "$iter/axfr-distribution.txt" --zone "$ZONE_NAME" \
			--out-dir "$iter"
		_poll_orphan_rc=$?
		set -e
	fi
	if docker logs "${CONTAINER_PREFIX}-distribution" 2>&1 \
		| grep -Eiq 'validation failed|failed to store changes|no valid signature'
	then
		REJECT_LOG_SEEN=1
	fi
	if [[ "$_poll_st" == "UNSIGNED" || "$_poll_st" == "PARTLY_SIGNED" ]]; then
		cp -a "$iter" "$OUT/invalid-hit"
		capture_status "$OUT/after-invalid"
		finish_fail "Knot served ${_poll_st} (serial=${_poll_serial:-none})"
	fi
	if (( _poll_orphan_rc == 0 )); then
		cp -a "$iter" "$OUT/invalid-hit"
		capture_status "$OUT/after-invalid"
		finish_fail "Knot served orphan RRSIG (serial=${_poll_serial:-none})"
	fi
	if [[ -n "${SERIAL_BAD:-}" && -n "${_poll_serial:-}" && "$_poll_serial" == "$SERIAL_BAD" ]]; then
		cp -a "$iter" "$OUT/invalid-hit"
		capture_status "$OUT/after-invalid"
		finish_fail "Knot served hazard serial ${SERIAL_BAD}"
	fi
}

log "=== scenario-zsk-withdraw-apex-strip-ixfr (ZSK gone + apex ZSK RRSIGs stripped) ==="
scenario_iter_init

"$ROOT/scripts/build-signed-zone.sh"
ZSK_FLAGS="$(sed -n 's/^zsk_flags=//p' "$META")"
ZSK_PROTO="$(sed -n 's/^zsk_proto=//p' "$META")"
ZSK_ALG="$(sed -n 's/^zsk_alg=//p' "$META")"
ZSK_KEYMATERIAL="$(sed -n 's/^zsk_keymaterial=//p' "$META")"
ZSK_BASE="$(sed -n 's/^zsk_base=//p' "$META")"
# dnssec-keygen zero-pads key ids (e.g. +07628); force decimal.
ZSK_KEYTAG="$((10#${ZSK_BASE##*+}))"
[[ -n "$ZSK_FLAGS" && -n "$ZSK_KEYMATERIAL" && -n "$ZSK_KEYTAG" ]] || die "incomplete $META"

compose_fresh
"$ROOT/scripts/wait-ready.sh" "$WARMUP_TIMEOUT"

log "Waiting up to ${WARMUP_TIMEOUT}s for FULLY_SIGNED on Knot..."
warmup_deadline=$((SECONDS + WARMUP_TIMEOUT))
warmup_ok=0
while (( SECONDS < warmup_deadline )); do
	"$CHECK" --role distribution --out "$OUT/warmup" --allow-axfr-unavailable 2>/dev/null || true
	st="$(results_status "$OUT/warmup" 2>/dev/null || true)"
	if [[ "$st" == "FULLY_SIGNED" ]]; then
		warmup_ok=1
		log "Knot FULLY_SIGNED under hand-signed NSEC3 zone"
		break
	fi
	log "warmup status=${st:-none}"
	rndc distribution retransfer "$ZONE_NAME" || true
	sleep 3
done
[[ "$warmup_ok" -eq 1 ]] || die "Knot never reached FULLY_SIGNED"

mkdir -p "$OUT/before"
cp -a "$OUT/warmup/axfr-distribution.txt" "$OUT/before/axfr-distribution.txt"
python3 "$ORACLE" --axfr "$OUT/before/axfr-distribution.txt" --zone "$ZONE_NAME" --list-dnskey \
	| tee "$OUT/before/dnskeys.txt"
if ! python3 "$ORACLE" --axfr "$OUT/before/axfr-distribution.txt" --zone "$ZONE_NAME" --list-zsk \
	| tee "$OUT/before/zsks.txt" | grep -q .
then
	die "no ZSK on distribution before withdraw"
fi
capture_status "$OUT/before"
SERIAL_GOOD="$(soa_serial "$DISTRIBUTION_HOST" "$DISTRIBUTION_PORT" || true)"
[[ -n "$SERIAL_GOOD" ]] || die "could not read Knot SOA before withdraw"
{
	echo "zone=${ZONE_NAME}"
	echo "zsk_flags=${ZSK_FLAGS}"
	echo "zsk_alg=${ZSK_ALG}"
	echo "zsk_keytag=${ZSK_KEYTAG}"
	echo "serial_good=${SERIAL_GOOD}"
	echo "withdraw_method=zonefile-edit-zsk+apex-zsk-rrsig-strip+rndc-reload"
	echo "pass_rule=knot never serves hazard serial (lingering non-apex orphans); recovers after restore"
} | tee "$OUT/baseline.txt"

log "Edit: remove ZSK DNSKEY + apex RRSIGs keytag=${ZSK_KEYTAG}; leave non-apex orphans"
cp -f "$SIGNED" "$OUT/before/db.signed.pre-withdraw"
EDITED="$OUT/db.signed.zsk-withdrawn-apex-strip"
withdraw_zsk_and_strip_apex_rrsigs "$SIGNED" "$ZSK_FLAGS" "$ZSK_PROTO" "$ZSK_ALG" \
	"$ZSK_KEYMATERIAL" "$ZSK_KEYTAG" "$ZONE_NAME" "$EDITED" | tee "$OUT/withdraw-edit.txt"
cat "$EDITED" >"$SIGNED"
SERIAL_BAD="$(sed -n 's/^new_serial=//p' "$OUT/withdraw-edit.txt" | tail -n1)"
[[ -n "$SERIAL_BAD" ]] || die "missing new_serial from withdraw edit"
[[ "$SERIAL_BAD" != "$SERIAL_GOOD" ]] || die "withdraw serial did not advance (${SERIAL_BAD})"
{
	echo "withdrawn_at_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	echo "serial_good=${SERIAL_GOOD}"
	echo "serial_bad=${SERIAL_BAD}"
	echo "edited_zonefile=${SIGNED}"
	cat "$OUT/withdraw-edit.txt"
} | tee "$OUT/withdraw.txt"
log "Serials: good=${SERIAL_GOOD} hazard=${SERIAL_BAD} — Knot must never serve ${SERIAL_BAD}"

log "rndc reload primary (ixfr-from-differences)"
rndc primary reload "$ZONE_NAME" || die "rndc reload failed"
rndc primary notify "$ZONE_NAME" || true
sleep 1
rndc distribution retransfer "$ZONE_NAME" || true

mkdir -p "$OUT/primary-after-withdraw"
dig_at "$PRIMARY_HOST" "$PRIMARY_PORT" "$ZONE_NAME" AXFR \
	+noall +answer +onesoa +time=60 +tries=2 \
	>"$OUT/primary-after-withdraw/axfr.txt" 2>"$OUT/primary-after-withdraw/axfr.err" || true
PRIMARY_SERIAL="$(axfr_soa_serial "$OUT/primary-after-withdraw/axfr.txt" || true)"
set +e
python3 "$ORACLE" --axfr "$OUT/primary-after-withdraw/axfr.txt" --zone "$ZONE_NAME" \
	--out-dir "$OUT/primary-after-withdraw"
primary_orphan_rc=$?
set -e
classify_orphans "$OUT/primary-after-withdraw/axfr.txt" \
	| tee "$OUT/primary-after-withdraw/orphan-class.txt"
{
	echo "primary_serial=${PRIMARY_SERIAL:-none}"
	echo "primary_orphan_rc=${primary_orphan_rc}"
	echo "expect_serial=${SERIAL_BAD}"
} | tee "$OUT/primary-after-withdraw/meta.txt"
[[ "$PRIMARY_SERIAL" == "$SERIAL_BAD" ]] \
	|| die "primary serial ${PRIMARY_SERIAL:-none} != hazard serial ${SERIAL_BAD}"
if (( primary_orphan_rc != 0 )); then
	die "primary on serial ${SERIAL_BAD} but no orphan RRSIGs (non-apex strip failed?)"
fi
APEX_ORPH="$(sed -n 's/^apex_orphan_rrsig=//p' "$OUT/primary-after-withdraw/orphan-class.txt")"
NONAPEX_ORPH="$(sed -n 's/^non_apex_orphan_rrsig=//p' "$OUT/primary-after-withdraw/orphan-class.txt")"
[[ "${NONAPEX_ORPH:-0}" -ge 1 ]] || die "expected non-apex lingering orphans"
log "Primary serial ${SERIAL_BAD}: apex_orphan=${APEX_ORPH} non_apex_orphan=${NONAPEX_ORPH} (ZSK RRSIGs stripped at apex)"

deadline=$((SECONDS + WATCH_TIMEOUT))
poll=0
AXFR_UNAVAILABLE_SEEN=0
KEPT_GOOD_SEEN=0
REJECT_LOG_SEEN=0
mkdir -p "$OUT/watch"

while (( SECONDS < deadline )); do
	poll=$((poll + 1))
	iter="$OUT/watch/poll-$(printf '%04d' "$poll")"
	poll_distribution_gate "$iter"
	primary_now="$(soa_serial "$PRIMARY_HOST" "$PRIMARY_PORT" || echo "?")"
	{
		echo "poll=${poll}"
		echo "phase=withdraw-watch"
		echo "distribution_status=${_poll_st:-none}"
		echo "distribution_serial=${_poll_serial:-none}"
		echo "primary_serial=${primary_now}"
		echo "serial_good=${SERIAL_GOOD}"
		echo "serial_bad=${SERIAL_BAD}"
		echo "orphan_rc=${_poll_orphan_rc}"
		echo "reject_log_seen=${REJECT_LOG_SEEN}"
		date -u +%Y-%m-%dT%H:%M:%SZ
	} >"$iter/meta.txt"
	log "poll ${poll}: knot st=${_poll_st:-none} serial=${_poll_serial:-none} (must not be ${SERIAL_BAD}); primary=${primary_now}"

	if [[ "${_poll_st:-}" == "AXFR_UNAVAILABLE" ]]; then
		AXFR_UNAVAILABLE_SEEN=1
	elif [[ "${_poll_st:-}" == "FULLY_SIGNED" ]]; then
		if [[ "${_poll_serial:-}" == "$SERIAL_GOOD" ]]; then
			KEPT_GOOD_SEEN=1
		elif [[ -n "${_poll_serial:-}" && "${_poll_serial}" != "$SERIAL_GOOD" && "${_poll_serial}" != "$SERIAL_BAD" ]]; then
			finish_fail "Knot served unexpected serial ${_poll_serial} during withdraw watch"
		fi
	fi

	if (( poll % 3 == 0 )); then
		rndc distribution retransfer "$ZONE_NAME" || true
	fi
	sleep "$WATCH_INTERVAL"
done

capture_status "$OUT/after-watch"
knot_after_watch="$(soa_serial "$DISTRIBUTION_HOST" "$DISTRIBUTION_PORT" || echo none)"
{
	echo "phase=withdraw-watch-done"
	echo "axfr_unavailable_seen=${AXFR_UNAVAILABLE_SEEN}"
	echo "kept_good_seen=${KEPT_GOOD_SEEN}"
	echo "reject_log_seen=${REJECT_LOG_SEEN}"
	echo "primary_orphan_rc=${primary_orphan_rc}"
	echo "apex_orphan_rrsig=${APEX_ORPH}"
	echo "non_apex_orphan_rrsig=${NONAPEX_ORPH}"
	echo "serial_good=${SERIAL_GOOD}"
	echo "serial_bad=${SERIAL_BAD}"
	echo "knot_serial_after_watch=${knot_after_watch}"
	echo "watch_timeout=${WATCH_TIMEOUT}"
	echo "polls=${poll}"
} | tee "$OUT/verdict-withdraw.txt"
[[ "$knot_after_watch" != "$SERIAL_BAD" ]] \
	|| finish_fail "Knot SOA is hazard serial ${SERIAL_BAD} after watch"
log "Withdraw watch OK: Knot never served serial ${SERIAL_BAD} (knot now=${knot_after_watch})"

SERIAL_RESTORED=$((SERIAL_BAD + 1))
log "Restore: offline re-sign at serial ${SERIAL_RESTORED} (same keys)"
UNSIGNED_RESTORE="$OUT/db.unsigned.restore"
SIGNED_RESTORE="$OUT/db.signed.zsk-restored"
cat >"$UNSIGNED_RESTORE" <<EOF
\$TTL 300
\$ORIGIN ${ZONE}.
@	300	IN	SOA	ns1.${ZONE}. hostmaster.${ZONE}. (
			${SERIAL_RESTORED} ; serial
			300        ; refresh
			60         ; retry
			3600       ; expire
			300        ; minimum
			)
@	300	IN	NS	ns1.${ZONE}.
ns1	300	IN	A	172.30.57.10
www	300	IN	A	192.0.2.80
app	300	IN	A	192.0.2.81
txt1	300	IN	TXT	"manual-signing restored"
EOF
docker run --rm \
	-v "$ROOT/keys:/keys:rw" \
	-v "$OUT:/work:rw" \
	-w /work \
	--user 0 \
	--entrypoint dnssec-signzone \
	"internetsystemsconsortium/bind9:${BIND_TAG}" \
	-S -K /keys -3 - -H 0 -o "$ZONE" \
	-f "$(basename "$SIGNED_RESTORE")" "$(basename "$UNSIGNED_RESTORE")" \
	| tee "$OUT/restore-sign.txt"
docker run --rm -v "$OUT:/work:rw" --user 0 alpine:3.20 \
	chmod -R a+rwX /work >/dev/null
[[ -f "$SIGNED_RESTORE" ]] || die "restore sign failed (missing $SIGNED_RESTORE)"
grep -qE 'DNSKEY.*256' "$SIGNED_RESTORE" || die "restored zone missing ZSK"
cat "$SIGNED_RESTORE" >"$SIGNED"
{
	echo "restored_at_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	echo "serial_restored=${SERIAL_RESTORED}"
	echo "method=offline-dnssec-signzone-same-keys"
} | tee "$OUT/restore.txt"

rndc primary reload "$ZONE_NAME" || die "rndc reload after restore failed"
rndc primary notify "$ZONE_NAME" || true
sleep 1
rndc distribution retransfer "$ZONE_NAME" || true

primary_restored="$(soa_serial "$PRIMARY_HOST" "$PRIMARY_PORT" || true)"
[[ "$primary_restored" == "$SERIAL_RESTORED" ]] \
	|| die "primary serial ${primary_restored:-none} != restored ${SERIAL_RESTORED}"
mkdir -p "$OUT/primary-after-restore"
dig_at "$PRIMARY_HOST" "$PRIMARY_PORT" "$ZONE_NAME" AXFR \
	+noall +answer +onesoa +time=60 +tries=2 \
	>"$OUT/primary-after-restore/axfr.txt" 2>"$OUT/primary-after-restore/axfr.err" || true
set +e
python3 "$ORACLE" --axfr "$OUT/primary-after-restore/axfr.txt" --zone "$ZONE_NAME" \
	--out-dir "$OUT/primary-after-restore"
primary_restore_orphan_rc=$?
set -e
(( primary_restore_orphan_rc != 0 )) \
	|| die "primary restored zone still has orphan RRSIGs"
log "Primary serves valid serial ${SERIAL_RESTORED} with ZSK (orphan-clean)"

restore_deadline=$((SECONDS + RESTORE_TIMEOUT))
restore_poll=0
RESTORE_OK=0
mkdir -p "$OUT/restore-watch"
while (( SECONDS < restore_deadline )); do
	restore_poll=$((restore_poll + 1))
	iter="$OUT/restore-watch/poll-$(printf '%04d' "$restore_poll")"
	poll_distribution_gate "$iter"
	{
		echo "poll=${restore_poll}"
		echo "phase=restore-watch"
		echo "distribution_status=${_poll_st:-none}"
		echo "distribution_serial=${_poll_serial:-none}"
		echo "serial_restored=${SERIAL_RESTORED}"
		echo "orphan_rc=${_poll_orphan_rc}"
		date -u +%Y-%m-%dT%H:%M:%SZ
	} >"$iter/meta.txt"
	log "restore poll ${restore_poll}: knot st=${_poll_st:-none} serial=${_poll_serial:-none} (want ${SERIAL_RESTORED} with ZSK)"

	if [[ "${_poll_st:-}" == "FULLY_SIGNED" && "${_poll_serial:-}" == "$SERIAL_RESTORED" ]]; then
		if python3 "$ORACLE" --axfr "$iter/axfr-distribution.txt" --zone "$ZONE_NAME" --list-zsk \
			| tee "$iter/zsks.txt" | grep -q .
		then
			RESTORE_OK=1
			cp -a "$iter" "$OUT/restore-hit"
			log "Knot accepted restored serial ${SERIAL_RESTORED} with ZSK"
			break
		fi
		log "serial ${SERIAL_RESTORED} FULLY_SIGNED but ZSK missing — continuing"
	fi
	if (( restore_poll % 3 == 0 )); then
		rndc distribution retransfer "$ZONE_NAME" || true
	fi
	sleep "$WATCH_INTERVAL"
done

capture_status "$OUT/after-restore"
{
	echo "restore_ok=${RESTORE_OK}"
	echo "serial_good=${SERIAL_GOOD}"
	echo "serial_bad=${SERIAL_BAD}"
	echo "serial_restored=${SERIAL_RESTORED}"
	echo "apex_orphan_rrsig=${APEX_ORPH}"
	echo "non_apex_orphan_rrsig=${NONAPEX_ORPH}"
	echo "reject_log_seen=${REJECT_LOG_SEEN}"
	echo "kept_good_seen=${KEPT_GOOD_SEEN}"
	echo "axfr_unavailable_seen=${AXFR_UNAVAILABLE_SEEN}"
} | tee "$OUT/verdict-inputs.txt"

(( RESTORE_OK == 1 )) \
	|| finish_fail "Knot never served restored serial ${SERIAL_RESTORED} with ZSK within ${RESTORE_TIMEOUT}s"

why="Knot never served hazard serial ${SERIAL_BAD} (ZSK gone + apex ZSK RRSIGs stripped; ${NONAPEX_ORPH} non-apex orphans on primary); then accepted restored serial ${SERIAL_RESTORED}"
if (( REJECT_LOG_SEEN == 1 )); then
	why+="; validation reject logged"
fi
if (( KEPT_GOOD_SEEN == 1 )); then
	why+="; kept good serial ${SERIAL_GOOD} during withdraw"
fi
finish_pass "$why"
