#!/usr/bin/env bash
# BIND-BIND-KNOT helpers: BIND primary/signer, Knot distribution.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMMON_ROOT="$(cd "$ROOT/../COMMON" && pwd)"
cd "$ROOT"

# shellcheck disable=SC1091
source "$COMMON_ROOT/scripts/lib-common.sh"

_PRESERVE_BIND_TAG="${BIND_TAG-}"
_PRESERVE_KNOT_TAG="${KNOT_TAG-}"
[[ -n "${_PRESERVE_BIND_TAG}" ]] && BIND_TAG="${_PRESERVE_BIND_TAG}"
[[ -n "${_PRESERVE_KNOT_TAG}" ]] && KNOT_TAG="${_PRESERVE_KNOT_TAG}"
unset _PRESERVE_BIND_TAG _PRESERVE_KNOT_TAG
BIND_TAG="${BIND_TAG:-9.20}"
KNOT_TAG="${KNOT_TAG:-latest}"

STACK_NAME=bbk
CONTAINER_PREFIX=bbk
DNSSEC_VALIDATION="${DNSSEC_VALIDATION:-off}"

prepare_runtime_dirs() {
	mkdir -p "$ROOT/zones" "$ROOT/keys" \
		"$ROOT/storage/distribution" "$ROOT/rundir/distribution"
	chmod -R a+rwX "$ROOT/storage" "$ROOT/rundir" "$ROOT/zones" "$ROOT/keys" 2>/dev/null || true
}

# Install Knot distribution conf for validate-off|validate-on and refresh the service.
install_distribution_validation() {
	local v="${1:?off|on}"
	local src="$ROOT/config/distribution/knot.validate-${v}.conf"
	[[ -f "$src" ]] || die "missing $src"
	cp "$src" "$ROOT/config/distribution/knot.conf"
	DNSSEC_VALIDATION="$v"
	export DNSSEC_VALIDATION
	if [[ "$v" == "on" ]]; then
		export ALLOW_AXFR_UNAVAILABLE=1
	else
		unset ALLOW_AXFR_UNAVAILABLE || true
		export ALLOW_AXFR_UNAVAILABLE=0
	fi
	log "Installed distribution dnssec-validation=${v} (ALLOW_AXFR_UNAVAILABLE=${ALLOW_AXFR_UNAVAILABLE})"
}

compose_up() {
	prepare_runtime_dirs
	ensure_all_starter_zones
	[[ -f "$ROOT/config/distribution/knot.conf" ]] || \
		install_distribution_validation "${DNSSEC_VALIDATION:-off}"
	"${COMPOSE[@]}" up -d
}

# Restart only distribution after swapping validate conf (zones/keys stay).
restart_distribution() {
	prepare_runtime_dirs
	"${COMPOSE[@]}" up -d --force-recreate distribution
}

knotc() {
	local role="$1"
	shift
	docker exec "${CONTAINER_PREFIX}-${role}" knotc "$@"
}

# BIND rndc for primary/signer; map distribution rndc onto knotc.
rndc() {
	local role="$1"
	shift
	case "$role" in
		distribution)
			case "${1:-}" in
				retransfer)
					knotc distribution zone-retransfer "${2:-$ZONE_NAME}"
					;;
				reload|reconfig)
					knotc distribution zone-reload "${2:-$ZONE_NAME}" 2>/dev/null || true
					;;
				sync)
					knotc distribution zone-flush "${3:-${2:-$ZONE_NAME}}" 2>/dev/null || true
					;;
				*)
					knotc distribution "$@"
					;;
			esac
			;;
		*)
			docker exec "${CONTAINER_PREFIX}-${role}" rndc -c /etc/bind/rndc.conf "$@"
			;;
	esac
}

stack_confirms_signing_enabled() {
	if rndc signer zonestatus "$ZONE_NAME" 2>/dev/null | grep -qi 'inline signing: yes'; then
		echo "inline signing: yes"
		return 0
	fi
	return 1
}

stack_ctl() {
	local role="$1"
	shift
	case "$role" in
		distribution) knotc distribution "$@" ;;
		*) rndc "$role" "$@" ;;
	esac
}

SIGNER_RUNTIME_CONF="${SIGNER_RUNTIME_CONF:-/var/cache/bind/named.conf}"

zone_mode_of() {
	local z="${1:-$ZONE_NAME}" mode
	for mode in "${ALL_MODES[@]}"; do
		if [[ "${MODE_ZONE[$mode]}" == "$z" ]]; then
			echo "$mode"
			return 0
		fi
	done
	return 1
}

flip_target_mode() {
	local from="${1:-}"
	case "$from" in
		nsec) echo nsec3 ;;
		nsec3) echo nsec ;;
		*) return 1 ;;
	esac
}

set_zone_dnssec_policy() {
	local zone="$1" policy="$2"
	local conf="$SIGNER_RUNTIME_CONF"
	local zone_fqdn="${zone%.}."
	local tmp
	tmp="$(mktemp)"
	docker cp "${CONTAINER_PREFIX}-signer:${conf}" "$tmp"
	python3 - "$tmp" "$zone_fqdn" "$policy" <<'PY'
import re, sys

path, zone, policy = sys.argv[1:4]
with open(path, encoding="utf-8") as fh:
    text = fh.read()

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
with open(path, "w", encoding="utf-8") as fh:
    fh.write(new)
PY
	docker cp "$tmp" "${CONTAINER_PREFIX}-signer:${conf}"
	rm -f "$tmp"
	docker exec "${CONTAINER_PREFIX}-signer" sh -c "chown bind:bind '$conf' 2>/dev/null || true; chmod 644 '$conf'"
}

flip_zone_policy() {
	local from to from_pol to_pol
	from="$(zone_mode_of "$ZONE_NAME")" || die "flip_zone_policy: unknown zone $ZONE_NAME"
	to="$(flip_target_mode "$from")" || die "flip_zone_policy: cannot flip mode $from"
	from_pol="repro-${from}"
	to_pol="repro-${to}"
	FLIP_FROM_MODE="$from"
	FLIP_TO_MODE="$to"
	FLIP_FROM_POLICY="$from_pol"
	FLIP_TO_POLICY="$to_pol"
	export FLIP_FROM_MODE FLIP_TO_MODE FLIP_FROM_POLICY FLIP_TO_POLICY
	log "Flip dnssec-policy on ${ZONE_NAME}: ${from_pol} -> ${to_pol}"
	set_zone_dnssec_policy "$ZONE_NAME" "$to_pol"
	rndc signer reconfig || die "rndc reconfig failed after policy flip"
	rndc signer sign "$ZONE_NAME" || true
}

restore_zone_policy() {
	local pol="${FLIP_FROM_POLICY:-}"
	[[ -n "$pol" ]] || return 0
	log "Restore dnssec-policy on ${ZONE_NAME}: ${pol}"
	set_zone_dnssec_policy "$ZONE_NAME" "$pol" || true
	rndc signer reconfig || true
}

capture_status() {
	local dir="$1"
	mkdir -p "$dir"
	{
		echo "=== signer zonestatus ==="
		rndc signer zonestatus "$ZONE_NAME" || true
		echo
		echo "=== signer signing -list ==="
		rndc signer signing -list "$ZONE_NAME" || true
		echo
		echo "=== distribution zone-status ==="
		knotc distribution zone-status "$ZONE_NAME" || true
		echo
		echo "=== dnssec-validation ==="
		echo "DNSSEC_VALIDATION=${DNSSEC_VALIDATION:-}"
		echo
		echo "=== serials ==="
		echo -n "primary: "; soa_serial "$PRIMARY_HOST" "$PRIMARY_PORT" || echo "?"
		echo -n "signer: "; soa_serial "$SIGNER_HOST" "$SIGNER_PORT" || echo "?"
		echo -n "distribution: "; soa_serial "$DISTRIBUTION_HOST" "$DISTRIBUTION_PORT" || echo "?"
	} >"$dir/status.txt" 2>&1 || true

	docker logs "${CONTAINER_PREFIX}-primary" --tail 200 >"$dir/primary.log" 2>&1 || true
	docker logs "${CONTAINER_PREFIX}-signer" --tail 400 >"$dir/signer.log" 2>&1 || true
	docker logs "${CONTAINER_PREFIX}-distribution" --tail 200 >"$dir/distribution.log" 2>&1 || true
	docker exec "${CONTAINER_PREFIX}-signer" sh -c 'tail -n 200 /var/log/bind/dnssec.log 2>/dev/null || true' \
		>"$dir/signer-dnssec.log" 2>&1 || true
	docker exec "${CONTAINER_PREFIX}-signer" sh -c 'tail -n 200 /var/log/bind/xfer.log 2>/dev/null || true' \
		>"$dir/signer-xfer.log" 2>&1 || true
}

save_broken_zone() {
	local dir="$1" role="$2" axfr="$3" status="${4:-BROKEN}"
	local serial broken_dir verify_target dv_rc err_lines

	mkdir -p "$dir"
	broken_dir="$dir/broken-zone"
	mkdir -p "$broken_dir"

	serial="$(sed -n 's/^| SOA serial | `\([^`]*\)` .*/\1/p' "$dir/RESULTS.md" 2>/dev/null | head -n 1 || true)"
	[[ -n "$serial" && "$serial" != "None" ]] || \
		serial="$(soa_serial "$SIGNER_HOST" "$SIGNER_PORT" 2>/dev/null || echo unknown)"

	if [[ -e "$axfr" ]]; then
		axfr="$(readlink -f "$axfr" || realpath "$axfr" || echo "$axfr")"
	fi
	if [[ -f "$axfr" && -s "$axfr" ]]; then
		cp -f "$axfr" "$broken_dir/broken-zone.axfr"
		cp -f "$axfr" "$broken_dir/broken-zone-${role}-serial${serial}.axfr"
		cp -f "$axfr" "$dir/BROKEN_ZONE.axfr"
	fi

	verify_target="$dir/BROKEN_ZONE.axfr"
	dv_rc=""
	err_lines=0
	if [[ -s "$verify_target" ]]; then
		dv_rc=0
		_run_dnssec_verify "$ZONE_NAME" "$verify_target" \
			"$dir/BROKEN_ZONE.dnssec-verify.out" \
			"$dir/BROKEN_ZONE.dnssec-verify.err" || dv_rc=$?
		err_lines="$(wc -l <"$dir/BROKEN_ZONE.dnssec-verify.err" 2>/dev/null | tr -d ' ' || echo 0)"
	fi

	{
		cat <<EOF
BIND-BIND-KNOT broken zone capture
==================================
Topology: BIND primary -> BIND signer (inline-signing) -> Knot distribution
dnssec-validation (distribution): ${DNSSEC_VALIDATION:-unknown}
status=${status} role=${role} zone=${ZONE_NAME} serial=${serial}
story: ${REPRO_STORY:-check-zone-signed}
EOF
		[[ -f "$dir/RESULTS.md" ]] && cat "$dir/RESULTS.md"
	} >"$broken_dir/README.txt"
	log "Saved broken zone copy under $broken_dir"
}
