#!/usr/bin/env bash
# Clean one or all scenario stacks.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
TARGET="${1:-all}"

clean_stack() { (cd "$ROOT/$1" && ./clean.sh); }

resolve_target() {
	case "$1" in
		bind|BIND|BIND-BIND-BIND) echo BIND-BIND-BIND ;;
		knot|KNOT|KNOT-KNOT-KNOT) echo KNOT-KNOT-KNOT ;;
		bbk|BBK|BIND-BIND-KNOT) echo BIND-BIND-KNOT ;;
		bkb|BKB|BIND-KNOT-BIND) echo BIND-KNOT-BIND ;;
		all|"") echo all ;;
		*) return 1 ;;
	esac
}

ALL_STACKS=(BIND-BIND-BIND BIND-BIND-KNOT BIND-KNOT-BIND KNOT-KNOT-KNOT)

resolved="$(resolve_target "$TARGET")" || {
	echo "Usage: $0 [bind|knot|bbk|bkb|BIND-BIND-BIND|BIND-BIND-KNOT|BIND-KNOT-BIND|KNOT-KNOT-KNOT|all]"
	exit 2
}

case "$resolved" in
	all)
		for s in "${ALL_STACKS[@]}"; do
			[[ -d "$ROOT/$s" ]] && clean_stack "$s"
		done
		;;
	*)
		clean_stack "$resolved"
		;;
esac
