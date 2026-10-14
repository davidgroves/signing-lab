# Knot stack usage

Uses **Knot DNS 3.6.x** via `cznic/knot:latest` (`KNOT_TAG` in `.env`).

```bash
./clean.sh
./run-all.sh
ZONESIZE=10 MODES=nsec ./run-all.sh
```

Artifacts: `artifacts/<timestamp>-<name>-PASS|FAIL/`.

See also [../USAGE.md](../USAGE.md) and [../COMMON/](../COMMON/).
