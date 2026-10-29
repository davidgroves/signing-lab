#!/usr/bin/env python3
"""Rewrite many RRsets in a zone file and bump the SOA serial (reload path).

Changes a####### A + TXT so the BITW signer must re-sign a large delta after
rndc reload on the primary.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--zone-file", type=Path, required=True)
    p.add_argument("--serial", type=int, required=True)
    p.add_argument("--txt-payload", default="Z" * 64)
    p.add_argument(
        "--count",
        type=int,
        default=0,
        help="Rewrite only the first N a####### owners (0 = all)",
    )
    return p.parse_args()


def bump_soa_serial(text: str, serial: int) -> str:
    new, n = re.subn(
        r"(SOA\b[\s\S]*?\()([\s\S]*?)(\))",
        lambda m: m.group(1)
        + re.sub(r"\b\d+\b", str(serial), m.group(2), count=1)
        + m.group(3),
        text,
        count=1,
        flags=re.IGNORECASE,
    )
    if n != 1:
        raise SystemExit("failed to patch SOA serial")
    return new


def main() -> int:
    args = parse_args()
    path = args.zone_file
    text = bump_soa_serial(path.read_text(encoding="utf-8"), args.serial)
    lines = text.splitlines(keepends=True)

    a_line = re.compile(r"^(a\d{7})(\s+IN\s+A\s+)\S+(\s*)$", re.I)
    txt_line = re.compile(r'^(a\d{7})(\s+IN\s+TXT\s+)".*?"(\s*)$', re.I)

    order: list[str] = []
    for ln in lines:
        m = a_line.match(ln.rstrip("\n"))
        if m:
            lab = m.group(1).lower()
            if lab not in order:
                order.append(lab)
    if args.count > 0:
        order = order[: args.count]
    allowed = set(order)
    index = {lab: i for i, lab in enumerate(order)}

    payload = args.txt_payload.replace("\\", "\\\\").replace('"', '\\"')
    n_a = n_txt = 0
    out: list[str] = []
    for ln in lines:
        raw = ln.rstrip("\n")
        eol = "\n" if ln.endswith("\n") else ""
        m_a = a_line.match(raw)
        if m_a and m_a.group(1).lower() in allowed:
            octet = (100 + (index[m_a.group(1).lower()] % 155)) % 255 or 1
            out.append(f"{m_a.group(1)}{m_a.group(2)}203.0.113.{octet}{eol}")
            n_a += 1
            continue
        m_t = txt_line.match(raw)
        if m_t and m_t.group(1).lower() in allowed:
            out.append(f'{m_t.group(1)}{m_t.group(2)}"{payload}"{eol}')
            n_txt += 1
            continue
        out.append(ln)

    path.write_text("".join(out), encoding="utf-8")
    print(
        f"mutated {path}: serial={args.serial} owners={len(allowed)} A={n_a} TXT={n_txt}",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
