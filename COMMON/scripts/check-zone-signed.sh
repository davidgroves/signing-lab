#!/usr/bin/env bash
# AXFR a server and verify RRSIG coverage for signable RRsets.
# Exit 0 = fully signed (PASS); 1 = unsigned/partly signed (FAIL); 2 = tool error.
set -euo pipefail
# Resolve stack lib: prefer caller path (symlink from <stack>/scripts),
# then STACK_LIB, then STACK_ROOT/scripts/lib.sh.
_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
if [[ -f "$_SCRIPT_DIR/lib.sh" ]]; then
	source "$_SCRIPT_DIR/lib.sh"
elif [[ -n "${STACK_LIB:-}" && -f "$STACK_LIB" ]]; then
	source "$STACK_LIB"
elif [[ -n "${STACK_ROOT:-}" && -f "$STACK_ROOT/scripts/lib.sh" ]]; then
	source "$STACK_ROOT/scripts/lib.sh"
else
	echo "ERROR: cannot find stack lib.sh (run via <stack>/scripts, or set STACK_LIB)" >&2
	exit 2
fi

usage() {
	cat <<EOF
Usage: $0 [--role signer|distribution] [--host H] [--port P] [--out DIR] [--expect-signing]
       [--allow-axfr-unavailable]

AXFR the zone and check that every signable RRset has a covering RRSIG.
Writes RESULTS.md. When --out is omitted, the artifact directory is renamed *-PASS or *-FAIL.

With --allow-axfr-unavailable (or ALLOW_AXFR_UNAVAILABLE=1): dig/empty/no-SOA AXFR is
PASS (zone not published). Still FAIL on UNSIGNED or PARTLY_SIGNED.
EOF
}

ROLE="distribution"
HOST=""
PORT=""
OUT=""
EXPECT_SIGNING=0
OWN_OUT=0
ALLOW_AXFR_UNAVAILABLE="${ALLOW_AXFR_UNAVAILABLE:-0}"

while [[ $# -gt 0 ]]; do
	case "$1" in
		--role) ROLE="$2"; shift 2 ;;
		--host) HOST="$2"; shift 2 ;;
		--port) PORT="$2"; shift 2 ;;
		--out) OUT="$2"; shift 2 ;;
		--expect-signing) EXPECT_SIGNING=1; shift ;;
		--allow-axfr-unavailable) ALLOW_AXFR_UNAVAILABLE=1; shift ;;
		-h|--help) usage; exit 0 ;;
		*) die "unknown arg: $1" ;;
	esac
done

case "$ROLE" in
	signer)
		HOST="${HOST:-$SIGNER_HOST}"
		PORT="${PORT:-$SIGNER_PORT}"
		;;
	distribution)
		HOST="${HOST:-$DISTRIBUTION_HOST}"
		PORT="${PORT:-$DISTRIBUTION_PORT}"
		;;
	primary)
		HOST="${HOST:-$PRIMARY_HOST}"
		PORT="${PORT:-$PRIMARY_PORT}"
		;;
	*) die "role must be signer|distribution|primary" ;;
esac

if [[ -z "$OUT" ]]; then
	OUT="$(artifact_dir "check-${ROLE}")"
	OWN_OUT=1
fi
mkdir -p "$OUT"

AXFR_FILE="$OUT/axfr-${ROLE}.txt"
RESULTS="$OUT/RESULTS.md"

finish() {
	local code=$1
	if [[ "$OWN_OUT" -eq 1 ]]; then
		if [[ "$code" -eq 0 ]]; then
			OUT="$(finalize_artifact_dir "$OUT" PASS)"
		elif [[ "$code" -eq 1 ]]; then
			OUT="$(finalize_artifact_dir "$OUT" FAIL)"
		fi
	fi
	exit "$code"
}

_pass_axfr_unavailable() {
	local reason="$1"
	log "PASS: AXFR unavailable ($reason) — treating as not publishing a broken zone"
	capture_status "$OUT"
	cat >"$RESULTS" <<EOF
# Results

**Verdict:** PASS
**Status:** AXFR_UNAVAILABLE

| Field | Value |
|-------|-------|
| Zone | \`${ZONE_NAME}\` |
| Role checked | \`${ROLE}\` |
| Server | \`${HOST}:${PORT}\` |
| Reason | ${reason} |

AXFR was unavailable; with --allow-axfr-unavailable this counts as PASS
(distribution did not serve UNSIGNED/PARTLY_SIGNED content).
EOF
	finish 0
}

log "AXFR $ZONE_NAME from ${ROLE} @${HOST}#${PORT} -> $AXFR_FILE"
if ! dig_at "$HOST" "$PORT" "$ZONE_NAME" AXFR +noall +answer +onesoa +time=120 +tries=2 >"$AXFR_FILE" 2>"$OUT/axfr-${ROLE}.err"; then
	log "AXFR dig failed; see $OUT/axfr-${ROLE}.err"
	if [[ "$ALLOW_AXFR_UNAVAILABLE" == "1" ]]; then
		_pass_axfr_unavailable "dig failed"
	fi
	capture_status "$OUT"
	finish 2
fi

if [[ ! -s "$AXFR_FILE" ]]; then
	log "empty AXFR"
	if [[ "$ALLOW_AXFR_UNAVAILABLE" == "1" ]]; then
		_pass_axfr_unavailable "empty AXFR"
	fi
	capture_status "$OUT"
	finish 2
fi
if ! grep -Eq '[[:space:]]SOA[[:space:]]' "$AXFR_FILE"; then
	log "AXFR missing SOA (transfer refused or truncated); see $AXFR_FILE"
	if [[ "$ALLOW_AXFR_UNAVAILABLE" == "1" ]]; then
		_pass_axfr_unavailable "missing SOA"
	fi
	capture_status "$OUT"
	finish 2
fi

# Build RESULTS.md: RRSIG coverage for signable RRsets.
python3 - "$AXFR_FILE" "$RESULTS" "$ROLE" "$HOST" "$PORT" "$ZONE_NAME" <<'PY'
import sys
from collections import defaultdict
from datetime import datetime, timezone

axfr_path, results_path, role, host, port, zone = sys.argv[1:7]

# Only RRSIG itself is not "signed by" an RRSIG; NSEC/NSEC3/NSEC3PARAM must be signed.
SKIP_NEED = {"RRSIG"}

rrsets = defaultdict(set)
rrsigs = defaultdict(set)
dnskey = 0
rrsig_total = 0
soa_serial = None
lines = 0
apex = zone.lower().rstrip(".") + "."
nsec3_optout = False

for raw in open(axfr_path, encoding="utf-8", errors="replace"):
    line = raw.strip()
    if not line or line.startswith(";"):
        continue
    parts = line.split()
    if len(parts) < 4:
        continue
    owner, _ttl, _cls, rtype = parts[0], parts[1], parts[2], parts[3]
    owner = owner.lower()
    if not owner.endswith("."):
        owner += "."
    rtype = rtype.upper()
    lines += 1
    if rtype == "SOA" and soa_serial is None and len(parts) >= 7:
        try:
            soa_serial = int(parts[6])
        except ValueError:
            pass
    if rtype == "DNSKEY":
        dnskey += 1
    if rtype == "NSEC3" and len(parts) >= 6:
        try:
            # NSEC3: hash_alg flags iterations salt ... — flags bit 0x01 = OPTOUT
            if int(parts[5]) & 0x01:
                nsec3_optout = True
        except ValueError:
            pass
    if rtype == "RRSIG":
        rrsig_total += 1
        if len(parts) >= 5:
            covered = parts[4].upper()
            rrsigs[(owner, covered)].add(True)
        continue
    rrsets[(owner, rtype)].add(True)

# Under NSEC3 opt-out, insecure delegation NS (+ typical in-bailiwick glue) stay unsigned.
delegation_ns = set()
if nsec3_optout:
    for (owner, rtype) in rrsets:
        if rtype == "NS" and owner != apex:
            delegation_ns.add(owner)

def optout_exempt(owner: str, rtype: str) -> bool:
    if not nsec3_optout:
        return False
    if rtype == "NS" and owner in delegation_ns:
        return True
    if rtype in ("A", "AAAA") and owner != apex:
        # Generator glue: ns.delegNNNN.<apex>
        local = owner[: -len(apex)].rstrip(".")
        if local.startswith("ns.deleg"):
            return True
    return False

need, have_sig, missing = [], [], []
for (owner, rtype), _ in sorted(rrsets.items()):
    if rtype in SKIP_NEED:
        continue
    if optout_exempt(owner, rtype):
        continue
    need.append((owner, rtype))
    if (owner, rtype) in rrsigs:
        have_sig.append((owner, rtype))
    else:
        missing.append((owner, rtype))

unsigned = rrsig_total == 0
partial = (not unsigned) and bool(missing) and bool(have_sig)
fully = (not missing) and rrsig_total > 0

status = "FULLY_SIGNED"
verdict = "PASS"
if unsigned:
    status = "UNSIGNED"
    verdict = "FAIL"
elif partial or missing:
    status = "PARTLY_SIGNED"
    verdict = "FAIL"

now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

nsec_count = sum(1 for (_o, t) in rrsets if t == "NSEC")
nsec3_count = sum(1 for (_o, t) in rrsets if t == "NSEC3")
nsec3param_count = sum(1 for (_o, t) in rrsets if t == "NSEC3PARAM")
if nsec3_count or nsec3param_count:
    oe = "optout=yes" if nsec3_optout else "optout=no"
    doe = f"NSEC3 (NSEC3={nsec3_count}, NSEC3PARAM={nsec3param_count}, {oe})"
elif nsec_count:
    doe = f"NSEC (NSEC={nsec_count})"
else:
    doe = "none detected (unsigned or incomplete)"

md = f"""# Results

**Verdict:** {verdict}
**Status:** {status}

| Field | Value |
|-------|-------|
| Zone | `{zone}` |
| Role checked | `{role}` |
| Server | `{host}:{port}` |
| Captured (UTC) | {now} |
| SOA serial | `{soa_serial}` |
| Denial of existence | {doe} |
| AXFR RR lines | {lines} |
| DNSKEY count | {dnskey} |
| RRSIG count | {rrsig_total} |
| Signable RRsets | {len(need)} |
| Signed RRsets | {len(have_sig)} |
| Missing RRSIGs | {len(missing)} |

## Meaning

| Status | Meaning |
|--------|---------|
| `FULLY_SIGNED` | Every signable RRset has a covering RRSIG (pass). |
| `UNSIGNED` | No RRSIGs in the AXFR (fail / reproduction hit). |
| `PARTLY_SIGNED` | Some RRsets signed, others missing RRSIGs (fail / reproduction hit). |

## Evidence files

- `axfr-{role}.txt` — full AXFR used for this check
- `BROKEN_ZONE.axfr` / `broken-zone/` — present on FAIL
- `BROKEN_ZONE.dnssec-verify.*` — `dnssec-verify` output on FAIL
"""

with open(results_path, "w", encoding="utf-8") as fh:
    fh.write(md)

print(f"results: {verdict} {status} serial={soa_serial} rrsig={rrsig_total} "
      f"signed={len(have_sig)}/{len(need)} missing={len(missing)} doe={doe}")
sys.exit(0 if fully else 1)
PY
rc=$?

capture_status "$OUT"

status="$(results_status "$OUT" 2>/dev/null || true)"

if [[ "$status" == "UNSIGNED" || "$status" == "PARTLY_SIGNED" ]]; then
	if [[ -z "${REPRO_STORY:-}" ]]; then
		REPRO_STORY="Ran scripts/check-zone-signed.sh --role ${ROLE} against ${HOST}:${PORT} for zone ${ZONE_NAME}. AXFR coverage status was ${status}."
		if [[ "$EXPECT_SIGNING" -eq 1 ]]; then
			REPRO_STORY+=" Flag --expect-signing was set (caller expected the zone to already be under DNSSEC)."
		fi
	fi
	export REPRO_STORY
	save_broken_zone "$OUT" "$ROLE" "$AXFR_FILE" "$status"
fi

if [[ "$ROLE" == "distribution" || "$EXPECT_SIGNING" -eq 1 ]]; then
	if [[ "$status" == "UNSIGNED" ]]; then
		# Optional stack hook (BIND: inline-signing yes; KNOT: dnssec-signing on).
		if declare -F stack_confirms_signing_enabled >/dev/null 2>&1; then
			if stack_confirms_signing_enabled >"$OUT/signer-signing-enabled.txt" 2>&1; then
				log "FAIL: AXFR unsigned while signer signing is enabled"
				log "Broken zone: $OUT/broken-zone/  (also $OUT/BROKEN_ZONE.axfr)"
				log "Artifacts: $OUT"
				finish 1
			fi
		fi
	fi
fi

if [[ $rc -eq 0 ]]; then
	log "PASS: fully signed ($ROLE) — see $RESULTS"
	finish 0
fi

log "FAIL: not fully signed ($ROLE) — see $RESULTS"
if [[ -d "$OUT/broken-zone" ]]; then
	log "Broken zone: $OUT/broken-zone/  (also $OUT/BROKEN_ZONE.axfr)"
fi
log "Artifacts: $OUT"
finish 1
