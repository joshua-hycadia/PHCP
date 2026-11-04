# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
# Walk a network and write it as a .phc model.
#
# Revit is not imported here.  The host hands over pipes, fittings, outlets
# and supplies as plain objects, with the connector bonds Revit already
# knows and the point of each end in millimetres.  The walk decides which
# ends are the same node, within the join tolerance, and writes the model
# the engine reads.  The same walk runs in the tests with no Revit.
#
# Keys.  A pipe's ends are "<pipe key>:A" and "<pipe key>:B" (A is the curve
# start, and positive flow in the results runs A to B).  A fitting's
# connectors are "<fitting key>:0", ":1", ...  An outlet's key and a
# supply's key are their own participant keys.  Bonds are pairs of those.

import math
import re

from phcp.fittings import (
    format_fittings, map_fitting, parse_fitting_string, parse_rules,
)
from phcp.parameters import DEFAULT_DROP_TYPE, DEFAULT_TOLERANCE_MM, DEFAULT_VELOCITY_LIMIT

# A gap this many times the tolerance, and at least this far, is reported as
# a near miss: close enough to be a join the designer missed, not so far that
# a pipe on the floor below is mentioned.
_NEAR_FACTOR = 10.0
_NEAR_FLOOR_MM = 50.0

# Display order for fitting codes that land on the same pipe.  Anything else
# follows, alphabetically, so two walks write the same string.
_FIT_ORDER = ["E", "EL", "EF", "E45", "E15", "E45M1", "E45M2", "E60M1", "E60M2",
              "E30M1", "E30M2", "E15M1", "EM1", "EM2", "EM3", "T", "TR"]


class ModelError(Exception):
    """The network cannot be written.  The messages are the walk's errors."""

    def __init__(self, messages):
        self.messages = list(messages)
        super(ModelError, self).__init__("\n".join(self.messages))


class Pt(object):
    """A point in millimetres, project coordinates."""

    def __init__(self, x, y, z):
        self.x = float(x)
        self.y = float(y)
        self.z = float(z)

    def dist(self, other):
        return math.sqrt((self.x - other.x) ** 2 + (self.y - other.y) ** 2
                          + (self.z - other.z) ** 2)

    def dist_xy(self, other):
        return math.sqrt((self.x - other.x) ** 2 + (self.y - other.y) ** 2)


class Issue(object):
    def __init__(self, severity, message, revit_ids=None):
        self.severity = severity
        self.message = message
        self.revit_ids = [i for i in (revit_ids or []) if i]


class Pipe(object):
    """One Revit pipe.

    a and b are the curve ends in mm.  length_m is the curve length the host
    measured; it already includes slope, so the walk does not add the change
    in height again.  length_override_m is a riser the designer drew short.
    dn None means "snap the diameter"; dn 0 means PHCP sizes the pipe.
    """

    def __init__(self, key, a, b, length_m, revit_id=None, pid=None, ptype=None,
                 dn=None, diameter_mm=None, c=None, fit_override=None, eqv_m=None,
                 loss_kpa=None, length_override_m=None, system=None,
                 device=None, device_data=None, duty_text=None):
        self.key = key
        self.revit_id = revit_id
        self.pid = pid
        self.ptype = ptype
        self.dn = dn
        self.diameter_mm = diameter_mm
        self.c = c
        self.fit_override = fit_override
        self.eqv_m = eqv_m
        self.loss_kpa = loss_kpa
        # One device in the pipe, at its start: a booster, a loss, a plate or
        # a ratio valve.  The fixed pressure loss above is that device when
        # it does not vary with flow.  The two are not combined.
        self.device = (device or "").strip().upper() or None
        self.device_data = device_data
        self.duty_text = duty_text
        self.length_m = length_m
        self.length_override_m = length_override_m
        self.system = system
        self.a = a
        self.b = b
        self.assigned = False
        self.auto_fits = []          # (count, code), filled by the walk
        self.n1 = None
        self.n2 = None
        self.omit = False            # a disconnected stub the walk leaves out


class Fitting(object):
    """A family that sits between pipes.  connectors are its connector points,
    in a stable order.  code, if set, is used as given and the map is not asked.
    """

    def __init__(self, key, connectors, revit_id=None, family="", part="",
                 angle=None, code=None, xyz=None):
        self.key = key
        self.revit_id = revit_id
        self.family = family or ""
        self.part = part or ""
        self.angle = angle
        self.code = code
        self.connectors = list(connectors or [])
        self.xyz = xyz or (self.connectors[0] if self.connectors else Pt(0, 0, 0))


class Outlet(object):
    """A sprinkler, hydrant, hose reel or fixed flow.

    role is SPRINKLER, HYDRANT, HREEL or FIXEDFLOW.  elevation_m overrides the
    point's height.  A fixed flow uses set_flow; the others use k and one of
    min_flow and min_pressure.
    """

    def __init__(self, key, xyz, role, revit_id=None, oid=None, elevation_m=None,
                 k=None, min_flow=None, min_pressure=None, set_flow=None,
                 drop_dn=None, drop_type=None, area=None):
        self.key = key
        self.revit_id = revit_id
        self.xyz = xyz
        self.role = (role or "SPRINKLER").upper()
        self.oid = oid
        self.elevation_m = elevation_m
        self.k = k
        self.min_flow = min_flow
        self.min_pressure = min_pressure
        self.set_flow = set_flow
        self.drop_dn = drop_dn
        self.drop_type = drop_type
        self.area = area
        self.assigned = False
        self.node = None
        self.drop = False
        self.drop_fits = []          # (count, code) on a synthetic drop pipe


class Supply(object):
    """Where the water comes from.  curve is [(flow_lpm, pressure_kpa), ...]."""

    def __init__(self, key, xyz, revit_id=None, sid=None, elevation_m=None,
                 static_kpa=None, curve=None):
        self.key = key
        self.revit_id = revit_id
        self.xyz = xyz
        self.sid = sid
        self.elevation_m = elevation_m
        self.static_kpa = static_kpa
        self.curve = list(curve or [])
        self.assigned = False
        self.node = None


class Project(object):
    """Cover sheet, method and the options the walk writes.  Strings are as
    the designer typed them; the writer cleans the characters .phc refuses.
    """

    def __init__(self):
        self.title = ""
        self.fields = {}             # JOB, COMPANY, ...
        self.method = "HW"
        self.velocity_pressure = False
        self.hose_allowance = None
        self.velocity_limit = None
        self.sizing_goal = None
        self.sizing_margin = None
        self.design_area = None
        self.fitting_map = ""
        self.tolerance_mm = DEFAULT_TOLERANCE_MM


class Network(object):
    def __init__(self):
        self.pipes = []
        self.fittings = []
        self.outlets = []
        self.supplies = []
        self.bonds = []              # (participant key, participant key)
        self.project = Project()
        self.sizes = None            # SizeTable or None
        self.model_name = ""
        self.when = ""


class Node(object):
    def __init__(self, root):
        self.root = root
        self.name = None
        self.elevation_m = 0.0
        self.x = 0.0
        self.y = 0.0
        self.z = 0.0
        self.pipe_ends = []         # (pipe, "A"|"B", Pt)
        self.fittings = []
        self.outlets = []
        self.supplies = []
        self.revit_ids = []
        self.capped = False
        self.drop_outlets = []       # outlets pulled off onto their own node


class Walk(object):
    """What the walk decided, whether or not it can be written."""

    def __init__(self):
        self.nodes = []
        self.pipes = []
        self.outlets = []
        self.supplies = []
        self.issues = []
        self.assignments = []        # (revit_id, parameter name, text)
        self.project = None
        self.tolerance_mm = DEFAULT_TOLERANCE_MM
        self.model_name = ""
        self.when = ""

    @property
    def errors(self):
        return [i for i in self.issues if i.severity == "error"]

    @property
    def warnings(self):
        return [i for i in self.issues if i.severity == "warning"]

    @property
    def ok(self):
        return not self.errors


# ---------------------------------------------------------------------------
# Small geometry and name helpers
# ---------------------------------------------------------------------------

def _segment_hit(p, a, b):
    """Distance from p to segment ab, and the position 0..1 along it."""
    abx, aby, abz = b.x - a.x, b.y - a.y, b.z - a.z
    ab2 = abx * abx + aby * aby + abz * abz
    if ab2 < 1e-9:
        return p.dist(a), 0.0
    t = ((p.x - a.x) * abx + (p.y - a.y) * aby + (p.z - a.z) * abz) / ab2
    t = 0.0 if t < 0.0 else (1.0 if t > 1.0 else t)
    q = Pt(a.x + t * abx, a.y + t * aby, a.z + t * abz)
    return p.dist(q), t


def clean_text(text):
    """Capitals, and none of the characters the .phc reader refuses or treats
    as a comment.  A project title is free text; it still has to be one line
    the reader will accept.
    """
    s = (text or "").replace("\r", " ").replace("\n", " ")
    s = s.replace("//", " ").replace("!", " ").replace("#", " ")
    s = re.sub(r"\s+", " ", s).strip().upper()
    return s


def clean_name(text):
    """An id: capitals, spaces as underscores, and only letters, digits,
    underscore and hyphen, which is what a .phc name may be.
    """
    s = clean_text(text).replace(" ", "_")
    s = re.sub(r"[^A-Z0-9_-]", "_", s)
    s = re.sub(r"_+", "_", s).strip("_")
    return s


def fmt(value, places=3):
    """A number the way the exporter writes one: fixed places, so a file
    diff is stable and a length of 6 m is 6.000, not 6.
    """
    return "%.*f" % (places, float(value))


def _num_token(value):
    """A DN or a C: an integer when it is a whole number, otherwise 3 places."""
    v = float(value)
    if abs(v - round(v)) < 1e-6:
        return str(int(round(v)))
    return fmt(v)


def _cmd(word):
    return word.ljust(10)


class _Union(object):
    def __init__(self):
        self.p = {}

    def add(self, key):
        self.p.setdefault(key, key)

    def find(self, key):
        self.add(key)
        while self.p[key] != key:
            self.p[key] = self.p[self.p[key]]
            key = self.p[key]
        return key

    def union(self, a, b):
        ra, rb = self.find(a), self.find(b)
        if ra != rb:
            # The older key wins, so the root does not depend on pair order.
            if rb < ra:
                ra, rb = rb, ra
            self.p[rb] = ra
        return self.find(a)

    def same(self, a, b):
        return a in self.p and b in self.p and self.find(a) == self.find(b)


def _ids(*objs):
    out = []
    for obj in objs:
        if obj is None:
            continue
        if isinstance(obj, (list, tuple)):
            out.extend(_ids(*obj))
        elif getattr(obj, "revit_id", None):
            out.append(obj.revit_id)
    return out


# ---------------------------------------------------------------------------
# The walk
# ---------------------------------------------------------------------------

def _participants(net, pipes, fittings, outlets, supplies):
    """Every point that can be a node, as (key, Pt, kind, owner)."""
    parts = []
    for pipe in pipes:
        parts.append((pipe.key + ":A", pipe.a, "pipe", pipe))
        parts.append((pipe.key + ":B", pipe.b, "pipe", pipe))
    for fit in fittings:
        pts = fit.connectors or [fit.xyz]
        for i, pt in enumerate(pts):
            parts.append(("%s:%d" % (fit.key, i), pt, "fitting", fit))
    for out in outlets:
        parts.append((out.key, out.xyz, "outlet", out))
    for sup in supplies:
        parts.append((sup.key, sup.xyz, "supply", sup))
    return parts


def _cell(pt, tol):
    return (int(math.floor(pt.x / tol)), int(math.floor(pt.y / tol)),
            int(math.floor(pt.z / tol)))


def walk(net, seeds=None):
    """Walk net and return a Walk.

    seeds, when given, are object keys (pipe, fitting, outlet or supply) the
    walk starts from.  Connector bonds are followed whatever the distance,
    and a point within the join tolerance is followed too, so a chain of
    short gaps is part of the same network.  Without seeds, every object is
    walked: a view or a whole model the host has already limited.
    """
    result = Walk()
    result.project = net.project
    result.model_name = net.model_name
    result.when = net.when
    tol = float(net.project.tolerance_mm or DEFAULT_TOLERANCE_MM)
    if tol <= 0:
        tol = DEFAULT_TOLERANCE_MM
    result.tolerance_mm = tol

    pipes, fittings, outlets, supplies = _scoped(
        net, seeds, tol, result)
    if not pipes and not outlets and not supplies:
        result.issues.append(Issue("error", "nothing to walk"))
        return result

    parts = _participants(net, pipes, fittings, outlets, supplies)
    by_key = {k: (pt, kind, owner) for k, pt, kind, owner in parts}
    groups = _Union()
    for key in by_key:
        groups.add(key)

    # A fitting's connectors are one node even when the body holds them
    # apart.  The pipes stop at the fitting faces; the bonds, plus this,
    # make those faces the same node.  The fitting's length is not added to
    # the pipes: the equivalent length stands in for the fitting.
    for fit in fittings:
        n = len(fit.connectors) or 1
        first = "%s:0" % fit.key
        for i in range(1, n):
            groups.union(first, "%s:%d" % (fit.key, i))

    bonded = set()
    for a, b in net.bonds:
        if a not in by_key or b not in by_key:
            # The other element was outside the scope.  The end is open as
            # far as this walk can see; the near-miss check covers a close one.
            continue
        bonded.add((a, b) if a < b else (b, a))
        pa, pb = by_key[a][0], by_key[b][0]
        gap = pa.dist(pb)
        groups.union(a, b)
        # An outlet centred under its pipe is a drop, not a connector left
        # open.  The height difference is the drop, and it is modelled as one.
        drop_link = (
            {by_key[a][1], by_key[b][1]} == {"outlet", "pipe"}
            and pa.dist_xy(pb) <= tol and abs(pa.z - pb.z) > tol)
        if gap > max(_NEAR_FACTOR * tol, _NEAR_FLOOR_MM) and not drop_link:
            result.issues.append(Issue(
                "warning",
                "connectors are joined but %.0f mm apart" % gap,
                _ids(by_key[a][2], by_key[b][2])))

    _join_on_tolerance(parts, groups, bonded, tol, result)
    _near_misses(parts, groups, tol, result)
    _midpipe(pipes, parts, tol, result)

    nodes_by_root = {}
    for key, pt, kind, owner in parts:
        if kind != "pipe":
            continue
        root = groups.find(key)
        node = nodes_by_root.get(root)
        if node is None:
            node = Node(root)
            nodes_by_root[root] = node
        which = "A" if key.endswith(":A") else "B"
        node.pipe_ends.append((owner, which, pt))

    for key, pt, kind, owner in parts:
        if kind == "pipe":
            continue
        root = groups.find(key)
        node = nodes_by_root.get(root)
        if node is None:
            continue
        if kind == "fitting":
            if owner not in node.fittings:
                node.fittings.append(owner)
        elif kind == "outlet":
            if owner not in node.outlets:
                node.outlets.append(owner)
                owner.node = node
        elif kind == "supply":
            if owner not in node.supplies:
                node.supplies.append(owner)
                owner.node = node

    _attach_drops(outlets, nodes_by_root, parts, groups, tol, result)
    _elevations(nodes_by_root.values())
    _mark_caps(nodes_by_root.values(), result)
    _check_ends(nodes_by_root.values(), pipes, result)

    _assign_ids(pipes, outlets, supplies, result)
    _name_nodes(pipes, nodes_by_root, result)
    _attribute_fittings(fittings, nodes_by_root, result)
    _check_values(pipes, outlets, supplies, net, result)
    result.nodes = list(nodes_by_root.values())
    result.pipes = pipes
    result.outlets = outlets
    result.supplies = supplies
    _components(pipes, result)
    result.nodes = sorted(result.nodes, key=lambda n: n.name or "")
    return result


def _scoped(net, seeds, tol, result):
    """The objects this walk includes.

    With no seeds, all of them.  With seeds, everything reached by a bond or
    by a point within tolerance, repeatedly, so the walk crosses a short gap
    and continues on the far side.
    """
    if not seeds:
        return list(net.pipes), list(net.fittings), list(net.outlets), list(net.supplies)

    owners = {}
    points = []  # (owner key, Pt, participant key)

    def add_owner(obj, pts, prefix=None):
        owners[obj.key] = obj
        for i, pt in enumerate(pts):
            pk = obj.key if prefix is None else "%s:%s" % (obj.key, prefix[i] if i < len(prefix) else i)
            points.append((obj.key, pt, pk))

    for pipe in net.pipes:
        add_owner(pipe, [pipe.a, pipe.b], ["A", "B"])
    for fit in net.fittings:
        pts = fit.connectors or [fit.xyz]
        add_owner(fit, pts, [str(i) for i in range(len(pts))])
    for out in net.outlets:
        add_owner(out, [out.xyz])
    for sup in net.supplies:
        add_owner(sup, [sup.xyz])

    part_owner = {pk: ok for ok, _pt, pk in points}
    neighbours = {}
    for a, b in net.bonds:
        if a in part_owner and b in part_owner:
            neighbours.setdefault(part_owner[a], set()).add(part_owner[b])
            neighbours.setdefault(part_owner[b], set()).add(part_owner[a])

    buckets = {}
    for ok, pt, _pk in points:
        buckets.setdefault(_cell(pt, tol), []).append((ok, pt))

    reached = set()
    queue = []
    for seed in seeds:
        if seed in owners and seed not in reached:
            reached.add(seed)
            queue.append(seed)
    unknown = [s for s in seeds if s not in owners]
    if unknown and not queue:
        result.issues.append(Issue(
            "error", "nothing selected is on the network"))

    while queue:
        ok = queue.pop()
        for other in neighbours.get(ok, ()):
            if other not in reached:
                reached.add(other)
                queue.append(other)
        for _ok, pt in [(o, p) for o, p, _ in points if o == ok]:
            c = _cell(pt, tol)
            for dx in (-1, 0, 1):
                for dy in (-1, 0, 1):
                    for dz in (-1, 0, 1):
                        for other, opt in buckets.get((c[0] + dx, c[1] + dy, c[2] + dz), []):
                            if other not in reached and pt.dist(opt) <= tol:
                                reached.add(other)
                                queue.append(other)

    def keep(objs):
        return [o for o in objs if o.key in reached]

    return keep(net.pipes), keep(net.fittings), keep(net.outlets), keep(net.supplies)


def _join_on_tolerance(parts, groups, bonded, tol, result):
    """Ends within the tolerance are one node, even with no connector.

    Revit sometimes leaves a gap of a few millimetres where a family was
    moved.  Joining on the tolerance picks that up.  It is a warning, not a
    silent join: the designer should close it.  Ends already bonded are the
    same node and are not warned about again.
    """
    buckets = {}
    for key, pt, _kind, _owner in parts:
        buckets.setdefault(_cell(pt, tol), []).append((key, pt))
    seen = set()
    for key, pt, kind, owner in parts:
        c = _cell(pt, tol)
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                for dz in (-1, 0, 1):
                    for other, opt in buckets.get((c[0] + dx, c[1] + dy, c[2] + dz), []):
                        if other <= key:
                            continue
                        pair = (key, other)
                        if pair in seen:
                            continue
                        gap = pt.dist(opt)
                        if gap > tol or gap == 0 and groups.same(key, other):
                            continue
                        if gap <= tol and not groups.same(key, other):
                            seen.add(pair)
                            groups.union(key, other)
                            if pair not in bonded and (other, key) not in bonded:
                                result.issues.append(Issue(
                                    "warning",
                                    "joined on tolerance, %.1f mm apart, with no connector" % gap,
                                    _ids(owner, _owner_of(parts, other))))


def _owner_of(parts, key):
    for k, _pt, _kind, owner in parts:
        if k == key:
            return owner
    return None


def _near_misses(parts, groups, tol, result):
    """A gap just outside the tolerance, and not already one node."""
    limit = max(_NEAR_FACTOR * tol, _NEAR_FLOOR_MM)
    # Compare each point with later points in neighbouring cells of `limit`.
    step = limit
    buckets = {}
    for key, pt, _kind, owner in parts:
        buckets.setdefault(_cell(pt, step), []).append((key, pt, owner))
    reported = set()
    for key, pt, _kind, owner in parts:
        c = _cell(pt, step)
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                for dz in (-1, 0, 1):
                    for other, opt, oowner in buckets.get((c[0] + dx, c[1] + dy, c[2] + dz), []):
                        if other <= key or groups.same(key, other):
                            continue
                        gap = pt.dist(opt)
                        if tol < gap <= limit:
                            pair = (owner.key, oowner.key)
                            if pair in reported or (pair[1], pair[0]) in reported:
                                continue
                            # Two ends of the same pipe are not a missed join.
                            if owner is oowner:
                                continue
                            reported.add(pair)
                            result.issues.append(Issue(
                                "warning",
                                "ends are %.0f mm apart, outside the %.0f mm join tolerance"
                                % (gap, tol),
                                _ids(owner, oowner)))


def _midpipe(pipes, parts, tol, result):
    """A pipe end that lands on another pipe's middle is not connected.

    Revit will not have split the pipe there.  It looks joined and is not.
    The walk refuses it rather than inventing a node the model does not have.
    """
    ends = [(pt, owner) for _k, pt, kind, owner in parts if kind == "pipe"]
    reported = set()
    for pt, owner in ends:
        for pipe in pipes:
            if pipe is owner:
                continue
            if pt.dist(pipe.a) <= tol or pt.dist(pipe.b) <= tol:
                continue
            dist, _t = _segment_hit(pt, pipe.a, pipe.b)
            if dist <= tol and pipe.a.dist(pipe.b) > 2 * tol:
                pair = (id(owner), id(pipe))
                if pair in reported:
                    continue
                reported.add(pair)
                result.issues.append(Issue(
                    "error",
                    "a pipe end meets another pipe mid-length; split the pipe at the branch",
                    _ids(owner, pipe)))


def _attach_drops(outlets, nodes_by_root, parts, groups, tol, result):
    """An outlet below a pipe end, at the same plan point, is a drop.

    A connector bond already put it on the node; a plan match with a
    different height did not, because two levels must not be joined.  Either
    way the outlet becomes its own node and a drop pipe is added later.
    """
    pipe_points = [(key, pt, owner) for key, pt, kind, owner in parts if kind == "pipe"]

    for out in outlets:
        if out.node is not None:
            node_z = _pipe_z(out.node)
            if node_z is None:
                continue
            elev = out.elevation_m if out.elevation_m is not None else out.xyz.z / 1000.0
            if abs(elev - node_z) * 1000.0 > tol:
                out.node.outlets.remove(out)
                out.node.drop_outlets.append(out)
                out.drop = True
                out.node = None
            continue
        # Not on a node.  A plan match to one pipe end is a drop.
        matches = []
        for key, pt, owner in pipe_points:
            if out.xyz.dist_xy(pt) <= tol and abs(out.xyz.z - pt.z) > tol:
                root = groups.find(key)
                node = nodes_by_root.get(root)
                if node is not None and node not in matches:
                    matches.append(node)
        if len(matches) == 1:
            matches[0].drop_outlets.append(out)
            out.drop = True
        elif len(matches) > 1:
            result.issues.append(Issue(
                "error",
                "outlet is in plan of more than one pipe end",
                _ids(out)))
        else:
            result.issues.append(Issue(
                "error",
                "outlet is not on a pipe",
                _ids(out)))


def _pipe_z(node):
    if not node.pipe_ends:
        return None
    return sum(pt.z for _p, _w, pt in node.pipe_ends) / len(node.pipe_ends) / 1000.0


def _elevations(nodes):
    """Node elevation from the pipe ends, then a supply's override.

    Outlets do not move the node: a head with its own elevation is a drop,
    and one without sits at the pipe.
    """
    for node in nodes:
        zs = [pt.z for _p, _w, pt in node.pipe_ends]
        xs = [pt.x for _p, _w, pt in node.pipe_ends]
        ys = [pt.y for _p, _w, pt in node.pipe_ends]
        if not zs:
            continue
        node.z = sum(zs) / len(zs)
        node.x = sum(xs) / len(xs)
        node.y = sum(ys) / len(ys)
        node.elevation_m = node.z / 1000.0
        for sup in node.supplies:
            if sup.elevation_m is not None:
                node.elevation_m = float(sup.elevation_m)
                break


def _mark_caps(nodes, result):
    for node in nodes:
        for fit in node.fittings:
            part = (fit.part or "").lower()
            name = (fit.family or "").lower()
            if part in ("cap", "endcap") or "cap" in name:
                node.capped = True


def _check_ends(nodes, pipes, result):
    for node in nodes:
        ends = node.pipe_ends
        # One pipe, both ends here, is a loop with no node between.
        n_pipes = len(set(p for p, _w, _pt in ends))
        n_out = len(node.outlets)
        n_sup = len(node.supplies)
        if n_out > 1:
            result.issues.append(Issue(
                "error",
                "two outlets on the same node; give one of them its own elevation (a drop)",
                _ids(node.outlets)))
        if n_sup > 1:
            result.issues.append(Issue(
                "error", "two supplies on the same node", _ids(node.supplies)))
        if n_out and n_sup:
            result.issues.append(Issue(
                "error",
                "a supply and an outlet on the same node",
                _ids(node.outlets + node.supplies)))
        if n_pipes == 1 and not n_out and not n_sup and not node.drop_outlets:
            pipe = ends[0][0]
            if node.capped:
                result.issues.append(Issue(
                    "warning",
                    "dead end with a cap and no outlet",
                    _ids(pipe, node.fittings)))
            else:
                result.issues.append(Issue(
                    "error",
                    "open end",
                    _ids(pipe)))


def _assign_ids(pipes, outlets, supplies, result):
    """Ids the designer set are kept.  The rest are filled in, in key order,
    so a new pipe is P7 rather than a number that moves every export.

    What was filled in is returned as assignments, for the host to store on
    the element.  The next walk then reads it back and the name stays.
    """
    used = set()

    def claim(name):
        name = clean_name(name)
        if not name or name in used:
            return None
        used.add(name)
        return name

    for pipe in pipes:
        if pipe.pid:
            got = claim(pipe.pid)
            if got is None:
                result.issues.append(Issue(
                    "error", "pipe id '%s' is used more than once" % pipe.pid,
                    _ids(pipe)))
            else:
                pipe.pid = got
    for out in outlets:
        if out.oid:
            got = claim(out.oid)
            if got is None:
                result.issues.append(Issue(
                    "error", "outlet id '%s' is used more than once" % out.oid,
                    _ids(out)))
            else:
                out.oid = got
    for sup in supplies:
        if sup.sid:
            got = claim(sup.sid)
            if got is None:
                result.issues.append(Issue(
                    "error", "supply id '%s' is used more than once" % sup.sid,
                    _ids(sup)))
            else:
                sup.sid = got

    def mint(prefix, obj, attr, param):
        n = 1
        while "%s%d" % (prefix, n) in used:
            n += 1
        name = "%s%d" % (prefix, n)
        used.add(name)
        setattr(obj, attr, name)
        obj.assigned = True
        if obj.revit_id:
            result.assignments.append((obj.revit_id, param, name))

    for pipe in sorted(pipes, key=lambda p: p.key):
        if not pipe.pid:
            mint("P", pipe, "pid", "PHCP ID")
    prefix = {"SPRINKLER": "S", "HYDRANT": "H", "HREEL": "R", "FIXEDFLOW": "F"}
    for out in sorted(outlets, key=lambda o: o.key):
        if not out.oid:
            mint(prefix.get(out.role, "S"), out, "oid", "PHCP ID")
    for sup in sorted(supplies, key=lambda s: s.key):
        if not sup.sid:
            param = "PHCP Supply ID" if str(sup.key).endswith(":SUP") else "PHCP ID"
            mint("SUP", sup, "sid", param)


def _name_nodes(pipes, nodes_by_root, result):
    """Node names follow pipe order and can change between exports.

    A supply names its node.  An outlet that sits on the pipe, rather than
    on a drop, names its node.  Everything else is N1, N2, ... in the order
    the pipes are written, which is by id.
    """
    order = []
    seen = set()
    for pipe in sorted(pipes, key=lambda p: p.pid or p.key):
        for which in ("A", "B"):
            for node in nodes_by_root.values():
                if any(p is pipe and w == which for p, w, _pt in node.pipe_ends):
                    if node not in seen:
                        seen.add(node)
                        order.append(node)
                    break
    for node in nodes_by_root.values():
        if node not in seen:
            order.append(node)

    # Every node is numbered in the order the pipes are written, and a supply
    # or an outlet then takes that number over.  A plain node keeps its
    # number, so the first junction after a supply that was node 1 is N2,
    # not N1.  The results then read the same way from one export to the next
    # when the pipes have not been renumbered.  The numbers themselves can
    # still change when a pipe is added earlier in the order.
    used = set()
    for index, node in enumerate(order, 1):
        if node.supplies:
            name = node.supplies[0].sid
        elif len(node.outlets) == 1:
            name = node.outlets[0].oid
        else:
            name = "N%d" % index
        if not name or name in used:
            k = index
            while "N%d" % k in used:
                k += 1
            name = "N%d" % k
        used.add(name)
        node.name = name
        for pipe, which, _pt in node.pipe_ends:
            if which == "A":
                pipe.n1 = name
            else:
                pipe.n2 = name
        # The node name is stored on the element that is the node: a fitting,
        # an outlet or a supply.  A pipe has two ends, so it is not given one.
        # A drop outlet is its own node, named by its own id, not the branch.
        ids = _ids(node.fittings, node.outlets, node.supplies)
        node.revit_ids = list(dict.fromkeys(ids))
        for rid in node.revit_ids:
            result.assignments.append((rid, "PHCP Node", name))
    for node in nodes_by_root.values():
        for out in node.drop_outlets:
            if out.revit_id and out.oid:
                result.assignments.append((out.revit_id, "PHCP Node", out.oid))


def _attribute_fittings(fittings, nodes_by_root, result):
    """Put each family's code on a pipe.

    A tee's equivalent length is for the flow that turns, so it goes on the
    branch: the pipe that is not the through pair.  The through pair is the
    two pipes whose directions away from the node are most nearly opposite.
    A cross puts a tee on each of the other two.  An elbow or a valve is in
    series, so which of the two pipes carries it does not change the loss
    when the sizes match; it goes on the smaller pipe, and on the later id
    when the sizes match, which keeps the file stable.

    A pipe with a fitting override is left alone.  The override is what the
    designer counted, and adding the families on top would count them twice.
    """
    rules = []
    # Rules are parsed once, at check_values if the text is bad.  Here a bad
    # map is an error and no built-in rule is silently used instead.
    project_rules = None
    for node in nodes_by_root.values():
        pipes_here = []
        seen = set()
        for pipe, _w, _pt in node.pipe_ends:
            if pipe not in seen:
                seen.add(pipe)
                pipes_here.append(pipe)
        for fit in node.fittings:
            part = (fit.part or "").lower()
            if part in ("cap", "endcap") or "cap" in (fit.family or "").lower():
                continue
            types = [p.ptype for p in pipes_here]
            if project_rules is None:
                project_rules = True
            code = fit.code or map_fitting(fit.family, fit.part, fit.angle, _rules_of(result), types)
            if not code:
                if part in ("transition", "union", "flange"):
                    result.issues.append(Issue(
                        "warning",
                        "a %s is not given an equivalent length" % (part or "fitting"),
                        _ids(fit)))
                continue
            _place(code, part, fit, pipes_here, node, result)
        _fittings_on_drops(node, result)


def _rules_of(result):
    try:
        return parse_rules(result.project.fitting_map)
    except ValueError:
        return []


def _place(code, part, fit, pipes_here, node, result):
    if not pipes_here:
        return
    free = [p for p in pipes_here if not p.fit_override]
    if not free:
        result.issues.append(Issue(
            "warning",
            "fitting %s was not added; every pipe at the node has a fitting override" % code,
            _ids(fit, pipes_here)))
        return
    targets = []
    if code == "T" and (part == "cross" or len(free) >= 4):
        _through, branches = _through_and_branches(free, node)
        targets = branches or free[:1]
    elif code == "T" and len(free) >= 3:
        _through, branches = _through_and_branches(free, node)
        targets = branches[:1] or free[:1]
    elif code == "T" and len(free) < 3:
        # A drop off this node is the missing branch.  _fittings_on_drops
        # puts the tee on the drop.  With no drop, the tee is still counted,
        # on one pipe, and the walk says so.
        if node.drop_outlets:
            targets = []
        else:
            result.issues.append(Issue(
                "warning",
                "a tee has fewer than three pipes; the equivalent length was put on one of them",
                _ids(fit, free)))
            targets = [_smaller(free)]
    else:
        targets = [_smaller(free)]
    for pipe in targets:
        pipe.auto_fits.append((1, code))


def _fittings_on_drops(node, result):
    """A synthetic drop is the branch a tee turns into.

    The drop is not a pipe of the model yet, so the tee could not be given
    to it during the ordinary pass.  It is moved here.  An elbow at the end
    of a single pipe, with the head below it, is the turn down: that elbow
    goes on the drop instead of the pipe.  A drop with no family at the node
    is given a tee, which is the ordinary take-off off a range pipe.
    """
    drops = [o for o in node.drop_outlets if o.role != "FIXEDFLOW"]
    if not drops:
        return
    real = []
    for pipe, _w, _pt in node.pipe_ends:
        if pipe not in real:
            real.append(pipe)
    for fit in node.fittings:
        part = (fit.part or "").lower()
        code = fit.code or map_fitting(
            fit.family, fit.part, fit.angle, _rules_of(result), [p.ptype for p in real])
        if code == "T" and len(real) < 3:
            # The through pipes are here and the drop is the turn.  One tee
            # on the drop, not also on the range.
            for out in drops:
                out.drop_fits.append((1, "T"))
            _remove_fit(real, "T")
        elif code in ("E", "EL", "EF", "E45", "E15") and len(real) == 1:
            drops[0].drop_fits.append((1, code))
            _remove_fit(real, code)
    for out in drops:
        if not out.drop_fits:
            out.drop_fits.append((1, "T"))


def _remove_fit(pipes, code):
    for pipe in pipes:
        for i, (count, got) in enumerate(pipe.auto_fits):
            if got == code:
                if count > 1:
                    pipe.auto_fits[i] = (count - 1, code)
                else:
                    del pipe.auto_fits[i]
                return


def _dir_from(node, pipe):
    """Unit vector from the node into the pipe, or None if the pipe has no length."""
    end = None
    other = None
    for p, which, pt in node.pipe_ends:
        if p is pipe:
            end = pt
            other = pipe.b if which == "A" else pipe.a
            break
    if end is None or other is None:
        return None
    dx, dy, dz = other.x - end.x, other.y - end.y, other.z - end.z
    length = math.sqrt(dx * dx + dy * dy + dz * dz)
    if length < 1e-6:
        return None
    return (dx / length, dy / length, dz / length)


def _through_and_branches(pipes, node):
    """The most colinear opposite pair, and the pipes that are not in it."""
    best = None
    dirs = [(p, _dir_from(node, p)) for p in pipes]
    dirs = [(p, d) for p, d in dirs if d is not None]
    for i in range(len(dirs)):
        for j in range(i + 1, len(dirs)):
            a, b = dirs[i][1], dirs[j][1]
            dot = a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
            if best is None or dot < best[0]:
                best = (dot, dirs[i][0], dirs[j][0])
    if best is None:
        return [], list(pipes)
    through = {best[1], best[2]}
    branches = [p for p in pipes if p not in through]
    return list(through), branches


def _smaller(pipes):
    """The pipe that should carry a series fitting.

    The smaller pipe, because that is the size the equivalent length is for
    when the two differ.  When they do not, the later id, so a second export
    does not move the fitting onto the other pipe.
    """
    def dn_of(p):
        return p.dn if isinstance(p.dn, (int, float)) and p.dn else 1e9

    ranked = sorted(pipes, key=lambda p: (dn_of(p), p.pid or ""))
    smallest = dn_of(ranked[0])
    tied = [p for p in ranked if dn_of(p) == smallest]
    tied.sort(key=lambda p: p.pid or p.key)
    return tied[-1]


def _check_values(pipes, outlets, supplies, net, result):
    try:
        parse_rules(result.project.fitting_map)
    except ValueError as err:
        result.issues.append(Issue("error", "fitting map: %s" % err))

    method = (result.project.method or "HW").upper()
    if method not in ("HW", "DW"):
        result.issues.append(Issue("error", "method must be HW or DW"))

    for pipe in pipes:
        if not pipe.ptype:
            result.issues.append(Issue(
                "error", "pipe %s has no pipe type" % pipe.pid, _ids(pipe)))
        elif net.sizes is not None and not net.sizes.has_type(pipe.ptype):
            result.issues.append(Issue(
                "error",
                "pipe %s: %s is not a pipe type in the database" % (pipe.pid, pipe.ptype),
                _ids(pipe)))
        dn = pipe.dn
        if dn is None and pipe.diameter_mm is not None and pipe.ptype and net.sizes is not None:
            dn = net.sizes.match(pipe.ptype, pipe.diameter_mm)
            if dn is None:
                result.issues.append(Issue(
                    "error",
                    "pipe %s: diameter %.1f mm is not a size of %s; set PHCP DN"
                    % (pipe.pid, pipe.diameter_mm, pipe.ptype),
                    _ids(pipe)))
            else:
                pipe.dn = dn
        elif dn is None:
            result.issues.append(Issue(
                "error", "pipe %s has no size" % pipe.pid, _ids(pipe)))
        elif dn != 0 and net.sizes is not None and pipe.ptype and net.sizes.has_type(pipe.ptype):
            if int(round(dn)) not in net.sizes.dns(pipe.ptype):
                result.issues.append(Issue(
                    "error",
                    "pipe %s: DN %s is not a size of %s" % (pipe.pid, _num_token(dn), pipe.ptype),
                    _ids(pipe)))
        if pipe.fit_override:
            try:
                parse_fitting_string(pipe.fit_override)
            except ValueError as err:
                result.issues.append(Issue(
                    "error", "pipe %s: %s" % (pipe.pid, err), _ids(pipe)))
        if pipe.eqv_m is not None and pipe.eqv_m < 0:
            result.issues.append(Issue(
                "error", "pipe %s: equivalent length cannot be negative" % pipe.pid, _ids(pipe)))
        if pipe.loss_kpa is not None and pipe.loss_kpa < 0:
            result.issues.append(Issue(
                "error", "pipe %s: pressure loss cannot be negative" % pipe.pid, _ids(pipe)))
        if pipe.device and pipe.loss_kpa:
            result.issues.append(Issue(
                "error",
                "pipe %s has a pressure loss and a %s; a pipe holds one device"
                % (pipe.pid, pipe.device),
                _ids(pipe)))
        if pipe.device:
            try:
                parse_device(pipe.device, pipe.device_data)
            except ValueError as err:
                result.issues.append(Issue(
                    "error", "pipe %s: %s" % (pipe.pid, err), _ids(pipe)))
        if pipe.duty_text:
            if pipe.device != "BP":
                result.issues.append(Issue(
                    "error",
                    "pipe %s: a pump duty belongs on a booster" % pipe.pid,
                    _ids(pipe)))
            else:
                try:
                    parse_duty(pipe.duty_text)
                except ValueError as err:
                    result.issues.append(Issue(
                        "error", "pipe %s: %s" % (pipe.pid, err), _ids(pipe)))
        length = _length_of(pipe)
        if length is None or length < 0.0005:
            result.issues.append(Issue(
                "error", "pipe %s has no length" % pipe.pid, _ids(pipe)))
        if pipe.n1 is None or pipe.n2 is None:
            result.issues.append(Issue(
                "error", "pipe %s is not connected at both ends" % pipe.pid, _ids(pipe)))
        elif pipe.n1 == pipe.n2:
            result.issues.append(Issue(
                "error", "pipe %s starts and ends at the same node" % pipe.pid, _ids(pipe)))

    for out in outlets:
        if out.role not in ("SPRINKLER", "HYDRANT", "HREEL", "FIXEDFLOW"):
            result.issues.append(Issue(
                "error", "outlet %s: role %s is not known" % (out.oid, out.role), _ids(out)))
        if out.role == "FIXEDFLOW":
            if not out.set_flow or out.set_flow <= 0:
                result.issues.append(Issue(
                    "error", "fixed flow %s has no flow" % out.oid, _ids(out)))
            continue
        k = out.k
        if (k is None or k == 0) and out.min_flow and out.min_pressure and out.min_pressure > 0:
            # Two of the three were given.  K = Q / sqrt(P), in L/min and kPa.
            k = out.min_flow / math.sqrt(out.min_pressure)
            out.k = k
        if k is None or k < 0:
            result.issues.append(Issue(
                "error",
                "outlet %s needs a K, or a minimum flow and a minimum pressure" % out.oid,
                _ids(out)))
        elif out.min_pressure is None and (out.min_flow is None or out.min_flow <= 0) and k > 0:
            result.issues.append(Issue(
                "error",
                "outlet %s needs a minimum pressure or a minimum flow" % out.oid,
                _ids(out)))
        if out.drop and (out.drop_dn is None):
            out.drop_dn = 25
        if out.drop and not out.drop_type:
            out.drop_type = DEFAULT_DROP_TYPE

    for sup in supplies:
        if sup.node is None:
            result.issues.append(Issue(
                "error", "supply %s is not on a pipe" % sup.sid, _ids(sup)))
        if sup.static_kpa is None:
            result.issues.append(Issue(
                "error", "supply %s has no static pressure" % sup.sid, _ids(sup)))
        elif sup.static_kpa < 0:
            result.issues.append(Issue(
                "error", "supply %s: static pressure cannot be negative" % sup.sid, _ids(sup)))
        for q, p in sup.curve:
            if q < 0 or p < 0:
                result.issues.append(Issue(
                    "error", "supply %s: a curve point cannot be negative" % sup.sid, _ids(sup)))
                break

    goal = (result.project.sizing_goal or "").upper()
    if goal and goal not in ("SMALLEST", "VOLUME"):
        result.issues.append(Issue("error", "sizing goal must be SMALLEST or VOLUME"))
    margin = (result.project.sizing_margin or "").strip()
    if margin and not re.match(r"^\d+(\.\d+)?%?$", margin):
        result.issues.append(Issue(
            "error", "sizing margin must be a pressure or a percentage, such as 50 or 10%"))


def _length_of(pipe):
    if pipe.length_override_m is not None:
        return float(pipe.length_override_m)
    if pipe.length_m is not None:
        return float(pipe.length_m)
    return pipe.a.dist(pipe.b) / 1000.0


def _components(pipes, result):
    """A run of pipe with outlets and no supply cannot be solved."""
    by_name = {}
    for pipe in pipes:
        if pipe.n1:
            by_name.setdefault(pipe.n1, []).append(pipe)
        if pipe.n2:
            by_name.setdefault(pipe.n2, []).append(pipe)
    seen = set()
    for pipe in pipes:
        if pipe in seen or not pipe.n1:
            continue
        stack = [pipe]
        seen.add(pipe)
        comp = []
        while stack:
            cur = stack.pop()
            comp.append(cur)
            for end in (cur.n1, cur.n2):
                for other in by_name.get(end, []):
                    if other not in seen:
                        seen.add(other)
                        stack.append(other)
        names = set()
        for p in comp:
            names.add(p.n1)
            names.add(p.n2)
        has_supply = any(s.node and s.node.name in names for s in result.supplies)
        has_outlet = any(
            (o.node and o.node.name in names) or (o.drop and _drop_host(o, result) in names)
            for o in result.outlets)
        if has_outlet and not has_supply:
            result.issues.append(Issue(
                "error",
                "a part of the network has outlets and no supply",
                _ids(comp)))
        elif not has_supply and len(comp) != len(pipes):
            # Left out of the model, so one stub does not stop the rest
            # solving.  The elements are named in the warning.
            for p in comp:
                p.omit = True
            result.issues.append(Issue(
                "warning",
                "a part of the network is not connected to a supply and was left out",
                _ids(comp)))


def _drop_host(out, result):
    """The node name a drop leaves from: the pipe end the outlet was matched to.

    Stored on the outlet by _name_nodes' time via drop_outlets on that node.
    """
    for node in result.nodes:
        if out in node.drop_outlets:
            return node.name
    return None


# ---------------------------------------------------------------------------
# .phc
# ---------------------------------------------------------------------------

def write_phc(result):
    """The .phc text for a walk that has no errors."""
    if result.errors:
        raise ModelError([i.message for i in result.errors])
    project = result.project
    lines = []
    lines.append("// PHCP MODEL EXPORTED FROM REVIT BY PHCP.EXTENSION")
    if result.model_name:
        lines.append("// MODEL: %s" % clean_text(result.model_name))
    if result.when:
        lines.append("// EXPORTED: %s" % result.when)
    lines.append("// NODE NAMES FOLLOW PIPE ORDER AND MAY CHANGE BETWEEN EXPORTS.")
    lines.append("// PIPE AND OUTLET IDS ARE STORED ON THE ELEMENTS AND STAY THE SAME.")
    lines.append("// JOIN TOLERANCE %.0f MM." % result.tolerance_mm)
    lines.append("// PIPE LENGTHS ARE THE MODELLED LENGTHS, WITH FITTING EQUIVALENT")
    lines.append("// LENGTHS ADDED. THE FITTING BODY IS NOT ADDED AS WELL.")
    lines.append("")

    if project.title:
        lines.append(_cmd("TITLE") + clean_text(project.title))
    for key in ("JOB", "COMPANY", "DESIGNER", "HAZARD", "DENSITY",
                "AREA_PER_SPRINKLER", "AUTHORITY"):
        value = project.fields.get(key)
        if value:
            lines.append(_cmd("PROJECT") + key + " " + clean_text(value))
    for unit in ("LENGTH M", "ELEVATION M", "SIZE MM", "PRESSURE KPA",
                 "FLOW LPM", "KFACTOR LPM/KPA"):
        lines.append(_cmd("UNITS") + unit)
    lines.append(_cmd("METHOD") + (project.method or "HW").upper())
    if project.velocity_pressure:
        lines.append(_cmd("OPTION") + "VELOCITY_PRESSURE ON")
    if project.hose_allowance:
        lines.append(_cmd("OPTION") + "HOSE_ALLOWANCE " + _num_token(project.hose_allowance))
    if project.velocity_limit:
        lines.append(_cmd("OPTION") + "VEL_LIMIT " + _num_token(project.velocity_limit))
    if project.sizing_goal:
        lines.append(_cmd("OPTION") + "SIZING_GOAL " + project.sizing_goal.strip().upper())
    if project.sizing_margin:
        lines.append(_cmd("OPTION") + "SIZING_MARGIN " + project.sizing_margin.strip().upper())
    if project.design_area:
        lines.append(_cmd("OPTION") + "DESIGN_AREA " + clean_name(project.design_area))
    lines.append("")

    # Supplies, then plain nodes, then outlets.  A node a supply or an outlet
    # names is written once, as that.
    named = set()
    for sup in sorted(result.supplies, key=lambda s: s.sid or ""):
        node = sup.node
        if node is None:
            continue
        named.add(node.name)
        curve = ""
        for q, p in sup.curve:
            curve += " " + fmt(q) + " " + fmt(p)
        lines.append(_cmd("WATER") + "%s %s %s%s" % (
            sup.sid, fmt(node.elevation_m), fmt(sup.static_kpa), curve))

    drop_hosts = {}
    for node in result.nodes:
        for out in node.drop_outlets:
            drop_hosts[out] = node

    for node in sorted(result.nodes, key=lambda n: n.name or ""):
        if node.name in named:
            continue
        if node.outlets:
            continue
        lines.append(_cmd("NODE") + "%s %s" % (node.name, fmt(node.elevation_m)))

    areas = {}
    for out in sorted(result.outlets, key=lambda o: o.oid or ""):
        if out.role == "FIXEDFLOW":
            host = out.node or drop_hosts.get(out)
            if host is None:
                continue
            extra = (" " + fmt(out.min_pressure)) if out.min_pressure else ""
            lines.append(_cmd("FIXEDFLOW") + "%s %s %s%s" % (
                out.oid, host.name, fmt(out.set_flow), extra))
            continue
        if out.drop:
            host = drop_hosts.get(out)
            elev = out.elevation_m if out.elevation_m is not None else out.xyz.z / 1000.0
        else:
            host = out.node
            elev = host.elevation_m if host is not None else (
                out.elevation_m if out.elevation_m is not None else out.xyz.z / 1000.0)
        demand = _outlet_demand(out)
        lines.append(_cmd(out.role) + "%s %s %s %s" % (
            out.oid, fmt(elev), demand, _num_token(out.k)))
        if out.area:
            areas.setdefault(clean_name(out.area), []).append(out.oid)

    for name in sorted(areas):
        lines.append(_cmd("AREA") + name + " " + " ".join(areas[name]))
    lines.append("")

    use = None
    for pipe in sorted(result.pipes, key=lambda p: p.pid or ""):
        if pipe.omit:
            continue
        c = _num_token(pipe.c) if pipe.c not in (None, "") else ""
        use_line = _cmd("USE") + pipe.ptype + ((" " + c) if c else "")
        if use_line != use:
            lines.append(use_line)
            use = use_line
        fits = _pipe_fittings(pipe)
        lines.append(_cmd("PIPE") + "%s %s %s %s %s%s" % (
            pipe.pid, pipe.n1, pipe.n2, fmt(_length_of(pipe)),
            _num_token(pipe.dn if pipe.dn is not None else 0),
            (" " + fits) if fits else ""))

    for out, host in drop_hosts.items():
        if out.role == "FIXEDFLOW":
            continue
        elev = out.elevation_m if out.elevation_m is not None else out.xyz.z / 1000.0
        length = abs(elev - host.elevation_m)
        if length < 0.0005:
            length = 0.001
        dtype = out.drop_type or DEFAULT_DROP_TYPE
        use_line = _cmd("USE") + dtype
        if use_line != use:
            lines.append(use_line)
            use = use_line
        drop_fits = format_fittings(out.drop_fits)
        lines.append(_cmd("PIPE") + "%s_D %s %s %s %s%s" % (
            out.oid, host.name, out.oid, fmt(length),
            _num_token(out.drop_dn or 25),
            (" " + drop_fits) if drop_fits else ""))

    for pipe in sorted(result.pipes, key=lambda p: p.pid or ""):
        if pipe.eqv_m:
            lines.append(_cmd("EQV") + "%s %s" % (pipe.pid, fmt(pipe.eqv_m)))
    for pipe in sorted(result.pipes, key=lambda p: p.pid or ""):
        if pipe.omit or not pipe.loss_kpa:
            continue
        # One pair at flow 0 is a loss that does not vary with flow.
        lines.append(_cmd("BFP") + "%s 0 %s" % (pipe.pid, fmt(pipe.loss_kpa)))
    for pipe in sorted(result.pipes, key=lambda p: p.pid or ""):
        if pipe.omit or not pipe.device:
            continue
        tokens = parse_device(pipe.device, pipe.device_data)
        lines.append(_cmd(pipe.device) + pipe.pid + " " + " ".join(tokens))
    for pipe in sorted(result.pipes, key=lambda p: p.pid or ""):
        if pipe.omit or pipe.device != "BP" or not pipe.duty_text:
            continue
        flow, pressure = parse_duty(pipe.duty_text)
        lines.append(_cmd("PUMPDUTY") + "%s %s %s" % (pipe.pid, fmt(flow), fmt(pressure)))
    lines.append("")
    return "\n".join(lines)


def _outlet_demand(out):
    """The MINFLOW field: a minimum pressure is written as a negative number.

    When both a flow and a pressure were given, the one that governs is
    written: the flow, if it is more than K at that pressure, otherwise the
    pressure.  K is always written as well.
    """
    p, q, k = out.min_pressure, out.min_flow, out.k or 0
    if p and q and k and q > k * math.sqrt(p):
        return fmt(q)
    if p is not None:
        return "-" + fmt(p)
    return fmt(q)


def _pipe_fittings(pipe):
    # An override is the designer's list; a walk builds its own.  Either way
    # the written order is fixed, so two exports of the same pipe match.
    if pipe.fit_override:
        items = list(parse_fitting_string(pipe.fit_override))
    else:
        items = list(pipe.auto_fits)
    items.sort(key=lambda ic: (_FIT_ORDER.index(ic[1]) if ic[1] in _FIT_ORDER else 100, ic[1]))
    # Merge after the sort so two elbows from the two ends become 2E.
    return format_fittings(items)


def zero_pipe_sizes(text, pipe_ids):
    """A copy of a .phc model with the named pipes set to size 0.

    Size 0 asks the engine to size the pipe.  The file the designer exported
    is not changed; the caller writes this text to a temporary model.
    """
    want = {str(i).upper() for i in pipe_ids}
    out = []
    for line in text.splitlines():
        body = line.split("//", 1)[0]
        bits = body.split()
        if len(bits) >= 6 and bits[0].upper() == "PIPE" and bits[1].upper() in want:
            # PIPE NAME START END LENGTH SIZE [FITTINGS...]
            bits[5] = "0"
            comment = ""
            if "//" in line:
                comment = " " + line[line.index("//"):]
            line = _cmd("PIPE") + " ".join(bits[1:]) + comment
        out.append(line)
    text_out = "\n".join(out)
    if text.endswith("\n"):
        text_out += "\n"
    return text_out


_DEVICES = ("BP", "BFP", "PRV", "OPP", "OFD", "PRA")
_RATIO_RE = re.compile(r"^(\d+(?:\.\d+)?):(\d+(?:\.\d+)?)$")
_COPY_RE = re.compile(r"^([A-Za-z]+)(\d+)$")


def _float_tokens(text):
    nums = []
    for bit in (text or "").replace(",", " ").split():
        try:
            nums.append(float(bit))
        except ValueError:
            raise ValueError("'%s' is not a number" % bit)
    return nums


def _ratio_of(token):
    """A ratio as a number, and the token to write.

    3:1 is kept as 3:1.  A plain number is written like any other figure.
    """
    m = _RATIO_RE.match((token or "").strip())
    if m:
        den = float(m.group(2))
        if den <= 0:
            raise ValueError("a ratio needs a denominator more than 0")
        return float(m.group(1)) / den, m.group(1) + ":" + m.group(2)
    try:
        value = float(token)
    except (TypeError, ValueError):
        raise ValueError("'%s' is not a ratio" % token)
    return value, fmt(value)


def parse_duty(text):
    """'2000 600' to (flow, pressure).  Both have to be more than zero."""
    nums = _float_tokens(text)
    if len(nums) != 2 or nums[0] <= 0 or nums[1] <= 0:
        raise ValueError("a pump duty is a flow and a pressure, both more than 0")
    return nums


def parse_device(kind, data):
    """The figures of one device, as the tokens written after the pipe name.

    This checks that the line is the command the engine reads.  It does not
    decide whether the device is large enough for the pipe; the engine does.
    """
    kind = (kind or "").strip().upper()
    if kind not in _DEVICES:
        raise ValueError("%s is not a device" % (kind or "a blank device"))
    raw = (data or "").strip()
    if not raw:
        raise ValueError("a %s needs its figures" % kind)
    if kind == "PRA":
        bits = raw.replace(",", " ").split()
        ratio, token = _ratio_of(bits[0])
        if ratio <= 1:
            raise ValueError("a pressure ratio valve reduces pressure, so the ratio is more than 1")
        rest = _float_tokens(" ".join(bits[1:])) if len(bits) > 1 else []
        if len(rest) > 2:
            raise ValueError("a pressure ratio valve takes a ratio, a minimum inlet and a band")
        if rest and rest[0] < 0:
            raise ValueError("the minimum inlet cannot be negative")
        if len(rest) == 2 and rest[1] < 0:
            raise ValueError("the band cannot be negative")
        if len(rest) == 2 and rest[1] / 100.0 >= 1.0 / ratio:
            raise ValueError("the band is wider than the valve passes")
        return [token] + [fmt(n) for n in rest]
    nums = _float_tokens(raw)
    if kind == "BP":
        if len(nums) < 3 or len(nums) % 2 == 0:
            raise ValueError("a booster needs its churn pressure, then flow and pressure pairs")
        if any(n < 0 for n in nums):
            raise ValueError("a booster curve cannot be negative")
        return [fmt(n) for n in nums]
    if kind in ("BFP", "PRV"):
        if len(nums) < 2 or len(nums) % 2:
            raise ValueError("a loss is flow and loss, in pairs")
        if any(n < 0 for n in nums):
            raise ValueError("a loss cannot be negative")
        if len(nums) == 2:
            if nums[0] != 0:
                raise ValueError("one pair is a fixed loss, so its flow is 0")
            if nums[1] <= 0:
                raise ValueError("a fixed loss must be more than 0")
        return [fmt(n) for n in nums]
    if kind == "OPP":
        if not 1 <= len(nums) <= 2:
            raise ValueError("an orifice sized for a drop takes the drop, and a discharge coefficient")
        if nums[0] <= 0:
            raise ValueError("the drop must be more than 0")
    else:
        if not 1 <= len(nums) <= 2:
            raise ValueError("an orifice of a known bore takes the bore, and a discharge coefficient")
        if nums[0] <= 0:
            raise ValueError("the bore must be more than 0")
    if len(nums) == 2 and not (0 < nums[1] <= 1):
        raise ValueError("the discharge coefficient is more than 0 and not more than 1")
    return [fmt(n) for n in nums]


def renumber_copies(records, only_ids=None):
    """New names for elements that repeat a name.

    records are (revit id, name, parameter).  Pipe names, outlet names and
    supply names are one list, which is how the walk reads them.  The lowest
    Revit id keeps the name: a copy is given a higher id than the element it
    was copied from.  only_ids, when set, limits which copies are renamed;
    the element that keeps the name is never renamed.

    Returns [(revit id, parameter, new name), ...] in id order.
    """
    used = set()
    groups = {}
    for rid, name, param in records:
        name = clean_name(name or "")
        if not name:
            continue
        used.add(name)
        groups.setdefault(name, []).append((rid, param))
    wanted = None if only_ids is None else set(only_ids)
    changes = []
    for name, holders in groups.items():
        if len(holders) < 2:
            continue
        holders.sort(key=lambda hp: hp[0])
        match = _COPY_RE.match(name)
        prefix = match.group(1) if match else name
        for rid, param in holders[1:]:
            if wanted is not None and rid not in wanted:
                continue
            n = 1
            while "%s%d" % (prefix, n) in used:
                n += 1
            fresh = "%s%d" % (prefix, n)
            used.add(fresh)
            changes.append((rid, param, fresh))
    changes.sort(key=lambda row: (row[0], row[1]))
    return changes


def note_positions(nodes, pipes):
    """(x, y, z, text) in mm for the node names and the pipe names.

    A node note sits 200 mm in +X.  A pipe note sits 200 mm in +Y at the
    middle of the pipe, so the two are not drawn on top of each other.
    """
    notes = []
    for node in nodes:
        if node.name:
            notes.append((node.x + 200.0, node.y, node.z, node.name))
    for pipe in pipes:
        if pipe.omit or not pipe.pid:
            continue
        notes.append((
            (pipe.a.x + pipe.b.x) / 2.0,
            (pipe.a.y + pipe.b.y) / 2.0 + 200.0,
            (pipe.a.z + pipe.b.z) / 2.0,
            pipe.pid,
        ))
    return notes


def parse_curve(text):
    """'1500 700, 3000 400' to [(1500, 700), (3000, 400)]."""
    nums = re.findall(r"[+-]?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?", text or "")
    vals = [float(n) for n in nums]
    if len(vals) % 2:
        raise ValueError("a supply curve needs flow and pressure in pairs")
    return list(zip(vals[0::2], vals[1::2]))
