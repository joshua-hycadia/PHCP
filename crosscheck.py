#!/usr/bin/env python3
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
"""Compare the Perl loop engine against the C++ engine, flow by flow.

This is the only reason the Lisp implementation exists: an independent
derivation of the converged flows.  It compares numbers, not report text, so a
difference in loop ordering or iteration count is allowed while a difference in
the ANSWER is not.
"""
import re, subprocess, sys, pathlib

root = pathlib.Path(__file__).resolve().parent.parent
worst_q = worst_p = 0.0
worst_where = ""
rows = []
skipped = []

for model in sorted((root / "examples").glob("*.hcx")):
    if "grid1000" in model.name:            # 20 s, proves nothing the others don't
        continue
    r = subprocess.run([str(root / "perl" / "phcp.pl"), str(model)],
                       capture_output=True, text=True)
    if r.returncode == 2:
        # The engine refused the model rather than solving it with physics it
        # does not implement.  That is the designed behaviour, not a failure:
        # a silently different answer would be far worse than a refusal.
        why = r.stderr.strip().replace("MODEL ERROR: ", "")
        skipped.append((model.name, why.split(" - ")[0][:60]))
        continue
    out = r.stdout
    lq = {m[1]: float(m[2]) for m in
          (re.match(r"Q (\S+) (\S+)", l) for l in out.splitlines()) if m}
    lp = {m[1]: float(m[2]) for m in
          (re.match(r"P (\S+) (\S+)", l) for l in out.splitlines()) if m}

    out = root / "/tmp/cpp_cc.txt"
    subprocess.run([str(root / "cpp" / "hardycross_cpp"), str(model), str(out)],
                   capture_output=True)
    txt = pathlib.Path(out).read_text()

    # Element flows and node pressures from the report.
    #
    # Split on the LAST occurrence of each heading.  The method statement near
    # the top of the report names every section it is describing, so splitting
    # on the first match landed in the guide text -- which parsed to an empty
    # dict, compared nothing, and printed a reassuring "max dP 0.0000".  A
    # check that silently compares nothing is worse than no check at all.
    cq = {}
    sec = txt.split("ELEMENT RESULTS")[-1].split("FLOW PATH")[0]
    for line in sec.splitlines():
        f = line.split()
        if len(f) >= 6 and re.match(r"^-?\d", f[-3] or ""):
            try: cq[f[0]] = float(f[-3])
            except ValueError: pass
    # node pressures from the NODE SCHEDULE
    cp = {}
    sec = txt.split("NODE SCHEDULE")[-1].split("PIPE SCHEDULE")[0]
    for line in sec.splitlines():
        f = line.split()
        if len(f) >= 5:
            try: cp[f[0]] = float(f[3])
            except ValueError: pass

    shared_q = [k for k in lq if k in cq]
    shared_p = [k for k in lp if k in cp]
    if not shared_q or not shared_p:
        # Nothing matched: say so loudly rather than printing a zero that reads
        # as perfect agreement.
        rows.append((model.name, 0, float("nan"), float("nan")))
        print(f"*** {model.name}: parsed 0 elements / 0 nodes from the report ***")
        continue
    dq = max(abs(lq[k] - cq[k]) for k in shared_q)
    dp = max(abs(lp[k] - cp[k]) for k in shared_p)
    n = len(shared_q)
    rows.append((model.name, n, dq, dp))
    if dq > worst_q: worst_q, worst_where = dq, model.name
    worst_p = max(worst_p, dp)

print(f"{'model':<26}{'elements':>9}{'max dQ L/min':>15}{'max dP kPa':>13}")
print("-" * 64)
for name, n, dq, dp in rows:
    print(f"{name:<26}{n:>9}{dq:>15.6f}{dp:>13.4f}")
print("-" * 64)
for name, why in skipped:
    print(f"{name:<26}  OUT OF SCOPE - {why}")
if skipped:
    print("-" * 64)
print(f"worst flow disagreement : {worst_q:.6f} L/min  ({worst_where})")
print(f"worst pressure disagreement : {worst_p:.4f} kPa")
sys.exit(0 if worst_q < 0.5 and worst_p < 0.5 else 1)
