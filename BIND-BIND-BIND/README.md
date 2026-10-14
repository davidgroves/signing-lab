# BIND Large-Zone Resign Reproduction Rig

Stack directory under the monorepo (`BIND-BIND-BIND/` — primary/signer/distribution all BIND). Shared generator/checker live in [`../COMMON/`](../COMMON/). All-Knot counterpart: [`../KNOT-KNOT-KNOT/`](../KNOT-KNOT-KNOT/). Analysis: [../REPORT.md](../REPORT.md).

**Quick start:** see [USAGE.md](USAGE.md) (`./clean.sh`, `ZONESIZE=10 ./run-all.sh`).

Docker Compose lab that models an ISC “bump in the wire” DNSSEC path:

```text
UNSIGNED PRIMARY  -->  SIGNER (inline-signing)  -->  DISTRIBUTION
```

Goal: stress a large-zone resign and catch cases where the **signer** serves an **unsigned or partly signed** zone to **distribution** (via AXFR/IXFR).

Images: ISC best-effort Hub images [`internetsystemsconsortium/bind9`](https://hub.docker.com/r/internetsystemsconsortium/bind9) (default tag `9.20`, override with `BIND_TAG`).

## After a git clone (generate these checks)

Prerequisites: Docker Compose v2, Python 3, `dig` (and ideally `dnssec-verify` from BIND tools). Plan on **~3–5×** zone size in free disk (~10 GiB for a 1 GiB zone).

```bash
git clone <this-repo> && cd bind-unsigned-zone-server-test
./run-all.sh                      # all modes, ZONESIZE=10
ZONESIZE=1024 ./run-all.sh        # ~1 GiB per zone
MODES=nsec3 ./run-all.sh          # one DNSSEC mode only
```

Artifacts are named `artifacts/<timestamp>-<name>-PASS` or `…-FAIL`. Each has `RESULTS.md`. On FAIL you also get `broken-zone/`, `BROKEN_ZONE.axfr`, and `BROKEN_ZONE.dnssec-verify.*`.

## DNSSEC modes

| Mode | Zone | Signer policy |
|------|------|---------------|
| `nsec` | `nsec.test.example` | NSEC |
| `nsec3` | `nsec3.test.example` | NSEC3 (`optout no`) |
| `nsec3optout` | `nsec3optout.test.example` | NSEC3 (`optout yes`) + insecure delegations |

## Quick reference

```bash
dig @127.0.0.1 -p 15353 nsec.test.example SOA
dig @127.0.0.1 -p 15354 nsec3.test.example DNSKEY +dnssec
dig @127.0.0.1 -p 15355 nsec3optout.test.example AXFR
```

## Topology

| Service        | Address on `dnsnet` | Host dig port | Role                                      |
|----------------|---------------------|---------------|-------------------------------------------|
| `primary`      | 172.30.53.10        | 15353         | Unsigned primary                          |
| `signer`       | 172.30.53.20        | 15354         | Secondary + `dnssec-policy` + inline-sign |
| `distribution` | 172.30.53.30        | 15355         | Secondary from signer                     |

## Results (PASS / FAIL)

`scripts/check-zone-signed.sh` AXFRs a role and requires an RRSIG for every signable RRset. It writes **`RESULTS.md`** and the artifact directory is renamed to end in `-PASS` or `-FAIL`.

| Status in RESULTS.md | Directory | Meaning |
|----------------------|-----------|---------|
| `FULLY_SIGNED` | `*-PASS` | Every signable RRset has a covering RRSIG |
| `UNSIGNED` | `*-FAIL` | No RRSIGs in AXFR |
| `PARTLY_SIGNED` | `*-FAIL` | Some RRsets signed, others missing RRSIGs |

On FAIL the check also writes **`broken-zone/`** plus root shortcuts:

| Path | Contents |
|------|----------|
| `RESULTS.md` | Verdict, status, coverage table |
| `broken-zone/README.txt` | Full narrative: topology, what ran, rndc, dnssec-verify |
| `broken-zone/broken-zone.axfr` | Text AXFR as served (primary evidence) |
| `BROKEN_ZONE.axfr` | Copy of the AXFR at the artifact root |
| `BROKEN_ZONE.dnssec-verify.*` | `dnssec-verify` outputs |

## Scenarios

1. **initial-sign** — poll distribution during first/ongoing sign  
2. **reload-resign** — `rndc sign` / `loadkeys`, hammer AXFR  
3. **serial-bump-during-sign** — bump primary serial (optional regenerate), overlap transfers  
4. **force-transfer-during-sign** — loop `rndc retransfer` on distribution during resign  
5. **nsec-flip-transfer** (`nsec` / `nsec3` only) — swap signer `dnssec-policy` NSEC↔NSEC3 via writable runtime `named.conf` + `rndc reconfig`, then immediate `rndc retransfer` on distribution  

Signer knobs that widen the race window (see `config/signer/named.conf`):

- short `signatures-validity` / `signatures-refresh` in `dnssec-policy "repro"`
- low `sig-signing-nodes` / `sig-signing-signatures`

## Reporting a FAIL to ISC

Attach from the `artifacts/...-FAIL/` directory:

- `RESULTS.md` — verdict and coverage
- `broken-zone/README.txt` — narrative of what ran and what failed
- `BROKEN_ZONE.axfr` / `broken-zone/` — the served broken zone
- `BROKEN_ZONE.dnssec-verify.err` — verifier errors
- `status.txt`, signer logs
- Image tag: `docker compose exec signer named -V`
- Zone size and scenario name / command line

## Notes

- Lab-only shared `rndc.key` / `rndc.conf`; do not reuse outside this stack.
- DNSSEC keys are created under `keys/` by the signer (`dnssec-policy`).
- Large generated zones are gitignored.
- Compose network subnet is `172.30.53.0/24` (change in `docker-compose.yml` + named.conf ACLs if it clashes).
- Host dig ports default to `15353`/`15354`/`15355` (override in `.env`).
- On a small smoke zone, distribution can briefly show `PARTLY_SIGNED` while the signer is still incrementally signing — that is the class of failure this rig archives under `artifacts/*-FAIL/`.
