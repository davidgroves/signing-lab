#!/usr/bin/env python3
"""Detect RRSIGs whose keytag is not present in the apex DNSKEY RRset.

Exit 0 if orphans found (hazard), 1 if clean, 2 on usage/parse errors.
Writes ORPHAN_RRSIG.md when --out-dir is set.
"""
from __future__ import annotations

import argparse
import base64
import re
import struct
import sys
from collections import defaultdict
from pathlib import Path


def rfc4034_keytag(flags: int, protocol: int, algorithm: int, key: bytes) -> int:
    """Key Tag from RFC 4034 Appendix B (non-RSAMD5).

    Even-indexed bytes are shifted left 8; odd-indexed bytes are not.
    """
    rdata = struct.pack("!HBB", flags, protocol, algorithm) + key
    ac = 0
    for i, b in enumerate(rdata):
        ac += (b << 8) if (i & 1) == 0 else b
    ac += (ac >> 16) & 0xFFFF
    return ac & 0xFFFF


def parse_axfr(path: str, zone: str):
    apex = zone.lower().rstrip(".") + "."
    dnskeys: dict[int, dict] = {}
    rrsigs: dict[tuple[str, str], set[int]] = defaultdict(set)

    dnskey_re = re.compile(
        r"^(\S+)\s+\d+\s+IN\s+DNSKEY\s+(\d+)\s+(\d+)\s+(\d+)\s+(.+)$",
        re.I,
    )
    rrsig_re = re.compile(
        r"^(\S+)\s+\d+\s+IN\s+RRSIG\s+(\S+)\s+(\d+)\s+(\d+)\s+(\d+)\s+"
        r"(\S+)\s+(\S+)\s+(\d+)\s+(\S+)\s+(.+)$",
        re.I,
    )

    pending_dnskey = None  # (owner, flags, proto, alg, b64parts)

    def flush_dnskey():
        nonlocal pending_dnskey
        if not pending_dnskey:
            return
        owner, flags, proto, alg, parts = pending_dnskey
        pending_dnskey = None
        if owner != apex:
            return
        b64 = "".join(parts)
        try:
            key = base64.b64decode(b64)
        except Exception:
            return
        tag = rfc4034_keytag(flags, proto, alg, key)
        dnskeys[tag] = {"flags": flags, "protocol": proto, "alg": alg}

    for raw in open(path, encoding="utf-8", errors="replace"):
        line = raw.rstrip("\n")
        stripped = line.strip()
        if not stripped or stripped.startswith(";"):
            continue

        # Continuation of multiline DNSKEY (dig +multiline / some AXFR pretty-print)
        if pending_dnskey and (line.startswith(" ") or line.startswith("\t")):
            part = stripped.split(";", 1)[0].strip()
            if part:
                pending_dnskey[4].append(part.replace(" ", ""))
            if "key id" in stripped.lower():
                flush_dnskey()
            continue
        if pending_dnskey:
            flush_dnskey()

        m = dnskey_re.match(stripped.split(";", 1)[0].strip())
        if m:
            owner = m.group(1).lower()
            if not owner.endswith("."):
                owner += "."
            flags, proto, alg = int(m.group(2)), int(m.group(3)), int(m.group(4))
            rest = m.group(5).strip()
            # Single-line key material (may still have spaces)
            if "(" in rest:
                pending_dnskey = [owner, flags, proto, alg, []]
                after = rest.split("(", 1)[1]
                after = after.split(";", 1)[0].strip()
                if after and after != ")":
                    pending_dnskey[4].append(after.replace(")", "").replace(" ", ""))
                if ")" in rest:
                    flush_dnskey()
            else:
                b64 = rest.replace(" ", "")
                try:
                    key = base64.b64decode(b64)
                except Exception:
                    continue
                tag = rfc4034_keytag(flags, proto, alg, key)
                if owner == apex:
                    dnskeys[tag] = {
                        "flags": flags,
                        "protocol": proto,
                        "alg": alg,
                    }
            continue

        m = rrsig_re.match(stripped.split(";", 1)[0].strip())
        if m:
            owner = m.group(1).lower()
            if not owner.endswith("."):
                owner += "."
            covers = m.group(2).upper()
            keytag = int(m.group(8))
            rrsigs[(owner, covers)].add(keytag)
            continue

        # dig default RRSIG: name TTL CLASS RRSIG covered alg labels origttl
        # expiration inception keytag signer sig...
        p = stripped.split()
        if len(p) >= 11 and p[3].upper() == "RRSIG":
            owner = p[0].lower()
            if not owner.endswith("."):
                owner += "."
            try:
                keytag = int(p[10])
            except ValueError:
                continue
            rrsigs[(owner, p[4].upper())].add(keytag)
            continue
        if len(p) >= 7 and p[3].upper() == "DNSKEY":
            owner = p[0].lower()
            if not owner.endswith("."):
                owner += "."
            if owner != apex:
                continue
            try:
                flags, proto, alg = int(p[4]), int(p[5]), int(p[6])
            except ValueError:
                continue
            b64 = "".join(p[7:]).split(";", 1)[0].replace(" ", "")
            try:
                key = base64.b64decode(b64)
            except Exception:
                continue
            tag = rfc4034_keytag(flags, proto, alg, key)
            dnskeys[tag] = {"flags": flags, "protocol": proto, "alg": alg}

    if pending_dnskey:
        flush_dnskey()

    return apex, dnskeys, rrsigs


def zsk_tags(dnskeys: dict[int, dict], alg: int | None = None) -> list[int]:
    # SEP bit (bit 0) set => KSK (flags 257); ZSK typically 256.
    out = []
    for t, m in dnskeys.items():
        if (m["flags"] & 0x0001) != 0:
            continue
        if alg is not None and m["alg"] != alg:
            continue
        out.append(t)
    return sorted(out)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--axfr", required=True, help="AXFR text dump")
    ap.add_argument("--zone", required=True)
    ap.add_argument(
        "--only-keytags",
        help="Comma-separated keytags to consider (e.g. retired ZSKs)",
    )
    ap.add_argument(
        "--list-zsk",
        action="store_true",
        help="Print ZSK keytags (one per line) and exit 0",
    )
    ap.add_argument(
        "--alg",
        type=int,
        default=None,
        help="With --list-zsk, only ZSKs of this DNSKEY algorithm number",
    )
    ap.add_argument(
        "--list-dnskey",
        action="store_true",
        help="Print keytag flags alg per line and exit 0",
    )
    ap.add_argument("--out-dir", type=Path, default=None)
    args = ap.parse_args()

    apex, dnskeys, rrsigs = parse_axfr(args.axfr, args.zone)

    if args.list_dnskey:
        for t in sorted(dnskeys):
            m = dnskeys[t]
            print(f"{t} {m['flags']} {m['alg']}")
        return 0

    if args.list_zsk:
        for t in zsk_tags(dnskeys, alg=args.alg):
            print(t)
        return 0

    present = set(dnskeys)
    only: set[int] | None = None
    if args.only_keytags:
        only = {int(x.strip()) for x in args.only_keytags.split(",") if x.strip()}

    orphans: list[tuple[str, str, int]] = []
    for (owner, covers), tags in sorted(rrsigs.items()):
        for tag in sorted(tags):
            if only is not None and tag not in only:
                continue
            if tag not in present:
                orphans.append((owner, covers, tag))

    lines = [
        f"# Orphan RRSIG check — `{args.zone}`",
        "",
        f"- Apex: `{apex}`",
        f"- DNSKEY keytags present: {sorted(present) or '(none)'}",
        f"- ZSK keytags: {zsk_tags(dnskeys) or '(none)'}",
        f"- Filter keytags: {sorted(only) if only else '(all)'}",
        f"- Orphan (owner, covers, keytag) count: **{len(orphans)}**",
        "",
    ]
    if orphans:
        lines.append("| Owner | Covers | Keytag |")
        lines.append("|-------|--------|-------:|")
        for owner, covers, tag in orphans[:50]:
            lines.append(f"| `{owner}` | {covers} | {tag} |")
        if len(orphans) > 50:
            lines.append(f"| … | … | ({len(orphans) - 50} more) |")
        lines.append("")
        lines.append("**HAZARD:** RRSIG keytag not in DNSKEY RRset.")
    else:
        lines.append("No orphan RRSIGs for the selected keytags.")

    text = "\n".join(lines) + "\n"
    if args.out_dir:
        args.out_dir.mkdir(parents=True, exist_ok=True)
        (args.out_dir / "ORPHAN_RRSIG.md").write_text(text, encoding="utf-8")
        (args.out_dir / "orphan-count.txt").write_text(
            str(len(orphans)) + "\n", encoding="utf-8"
        )
    sys.stdout.write(text)
    return 0 if orphans else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except BrokenPipeError:
        raise SystemExit(0)
