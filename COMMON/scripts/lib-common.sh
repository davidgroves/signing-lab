#!/usr/bin/env bash
# Stack-agnostic helpers shared by scenario stack directories.
# Sourced from each stack's scripts/lib.sh after ROOT / COMMON_ROOT are set.
set -euo pipefail

: "${ROOT:?lib-common.sh requires ROOT (stack root)}"
: "${COMMON_ROOT:?lib-common.sh requires COMMON_ROOT}"

COMMON_ZONES="${COMMON_ZONES:-$COMMON_ROOT/zones}"
ZONES_DIR="${ZONES_DIR:-$ROOT/zones}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-$ROOT/artifacts}"

# Preserve caller exports so .env does not clobber ZONE_NAME / MODES / etc.
_PRESERVE_ZONE_NAME="${ZONE_NAME-}"
_PRESERVE_ZONE_FILE="${ZONE_FILE-}"
_PRESERVE_MODES="${MODES-}"
_PRESERVE_ZONESIZE="${ZONESIZE-}"

if [[ -f "$ROOT/.env" ]]; then
	# shellcheck disable=SC1091
	set -a
	source "$ROOT/.env"
	set +a
fi

[[ -n "${_PRESERVE_ZONE_NAME}" ]] && ZONE_NAME="${_PRESERVE_ZONE_NAME}"
[[ -n "${_PRESERVE_ZONE_FILE}" ]] && ZONE_FILE="${_PRESERVE_ZONE_FILE}"
[[ -n "${_PRESERVE_MODES}" ]] && MODES="${_PRESERVE_MODES}"
[[ -n "${_PRESERVE_ZONESIZE}" ]] && ZONESIZE="${_PRESERVE_ZONESIZE}"
unset _PRESERVE_ZONE_NAME _PRESERVE_ZONE_FILE _PRESERVE_MODES _PRESERVE_ZONESIZE

declare -A MODE_ZONE=(
	[nsec]=nsec.test.example
	[nsec3]=nsec3.test.example
	[nsec3optout]=nsec3optout.test.example
)
ALL_MODES=(nsec nsec3 nsec3optout)

ZONE_NAME="${ZONE_NAME:-nsec.test.example}"
ZONE_FILE="${ZONE_FILE:-db.${ZONE_NAME}}"
PRIMARY_PORT="${PRIMARY_PORT:-15353}"
SIGNER_PORT="${SIGNER_PORT:-15354}"
DISTRIBUTION_PORT="${DISTRIBUTION_PORT:-15355}"

PRIMARY_HOST="${PRIMARY_HOST:-127.0.0.1}"
SIGNER_HOST="${SIGNER_HOST:-127.0.0.1}"
DISTRIBUTION_HOST="${DISTRIBUTION_HOST:-127.0.0.1}"

COMPOSE=(docker compose --env-file "$ROOT/.env")

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { log "ERROR: $*"; exit 1; }

# Count scenarios for modes × validation passes (BBK uses passes=2).
# Usage: count_battery_scenarios <passes> mode [mode...]
count_battery_scenarios() {
	local passes="${1:?}"
	shift
	local n=0 p mode
	for ((p = 0; p < passes; p++)); do
		for mode in "$@"; do
			n=$((n + 4)) # initial-sign reload-resign serial-bump force-transfer
			case "$mode" in
				nsec|nsec3) n=$((n + 1)) ;; # nsec-flip-transfer
			esac
		done
	done
	echo "$n"
}

# Optional GLOBAL_TEST_OFFSET / GLOBAL_TEST_TOTAL (set by root ./run-all.sh all).
init_test_progress() {
	local local_total="${1:?}"
	TEST_PROGRESS_NUM=0
	TEST_PROGRESS_BASE="${GLOBAL_TEST_OFFSET:-0}"
	if [[ -n "${GLOBAL_TEST_TOTAL:-}" ]]; then
		TEST_PROGRESS_TOTAL="$GLOBAL_TEST_TOTAL"
	else
		TEST_PROGRESS_TOTAL="$local_total"
	fi
}

announce_running_test() {
	local name="${1:?}"
	TEST_PROGRESS_NUM=$((TEST_PROGRESS_NUM + 1))
	local cur=$((TEST_PROGRESS_BASE + TEST_PROGRESS_NUM))
	local tot="${TEST_PROGRESS_TOTAL:?}"
	printf '\n'
	printf '%s\n' '***************************'
	printf '*** RUNNING TEST %s/%s ***\n' "$cur" "$tot"
	printf '%s\n' '***************************'
	log ">>>> $name"
}

set_zone_mode() {
	local mode="$1"
	local z="${MODE_ZONE[$mode]:-}"
	[[ -n "$z" ]] || die "unknown DNSSEC mode: $mode (expected: ${ALL_MODES[*]})"
	ZONE_NAME="$z"
	ZONE_FILE="db.${ZONE_NAME}"
	export ZONE_NAME ZONE_FILE
}

ensure_starter_zone() {
	local zone="${1:-$ZONE_NAME}"
	local dest="$ZONES_DIR/db.${zone}"
	local starter="$COMMON_ZONES/db.${zone}.starter"
	mkdir -p "$ZONES_DIR"
	if [[ ! -f "$dest" ]]; then
		[[ -f "$starter" ]] || die "missing $dest and $starter"
		cp "$starter" "$dest"
		log "Installed starter zone -> $dest"
	fi
}

ensure_all_starter_zones() {
	local mode
	for mode in "${ALL_MODES[@]}"; do
		ensure_starter_zone "${MODE_ZONE[$mode]}"
	done
}

generate_all_zones() {
	local size_mb="$1" serial="${2:-1}"
	local mode zone
	mkdir -p "$ZONES_DIR"
	for mode in "${ALL_MODES[@]}"; do
		zone="${MODE_ZONE[$mode]}"
		log "Generating ${size_mb} MiB zone ${zone} (mode=${mode})"
		python3 "$COMMON_ROOT/scripts/generate-zone.py" \
			--size-mb "$size_mb" --serial "$serial" --zone "$zone" \
			--output "$ZONES_DIR/db.${zone}"
	done
}

compose_up() {
	ensure_all_starter_zones
	"${COMPOSE[@]}" up -d
}

# Tear down volumes and bring the stack back so signer/distribution start from
# an unsigned transfer again. Required between scenarios/modes: a shared stack
# lets sibling zones finish signing in the background and produces false PASSes.
compose_fresh() {
	log "Fresh stack (compose down -v + up) — isolate mid-sign race for ${ZONE_NAME}"
	"${COMPOSE[@]}" down -v 2>/dev/null || true
	compose_up
}

compose_down() {
	"${COMPOSE[@]}" down
}

dig_at() {
	local host="$1" port="$2"
	shift 2
	dig @"$host" -p "$port" "$@"
}

soa_serial() {
	local host="$1" port="$2"
	dig_at "$host" "$port" "$ZONE_NAME" SOA +short | awk '{print $3}'
}

zone_loaded() {
	local host="$1" port="$2"
	local serial
	serial="$(soa_serial "$host" "$port" 2>/dev/null || true)"
	[[ -n "$serial" && "$serial" != "0" ]]
}

artifact_dir() {
	local name="${1:-run}"
	local ts
	ts="$(date -u +%Y%m%dT%H%M%SZ)"
	local dir="$ARTIFACTS_DIR/${ts}-${name}"
	mkdir -p "$dir"
	echo "$dir"
}

finalize_artifact_dir() {
	local dir="$1" result="$2"
	local parent base new
	case "$result" in
		PASS|FAIL) ;;
		*) die "finalize_artifact_dir: result must be PASS or FAIL (got $result)" ;;
	esac
	[[ -d "$dir" ]] || die "finalize_artifact_dir: not a directory: $dir"
	parent="$(cd "$(dirname "$dir")" && pwd)"
	base="$(basename "$dir")"
	base="${base%-PASS}"
	base="${base%-FAIL}"
	new="${parent}/${base}-${result}"
	if [[ "$dir" != "$new" ]]; then
		if [[ -e "$new" ]]; then
			rm -rf "$new"
		fi
		mv "$dir" "$new"
	fi
	echo "$new"
}

results_status() {
	local dir="$1"
	local f="$dir/RESULTS.md"
	[[ -f "$f" ]] || return 1
	sed -n 's/^\*\*Status:\*\*[[:space:]]*//p' "$f" | head -n 1 | tr -d '\r'
}

results_is_fail() {
	local st
	st="$(results_status "$1" 2>/dev/null || true)"
	[[ "$st" == "UNSIGNED" || "$st" == "PARTLY_SIGNED" ]]
}

_run_dnssec_verify() {
	local zone="$1" zonefile="$2" out="$3" err="$4"
	local rc=0
	: >"$out"
	: >"$err"
	if command -v dnssec-verify >/dev/null 2>&1; then
		dnssec-verify -o "$zone" "$zonefile" >"$out" 2>"$err" || rc=$?
	else
		docker run --rm --entrypoint dnssec-verify \
			-v "$(cd "$(dirname "$zonefile")" && pwd):/z:ro" \
			"internetsystemsconsortium/bind9:${BIND_TAG:-9.20}" \
			-o "$zone" "/z/$(basename "$zonefile")" \
			>"$out" 2>"$err" || rc=$?
	fi
	return "$rc"
}

# Scenario poll budget. Default: exactly one iter.
# Override:
#   MAX_ITERS=60 INTERVAL=2
#   POLL_DURATION=120 INTERVAL=2   # time-boxed (takes precedence over MAX_ITERS)
scenario_iter_init() {
	INTERVAL="${INTERVAL:-2}"
	if [[ -n "${POLL_DURATION:-}" ]]; then
		_SCENARIO_USE_DEADLINE=1
		_SCENARIO_DEADLINE=$((SECONDS + POLL_DURATION))
		log "poll budget: POLL_DURATION=${POLL_DURATION}s interval=${INTERVAL}s"
	else
		_SCENARIO_USE_DEADLINE=0
		MAX_ITERS="${MAX_ITERS:-1}"
		log "poll budget: MAX_ITERS=${MAX_ITERS} interval=${INTERVAL}s"
	fi
}

# Return 0 if iteration number n (1-based) should still run.
scenario_iter_should_run() {
	local n="$1"
	if [[ "${_SCENARIO_USE_DEADLINE:-0}" -eq 1 ]]; then
		(( SECONDS < _SCENARIO_DEADLINE ))
	else
		(( n <= MAX_ITERS ))
	fi
}

scenario_iter_sleep() {
	local n="$1"
	if [[ "${_SCENARIO_USE_DEADLINE:-0}" -eq 1 ]]; then
		(( SECONDS + INTERVAL < _SCENARIO_DEADLINE )) || return 0
		sleep "$INTERVAL"
	else
		(( n < MAX_ITERS )) || return 0
		sleep "$INTERVAL"
	fi
}
