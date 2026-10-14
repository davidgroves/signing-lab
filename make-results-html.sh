#!/usr/bin/env bash
# Build RESULTS.html from the latest run-all battery artifacts in each stack.
# Safe to run anytime (including while a battery is still in progress).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$ROOT/COMMON/scripts/make-results-html.py" --root "$ROOT" "$@"
