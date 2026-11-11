"""Compare every engine against PHCP and write the tables and plots.

    python tools/compare.py          round 1: models/ and results/
    python tools/compare.py A        round 2 suite A: models_A/ and results_A/
    python tools/compare.py B        round 2 suite B: models_B/ and results_B/

Reads the models and <results>/<engine>.jsonl.gz (one normalised result per
model: requirement, total flow, every head pressure, every pipe flow) and
writes results.csv, summary.md and the two plots beside them.
"""

from __future__ import annotations

import csv
import gzip
import json
import math
import statistics as st
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SUITE = sys.argv[1].upper() if len(sys.argv) > 1 else ""
SFX = f"_{SUITE}" if SUITE else ""
OUT = ROOT / f"results{SFX}"
REF = "phcp"
# suite B (devices) is run only by the programs that take a BFP, a fixed-drop PRV and a
# fixed-bore orifice plate natively
ENGINES = ["phcp", "au", "epanet"] if SUITE == "B" else ["phcp", "au", "us1", "us2", "us3", "epanet"]
LABEL = {"phcp": "PHCP 1.0.0", "au": "AU Calc Program", "us3": "US Calc Program 3",
         "us1": "US Calc Program 1", "us2": "US Calc Program 2", "epanet": "EPANET 2.2"}
FAM = ["tree", "loop", "grid"]


def load():
    models = {p.stem: json.loads(p.read_text(encoding="utf-8"))
              for p in sorted((ROOT / f"models{SFX}").glob("*.json"))}
    res = {e: {} for e in ENGINES}
    for e in ENGINES:
        with gzip.open(OUT / f"{e}.jsonl.gz", "rt", encoding="utf-8") as f:
            for line in f:
                r = json.loads(line)
                res[e][r["model"]] = r
    # PHCP's label is the version that produced its results (the stored run is
    # 1.0.0; tools/rerun_phcp.py records the version it ran)
    progs = {r["program"] for r in res[REF].values() if r.get("program")}
    if len(progs) == 1:
        LABEL[REF] = progs.pop()
    return models, res


def rows(models, res):
    out = []
    for mid, m in models.items():
        ref = res[REF].get(mid)
        ok_vals = [res[e][mid]["supply_kpa"] for e in ENGINES if res[e].get(mid, {}).get("ok")]
        med = st.median(ok_vals) if ok_vals else None
        for e in ENGINES:
            r = res[e].get(mid)
            row = dict(model=mid, family=m["family"], heads=m["counts"]["heads"], pipes=m["counts"]["pipes"],
                       loops=m["counts"]["loops"], engine=e, ok=bool(r and r.get("ok")),
                       converged=bool(r and r.get("converged")), supply_kpa=None, flow_lpm=None,
                       d_supply_kpa=None, d_supply_pct=None, d_flow_pct=None, d_median_pct=None,
                       head_max_kpa=None, head_rms_kpa=None, pipe_max_lpm=None, pipe_max_pct=None,
                       seconds=r.get("seconds") if r else None, iterations=r.get("iterations") if r else None,
                       )
            if row["ok"]:
                row["supply_kpa"], row["flow_lpm"] = r["supply_kpa"], r["flow_lpm"]
                if med:
                    row["d_median_pct"] = 100 * (r["supply_kpa"] - med) / med
                if ref and ref.get("ok") and e != REF:
                    row["d_supply_kpa"] = r["supply_kpa"] - ref["supply_kpa"]
                    row["d_supply_pct"] = 100 * row["d_supply_kpa"] / ref["supply_kpa"]
                    row["d_flow_pct"] = 100 * (r["flow_lpm"] - ref["flow_lpm"]) / ref["flow_lpm"]
                    common = set(r["heads"]) & set(ref["heads"])
                    if common:
                        d = [r["heads"][k] - ref["heads"][k] for k in common]
                        row["head_max_kpa"] = max(abs(x) for x in d)
                        row["head_rms_kpa"] = math.sqrt(sum(x * x for x in d) / len(d))
                    cp = set(r["pipes"]) & set(ref["pipes"])
                    if cp:
                        d = [(abs(r["pipes"][k] - ref["pipes"][k]), abs(ref["pipes"][k])) for k in cp]
                        row["pipe_max_lpm"] = max(x for x, _ in d)
                        big = [x / q * 100 for x, q in d if q > 10]
                        row["pipe_max_pct"] = max(big) if big else None
            out.append(row)
    return out


def pct(v, q):
    v = sorted(v)
    if not v:
        return None
    i = min(len(v) - 1, max(0, int(math.ceil(q * len(v))) - 1))
    return v[i]


def fmt(x, nd=2):
    return "-" if x is None else f"{x:.{nd}f}"


def summary(rs):
    lines = []
    for scope in ["all"] + FAM:
        sel = [r for r in rs if scope == "all" or r["family"] == scope]
        n = len({r["model"] for r in sel})
        lines.append(f"\n### {'All 300 models' if scope == 'all' else scope.capitalize() + 's'} ({n} models)\n")
        lines.append("| Engine | Solved | Supply vs PHCP: median % | mean % | P95 abs % | max abs % "
                     "| Total flow vs PHCP: median % | Head pressure max diff kPa: median / max "
                     "| Pipe flow max diff %: median | Median run s |")
        lines.append("|---|---|---|---|---|---|---|---|---|---|")
        for e in ENGINES:
            er = [r for r in sel if r["engine"] == e]
            ok = [r for r in er if r["ok"]]
            dp = [r["d_supply_pct"] for r in ok if r["d_supply_pct"] is not None]
            dq = [r["d_flow_pct"] for r in ok if r["d_flow_pct"] is not None]
            hm = [r["head_max_kpa"] for r in ok if r["head_max_kpa"] is not None]
            pm = [r["pipe_max_pct"] for r in ok if r["pipe_max_pct"] is not None]
            tt = [r["seconds"] for r in ok if r["seconds"] is not None]
            if e == REF:
                lines.append(f"| {LABEL[e]} (reference) | {len(ok)}/{len(er)} | - | - | - | - | - | - | - | "
                             f"{fmt(st.median(tt) if tt else None)} |")
                continue
            lines.append(
                f"| {LABEL[e]} | {len(ok)}/{len(er)} | {fmt(st.median(dp) if dp else None)} | "
                f"{fmt(st.mean(dp) if dp else None)} | {fmt(pct([abs(x) for x in dp], .95))} | "
                f"{fmt(max(abs(x) for x in dp) if dp else None)} | {fmt(st.median(dq) if dq else None)} | "
                f"{fmt(st.median(hm) if hm else None)} / {fmt(max(hm) if hm else None)} | "
                f"{fmt(st.median(pm) if pm else None)} | {fmt(st.median(tt) if tt else None)} |")
    return "\n".join(lines)


def plots(rs, out):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    mk = {"tree": "o", "loop": "s", "grid": "^"}
    n = len(ENGINES) - 1
    fig, axs = plt.subplots(1, n, figsize=(4 * n, 4.2), sharey=True, squeeze=False)
    axs = axs[0]
    for ax, e in zip(axs, ENGINES[1:]):
        for f in FAM:
            pts = [(r["heads"], r["d_supply_pct"]) for r in rs if r["engine"] == e and r["family"] == f
                   and r["d_supply_pct"] is not None]
            if pts:
                ax.scatter(*zip(*pts), s=12, marker=mk[f], label=f, alpha=.75)
        ax.axhline(0, color="k", lw=.6)
        ax.set_title(LABEL[e], fontsize=10)
        ax.set_xlabel("operating heads")
        ax.grid(alpha=.3)
    axs[0].set_ylabel("required supply pressure vs PHCP, %")
    axs[0].legend(fontsize=8)
    fig.tight_layout()
    fig.savefig(out / "supply_vs_phcp.png", dpi=130)
    plt.close(fig)

    fig, ax = plt.subplots(figsize=(8, 4.5))
    for e in ENGINES:
        pts = sorted((r["pipes"], r["seconds"]) for r in rs if r["engine"] == e and r["ok"] and r["seconds"])
        if pts:
            ax.scatter(*zip(*pts), s=8, label=LABEL[e], alpha=.7)
    ax.set_xlabel("pipes in model")
    ax.set_ylabel("wall time per model, s (incl. outer search)")
    ax.set_yscale("log")
    ax.grid(alpha=.3)
    ax.legend(fontsize=8)
    fig.tight_layout()
    fig.savefig(out / "runtime.png", dpi=130)
    plt.close(fig)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    models, res = load()
    rs = rows(models, res)
    keys = list(rs[0].keys())
    with open(OUT / "results.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=keys)
        w.writeheader()
        for r in rs:
            w.writerow({k: (f"{v:.6g}" if isinstance(v, float) else v) for k, v in r.items()})
    (OUT / "summary.md").write_text(summary(rs) + "\n", encoding="utf-8")
    plots(rs, OUT)
    fails = [r for r in rs if not r["ok"]]
    print(summary(rs))
    print(f"\n{len(fails)} failed runs")
    for r in fails[:40]:
        print(" ", r["engine"], r["model"])


if __name__ == "__main__":
    main()
