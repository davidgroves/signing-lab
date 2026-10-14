#!/usr/bin/env bash
# Knot stack helpers (sources COMMON/scripts/lib-common.sh).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMMON_ROOT="$(cd "$ROOT/../COMMON" && pwd)"
cd "$ROOT"

# shellcheck disable=SC1091
source "$COMMON_ROOT/scripts/lib-common.sh"

_PRESERVE_KNOT_TAG="${KNOT_TAG-}"
[[ -n "${_PRESERVE_KNOT_TAG}" ]] && KNOT_TAG="${_PRESERVE_KNOT_TAG}"
unset _PRESERVE_KNOT_TAG
KNOT_TAG="${KNOT_TAG:-latest}"

STACK_NAME=knot
CONTAINER_PREFIX=knot

# Used by COMMON check-zone-signed.sh when AXFR is UNSIGNED.
stack_confirms_signing_enabled() {
	# On-secondary signing is configured on; confirm zone is loaded on signer.
	if knotc signer zone-status "$ZONE_NAME" >/dev/null 2>&1; then
		echo "knot dnssec-signing enabled for ${ZONE_NAME}"
		return 0
	fi
	return 1
}

# Ensure knot (uid 53) can write storage/rundir on the host bind-mounts.
prepare_runtime_dirs() {
	mkdir -p "$ROOT/zones" \
		"$ROOT/storage/primary" "$ROOT/storage/signer" "$ROOT/storage/distribution" \
		"$ROOT/rundir/primary" "$ROOT/rundir/signer" "$ROOT/rundir/distribution"
	chmod -R a+rwX "$ROOT/storage" "$ROOT/rundir" "$ROOT/zones" 2>/dev/null || true
}

compose_up() {
	prepare_runtime_dirs
	ensure_all_starter_zones
	"${COMPOSE[@]}" up -d
}

knotc() {
	local role="$1"
	shift
	docker exec "${CONTAINER_PREFIX}-${role}" knotc "$@"
}

stack_ctl() {
	# Map loosely to knotc zone-* actions: stack_ctl <role> <args...>
	knotc "$@"
}

# Map ZONE_NAME -> mode key (nsec|nsec3|nsec3optout).
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

# Target mode for NSEC↔NSEC3 flip (nsec3optout unsupported).
flip_target_mode() {
	local from="${1:-}"
	case "$from" in
		nsec) echo nsec3 ;;
		nsec3) echo nsec ;;
		*) return 1 ;;
	esac
}

# Set zone dnssec-policy via Knot dynamic config.
# Usage: set_zone_dnssec_policy <zone> <policy-id>
set_zone_dnssec_policy() {
	local zone="$1" policy="$2"
	knotc signer conf-begin
	knotc signer conf-set "zone[${zone}].dnssec-policy" "$policy"
	knotc signer conf-commit
}

# Flip active zone policy nsec↔nsec3; records FLIP_* for restore.
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
		echo "=== knotd -V ==="
		docker exec knot-signer knotd -V || true
	} >"$dir/status.txt" 2>&1 || true

	docker logs knot-primary --tail 200 >"$dir/primary.log" 2>&1 || true
	docker logs knot-signer --tail 400 >"$dir/signer.log" 2>&1 || true
	docker logs knot-distribution --tail 200 >"$dir/distribution.log" 2>&1 || true
	docker logs knot-signer --tail 400 >"$dir/signer-docker.log" 2>&1 || true
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
		distribution) container="knot-distribution" ;;
		signer) container="knot-signer" ;;
		primary) container="knot-primary" ;;
		*) container="" ;;
	esac
	if [[ -n "$container" ]]; then
		knotc "$role" zone-flush "$ZONE_NAME" 2>/dev/null || true
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
		log "dnssec-verify rc=${dv_rc} -> $dir/BROKEN_ZONE.dnssec-verify.err (${err_lines} lines)"
	fi

	_write_broken_zone_readme "$dir" "$broken_dir" "$role" "$status" "$serial" "$axfr" "$dv_rc" "$err_lines"
	log "Saved broken zone copy under $broken_dir"
}

_write_broken_zone_readme() {
	local dir="$1" broken_dir="$2" role="$3" status="$4" serial="$5" axfr="$6" dv_rc="$7" err_lines="$8"
	local story knot_ver zone_bytes results_file

	story="${REPRO_STORY:-Check via check-zone-signed.sh --role ${role}}"
	results_file="$dir/RESULTS.md"
	knot_ver="$(docker exec knot-signer knotd -V 2>/dev/null | head -n 1)" || true
	knot_ver="${knot_ver:-unknown}"
	zone_bytes=0
	[[ -f "$broken_dir/broken-zone.axfr" ]] && zone_bytes="$(wc -c <"$broken_dir/broken-zone.axfr" | tr -d ' ')"

	{
		cat <<EOF
Knot resign reproduction — broken zone capture
==============================================

Topology: UNSIGNED PRIMARY -> SIGNER (dnssec-signing on-secondary) -> DISTRIBUTION

status=${status} role=${role} zone=${ZONE_NAME} serial=${serial}
knotd: ${knot_ver}  image tag: ${KNOT_TAG}
story: ${story}
axfr_bytes: ${zone_bytes}

RESULTS.md
----------
EOF
		[[ -f "$results_file" ]] && cat "$results_file" || echo "(none)"
		echo
		echo "Signer zone-status"
		echo "------------------"
		knotc signer -e zone-status "$ZONE_NAME" 2>/dev/null || true
		cat <<EOF

dnssec-verify exit: ${dv_rc:-n/a}  stderr_lines: ${err_lines}

Run: cd KNOT-KNOT-KNOT && ./run-all.sh
EOF
	} >"$broken_dir/README.txt"
}
