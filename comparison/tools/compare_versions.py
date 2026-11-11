"""PHCP against itself: the re-run (tools/rerun_phcp.py) against the stored
PHCP 1.0.0 results, model by model.

    python tools/compare_versions.py [rerun-dir]      (default comparison/rerun)

Writes <rerun-dir>/versions.md: for each suite, how many models solved, and
the largest differences in the requirement, the total flow, any head
pressure and any pipe flow, with the model each occurs on; and the run time
against 1.0.0's.  The other programs are compared in compare.py.
"""

from __future__ import annotations

import gzip
import json
import statistics as st
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RERUN = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "rerun"


def load(p: Path) -> dict:
    with gzip.open(p, "rt", encoding="utf-8") as f:
        return {r["model"]: r for r in map(json.loads, f)}


def worst(pairs):
    """(value, model) of the largest absolute value, or (None, '')."""
    pairs = [(v, m) for v, m in pairs if v is not None]
    return max(pairs, key=lambda x: abs(x[0])) if pairs else (None, "")


def main() -> int:
    out = ["# PHCP re-run against PHCP 1.0.0", ""]
    for s, name in (("R", "Round 1 (no fittings)"), ("A", "Round 2 suite A (fittings)"),
                    ("B", "Round 2 suite B (fittings and devices)")):
        old = load(ROOT / ("results" if s == "R" else f"results_{s}") / "phcp.jsonl.gz")
        new = load(RERUN / s / "phcp.jsonl.gz")
        prog = sorted({r.get("program", "?") for r in new.values() if r.get("ok")})
        both = [m for m in old if old[m].get("ok") and new.get(m, {}).get("ok")]
        dsup = [(100 * (new[m]["supply_kpa"] - old[m]["supply_kpa"]) / old[m]["supply_kpa"], m) for m in both]
        dkpa = [(new[m]["supply_kpa"] - old[m]["supply_kpa"], m) for m in both]
        dflow = [(100 * (new[m]["flow_lpm"] - old[m]["flow_lpm"]) / old[m]["flow_lpm"], m) for m in both]
        dhead = [(max((abs(new[m]["heads"][k] - v) for k, v in old[m]["heads"].items() if k in new[m]["heads"]),
                      default=None), m) for m in both]
        dpipe = [(max((abs(new[m]["pipes"][k] - v) for k, v in old[m]["pipes"].items() if k in new[m]["pipes"]),
                      default=None), m) for m in both]
        keys = sum(set(old[m]["heads"]) != set(new[m]["heads"]) or set(old[m]["pipes"]) != set(new[m]["pipes"])
                   for m in both)
        ratio = [new[m]["seconds"] / old[m]["seconds"] for m in both if old[m]["seconds"] > 0]
        failed = [f"{m} ({new.get(m, {}).get('error', 'not run')})" for m in old if not new.get(m, {}).get("ok")]
        acc = {}
        for r in new.values():
            acc[r.get("acceptance", "-")] = acc.get(r.get("acceptance", "-"), 0) + 1

        def row(label, pairs, unit, nd):
            v, m = worst(pairs)
            med = st.median(abs(x) for x, _ in pairs if x is not None) if pairs else None
            return (f"| {label} | {med:.{nd}f} {unit} | {v:+.{nd}f} {unit} ({m}) |" if v is not None
                    else f"| {label} | - | - |")

        out += [f"## {name}", "",
                f"{', '.join(prog)}: {len(both)} of {len(old)} models solved by both, "
                f"{len(new)} re-run.  Heads or pipes not matched by name: {keys} models.", "",
                "| Difference from 1.0.0 | median abs | worst |", "|---|---|---|",
                row("required supply pressure", dsup, "%", 4),
                row("required supply pressure", dkpa, "kPa", 4),
                row("total flow", dflow, "%", 4),
                row("worst head pressure", dhead, "kPa", 4),
                row("worst pipe flow", dpipe, "L/min", 4), "",
                f"Run time against 1.0.0's: median x{st.median(ratio):.2f}, "
                f"range x{min(ratio):.2f} - x{max(ratio):.2f} (different computers; an order of magnitude only)."
                if ratio else "", "",
                "Acceptance of the second solve (supply at its requirement): "
                + ", ".join(f"{k} {v}" for k, v in sorted(acc.items())) + ".", ""]
        if failed:
            out += ["Not solved: " + "; ".join(failed), ""]
    (RERUN / "versions.md").write_text("\n".join(out) + "\n", encoding="utf-8")
    print("\n".join(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
