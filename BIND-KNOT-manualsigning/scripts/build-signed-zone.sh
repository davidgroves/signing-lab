#!/usr/bin/env bash
# Build a small hand-signed NSEC3 zone (KSK + ZSK) for manual.test.example.
# Uses the BIND image's dnssec-keygen / dnssec-signzone.
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

ZONE_NAME="${ZONE_NAME:-manual.test.example}"
ZONE="${ZONE_NAME%.}"
KEYS_DIR="$ROOT/keys"
ZONES_DIR="$ROOT/zones"
UNSIGNED="$ZONES_DIR/db.${ZONE}.unsigned"
SIGNED="$ZONES_DIR/db.${ZONE}.signed"
META="$KEYS_DIR/zsk-withdraw-meta.txt"

mkdir -p "$KEYS_DIR" "$ZONES_DIR"
chmod -R a+rwX "$KEYS_DIR" "$ZONES_DIR" 2>/dev/null || true

log "Clear previous keys/zone material for ${ZONE}"
docker run --rm -v "$KEYS_DIR:/keys:rw" -v "$ZONES_DIR:/zones:rw" --user 0 alpine:3.20 \
	sh -c "rm -f /keys/K${ZONE}.* /keys/*.name /keys/zsk-withdraw-meta.txt /zones/db.${ZONE}.* /zones/dsset-${ZONE}. /zones/*.jnl" \
	2>/dev/null || true

log "Generate KSK + ZSK (ECDSAP256SHA256)"
KSK_BASE="$(
	docker run --rm -v "$KEYS_DIR:/keys:rw" -w /keys --user 0 \
		--entrypoint dnssec-keygen \
		"internetsystemsconsortium/bind9:${BIND_TAG}" \
		-a ECDSAP256SHA256 -f KSK "$ZONE" | tr -d '[:space:]'
)"
ZSK_BASE="$(
	docker run --rm -v "$KEYS_DIR:/keys:rw" -w /keys --user 0 \
		--entrypoint dnssec-keygen \
		"internetsystemsconsortium/bind9:${BIND_TAG}" \
		-a ECDSAP256SHA256 "$ZONE" | tr -d '[:space:]'
)"
docker run --rm -v "$KEYS_DIR:/keys:rw" --user 0 alpine:3.20 \
	chmod -R a+rwX /keys >/dev/null
echo "$KSK_BASE" >"$KEYS_DIR/ksk.name"
echo "$ZSK_BASE" >"$KEYS_DIR/zsk.name"
[[ -f "$KEYS_DIR/${KSK_BASE}.key" && -f "$KEYS_DIR/${ZSK_BASE}.key" ]] \
	|| die "key generation failed (ksk=${KSK_BASE} zsk=${ZSK_BASE})"

# ZSK DNSKEY rdata for nsupdate delete (flags proto alg key).
ZSK_DNSKEY_LINE="$(
	python3 - "$KEYS_DIR/${ZSK_BASE}.key" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
# Join continuation lines after stripping comments.
lines = []
for raw in text.splitlines():
    s = raw.split(";", 1)[0].rstrip()
    if not s:
        continue
    lines.append(s)
blob = " ".join(lines)
m = re.search(
    r"\bDNSKEY\s+(\d+)\s+(\d+)\s+(\d+)\s+([A-Za-z0-9+/= \t]+)",
    blob,
    re.I,
)
if not m:
    raise SystemExit("no DNSKEY in key file")
flags, proto, alg, key = m.groups()
key = re.sub(r"\s+", "", key)
print(flags, proto, alg, key)
PY
)"
read -r ZSK_FLAGS ZSK_PROTO ZSK_ALG ZSK_KEYMATERIAL <<<"$ZSK_DNSKEY_LINE"
[[ -n "${ZSK_KEYMATERIAL:-}" ]] || die "could not parse ZSK DNSKEY"

log "Write unsigned zone (DNSKEYs added by dnssec-signzone -S)"
cat >"$UNSIGNED" <<EOF
\$TTL 300
\$ORIGIN ${ZONE}.
@	300	IN	SOA	ns1.${ZONE}. hostmaster.${ZONE}. (
			1          ; serial
			300        ; refresh
			60         ; retry
			3600       ; expire
			300        ; minimum
			)
@	300	IN	NS	ns1.${ZONE}.
ns1	300	IN	A	172.30.57.10
www	300	IN	A	192.0.2.80
app	300	IN	A	192.0.2.81
txt1	300	IN	TXT	"manual-signing baseline"
EOF

log "Sign with NSEC3 (iterations 0, no opt-out)"
docker run --rm \
	-v "$KEYS_DIR:/keys:rw" \
	-v "$ZONES_DIR:/zones:rw" \
	-w /zones \
	--user 0 \
	--entrypoint dnssec-signzone \
	"internetsystemsconsortium/bind9:${BIND_TAG}" \
	-S -K /keys -3 - -H 0 -o "$ZONE" -f "db.${ZONE}.signed" "db.${ZONE}.unsigned"
docker run --rm -v "$ZONES_DIR:/zones:rw" -v "$KEYS_DIR:/keys:rw" --user 0 alpine:3.20 \
	chmod -R a+rwX /zones /keys >/dev/null

[[ -f "$SIGNED" ]] || die "signed zone not written to $SIGNED"

{
	echo "zone=${ZONE}"
	echo "ksk_base=${KSK_BASE}"
	echo "zsk_base=${ZSK_BASE}"
	echo "zsk_flags=${ZSK_FLAGS}"
	echo "zsk_proto=${ZSK_PROTO}"
	echo "zsk_alg=${ZSK_ALG}"
	echo "zsk_keymaterial=${ZSK_KEYMATERIAL}"
	echo "signed_file=${SIGNED}"
} | tee "$META"

log "Built ${SIGNED} ($(wc -l <"$SIGNED") lines); ZSK flags=${ZSK_FLAGS} alg=${ZSK_ALG}"
# Sanity: NSEC3 + both roles present
grep -q NSEC3PARAM "$SIGNED" || die "signed zone missing NSEC3PARAM"
grep -q 'DNSKEY[[:space:]]*257' "$SIGNED" || grep -q 'DNSKEY 257' "$SIGNED" || \
	grep -E 'DNSKEY.*257' "$SIGNED" >/dev/null || die "signed zone missing KSK DNSKEY"
grep -qE 'DNSKEY.*256' "$SIGNED" || die "signed zone missing ZSK DNSKEY"
