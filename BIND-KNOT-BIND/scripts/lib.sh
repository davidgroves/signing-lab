#!/usr/bin/env bash
# BIND-KNOT-BIND helpers: BIND primary/distribution, Knot signer.
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

STACK_NAME=bkb
CONTAINER_PREFIX=bkb

prepare_runtime_dirs() {
	mkdir -p "$ROOT/zones" "$ROOT/keys" \
		"$ROOT/storage/signer" "$ROOT/rundir/signer"
	chmod -R a+rwX "$ROOT/storage" "$ROOT/rundir" "$ROOT/zones" "$ROOT/keys" 2>/dev/null || true
}

# Install BIND distribution conf for validate-off|validate-on (dnssec-validation no|yes).
install_distribution_validation() {
	local v="${1:?off|on}"
	local src="$ROOT/config/distribution/named.validate-${v}.conf"
	[[ -f "$src" ]] || die "missing $src"
	cp "$src" "$ROOT/config/distribution/named.conf"
	DNSSEC_VALIDATION="$v"
	export DNSSEC_VALIDATION
	# BIND secondary still serves AXFR regardless; keep unavailable=off for both.
	unset ALLOW_AXFR_UNAVAILABLE || true
	export ALLOW_AXFR_UNAVAILABLE=0
	log "Installed distribution dnssec-validation=${v}"
}

compose_up() {
	prepare_runtime_dirs
	ensure_all_starter_zones
	[[ -f "$ROOT/config/distribution/named.conf" ]] || \
		install_distribution_validation "${DNSSEC_VALIDATION:-off}"
	"${COMPOSE[@]}" up -d
}

knotc() {
	local role="$1"
	shift
	docker exec "${CONTAINER_PREFIX}-${role}" knotc "$@"
}

# BIND rndc for primary/distribution; map signer rndc calls onto knotc.
rndc() {
	local role="$1"
	shift
	case "$role" in
		signer)
			case "${1:-}" in
				sign)
					knotc signer zone-sign "${2:-$ZONE_NAME}"
					;;
				loadkeys)
					return 0
					;;
				signing)
					# rndc signing -list ZONE -> knotc zone-status
					knotc signer zone-status "${3:-${2:-$ZONE_NAME}}"
					;;
				zonestatus)
					knotc signer zone-status "${2:-$ZONE_NAME}"
					;;
				reconfig|reload)
					return 0
					;;
				sync)
					knotc signer zone-flush "${3:-${2:-$ZONE_NAME}}" 2>/dev/null || true
					;;
				*)
					knotc signer "$@"
					;;
			esac
			;;
		*)
			docker exec "${CONTAINER_PREFIX}-${role}" rndc -c /etc/bind/rndc.conf "$@"
			;;
	esac
}

stack_confirms_signing_enabled() {
	if knotc signer zone-status "$ZONE_NAME" >/dev/null 2>&1; then
		echo "knot dnssec-signing enabled for ${ZONE_NAME}"
		return 0
	fi
	return 1
}

stack_ctl() {
	local role="$1"
	shift
	case "$role" in
		signer) knotc signer "$@" ;;
		*) rndc "$role" "$@" ;;
	esac
}

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
	knotc signer conf-begin
	knotc signer conf-set "zone[${zone}].dnssec-policy" "$policy"
	knotc signer conf-commit
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
	knotc signer zone-sign "$ZONE_NAME" || true
}

restore_zone_policy() {
	local pol="${FLIP_FROM_POLICY:-}"
	[[ -n "$pol" ]] || return 0
	log "Restore dnssec-policy on ${ZONE_NAME}: ${pol}"
	set_zone_dnssec_policy "$ZONE_NAME" "$pol" || true
}

capture_status() {
	local dir="$1"
	mkdir -p "$dir"
	{
		echo "=== signer zone-status ==="
		knotc signer zone-status "$ZONE_NAME" || true
		echo
		echo "=== signer zone-status +extended ==="
		knotc signer -e zone-status "$ZONE_NAME" || true
		echo
		echo "=== serials ==="
		echo -n "primary: "; soa_serial "$PRIMARY_HOST" "$PRIMARY_PORT" || echo "?"
		echo -n "signer: "; soa_serial "$SIGNER_HOST" "$SIGNER_PORT" || echo "?"
		echo -n "distribution: "; soa_serial "$DISTRIBUTION_HOST" "$DISTRIBUTION_PORT" || echo "?"
		echo
		echo "=== dnssec-validation (distribution) ==="
		echo "${DNSSEC_VALIDATION:-unknown}"
		echo
		echo "=== knotd -V ==="
		docker exec "${CONTAINER_PREFIX}-signer" knotd -V || true
	} >"$dir/status.txt" 2>&1 || true

	docker logs "${CONTAINER_PREFIX}-primary" --tail 200 >"$dir/primary.log" 2>&1 || true
	docker logs "${CONTAINER_PREFIX}-signer" --tail 400 >"$dir/signer.log" 2>&1 || true
	docker logs "${CONTAINER_PREFIX}-distribution" --tail 200 >"$dir/distribution.log" 2>&1 || true
	docker logs "${CONTAINER_PREFIX}-signer" --tail 400 >"$dir/signer-docker.log" 2>&1 || true
}

save_broken_zone() {
	local dir="$1" role="$2" axfr="$3" status="${4:-BROKEN}"
	local serial broken_dir verify_target dv_rc err_lines container

	mkdir -p "$dir"
	broken_dir="$dir/broken-zone"
	mkdir -p "$broken_dir"

	serial="$(sed -n 's/^| SOA serial | `\([^`]*\)` .*/\1/p' "$dir/RESULTS.md" 2>/dev/null | head -n 1 || true)"
	if [[ -z "$serial" || "$serial" == "None" ]]; then
		serial="$(soa_serial "$SIGNER_HOST" "$SIGNER_PORT" 2>/dev/null || echo unknown)"
	fi

	if [[ -e "$axfr" ]]; then
		axfr="$(readlink -f "$axfr" || realpath "$axfr" || echo "$axfr")"
	fi
	if [[ -f "$axfr" && -s "$axfr" ]]; then
		if [[ "$axfr" != "$(readlink -f "$broken_dir/broken-zone.axfr" 2>/dev/null || true)" ]]; then
			cp -f "$axfr" "$broken_dir/broken-zone.axfr"
		fi
		cp -f "$axfr" "$broken_dir/broken-zone-${role}-serial${serial}.axfr"
	fi

	case "$role" in
		distribution) container="${CONTAINER_PREFIX}-distribution" ;;
		signer) container="${CONTAINER_PREFIX}-signer" ;;
		primary) container="${CONTAINER_PREFIX}-primary" ;;
		*) container="" ;;
	esac
	if [[ -n "$container" && "$role" == "signer" ]]; then
		knotc signer zone-flush "$ZONE_NAME" 2>/dev/null || true
		docker exec "$container" sh -c "ls -la /storage 2>/dev/null | head" \
			>"$broken_dir/storage-listing.txt" 2>&1 || true
	fi

	if [[ -s "$broken_dir/broken-zone.axfr" ]]; then
		cp -f "$broken_dir/broken-zone.axfr" "$dir/BROKEN_ZONE.axfr"
	fi

	verify_target="$dir/BROKEN_ZONE.axfr"
	[[ -s "$verify_target" ]] || verify_target="$broken_dir/broken-zone.axfr"
	dv_rc=""
	err_lines=0
	if [[ -s "$verify_target" ]]; then
		dv_rc=0
		_run_dnssec_verify "$ZONE_NAME" "$verify_target" \
			"$dir/BROKEN_ZONE.dnssec-verify.out" \
			"$dir/BROKEN_ZONE.dnssec-verify.err" || dv_rc=$?
		cp -f "$dir/BROKEN_ZONE.dnssec-verify.out" "$broken_dir/dnssec-verify.out" 2>/dev/null || true
		cp -f "$dir/BROKEN_ZONE.dnssec-verify.err" "$broken_dir/dnssec-verify.err" 2>/dev/null || true
		[[ -f "$dir/BROKEN_ZONE.dnssec-verify.err" ]] && \
			err_lines="$(wc -l <"$dir/BROKEN_ZONE.dnssec-verify.err" | tr -d ' ')"
		{
			echo "command: dnssec-verify -o ${ZONE_NAME} BROKEN_ZONE.axfr"
			echo "exit_code: ${dv_rc}"
			echo "stderr_lines: ${err_lines}"
			head -n 40 "$dir/BROKEN_ZONE.dnssec-verify.err" 2>/dev/null || true
		} >"$dir/BROKEN_ZONE.dnssec-verify.log"
	fi

	{
		cat <<EOF
BIND-KNOT-BIND broken zone capture
==================================
Topology: BIND primary -> Knot signer (dnssec-signing) -> BIND distribution
status=${status} role=${role} zone=${ZONE_NAME} serial=${serial}
story: ${REPRO_STORY:-check-zone-signed}
EOF
		[[ -f "$dir/RESULTS.md" ]] && cat "$dir/RESULTS.md"
	} >"$broken_dir/README.txt"
	log "Saved broken zone copy under $broken_dir"
}
