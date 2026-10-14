# DNSSEC BITW resign labs

Published report: **https://davidgroves.github.io/signing-lab/**

Compare how **BIND** and **Knot DNS** behave as bump-in-the-wire signers across
primary → signer → distribution topology combinations:

```text
UNSIGNED PRIMARY  -->  SIGNER (on-secondary DNSSEC)  -->  DISTRIBUTION
```

Directories are named **PRIMARY-SIGNER-DISTRIBUTION**:

| Directory | Topology |
|-----------|----------|
| [`BIND-BIND-BIND/`](BIND-BIND-BIND/) | all BIND (inline-signing secondary) |
| [`BIND-BIND-KNOT/`](BIND-BIND-KNOT/) | BIND signer, Knot distribution (`dnssec-validation` off + on) |
| [`BIND-KNOT-BIND/`](BIND-KNOT-BIND/) | Knot signer, BIND distribution |
| [`KNOT-KNOT-KNOT/`](KNOT-KNOT-KNOT/) | all Knot |
| [`COMMON/`](COMMON/) | Shared zone generator, AXFR coverage checker, starters |

## Quick start

```bash
./clean.sh
./run-all.sh bind                 # BIND-BIND-BIND
./run-all.sh knot                 # KNOT-KNOT-KNOT
./run-all.sh bbk                  # BIND-BIND-KNOT
./run-all.sh bkb                  # BIND-KNOT-BIND
./run-all.sh all                  # all four stacks
ZONESIZE=10 MODES=nsec ./run-all.sh BIND-BIND-KNOT
```

## Host ports

| Stack | Primary | Signer | Distribution | Network |
|-------|---------|--------|--------------|---------|
| BIND-BIND-BIND | 15353 | 15354 | 15355 | `172.30.53.0/24` |
| KNOT-KNOT-KNOT | 25353 | 25354 | 25355 | `172.30.54.0/24` |
| BIND-BIND-KNOT | 35353 | 35354 | 35355 | `172.30.55.0/24` |
| BIND-KNOT-BIND | 45353 | 45354 | 45355 | `172.30.56.0/24` |

## Docs

- [USAGE.md](USAGE.md) — clean / run / results
- `RESULTS.html` — latest battery summary per stack (`./make-results-html.sh`, also end of `./run-all.sh`)
- [REPORT.html](https://davidgroves.github.io/signing-lab/) — definitive battery analysis + SVG timelines ([local](REPORT.html); source [REPORT.md](REPORT.md); `python3 COMMON/scripts/make-report-html.py`)
- Per-stack READMEs under each topology directory

## Prerequisites

Docker Compose v2, Python 3, `dig`. Disk ≈ 3–5× `ZONESIZE` × number of modes per stack.
