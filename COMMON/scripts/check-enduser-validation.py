#!/usr/bin/env python3
"""Probe end-user DNSSEC validation failure on a partly signed zone.

Looks up owners near the *end* of the synthetic zone (highest a####### labels)
and checks:

1. Positive answers with missing RRSIGs (validating stub → BOGUS / SERVFAIL).
2. Broken denial-of-existence chains (owner missing from NSEC chain, or NSEC3
   hash absent from the hashed owner set).

Works offline against an AXFR capture (--axfr) and optionally live against an
authority (--host/--port) via dig +dnssec and delv +root=<zone>.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import re
import subprocess
import sys
from collections import defaultdict
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path


def wire_name(name: str) -> bytes:
    name = name.lower().rstrip(".")
    out = bytearray()
    if name:
        for lab in name.split("."):
            b = lab.encode("ascii")
            out.append(len(b))
            out.extend(b)
    out.append(0)
    return bytes(out)


def nsec3_hash(qname: str, iterations: int, salt: bytes, alg: int = 1) -> str:
    if alg != 1:
        raise ValueError(f"unsupported NSEC3 hash algorithm {alg} (want 1=SHA-1)")
    h = wire_name(qname)
    for _ in range(iterations + 1):
        h = hashlib.sha1(h + salt).digest()
    return base64.b32hexencode(h).decode("ascii").rstrip("=").upper()


def fqdn(name: str) -> str:
    name = name.lower().strip()
    if not name.endswith("."):
        name += "."
    return name


def parse_salt(tok: str) -> bytes:
    if tok in ("-", "", "."):
        return b""
    return bytes.fromhex(tok)


@dataclass
class ZoneView:
    apex: str
    rrsets: dict[tuple[str, str], list[str]] = field(default_factory=lambda: defaultdict(list))
    rrsigs: set[tuple[str, str]] = field(default_factory=set)
    nsec_next: dict[str, str] = field(default_factory=dict)  # owner -> next name
    nsec3_owners: set[str] = field(default_factory=set)  # base32hex labels
    nsec3_params: tuple[int, int, int, bytes] | None = None  # alg, flags, iters, salt
    dnskeys: list[str] = field(default_factory=list)
    soa_serial: int | None = None


def parse_axfr(path: Path, apex: str) -> ZoneView:
    apex = fqdn(apex)
    view = ZoneView(apex=apex)
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.strip()
        if not line or line.startswith(";"):
            continue
        parts = line.split()
        if len(parts) < 4:
            continue
        owner = fqdn(parts[0])
        rtype = parts[3].upper()
        if rtype == "SOA" and view.soa_serial is None and len(parts) >= 7:
            try:
                view.soa_serial = int(parts[6])
            except ValueError:
                pass
        if rtype == "DNSKEY":
            view.dnskeys.append(line)
        if rtype == "RRSIG" and len(parts) >= 5:
            view.rrsigs.add((owner, parts[4].upper()))
            continue
        if rtype == "NSEC" and len(parts) >= 5:
            view.nsec_next[owner] = fqdn(parts[4])
        if rtype == "NSEC3PARAM" and len(parts) >= 8:
            try:
                view.nsec3_params = (
                    int(parts[4]),
                    int(parts[5]),
                    int(parts[6]),
                    parse_salt(parts[7]),
                )
            except ValueError:
                pass
        if rtype == "NSEC3" and len(parts) >= 8:
            label = owner[: -len(apex)].rstrip(".").upper()
            if label:
                view.nsec3_owners.add(label)
            if view.nsec3_params is None:
                try:
                    view.nsec3_params = (
                        int(parts[4]),
                        int(parts[5]),
                        int(parts[6]),
                        parse_salt(parts[7]),
                    )
                except ValueError:
                    pass
        view.rrsets[(owner, rtype)].append(line)
    return view


def a_owners(view: ZoneView) -> list[str]:
    """Synthetic generator labels a#######.<apex>, sorted lexicographically."""
    apex = view.apex
    out = []
    for (owner, rtype) in view.rrsets:
        if rtype != "A":
            continue
        if not owner.endswith(apex):
            continue
        local = owner[: -len(apex)].rstrip(".")
        if re.fullmatch(r"a\d{7}", local):
            out.append(owner)
    return sorted(out)


def pick_end_owners(owners: list[str], count: int = 5) -> list[str]:
    if not owners:
        return []
    return owners[-count:]


def run(cmd: list[str], timeout: float = 30.0) -> tuple[int, str, str]:
    try:
        p = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
        return p.returncode, p.stdout, p.stderr
    except FileNotFoundError:
        return 127, "", f"missing command: {cmd[0]}"
    except subprocess.TimeoutExpired:
        return 124, "", "timeout"


def dig_query(host: str, port: int, *args: str) -> tuple[int, str, str]:
    return run(["dig", f"@{host}", "-p", str(port), *args, "+time=5", "+tries=2"])


def write_trust_anchor(path: Path, apex: str, dnskey_lines: list[str]) -> None:
    """Write a delv trust-anchors file for +root=<apex>."""
    apex = fqdn(apex).rstrip(".")
    lines = ['trust-anchors {']
    for raw in dnskey_lines:
        parts = raw.split()
        # name TTL CLASS DNSKEY flags protocol alg key...
        if len(parts) < 7 or parts[3].upper() != "DNSKEY":
            continue
        flags, proto, alg = parts[4], parts[5], parts[6]
        key = " ".join(parts[7:])
        lines.append(f'  {apex}. static-key {flags} {proto} {alg} "{key}";')
    lines.append("};")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


@dataclass
class ProbeResult:
    name: str
    has_a: bool = False
    has_rrsig_a: bool = False
    has_nsec: bool = False
    nsec3_hash: str | None = None
    has_nsec3: bool = False
    dig_a_out: str = ""
    dig_doe_out: str = ""
    delv_rc: int | None = None
    delv_out: str = ""
    missing_rrsig: bool = False
    chain_broken: bool = False


def analyze_owner(view: ZoneView, name: str) -> ProbeResult:
    name = fqdn(name)
    pr = ProbeResult(name=name)
    pr.has_a = (name, "A") in view.rrsets
    pr.has_rrsig_a = (name, "A") in view.rrsigs
    pr.missing_rrsig = pr.has_a and not pr.has_rrsig_a

    if view.nsec_next:
        pr.has_nsec = name in view.nsec_next
        nsec_signed = (name, "NSEC") in view.rrsigs
        # Broken for validators: owner absent from chain, or NSEC present but unsigned.
        pr.chain_broken = pr.has_a and (not pr.has_nsec or not nsec_signed)
    elif view.nsec3_params is not None:
        alg, _flags, iters, salt = view.nsec3_params
        pr.nsec3_hash = nsec3_hash(name, iters, salt, alg)
        pr.has_nsec3 = pr.nsec3_hash in view.nsec3_owners
        nsec3_owner = f"{pr.nsec3_hash.lower()}.{view.apex}"
        nsec3_signed = (nsec3_owner, "NSEC3") in view.rrsigs
        # Absent hash or unsigned NSEC3 RR → denial proof fails validation.
        pr.chain_broken = pr.has_a and (not pr.has_nsec3 or not nsec3_signed)
    return pr

def find_nsec_span_skip(view: ZoneView, owners: list[str], limit: int = 20) -> list[str]:
    """Return existing a# owners that have no NSEC RR (incomplete chain).

    Full next-pointer span walking is O(n²) on large zones; absence from the
    NSEC owner set is the same end-user-visible chain gap and is O(n).
    """
    if not view.nsec_next or not owners:
        return []
    skipped = [o for o in owners if o not in view.nsec_next]
    if len(skipped) <= limit:
        return skipped
    # Prefer the end of the zone (what validating clients hit for late labels).
    return skipped[-limit:]


def live_probe(
    host: str,
    port: int,
    apex: str,
    name: str,
    trust_path: Path | None,
    mode: str,
    nsec3_label: str | None,
) -> ProbeResult:
    """Supplement offline analysis with dig/delv against the authority."""
    pr = ProbeResult(name=fqdn(name))
    rc, out, err = dig_query(host, port, name, "A", "+dnssec", "+norecurse", "+noall", "+answer", "+authority")
    pr.dig_a_out = out + (("\n" + err) if err else "")
    ans_lines = [ln for ln in out.splitlines() if ln and not ln.startswith(";")]
    pr.has_a = any(re.search(r"\sA\s", ln) and not re.search(r"\sRRSIG\s", ln) for ln in ans_lines) or any(
        re.search(r"\sA\s", ln) for ln in ans_lines
    )
    # More precise: separate A vs RRSIG A
    has_a = False
    has_rrsig_a = False
    for ln in ans_lines:
        parts = ln.split()
        if len(parts) < 4:
            continue
        rt = parts[3].upper()
        if rt == "A":
            has_a = True
        if rt == "RRSIG" and len(parts) >= 5 and parts[4].upper() == "A":
            has_rrsig_a = True
    pr.has_a = has_a
    pr.has_rrsig_a = has_rrsig_a
    pr.missing_rrsig = has_a and not has_rrsig_a

    if mode == "nsec":
        rc2, out2, err2 = dig_query(
            host, port, name, "NSEC", "+dnssec", "+norecurse", "+noall", "+answer"
        )
        pr.dig_doe_out = out2 + (("\n" + err2) if err2 else "")
        pr.has_nsec = any(
            (parts := ln.split()) and len(parts) >= 4 and parts[3].upper() == "NSEC"
            for ln in out2.splitlines()
        )
        pr.chain_broken = pr.has_a and not pr.has_nsec
    elif mode == "nsec3" and nsec3_label:
        q = f"{nsec3_label}.{apex}"
        pr.nsec3_hash = nsec3_label
        rc2, out2, err2 = dig_query(
            host, port, q, "NSEC3", "+dnssec", "+norecurse", "+noall", "+answer"
        )
        pr.dig_doe_out = out2 + (("\n" + err2) if err2 else "")
        pr.has_nsec3 = any(
            (parts := ln.split()) and len(parts) >= 4 and parts[3].upper() == "NSEC3"
            for ln in out2.splitlines()
        )
        pr.chain_broken = pr.has_a and not pr.has_nsec3

    if trust_path is not None and trust_path.is_file():
        # delv does not accept dig's +norecurse; +root=<apex> with -a trust file.
        rc3, out3, err3 = run(
            [
                "delv",
                f"@{host}",
                "-p",
                str(port),
                "-a",
                str(trust_path),
                f"+root={apex.rstrip('.')}",
                "+vtrace",
                name,
                "A",
            ],
            timeout=20.0,
        )
        pr.delv_rc = rc3
        pr.delv_out = (out3 + "\n" + err3).strip()
    return pr


def discover_end_owners_live(host: str, port: int, apex: str, lo: int = 1, hi: int = 300000) -> list[str]:
    """Binary-search the highest existing a####### label via A queries."""
    apex = fqdn(apex)

    def exists(n: int) -> bool:
        name = f"a{n:07d}.{apex}"
        _rc, out, _err = dig_query(host, port, name, "A", "+norecurse", "+short")
        return bool(out.strip())

    if not exists(lo):
        return []
    # Expand hi until miss
    while exists(hi):
        hi *= 2
        if hi > 5_000_000:
            break
    left, right = lo, hi
    best = lo
    while left <= right:
        mid = (left + right) // 2
        if exists(mid):
            best = mid
            left = mid + 1
        else:
            right = mid - 1
    return [fqdn(f"a{n:07d}.{apex}") for n in range(max(lo, best - 4), best + 1)]


def render_report(
    *,
    apex: str,
    host: str | None,
    port: int | None,
    mode: str,
    soa_serial: int | None,
    probes: list[ProbeResult],
    span_skips: list[str],
    nsec3_params: tuple | None,
    expect_fail: bool,
) -> tuple[str, str, int]:
    """Return (markdown, status, exit_code)."""
    missing = [p for p in probes if p.missing_rrsig]
    broken = [p for p in probes if p.chain_broken]
    delv_fail = [p for p in probes if p.delv_rc not in (None, 0) and p.missing_rrsig]

    demonstrated = bool(missing) and (bool(broken) or bool(span_skips) or mode == "nsec" and bool(missing))
    # Prefer requiring both classes when chain info exists; missing RRSIG alone is enough
    # for end-user BOGUS, chain evidence strengthens.
    if missing and (broken or span_skips):
        status = "ENDUSER_VALIDATION_FAILS"
        demonstrated = True
    elif missing:
        status = "ENDUSER_MISSING_RRSIG"
        demonstrated = True
    elif broken or span_skips:
        status = "ENDUSER_BROKEN_CHAIN"
        demonstrated = True
    else:
        status = "ENDUSER_LOOKS_VALID"
        demonstrated = False

    if expect_fail:
        # Called from PARTLY_SIGNED path: demonstrating failure is the desired outcome.
        verdict = "PASS" if demonstrated else "INCONCLUSIVE"
        exit_code = 0 if demonstrated else 1
    else:
        verdict = "FAIL" if demonstrated else "PASS"
        exit_code = 1 if demonstrated else 0

    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    lines = [
        "# End-user DNSSEC validation probe",
        "",
        f"**Verdict:** {verdict}",
        f"**Status:** {status}",
        "",
        "| Field | Value |",
        "|-------|-------|",
        f"| Zone | `{apex}` |",
        f"| Denial mode | {mode} |",
        f"| Captured (UTC) | {now} |",
        f"| SOA serial | `{soa_serial}` |",
        f"| Server | `{host}:{port}` |" if host else "| Server | *(AXFR-only)* |",
        f"| End owners probed | {len(probes)} |",
        f"| Missing RRSIG (A) | {len(missing)} |",
        f"| Broken chain (owner∉NSEC/NSEC3) | {len(broken)} |",
        f"| NSEC span skips (sample) | {len(span_skips)} |",
        "",
        "## Meaning",
        "",
        "| Status | Meaning |",
        "|--------|---------|",
        "| `ENDUSER_VALIDATION_FAILS` | End-of-zone names lack RRSIGs **and** DOE chain is incomplete. |",
        "| `ENDUSER_MISSING_RRSIG` | End-of-zone positive answers have no covering RRSIG (validating stub → BOGUS). |",
        "| `ENDUSER_BROKEN_CHAIN` | End-of-zone owners missing from NSEC / NSEC3 chain. |",
        "| `ENDUSER_LOOKS_VALID` | End-of-zone probes have RRSIGs and chain entries. |",
        "",
        "## 1. Records with missing RRSIGs (end of zone)",
        "",
    ]
    if not missing:
        lines.append("No missing-RRSIG end-of-zone A owners among probes.")
    else:
        lines.append("| Owner | Has A | Has RRSIG(A) | delv rc |")
        lines.append("|-------|:-----:|:------------:|--------:|")
        for p in missing:
            lines.append(
                f"| `{p.name}` | {int(p.has_a)} | {int(p.has_rrsig_a)} | "
                f"{'' if p.delv_rc is None else p.delv_rc} |"
            )
    lines += ["", "## 2. Broken NSEC / NSEC3 chain (end of zone)", ""]
    if nsec3_params is not None:
        alg, flags, iters, salt = nsec3_params
        salt_s = salt.hex() if salt else "-"
        lines.append(
            f"NSEC3 params: algorithm={alg} flags={flags} iterations={iters} salt=`{salt_s}`"
        )
        lines.append("")
    if not broken and not span_skips:
        lines.append("No chain gaps detected among end-of-zone probes.")
    else:
        if broken:
            lines.append("| Owner | NSEC | NSEC3 hash | In NSEC3 chain |")
            lines.append("|-------|:----:|------------|:--------------:|")
            for p in broken:
                lines.append(
                    f"| `{p.name}` | {int(p.has_nsec)} | `{p.nsec3_hash or ''}` | "
                    f"{int(p.has_nsec3)} |"
                )
        if span_skips:
            lines.append("")
            lines.append(
                f"NSEC next-pointer spans skip {len(span_skips)} existing `a#` owners "
                f"(showing last 10):"
            )
            for n in span_skips[-10:]:
                lines.append(f"- `{n}`")

    lines += ["", "## 3. Live dig / delv evidence", ""]
    any_live = False
    for p in probes:
        if p.dig_a_out or p.delv_out:
            any_live = True
            lines.append(f"### `{p.name}`")
            lines.append("")
            if p.dig_a_out:
                lines.append("```")
                lines.append(p.dig_a_out.rstrip()[:4000])
                lines.append("```")
                lines.append("")
            if p.dig_doe_out:
                lines.append("DOE query:")
                lines.append("```")
                lines.append(p.dig_doe_out.rstrip()[:2000])
                lines.append("```")
                lines.append("")
            if p.delv_out:
                lines.append(f"delv exit={p.delv_rc}:")
                lines.append("```")
                lines.append(p.delv_out.rstrip()[:4000])
                lines.append("```")
                lines.append("")
    if not any_live:
        lines.append("*(No live dig/delv — AXFR-only analysis.)*")
    if delv_fail:
        lines += [
            "",
            f"delv failed for {len(delv_fail)} unsigned end-of-zone name(s), matching "
            "validating-resolver SERVFAIL behaviour.",
        ]

    return "\n".join(lines) + "\n", status, exit_code


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--zone", required=True, help="Zone apex")
    ap.add_argument("--axfr", type=Path, help="AXFR text capture to analyse")
    ap.add_argument("--host", help="Authority IP for live dig/delv")
    ap.add_argument("--port", type=int, default=53)
    ap.add_argument("--out", type=Path, help="Write ENDUSER_VALIDATION.md here")
    ap.add_argument(
        "--expect-fail",
        action="store_true",
        help="Treat demonstrated end-user validation failure as PASS (PARTLY_SIGNED path)",
    )
    ap.add_argument("--probe-count", type=int, default=5, help="How many end owners to probe")
    args = ap.parse_args()

    apex = fqdn(args.zone)
    if not args.axfr and not args.host:
        print("need --axfr and/or --host", file=sys.stderr)
        return 2

    view: ZoneView | None = None
    if args.axfr:
        if not args.axfr.is_file():
            print(f"AXFR not found: {args.axfr}", file=sys.stderr)
            return 2
        view = parse_axfr(args.axfr, apex)

    owners: list[str] = []
    if view is not None:
        owners = a_owners(view)
    if not owners and args.host:
        owners = discover_end_owners_live(args.host, args.port, apex)

    end = pick_end_owners(owners, args.probe_count)
    if not end:
        print("could not find synthetic a####### end-of-zone owners", file=sys.stderr)
        return 2

    if view is None:
        # Minimal view for live-only mode
        view = ZoneView(apex=apex)

    # Detect mode
    if view.nsec3_params is not None or view.nsec3_owners:
        mode = "nsec3"
    elif view.nsec_next:
        mode = "nsec"
    elif "nsec3" in apex:
        mode = "nsec3"
    else:
        mode = "nsec"

    probes = [analyze_owner(view, n) for n in end]
    span_skips = find_nsec_span_skip(view, owners) if view.nsec_next else []

    trust_path = None
    out_dir = args.out.parent if args.out else Path(".")
    if args.host:
        # Prefer DNSKEYs from AXFR; else dig them live.
        dnskeys = list(view.dnskeys)
        if not dnskeys:
            _rc, out, _err = dig_query(
                args.host, args.port, apex, "DNSKEY", "+norecurse", "+noall", "+answer"
            )
            dnskeys = [ln for ln in out.splitlines() if "DNSKEY" in ln]
            for ln in dnskeys:
                view.dnskeys.append(ln)
        if dnskeys:
            trust_path = out_dir / "enduser-trust-anchors.conf"
            write_trust_anchor(trust_path, apex, dnskeys)

        # If we lack NSEC3 params offline, try dig NSEC3PARAM
        if mode == "nsec3" and view.nsec3_params is None:
            _rc, out, _err = dig_query(
                args.host, args.port, apex, "NSEC3PARAM", "+norecurse", "+short"
            )
            # short: "1 0 0 -"
            toks = out.split()
            if len(toks) >= 4:
                try:
                    view.nsec3_params = (
                        int(toks[0]),
                        int(toks[1]),
                        int(toks[2]),
                        parse_salt(toks[3]),
                    )
                except ValueError:
                    pass

        live_probes: list[ProbeResult] = []
        for offline in probes:
            nsec3_label = None
            if mode == "nsec3" and view.nsec3_params is not None:
                alg, _f, iters, salt = view.nsec3_params
                nsec3_label = nsec3_hash(offline.name, iters, salt, alg)
                offline.nsec3_hash = nsec3_label
            live = live_probe(
                args.host,
                args.port,
                apex,
                offline.name,
                trust_path,
                mode,
                nsec3_label,
            )
            # AXFR (when present) is the authoritative mid-sign snapshot. Live
            # dig/delv is supplementary evidence only — a later fully-signed
            # stack must not overwrite PARTLY_SIGNED AXFR facts.
            if args.axfr is None:
                if live.has_a:
                    offline.has_a = True
                    offline.has_rrsig_a = live.has_rrsig_a
                    offline.missing_rrsig = offline.has_a and not offline.has_rrsig_a
                if mode == "nsec":
                    offline.has_nsec = live.has_nsec
                    offline.chain_broken = offline.has_a and not offline.has_nsec
                elif mode == "nsec3":
                    offline.nsec3_hash = live.nsec3_hash or offline.nsec3_hash
                    offline.has_nsec3 = live.has_nsec3
                    offline.chain_broken = offline.has_a and not offline.has_nsec3
            elif live.nsec3_hash and not offline.nsec3_hash:
                offline.nsec3_hash = live.nsec3_hash
            offline.dig_a_out = live.dig_a_out
            offline.dig_doe_out = live.dig_doe_out
            offline.delv_rc = live.delv_rc
            offline.delv_out = live.delv_out
            live_probes.append(offline)
        probes = live_probes

    md, status, code = render_report(
        apex=apex,
        host=args.host,
        port=args.port if args.host else None,
        mode=mode,
        soa_serial=view.soa_serial,
        probes=probes,
        span_skips=span_skips,
        nsec3_params=view.nsec3_params,
        expect_fail=args.expect_fail,
    )
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(md, encoding="utf-8")
        print(f"wrote {args.out} status={status}")
    else:
        sys.stdout.write(md)
    print(
        f"enduser: {'PASS' if code == 0 else 'FAIL'} {status} "
        f"missing_rrsig={sum(1 for p in probes if p.missing_rrsig)} "
        f"broken_chain={sum(1 for p in probes if p.chain_broken)}",
        file=sys.stderr,
    )
    return code


if __name__ == "__main__":
    raise SystemExit(main())
