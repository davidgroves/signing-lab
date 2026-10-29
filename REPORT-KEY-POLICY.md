# BIND dnssec-policy: ZSK key-length change vs algorithm rollover

**Date:** 2026-10-22  
**Lab:** [github.com/davidgroves/signing-lab](https://github.com/davidgroves/signing-lab) (`UNSIGNED PRIMARY → SIGNER → DISTRIBUTION`)  
**Companion reports:** mid-sign BITW transfers — [REPORT.md](REPORT.md) / [REPORT.html](https://davidgroves.github.io/signing-lab/); Knot gate on explicit ZSK withdraw — [REPORT-ZSK-WITHDRAW.md](REPORT-ZSK-WITHDRAW.md)  
**BIND under test:** `9.20.x` (lab image `BIND_TAG=9.20`; analysis against tree at `/home/dwg/CODE/bind9`)  
**Incident context:** production BITW signer, policy **name** changed (`…-8-1024-…` → `…-8-2048-…`), longest zone TTL **24 h**, `max-zone-ttl: P2D` in the new policy

---

## Executive summary

Changing only the **RSA key length** (same algorithm) under `dnssec-policy` is **not** a linked ZSK pre-publication rollover. BIND treats the old key as a **policy mismatch**, retires it immediately (`Inactive = now`, goal `HIDDEN`), and creates a **new** key **without** a Predecessor/Successor link. Without that link, the ZRRSIG→`OMNIPRESENT` timer **skips `Dsgn` (sign delay)**. Rule **[(3f)](https://www.nlnetlabs.nl/downloads/publications/satin2012-Schaeffer.pdf#page=5)** then lets the old same-algorithm ZSK drop its ZRRSIG state as soon as the new ZSK is marked fully published — after roughly **`max-zone-ttl + zone-propagation-delay`**, not after a full-zone re-sign.

When the old DNSKEY is removed, `zone_signwithkey(..., deleteit)` starts deleting old-keytag RRSIGs. On a large zone with slow incremental signing, that removal can happen **while many RRsets still carry only the old keytag**. Validating resolvers then see **RRSIG keytag with no matching DNSKEY** → **BOGUS**.

A **true algorithm change** (e.g. RSASHA256 → ECDSAP256SHA256) hits the same “unmatched → retire” entry point, but rule **(3f)** is **same-algorithm only**. The new ZSK cannot vouch for the old algorithm’s ZRRSIG retirement, so the old ZSK cannot take that early exit. Old DNSKEY (and therefore old-alg RRSIGs) stay until a proper multi-algorithm transition completes — the contrast this lab is built to show.

| Change | Predecessor link? | `Dsgn` in ZRRSIG timer? | Rule (3f) early exit? | Orphan-RRSIG hazard |
|--------|-------------------|-------------------------|------------------------|---------------------|
| Same alg, length 1024→2048 | No (policy mismatch retire) | Skipped | Yes (new ZSK same alg) | **Yes** on large/slow BITW |
| Alg 8→13 (new policy name) | No (mismatch retire) | Skipped for *new* key | **No** (different alg) | **No** (old DNSKEY retained) |

Lab scenarios: BIND-BIND-BIND `scenario-key-policy-change.sh` with `ROLLOVER=size` (expect hazard) and `ROLLOVER=alg` (expect clean contrast); BIND-BIND-KNOT `scenario-key-policy-gate.sh` (NSEC3, Knot validate-on — PASS if distribution never serves invalid).

**Lab confirmation (2026-10-22):** `ROLLOVER=size` on a 10 MiB NSEC zone reproduced the hazard within ~20 s of the policy name switch — old ZSK left DNSKEY while RRSIGs still carried its keytag (`…-nsec-key-policy-size-FAIL`).

---

## Topology

Same BITW contract as the mid-sign report:

```text
primary (unsigned)  --AXFR-->  signer (dnssec-policy + inline-signing)
                                      |
                                      | AXFR/IXFR (must stay valid for DO=1 clients)
                                      v
                               distribution (secondary)
```

The production incident and the lab scenarios both put **key policy on the signer**, not on the unsigned primary.

---

## What happened in the incident (model)

1. Zone stable under policy A (RSA-SHA256 / algorithm 8, ZSK **1024**).
2. Operator switched the zone to policy B by **changing the policy name** (not an in-place edit of the same `dnssec-policy` block). New policy: algorithm 8, ZSK **2048**, `max-zone-ttl: P2D`.
3. Longest **actual** RRset TTL in the zone was **24 h**. BIND’s key-state timers still use the policy’s **`max-zone-ttl`** (here **P2D**), not the observed maximum TTL.
4. Within on the order of **~48 h** (`≈ max-zone-ttl` plus publish/propagation slop — not a 7-day sign-delay rollover), the **1024-bit ZSK left the DNSKEY RRset** while re-signing was still in progress.
5. NSEC3 chain churn looked alarming in logs/AXFR diffs; it was **re-signing under the new key**, not a separate NSEC3PARAM rollover.

```text
  policy A (alg8/1024)                 policy B (alg8/2048)
         |                                      |
         |  dns_kasp_key_match?  alg+length+role
         |         |
         |         +-- no match --> keymgr_key_retire
         |                            Inactive=now, goal=HIDDEN
         |         +-- create new ZSK (no Predecessor)
         v
   old ZRRSIG still OMNIPRESENT
   new ZSK: DNSKEY publish --> ZRRSIG RUMOURED
                |
                |  transition_time(ZRRSIG->OMNIPRESENT):
                |    + max-zone-ttl + zone-propagation-delay
                |    + Dsgn  ONLY if Predecessor|Successor set
                |         ^^^^^^^^ skipped here
                v
   new ZRRSIG OMNIPRESENT  --(3f)-->  old ZRRSIG may go UNRETENTIVE
                |
                v
   old DNSKEY removed  -->  zone_signwithkey(deleteit)
                |
                +-- RRsets not yet re-signed: RRSIG keytag orphaned --> BOGUS
```

---

## BIND code path (keymgr / kasp / zone)

### Policy match is algorithm **and** length

```c
/* lib/dns/kasp.c — dns_kasp_key_match() */
if (dst_key_alg(dkey->key) != dns_kasp_key_algorithm(key))
    return false;
if (dst_key_size(dkey->key) != dns_kasp_key_size(key))
    return false;
```

A 1024-bit ZSK does **not** match a policy that asks for 2048. Same for algorithm mismatches. Unmatched keys are retired; the policy’s key slots are filled with **new** keys.

### Unmatched → immediate retire (not “wait for lifetime”)

`keymgr_key_retire()` sets goal `HIDDEN` and, if needed, **`Inactive = now`**. That is the opposite of a scheduled lifetime rollover, where the successor is created with a Predecessor link before the predecessor’s inactive time.

### Sign delay (`Dsgn`) is gated on Predecessor/Successor

```c
/* lib/dns/keymgr.c — keymgr_transition_time(), DST_KEY_ZRRSIG → OMNIPRESENT */
nexttime = sigtime + ttlsig + dns_kasp_zonepropagationdelay(kasp);
/* Only add the sign delay Dsgn and retire-safety if
 * there is an actual predecessor or successor key. */
if (/* Predecessor or Successor present */) {
    nexttime += signdelay + dns_kasp_retiresafety(kasp);
}
```

`signdelay` ≈ `signatures-validity − signatures-refresh` (often days in production). **Unlinked** keys omit it. The new ZSK can be marked ZRRSIG-`OMNIPRESENT` after **`max-zone-ttl + propagation` alone** — even if the zone is nowhere near fully re-signed.

### Rule (3f) is same-algorithm

The labels (3a)–(3i) are the formal validity rules in Yuri Schaeffer, Benno Overeinder, and Matthijs Mekking, [Flexible and Robust Key Rollover in DNSSEC](https://www.nlnetlabs.nl/downloads/publications/satin2012-Schaeffer.pdf#page=5) (NLnet Labs, SATIN 2012), page 5. Rule 3 covers signatures other than the DNSKEY RRSIG. Equation (3f) is its first alternative: some same-algorithm key has both its DNSKEY and its signatures omnipresent. The paper spells (3f)–(3i) out on [page 6](https://www.nlnetlabs.nl/downloads/publications/satin2012-Schaeffer.pdf#page=6). BIND implements them in `keymgr_have_rrsig()` and cites the paper from `keymgr.c` (equations (1), (2), and (3a)–(3i)). ISC restates the three rules, without these labels, in [DNSSEC Key States](https://kb.isc.org/docs/dnssec-key-states).

In the 9.20.23 tree at `/home/dwg/CODE/bind9`, (3f) is [`lib/dns/keymgr.c` lines 1143 and 1159–1164](https://gitlab.isc.org/isc-projects/bind9/-/blob/v9.20.23/lib/dns/keymgr.c#L1143). The same-algorithm test is the last argument, `match_algorithms`, applied at [lines 823–827](https://gitlab.isc.org/isc-projects/bind9/-/blob/v9.20.23/lib/dns/keymgr.c#L823-827).

```c
/* lib/dns/keymgr.c:1142-1143, 1159-1164 — keymgr_have_rrsig() */
/* DNSKEY,     ZRRSIG,      KRRSIG, DS */
{ OMNIPRESENT, OMNIPRESENT, NA,     NA }, /* (3f) */

/*
 * Equation (3f):
 * There is a key with the same algorithm with its DNSKEY and
 * ZRRSIG records in OMNIPRESENT state.
 */
keymgr_key_exists_with_state(keyring, key, type, next_state,
                             states[0], na, false, true);
```

- **Length change (same alg):** the new ZSK satisfies (3f) for the old ZSK, so the old ZRRSIG may go `UNRETENTIVE`.
- **Algorithm change:** the new ZSK is a different algorithm, so (3f) does not match. The old ZRRSIG stays `OMNIPRESENT`, and the old DNSKEY stays while those RRSIGs are still required.

### Deleting signatures after DNSKEY removal

When the old DNSKEY is removed from the zone, signing walks the zone with **delete** for that key. Incremental quanta (`sig-signing-nodes` / `sig-signing-signatures`) mean the delete pass — like the mid-sign report — is **not atomic**. The BITW secondary can serve a zone where some names still show the old keytag and the DNSKEY RRset no longer includes it.

---

## Contrast diagram

```text
 SAME ALGORITHM, NEW LENGTH                         ALGORITHM CHANGE
 -------------------                                -----------------

  ZSK_old (alg 8, 1024)                             ZSK_old (alg 8)
  ZSK_new (alg 8, 2048)                             ZSK_new (alg 13)

       |                                                 |
       |  (3f): same alg? YES                            |  (3f): same alg? NO
       v                                                 v
  old ZRRSIG → UNRETENTIVE                         old ZRRSIG stays OMNIPRESENT
  after new ZRRSIG OMNIPRESENT                     ((3f) is same-algorithm only)
       |                                                 |
       v                                                 v
  old DNSKEY removed                                old DNSKEY retained
  while re-sign incomplete                          until safe multi-alg transition
       |                                                 |
       v                                                 v
  orphan RRSIG / BOGUS                              validators still find DNSKEY
```

Lifetimeating resolvers do not care that both keys are “algorithm 8” if the **keytag** in the RRSIG is gone from DNSKEY. Algorithm rollover’s dual-algorithm period is a different (and better understood) dance; the length-only trap is easy to miss because the ARM describes smooth **lifetime** rollovers and **algorithm** rollovers — not “replace key length by switching policy name.”

---

## Timing model (incident vs lab)

| Knob | Incident (approx.) | Lab short-timer policies |
|------|--------------------|---------------------------|
| Longest real TTL | **24 h** | zone `$TTL 300` |
| `max-zone-ttl` | **P2D** (drives timers) | **15s** (opens the unlinked window before a large-zone re-sign finishes) |
| `dnskey-ttl` / safety | hours | 5s / 0 |
| Linked `Dsgn` | ~days if predecessor existed | ~45 m if predecessor existed |
| Observed to old-ZSK removal | **~48 h** | order of **minutes** after switch |

Important: operators who assume “timers follow the longest TTL in the zone (24 h)” will under-estimate wait if `max-zone-ttl` is larger (P2D). Conversely, setting `max-zone-ttl` high “for safety” **extends** the unlinked omnipresent wait — but still **without** guaranteeing a full re-sign, because `Dsgn` was skipped.

---

## Safeguards (operational)

1. **Do not change ZSK/KSK length by swapping policy names** on a live signed zone. Prefer a planned lifetime rollover, or introduce the new length as an **additional** key in `keys { ... }` and remove the old only after coverage.
2. **`manual-mode yes;`** during policy surgery; step with `rndc dnssec -step` only when coverage is verified.
3. Temporarily **raise** `max-zone-ttl` / add explicit wait until every signable RRset carries the **new** keytag (AXFR oracle), before allowing old DNSKEY removal — understanding that unlinked keys still skip `Dsgn`.
4. For algorithm changes, follow a multi-algorithm transition; do not treat them as interchangeable with length changes.
5. On BITW, remember mid-sign **PARTLY_SIGNED** publication (see [REPORT.md](REPORT.md)) can compound key-transition damage for `DO=1` clients.

---

## Lab reproduction

### BIND-BIND-BIND — reproduce the orphan hazard

```bash
cd BIND-BIND-BIND
# Prefer ZONESIZE≥10 so re-sign outlasts the unlinked max-zone-ttl window.
# Same algorithm, 1024 → 2048 (expect FAIL = orphan RRSIG hazard)
ZONESIZE=10 ROLLOVER=size ./scripts/scenario-key-policy-change.sh

# Algorithm 8 → 13 (expect PASS = no orphan while old DNSKEY retained)
ZONESIZE=10 ROLLOVER=alg ./scripts/scenario-key-policy-change.sh
```

Oracle: `COMMON/scripts/check-orphan-rrsig.py` — RRSIGs whose keytag is not present in the apex DNSKEY RRset.

### BIND-BIND-KNOT — Knot gate after the same length switch (NSEC3)

Same 1024→2048 policy-name switch on a large NSEC3 zone with short-timer policies `repro-nsec3-rsa1024` / `repro-nsec3-rsa2048`, Knot distribution `dnssec-validation: on`.

**PASS** if distribution never serves an invalid zone (`UNSIGNED` / `PARTLY_SIGNED` / orphan RRSIG), including when AXFR is unavailable. **FAIL** if Knot ever answers with invalid content.

```bash
cd BIND-BIND-KNOT
ZONESIZE=10 MODE=nsec3 ./scripts/scenario-key-policy-gate.sh
```

Standalone (not in `./run-all.sh`). Signer-side orphan checks are diagnostic only.

---

## Relation to the mid-sign report

| Report | Failure mode |
|--------|----------------|
| [REPORT.md](REPORT.md) | BIND commits/notifies **during** `zone_sign` quanta → `PARTLY_SIGNED` AXFR |
| This report | Key **state machine** removes DNSKEY / deletes RRSIGs **before** full re-sign after an unlinked length change |

Both break validating end users; they are independent bugs/hazards in the same BITW posture.
