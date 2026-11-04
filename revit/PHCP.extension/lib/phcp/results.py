# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
# What to do with a solved model: which value goes back on which element,
# which colour a view should use, and which pipes auto sizing would change.
#
# Pass and fail come from the engine.  The colour bands are only for the
# view.  A pass drawn amber is still a pass; the band shows how little
# pressure is left so it can be seen without opening the report.

from phcp import JSON_INTERFACE
from phcp.parameters import DEFAULT_VELOCITY_LIMIT

# Pressure to spare below which a pass is drawn amber.  Display only.
MARGIN_BAND_KPA = 50.0

# Flow bands, in L/min, the unit the extension's models are written in.
# Darker is more flow.  The edges are round numbers a designer can remember.
FLOW_BANDS = (
    (100.0, (198, 219, 239), "0 TO 100 L/MIN"),
    (500.0, (158, 202, 225), "100 TO 500 L/MIN"),
    (1500.0, (49, 130, 189), "500 TO 1500 L/MIN"),
    (3000.0, (8, 81, 156), "1500 TO 3000 L/MIN"),
    (None, (8, 48, 107), "OVER 3000 L/MIN"),
)

_VEL_BANDS = (
    (0.5, (65, 171, 93), "UP TO HALF THE LIMIT"),
    (0.8, (116, 196, 118), "HALF TO 80% OF THE LIMIT"),
    (1.0, (253, 174, 97), "80% OF THE LIMIT TO THE LIMIT"),
    (None, (215, 48, 39), "OVER THE LIMIT"),
)

_ABILITY = {
    "fail": ((215, 48, 39), "FAILS"),
    "tight": ((253, 174, 97), "PASSES, LESS THAN %.0f KPA TO SPARE" % MARGIN_BAND_KPA),
    "pass": ((65, 171, 93), "PASSES"),
}


class ResultError(Exception):
    pass


def accept(data):
    """The JSON object, or raise if it is not the contract this was written for."""
    if not isinstance(data, dict):
        raise ResultError("PHCP did not return a result")
    if data.get("interface") != JSON_INTERFACE:
        raise ResultError(
            "PHCP returned interface %s; this extension reads interface %d"
            % (data.get("interface"), JSON_INTERFACE))
    return data


def summary_text(data):
    """The lines the engine says to show a user, one to a line."""
    lines = data.get("summary") or []
    if lines:
        return "\n".join(str(line) for line in lines)
    status = data.get("status") or "error"
    errs = data.get("errors") or []
    if errs:
        bits = []
        for err in errs:
            if isinstance(err, dict):
                line = err.get("line")
                msg = err.get("message") or ""
                bits.append(("line %s: %s" % (line, msg)) if line else msg)
            else:
                bits.append(str(err))
        return "\n".join(bits)
    return status.upper()


def element_results(data, id_by_phcp):
    """(revit id, {parameter: value}) for each result the engine returned.

    id_by_phcp maps a PHCP pipe id, outlet id or node id to a Revit element
    id.  A node id is the outlet or the supply that names it.  Flow on a
    pipe is signed as the engine signed it.
    """
    writes = {}

    def put(phcp_id, values):
        rid = id_by_phcp.get(phcp_id)
        if not rid:
            return
        slot = writes.setdefault(rid, {})
        slot.update(values)

    for pipe in data.get("pipes") or []:
        put(pipe.get("id"), {
            "PHCP Flow": pipe.get("flow"),
            "PHCP Velocity": pipe.get("velocity"),
            "PHCP Friction Loss": pipe.get("friction_loss"),
        })
    for node in data.get("nodes") or []:
        put(node.get("id"), {"PHCP Pressure": node.get("pressure")})
    for out in data.get("outlets") or []:
        put(out.get("id"), {
            "PHCP Flow": out.get("flow"),
            "PHCP Pressure": out.get("pressure"),
            "PHCP Margin": out.get("margin"),
            "PHCP Pass": bool(out.get("pass")),
        })
    demand = data.get("demand") or {}
    if demand.get("supply"):
        put(demand["supply"], {
            "PHCP Flow": demand.get("flow"),
            "PHCP Pressure": demand.get("available"),
            "PHCP Margin": demand.get("margin"),
            "PHCP Pass": bool(demand.get("meets")),
        })
    return writes


def suggestions(data, current_dn):
    """Pipes auto sizing changed, as (id, was, suggested, velocity).

    current_dn maps the pipe id to the DN the model had before it was set
    to 0.  A pipe the engine did not size is absent.  The modelled size is
    not changed by this; the caller stores the suggestion.
    """
    found = []
    for row in data.get("sized") or []:
        for pid in row.get("pipes") or []:
            found.append({
                "id": pid,
                "was": current_dn.get(pid),
                "dn": row.get("dn"),
                "velocity": row.get("velocity"),
                "line": row.get("line"),
            })
    return found


def pipes_over_velocity(data, limit=None):
    """Pipe ids whose solved speed is over the limit.  The limit is m/s."""
    cap = float(limit if limit else DEFAULT_VELOCITY_LIMIT)
    over = []
    for pipe in data.get("pipes") or []:
        speed = pipe.get("velocity")
        if speed is not None and abs(speed) > cap:
            over.append(pipe.get("id"))
    return over


def colour_velocity(speeds, limit=None):
    """{revit id: (r, g, b)} and the legend, from solved speeds in m/s.

    speeds is {revit id: velocity}.  The bands are fractions of the limit.
    """
    cap = float(limit if limit else DEFAULT_VELOCITY_LIMIT)
    colours = {}
    for rid, speed in speeds.items():
        if speed is None or cap <= 0:
            continue
        colours[rid] = _band(abs(speed) / cap, _VEL_BANDS)
    legend = [(rgb, label) for _frac, rgb, label in _VEL_BANDS]
    return colours, legend


def colour_flow(flows):
    """{revit id: rgb} and the legend, from solved flows in L/min."""
    colours = {}
    for rid, flow in flows.items():
        if flow is None:
            continue
        colours[rid] = _flow_rgb(abs(flow))
    legend = [(rgb, label) for _edge, rgb, label in FLOW_BANDS]
    return colours, legend


def colour_ability(outlets, pipes):
    """Colour outlets, and the pipes that end on them, by pass and margin.

    outlets: {revit id: {"node": name, "pass": bool, "margin": kPa}}
    pipes:   {revit id: (node name, node name)}

    A main with no outlet at either end is left uncoloured, so a failing
    branch reads on its own and the main stays as drawn.  The margin band
    is display only; pass and fail are the engine's.
    """
    colours = {}
    worst = {}
    for rid, out in outlets.items():
        kind = _ability_kind(out)
        colours[rid] = _ABILITY[kind][0]
        node = out.get("node")
        if node:
            rank = {"fail": 2, "tight": 1, "pass": 0}[kind]
            if rank >= worst.get(node, (-1, None))[0]:
                worst[node] = (rank, kind)
    for rid, ends in pipes.items():
        ranks = [worst[n] for n in ends if n in worst]
        if not ranks:
            continue
        kind = max(ranks)[1]
        colours[rid] = _ABILITY[kind][0]
    legend = [(rgb, label) for rgb, label in (v for v in _ABILITY.values())]
    return colours, legend


def _ability_kind(out):
    if not out.get("pass"):
        return "fail"
    margin = out.get("margin")
    if margin is not None and margin < MARGIN_BAND_KPA:
        return "tight"
    return "pass"


def _flow_rgb(flow):
    for edge, rgb, _label in FLOW_BANDS:
        if edge is None or flow <= edge:
            return rgb
    return FLOW_BANDS[-1][1]


def legend_note(legend):
    """The colour key as a text note: one band to a line."""
    lines = ["PHCP"]
    for rgb, label in legend:
        lines.append("#%02X%02X%02X  %s" % (int(rgb[0]), int(rgb[1]), int(rgb[2]), label))
    return "\n".join(lines)


def failing_ids(outlets):
    """Revit ids of outlets whose stored pass is no.

    outlets is {revit id: {"pass": bool, ...}}, as the host reads it back.
    An outlet with no pass yet is not in that dict, so it is not selected.
    """
    return [rid for rid, out in outlets.items() if out.get("pass") is False]


def fast_ids(speeds, limit=None):
    """Revit ids of pipes whose stored velocity is over the limit."""
    cap = float(limit if limit else DEFAULT_VELOCITY_LIMIT)
    return [rid for rid, speed in speeds.items() if speed is not None and abs(speed) > cap]


def dns_to_apply(suggested):
    """{revit id: suggested DN} to the sizes worth storing.

    A blank and a size of 0 are left.  Size 0 asks the engine to choose; it
    is not itself a size to put on the pipe.  The Revit diameter is not in
    this map.  The caller writes PHCP DN only.
    """
    out = {}
    for rid, dn in suggested.items():
        if dn is None:
            continue
        try:
            value = float(dn)
        except (TypeError, ValueError):
            continue
        if value <= 0:
            continue
        out[rid] = value
    return out


def _band(fraction, table):
    for edge, rgb, _label in table:
        if edge is None or fraction <= edge:
            return rgb
    return table[-1][1]
