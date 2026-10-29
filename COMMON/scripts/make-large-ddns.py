#!/usr/bin/env python3
"""Emit an nsupdate script that rewrites many existing TXT RRsets (large resign).

Reads the zone file to discover a####### owners, then emits delete+add TXT
updates for the first --count of them (or all if --count 0).
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--zone-file", type=Path, required=True)
    p.add_argument("--zone", required=True, help="Zone apex (no trailing dot OK)")
    p.add_argument("--server", default="127.0.0.1")
    p.add_argument("--port", type=int, required=True)
    p.add_argument(
        "--count",
        type=int,
        default=5000,
        help="How many a####### TXT RRsets to rewrite (0 = all found)",
    )
    p.add_argument(
        "--payload",
        default="Y" * 64,
        help="New TXT payload (default: 64×Y)",
    )
    p.add_argument(
        "--mode",
        choices=("giant", "burst"),
        default="giant",
        help="giant = few large sends in one nsupdate; burst = many tiny sends",
    )
    p.add_argument(
        "--burst-size",
        type=int,
        default=25,
        help="RRsets per send for burst mode (default 25)",
    )
    p.add_argument(
        "--giant-chunk",
        type=int,
        default=150,
        help="RRsets per send for giant mode (nsupdate packet limit; default 150)",
    )
    p.add_argument("-o", "--output", type=Path, default=None)
    return p.parse_args()


def owners_from_zone(path: Path, apex: str) -> list[str]:
    apex = apex.rstrip(".").lower()
    pat = re.compile(r"^(a\d{7})\s+IN\s+TXT\b", re.IGNORECASE)
    out: list[str] = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        m = pat.match(line.strip())
        if m:
            out.append(f"{m.group(1).lower()}.{apex}.")
    return out


def main() -> int:
    args = parse_args()
    apex = args.zone.rstrip(".")
    owners = owners_from_zone(args.zone_file, apex)
    if not owners:
        print(f"no a####### TXT owners in {args.zone_file}", file=sys.stderr)
        return 2
    count = len(owners) if args.count <= 0 else min(args.count, len(owners))
    owners = owners[:count]
    payload = args.payload.replace('"', '\\"')

    chunk = args.burst_size if args.mode == "burst" else max(1, args.giant_chunk)
    lines: list[str] = [
        f"server {args.server} {args.port}",
        f"zone {apex}.",
    ]
    pending = 0
    for name in owners:
        lines.append(f"update delete {name} TXT")
        lines.append(f'update add {name} 300 TXT "{payload}"')
        pending += 1
        if pending >= chunk:
            lines.append("send")
            pending = 0
    if pending:
        lines.append("send")
    lines.append("quit")

    text = "\n".join(lines) + "\n"
    if args.output:
        args.output.write_text(text, encoding="utf-8")
        print(
            f"wrote {args.output}: mode={args.mode} updates={count} "
            f"owners_available={len(owners_from_zone(args.zone_file, apex))}",
            file=sys.stderr,
        )
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
