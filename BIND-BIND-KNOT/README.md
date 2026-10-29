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

### Key-policy gate (standalone)

RSA1024 → RSA2048 same-algorithm policy-name switch on a large NSEC3 zone with short timers; asserts Knot `dnssec-validation: on` never serves an invalid zone (orphan RRSIG / `PARTLY_SIGNED` / `UNSIGNED`). See [`../REPORT-KEY-POLICY.md`](../REPORT-KEY-POLICY.md).

```bash
ZONESIZE=10 MODE=nsec3 ./scripts/scenario-key-policy-gate.sh
```

PASS = every successful distribution AXFR is clean, or AXFR unavailable. FAIL = distribution served invalid content. Not part of `./run-all.sh`.

Shared oracle/generator: [`../COMMON/`](../COMMON/). Analysis: [`../REPORT.md`](../REPORT.md), [`../REPORT-KEY-POLICY.md`](../REPORT-KEY-POLICY.md).
