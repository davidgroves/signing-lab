#!/usr/bin/env python3
"""Generate a deterministic synthetic zone file of approximately TARGET_MB megabytes."""

from __future__ import annotations

import argparse
import os
import sys


PRESETS = {
    "smoke": 1,
    "10": 10,
    "100": 100,
    "500": 500,
    "1024": 1024,
}


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument(
        "--size-mb",
        type=int,
        default=None,
        help="Target zone file size in megabytes (MiB).",
    )
    p.add_argument(
        "--preset",
        choices=sorted(PRESETS.keys()),
        default=None,
        help="Named size preset.",
    )
    p.add_argument(
        "--zone",
        default=os.environ.get("ZONE_NAME", "nsec.test.example"),
        help="Zone apex (default: nsec.test.example or $ZONE_NAME).",
    )
    p.add_argument(
        "--output",
        default=None,
        help="Output path (default: zones/db.<zone>).",
    )
    p.add_argument(
        "--serial",
        type=int,
        default=1,
        help="SOA serial to embed.",
    )
    p.add_argument(
        "--delegations",
        type=int,
        default=None,
        help="Number of insecure NS delegations (for NSEC3 opt-out). "
        "Default: 100 if zone name contains 'optout', else 0.",
    )
    return p.parse_args()


def resolve_size_mb(args: argparse.Namespace) -> int:
    if args.preset is not None:
        return PRESETS[args.preset]
    if args.size_mb is not None:
        return args.size_mb
    env = os.environ.get("ZONE_SIZE_MB")
    if env:
        return int(env)
    return 10


def resolve_delegations(args: argparse.Namespace, zone: str) -> int:
    if args.delegations is not None:
        return max(0, args.delegations)
    if "optout" in zone.lower():
        return 100
    return 0


def write_zone(path: str, zone: str, size_mb: int, serial: int, delegations: int) -> int:
    apex = zone if zone.endswith(".") else zone + "."
    target = size_mb * 1024 * 1024
    os.makedirs(os.path.dirname(os.path.abspath(path)) or ".", exist_ok=True)

    txt_payload = "x" * 64
    header = f"""\
$ORIGIN {apex}
$TTL 300
@	IN	SOA	ns1.{apex} hostmaster.{apex} (
			{serial}		; serial
			30		; refresh
			15		; retry
			3600		; expire
			300		; minimum
			)
	IN	NS	ns1.{apex}
	IN	NS	ns2.{apex}
ns1	IN	A	172.30.53.10
ns2	IN	A	172.30.53.20
"""

    with open(path, "w", encoding="ascii", newline="\n") as fh:
        fh.write(header)
        # Insecure delegations (no DS) — useful for NSEC3 opt-out coverage.
        for d in range(1, delegations + 1):
            label = f"deleg{d:04d}"
            fh.write(f"{label}	IN	NS	ns.{label}.{apex}\n")
            fh.write(f"ns.{label}	IN	A	198.51.100.{(d % 254) + 1}\n")

        n = 0
        while fh.tell() < target:
            n += 1
            label = f"a{n:07d}"
            fh.write(f"{label}	IN	A	192.0.2.{(n % 254) + 1}\n")
            fh.write(f"{label}	IN	TXT	\"{txt_payload}\"\n")
            if n % 100000 == 0:
                print(f"  ... {n} owners, {fh.tell() / (1024 * 1024):.1f} MiB", file=sys.stderr)

    final = os.path.getsize(path)
    print(
        f"Wrote {path}: {final} bytes ({final / (1024 * 1024):.2f} MiB), "
        f"{n} owners, {delegations} delegations, serial {serial}",
        file=sys.stderr,
    )
    return n


def main() -> int:
    args = parse_args()
    size_mb = resolve_size_mb(args)
    if size_mb < 1:
        print("--size-mb must be >= 1", file=sys.stderr)
        return 2

    zone = args.zone.rstrip(".")
    delegations = resolve_delegations(args, zone)
    out = args.output
    if not out:
        root = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
        out = os.path.join(root, "zones", f"db.{zone}")

    print(
        f"Generating ~{size_mb} MiB zone {zone} "
        f"(delegations={delegations}) -> {out}",
        file=sys.stderr,
    )
    write_zone(out, zone, size_mb, args.serial, delegations)
    return 0


if __name__ == "__main__":
    sys.exit(main())
