# BIND bump-in-the-wire signer: mid-sign transfers

**Date:** 2026-10-14  
**Lab:** [github.com/davidgroves/signing-lab](https://github.com/davidgroves/signing-lab) (`UNSIGNED PRIMARY → SIGNER → DISTRIBUTION`)  
**BIND under test:** `9.20.29` (`named -V` id `c3d4465`)  
**BIND source:** [isc-projects/bind9](https://gitlab.isc.org/isc-projects/bind9) tag `v9.20.29` / commit `c3d4465`  
**Knot under test:** `3.6.1` (`knotc` in lab containers; image `cznic/knot` via `KNOT_TAG=latest`)  
**Knot source referenced below:** Knot DNS `v3.4.6` `src/knot/events/handlers/refresh.c` (sign-then-commit model; behaviour confirmed empirically on 3.6.1)  
**Battery matrix:** [`RESULTS.html`](RESULTS.html)

---

## Executive summary

Across a full four-stack battery (`ZONESIZE=10`, `MAX_ITERS=1`, modes `nsec` / `nsec3` / `nsec3optout`), this lab shows:

1. **BIND as BITW signer publishes partly signed zones.** Every mid-sign race scenario against a BIND signer (`initial-sign`, `reload-resign`, `serial-bump`, `force-transfer`) returned `FAIL` / `PARTLY_SIGNED` on distribution AXFR — **12/12** in `BIND-BIND-BIND`, and **12/12** again in `BIND-BIND-KNOT` with Knot `dnssec-validation: off`.
2. **Knot as BITW signer does not.** All **28** scenarios with a Knot signer (`BIND-KNOT-BIND` + `KNOT-KNOT-KNOT`) returned `PASS` / `FULLY_SIGNED`.
3. **Knot distribution with `dnssec-validation: on` refuses to serve the broken BIND-signed content.** All **14** validate-on scenarios in `BIND-BIND-KNOT` returned `PASS` with status `AXFR_UNAVAILABLE` (distribution did not answer a usable SOA/AXFR). That is a **distribution gate**, not BIND signing atomicity.
4. **The BIND behaviour is intentional in code**, not a lab false positive: `zone_sign()` commits and sets `NEEDNOTIFY` after each quantum. Coverage numbers in `RESULTS.md` match the captured AXFR bytes.

Scoreboard for the definitive run (70 scenarios):

| Stack | Battery | PASS | FAIL | Notes |
|-------|---------|-----:|-----:|-------|
| `BIND-BIND-BIND` | `20261014T195345Z-run-all-10m-FAIL` | 2 | 12 | Only `nsec-flip-transfer` passed (both NSEC and NSEC3) |
| `BIND-BIND-KNOT` | `20261014T200801Z-run-all-10m-FAIL` | 16 | 12 | 2 flip PASS + 14 validate-on (`AXFR_UNAVAILABLE`) |
| `BIND-KNOT-BIND` | `20261014T202832Z-run-all-10m-PASS` | 14 | 0 | Knot signer → BIND distribution |
| `KNOT-KNOT-KNOT` | `20261014T203520Z-run-all-10m-PASS` | 14 | 0 | All Knot |
| **Total** | | **46** | **24** | |

---

## Topology under test

Stacks are named **PRIMARY-SIGNER-DISTRIBUTION**:

```text
primary (unsigned)  --AXFR-->  signer (on-secondary DNSSEC)
                                      |
                                      | AXFR/IXFR (BITW contract: fully signed)
                                      v
                               distribution (secondary)
```

| Stack | Primary | Signer | Distribution | Host nets / DNS ports |
|-------|---------|--------|--------------|------------------------|
| `BIND-BIND-BIND` | BIND | BIND inline-signing | BIND | `172.30.53.0/24` · 15353–15355 |
| `BIND-BIND-KNOT` | BIND | BIND inline-signing | Knot (± validation) | `172.30.55.0/24` · 35353–35355 |
| `BIND-KNOT-BIND` | BIND | Knot on-secondary | BIND | `172.30.56.0/24` · 45353–45355 |
| `KNOT-KNOT-KNOT` | Knot | Knot on-secondary | Knot | `172.30.54.0/24` · 25353–25355 |

Zones: `nsec.test.example`, `nsec3.test.example`, `nsec3optout.test.example` (~10 MiB each).  
BIND signer knobs that widen the race (`BIND-*/config/signer/named.conf`):

- `sig-signing-nodes 25;`
- `sig-signing-signatures 25;`

ARM: [`sig-signing-nodes`](https://bind9.readthedocs.io/en/v9.20.29/reference.html#namedconf-statement-sig-signing-nodes), [`sig-signing-signatures`](https://bind9.readthedocs.io/en/v9.20.29/reference.html#namedconf-statement-sig-signing-signatures).

Oracle: `COMMON/scripts/check-zone-signed.sh` classifies distribution (or signer) AXFR as `FULLY_SIGNED` / `PARTLY_SIGNED` / `UNSIGNED` / (BBK validate-on) `AXFR_UNAVAILABLE`.

---

## Definitive results

### BIND-BIND-BIND — BIND signer publishes mid-sign (12 FAIL / 2 PASS)

Battery: `BIND-BIND-BIND/artifacts/20261014T195345Z-run-all-10m-FAIL`

| Scenario | Verdict | Status | SOA | Signed / signable | Missing |
|----------|---------|--------|----:|------------------:|--------:|
| `nsec/initial-sign` | FAIL | PARTLY_SIGNED | 389 | 3 / 202830 | 202827 |
| `nsec/reload-resign` | FAIL | PARTLY_SIGNED | 3932 | 1808 / 289734 | 287926 |
| `nsec/serial-bump` | FAIL | PARTLY_SIGNED | 426 | 3 / 203755 | 203752 |
| `nsec/force-transfer` | FAIL | PARTLY_SIGNED | 548 | 3 / 206755 | 206752 |
| `nsec/nsec-flip-transfer` | PASS | FULLY_SIGNED | 14597 | 289734 / 289734 | 0 |
| `nsec3/initial-sign` | FAIL | PARTLY_SIGNED | 438 | 3048 / 196199 | 193151 |
| `nsec3/reload-resign` | FAIL | PARTLY_SIGNED | 3736 | 26134 / 219285 | 193151 |
| `nsec3/serial-bump` | FAIL | PARTLY_SIGNED | 451 | 3139 / 196290 | 193151 |
| `nsec3/force-transfer` | FAIL | PARTLY_SIGNED | 581 | 4035 / 197186 | 193151 |
| `nsec3/nsec-flip-transfer` | PASS | FULLY_SIGNED | 24534 | 289755 / 289755 | 0 |
| `nsec3optout/initial-sign` | FAIL | PARTLY_SIGNED | 424 | 2950 / 195941 | 192991 |
| `nsec3optout/reload-resign` | FAIL | PARTLY_SIGNED | 3723 | 26043 / 219034 | 192991 |
| `nsec3optout/serial-bump` | FAIL | PARTLY_SIGNED | 422 | 2936 / 195927 | 192991 |
| `nsec3optout/force-transfer` | FAIL | PARTLY_SIGNED | 595 | 4133 / 197124 | 192991 |

**What FAIL means here.** Distribution served an AXFR whose RRSIG coverage was incomplete while the signer was still signing. Representative capture (`20261014T195346Z-nsec-initial-sign-FAIL`):

| Evidence | Value |
|----------|-------|
| Distribution AXFR SOA | `389` |
| Signed / signable | **3 / 202830** |
| Signer `rndc zonestatus` | `secure: no`, signed serial climbing (`608` at status capture) |
| Signer `rndc signing -list` | `Signing with key …` (not done) |
| Serials at capture | primary `1`, signer `613`, distribution `560` |
| Signer xfer-out | AXFR to `172.30.53.30` at serials **389** then **560** while signing still in progress |

NSEC3 / NSEC3-optout FAILs are the same class with more progress (thousands of RRSIGs present, ~193k still missing). That matches quantum signing mid-flight, not an empty zone.

**`nsec-flip-transfer` PASS.** Under `MAX_ITERS=1`, after waiting for an initial `FULLY_SIGNED` warmup, flipping NSEC↔NSEC3 and force-transferring did **not** capture a `PARTLY_SIGNED` distribution AXFR. That does **not** contradict the mid-sign publication finding; it means this particular one-shot flip path did not hit the race window in this battery.

### BIND-BIND-KNOT — same BIND signer race; validation gates the wire

Battery: `BIND-BIND-KNOT/artifacts/20261014T200801Z-run-all-10m-FAIL`

#### `dnssec-validation: off` (12 FAIL / 2 PASS)

Same pattern as all-BIND. Distribution accepts and re-serves the partly signed zone:

| Scenario | Verdict | Status | SOA | Signed / signable | Missing |
|----------|---------|--------|----:|------------------:|--------:|
| `nsec/…/initial-sign` | FAIL | PARTLY_SIGNED | 385 | 3 / 202730 | 202727 |
| `nsec/…/reload-resign` | FAIL | PARTLY_SIGNED | 3950 | 2294 / 289734 | 287440 |
| `nsec/…/serial-bump` | FAIL | PARTLY_SIGNED | 293 | 3 / 200430 | 200427 |
| `nsec/…/force-transfer` | FAIL | PARTLY_SIGNED | 401 | 3 / 203080 | 203077 |
| `nsec/…/nsec-flip-transfer` | PASS | FULLY_SIGNED | 14597 | 289734 / 289734 | 0 |
| `nsec3/…/initial-sign` | FAIL | PARTLY_SIGNED | 417 | 2901 / 196052 | 193151 |
| `nsec3/…/reload-resign` | FAIL | PARTLY_SIGNED | 3671 | 25679 / 218830 | 193151 |
| `nsec3/…/serial-bump` | FAIL | PARTLY_SIGNED | 400 | 2782 / 195933 | 193151 |
| `nsec3/…/force-transfer` | FAIL | PARTLY_SIGNED | 595 | 4133 / 197284 | 193151 |
| `nsec3/…/nsec-flip-transfer` | PASS | FULLY_SIGNED | 24534 | 289755 / 289755 | 0 |
| `nsec3optout/…/initial-sign` | FAIL | PARTLY_SIGNED | 410 | 2852 / 195843 | 192991 |
| `nsec3optout/…/reload-resign` | FAIL | PARTLY_SIGNED | 3657 | 25581 / 218572 | 192991 |
| `nsec3optout/…/serial-bump` | FAIL | PARTLY_SIGNED | 441 | 3069 / 196060 | 192991 |
| `nsec3optout/…/force-transfer` | FAIL | PARTLY_SIGNED | 590 | 4098 / 197089 | 192991 |

#### `dnssec-validation: on` (14 PASS — all `AXFR_UNAVAILABLE`)

| Result | Meaning |
|--------|---------|
| Verdict `PASS` | Lab treats “distribution did not serve UNSIGNED/PARTLY_SIGNED” as success when `--allow-axfr-unavailable` is set |
| Status `AXFR_UNAVAILABLE` | No usable SOA/AXFR from Knot distribution during the check |

So with validation on, Knot **does not republish** the half-signed BIND content to the checker. The BIND signer race is unchanged; the distribution role refuses to be a loudspeaker for it.

### BIND-KNOT-BIND — Knot signer, BIND distribution (14/14 PASS)

Battery: `BIND-KNOT-BIND/artifacts/20261014T202832Z-run-all-10m-PASS`

| Scenario | Verdict | Status | SOA | Signed / signable | Missing |
|----------|---------|--------|----:|------------------:|--------:|
| `nsec/initial-sign` | PASS | FULLY_SIGNED | 3 | 289735 / 289735 | 0 |
| `nsec/reload-resign` | PASS | FULLY_SIGNED | 4 | 289735 / 289735 | 0 |
| `nsec/serial-bump` | PASS | FULLY_SIGNED | 5 | 289735 / 289735 | 0 |
| `nsec/force-transfer` | PASS | FULLY_SIGNED | 7 | 289735 / 289735 | 0 |
| `nsec/nsec-flip-transfer` | PASS | FULLY_SIGNED | 8 | 289735 / 289735 | 0 |
| `nsec3/initial-sign` | PASS | FULLY_SIGNED | 7 | 289733 / 289733 | 0 |
| `nsec3/reload-resign` | PASS | FULLY_SIGNED | 8 | 289733 / 289733 | 0 |
| `nsec3/serial-bump` | PASS | FULLY_SIGNED | 9 | 289733 / 289733 | 0 |
| `nsec3/force-transfer` | PASS | FULLY_SIGNED | 11 | 289733 / 289733 | 0 |
| `nsec3/nsec-flip-transfer` | PASS | FULLY_SIGNED | 12 | 289733 / 289733 | 0 |
| `nsec3optout/initial-sign` | PASS | FULLY_SIGNED | 12 | 289493 / 289493 | 0 |
| `nsec3optout/reload-resign` | PASS | FULLY_SIGNED | 13 | 289493 / 289493 | 0 |
| `nsec3optout/serial-bump` | PASS | FULLY_SIGNED | 14 | 289493 / 289493 | 0 |
| `nsec3optout/force-transfer` | PASS | FULLY_SIGNED | 16 | 289493 / 289493 | 0 |

### KNOT-KNOT-KNOT — all Knot (14/14 PASS)

Battery: `KNOT-KNOT-KNOT/artifacts/20261014T203520Z-run-all-10m-PASS`

| Scenario | Verdict | Status | SOA | Signed / signable | Missing |
|----------|---------|--------|----:|------------------:|--------:|
| `nsec/initial-sign` | PASS | FULLY_SIGNED | 10 | 289735 / 289735 | 0 |
| `nsec/reload-resign` | PASS | FULLY_SIGNED | 11 | 289735 / 289735 | 0 |
| `nsec/serial-bump` | PASS | FULLY_SIGNED | 12 | 289735 / 289735 | 0 |
| `nsec/force-transfer` | PASS | FULLY_SIGNED | 14 | 289735 / 289735 | 0 |
| `nsec/nsec-flip-transfer` | PASS | FULLY_SIGNED | 15 | 289735 / 289735 | 0 |
| `nsec3/initial-sign` | PASS | FULLY_SIGNED | 10 | 289733 / 289733 | 0 |
| `nsec3/reload-resign` | PASS | FULLY_SIGNED | 11 | 289733 / 289733 | 0 |
| `nsec3/serial-bump` | PASS | FULLY_SIGNED | 12 | 289733 / 289733 | 0 |
| `nsec3/force-transfer` | PASS | FULLY_SIGNED | 14 | 289733 / 289733 | 0 |
| `nsec3/nsec-flip-transfer` | PASS | FULLY_SIGNED | 15 | 289733 / 289733 | 0 |
| `nsec3optout/initial-sign` | PASS | FULLY_SIGNED | 14 | 289493 / 289493 | 0 |
| `nsec3optout/reload-resign` | PASS | FULLY_SIGNED | 15 | 289493 / 289493 | 0 |
| `nsec3optout/serial-bump` | PASS | FULLY_SIGNED | 16 | 289493 / 289493 | 0 |
| `nsec3optout/force-transfer` | PASS | FULLY_SIGNED | 18 | 289493 / 289493 | 0 |

---

## How the FAIL is produced (timelines)

These timelines describe what the lab scripts **do** and **when they check**, tied to what BIND **publishes**.

### Timeline A — `initial-sign` (canonical BIND FAIL)

```text
t ──────────────────────────────────────────────────────────────────►

PRIMARY     [ generate unsigned zone serial=1 ]
               │
               │  compose up / AXFR
               ▼
SIGNER      [ load unsigned ]──►[ zone_sign quantum 1 ]──► commit + NEEDNOTIFY
               │                      │
               │                      │  ~10 ms later
               │                      ▼
               │                 [ quantum 2 ]──► commit + NEEDNOTIFY ──► …
               │                      │
               │                      │  still “Signing with key…”
               ▼                      ▼
DISTRIB     [ NOTIFY / retransfer ]──► AXFR serial 389 (3 RRSIGs / ~203k)
               │
LAB CHECK   ══════════════════════════╤══════════════════════════════
                                      │  check-zone-signed.sh
                                      ▼
                                 PARTLY_SIGNED → FAIL
                                 (status.txt: secure:no, Signing with key)
```

**Lab steps (evidence):** `compose_fresh` → `wait-ready` → `rndc distribution retransfer` → poll distribution AXFR once (`MAX_ITERS=1`) → classify → capture `status.txt` / logs.

**BIND steps (evidence):** inbound unsigned AXFR serial `1` at `19:53:52Z`; outbound AXFR to distribution at serial `389` at `19:53:57Z` while signing list still shows active keys; checker records `3/202830` signed.

### Timeline B — `reload-resign` / `force-transfer` / `serial-bump`

```text
t ──────────────────────────────────────────────────────────────────►

SIGNER      [ … reach Done signing (reload) or mid-sign window … ]
               │
LAB ACTION  ───┼── rndc sign/loadkeys     (reload-resign)
               ├── bump primary serial    (serial-bump)
               └── rndc retransfer/sign   (force-transfer)
               │
SIGNER      [ new signing work / quantum commits + NEEDNOTIFY ]
               │
DISTRIB     [ transfers intermediate signed serial ]
               │
LAB CHECK   ──► distribution AXFR ──► PARTLY_SIGNED → FAIL
```

Measured pattern: reload-resign FAILs show **higher** SOA and **more** RRSIGs than cold `initial-sign` (e.g. NSEC reload `1808/289734` vs initial `3/202830`) — resign is in progress, not “unsigned from scratch,” but still incomplete at the check instant.

### Timeline C — Knot signer (why BKB / KKK PASS)

```text
t ──────────────────────────────────────────────────────────────────►

PRIMARY     [ unsigned AXFR/IXFR ]
               │
SIGNER      [ hold in zone_update ]──► knot_dnssec_zone_sign / sign_update
               │                              │
               │                              ▼
               │                      zone_update_commit  (only after sign)
               │                              │
               │                              ▼
               │                         schedule NOTIFY
               ▼
DISTRIB     [ AXFR only after commit ]──► FULLY_SIGNED
               │
LAB CHECK   ──► PASS
```

No published half-signed snapshot exists for the inbound-XFR-driven sign path. The lab’s distribution AXFRs confirm full coverage on every Knot-signer scenario in this battery.

### Timeline D — BBK `dnssec-validation: on` (PASS without FULLY_SIGNED)

```text
BIND SIGNER     still publishes PARTLY_SIGNED intermediates
        │
        │  XFR / NOTIFY
        ▼
KNOT DIST       dnssec-validation: on ──► refuses usable SOA/AXFR
        │
LAB CHECK       AXFR_UNAVAILABLE → PASS (allowed)
                (does not prove BIND stopped mid-sign publish)
```

---

## The operational surprise

BITW operators typically assume:

1. Signer loads the unsigned zone from the hidden primary.
2. Inline / on-secondary signing produces a signed view.
3. Downstream only ever sees a **fully signed** zone (or is not notified of incomplete ones).

**What BIND did in this lab during initial key signing of a ~10 MiB zone:**

1. Sign in **quanta** (`sig-signing-nodes` / `sig-signing-signatures`).
2. After each quantum that changed the zone: bump signed SOA, **commit**, set **`NEEDNOTIFY`**.
3. Distribution transferred that intermediate (AXFR serials `389`, then `560` in the NSEC initial-sign artifact).
4. Signing continued (`Signing with key…`, `secure: no`).

There is **no** transfer gate that waits for `Done signing` before outbound XFR. Lower quantum sizes make the race easier to observe; the commit-per-quantum design also exists at BIND defaults (`nodes=100`, `signatures=10`).

---

## BIND code trace (intentional behaviour)

Source: BIND `v9.20.29` / `c3d4465`, primarily `lib/dns/zone.c` and `lib/dns/qpzone.c`.

### 1. Quantum limits

```c
/* lib/dns/zone.c — zone defaults */
.signatures = 10,
.nodes = 100,
```

Configured via `sig-signing-nodes` / `sig-signing-signatures`.

### 2. `zone_sign()` commits and notifies per quantum

```c
/* lib/dns/zone.c — zone_sign() */
nodes = zone->nodes;
signatures = zone->signatures;
/* … apply signatures for this quantum … */
dns_db_closeversion(db, &version, commit);
if (commit) {
    DNS_ZONE_SETFLAG(zone, DNS_ZONEFLG_NEEDNOTIFY);
    zone_needdump(zone, DNS_DUMP_DELAY);
}
```

Next quantum ~**10 ms** later while `zone->signing` remains non-empty.

**Implication:** every successful quantum that changes the zone is a **published, notifiable** version — including versions with only a handful of RRSIGs into a ~200k-RRset zone. That is exactly what the FAIL artifacts contain.

### 3. `secure` is not “fully signed”

`rndc zonestatus` `secure:` comes from `setsecure()` (NSEC/NSEC3 presence), **not** full RRSIG coverage. The lab’s `secure: no` during early initial sign matches that predicate.

### 4. Lab symptom → code

| Lab symptom (this battery) | Code explanation |
|----------------------------|------------------|
| Rising signed serials while primary stays at `1` | SOA bump + commit each quantum |
| AXFR with only 3 RRSIGs (`nsec/initial-sign`) | Early quantum: apex/DNSKEY/private type first |
| Outbound xfer while `Signing with key` | No wait-for-done before XFR/notify |
| `secure: no` mid-sign | `setsecure()` ≠ full RRSIG coverage |
| NSEC3 FAILs with thousands signed, ~193k missing | Mid-chain quantum publish |

---

## Knot DNS comparison

Knot’s documented on-secondary model: the zone is signed after every AXFR/IXFR from primary so the secondary **always serves a signed up-to-date version**  
([On-secondary signing](https://www.knot-dns.cz/docs/latest/html/configuration.html#on-secondary-on-slave-signing)).

AXFR finalize (`v3.4.6` `refresh.c`): `knot_dnssec_zone_sign` → then `zone_update_commit`. IXFR: `knot_dnssec_sign_update` → then commit. NOTIFY is scheduled after a successful updated transfer (post sign+commit).

| Concern | BIND 9.20.29 (lab) | Knot 3.6.1 (lab) |
|---------|--------------------|------------------|
| Mid-sign outbound half-signed AXFR? | **Yes** — measured 24 FAIL artifacts | **No** — 28/28 Knot-signer scenarios `FULLY_SIGNED` |
| NOTIFY timing | After each successful signing quantum | After successful refresh that updated the zone (post sign+commit) |
| Publication vs signing completeness | Overlapped | Atomic at commit |

Caveat: Knot can still take wall-clock time to sign a huge zone; the measured difference is **visibility of incomplete signatures**, not CPU.

---

## Is this a BIND bug?

| Claim | Assessment |
|-------|------------|
| Lab false positive / bad AXFR parse | **No** — coverage matches AXFR bytes; xfer logs show the serials served |
| BIND coding accident | **No** — quantum commit + `NEEDNOTIFY` is explicit |
| ARM promises “secondaries only get fully signed zones” | **No** — quantum sizes are documented; transfer gating on full coverage is not |
| Operational surprise for BITW | **Yes** — confirmed across two BIND-signer stacks and three DNSSEC modes |
| Knot-as-signer avoids the publication hazard | **Yes** — confirmed on `BIND-KNOT-BIND` and `KNOT-KNOT-KNOT` |
| Knot validate-on “fixes” BIND | **No** — it **hides** bad content at distribution; BIND still published it |

Enhancement ask: optional “do not notify / allow-transfer until signing complete” (or until `secure` **and** no pending signing records) for inline-signing secondaries.

### Possible BIND changes

Two ways to get BITW-safe publication without changing quantum signing for CPU fairness:

- **Approach A — gate publication while signing is incomplete (easy).** Optional knob: suppress `NEEDNOTIFY` and refuse outbound AXFR/IXFR while `zone->signing` / `zone->nsec3chain` is non-empty (or equivalent “signing not done”). When the walk finishes, notify once. Small change in `zone_sign()` / `xfrout`; no DB redesign. Downstream keeps its last good zone until signing completes.
- **Approach B — Knot-like atomic publish (hard).** Keep serving the last fully signed version (or hold one uncommitted version) until the full sign finishes, then commit/notify once. Requires redesign of per-quantum `dns_db_closeversion(..., commit)` and journal behaviour; much larger effort.

### Memory (BIND vs Knot)

BIND inline-signing keeps ~2× steady-state RAM (`zone->raw` + `zone->db`); quantum commits keep the mid-sign working set small. Knot keeps ~1× signed zone in RAM and pays a higher peak during update because sign-then-commit holds the update before swap. Approach A adds essentially no RAM; Approach B would temporarily cost a pinned old signed view / staging during full re-sign.

---

## BIND 9.21 development series

**No** — BIND 9.21 does not fix the mid-sign publish/transfer behaviour this lab hits.

Checked against 9.21 notes (through `9.21.25`) and development `main` `zone_sign()`: each successful quantum still commits, bumps signed SOA, and sets `NEEDNOTIFY`.

`notify-defer` (9.21.9, [GL #5259](https://gitlab.isc.org/isc-projects/bind9/-/issues/5259)) is a fixed NOTIFY delay. It does **not** wait for signing complete, does **not** block outbound AXFR/IXFR of intermediates, and does **not** change quantum commit.

---

## Evidence checklist

From e.g. `BIND-BIND-BIND/artifacts/20261014T195346Z-nsec-initial-sign-FAIL/`:

- `RESULTS.md` — verdict / coverage table  
- `axfr-distribution.txt` / `BROKEN_ZONE.axfr` — served zone  
- `status.txt` — `secure`, signed serial, `signing -list`  
- `signer-xfer.log` — outbound AXFR serials during sign  
- `signer-dnssec.log` — signing activity in the window  
- `named -V` / `knotc` version from the running containers  

Full matrix: [`RESULTS.html`](RESULTS.html) (regenerate with `./make-results-html.sh`).

---

## References

1. BIND ARM 9.20.29 — [sig-signing-nodes](https://bind9.readthedocs.io/en/v9.20.29/reference.html#namedconf-statement-sig-signing-nodes), [sig-signing-signatures](https://bind9.readthedocs.io/en/v9.20.29/reference.html#namedconf-statement-sig-signing-signatures)  
2. BIND 9.21 release notes — [v9.21.25](https://bind9.readthedocs.io/en/v9.21.25/notes.html) (`notify-defer` / [GL #5259](https://gitlab.isc.org/isc-projects/bind9/-/issues/5259))  
3. BIND source `lib/dns/zone.c` (`zone_sign`, `receive_secure_serial`), `lib/dns/qpzone.c` (`setsecure`)  
4. Knot docs — [On-secondary signing](https://www.knot-dns.cz/docs/latest/html/configuration.html#on-secondary-on-slave-signing)  
5. Knot source `src/knot/events/handlers/refresh.c` (AXFR/IXFR finalize: sign → commit → notify)  
6. knot-dns-users thread on BITW / `block-notify-after-transfer` (Libor Peltan, 2023-08)  
7. This repo: stack directories, `COMMON/scripts/check-zone-signed.sh`, batteries listed above, [`RESULTS.html`](RESULTS.html)
