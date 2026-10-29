# BIND-KNOT-manualsigning

Topology: **BIND primary (hand-signed zone file) → Knot secondary** (`dnssec-validation: on`).

No middle signer. BIND does **not** run `dnssec-policy` / inline-signing. The
zone is produced offline with `dnssec-signzone` (NSEC3, KSK + ZSK) and BIND
only serves it.

Scenarios (after Knot has a valid copy):

| Script | Hazard on primary |
|--------|-------------------|
| `scenario-zsk-withdraw-ixfr.sh` | Remove **ZSK DNSKEY** only; all old ZSK RRSIGs remain (incl. apex) |
| `scenario-zsk-withdraw-apex-strip-ixfr.sh` | Remove ZSK DNSKEY **and** apex ZSK RRSIGs (apex NS becomes unsigned); non-apex orphans linger |
| `scenario-zsk-withdraw-clean-apex-ixfr.sh` | **Proof target:** apex valid under KSK only (ZSK gone); non-apex names keep ZSK-only RRSIGs → Knot hint is e.g. `app … A` |

Both then:

1. Bump SOA (`serial_bad`), `rndc reload` → IXFR via `ixfr-from-differences` (BIND does not re-sign).
2. Watch **60s**: Knot must **never** serve `serial_bad`, nor orphans / `PARTLY_SIGNED`.
3. Restore via offline `dnssec-signzone` (same keys) at `serial_restored`; Knot must accept it with the ZSK present.

| Outcome | Meaning |
|---------|---------|
| **PASS** | Never served hazard serial; then accepted restored valid serial |
| **FAIL** | Served hazard serial / orphans / partly signed, or never recovered after restore |

```bash
./clean.sh
./scripts/scenario-zsk-withdraw-clean-apex-ixfr.sh   # clean apex + lingering orphans
./scripts/scenario-zsk-withdraw-ixfr.sh
./scripts/scenario-zsk-withdraw-apex-strip-ixfr.sh
# or: ./run-all.sh   # all three
```

| Role | Software | Address | Host port |
|------|----------|---------|-----------|
| primary | BIND (static signed zone; no signing) | 172.30.57.10 | 55353 |
| distribution | Knot `dnssec-validation: on` | 172.30.57.30 | 55355 |

Zone: `manual.test.example` (built by `scripts/build-signed-zone.sh`).

**Why not `nsupdate`?** On a DNSSEC-signed zone BIND treats dynamic updates as
secure updates and tries to maintain RRSIGs/NSEC3 (needs private keys / would
re-sign). That is the opposite of this test. Zonefile edit + reload keeps BIND
as a dumb primary.

Shared oracle: [`../COMMON/scripts/check-orphan-rrsig.py`](../COMMON/scripts/check-orphan-rrsig.py), [`../COMMON/scripts/check-zone-signed.sh`](../COMMON/scripts/check-zone-signed.sh).

Report (lab result + Knot source path): [`../REPORT-ZSK-WITHDRAW.md`](../REPORT-ZSK-WITHDRAW.md) / [`../REPORT-ZSK-WITHDRAW.html`](../REPORT-ZSK-WITHDRAW.html).
