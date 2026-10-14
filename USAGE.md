# Usage

## Clean

```bash
./clean.sh          # all stacks
./clean.sh bind     # BIND-BIND-BIND
./clean.sh knot     # KNOT-KNOT-KNOT
./clean.sh bbk      # BIND-BIND-KNOT
./clean.sh bkb      # BIND-KNOT-BIND
```

## Run tests

```bash
./run-all.sh bind                 # BIND-BIND-BIND
./run-all.sh knot                 # KNOT-KNOT-KNOT
./run-all.sh bbk                  # BIND-BIND-KNOT (validate-off then validate-on)
./run-all.sh bkb                  # BIND-KNOT-BIND
./run-all.sh all                  # all four (sequential)
ZONESIZE=100 MODES="nsec nsec3 nsec3optout" ./run-all.sh knot
```

- ZONESIZE is in megabytes.
- MODES is one or more space seperated [nsec,nsec3,nsec3optout]
- Each scenario runs on a **fresh stack** (`docker compose down -v` + up) so later modes do not inherit zones that already finished signing in the background.

### Runtime (expect a long wall clock)

A full `./run-all.sh` / `./run-all.sh all` battery is **slow**: every scenario recreates the compose stack, and `nsec-flip-transfer` waits until the zone is `FULLY_SIGNED` before flipping.

Rough timings on the author’s machine (AMD Ryzen AI 7 350, 8 cores / 16 threads, ~93 GiB RAM, NVMe, Debian; default `ZONESIZE=10`, `MAX_ITERS=1`):

| Scope | Scenarios | Approx. wall clock |
|-------|-----------|--------------------|
| One stack (`bind` / `knot` / `bkb`) | 14 | **~15 minutes** |
| `bbk` (validate-off + validate-on) | 28 | **~30 minutes** |
| All four stacks | 70 | **~75 minutes** |

Figures are extrapolated from a live run (~25 minutes in, 23/70 scenarios done). Larger `ZONESIZE`, `POLL_DURATION` / high `MAX_ITERS`, or a colder disk cache will push this higher.

Inside a stack directory the same entrypoints work:

```bash
cd BIND-BIND-BIND && ./run-all.sh
cd ../KNOT-KNOT-KNOT && ZONESIZE=10 ./run-all.sh
```

## Results

```text
BIND-BIND-BIND/artifacts/<timestamp>-<name>-PASS|FAIL/
BIND-BIND-KNOT/artifacts/<timestamp>-<name>-PASS|FAIL/
BIND-KNOT-BIND/artifacts/<timestamp>-<name>-PASS|FAIL/
KNOT-KNOT-KNOT/artifacts/<timestamp>-<name>-PASS|FAIL/
```

- `RESULTS.md` — RRSIG coverage (`FULLY_SIGNED` / `UNSIGNED` / `PARTLY_SIGNED`; BBK validate-on may also use `AXFR_UNAVAILABLE`)
- On FAIL: `broken-zone/`, `BROKEN_ZONE.axfr`, `BROKEN_ZONE.dnssec-verify.*`
- Each scenario writes **one** `iter-0001/` by default.
- Root [`RESULTS.html`](RESULTS.html) — cross-stack summary of the latest `run-all` battery per stack (written at the end of `./run-all.sh`, or on demand):

```bash
./make-results-html.sh
```

Multi-poll race hunting (optional):

```bash
MAX_ITERS=60 INTERVAL=2 ./run-all.sh bind
POLL_DURATION=120 INTERVAL=2 ./run-all.sh knot
```

## DNSSEC modes

| Mode | Zone | Denial of existence |
|------|------|---------------------|
| `nsec` | `nsec.test.example` | NSEC |
| `nsec3` | `nsec3.test.example` | NSEC3 (`optout no`) |
| `nsec3optout` | `nsec3optout.test.example` | NSEC3 (`optout yes`) + insecure delegations |

## Scenarios

Shared battery per mode: `initial-sign`, `reload-resign`, `serial-bump`, `force-transfer`.

For `nsec` and `nsec3` only, also **`nsec-flip-transfer`**.

### BIND-BIND-KNOT naming

Summary lines include the Knot `dnssec-validation` knob:

```text
nsec/validate-off/initial-sign rc=1
nsec/validate-on/initial-sign rc=0
```

## COMMON

Shared pieces under [`COMMON/`](COMMON/):

- `scripts/generate-zone.py` — synthetic zone generator
- `scripts/check-zone-signed.sh` — AXFR RRSIG coverage oracle (`--allow-axfr-unavailable` for validate-on)
- `scripts/lib-common.sh` — dig/artifact/mode helpers
- `zones/*.starter` — tiny starter zones
