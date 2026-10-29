#!/usr/bin/env bash
# Prove: Knot rejects an IXFR where the apex is valid *without* the ZSK
# (ZSK removed from DNSKEY; apex + NSEC3 re-signed by KSK alone), while
# non-apex RRsets still carry RRSIGs only for the removed ZSK.
#
# Why this works in Knot: during dnssec-validation, every DNSKEY is treated
# as usable like a ZSK (kasp_zone.c: is_zsk = true). So a KSK-signed apex
# validates after ZSK withdrawal; lingering non-apex ZSK RRSIGs then fail
# with KNOT_DNSSEC_ENOSIG (hint should be a non-apex name, not apex NS).
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

ZONE_NAME="${ZONE_NAME:-manual.test.example}"
ZONE="${ZONE_NAME%.}"
export ZONE_NAME
ZONE_FILE="db.${ZONE}.signed"
export ZONE_FILE
SIGNED="$ROOT/zones/$ZONE_FILE"
KEYS_DIR="$ROOT/keys"

WARMUP_TIMEOUT="${WARMUP_TIMEOUT:-180}"
WATCH_TIMEOUT="${WATCH_TIMEOUT:-60}"
RESTORE_TIMEOUT="${RESTORE_TIMEOUT:-60}"
WATCH_INTERVAL="${WATCH_INTERVAL:-2}"

OUT="$(artifact_dir "zsk-withdraw-clean-apex-ixfr")"
ORACLE="$COMMON_ROOT/scripts/check-orphan-rrsig.py"
CHECK="$ROOT/scripts/check-zone-signed.sh"
META="$KEYS_DIR/zsk-withdraw-meta.txt"

# Non-apex names that keep orphan ZSK RRSIGs (apex + NSEC3 stay KSK-clean).
ORPHAN_OWNERS=(
	"www.${ZONE}."
	"app.${ZONE}."
	"ns1.${ZONE}."
	"txt1.${ZONE}."
)

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

axfr_soa_serial() {
	local axfr="$1"
	[[ -f "$axfr" ]] || return 1
	awk 'BEGIN{IGNORECASE=1} $4=="SOA"{print $7; exit}' "$axfr"
}

# Build serial-2 hazard: KSK-only signed zone + splice ZSK RRSIGs onto ORPHAN_OWNERS.
build_clean_apex_hazard_zone() {
	local serial1_signed="$1"
	local zsk_keytag="$2"
	local serial_bad="$3"
	local out_signed="$4"

	local ksk_only="$OUT/keys-ksk-only"
	local unsigned="$OUT/db.unsigned.clean-apex"
	local ksk_signed="$OUT/db.signed.ksk-only"
	rm -rf "$ksk_only"
	mkdir -p "$ksk_only"
	# Only the KSK private/public material — dnssec-signzone -S will not publish ZSK.
	local ksk_base
	ksk_base="$(sed -n 's/^ksk_base=//p' "$META")"
	cp -a "$KEYS_DIR/${ksk_base}".key "$KEYS_DIR/${ksk_base}".private "$ksk_only/"

	cat >"$unsigned" <<EOF
\$TTL 300
\$ORIGIN ${ZONE}.
@	300	IN	SOA	ns1.${ZONE}. hostmaster.${ZONE}. (
			${serial_bad} ; serial
			300        ; refresh
			60         ; retry
			3600       ; expire
			300        ; minimum
			)
@	300	IN	NS	ns1.${ZONE}.
ns1	300	IN	A	172.30.57.10
www	300	IN	A	192.0.2.80
app	300	IN	A	192.0.2.81
txt1	300	IN	TXT	"manual-signing clean-apex hazard"
EOF

	docker run --rm \
		-v "$ksk_only:/keys:rw" \
		-v "$OUT:/work:rw" \
		-w /work \
		--user 0 \
		--entrypoint dnssec-signzone \
		"internetsystemsconsortium/bind9:${BIND_TAG}" \
		-S -z -K /keys -3 - -H 0 -o "$ZONE" \
		-f "$(basename "$ksk_signed")" "$(basename "$unsigned")" \
		| tee "$OUT/ksk-only-sign.txt"
	docker run --rm -v "$OUT:/work:rw" --user 0 alpine:3.20 chmod -R a+rwX /work >/dev/null
	[[ -f "$ksk_signed" ]] || die "KSK-only sign failed"

	# Ensure no ZSK DNSKEY (flags 256) in the KSK-only zone.
	if grep -qE 'DNSKEY[[:space:]]+256[[:space:]]' "$ksk_signed"; then
		die "KSK-only signed zone unexpectedly contains ZSK DNSKEY"
	fi

	python3 - "$serial1_signed" "$ksk_signed" "$zsk_keytag" "$out_signed" "${ORPHAN_OWNERS[@]}" <<'PY'
import re, sys
from pathlib import Path

src_path, ksk_path, keytag_s, out_path, *owners = sys.argv[1:]
zsk_keytag = int(keytag_s)
want = {o.rstrip(".").lower() + "." for o in owners}

def owner_of(line: str, current: str | None) -> str | None:
    m = re.match(r"^(\S+)\s+", line)
    if not m:
        return current
    tok = m.group(1)
    if tok.startswith("$") or tok.startswith(";"):
        return current
    return tok.lower() if tok.endswith(".") else (tok.lower() + ".")

def iter_rrsig_blocks(text: str):
    lines = text.splitlines(keepends=True)
    i = 0
    current = None
    while i < len(lines):
        line = lines[i]
        current = owner_of(line.split(";", 1)[0], current)
        left = line.split(";", 1)[0]
        if current and re.search(r"\bRRSIG\b", left, re.I):
            block = [line]
            j = i + 1
            if "(" in left:
                while j < len(lines):
                    block.append(lines[j])
                    if ")" in lines[j].split(";", 1)[0]:
                        j += 1
                        break
                    j += 1
            flat = re.sub(r"[()]", " ", " ".join(x.split(";", 1)[0] for x in block))
            m = re.search(
                r"\bRRSIG\s+(\S+)\s+\d+\s+\d+\s+\d+\s+(\d+)\s+(\d+)\s+(\d+)\s+",
                flat,
                re.I,
            )
            tag = int(m.group(4)) if m else None
            covers = m.group(1).upper() if m else None
            yield current, covers, tag, block, i, j
            i = j
            continue
        i += 1

# Harvest ZSK RRSIGs for orphan owners from the original dual-key zone.
harvest: dict[tuple[str, str], list[str]] = {}
src = Path(src_path).read_text(encoding="utf-8")
for owner, covers, tag, block, _, _ in iter_rrsig_blocks(src):
    if owner in want and tag == zsk_keytag and covers is not None:
        harvest[(owner, covers)] = block

if len(harvest) < 1:
    raise SystemExit(f"no ZSK RRSIGs harvested for {sorted(want)} keytag={zsk_keytag}")

# Rebuild KSK-only zone: drop RRSIGs under orphan owners, then append harvested ZSK RRSIGs.
ksk_lines = Path(ksk_path).read_text(encoding="utf-8").splitlines(keepends=True)
out: list[str] = []
i = 0
current = None
stripped = 0
while i < len(ksk_lines):
    line = ksk_lines[i]
    current = owner_of(line.split(";", 1)[0], current)
    left = line.split(";", 1)[0]
    if (
        current in want
        and re.search(r"\bRRSIG\b", left, re.I)
    ):
        j = i + 1
        if "(" in left:
            while j < len(ksk_lines):
                if ")" in ksk_lines[j].split(";", 1)[0]:
                    j += 1
                    break
                j += 1
        stripped += 1
        i = j
        continue
    out.append(line)
    i += 1

# Append harvested ZSK RRSIGs (with absolute owner) before end of file.
# Re-emit each block forcing absolute owner on the first line.
for (owner, covers), block in sorted(harvest.items()):
    first = block[0]
    # Ensure absolute owner at start of RRSIG line.
    if re.match(r"^\s", first):
        # blank-owner form: "\t\t\t300\tRRSIG\t..."
        first = re.sub(r"^\s+", f"{owner}\t", first, count=1)
    elif not first.lower().startswith(owner):
        first = f"{owner}\t" + first.lstrip()
    out.append(first)
    out.extend(block[1:])

Path(out_path).write_text("".join(out), encoding="utf-8")
print(f"harvested_zsk_rrsig={len(harvest)}")
print(f"stripped_ksk_rrsig_on_orphan_owners={stripped}")
print(f"orphan_owners={','.join(sorted(want))}")
print(f"zsk_keytag={zsk_keytag}")
PY
}

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
print(f"non_apex_orphan_detail={other_orph[:12]}")
if len(apex_orph) != 0:
    raise SystemExit(f"apex should be orphan-clean, got {apex_orph}")
if len(other_orph) < 1:
    raise SystemExit("expected non-apex orphan RRSIGs")
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
	# Capture first validation hint (expect non-apex once gate holds).
	if [[ -z "${VALIDATION_HINT:-}" ]]; then
		VALIDATION_HINT="$(
			docker logs "${CONTAINER_PREFIX}-distribution" 2>&1 \
				| grep -Eo 'validation hint: [^[:space:]]+ [[:alnum:]]+' \
				| tail -n1 || true
		)"
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

log "=== scenario-zsk-withdraw-clean-apex-ixfr (KSK-clean apex, lingering ZSK orphans) ==="
scenario_iter_init
VALIDATION_HINT=""

"$ROOT/scripts/build-signed-zone.sh"
ZSK_BASE="$(sed -n 's/^zsk_base=//p' "$META")"
ZSK_KEYTAG="$((10#${ZSK_BASE##*+}))"
[[ -n "$ZSK_KEYTAG" ]] || die "missing ZSK keytag in $META"
cp -a "$SIGNED" "$OUT/db.signed.serial1-dual-key"

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
		log "Knot FULLY_SIGNED under dual-key signed zone"
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
capture_status "$OUT/before"
SERIAL_GOOD="$(soa_serial "$DISTRIBUTION_HOST" "$DISTRIBUTION_PORT" || true)"
[[ -n "$SERIAL_GOOD" ]] || die "could not read Knot SOA before withdraw"
SERIAL_BAD=$((SERIAL_GOOD + 1))
{
	echo "zone=${ZONE_NAME}"
	echo "zsk_keytag=${ZSK_KEYTAG}"
	echo "serial_good=${SERIAL_GOOD}"
	echo "serial_bad=${SERIAL_BAD}"
	echo "withdraw_method=ksk-only-resign-apex+splice-zsk-rrsigs-on-non-apex"
	echo "pass_rule=knot rejects clean-apex IXFR due to non-apex ZSK orphans; never serves serial_bad"
} | tee "$OUT/baseline.txt"

log "Build hazard serial ${SERIAL_BAD}: KSK-clean apex/NSEC3; splice ZSK RRSIGs onto non-apex names"
HAZARD="$OUT/db.signed.clean-apex-hazard"
build_clean_apex_hazard_zone "$OUT/db.signed.serial1-dual-key" "$ZSK_KEYTAG" \
	"$SERIAL_BAD" "$HAZARD" | tee "$OUT/withdraw-edit.txt"
cat "$HAZARD" >"$SIGNED"
{
	echo "withdrawn_at_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	echo "serial_good=${SERIAL_GOOD}"
	echo "serial_bad=${SERIAL_BAD}"
	cat "$OUT/withdraw-edit.txt"
} | tee "$OUT/withdraw.txt"

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
	|| die "primary serial ${PRIMARY_SERIAL:-none} != hazard ${SERIAL_BAD}"
(( primary_orphan_rc == 0 )) || die "primary missing expected non-apex orphans"
APEX_ORPH="$(sed -n 's/^apex_orphan_rrsig=//p' "$OUT/primary-after-withdraw/orphan-class.txt")"
NONAPEX_ORPH="$(sed -n 's/^non_apex_orphan_rrsig=//p' "$OUT/primary-after-withdraw/orphan-class.txt")"
log "Primary serial ${SERIAL_BAD}: apex_orphan=${APEX_ORPH} non_apex_orphan=${NONAPEX_ORPH} (clean apex, lingering ZSK orphans)"

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
		echo "validation_hint=${VALIDATION_HINT:-none}"
		echo "orphan_rc=${_poll_orphan_rc}"
		date -u +%Y-%m-%dT%H:%M:%SZ
	} >"$iter/meta.txt"
	log "poll ${poll}: knot st=${_poll_st:-none} serial=${_poll_serial:-none} (must not be ${SERIAL_BAD}); hint=${VALIDATION_HINT:-none}"

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
	echo "validation_hint=${VALIDATION_HINT:-none}"
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
# Soft assert: hint should not be apex NS if apex is clean (non-apex orphan is the point).
if [[ "${VALIDATION_HINT:-}" == *"${ZONE}."*" NS" ]]; then
	log "WARN: validation hint still apex NS (${VALIDATION_HINT}) — apex may not be KSK-valid"
fi
log "Withdraw watch OK: Knot never served serial ${SERIAL_BAD} (hint=${VALIDATION_HINT:-none})"

SERIAL_RESTORED=$((SERIAL_BAD + 1))
log "Restore: offline re-sign at serial ${SERIAL_RESTORED} (KSK+ZSK)"
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
	-v "$KEYS_DIR:/keys:rw" \
	-v "$OUT:/work:rw" \
	-w /work \
	--user 0 \
	--entrypoint dnssec-signzone \
	"internetsystemsconsortium/bind9:${BIND_TAG}" \
	-S -K /keys -3 - -H 0 -o "$ZONE" \
	-f "$(basename "$SIGNED_RESTORE")" "$(basename "$UNSIGNED_RESTORE")" \
	| tee "$OUT/restore-sign.txt"
docker run --rm -v "$OUT:/work:rw" --user 0 alpine:3.20 chmod -R a+rwX /work >/dev/null
[[ -f "$SIGNED_RESTORE" ]] || die "restore sign failed"
grep -qE 'DNSKEY.*256' "$SIGNED_RESTORE" || die "restored zone missing ZSK"
cat "$SIGNED_RESTORE" >"$SIGNED"
{
	echo "restored_at_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	echo "serial_restored=${SERIAL_RESTORED}"
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
(( primary_restore_orphan_rc != 0 )) || die "primary restored zone still has orphan RRSIGs"

restore_deadline=$((SECONDS + RESTORE_TIMEOUT))
restore_poll=0
RESTORE_OK=0
mkdir -p "$OUT/restore-watch"
while (( SECONDS < restore_deadline )); do
	restore_poll=$((restore_poll + 1))
	iter="$OUT/restore-watch/poll-$(printf '%04d' "$restore_poll")"
	poll_distribution_gate "$iter"
	log "restore poll ${restore_poll}: knot st=${_poll_st:-none} serial=${_poll_serial:-none} (want ${SERIAL_RESTORED})"
	if [[ "${_poll_st:-}" == "FULLY_SIGNED" && "${_poll_serial:-}" == "$SERIAL_RESTORED" ]]; then
		if python3 "$ORACLE" --axfr "$iter/axfr-distribution.txt" --zone "$ZONE_NAME" --list-zsk \
			| tee "$iter/zsks.txt" | grep -q .
		then
			RESTORE_OK=1
			cp -a "$iter" "$OUT/restore-hit"
			break
		fi
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
	echo "validation_hint=${VALIDATION_HINT:-none}"
	echo "apex_orphan_rrsig=${APEX_ORPH}"
	echo "non_apex_orphan_rrsig=${NONAPEX_ORPH}"
	echo "reject_log_seen=${REJECT_LOG_SEEN}"
	echo "kept_good_seen=${KEPT_GOOD_SEEN}"
} | tee "$OUT/verdict-inputs.txt"

(( RESTORE_OK == 1 )) \
	|| finish_fail "Knot never served restored serial ${SERIAL_RESTORED} with ZSK within ${RESTORE_TIMEOUT}s"

why="Knot rejected clean-apex hazard serial ${SERIAL_BAD} (apex orphan=0, non-apex orphan=${NONAPEX_ORPH}; hint=${VALIDATION_HINT:-none}); accepted restored ${SERIAL_RESTORED}"
if (( REJECT_LOG_SEEN == 1 )); then
	why+="; validation reject logged"
fi
if (( KEPT_GOOD_SEEN == 1 )); then
	why+="; kept good serial ${SERIAL_GOOD}"
fi
finish_pass "$why"
