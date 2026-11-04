# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
# What each ribbon button does.  The buttons themselves are a few lines;
# the work is here so it can be found in one place.  PyRevit is imported
# only when a button runs.

import os
import traceback

import phcp.revit_host as host
from phcp.fittings import parse_rules
from phcp.model import Issue, parse_curve, walk, write_phc, zero_pipe_sizes
from phcp.parameters import DEFAULT_VELOCITY_LIMIT
from phcp.results import (
    colour_ability, colour_flow, colour_velocity, element_results,
    pipes_over_velocity, suggestions, summary_text,
)
from phcp.revit_ui import ask_choice, ask_form, open_exe, save_phc, tell
from phcp.runner import command_for, load_exe, run, save_exe

_SCOPES = ["CONNECTED NETWORK", "ACTIVE VIEW", "WHOLE MODEL"]


def _guard(fn):
    try:
        fn()
    except Exception as err:
        traceback.print_exc()
        tell(str(err))


def _need_parameters(doc):
    if doc.ProjectInformation.LookupParameter("PHCP Title") is None:
        tell("Run PARAMETERS first. The PHCP parameters are not in this model yet.")
        return False
    return True


def _show(walked):
    lines = ["%d pipes, %d outlets, %d supplies, %d nodes." % (
        len([p for p in walked.pipes if not p.omit]),
        len(walked.outlets), len(walked.supplies), len(walked.nodes))]
    if walked.ok and not walked.warnings:
        lines.append("No problems found.")
    for issue in walked.issues:
        lines.append("%s: %s" % (issue.severity.upper(), issue.message))
    text = "\n".join(lines)
    print(text)
    if len(lines) > 40:
        short = "\n".join(lines[:40]) + "\n... %d more lines are in the pyRevit output." % (len(lines) - 40)
    else:
        short = text
    tell(short, echo=False)


def _error_ids(walked):
    ids = []
    for issue in walked.errors:
        ids.extend(issue.revit_ids)
    return ids


def _prepare(need_ok):
    """Ask what to walk, walk it, and store any ids the walk minted.

    Returns (doc, uidoc, walked) or None when the designer cancels, or when
    need_ok is set and the walk has errors.  Warnings do not stop a walk:
    the model is still written, and the warnings are shown with the result.
    """
    doc, uidoc = host._doc()
    if not _need_parameters(doc):
        return None
    scope = ask_choice("PHCP", "Walk which pipes?", _SCOPES)
    if not scope:
        return None
    net = host.read_network(doc, scope, uidoc.ActiveView, load_exe())
    seeds = None
    if scope == "CONNECTED NETWORK":
        seeds = host.selected_keys(uidoc, net)
        if not seeds:
            tell("Select a pipe, an outlet or a supply to walk from.")
            return None
    walked = walk(net, seeds=seeds)
    if getattr(net, "skipped_flex", 0):
        walked.issues.insert(0, Issue(
            "warning",
            "%d flex pipes were skipped; a flex pipe has no single nominal size" % net.skipped_flex))
    host.apply_assignments(doc, walked.assignments)
    if need_ok and not walked.ok:
        _show(walked)
        host.select_ids(uidoc, _error_ids(walked))
        return None
    return doc, uidoc, walked


def _number(text, label):
    text = (text or "").strip()
    if not text:
        return None
    try:
        return float(text)
    except ValueError:
        raise host.RevitHostError("%s must be a number" % label)


def _paths(doc):
    import tempfile
    path = ""
    try:
        path = doc.PathName or ""
    except Exception:
        path = ""
    if path:
        folder = os.path.dirname(path)
        base = os.path.splitext(os.path.basename(path))[0]
    else:
        folder = tempfile.gettempdir()
        base = doc.Title or "phcp"
    return os.path.join(folder, base + ".phc"), os.path.join(folder, base + "-phcp.pdf")


def _solve(text, report=None):
    exe = load_exe()
    if not exe:
        tell("Run ENGINE and choose phcp.exe. Nothing was solved.")
        return None
    result = run(command_for(exe), text, report_path=report)
    try:
        if result.model_path and os.path.isfile(result.model_path):
            os.remove(result.model_path)
    except OSError:
        pass
    return result


def _legend(legend):
    return "\n".join("%s  %s" % ("#%02X%02X%02X" % rgb, label) for rgb, label in legend)


# ---------------------------------------------------------------- setup
def engine_path():
    def go():
        current = load_exe() or ""
        path = open_exe()
        if not path:
            return
        if not os.path.isfile(path):
            tell("That file was not found.")
            return
        save_exe(path)
        tell("PHCP will use\n%s" % path)
    _guard(go)


def parameters():
    def go():
        doc, _uidoc = host._doc()
        bound = host.ensure_parameters(doc)
        tell("PHCP parameters are in this model (%d bound)." % bound)
    _guard(go)


def project_settings():
    def go():
        doc, _uidoc = host._doc()
        if not _need_parameters(doc):
            return
        project = host.read_project(doc)
        rows = [
            ("title", "TITLE", project.title, False),
            ("job", "JOB", project.fields.get("JOB", ""), False),
            ("company", "COMPANY", project.fields.get("COMPANY", ""), False),
            ("designer", "DESIGNER", project.fields.get("DESIGNER", ""), False),
            ("hazard", "HAZARD", project.fields.get("HAZARD", ""), False),
            ("density", "DENSITY", project.fields.get("DENSITY", ""), False),
            ("area", "AREA PER SPRINKLER", project.fields.get("AREA_PER_SPRINKLER", ""), False),
            ("authority", "AUTHORITY", project.fields.get("AUTHORITY", ""), False),
            ("method", "METHOD: HW OR DW", project.method, False),
            ("vpress", "VELOCITY PRESSURE: YES OR NO",
             "YES" if project.velocity_pressure else "NO", False),
            ("hose", "HOSE ALLOWANCE, L/MIN. BLANK FOR NONE",
             "" if not project.hose_allowance else ("%g" % project.hose_allowance), False),
            ("vlim", "VELOCITY LIMIT, M/S. BLANK FOR 6",
             "" if not project.velocity_limit else ("%g" % project.velocity_limit), False),
            ("tol", "JOIN TOLERANCE, MM", "%g" % project.tolerance_mm, False),
            ("goal", "SIZING GOAL: SMALLEST OR VOLUME. BLANK FOR SMALLEST",
             project.sizing_goal or "", False),
            ("margin", "SIZING MARGIN, SUCH AS 10% OR 50. BLANK FOR NONE",
             project.sizing_margin or "", False),
            ("darea", "DESIGN AREA TO SOLVE. BLANK SOLVES EVERY AREA",
             project.design_area or "", False),
        ]
        got = ask_form("PHCP PROJECT", rows)
        if not got:
            return
        host.set_project(doc, {
            "PHCP Title": got["title"],
            "PHCP Job": got["job"],
            "PHCP Company": got["company"],
            "PHCP Designer": got["designer"],
            "PHCP Hazard": got["hazard"],
            "PHCP Density": got["density"],
            "PHCP Area Per Sprinkler": got["area"],
            "PHCP Authority": got["authority"],
            "PHCP Method": got["method"],
            "PHCP Velocity Pressure": got["vpress"].strip().upper() in ("YES", "ON", "TRUE", "1"),
            # Blank is none: 0 is not written as an option, so the engine's
            # own default (no hose allowance, 6 m/s) applies.
            "PHCP Hose Allowance": _number(got["hose"], "hose allowance") or 0,
            "PHCP Velocity Limit": _number(got["vlim"], "velocity limit") or 0,
            "PHCP Join Tolerance": _number(got["tol"], "join tolerance") or 5,
            "PHCP Sizing Goal": got["goal"],
            "PHCP Sizing Margin": got["margin"],
            "PHCP Design Area": got["darea"],
        })
    _guard(go)


def fitting_map():
    def go():
        doc, _uidoc = host._doc()
        if not _need_parameters(doc):
            return
        current = host.read_project(doc).fitting_map
        got = ask_form("PHCP FITTING MAP", [(
            "map",
            "ONE RULE A LINE: FAMILY TEXT, THEN THE CODE.  THESE WIN OVER THE BUILT-IN RULES (ELBOW, TEE, GATE, CHECK, BUTTERFLY).",
            current, True)])
        if not got:
            return
        parse_rules(got["map"])
        host.set_project(doc, {"PHCP Fitting Map": got["map"]})
        tell("Fitting map saved.")
    _guard(go)


# ---------------------------------------------------------------- markup
def _ids_or_tell(uidoc):
    ids = host.selection_ids(uidoc)
    if not ids:
        tell("Select the elements first.")
        return None
    return ids


def supply():
    def go():
        doc, uidoc = host._doc()
        if not _need_parameters(doc):
            return
        ids = _ids_or_tell(uidoc)
        if not ids or len(ids) != 1:
            if ids:
                tell("Select one element to be the supply.")
            return
        on_pipe = host.element_is_pipe(doc, ids[0])
        got = ask_form("PHCP SUPPLY", [
            ("id", "SUPPLY ID", "SUP1", False),
            ("end", "PIPE END A OR B. A IS THE START OF THE PIPE. BLANK WHEN THE ELEMENT ITSELF IS THE SUPPLY.",
             "A" if on_pipe else "", False),
            ("elev", "ELEVATION, M. BLANK USES THE MODEL.", "", False),
            ("static", "STATIC PRESSURE, KPA", "", False),
            ("curve", "CURVE, OPTIONAL: FLOW PRESSURE, FLOW PRESSURE. L/MIN AND KPA.", "", False),
        ])
        if not got:
            return
        if not got["static"]:
            tell("A supply needs its static pressure.")
            return
        if got["curve"]:
            parse_curve(got["curve"])
        if got["id"]:
            if on_pipe:
                values_text = {"PHCP Supply ID": got["id"], "PHCP Role": "WATER"}
            else:
                values_text = {"PHCP ID": got["id"], "PHCP Role": "WATER"}
        else:
            values_text = {"PHCP Role": "WATER"}
        if got["curve"]:
            values_text["PHCP Curve"] = got["curve"]
        if on_pipe and got["end"]:
            end = got["end"].strip().upper()
            if end not in ("A", "B"):
                tell("The pipe end is A or B.")
                return
            values_text["PHCP Supply End"] = end
        host.set_texts(doc, ids, values_text)
        numbers = {"PHCP Static": float(got["static"])}
        if got["elev"]:
            numbers["PHCP Elevation"] = float(got["elev"])
        host.set_numbers(doc, ids, numbers)
        tell("Supply %s set." % (got["id"] or ""))
    _guard(go)


def area():
    def go():
        doc, uidoc = host._doc()
        if not _need_parameters(doc):
            return
        ids = _ids_or_tell(uidoc)
        if not ids:
            return
        got = ask_form("PHCP AREA", [(
            "name",
            "DESIGN AREA NAME. OUTLETS WITH THE SAME NAME FLOW TOGETHER. BLANK CLEARS IT.",
            "", False)])
        if got is None:
            return
        host.set_texts(doc, ids, {"PHCP Area": got["name"]})
        tell("Area %s on %d elements." % (got["name"] or "(cleared)", len(ids)))
    _guard(go)


def pipe_markup():
    def go():
        doc, uidoc = host._doc()
        if not _need_parameters(doc):
            return
        ids = _ids_or_tell(uidoc)
        if not ids:
            return
        got = ask_form("PHCP PIPES", [
            ("type", "PIPE TYPE, SUCH AS ASAM. BLANK LEAVES IT.", "", False),
            ("dn", "DN, MM. 0 ASKS PHCP TO SIZE THE PIPE. BLANK LEAVES IT.", "", False),
            ("c", "C, OR ROUGHNESS IN MM UNDER DW. BLANK LEAVES IT.", "", False),
            ("fit", "FITTINGS, SUCH AS 2E T GV. BLANK LEAVES THEM. NONE CLEARS THEM.", "", False),
        ])
        if not got:
            return
        texts = {}
        if got["type"]:
            texts["PHCP Pipe Type"] = got["type"]
        if got["fit"].upper() == "NONE":
            texts["PHCP Fittings"] = None
        elif got["fit"]:
            texts["PHCP Fittings"] = got["fit"]
        if texts:
            host.set_texts(doc, ids, texts)
        numbers = {}
        if got["dn"]:
            numbers["PHCP DN"] = float(got["dn"])
        if got["c"]:
            numbers["PHCP C"] = float(got["c"])
        if numbers:
            host.set_numbers(doc, ids, numbers)
        tell("Pipe data set on %d elements." % len(ids))
    _guard(go)


def override():
    def go():
        doc, uidoc = host._doc()
        if not _need_parameters(doc):
            return
        ids = _ids_or_tell(uidoc)
        if not ids:
            return
        got = ask_form("PHCP OVERRIDE", [
            ("eqv", "EQUIVALENT LENGTH TO ADD, M. BLANK LEAVES IT. 0 CLEARS IT.", "", False),
            ("loss", "FIXED PRESSURE LOSS, KPA. BLANK LEAVES IT. 0 CLEARS IT.", "", False),
        ])
        if not got:
            return
        numbers = {}
        if got["eqv"] != "":
            numbers["PHCP Equivalent Length"] = float(got["eqv"])
        if got["loss"] != "":
            numbers["PHCP Pressure Loss"] = float(got["loss"])
        if not numbers:
            tell("Nothing to change.")
            return
        host.set_numbers(doc, ids, numbers)
        tell("Override set on %d elements." % len(ids))
    _guard(go)


def info():
    def go():
        doc, uidoc = host._doc()
        tell(host.describe(doc, uidoc))
    _guard(go)


# ---------------------------------------------------------------- calculate
def check_network():
    def go():
        prepared = _prepare(need_ok=False)
        if not prepared:
            return
        _doc, uidoc, walked = prepared
        _show(walked)
        if walked.errors:
            host.select_ids(uidoc, _error_ids(walked))
    _guard(go)


def export_model():
    def go():
        prepared = _prepare(need_ok=True)
        if not prepared:
            return
        doc, _uidoc, walked = prepared
        _show(walked)
        default = (doc.Title or "model") + ".phc"
        path = save_phc(default)
        if not path:
            return
        text = write_phc(walked)
        with open(path, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(text if text.endswith("\n") else text + "\n")
        tell("Exported %s" % path)
    _guard(go)


def calculate():
    def go():
        prepared = _prepare(need_ok=True)
        if not prepared:
            return
        doc, _uidoc, walked = prepared
        text = write_phc(walked)
        phc_path, pdf_path = _paths(doc)
        with open(phc_path, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(text if text.endswith("\n") else text + "\n")
        result = _solve(text, pdf_path)
        if result is None:
            return
        summary = summary_text(result.data)
        if result.code == 2:
            tell(summary)
            return
        if result.code != 0:
            tell("DID NOT CONVERGE. The results were not written back.\n\n" + summary)
            return
        host.apply_values(doc, element_results(result.data, host.id_map(walked)))
        tell(summary + "\n\n%s\n%s" % (phc_path, pdf_path))
    _guard(go)


def suggest():
    def go():
        prepared = _prepare(need_ok=True)
        if not prepared:
            return
        doc, uidoc, walked = prepared
        choice = ask_choice(
            "PHCP SUGGEST",
            "Which pipes should PHCP size? The modelled size is not changed.",
            ["OVER THE VELOCITY LIMIT", "SELECTED PIPES", "EVERY PIPE"])
        if not choice:
            return
        text = write_phc(walked)
        limit = walked.project.velocity_limit or DEFAULT_VELOCITY_LIMIT
        if choice == "OVER THE VELOCITY LIMIT":
            current = _solve(text)
            if current is None:
                return
            if current.code != 0:
                tell(summary_text(current.data))
                return
            host.apply_values(doc, element_results(current.data, host.id_map(walked)))
            ids = pipes_over_velocity(current.data, limit)
        elif choice == "SELECTED PIPES":
            chosen = set(host.selection_ids(uidoc))
            ids = [p.pid for p in walked.pipes if p.revit_id in chosen and not p.omit]
        else:
            ids = [p.pid for p in walked.pipes if not p.omit]
        if not ids:
            tell("No pipes to size.")
            return
        was = {p.pid: p.dn for p in walked.pipes}
        sized = _solve(zero_pipe_sizes(text, ids))
        if sized is None:
            return
        if sized.code != 0:
            tell(summary_text(sized.data))
            return
        rows = suggestions(sized.data, was)
        if not rows:
            tell("PHCP did not change a size.\n\n" + summary_text(sized.data))
            return
        writes = {}
        lines = []
        id_of = host.id_map(walked)
        for row in rows:
            rid = id_of.get(row["id"])
            if rid:
                writes[rid] = {"PHCP Suggested DN": row["dn"]}
            lines.append("%s  %s -> %s" % (
                row["id"],
                "-" if row["was"] is None else ("%g" % row["was"]),
                row["dn"]))
        host.apply_values(doc, writes)
        tell("SUGGESTED SIZES. The model was not changed.\n\n" + "\n".join(lines))
    _guard(go)


def _colour(mode):
    prepared = _prepare(need_ok=False)
    if not prepared:
        return
    doc, uidoc, walked = prepared
    if not walked.ok:
        _show(walked)
        host.select_ids(uidoc, _error_ids(walked))
        return
    speeds, flows, outlets, pipes = host.read_result_numbers(doc, walked)
    limit = walked.project.velocity_limit or DEFAULT_VELOCITY_LIMIT
    if mode == "velocity":
        if not speeds:
            tell("Calculate first. There is no velocity on the pipes.")
            return
        colours, legend = colour_velocity(speeds, limit)
    elif mode == "flow":
        if not flows:
            tell("Calculate first. There is no flow on the pipes.")
            return
        colours, legend = colour_flow(flows)
    else:
        if not outlets:
            tell("Calculate first. There is no pass or fail on the outlets.")
            return
        colours, legend = colour_ability(outlets, pipes)
    view = uidoc.ActiveView
    host.colour_elements(doc, view, colours, legend)
    tell("Coloured %d elements in this view.\n\n%s" % (len(colours), _legend(legend)))


def colour_by_velocity():
    _guard(lambda: _colour("velocity"))


def colour_by_flow():
    _guard(lambda: _colour("flow"))


def colour_by_ability():
    _guard(lambda: _colour("ability"))


def tag_nodes():
    def go():
        prepared = _prepare(need_ok=False)
        if not prepared:
            return
        doc, uidoc, walked = prepared
        if walked.errors:
            _show(walked)
            host.select_ids(uidoc, _error_ids(walked))
            return
        placed = host.tag_nodes(doc, uidoc.ActiveView, walked.nodes)
        tell("Tagged %d nodes. Running this again replaces the tags." % placed)
    _guard(go)


def clear_display():
    def go():
        doc, uidoc = host._doc()
        choice = ask_choice("PHCP CLEAR", "Clear what?", [
            "COLOUR AND TAGS", "RESULTS", "COLOUR, TAGS AND RESULTS"])
        if not choice:
            return
        view = uidoc.ActiveView
        if choice != "RESULTS":
            host.clear_colours(doc, view)
            host.clear_tags(doc, view)
        if choice != "COLOUR AND TAGS":
            host.clear_result_values(doc)
        tell("Cleared.")
    _guard(go)
