# Knot DNS on-secondary signing lab

Image: [`cznic/knot:latest`](https://hub.docker.com/r/cznic/knot) — **Knot DNS 3.6.x** (verified `knotd` 3.6.1). Override with `KNOT_TAG` in `.env` if Hub publishes a pinned tag.

Topology matches the BIND lab:

```text
UNSIGNED PRIMARY  -->  SIGNER (dnssec-signing: on)  -->  DISTRIBUTION
```

Knot signs **inside** the inbound AXFR/IXFR update and only then `zone_update_commit`s — it should **not** publish a partly signed zone the way BIND’s quantum `zone_sign` + `NEEDNOTIFY` path can. See [../REPORT.md](../REPORT.md).

Topology name: `KNOT-KNOT-KNOT` (primary/signer/distribution all Knot).

## Quick start

```bash
./clean.sh
ZONESIZE=10 ./run-all.sh
MODES=nsec ./run-all.sh
```

## Ports / network

| Role | Address | Host port |
|------|---------|-----------|
| primary | 172.30.54.10 | 25353 |
| signer | 172.30.54.20 | 25354 |
| distribution | 172.30.54.30 | 25355 |

## Scenarios

Same battery as BIND: `initial-sign`, `reload-resign`, `serial-bump`, `force-transfer`, plus **`nsec-flip-transfer`** for `nsec` / `nsec3` (swap zone `dnssec-policy` via `knotc conf-set` / `conf-commit`, then immediate `zone-retransfer` on distribution).

## Control

```bash
docker exec knot-signer knotc zone-status nsec.test.example
docker exec knot-signer knotc zone-sign nsec.test.example
docker exec knot-distribution knotc zone-retransfer nsec.test.example
dig @127.0.0.1 -p 25355 nsec.test.example AXFR
```

Shared generator/checker: [`../COMMON/`](../COMMON/).
