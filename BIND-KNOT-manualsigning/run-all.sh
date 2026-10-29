#!/usr/bin/env bash
# Standalone battery for BIND-KNOT-manualsigning (not part of mid-sign run-all).
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/scripts/lib.sh"

log "=== run-all BIND-KNOT-manualsigning ==="
rc=0
"$ROOT/scripts/scenario-zsk-withdraw-ixfr.sh" || rc=$?
"$ROOT/scripts/scenario-zsk-withdraw-apex-strip-ixfr.sh" || rc=$?
"$ROOT/scripts/scenario-zsk-withdraw-clean-apex-ixfr.sh" || rc=$?
exit "$rc"
