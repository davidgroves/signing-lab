# BIND-BIND-KNOT

Topology: **BIND primary → BIND signer (inline-signing) → Knot distribution**.

One directory; the battery runs twice with Knot `dnssec-validation` **off** and **on**.
Test names always include the knob:

```text
nsec/validate-off/initial-sign
nsec/validate-on/initial-sign
```

| Mode | Expected |
|------|----------|
| `validate-off` | Can FAIL with `PARTLY_SIGNED` / `UNSIGNED` (Knot serves what BIND transferred) |
| `validate-on` | Knot cancels invalid updates; FAIL only if distribution AXFR is broken. AXFR unavailable / previous `FULLY_SIGNED` is PASS |

```bash
./clean.sh
ZONESIZE=10 ./run-all.sh
```

| Role | Software | Address | Host port |
|------|----------|---------|-----------|
| primary | BIND | 172.30.55.10 | 35353 |
| signer | BIND inline-signing | 172.30.55.20 | 35354 |
| distribution | Knot | 172.30.55.30 | 35355 |

Configs: `config/distribution/knot.validate-off.conf` / `knot.validate-on.conf`.

Shared oracle/generator: [`../COMMON/`](../COMMON/). Analysis: [`../REPORT.md`](../REPORT.md).
