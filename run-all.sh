#!/usr/bin/env bash
# Run one or all PRIMARY-SIGNER-DISTRIBUTION scenario stacks.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
TARGET="${1:-all}"
if [[ $# -ge 1 ]]; then
	shift
fi

usage() {
	echo "Usage: $0 [bind|knot|bbk|bkb|BIND-BIND-BIND|BIND-BIND-KNOT|BIND-KNOT-BIND|KNOT-KNOT-KNOT|all]"
	echo "  env: ZONESIZE MODES MAX_ITERS POLL_DURATION"
}

run_stack() {
	local dir="$1"
	shift
	(cd "$ROOT/$dir" && ./run-all.sh "$@")
}

resolve_target() {
	case "$1" in
		bind|BIND|BIND-BIND-BIND) echo BIND-BIND-BIND ;;
		knot|KNOT|KNOT-KNOT-KNOT) echo KNOT-KNOT-KNOT ;;
		bbk|BBK|BIND-BIND-KNOT) echo BIND-BIND-KNOT ;;
		bkb|BKB|BIND-KNOT-BIND) echo BIND-KNOT-BIND ;;
		all) echo all ;;
		-h|--help|help) echo help ;;
		*) return 1 ;;
	esac
}

ALL_STACKS=(BIND-BIND-BIND BIND-BIND-KNOT BIND-KNOT-BIND KNOT-KNOT-KNOT)

# Mirror stack battery counting (BBK runs validate-off + validate-on).
count_stack_tests() {
	local stack="$1"
	shift
	local -a modes=("$@")
	local passes=1
	[[ "$stack" == "BIND-BIND-KNOT" ]] && passes=2
	local n=0 p mode
	for ((p = 0; p < passes; p++)); do
		for mode in "${modes[@]}"; do
			n=$((n + 4))
			case "$mode" in
				nsec|nsec3) n=$((n + 1)) ;;
			esac
		done
	done
	echo "$n"
}

rc=0
resolved="$(resolve_target "$TARGET")" || {
	usage
	exit 2
}
if [[ "$resolved" == "help" ]]; then
	usage
	exit 0
fi

read -r -a RUN_MODES <<<"${MODES:-nsec nsec3 nsec3optout}"

case "$resolved" in
	all)
		GLOBAL_TOTAL=0
		for s in "${ALL_STACKS[@]}"; do
			GLOBAL_TOTAL=$((GLOBAL_TOTAL + $(count_stack_tests "$s" "${RUN_MODES[@]}")))
		done
		echo "***************************"
		echo "*** TOTAL TESTS: ${GLOBAL_TOTAL} ***"
		echo "***************************"
		offset=0
		for s in "${ALL_STACKS[@]}"; do
			stack_n="$(count_stack_tests "$s" "${RUN_MODES[@]}")"
			echo
			echo "======== stack ${s} (${stack_n} tests; global offset ${offset}) ========"
			GLOBAL_TEST_OFFSET="$offset" GLOBAL_TEST_TOTAL="$GLOBAL_TOTAL" \
				run_stack "$s" "$@" || rc=$?
			offset=$((offset + stack_n))
		done
		;;
	*)
		run_stack "$resolved" "$@" || rc=$?
		;;
esac

# Always refresh the root HTML summary after a battery (pass or fail).
if ! "$ROOT/make-results-html.sh"; then
	echo "warning: make-results-html.sh failed" >&2
fi
exit "$rc"
