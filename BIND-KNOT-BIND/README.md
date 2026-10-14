# BIND-KNOT-BIND

Topology: **BIND primary → Knot signer → BIND distribution**.

Knot signs inside inbound XFR and only then commits — BIND distribution should
never receive a partly signed zone. Expect the scenario battery to **PASS**.

```bash
./clean.sh
ZONESIZE=10 ./run-all.sh
```

| Role | Software | Address | Host port |
|------|----------|---------|-----------|
| primary | BIND | 172.30.56.10 | 45353 |
| signer | Knot (`dnssec-signing: on`) | 172.30.56.20 | 45354 |
| distribution | BIND | 172.30.56.30 | 45355 |

Shared oracle/generator: [`../COMMON/`](../COMMON/). Analysis: [`../REPORT.md`](../REPORT.md).
