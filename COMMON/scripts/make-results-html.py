#!/usr/bin/env python3
"""Scan stack artifacts and write a RESULTS.html summary at the repo root."""
from __future__ import annotations

import argparse
import html
import re
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

STACKS = (
    "BIND-BIND-BIND",
    "BIND-BIND-KNOT",
    "BIND-KNOT-BIND",
    "KNOT-KNOT-KNOT",
)

TS_RE = re.compile(r"^(\d{8}T\d{6}Z)-(.+)$")
FIELD_RE = re.compile(r"^\|\s*([^|]+?)\s*\|\s*(.*?)\s*\|\s*$")
MD_BOLD_RE = re.compile(r"^\*\*([^*]+):\*\*\s*(.*)$")


@dataclass
class ScenarioResult:
    stack: str
    dirname: str
    timestamp: str
    slug: str
    verdict: str  # PASS | FAIL | RUNNING | UNKNOWN
    status: str = ""
    zone: str = ""
    serial: str = ""
    signed: str = ""
    signable: str = ""
    missing: str = ""
    doe: str = ""
    captured: str = ""
    path: str = ""
    summary_rc: str = ""


@dataclass
class StackBattery:
    stack: str
    run_all_dir: str = ""
    run_all_ts: str = ""
    run_all_result: str = ""  # PASS | FAIL | RUNNING | ""
    zonesize: str = ""
    summary_lines: list[tuple[str, str]] = field(default_factory=list)
    scenarios: list[ScenarioResult] = field(default_factory=list)


def parse_dirname(name: str) -> tuple[str, str, str] | None:
    """Return (timestamp, base_slug, verdict_suffix) or None."""
    m = TS_RE.match(name)
    if not m:
        return None
    ts, rest = m.group(1), m.group(2)
    if rest.endswith("-PASS"):
        return ts, rest[: -len("-PASS")], "PASS"
    if rest.endswith("-FAIL"):
        return ts, rest[: -len("-FAIL")], "FAIL"
    return ts, rest, "RUNNING"


def is_run_all(slug: str) -> bool:
    return slug.startswith("run-all-")


def parse_results_md(path: Path) -> dict[str, str]:
    out: dict[str, str] = {}
    if not path.is_file():
        return out
    text = path.read_text(encoding="utf-8", errors="replace")
    in_table = False
    for line in text.splitlines():
        mb = MD_BOLD_RE.match(line.strip())
        if mb:
            key = mb.group(1).strip().lower()
            out[key] = mb.group(2).strip()
            continue
        if line.startswith("| Field"):
            in_table = True
            continue
        if in_table:
            if not line.startswith("|"):
                in_table = False
                continue
            fm = FIELD_RE.match(line)
            if not fm:
                continue
            key = fm.group(1).strip().lower()
            val = fm.group(2).strip().strip("`")
            if key == "field":
                continue
            out[key] = val
    return out


def coverage_bits(fields: dict[str, str]) -> tuple[str, str, str]:
    signed = fields.get("signed rrsets", "")
    signable = fields.get("signable rrsets", "")
    missing = fields.get("missing rrsigs", "")
    return signed, signable, missing


def load_summary(path: Path) -> list[tuple[str, str]]:
    lines: list[tuple[str, str]] = []
    if not path.is_file():
        return lines
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        raw = raw.strip()
        if not raw:
            continue
        m = re.match(r"^(.+?)\s+rc=(\d+)\s*$", raw)
        if m:
            lines.append((m.group(1), m.group(2)))
        else:
            lines.append((raw, ""))
    return lines


def zonesize_from_slug(slug: str) -> str:
    m = re.search(r"run-all-(\d+m)", slug)
    return m.group(1) if m else ""


def collect_stack(root: Path, stack: str) -> StackBattery:
    battery = StackBattery(stack=stack)
    art = root / stack / "artifacts"
    if not art.is_dir():
        return battery

    run_alls: list[tuple[str, str, str, Path]] = []
    scenarios: list[tuple[str, str, str, Path]] = []

    for child in art.iterdir():
        if not child.is_dir():
            continue
        parsed = parse_dirname(child.name)
        if not parsed:
            continue
        ts, slug, verdict = parsed
        if is_run_all(slug):
            run_alls.append((ts, slug, verdict, child))
        else:
            scenarios.append((ts, slug, verdict, child))

    run_alls.sort(key=lambda x: x[0])
    scenarios.sort(key=lambda x: x[0])

    window_ts = ""
    if run_alls:
        ts, slug, verdict, path = run_alls[-1]
        battery.run_all_dir = f"{stack}/artifacts/{path.name}"
        battery.run_all_ts = ts
        battery.run_all_result = verdict
        battery.zonesize = zonesize_from_slug(slug)
        battery.summary_lines = load_summary(path / "summary.txt")
        window_ts = ts

    summary_by_slug = {
        name.replace("/", "-"): rc for name, rc in battery.summary_lines
    }

    for ts, slug, verdict, path in scenarios:
        if window_ts and ts < window_ts:
            continue
        fields = parse_results_md(path / "RESULTS.md")
        if not fields:
            # Prefer top-level RESULTS.md; fall back to first iter-*/RESULTS.md
            for iter_dir in sorted(path.glob("iter-*/RESULTS.md")):
                fields = parse_results_md(iter_dir)
                if fields:
                    break
        signed, signable, missing = coverage_bits(fields)
        md_verdict = fields.get("verdict", "").upper()
        if verdict == "RUNNING" and md_verdict in {"PASS", "FAIL"}:
            verdict = md_verdict
        elif verdict == "RUNNING" and not fields:
            verdict = "RUNNING"
        status = fields.get("status", "")
        battery.scenarios.append(
            ScenarioResult(
                stack=stack,
                dirname=path.name,
                timestamp=ts,
                slug=slug,
                verdict=verdict,
                status=status,
                zone=fields.get("zone", ""),
                serial=fields.get("soa serial", ""),
                signed=signed,
                signable=signable,
                missing=missing,
                doe=fields.get("denial of existence", ""),
                captured=fields.get("captured (utc)", ""),
                path=f"{stack}/artifacts/{path.name}",
                summary_rc=summary_by_slug.get(slug, ""),
            )
        )
    return battery


def esc(s: str) -> str:
    return html.escape(s, quote=True)


def badge(verdict: str) -> str:
    cls = {
        "PASS": "ok",
        "FAIL": "bad",
        "RUNNING": "run",
        "UNKNOWN": "muted",
    }.get(verdict, "muted")
    return f'<span class="badge {cls}">{esc(verdict)}</span>'


def coverage_cell(s: ScenarioResult) -> str:
    if s.signed and s.signable:
        return f"{esc(s.signed)}/{esc(s.signable)}"
    return "—"


def render(batteries: list[StackBattery], out_path: Path) -> None:
    generated = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%SZ")
    total_pass = total_fail = total_run = total = 0
    for b in batteries:
        for s in b.scenarios:
            total += 1
            if s.verdict == "PASS":
                total_pass += 1
            elif s.verdict == "FAIL":
                total_fail += 1
            elif s.verdict == "RUNNING":
                total_run += 1

    sections: list[str] = []
    toc_items: list[str] = []
    for b in batteries:
        anchor = b.stack
        n_pass = sum(1 for s in b.scenarios if s.verdict == "PASS")
        n_fail = sum(1 for s in b.scenarios if s.verdict == "FAIL")
        n_run = sum(1 for s in b.scenarios if s.verdict == "RUNNING")
        n = len(b.scenarios)
        toc_items.append(
            f'<li><a href="#{esc(anchor)}">{esc(b.stack)}</a>'
            f" — {n} tests"
            f" ({n_pass} pass / {n_fail} fail"
            + (f" / {n_run} running" if n_run else "")
            + ")</li>"
        )

        meta_bits = []
        if b.run_all_dir:
            meta_bits.append(
                f"Battery: <code>{esc(b.run_all_dir)}</code> {badge(b.run_all_result or 'RUNNING')}"
            )
        if b.zonesize:
            meta_bits.append(f"ZONESIZE hint: <code>{esc(b.zonesize)}</code>")
        if b.run_all_ts:
            meta_bits.append(f"Started: <code>{esc(b.run_all_ts)}</code>")
        meta_html = (
            f'<p class="stack-meta">{" · ".join(meta_bits)}</p>' if meta_bits else ""
        )

        if b.summary_lines:
            sum_rows = []
            for name, rc in b.summary_lines:
                if rc == "0":
                    v = badge("PASS")
                elif rc == "1":
                    v = badge("FAIL")
                elif rc:
                    v = f'<span class="badge muted">rc={esc(rc)}</span>'
                else:
                    v = badge("UNKNOWN")
                sum_rows.append(f"<tr><td><code>{esc(name)}</code></td><td>{v}</td></tr>")
            summary_table = (
                "<h3>run-all summary</h3>\n"
                "<table><thead><tr><th>Test</th><th>Result</th></tr></thead>\n"
                "<tbody>\n"
                + "\n".join(sum_rows)
                + "\n</tbody></table>"
            )
        else:
            summary_table = "<p class=\"muted\">No <code>summary.txt</code> for this stack yet.</p>"

        if b.scenarios:
            rows = []
            for s in b.scenarios:
                cov = coverage_cell(s)
                miss = esc(s.missing) if s.missing else "—"
                rows.append(
                    "<tr>"
                    f"<td><code>{esc(s.slug)}</code></td>"
                    f"<td>{badge(s.verdict)}</td>"
                    f"<td>{esc(s.status) if s.status else '—'}</td>"
                    f"<td>{esc(s.zone) if s.zone else '—'}</td>"
                    f"<td>{esc(s.serial) if s.serial else '—'}</td>"
                    f"<td>{cov}</td>"
                    f"<td>{miss}</td>"
                    f"<td><code>{esc(s.path)}</code></td>"
                    "</tr>"
                )
            detail_table = (
                "<h3>Scenario artifacts</h3>\n"
                "<table>\n"
                "<thead><tr>"
                "<th>Scenario</th><th>Verdict</th><th>Status</th><th>Zone</th>"
                "<th>SOA</th><th>Signed/Signable</th><th>Missing</th><th>Artifact</th>"
                "</tr></thead>\n<tbody>\n"
                + "\n".join(rows)
                + "\n</tbody></table>"
            )
        else:
            detail_table = "<p class=\"muted\">No scenario artifacts in the latest battery window.</p>"

        sections.append(
            f'<section id="{esc(anchor)}">\n'
            f"<h2>{esc(b.stack)}</h2>\n"
            f"{meta_html}\n"
            f'<p class="counts">{n_pass} pass · {n_fail} fail'
            + (f" · {n_run} running" if n_run else "")
            + f" · {n} total</p>\n"
            f"{summary_table}\n"
            f"{detail_table}\n"
            "</section>"
        )

    overall_cls = "bad" if total_fail else ("run" if total_run else "ok")
    doc = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>DNSSEC BITW lab — RESULTS</title>
<style>
  :root {{
    color-scheme: dark;
    --bg: #0d1117;
    --ink: #e6edf3;
    --muted: #9aa7b5;
    --card: #161b22;
    --line: #30363d;
    --accent: #58a6ff;
    --ok: #3fb950;
    --bad: #f85149;
    --run: #d29922;
    --th: #21262d;
    --ok-bg: #0d2818;
    --bad-bg: #2d1214;
    --run-bg: #2a1f0a;
  }}
  * {{ box-sizing: border-box; }}
  body {{
    margin: 0;
    font: 16px/1.5 "Iowan Old Style", "Palatino Linotype", Palatino, Georgia, serif;
    color: var(--ink);
    background:
      radial-gradient(ellipse 80% 50% at 10% 0%, #12203a 0%, transparent 55%),
      radial-gradient(ellipse 60% 40% at 90% 10%, #0f2a24 0%, transparent 50%),
      var(--bg);
  }}
  .wrap {{ max-width: 72rem; margin: 0 auto; padding: 2.2rem 1.25rem 4rem; }}
  header.hero {{
    border-bottom: 1px solid var(--line);
    padding-bottom: 1.25rem;
    margin-bottom: 1.5rem;
  }}
  h1 {{
    margin: 0 0 0.6rem;
    font-size: clamp(1.5rem, 3vw, 2rem);
    letter-spacing: -0.02em;
    color: #f0f6fc;
  }}
  h2 {{
    font-size: 1.3rem;
    margin: 2.2rem 0 0.6rem;
    padding-top: 0.35rem;
    border-top: 1px solid var(--line);
    color: #f0f6fc;
  }}
  h3 {{ font-size: 1.05rem; margin: 1.2rem 0 0.5rem; color: #e6edf3; }}
  .meta, .muted, .stack-meta, .counts {{ color: var(--muted); }}
  .stack-meta code, td code {{ font-size: 0.84em; }}
  a {{ color: var(--accent); }}
  code {{
    font-family: "JetBrains Mono", "SF Mono", Menlo, Consolas, monospace;
    background: #21262d;
    color: #ffa657;
    padding: 0.08em 0.3em;
    border-radius: 3px;
  }}
  .summary-cards {{
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(8.5rem, 1fr));
    gap: 0.75rem;
    margin: 1.2rem 0 1.5rem;
  }}
  .card {{
    background: var(--card);
    border: 1px solid var(--line);
    border-radius: 8px;
    padding: 0.85rem 1rem;
  }}
  .card.ok {{ border-color: #238636; background: var(--ok-bg); }}
  .card.bad {{ border-color: #da3633; background: var(--bad-bg); }}
  .card.run {{ border-color: #9e6a03; background: var(--run-bg); }}
  .card .n {{
    display: block;
    font-size: 1.8rem;
    font-weight: 700;
    line-height: 1.1;
    color: #f0f6fc;
  }}
  .card.ok .n {{ color: var(--ok); }}
  .card.bad .n {{ color: var(--bad); }}
  .card.run .n {{ color: var(--run); }}
  .badge {{
    display: inline-block;
    font-family: "JetBrains Mono", "SF Mono", Menlo, Consolas, monospace;
    font-size: 0.78rem;
    font-weight: 700;
    letter-spacing: 0.03em;
    padding: 0.15em 0.45em;
    border-radius: 4px;
    border: 1px solid var(--line);
  }}
  .badge.ok {{ color: var(--ok); background: var(--ok-bg); border-color: #238636; }}
  .badge.bad {{ color: var(--bad); background: var(--bad-bg); border-color: #da3633; }}
  .badge.run {{ color: var(--run); background: var(--run-bg); border-color: #9e6a03; }}
  .badge.muted {{ color: var(--muted); }}
  .toc {{
    background: var(--card);
    border: 1px solid var(--line);
    border-radius: 8px;
    padding: 1rem 1.2rem;
    margin: 1rem 0 1.5rem;
  }}
  .toc strong {{ display: block; margin-bottom: 0.4rem; color: #f0f6fc; }}
  .toc ol {{ margin: 0; padding-left: 1.3rem; }}
  table {{
    width: 100%;
    border-collapse: collapse;
    font-size: 0.88rem;
    margin: 0.6rem 0 1.2rem;
    background: var(--card);
  }}
  th, td {{
    border: 1px solid var(--line);
    padding: 0.45rem 0.55rem;
    text-align: left;
    vertical-align: top;
  }}
  th {{ background: var(--th); color: #f0f6fc; }}
  tr:has(.badge.bad) td {{ background: rgba(248, 81, 73, 0.06); }}
  tr:has(.badge.ok) td {{ background: rgba(63, 185, 80, 0.04); }}
  footer {{
    margin-top: 2.5rem;
    padding-top: 1rem;
    border-top: 1px solid var(--line);
    color: var(--muted);
    font-size: 0.9rem;
  }}
  @media print {{
    :root {{ color-scheme: light; --bg: #fff; --ink: #111; --muted: #444; --card: #fff; --line: #ccc; --th: #f0f0f0; }}
    body {{ background: #fff; }}
  }}
</style>
</head>
<body>
<div class="wrap">
<header class="hero">
  <h1>DNSSEC BITW lab — test results</h1>
  <p class="meta">Generated {esc(generated)} · source: latest <code>*-run-all-*</code> battery per stack (and its scenario artifacts)</p>
</header>

<div class="summary-cards">
  <div class="card {overall_cls}"><span class="n">{total}</span>scenarios</div>
  <div class="card ok"><span class="n">{total_pass}</span>pass</div>
  <div class="card bad"><span class="n">{total_fail}</span>fail</div>
  <div class="card run"><span class="n">{total_run}</span>running</div>
</div>

<nav class="toc">
  <strong>Stacks</strong>
  <ol>
    {"".join(toc_items)}
  </ol>
</nav>

{"".join(sections)}

<footer>
  Regenerate with <code>./make-results-html.sh</code> (also run at the end of <code>./run-all.sh</code>).
  Narrative analysis: <a href="REPORT.html">REPORT.html</a>.
</footer>
</div>
</body>
</html>
"""
    out_path.write_text(doc, encoding="utf-8")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "-o",
        "--output",
        type=Path,
        default=None,
        help="Output HTML path (default: <repo>/RESULTS.html)",
    )
    ap.add_argument(
        "--root",
        type=Path,
        default=None,
        help="Repository root (default: parent of COMMON/)",
    )
    args = ap.parse_args()
    script = Path(__file__).resolve()
    root = args.root.resolve() if args.root else script.parents[2]
    out = args.output.resolve() if args.output else root / "RESULTS.html"

    batteries = [collect_stack(root, s) for s in STACKS]
    render(batteries, out)
    n_fail = sum(1 for b in batteries for s in b.scenarios if s.verdict == "FAIL")
    n_pass = sum(1 for b in batteries for s in b.scenarios if s.verdict == "PASS")
    n_run = sum(1 for b in batteries for s in b.scenarios if s.verdict == "RUNNING")
    print(f"Wrote {out} ({n_pass} pass / {n_fail} fail / {n_run} running)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
