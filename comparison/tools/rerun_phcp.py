"""Re-run PHCP on the comparison models and write its results in the
normalised form compare.py reads.

    python tools/rerun_phcp.py [--shard I/N] [--out DIR] [--timeout S] [suite ...]

Suites are R (round 1, models/), A and B (round 2, models_A/ and models_B/);
all three if none is given.  The other programs' results are not touched:
they are what those programs gave on 4 November 2026, and only PHCP is run
again here.

The method is the one used for the original run.  PHCP solves once for the
demand point (the supply pressure at which the governing head has exactly its
minimum).  The supply is then set to that pressure and the network solved
again, and every head pressure and pipe flow is taken from that second solve.

--shard I/N runs every Nth model from the Ith (models dealt longest first, by
PHCP's time in the stored results, so the shards finish together), and writes
<out>/<suite>/phcp.<I>.jsonl.  Without --shard every model is run and
<out>/<suite>/phcp.jsonl.gz is written.  --merge joins the shard files.
A model that takes longer than --timeout seconds (default 3 h) is recorded as
not solved, with the reason.
"""

from __future__ import annotations

import argparse
import gzip
import json
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent      # comparison/
REPO = ROOT.parent                                  # the PHCP checkout
PHCP = REPO / "phcp.pl"


def folder(suite: str, kind: str) -> Path:
    return ROOT / (kind if suite == "R" else f"{kind}_{suite}")


def solve(text: str, timeout: float) -> dict:
    """One `phcp.pl --json` run on a model given as text."""
    with tempfile.NamedTemporaryFile("w", suffix=".phc", delete=False, newline="\n") as f:
        f.write(text)
        path = f.name
    try:
        r = subprocess.run(["perl", str(PHCP), "--json", path], capture_output=True, text=True,
                           cwd=REPO, timeout=timeout)
    finally:
        Path(path).unlink()
    return json.loads(r.stdout)


def run_model(suite: str, model: str, timeout: float) -> dict:
    src = (folder(suite, "models") / f"{model}.phc").read_text()
    t0 = time.perf_counter()
    rec = {"engine": "phcp", "model": model, "ok": False}
    try:
        first = solve(src, timeout)
        p = first["demand"]["pressure"]
        sup = first["demand"]["supply"]
        # the second solve: the supply at the requirement just found
        src2, n = re.subn(rf"^(WATER\s+{re.escape(sup)}\s+\S+\s+)\S+", rf"\g<1>{p:.4f}", src, flags=re.M)
        if n != 1:
            raise ValueError(f"no single WATER line for {sup}")
        j = solve(src2, max(1.0, timeout - (time.perf_counter() - t0)))
        rec.update(ok=bool(j["converged"]), converged=bool(j["converged"]), supply_kpa=round(p, 4),
                   flow_lpm=j["demand"]["flow"], iterations=2, program=j["program"],
                   acceptance=j["acceptance"],
                   # the stored results name heads and pipes without their N / P prefix
                   heads={o["node"][1:]: o["pressure"] for o in j["outlets"]},
                   pipes={q["id"][1:]: q["flow"] for q in j["pipes"]})
    except subprocess.TimeoutExpired:
        rec["error"] = f"not solved within {timeout:.0f} s"
    except Exception as e:  # noqa: BLE001 -- recorded, and the run goes on
        rec["error"] = repr(e)[:300]
    rec["seconds"] = time.perf_counter() - t0
    return rec


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("suites", nargs="*", default=["R", "A", "B"])
    ap.add_argument("--shard", default="0/1")
    ap.add_argument("--out", default=str(ROOT / "rerun"))
    ap.add_argument("--timeout", type=float, default=3 * 3600)
    ap.add_argument("--merge", action="store_true")
    a = ap.parse_args()
    out = Path(a.out)

    if a.merge:
        for s in a.suites:
            rows = []
            for f in sorted((out / s).glob("phcp.*.jsonl")):
                rows += [json.loads(line) for line in f.read_text().splitlines() if line]
            rows.sort(key=lambda r: r["model"])
            with gzip.open(out / s / "phcp.jsonl.gz", "wt", encoding="utf-8") as g:
                g.writelines(json.dumps(r) + "\n" for r in rows)
            print(f"{s}: {len(rows)} models, {sum(r['ok'] for r in rows)} solved")
        return 0

    i, n = (int(x) for x in a.shard.split("/"))
    jobs = []
    for s in a.suites:
        with gzip.open(folder(s, "results") / "phcp.jsonl.gz", "rt") as f:
            jobs += [(r["seconds"], s, r["model"]) for r in map(json.loads, f)]
    jobs.sort(reverse=True)
    mine = jobs[i::n]
    for k, (_, s, m) in enumerate(mine, 1):
        rec = run_model(s, m, a.timeout)
        d = out / s
        d.mkdir(parents=True, exist_ok=True)
        with open(d / f"phcp.{i}.jsonl", "a", encoding="utf-8") as f:
            f.write(json.dumps(rec) + "\n")
        print(f"{k}/{len(mine)} {s} {m} ok={rec['ok']} {rec['seconds']:.1f}s {rec.get('error', '')}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
