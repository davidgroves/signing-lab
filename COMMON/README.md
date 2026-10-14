# COMMON — shared lab pieces

| Path | Purpose |
|------|---------|
| `scripts/lib-common.sh` | Modes, dig helpers, artifacts, zone generate/install, scenario poll budget (`MAX_ITERS=1` default) |
| `scripts/generate-zone.py` | Synthetic zone files (`--size-mb`, `--zone`, opt-out delegations) |
| `scripts/check-zone-signed.sh` | AXFR RRSIG coverage oracle (sources stack `lib.sh` via symlink) |
| `zones/*.starter` | Tiny starter zones copied into each stack’s `zones/` |

Stacks symlink the scripts:

```text
<stack>/scripts/check-zone-signed.sh -> ../../COMMON/scripts/check-zone-signed.sh
(same for BIND-BIND-BIND, BIND-BIND-KNOT, BIND-KNOT-BIND, KNOT-KNOT-KNOT)
```
