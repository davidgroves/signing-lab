#!/usr/bin/env bash
# Run the test battery; write artifacts/.
# Zone size: ZONESIZE=<megabytes> (default 10). Example: ZONESIZE=1024 ./run-all.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
exec "$ROOT/scripts/run-all.sh" "$@"
