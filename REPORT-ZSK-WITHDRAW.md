# Knot `dnssec-validation`: ZSK withdraw never reaches clients

**Date:** 2026-10-29  
**Lab:** [github.com/davidgroves/signing-lab](https://github.com/davidgroves/signing-lab) — stack [`BIND-KNOT-manualsigning/`](BIND-KNOT-manualsigning/)  
**Companion reports:** mid-sign BITW — [REPORT.md](REPORT.md); key-policy orphans — [REPORT-KEY-POLICY.md](REPORT-KEY-POLICY.md)  
**BIND under test:** `9.20.x` (image `BIND_TAG=9.20`); **no** `dnssec-policy` / inline-signing on this stack  
**Knot under test:** `3.6.1` (`cznic/knot` / `KNOT_TAG=latest`)  
**Knot source cited below:** tag [`v3.6.1`](https://github.com/CZ-NIC/knot/tree/v3.6.1) (`15a5f7a`)  
**Definitive runs:**  
- **Clean apex + non-apex orphans (proof target)** — `BIND-KNOT-manualsigning/artifacts/20261029T164827Z-zsk-withdraw-clean-apex-ixfr-PASS`  
- ZSK DNSKEY only — `BIND-KNOT-manualsigning/artifacts/20261029T153750Z-zsk-withdraw-ixfr-PASS`  
- ZSK + apex ZSK-RRSIG strip — `BIND-KNOT-manualsigning/artifacts/20261029T155557Z-zsk-withdraw-apex-strip-ixfr-PASS`

---

## Executive summary

Removing the **ZSK DNSKEY** from an otherwise still-signed zone (RRSIGs left intact) produces a classic **orphan-RRSIG** hazard: validating resolvers would see signatures whose keytag is absent from DNSKEY.

This stack puts that broken serial on a **BIND primary** that does **not** re-sign, and a **Knot secondary** with `dnssec-validation: on`. Knot **receives** the IXFR/AXFR for the bad serial, **fails DNSSEC validation before `zone_switch_contents`**, discards the update, and **keeps serving the last good serial**. Lab polls never saw the no-ZSK serial on distribution AXFR.

| Serial | Zone state | BIND primary | Knot distribution |
|-------:|------------|:------------:|:-----------------:|
| **1** | KSK + ZSK, fully signed | serves | **serves** (held through withdraw) |
| **2** | ZSK DNSKEY removed; orphan RRSIGs (keytag 59678) | serves | **never** |
| **3** | Offline `dnssec-signzone` restore (same keys) | serves | **serves** (accepted immediately) |

Verdict: **PASS** — Knot never served no-ZSK serial 2; kept serial 1 for ≥60 s; then accepted restored serial 3.

---

## Topology

Not the three-box BITW layout. BIND is a dumb primary for a **pre-signed** zone file:

```text
  offline dnssec-signzone (NSEC3, KSK+ZSK)
              |
              v
  BIND primary  --IXFR/AXFR-->  Knot distribution
  (ixfr-from-differences)       dnssec-signing: off
  no inline-signing             dnssec-validation: on
```

### Proof target: clean apex, ZSK still required elsewhere

With a normal KSK/ZSK split, simply deleting the ZSK DNSKEY (or stripping apex ZSK RRSIGs) makes **apex `NS`/`SOA` fail first** — that does **not** isolate “other records still need the ZSK.”

Knot’s validator, however, loads DNSKEYs with **`is_zsk = true` for every key** (`src/knot/dnssec/kasp/kasp_zone.c`), so a **KSK can validate apex zone data** after the ZSK is gone. That lets us build a fair IXFR:

1. Serial **1**: normal KSK+ZSK NSEC3 zone.
2. Serial **2**: re-sign the zone with **KSK only** (`dnssec-signzone -S -z`); then replace RRSIGs on `www`/`app`/`ns1`/`txt1` with the **old ZSK** signatures (ZSK absent from DNSKEY). Apex + NSEC3 stay KSK-valid (**0** apex orphans).
3. Knot must reject serial 2; validation hint should be a **non-apex** name (lab: `app.manual.test.example. A`).

Script: [`scenario-zsk-withdraw-clean-apex-ixfr.sh`](BIND-KNOT-manualsigning/scripts/scenario-zsk-withdraw-clean-apex-ixfr.sh) — **PASS** `20261029T164827Z-…-PASS` (apex orphan=0, non-apex orphan=4; never served serial 2; restored serial 3).

### Related variants

| Script | Primary hazard | Typical Knot hint |
|--------|----------------|-------------------|
| [`…-ixfr.sh`](BIND-KNOT-manualsigning/scripts/scenario-zsk-withdraw-ixfr.sh) | Drop ZSK DNSKEY; leave all ZSK RRSIGs | apex `NS` (orphan) |
| [`…-apex-strip-ixfr.sh`](BIND-KNOT-manualsigning/scripts/scenario-zsk-withdraw-apex-strip-ixfr.sh) | Drop ZSK + apex ZSK RRSIGs; non-apex orphans linger | apex `NS` (**unsigned**) |
| [`…-clean-apex-ixfr.sh`](BIND-KNOT-manualsigning/scripts/scenario-zsk-withdraw-clean-apex-ixfr.sh) | KSK-clean apex; ZSK orphans only on non-apex | **`app … A`** (non-apex) |

`nsupdate` is deliberately avoided: on a DNSSEC-signed zone BIND treats updates as secure and would try to maintain RRSIGs — the opposite of this hazard.

---

## What the lab observed

From `after-watch/distribution.log` / `after-restore/distribution.log` (run `20261029T153750Z`):

```text
# good load
AXFR incoming … remote serial 1
DNSSEC, validation successful, checked RRSIGs 25
refresh … serial none -> 1

# ZSK withdrawn on primary (serial 2)
notify … serial 2
IXFR incoming … remote serial 2
DNSSEC, incremental validation failed (no valid signature for a record)
DNSSEC, validation hint: manual.test.example. NS
AXFR incoming … remote serial 2          # fallback after IXFR reject
DNSSEC, validation failed (no valid signature for a record)
DNSSEC, validation hint: manual.test.example. NS
AXFR outgoing … serial 1                 # clients still get the good zone

# restore (serial 3)
AXFR incoming … remote serial 3
DNSSEC, validation successful, checked RRSIGs 25
refresh … serial 1 -> 3
```

Primary after withdraw: DNSKEY keytags **[29443]** (KSK only); **12** orphan RRSIGs still keyed **59678** (ex-ZSK). Knot never published that view.

---

## Why this works in the Knot codebase

### Validation treats every DNSKEY as a ZSK

When building keys from the candidate zone for validation (`kasp_zone_keys_from_rr`):

```c
zone->keys[i].is_ksk = (knot_dnskey_flags(zkey) & DNSKEY_FLAGS_KSK) == DNSKEY_FLAGS_KSK;
zone->keys[i].is_zsk = true; // any KSK might behave like ZSK … for validation
```

So after a clean ZSK withdrawal, apex `NS`/`SOA`/NSEC3 signed by the remaining KSK still verify. RRSIGs whose **keytag is absent** from DNSKEY (the lingering ZSK on `app`/`www`/…) fail `knot_validate_rrsigs()` → `KNOT_DNSSEC_ENOSIG`. That is the clean-apex proof.

### Gate sits before publish

Knot’s documented behaviour matches the code path used on every zone update (load, IXFR, AXFR):

> When the validation fails, the zone being loaded or update being applied is cancelled with an error, and either none or previous zone state is published.  
> — `doc/reference.rst`, `zone_dnssec-validation` (`v3.6.1`)

### 1. Gate sits *before* the contents switch

`zone_update_commit()` (`src/knot/updates/zone-update.c`) reads `C_DNSSEC_VALIDATION`. If on, it calls `knot_dnssec_validate_zone()` and, on any error, **`discard_adds_tree(update)` and return** — never reaching `zone_switch_contents()`:

```c
val = conf_zone_get(conf, C_DNSSEC_VALIDATION, update->zone->name);
if (conf_bool(&val)) {
    validation_conf_t val_conf = {
        .conf = conf,
        .incremental = update->flags & UPDATE_INCREMENTAL,
        .fast = false,
        .log_plan = true,
    };
    ret = knot_dnssec_validate_zone(update, &val_conf);
    if (ret != KNOT_EOK) {
        discard_adds_tree(update);
        return ret;
    }
}
/* … journal … */
/* Switch zone contents. */
old_contents = zone_switch_contents(update->zone, update->new_cont);
```

IXFR finalization in `refresh.c` only publishes after a successful `zone_update_commit()`. A validation failure there leaves the previous `zone->contents` (serial 1) answering queries — exactly the outgoing `AXFR … serial 1` lines above.

### 2. Validator keys come from the *candidate* DNSKEY RRset

`knot_dnssec_validate_zone()` (`src/knot/dnssec/zone-events.c`) builds a validation context from **`update->new_cont`**, not from KASP private keys and not from the old zone:

```c
ret = kdnssec_validation_ctx(val_conf->conf, &ctx, update->new_cont,
                             val_conf->threads);
/* … */
ctx.validation_mode = true;   /* set inside kdnssec_validation_ctx */
```

`kasp_zone_from_contents()` loads whatever DNSKEYs are in the **new** apex. After the withdraw IXFR, that set is **KSK only**. RRSIGs still carry keytag **59678** (the removed ZSK).

### 3. Failure mode is `KNOT_DNSSEC_ENOSIG` (“no valid signature for a record”)

In validation mode, `sign_node_rrsets()` (`src/knot/dnssec/zone-sign.c`) does not sign; it calls `knot_validate_rrsigs()`:

- For apex `NS` / most RRtypes, `key_used()` requires a **ZSK** (`is_zsk`).
- With only the KSK left in the keyset, no usable key matches the ZSK RRSIGs.
- `knot_validate_rrsigs()` returns **`KNOT_DNSSEC_ENOSIG`** when no valid signature exists for a required key — the same string Knot logs (`src/libknot/error.c`).

That matches the lab hint: `validation hint: manual.test.example. NS`.

Doc checklist for the same check: *“Every zone RRSet is correctly signed by at least one present DNSKEY.”*

### 4. DNSKEY change forces a full walk even on an “incremental” update

`knot_zone_sign_update()` notices apex DNSKEY / NSEC3PARAM changes via `apex_dnssec_changed()` and falls through to a **full** `knot_zone_sign()` even when `validation_conf.incremental` is true (IXFR). So removing the ZSK is not a narrow incremental pass that could miss orphans elsewhere in the zone — the whole candidate contents are checked. The log still prefixes *“incremental ”* because that flag reflects the update type, not the scope of the crypto walk.

After IXFR reject, refresh falls back to AXFR; full validation fails the same way; serial 2 still never switches in.

### 5. Restore succeeds for the complementary reason

Serial **3** is produced by offline `dnssec-signzone` with the **same** KSK+ZSK. Candidate DNSKEY again contains keytag 59678; RRSIGs verify; `zone_update_commit` switches `1 → 3`. Lab: `validation successful, checked RRSIGs 25` then distribution AXFR `FULLY_SIGNED serial=3`.

---

## Relation to the other reports

| Report | Hazard | Gate |
|--------|--------|------|
| [REPORT.md](REPORT.md) | BIND BITW mid-sign → `PARTLY_SIGNED` | Knot validate-on → often `AXFR_UNAVAILABLE` while BIND still publishes junk |
| [REPORT-KEY-POLICY.md](REPORT-KEY-POLICY.md) | Same-alg ZSK length change → orphan RRSIGs during slow re-sign | Same Knot gate in BBK `scenario-key-policy-gate.sh` |
| **This report** | Explicit ZSK DNSKEY withdraw **without** re-sign | Knot keeps last good serial; primary still serves orphans |

This stack isolates the **distribution gate** with no middle signer and no BIND signing at all: the primary is *supposed* to publish the broken serial; Knot is the only safety rail.

---

## Reproduce

```bash
cd BIND-KNOT-manualsigning
./clean.sh
./scripts/scenario-zsk-withdraw-ixfr.sh
```

PASS criterion (scenario): Knot never serves `serial_bad`; then accepts `serial_restored` with ZSK present; validation reject logged; good serial kept during the withdraw window.
