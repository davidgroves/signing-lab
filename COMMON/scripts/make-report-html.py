#!/usr/bin/env python3
"""Convert REPORT.md into styled REPORT.html with embedded SVG figures."""
from __future__ import annotations

import argparse
import html
import re
from pathlib import Path

CSS = """
  :root {
    color-scheme: dark;
    --bg: #0d1117;
    --ink: #e6edf3;
    --muted: #9aa7b5;
    --card: #161b22;
    --line: #30363d;
    --accent: #58a6ff;
    --warn: #d29922;
    --bad: #f85149;
    --ok: #3fb950;
    --code-bg: #010409;
    --code-ink: #e6edf3;
    --code-inline: #21262d;
    --th: #21262d;
    --quote-bg: #2a1f0a;
    --quote-ink: #e3b341;
    --ok-bg: #0d2818;
    --ok-border: #238636;
    --bad-bg: #2d1214;
    --bad-border: #da3633;
  }
  * { box-sizing: border-box; }
  html { scroll-behavior: smooth; }
  body {
    margin: 0;
    font: 17px/1.55 "Iowan Old Style", "Palatino Linotype", Palatino, "Book Antiqua", Georgia, serif;
    color: var(--ink);
    background:
      radial-gradient(ellipse 80% 50% at 10% 0%, #12203a 0%, transparent 55%),
      radial-gradient(ellipse 60% 40% at 90% 10%, #0f2a24 0%, transparent 50%),
      var(--bg);
  }
  .wrap { max-width: 54rem; margin: 0 auto; padding: 2.5rem 1.25rem 4rem; }
  header.hero {
    border-bottom: 1px solid var(--line);
    padding-bottom: 1.5rem;
    margin-bottom: 2rem;
  }
  h1 {
    font-size: clamp(1.6rem, 3.5vw, 2.15rem);
    line-height: 1.2;
    margin: 0 0 1rem;
    letter-spacing: -0.02em;
    color: #f0f6fc;
  }
  .meta { display: grid; gap: 0.35rem; color: var(--muted); font-size: 0.95rem; }
  .meta a { color: var(--accent); }
  h2 {
    font-size: 1.35rem;
    margin: 2.4rem 0 0.85rem;
    padding-top: 0.4rem;
    border-top: 1px solid var(--line);
    color: #f0f6fc;
  }
  h3 { font-size: 1.1rem; margin: 1.5rem 0 0.6rem; color: #e6edf3; }
  h4 { font-size: 1rem; margin: 1.2rem 0 0.5rem; color: #e6edf3; }
  p, li { max-width: 70ch; }
  blockquote {
    margin: 1rem 0;
    padding: 0.85rem 1.1rem;
    border-left: 4px solid var(--warn);
    background: var(--quote-bg);
    color: var(--quote-ink);
  }
  blockquote p { margin: 0; }
  a { color: var(--accent); }
  code, pre {
    font-family: "JetBrains Mono", "SF Mono", Menlo, Consolas, monospace;
    font-size: 0.86em;
  }
  code {
    background: var(--code-inline);
    color: #ffa657;
    padding: 0.1em 0.35em;
    border-radius: 3px;
  }
  pre {
    background: var(--code-bg);
    color: var(--code-ink);
    padding: 1rem 1.1rem;
    overflow-x: auto;
    border-radius: 6px;
    border: 1px solid var(--line);
    line-height: 1.45;
  }
  pre code { background: none; padding: 0; color: inherit; }
  table {
    width: 100%;
    border-collapse: collapse;
    font-size: 0.88rem;
    margin: 1rem 0 1.4rem;
    background: var(--card);
  }
  th, td {
    border: 1px solid var(--line);
    padding: 0.45rem 0.55rem;
    text-align: left;
    vertical-align: top;
  }
  th { background: var(--th); color: #f0f6fc; }
  td strong { color: var(--bad); }
  .fig {
    margin: 1.4rem 0 1.8rem;
    padding: 1rem;
    background: var(--card);
    border: 1px solid var(--line);
    border-radius: 8px;
  }
  .fig svg { display: block; width: 100%; height: auto; max-width: 100%; }
  .fig figcaption {
    margin-top: 0.75rem;
    font-size: 0.88rem;
    color: var(--muted);
    max-width: none;
  }
  .callout {
    margin: 1rem 0;
    padding: 0.9rem 1.1rem;
    border: 1px solid var(--line);
    border-radius: 6px;
    background: var(--card);
  }
  .callout.ok { border-color: var(--ok-border); background: var(--ok-bg); color: #7ee787; }
  .callout.bad { border-color: var(--bad-border); background: var(--bad-bg); color: #ff7b72; }
  .toc {
    background: var(--card);
    border: 1px solid var(--line);
    border-radius: 8px;
    padding: 1rem 1.2rem;
    margin: 1.5rem 0;
  }
  .toc strong { display: block; margin-bottom: 0.4rem; color: #f0f6fc; }
  .toc ol { margin: 0; padding-left: 1.3rem; }
  .toc a { text-decoration: none; }
  .toc a:hover { text-decoration: underline; }
  .badge {
    display: inline-block;
    font-family: "JetBrains Mono", Menlo, Consolas, monospace;
    font-size: 0.75rem;
    font-weight: 700;
    padding: 0.1em 0.4em;
    border-radius: 3px;
  }
  .badge.ok { color: var(--ok); background: var(--ok-bg); border: 1px solid var(--ok-border); }
  .badge.bad { color: var(--bad); background: var(--bad-bg); border: 1px solid var(--bad-border); }
  footer {
    margin-top: 3rem;
    padding-top: 1rem;
    border-top: 1px solid var(--line);
    color: var(--muted);
    font-size: 0.9rem;
  }
  @media print {
    :root {
      color-scheme: light;
      --bg: #fff; --ink: #111; --muted: #444; --card: #fff; --line: #ccc;
      --accent: #06c; --code-bg: #f4f4f4; --code-ink: #111; --code-inline: #eee; --th: #f0f0f0;
    }
    body { background: #fff; color: #111; }
    .fig { break-inside: avoid; }
  }
"""

FIG_CONTRAST = """
<figure class="fig" aria-labelledby="fig-contrast-cap">
<svg viewBox="0 0 760 280" role="img" aria-label="BIND publishes partial signatures per quantum; Knot signs then commits once">
  <defs>
    <marker id="arrow" markerWidth="8" markerHeight="8" refX="6" refY="3" orient="auto">
      <path d="M0,0 L6,3 L0,6 Z" fill="#8b949e"/>
    </marker>
  </defs>
  <rect x="20" y="20" width="340" height="240" rx="8" fill="#152238" stroke="#388bfd"/>
  <text x="40" y="48" font-family="Georgia, serif" font-size="16" font-weight="700" fill="#58a6ff">BIND inline-signing</text>
  <text x="40" y="70" font-family="monospace" font-size="11" fill="#8b949e">zone_sign() quantum loop</text>
  <rect x="50" y="95" width="70" height="36" rx="4" fill="#1d4ed8"/><text x="85" y="117" text-anchor="middle" font-family="monospace" font-size="11" fill="#fff">Q1</text>
  <rect x="140" y="95" width="70" height="36" rx="4" fill="#2563eb"/><text x="175" y="117" text-anchor="middle" font-family="monospace" font-size="11" fill="#fff">Q2</text>
  <rect x="230" y="95" width="70" height="36" rx="4" fill="#3b82f6"/><text x="265" y="117" text-anchor="middle" font-family="monospace" font-size="11" fill="#fff">Q3…</text>
  <path d="M85 131 v28" stroke="#f85149" stroke-width="2" marker-end="url(#arrow)"/>
  <path d="M175 131 v28" stroke="#f85149" stroke-width="2" marker-end="url(#arrow)"/>
  <path d="M265 131 v28" stroke="#f85149" stroke-width="2" marker-end="url(#arrow)"/>
  <text x="40" y="185" font-family="Georgia, serif" font-size="13" fill="#f85149">commit + NEEDNOTIFY</text>
  <text x="40" y="205" font-family="Georgia, serif" font-size="13" fill="#f85149">per quantum → half-signed AXFR</text>
  <rect x="50" y="220" width="270" height="24" rx="3" fill="#3d1517" stroke="#f85149"/>
  <text x="185" y="236" text-anchor="middle" font-family="monospace" font-size="11" fill="#ff7b72">lab: 24× PARTLY_SIGNED FAIL</text>
  <rect x="400" y="20" width="340" height="240" rx="8" fill="#12261f" stroke="#3fb950"/>
  <text x="420" y="48" font-family="Georgia, serif" font-size="16" font-weight="700" fill="#3fb950">Knot on-secondary</text>
  <text x="420" y="70" font-family="monospace" font-size="11" fill="#8b949e">refresh finalize</text>
  <rect x="430" y="95" width="100" height="36" rx="4" fill="#8b949e"/><text x="480" y="117" text-anchor="middle" font-family="monospace" font-size="11" fill="#fff">inbound XFR</text>
  <path d="M530 113 H560" stroke="#5a6570" stroke-width="2" marker-end="url(#arrow)"/>
  <rect x="560" y="95" width="140" height="36" rx="4" fill="#0f766e"/><text x="630" y="117" text-anchor="middle" font-family="monospace" font-size="11" fill="#fff">sign entire update</text>
  <path d="M630 131 v28" stroke="#3fb950" stroke-width="2" marker-end="url(#arrow)"/>
  <rect x="545" y="165" width="170" height="36" rx="4" fill="#059669"/><text x="630" y="187" text-anchor="middle" font-family="monospace" font-size="11" fill="#fff">zone_update_commit</text>
  <text x="420" y="225" font-family="Georgia, serif" font-size="13" fill="#3fb950">NOTIFY only after commit</text>
  <rect x="430" y="235" width="270" height="18" rx="3" fill="#123526" stroke="#3fb950"/>
  <text x="565" y="248" text-anchor="middle" font-family="monospace" font-size="11" fill="#7ee787">lab: 28/28 FULLY_SIGNED</text>
</svg>
<figcaption id="fig-contrast-cap">Figure 1. Measured publication models — BIND commits/notifies per signing quantum; Knot signs then commits once.</figcaption>
</figure>
"""

FIG_SCORE = """
<figure class="fig" aria-labelledby="fig-score-cap">
<svg viewBox="0 0 760 210" role="img" aria-label="Pass fail scoreboard across four stacks">
  <text x="20" y="28" font-family="Georgia, serif" font-size="15" font-weight="700" fill="#e6edf3">Definitive battery — 70 scenarios</text>
  <!-- BBB -->
  <g transform="translate(20,50)">
    <rect width="170" height="140" rx="8" fill="#1c2128" stroke="#30363d"/>
    <text x="85" y="28" text-anchor="middle" font-family="monospace" font-size="11" font-weight="700" fill="#58a6ff">BIND-BIND-BIND</text>
    <text x="85" y="70" text-anchor="middle" font-family="monospace" font-size="28" font-weight="700" fill="#f85149">12</text>
    <text x="85" y="92" text-anchor="middle" font-family="Georgia, serif" font-size="12" fill="#f85149">FAIL</text>
    <text x="85" y="120" text-anchor="middle" font-family="monospace" font-size="18" fill="#3fb950">2</text>
    <text x="85" y="138" text-anchor="middle" font-family="Georgia, serif" font-size="11" fill="#3fb950">PASS (flip only)</text>
  </g>
  <g transform="translate(205,50)">
    <rect width="170" height="140" rx="8" fill="#1c2128" stroke="#30363d"/>
    <text x="85" y="28" text-anchor="middle" font-family="monospace" font-size="11" font-weight="700" fill="#58a6ff">BIND-BIND-KNOT</text>
    <text x="85" y="70" text-anchor="middle" font-family="monospace" font-size="28" font-weight="700" fill="#f85149">12</text>
    <text x="85" y="92" text-anchor="middle" font-family="Georgia, serif" font-size="12" fill="#f85149">FAIL (val-off)</text>
    <text x="85" y="120" text-anchor="middle" font-family="monospace" font-size="18" fill="#3fb950">16</text>
    <text x="85" y="138" text-anchor="middle" font-family="Georgia, serif" font-size="11" fill="#3fb950">PASS (val-on+flip)</text>
  </g>
  <g transform="translate(390,50)">
    <rect width="170" height="140" rx="8" fill="#1c2128" stroke="#30363d"/>
    <text x="85" y="28" text-anchor="middle" font-family="monospace" font-size="11" font-weight="700" fill="#3fb950">BIND-KNOT-BIND</text>
    <text x="85" y="80" text-anchor="middle" font-family="monospace" font-size="36" font-weight="700" fill="#3fb950">14</text>
    <text x="85" y="110" text-anchor="middle" font-family="Georgia, serif" font-size="13" fill="#3fb950">PASS / 0 FAIL</text>
    <text x="85" y="132" text-anchor="middle" font-family="monospace" font-size="11" fill="#8b949e">Knot signer</text>
  </g>
  <g transform="translate(575,50)">
    <rect width="165" height="140" rx="8" fill="#1c2128" stroke="#30363d"/>
    <text x="82" y="28" text-anchor="middle" font-family="monospace" font-size="11" font-weight="700" fill="#3fb950">KNOT-KNOT-KNOT</text>
    <text x="82" y="80" text-anchor="middle" font-family="monospace" font-size="36" font-weight="700" fill="#3fb950">14</text>
    <text x="82" y="110" text-anchor="middle" font-family="Georgia, serif" font-size="13" fill="#3fb950">PASS / 0 FAIL</text>
    <text x="82" y="132" text-anchor="middle" font-family="monospace" font-size="11" fill="#8b949e">all Knot</text>
  </g>
</svg>
<figcaption id="fig-score-cap">Figure 2. Scoreboard from the 2026-10-14 ZONESIZE=10 full battery.</figcaption>
</figure>
"""

FIG_TIMELINE_A = """
<figure class="fig" aria-labelledby="fig-tl-a-cap">
<svg viewBox="0 0 780 320" role="img" aria-label="initial-sign timeline showing when lab checks and when BIND publishes">
  <text x="20" y="28" font-family="Georgia, serif" font-size="15" font-weight="700" fill="#e6edf3">Timeline A — initial-sign (BIND FAIL)</text>
  <line x1="40" y1="250" x2="740" y2="250" stroke="#6e7681" stroke-width="2"/>
  <text x="40" y="275" font-family="monospace" font-size="11" fill="#8b949e">t →</text>
  <!-- primary -->
  <rect x="40" y="60" width="120" height="50" rx="6" fill="#1c2128" stroke="#6e7681"/>
  <text x="100" y="80" text-anchor="middle" font-family="monospace" font-size="11" fill="#c9d1d9">PRIMARY</text>
  <text x="100" y="98" text-anchor="middle" font-family="monospace" font-size="10" fill="#8b949e">unsigned s=1</text>
  <line x1="100" y1="110" x2="100" y2="250" stroke="#6e7681" stroke-dasharray="3 3"/>
  <circle cx="100" cy="250" r="6" fill="#8b949e"/>
  <!-- signer quanta -->
  <rect x="200" y="50" width="130" height="70" rx="6" fill="#3d1517" stroke="#f85149"/>
  <text x="265" y="72" text-anchor="middle" font-family="monospace" font-size="11" fill="#ff7b72">SIGNER Q1</text>
  <text x="265" y="90" text-anchor="middle" font-family="monospace" font-size="10" fill="#f85149">commit+NOTIFY</text>
  <text x="265" y="108" text-anchor="middle" font-family="monospace" font-size="10" fill="#f85149">~3 RRSIGs</text>
  <line x1="265" y1="120" x2="265" y2="250" stroke="#f85149"/>
  <circle cx="265" cy="250" r="6" fill="#f85149"/>
  <rect x="360" y="50" width="130" height="70" rx="6" fill="#3d1517" stroke="#f85149"/>
  <text x="425" y="72" text-anchor="middle" font-family="monospace" font-size="11" fill="#ff7b72">SIGNER Q2…</text>
  <text x="425" y="90" text-anchor="middle" font-family="monospace" font-size="10" fill="#f85149">still Signing</text>
  <text x="425" y="108" text-anchor="middle" font-family="monospace" font-size="10" fill="#f85149">serial climbing</text>
  <line x1="425" y1="120" x2="425" y2="250" stroke="#f85149"/>
  <circle cx="425" cy="250" r="6" fill="#f85149"/>
  <!-- dist + check -->
  <rect x="520" y="50" width="140" height="70" rx="6" fill="#2a1a0a" stroke="#db6d28"/>
  <text x="590" y="72" text-anchor="middle" font-family="monospace" font-size="11" fill="#db6d28">DISTRIB AXFR</text>
  <text x="590" y="90" text-anchor="middle" font-family="monospace" font-size="10" fill="#db6d28">serial 389</text>
  <text x="590" y="108" text-anchor="middle" font-family="monospace" font-size="10" fill="#db6d28">3/202830</text>
  <line x1="590" y1="120" x2="590" y2="250" stroke="#db6d28"/>
  <circle cx="590" cy="250" r="6" fill="#db6d28"/>
  <rect x="680" y="140" width="80" height="50" rx="6" fill="#3d1517" stroke="#f85149"/>
  <text x="720" y="162" text-anchor="middle" font-family="monospace" font-size="11" fill="#ff7b72">CHECK</text>
  <text x="720" y="180" text-anchor="middle" font-family="monospace" font-size="10" fill="#f85149">FAIL</text>
  <path d="M590 175 H680" stroke="#f85149" stroke-width="2"/>
  <text x="390" y="305" text-anchor="middle" font-family="Georgia, serif" font-size="12" fill="#8b949e">Lab: compose_fresh → retransfer → one AXFR poll (MAX_ITERS=1) → classify</text>
</svg>
<figcaption id="fig-tl-a-cap">Figure 3. When the incomplete zone is published versus when the lab checks (NSEC initial-sign evidence).</figcaption>
</figure>
"""

FIG_TIMELINE_B = """
<figure class="fig" aria-labelledby="fig-tl-b-cap">
<svg viewBox="0 0 780 250" role="img" aria-label="reload-resign serial-bump force-transfer timeline">
  <text x="20" y="28" font-family="Georgia, serif" font-size="15" font-weight="700" fill="#e6edf3">Timeline B — reload / serial-bump / force-transfer</text>
  <line x1="40" y1="190" x2="740" y2="190" stroke="#6e7681" stroke-width="2"/>
  <rect x="50" y="55" width="150" height="60" rx="6" fill="#152238" stroke="#58a6ff"/>
  <text x="125" y="80" text-anchor="middle" font-family="monospace" font-size="11" fill="#79c0ff">warm / mid-sign</text>
  <text x="125" y="98" text-anchor="middle" font-family="monospace" font-size="10" fill="#8b949e">signer state</text>
  <line x1="125" y1="115" x2="125" y2="190" stroke="#58a6ff" stroke-dasharray="3 3"/>
  <circle cx="125" cy="190" r="6" fill="#58a6ff"/>
  <rect x="240" y="50" width="200" height="70" rx="6" fill="#2a1f0a" stroke="#d29922"/>
  <text x="340" y="72" text-anchor="middle" font-family="monospace" font-size="11" fill="#e3b341">LAB ACTION</text>
  <text x="340" y="90" text-anchor="middle" font-family="monospace" font-size="10" fill="#d29922">rndc sign · serial bump</text>
  <text x="340" y="108" text-anchor="middle" font-family="monospace" font-size="10" fill="#d29922">or force retransfer</text>
  <line x1="340" y1="120" x2="340" y2="190" stroke="#d29922"/>
  <circle cx="340" cy="190" r="6" fill="#d29922"/>
  <rect x="480" y="50" width="150" height="70" rx="6" fill="#3d1517" stroke="#f85149"/>
  <text x="555" y="80" text-anchor="middle" font-family="monospace" font-size="11" fill="#ff7b72">quantum publish</text>
  <text x="555" y="100" text-anchor="middle" font-family="monospace" font-size="10" fill="#f85149">NEEDNOTIFY again</text>
  <line x1="555" y1="120" x2="555" y2="190" stroke="#f85149"/>
  <circle cx="555" cy="190" r="6" fill="#f85149"/>
  <rect x="660" y="55" width="100" height="60" rx="6" fill="#3d1517" stroke="#f85149"/>
  <text x="710" y="80" text-anchor="middle" font-family="monospace" font-size="11" fill="#ff7b72">CHECK</text>
  <text x="710" y="100" text-anchor="middle" font-family="monospace" font-size="10" fill="#f85149">PARTLY</text>
  <line x1="710" y1="115" x2="710" y2="190" stroke="#f85149"/>
  <circle cx="710" cy="190" r="6" fill="#f85149"/>
  <text x="390" y="230" text-anchor="middle" font-family="Georgia, serif" font-size="12" fill="#8b949e">Reload FAILs show higher SOA / more RRSIGs than cold initial-sign — resign mid-flight, still incomplete</text>
</svg>
<figcaption id="fig-tl-b-cap">Figure 3b. Lab-triggered resign / serial / retransfer re-opens the quantum publish window.</figcaption>
</figure>
"""

FIG_TIMELINE_C = """
<figure class="fig" aria-labelledby="fig-tl-c-cap">
<svg viewBox="0 0 780 260" role="img" aria-label="Knot signer timeline showing sign before commit">
  <text x="20" y="28" font-family="Georgia, serif" font-size="15" font-weight="700" fill="#e6edf3">Timeline C — Knot signer (BKB / KKK PASS)</text>
  <line x1="40" y1="200" x2="740" y2="200" stroke="#6e7681" stroke-width="2"/>
  <rect x="60" y="60" width="130" height="55" rx="6" fill="#1c2128" stroke="#6e7681"/>
  <text x="125" y="82" text-anchor="middle" font-family="monospace" font-size="11" fill="#c9d1d9">inbound XFR</text>
  <text x="125" y="100" text-anchor="middle" font-family="monospace" font-size="10" fill="#8b949e">held in update</text>
  <line x1="125" y1="115" x2="125" y2="200" stroke="#6e7681" stroke-dasharray="3 3"/>
  <circle cx="125" cy="200" r="6" fill="#8b949e"/>
  <rect x="240" y="55" width="160" height="65" rx="6" fill="#12261f" stroke="#3fb950"/>
  <text x="320" y="80" text-anchor="middle" font-family="monospace" font-size="11" fill="#7ee787">knot_dnssec_zone_sign</text>
  <text x="320" y="100" text-anchor="middle" font-family="monospace" font-size="10" fill="#3fb950">entire update</text>
  <line x1="320" y1="120" x2="320" y2="200" stroke="#3fb950"/>
  <circle cx="320" cy="200" r="6" fill="#3fb950"/>
  <rect x="450" y="55" width="150" height="65" rx="6" fill="#059669" stroke="#3fb950"/>
  <text x="525" y="80" text-anchor="middle" font-family="monospace" font-size="11" fill="#fff">zone_update_commit</text>
  <text x="525" y="100" text-anchor="middle" font-family="monospace" font-size="10" fill="#d2f4d2">then NOTIFY</text>
  <line x1="525" y1="120" x2="525" y2="200" stroke="#3fb950"/>
  <circle cx="525" cy="200" r="6" fill="#3fb950"/>
  <rect x="640" y="55" width="110" height="65" rx="6" fill="#12261f" stroke="#3fb950"/>
  <text x="695" y="80" text-anchor="middle" font-family="monospace" font-size="11" fill="#7ee787">DISTRIB AXFR</text>
  <text x="695" y="100" text-anchor="middle" font-family="monospace" font-size="10" fill="#3fb950">FULLY_SIGNED</text>
  <line x1="695" y1="120" x2="695" y2="200" stroke="#3fb950"/>
  <circle cx="695" cy="200" r="6" fill="#3fb950"/>
  <text x="390" y="240" text-anchor="middle" font-family="Georgia, serif" font-size="12" fill="#8b949e">No half-signed publication window for the inbound-XFR sign path — 28/28 PASS in this battery</text>
</svg>
<figcaption id="fig-tl-c-cap">Figure 4. Knot signs inside the update, commits once, then notifies — matching all Knot-signer lab results.</figcaption>
</figure>
"""

FIG_TIMELINE_D = """
<figure class="fig" aria-labelledby="fig-tl-d-cap">
<svg viewBox="0 0 780 220" role="img" aria-label="BBK validate-on gate timeline">
  <text x="20" y="28" font-family="Georgia, serif" font-size="15" font-weight="700" fill="#e6edf3">Timeline D — BBK dnssec-validation: on</text>
  <rect x="40" y="60" width="200" height="70" rx="6" fill="#3d1517" stroke="#f85149"/>
  <text x="140" y="88" text-anchor="middle" font-family="monospace" font-size="12" fill="#ff7b72">BIND signer</text>
  <text x="140" y="110" text-anchor="middle" font-family="monospace" font-size="11" fill="#f85149">still PARTLY_SIGNED</text>
  <path d="M240 95 H320" stroke="#8b949e" stroke-width="2"/>
  <rect x="320" y="60" width="220" height="70" rx="6" fill="#2a1f0a" stroke="#d29922"/>
  <text x="430" y="88" text-anchor="middle" font-family="monospace" font-size="12" fill="#e3b341">Knot distribution</text>
  <text x="430" y="110" text-anchor="middle" font-family="monospace" font-size="11" fill="#d29922">validation on → no SOA/AXFR</text>
  <path d="M540 95 H620" stroke="#8b949e" stroke-width="2"/>
  <rect x="620" y="60" width="130" height="70" rx="6" fill="#12261f" stroke="#3fb950"/>
  <text x="685" y="88" text-anchor="middle" font-family="monospace" font-size="12" fill="#7ee787">LAB CHECK</text>
  <text x="685" y="110" text-anchor="middle" font-family="monospace" font-size="11" fill="#3fb950">AXFR_UNAVAILABLE</text>
  <text x="390" y="175" text-anchor="middle" font-family="Georgia, serif" font-size="13" fill="#8b949e">PASS means distribution did not republish bad content — not that BIND stopped publishing it</text>
</svg>
<figcaption id="fig-tl-d-cap">Figure 5. Validate-on is a distribution gate over an unchanged BIND signer race.</figcaption>
</figure>
"""


def slugify(text: str) -> str:
    s = re.sub(r"<[^>]+>", "", text)
    s = s.lower()
    s = re.sub(r"[^a-z0-9]+", "-", s).strip("-")
    return s


def inline(text: str) -> str:
    # links then code then bold
    text = html.escape(text)
    text = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r'<a href="\2">\1</a>', text)
    text = re.sub(r"`([^`]+)`", r"<code>\1</code>", text)
    text = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", text)
    return text


def is_timeline_fence(body: str) -> bool:
    return bool(re.search(r"^t\s*[─\-]", body, re.M)) or "LAB CHECK" in body


def md_to_html(md: str) -> tuple[str, list[tuple[str, str]]]:
    """Return (body_html, toc_items)."""
    lines = md.splitlines()
    out: list[str] = []
    toc: list[tuple[str, str]] = []
    i = 0
    in_table = False
    table_rows: list[str] = []
    skip_title = True
    injected_contrast = False
    injected_score = False
    timeline_figs = {
        "Timeline A": FIG_TIMELINE_A,
        "Timeline B": FIG_TIMELINE_B,
        "Timeline C": FIG_TIMELINE_C,
        "Timeline D": FIG_TIMELINE_D,
    }

    def flush_table() -> None:
        nonlocal in_table, table_rows
        if not table_rows:
            return
        # first row header, second separator
        headers = [c.strip() for c in table_rows[0].strip("|").split("|")]
        body_rows = table_rows[2:] if len(table_rows) > 2 else []
        out.append("<table><thead><tr>")
        for h in headers:
            out.append(f"<th>{inline(h)}</th>")
        out.append("</tr></thead><tbody>")
        for row in body_rows:
            cols = [c.strip() for c in row.strip("|").split("|")]
            out.append("<tr>")
            for c in cols:
                cell = inline(c)
                # badge-ish FAIL/PASS
                if c.strip() == "FAIL":
                    cell = '<span class="badge bad">FAIL</span>'
                elif c.strip() == "PASS":
                    cell = '<span class="badge ok">PASS</span>'
                out.append(f"<td>{cell}</td>")
            out.append("</tr>")
        out.append("</tbody></table>")
        table_rows = []
        in_table = False

    while i < len(lines):
        line = lines[i]

        # skip leading H1 + preamble through first --- (hero holds title/meta)
        if skip_title and line.startswith("# "):
            skip_title = False
            i += 1
            while i < len(lines) and lines[i].strip() != "---":
                i += 1
            if i < len(lines) and lines[i].strip() == "---":
                i += 1
            while i < len(lines) and not lines[i].strip():
                i += 1
            continue

        if line.strip() == "---":
            flush_table()
            i += 1
            continue

        if line.startswith("```"):
            flush_table()
            i += 1
            body_lines: list[str] = []
            while i < len(lines) and not lines[i].startswith("```"):
                body_lines.append(lines[i])
                i += 1
            if i < len(lines):
                i += 1
            body = "\n".join(body_lines)
            out.append(f"<pre><code>{html.escape(body)}</code></pre>")
            # Inject SVG after timeline ASCII blocks when heading previously mentioned
            continue

        if re.match(r"^\|.+\|$", line.strip()):
            if not in_table:
                flush_table()
                in_table = True
                table_rows = []
            table_rows.append(line.strip())
            i += 1
            continue
        else:
            flush_table()

        m = re.match(r"^(#{2,4})\s+(.*)$", line)
        if m:
            level = len(m.group(1))
            title = m.group(2).strip()
            sid = slugify(title)
            out.append(f'<h{level} id="{sid}">{inline(title)}</h{level}>')
            if level == 2:
                toc.append((sid, title))
            if title == "Executive summary" and not injected_contrast:
                out.append(FIG_CONTRAST)
                injected_contrast = True
            if title == "Definitive results" and not injected_score:
                out.append(FIG_SCORE)
                injected_score = True
            for key, fig in timeline_figs.items():
                if title.startswith(key):
                    out.append(fig)
            i += 1
            continue

        if line.startswith("> "):
            flush_table()
            quote = [line[2:]]
            i += 1
            while i < len(lines) and lines[i].startswith("> "):
                quote.append(lines[i][2:])
                i += 1
            out.append("<blockquote><p>" + "<br>".join(inline(q) for q in quote) + "</p></blockquote>")
            continue

        ol = re.match(r"^(\d+)\.\s+(.*)$", line)
        if ol:
            flush_table()
            items = [ol.group(2)]
            i += 1
            while i < len(lines):
                m2 = re.match(r"^\d+\.\s+(.*)$", lines[i])
                if not m2:
                    break
                items.append(m2.group(1))
                i += 1
            out.append("<ol>" + "".join(f"<li>{inline(x)}</li>" for x in items) + "</ol>")
            continue

        if line.startswith("- "):
            flush_table()
            items = [line[2:]]
            i += 1
            while i < len(lines) and lines[i].startswith("- "):
                items.append(lines[i][2:])
                i += 1
            out.append("<ul>" + "".join(f"<li>{inline(x)}</li>" for x in items) + "</ul>")
            continue

        if not line.strip():
            i += 1
            continue

        # paragraph
        paras = [line]
        i += 1
        while i < len(lines) and lines[i].strip() and not re.match(
            r"^(#{2,4}\s>|---|```|\||\d+\.\s|- |\> )", lines[i]
        ) and not lines[i].startswith("#") and not lines[i].startswith(">"):
            if lines[i].startswith("#") or lines[i].startswith("```") or lines[i].startswith("|") or lines[i].startswith("- ") or re.match(r"^\d+\.\s", lines[i]) or lines[i].strip() == "---":
                break
            paras.append(lines[i])
            i += 1
        out.append("<p>" + " ".join(inline(p.strip()) for p in paras) + "</p>")

    flush_table()
    return "\n".join(out), toc


def build(md_path: Path, out_path: Path) -> None:
    md = md_path.read_text(encoding="utf-8")
    # hero meta from first lines
    title = "BIND bump-in-the-wire signer: mid-sign transfers"
    meta_lines: list[str] = []
    for line in md.splitlines()[1:]:
        if line.startswith("#"):
            break
        if line.startswith("**") and ":**" in line:
            meta_lines.append(line)
        if line.strip() == "---":
            break

    body, toc = md_to_html(md)
    toc_html = "".join(f'<li><a href="#{html.escape(s)}">{html.escape(t)}</a></li>' for s, t in toc)
    meta_html = "".join(f"<div>{inline(m.strip())}</div>" for m in meta_lines)

    doc = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{html.escape(title)}</title>
<style>{CSS}</style>
</head>
<body>
<div class="wrap">
<header class="hero">
  <h1>{html.escape(title)}</h1>
  <div class="meta">{meta_html}</div>
</header>

<nav class="toc" aria-label="Contents">
  <strong>Contents</strong>
  <ol>
    {toc_html}
  </ol>
</nav>

{body}

<footer>
  Repository: <a href="https://github.com/davidgroves/signing-lab">github.com/davidgroves/signing-lab</a> ·
  Source: <a href="REPORT.md">REPORT.md</a> · Battery matrix: <a href="RESULTS.html">RESULTS.html</a> ·
  Regenerate with <code>python3 COMMON/scripts/make-report-html.py</code>
</footer>
</div>
</body>
</html>
"""
    out_path.write_text(doc, encoding="utf-8")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--root", type=Path, default=None)
    args = ap.parse_args()
    root = args.root.resolve() if args.root else Path(__file__).resolve().parents[2]
    md = root / "REPORT.md"
    out = root / "REPORT.html"
    build(md, out)
    print(f"Wrote {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
