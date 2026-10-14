#!/usr/bin/env bash
# BIND stack helpers (sources COMMON/scripts/lib-common.sh).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMMON_ROOT="$(cd "$ROOT/../COMMON" && pwd)"
cd "$ROOT"

# shellcheck disable=SC1091
source "$COMMON_ROOT/scripts/lib-common.sh"

_PRESERVE_BIND_TAG="${BIND_TAG-}"
[[ -n "${_PRESERVE_BIND_TAG}" ]] && BIND_TAG="${_PRESERVE_BIND_TAG}"
unset _PRESERVE_BIND_TAG
BIND_TAG="${BIND_TAG:-9.20}"

STACK_NAME=bind
CONTAINER_PREFIX=bind

rndc() {
	local role="$1"
	shift
	docker exec "${CONTAINER_PREFIX}-${role}" rndc -c /etc/bind/rndc.conf "$@"
}
# Used by COMMON check-zone-signed.sh when AXFR is UNSIGNED.
stack_confirms_signing_enabled() {
	if rndc signer zonestatus "$ZONE_NAME" 2>/dev/null | grep -qi 'inline signing: yes'; then
		echo "inline signing: yes"
		return 0
	fi
	return 1
}

# Stack control helper used by scenarios that may be ported across stacks.
stack_ctl() {
	rndc "$@"
}

# Writable runtime named.conf used by the signer (see named-entrypoint.sh).
SIGNER_RUNTIME_CONF="${SIGNER_RUNTIME_CONF:-/var/cache/bind/named.conf}"

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

# Set dnssec-policy for one zone block inside the signer runtime named.conf.
# Usage: set_zone_dnssec_policy <zone> <policy-id>   e.g. repro-nsec / repro-nsec3
set_zone_dnssec_policy() {
	local zone="$1" policy="$2"
	local conf="$SIGNER_RUNTIME_CONF"
	local zone_fqdn="${zone%.}."
	local tmp
	tmp="$(mktemp)"
	# Host python3 (BIND image has no python); push edited conf back.
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
	# named runs as bind; docker cp often leaves root-owned files.
	docker exec "${CONTAINER_PREFIX}-signer" sh -c "chown bind:bind '$conf' 2>/dev/null || true; chmod 644 '$conf'"
}

# Flip active zone policy nsec<->nsec3; records FLIP_* for restore.
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
		echo "=== serials ==="
		echo -n "primary: "; soa_serial "$PRIMARY_HOST" "$PRIMARY_PORT" || echo "?"
		echo -n "signer: "; soa_serial "$SIGNER_HOST" "$SIGNER_PORT" || echo "?"
		echo -n "distribution: "; soa_serial "$DISTRIBUTION_HOST" "$DISTRIBUTION_PORT" || echo "?"
	} >"$dir/status.txt" 2>&1 || true

	docker logs bind-primary --tail 200 >"$dir/primary.log" 2>&1 || true
	docker logs bind-signer --tail 400 >"$dir/signer.log" 2>&1 || true
	docker logs bind-distribution --tail 200 >"$dir/distribution.log" 2>&1 || true
	docker exec bind-signer sh -c 'tail -n 200 /var/log/bind/dnssec.log 2>/dev/null || true' \
		>"$dir/signer-dnssec.log" 2>&1 || true
	docker exec bind-signer sh -c 'tail -n 200 /var/log/bind/xfer.log 2>/dev/null || true' \
		>"$dir/signer-xfer.log" 2>&1 || true
	docker logs bind-signer --tail 400 >"$dir/signer-docker.log" 2>&1 || true
}

save_broken_zone() {
	local dir="$1" role="$2" axfr="$3" status="${4:-BROKEN}"
	local serial zone_path container broken_dir verify_target dv_rc err_lines

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
		distribution) container="bind-distribution"; zone_path="/var/lib/bind/db.${ZONE_NAME}" ;;
		signer) container="bind-signer"; zone_path="/var/lib/bind/db.${ZONE_NAME}" ;;
		primary) container="bind-primary"; zone_path="/var/lib/bind/zones/db.${ZONE_NAME}" ;;
		*) container=""; zone_path="" ;;
	esac

	if [[ -n "$container" ]]; then
		rndc "$role" sync -clean "$ZONE_NAME" 2>/dev/null || rndc "$role" sync "$ZONE_NAME" 2>/dev/null || true
		docker cp "${container}:${zone_path}" "$broken_dir/db.${ZONE_NAME}.ondisk" 2>/dev/null || true
		docker cp "${container}:${zone_path}.jnl" "$broken_dir/db.${ZONE_NAME}.ondisk.jnl" 2>/dev/null || true
		if [[ "$role" == "signer" ]]; then
			docker cp "${container}:${zone_path}.signed" "$broken_dir/db.${ZONE_NAME}.signed.ondisk" 2>/dev/null || true
			docker cp "${container}:${zone_path}.signed.jnl" "$broken_dir/db.${ZONE_NAME}.signed.ondisk.jnl" 2>/dev/null || true
		fi
		if [[ -f "$broken_dir/db.${ZONE_NAME}.ondisk" ]]; then
			docker exec "$container" named-checkzone -D -f raw -o - "$ZONE_NAME" "$zone_path" \
				>"$broken_dir/db.${ZONE_NAME}.ondisk.txt" 2>"$broken_dir/named-checkzone.err" || true
		fi
		if [[ -f "$broken_dir/db.${ZONE_NAME}.signed.ondisk" ]]; then
			docker exec "$container" named-checkzone -D -f raw -o - "$ZONE_NAME" "${zone_path}.signed" \
				>"$broken_dir/db.${ZONE_NAME}.signed.ondisk.txt" 2>>"$broken_dir/named-checkzone.err" || true
		fi
	fi

	if [[ -s "$broken_dir/broken-zone.axfr" ]]; then
		cp -f "$broken_dir/broken-zone.axfr" "$dir/BROKEN_ZONE.axfr"
	fi

	verify_target="$dir/BROKEN_ZONE.axfr"
	if [[ ! -s "$verify_target" ]]; then
		verify_target="$broken_dir/broken-zone.axfr"
	fi
	dv_rc=""
	err_lines=0
	if [[ -s "$verify_target" ]]; then
		dv_rc=0
		_run_dnssec_verify "$ZONE_NAME" "$verify_target" \
			"$dir/BROKEN_ZONE.dnssec-verify.out" \
			"$dir/BROKEN_ZONE.dnssec-verify.err" || dv_rc=$?
		cp -f "$dir/BROKEN_ZONE.dnssec-verify.out" "$broken_dir/dnssec-verify.out" 2>/dev/null || true
		cp -f "$dir/BROKEN_ZONE.dnssec-verify.err" "$broken_dir/dnssec-verify.err" 2>/dev/null || true
		if [[ -f "$dir/BROKEN_ZONE.dnssec-verify.err" ]]; then
			err_lines="$(wc -l <"$dir/BROKEN_ZONE.dnssec-verify.err" | tr -d ' ')"
		fi
		{
			echo "command: dnssec-verify -o ${ZONE_NAME} BROKEN_ZONE.axfr"
			echo "exit_code: ${dv_rc}"
			echo "stderr_lines: ${err_lines}"
			echo "--- stderr (first 40 lines) ---"
			head -n 40 "$dir/BROKEN_ZONE.dnssec-verify.err" 2>/dev/null || true
			if [[ "${err_lines}" -gt 40 ]]; then
				echo "..."
				echo "(full errors in BROKEN_ZONE.dnssec-verify.err)"
			fi
			echo "--- stdout ---"
			cat "$dir/BROKEN_ZONE.dnssec-verify.out" 2>/dev/null || true
		} >"$dir/BROKEN_ZONE.dnssec-verify.log"
		log "dnssec-verify rc=${dv_rc} -> $dir/BROKEN_ZONE.dnssec-verify.err (${err_lines} lines)"
	else
		log "WARN: no AXFR to dnssec-verify under $dir"
	fi

	_write_broken_zone_readme "$dir" "$broken_dir" "$role" "$status" "$serial" "$axfr" "$dv_rc" "$err_lines"
	log "Saved broken zone copy under $broken_dir"
}

_write_broken_zone_readme() {
	local dir="$1" broken_dir="$2" role="$3" status="$4" serial="$5" axfr="$6" dv_rc="$7" err_lines="$8"
	local story bind_ver zone_bytes primary_serial signer_serial dist_serial results_file

	story="${REPRO_STORY:-Check via check-zone-signed.sh --role ${role}}"
	results_file="$dir/RESULTS.md"
	bind_ver="$(docker exec bind-signer named -V 2>/dev/null | head -n 1)" || true
	bind_ver="${bind_ver:-unknown}"
	zone_bytes=0
	[[ -f "$broken_dir/broken-zone.axfr" ]] && zone_bytes="$(wc -c <"$broken_dir/broken-zone.axfr" | tr -d ' ')"
	primary_serial="$(soa_serial "$PRIMARY_HOST" "$PRIMARY_PORT" 2>/dev/null || echo "?")"
	signer_serial="$(soa_serial "$SIGNER_HOST" "$SIGNER_PORT" 2>/dev/null || echo "?")"
	dist_serial="$(soa_serial "$DISTRIBUTION_HOST" "$DISTRIBUTION_PORT" 2>/dev/null || echo "?")"

	{
		cat <<EOF
BIND resign reproduction — broken zone capture
==============================================

What this is
------------
This directory was created because the lab found that a DNS server in the
UNSIGNED PRIMARY -> SIGNER (inline-signing) -> DISTRIBUTION path served a zone
that was ${status} (missing or incomplete DNSSEC signatures).

Topology
--------
  primary      (unsigned hidden primary)     ${PRIMARY_HOST}:${PRIMARY_PORT} / 172.30.53.10
       |  AXFR/IXFR (unsigned)
       v
  signer       (secondary + dnssec-policy     ${SIGNER_HOST}:${SIGNER_PORT} / 172.30.53.20
               + inline-signing yes)
       |  AXFR/IXFR (expected: fully signed)
       v
  distribution (secondary from signer)        ${DISTRIBUTION_HOST}:${DISTRIBUTION_PORT} / 172.30.53.30

What the test did
-----------------
${story}

At capture time role "${role}" for zone "${ZONE_NAME}" was classified as ${status}.

Environment
-----------
captured_at_utc:     $(date -u +%Y-%m-%dT%H:%M:%SZ)
BIND image tag:      ${BIND_TAG:-9.20}
named -V (signer):   ${bind_ver}
zone:                ${ZONE_NAME}
checked_role:        ${role}
status:              ${status}
axfr_soa_serial:     ${serial}
axfr_bytes:          ${zone_bytes}
axfr_source_path:    ${axfr}
artifact_dir:        ${dir}

SOA serials at capture (live queries)
-------------------------------------
primary:       ${primary_serial}
signer:        ${signer_serial}
distribution:  ${dist_serial}

RESULTS.md (RRSIG coverage)
---------------------------
EOF
		if [[ -f "$results_file" ]]; then
			cat "$results_file"
		else
			echo "(RESULTS.md not present)"
		fi

		cat <<EOF

Signer DNSSEC state (rndc)
--------------------------
EOF
		rndc signer zonestatus "$ZONE_NAME" 2>/dev/null || echo "(rndc zonestatus unavailable)"
		echo
		rndc signer signing -list "$ZONE_NAME" 2>/dev/null || echo "(rndc signing -list unavailable)"

		cat <<EOF

dnssec-verify
-------------
command:     dnssec-verify -o ${ZONE_NAME} BROKEN_ZONE.axfr
exit_code:   ${dv_rc:-n/a}
stderr_lines:${err_lines}

How this lab is run
-------------------
  cd BIND-BIND-BIND && ./run-all.sh
  ZONESIZE=1024 ./run-all.sh
EOF
	} >"$broken_dir/README.txt"
}
