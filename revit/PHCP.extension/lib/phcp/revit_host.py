# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
# The Revit API, and nothing hydraulic.
#
# Readings go into the plain objects phcp.model walks.  Results come back as
# numbers in the engine's units (m, mm, kPa, L/min, m/s) and are converted
# into Revit's internal units on the way into a parameter.  The forks are the
# ones that actually moved between Revit 2022 and Revit 2027: ElementId became
# 64-bit in 2024, and parameter groups moved from an enum to ForgeTypeId.
# Units have been ForgeTypeId since before 2022, so one call covers the range.
#
# Imported by the tests.  The Revit assemblies are imported inside the
# functions, so loading this module does not need Revit.

import math
import os
import re

from phcp.model import Fitting, Network, Outlet, Pipe, Pt, Supply, parse_curve
from phcp.parameters import (
    BY_NAME, ELEMENT_PARAMS, PARAMS, PROJECT_FIELDS, RESULT_PARAMS,
)
from phcp.sizes import designations, find_database, load

# Marks PHCP leaves on a view (the elements it coloured) and on a text note
# (a node tag), so CLEAR removes those and nothing the designer placed.
_MARK_GUID = "b7e1c4a2-9f30-4d6e-8a11-0c33d633d6a1"


class RevitHostError(Exception):
    pass


def _db():
    from Autodesk.Revit import DB
    return DB


def _doc():
    """The document and the UI document of the active command."""
    try:
        from pyrevit import revit
        doc = revit.doc
        uidoc = revit.uidoc
    except Exception as err:
        raise RevitHostError("PHCP has to be run from a button inside Revit (%s)" % err)
    if doc is None:
        raise RevitHostError("No model is open.")
    return doc, uidoc


def element_int(element_id):
    """An element id as an int, on Revit 2022 (IntegerValue) and 2024+ (Value)."""
    try:
        return int(element_id.Value)
    except Exception:
        return int(element_id.IntegerValue)


def make_id(number):
    DB = _db()
    try:
        return DB.ElementId(int(number))
    except Exception:
        from System import Int64
        return DB.ElementId(Int64(int(number)))


def _to(value, unit):
    DB = _db()
    return DB.UnitUtils.ConvertFromInternalUnits(float(value), unit)


def _from(value, unit):
    DB = _db()
    return DB.UnitUtils.ConvertToInternalUnits(float(value), unit)


def _units():
    DB = _db()
    u = DB.UnitTypeId
    return u


def mm_of(feet):
    return _to(feet, _units().Millimeters)


def m_of(feet):
    return _to(feet, _units().Meters)


def kpa_of(internal):
    return _to(internal, _units().Kilopascals)


def lpm_of(internal):
    return _to(internal, _units().LitersPerMinute)


def mps_of(internal):
    u = _units()
    unit = getattr(u, "MetersPerSecond", None)
    if unit is None:
        return float(internal)
    return _to(internal, unit)


def _internal_of(kind, value):
    """An engine-unit value as the double a parameter of this kind stores."""
    u = _units()
    if kind == "length":
        return _from(value, u.Meters)
    if kind == "pressure":
        return _from(value, u.Kilopascals)
    if kind == "flow":
        return _from(value, u.LitersPerMinute)
    if kind == "velocity":
        unit = getattr(u, "MetersPerSecond", None)
        return float(value) if unit is None else _from(value, unit)
    return float(value)


def _engine_of(kind, value):
    u = _units()
    if kind == "length":
        return _to(value, u.Meters)
    if kind == "pressure":
        return _to(value, u.Kilopascals)
    if kind == "flow":
        return _to(value, u.LitersPerMinute)
    if kind == "velocity":
        return mps_of(value)
    return float(value)


def _param(el, name):
    found = el.LookupParameter(name)
    if found is None or not found.HasValue:
        return None
    return found


def read_text(el, name):
    found = _param(el, name)
    if found is None:
        return None
    DB = _db()
    if found.StorageType == DB.StorageType.String:
        return found.AsString()
    return None


def read_number(el, name, kind):
    """A PHCP parameter in engine units, or None when it is blank."""
    found = _param(el, name)
    if found is None:
        return None
    DB = _db()
    if found.StorageType == DB.StorageType.Integer:
        return float(found.AsInteger())
    if found.StorageType != DB.StorageType.Double:
        return None
    return _engine_of(kind, found.AsDouble())


def read_bool(el, name):
    found = _param(el, name)
    if found is None:
        return False
    DB = _db()
    if found.StorageType == DB.StorageType.Integer:
        return bool(found.AsInteger())
    return False


def _set(el, name, value):
    found = el.LookupParameter(name)
    if found is None or found.IsReadOnly:
        return False
    DB = _db()
    spec = BY_NAME.get(name)
    kind = spec.kind if spec else "text"
    if kind == "yesno" or found.StorageType == DB.StorageType.Integer:
        found.Set(1 if value else 0)
        return True
    if found.StorageType == DB.StorageType.String or kind == "text":
        found.Set("" if value is None else str(value))
        return True
    if value is None:
        return False
    found.Set(float(_internal_of(kind, value)))
    return True


def _transaction(doc, name):
    DB = _db()

    class _Txn(object):
        def __enter__(self):
            self.txn = DB.Transaction(doc, name)
            self.txn.Start()
            return self.txn

        def __exit__(self, exc_type, _exc, _tb):
            if exc_type is None:
                self.txn.Commit()
            else:
                self.txn.RollBack()
            return False

    return _Txn()


# ---------------------------------------------------------------- parameters
def _spec(kind):
    DB = _db()
    specs = DB.SpecTypeId
    table = {
        "text": specs.String,
        "number": specs.Number,
        "length": specs.Length,
        "pressure": getattr(specs, "PipingPressure", specs.Number),
        "flow": getattr(specs, "Flow", specs.Number),
        "yesno": specs.Boolean,
        "velocity": getattr(specs, "PipingVelocity", specs.Number),
    }
    return table[kind]


def _shared_file():
    base = os.environ.get("APPDATA") or os.path.join(os.path.expanduser("~"), ".config")
    folder = os.path.join(base, "PHCP")
    if not os.path.isdir(folder):
        os.makedirs(folder)
    path = os.path.join(folder, "PHCP-shared-parameters.txt")
    if not os.path.isfile(path):
        # Revit reads a shared-parameter file as UTF-16.  The definitions are
        # then added through the API, which keeps the GUIDs we set.
        header = (
            "# This is a Revit shared parameter file.\r\n"
            "# Do not edit manually.\r\n"
            "*META\tVERSION\tMINVERSION\r\n"
            "META\t2\t1\r\n"
            "*GROUP\tID\tNAME\r\n"
            "*PARAM\tGUID\tNAME\tDATATYPE\tDATACATEGORY\tGROUP\tVISIBLE\tDESCRIPTION\tUSERMODIFIABLE\r\n"
        )
        with open(path, "w", encoding="utf-16") as fh:
            fh.write(header)
    return path


def _category(doc, bic):
    DB = _db()
    try:
        return DB.Category.GetCategory(doc, bic)
    except Exception:
        return doc.Settings.Categories.get_Item(bic)


def _element_categories():
    DB = _db()
    bics = [
        DB.BuiltInCategory.OST_PipeCurves,
        DB.BuiltInCategory.OST_PipeFitting,
        DB.BuiltInCategory.OST_PipeAccessory,
        DB.BuiltInCategory.OST_Sprinklers,
        DB.BuiltInCategory.OST_MechanicalEquipment,
        DB.BuiltInCategory.OST_PlumbingFixtures,
    ]
    flex = getattr(DB.BuiltInCategory, "OST_FlexPipeCurves", None)
    if flex is not None:
        bics.append(flex)
    return bics


def _bind(doc, defn, bics):
    DB = _db()
    app = doc.Application
    cats = app.Create.NewCategorySet()
    for bic in bics:
        cat = _category(doc, bic)
        allows = True
        try:
            allows = bool(cat.AllowsBoundParameters)
        except Exception:
            allows = True
        if cat is not None and allows:
            cats.Insert(cat)
    if cats.IsEmpty:
        return False
    binding = app.Create.NewInstanceBinding(cats)
    bindings = doc.ParameterBindings
    group = None
    try:
        group = getattr(DB.GroupTypeId, "FireProtection", None) or DB.GroupTypeId.Mechanical
    except Exception:
        group = None
    try:
        if group is not None:
            if bindings.Contains(defn):
                return bool(bindings.ReInsert(defn, binding, group))
            return bool(bindings.Insert(defn, binding, group))
    except Exception:
        group = None
    pg = DB.BuiltInParameterGroup.PG_MECHANICAL
    if bindings.Contains(defn):
        return bool(bindings.ReInsert(defn, binding, pg))
    return bool(bindings.Insert(defn, binding, pg))


def ensure_parameters(doc):
    """Create the PHCP shared parameters and bind them.  Returns how many
    were newly bound.  Running it again does not make a second copy: the
    GUIDs are fixed, and a parameter that is already there is reused.
    """
    DB = _db()
    from System import Guid
    app = doc.Application
    path = _shared_file()
    previous = app.SharedParametersFilename
    try:
        app.SharedParametersFilename = path
        spfile = app.OpenSharedParameterFile()
    finally:
        # Put the user's own shared-parameter file back even if opening ours
        # failed.  Leaving it pointed at ours would surprise the next command.
        if previous != path:
            try:
                app.SharedParametersFilename = previous or ""
            except Exception:
                pass
    if spfile is None:
        raise RevitHostError("Revit could not open the PHCP shared parameter file at %s" % path)
    group = None
    for existing in spfile.Groups:
        if existing.Name == "PHCP":
            group = existing
    if group is None:
        group = spfile.Groups.Create("PHCP")
    have = {}
    for defn in group.Definitions:
        have[defn.Name] = defn
    made = []
    for param in PARAMS:
        defn = have.get(param.name)
        if defn is None:
            opt = DB.ExternalDefinitionCreationOptions(param.name, _spec(param.kind))
            opt.GUID = Guid(param.guid)
            opt.Description = param.description
            opt.UserModifiable = True
            defn = group.Definitions.Create(opt)
        made.append((param, defn))
    bound = 0
    with _transaction(doc, "PHCP parameters"):
        for param, defn in made:
            bics = (_element_categories() if param.scope == "element"
                    else [DB.BuiltInCategory.OST_ProjectInformation])
            if _bind(doc, defn, bics):
                bound += 1
    return bound


# ---------------------------------------------------------------- reading
def _family(el):
    symbol = getattr(el, "Symbol", None)
    if symbol is not None:
        try:
            return symbol.Family.Name
        except Exception:
            pass
    try:
        return el.Name or ""
    except Exception:
        return ""


def _part(el):
    mep = getattr(el, "MEPModel", None)
    if mep is None:
        return ""
    try:
        return str(mep.PartType)
    except Exception:
        return ""


def _angle_deg(el):
    found = el.LookupParameter("Angle")
    if found is None or not found.HasValue:
        return None
    try:
        value = float(found.AsDouble())
    except Exception:
        return None
    # An angle parameter is stored in radians.  A number parameter someone
    # named Angle may already be degrees; a value past a full circle is that.
    if abs(value) <= 2 * math.pi + 0.01:
        return value * 180.0 / math.pi
    return value


def _connectors(el):
    mgr = None
    try:
        mgr = el.ConnectorManager
    except Exception:
        mgr = None
    if mgr is None:
        mep = getattr(el, "MEPModel", None)
        if mep is not None:
            try:
                mgr = mep.ConnectorManager
            except Exception:
                mgr = None
    if mgr is None:
        return []
    found = list(mgr.Connectors)
    # Stable order, so connector ":0" is the same one next time.
    found.sort(key=lambda c: (round(c.Origin.X, 4), round(c.Origin.Y, 4), round(c.Origin.Z, 4)))
    return found


def _xyz_mm(xyz):
    return Pt(mm_of(xyz.X), mm_of(xyz.Y), mm_of(xyz.Z))


def _location_mm(el):
    loc = getattr(el, "Location", None)
    point = getattr(loc, "Point", None) if loc is not None else None
    if point is None:
        conns = _connectors(el)
        if conns:
            return _xyz_mm(conns[0].Origin)
        return Pt(0, 0, 0)
    return _xyz_mm(point)


def _category_is(el, bic):
    cat = getattr(el, "Category", None)
    if cat is None:
        return False
    return element_int(cat.Id) == int(bic)


def _guess_type(name, sizes):
    if not name or sizes is None:
        return None
    for token in re.split(r"[^A-Za-z0-9]+", name.upper()):
        if token and sizes.has_type(token):
            return token
    return None


def _role(el):
    stated = read_text(el, "PHCP Role")
    if stated:
        return stated.strip().upper()
    DB = _db()
    if _category_is(el, DB.BuiltInCategory.OST_Sprinklers):
        return "SPRINKLER"
    name = _family(el).lower()
    if "hose reel" in name or "hosereel" in name:
        return "HREEL"
    if "hydrant" in name:
        return "HYDRANT"
    return ""


def read_project(doc):
    """Cover sheet and options from Project Information."""
    from phcp.model import Project
    info = doc.ProjectInformation
    project = Project()
    project.title = read_text(info, "PHCP Title") or ""
    project.fields = {}
    for param, key in PROJECT_FIELDS:
        value = read_text(info, param)
        if value:
            project.fields[key] = value
    method = (read_text(info, "PHCP Method") or "").strip().upper()
    project.method = method if method in ("HW", "DW") else "HW"
    project.velocity_pressure = read_bool(info, "PHCP Velocity Pressure")
    project.hose_allowance = read_number(info, "PHCP Hose Allowance", "flow")
    project.velocity_limit = read_number(info, "PHCP Velocity Limit", "number")
    project.sizing_goal = read_text(info, "PHCP Sizing Goal") or ""
    project.sizing_margin = read_text(info, "PHCP Sizing Margin") or ""
    project.design_area = read_text(info, "PHCP Design Area") or ""
    project.fitting_map = read_text(info, "PHCP Fitting Map") or ""
    tol = read_number(info, "PHCP Join Tolerance", "number")
    if tol:
        project.tolerance_mm = float(tol)
    return project


def _sizes(exe):
    path = find_database(exe)
    if path:
        try:
            return load(path)
        except Exception:
            return designations()
    return designations()


def _collector(doc, view, scope):
    DB = _db()
    if scope == "ACTIVE VIEW":
        return DB.FilteredElementCollector(doc, view.Id)
    return DB.FilteredElementCollector(doc)


def _collect(doc, view, scope):
    DB = _db()
    pipes = list(_collector(doc, view, scope).OfClass(DB.Plumbing.Pipe)
                 .WhereElementIsNotElementType().ToElements())
    flex = []
    flex_cls = getattr(DB.Plumbing, "FlexPipe", None)
    if flex_cls is not None:
        flex = list(_collector(doc, view, scope).OfClass(flex_cls)
                    .WhereElementIsNotElementType().ToElements())
    # Category filters, so a door is not opened to see if it is a sprinkler.
    bics = [
        DB.BuiltInCategory.OST_PipeFitting,
        DB.BuiltInCategory.OST_PipeAccessory,
        DB.BuiltInCategory.OST_Sprinklers,
        DB.BuiltInCategory.OST_MechanicalEquipment,
        DB.BuiltInCategory.OST_PlumbingFixtures,
    ]
    filt = DB.ElementCategoryFilter(bics[0])
    for bic in bics[1:]:
        filt = DB.LogicalOrFilter(filt, DB.ElementCategoryFilter(bic))
    instances = list(_collector(doc, view, scope).WherePasses(filt)
                     .WhereElementIsNotElementType().ToElements())
    return pipes, flex, instances


def element_is_pipe(doc, rid):
    DB = _db()
    el = doc.GetElement(make_id(rid))
    return el is not None and _category_is(el, DB.BuiltInCategory.OST_PipeCurves)


def _is_pipe_instance(el):
    DB = _db()
    return any(_category_is(el, bic) for bic in (
        DB.BuiltInCategory.OST_PipeFitting,
        DB.BuiltInCategory.OST_PipeAccessory,
        DB.BuiltInCategory.OST_Sprinklers,
        DB.BuiltInCategory.OST_MechanicalEquipment,
        DB.BuiltInCategory.OST_PlumbingFixtures,
    ))


def read_network(doc, scope, view, exe=None):
    """A Network from the model.

    scope ACTIVE VIEW reads what the view shows.  CONNECTED NETWORK and
    WHOLE MODEL read the model; the walk, given seeds, keeps the connected
    part.  A flex pipe is skipped: it has no single nominal size.
    """
    DB = _db()
    net = Network()
    net.project = read_project(doc)
    net.model_name = doc.Title or ""
    net.sizes = _sizes(exe)
    pipes, flex, instances = _collect(doc, view, scope)
    net.skipped_flex = len(flex)

    pipe_by_id = {}
    for el in pipes:
        built = _pipe_from(el, net.sizes)
        if built is None:
            continue
        net.pipes.append(built)
        pipe_by_id[built.revit_id] = built
        _supply_on_pipe(el, built, net)

    # Fittings and outlets.  Connector keys are allocated first so a pipe
    # bond can name "fit:12:0" and mean the same connector the fitting has.
    conn_keys = {}
    for el in instances:
        if not _is_pipe_instance(el):
            continue
        role = _role(el)
        rid = element_int(el.Id)
        conns = _connectors(el)
        if role == "WATER":
            xyz = _xyz_mm(conns[0].Origin) if conns else _location_mm(el)
            net.supplies.append(_supply_from(el, "sup:%d" % rid, xyz))
            for i, conn in enumerate(conns):
                conn_keys[(rid, i)] = "sup:%d" % rid
            continue
        if role in ("SPRINKLER", "HYDRANT", "HREEL", "FIXEDFLOW"):
            xyz = _xyz_mm(conns[0].Origin) if conns else _location_mm(el)
            net.outlets.append(_outlet_from(el, "out:%d" % rid, xyz, role))
            for i, conn in enumerate(conns):
                conn_keys[(rid, i)] = "out:%d" % rid
            continue
        if _category_is(el, DB.BuiltInCategory.OST_Sprinklers):
            continue
        if not (_category_is(el, DB.BuiltInCategory.OST_PipeFitting)
                or _category_is(el, DB.BuiltInCategory.OST_PipeAccessory)):
            continue
        pts = [_xyz_mm(c.Origin) for c in conns] or [_location_mm(el)]
        fit = Fitting(
            "fit:%d" % rid, pts, revit_id=rid, family=_family(el),
            part=_part(el), angle=_angle_deg(el), code=_explicit_code(el))
        net.fittings.append(fit)
        for i in range(len(pts)):
            conn_keys[(rid, i)] = "fit:%d:%d" % (rid, i)

    for el in pipes:
        built = pipe_by_id.get(element_int(el.Id))
        if built is None:
            continue
        _bonds_from_pipe(el, built, conn_keys, pipe_by_id, net)
    for el in instances:
        if not _is_pipe_instance(el):
            continue
        _bonds_from_instance(el, conn_keys, pipe_by_id, net)
    # Each connection is seen from both ends.  One bond is enough, and a
    # second copy would warn twice about the same gap.
    seen = set()
    unique = []
    for a, b in net.bonds:
        pair = (a, b) if a <= b else (b, a)
        if pair in seen or a == b:
            continue
        seen.add(pair)
        unique.append((a, b))
    net.bonds = unique
    return net


def _explicit_code(el):
    """A fitting code the designer typed on the family, if it is one code.

    PHCP Fittings on a pipe is the whole string and is read with the pipe.
    On a fitting it is one code, for a family the map does not know.
    """
    from phcp.fittings import canonical_code
    text = read_text(el, "PHCP Fittings")
    if not text:
        return None
    return canonical_code(text.strip())


def _pipe_from(el, sizes):
    loc = el.Location
    curve = getattr(loc, "Curve", None) if loc is not None else None
    if curve is None:
        return None
    a = _xyz_mm(curve.GetEndPoint(0))
    b = _xyz_mm(curve.GetEndPoint(1))
    length = m_of(curve.Length)
    rid = element_int(el.Id)
    ptype = read_text(el, "PHCP Pipe Type")
    if not ptype:
        type_name = ""
        try:
            type_name = el.PipeType.Name
        except Exception:
            type_name = ""
        ptype = _guess_type(type_name, sizes)
    dn = read_number(el, "PHCP DN", "number")
    diameter = None
    if dn is None:
        DB = _db()
        diam = el.get_Parameter(DB.BuiltInParameter.RBS_PIPE_DIAMETER_PARAM)
        if diam is not None and diam.HasValue:
            diameter = mm_of(diam.AsDouble())
    return Pipe(
        "pipe:%d" % rid, a, b, length, revit_id=rid,
        pid=read_text(el, "PHCP ID"),
        ptype=(ptype or "").strip().upper() or None,
        dn=dn, diameter_mm=diameter,
        c=read_number(el, "PHCP C", "number"),
        fit_override=read_text(el, "PHCP Fittings"),
        eqv_m=read_number(el, "PHCP Equivalent Length", "length"),
        loss_kpa=read_number(el, "PHCP Pressure Loss", "pressure"),
        length_override_m=read_number(el, "PHCP Length", "length"),
    )


def _supply_from(el, key, xyz, own_id=True):
    curve = []
    text = read_text(el, "PHCP Curve")
    if text:
        try:
            curve = parse_curve(text)
        except ValueError as err:
            raise RevitHostError("the supply curve cannot be read: %s" % err)
    # A supply stored on a pipe must not inherit the pipe's own id.
    sid = read_text(el, "PHCP Supply ID")
    if own_id and not sid:
        sid = read_text(el, "PHCP ID")
    return Supply(
        key, xyz, revit_id=element_int(el.Id),
        sid=sid,
        elevation_m=read_number(el, "PHCP Elevation", "length"),
        static_kpa=read_number(el, "PHCP Static", "pressure"),
        curve=curve,
    )


def _supply_on_pipe(el, built, net):
    end = (read_text(el, "PHCP Supply End") or "").strip().upper()
    if end in ("0", "START"):
        end = "A"
    if end in ("1", "END"):
        end = "B"
    if end not in ("A", "B"):
        return
    xyz = built.a if end == "A" else built.b
    sup = _supply_from(el, built.key + ":SUP", xyz, own_id=False)
    net.supplies.append(sup)
    net.bonds.append((sup.key, built.key + ":" + end))


def _outlet_from(el, key, xyz, role):
    return Outlet(
        key, xyz, role, revit_id=element_int(el.Id),
        oid=read_text(el, "PHCP ID"),
        elevation_m=read_number(el, "PHCP Elevation", "length"),
        k=read_number(el, "PHCP K", "number"),
        min_flow=read_number(el, "PHCP Min Flow", "flow"),
        min_pressure=read_number(el, "PHCP Min Pressure", "pressure"),
        set_flow=read_number(el, "PHCP Set Flow", "flow"),
        drop_dn=read_number(el, "PHCP Drop DN", "number"),
        drop_type=read_text(el, "PHCP Drop Type"),
        area=read_text(el, "PHCP Area"),
    )


def _index_of(conns, origin):
    best = None
    for i, conn in enumerate(conns):
        gap = conn.Origin.DistanceTo(origin)
        if best is None or gap < best[0]:
            best = (gap, i)
    return None if best is None else best[1]


def _bonds_from_pipe(el, built, conn_keys, pipe_by_id, net):
    curve = el.Location.Curve
    ends = {"A": curve.GetEndPoint(0), "B": curve.GetEndPoint(1)}
    for conn in _connectors(el):
        which = "A"
        try:
            if conn.Origin.DistanceTo(ends["B"]) < conn.Origin.DistanceTo(ends["A"]):
                which = "B"
        except Exception:
            which = "A"
        for ref in conn.AllRefs:
            other = _ref_key(ref, conn_keys, pipe_by_id)
            if other and other != built.key + ":" + which:
                net.bonds.append((built.key + ":" + which, other))


def _bonds_from_instance(el, conn_keys, pipe_by_id, net):
    rid = element_int(el.Id)
    conns = _connectors(el)
    for i, conn in enumerate(conns):
        mine = conn_keys.get((rid, i))
        if not mine:
            continue
        for ref in conn.AllRefs:
            other = _ref_key(ref, conn_keys, pipe_by_id)
            if other and other != mine:
                net.bonds.append((mine, other))


def _ref_key(ref, conn_keys, pipe_by_id):
    owner = ref.Owner
    if owner is None:
        return None
    rid = element_int(owner.Id)
    pipe = pipe_by_id.get(rid)
    if pipe is not None:
        try:
            curve = owner.Location.Curve
            a = curve.GetEndPoint(0)
            b = curve.GetEndPoint(1)
            which = "B" if ref.Origin.DistanceTo(b) < ref.Origin.DistanceTo(a) else "A"
        except Exception:
            which = "A"
        return pipe.key + ":" + which
    conns = _connectors(owner)
    index = _index_of(conns, ref.Origin)
    if index is None:
        return None
    return conn_keys.get((rid, index))


def selected_keys(uidoc, net):
    """Object keys in `net` for whatever is selected."""
    chosen = set()
    try:
        ids = [element_int(i) for i in uidoc.Selection.GetElementIds()]
    except Exception:
        ids = []
    wanted = set(ids)
    for pipe in net.pipes:
        if pipe.revit_id in wanted:
            chosen.add(pipe.key)
    for fit in net.fittings:
        if fit.revit_id in wanted:
            chosen.add(fit.key)
    for out in net.outlets:
        if out.revit_id in wanted:
            chosen.add(out.key)
    for sup in net.supplies:
        if sup.revit_id in wanted:
            chosen.add(sup.key)
    return sorted(chosen)


def id_map(walked):
    """PHCP id -> Revit element id, for writing a result back."""
    found = {}
    for pipe in walked.pipes:
        if pipe.revit_id and pipe.pid:
            found[pipe.pid] = pipe.revit_id
    for out in walked.outlets:
        if out.revit_id and out.oid:
            found[out.oid] = out.revit_id
    for sup in walked.supplies:
        if sup.revit_id and sup.sid and sup.sid not in found:
            found[sup.sid] = sup.revit_id
    for node in walked.nodes:
        if node.name and node.name not in found and node.revit_ids:
            found[node.name] = node.revit_ids[0]
    return found


# ---------------------------------------------------------------- writing
def apply_assignments(doc, assignments):
    """Store ids and node names the walk minted, so the next walk reads them."""
    if not assignments:
        return
    with _transaction(doc, "PHCP names"):
        for rid, name, text in assignments:
            el = doc.GetElement(make_id(rid))
            if el is not None:
                _set(el, name, text)


def apply_values(doc, writes):
    """writes is {revit id: {parameter name: engine-unit value}}."""
    if not writes:
        return 0
    done = 0
    with _transaction(doc, "PHCP results"):
        for rid, values in writes.items():
            el = doc.GetElement(make_id(rid))
            if el is None:
                continue
            for name, value in values.items():
                if _set(el, name, value):
                    done += 1
    return done


def clear_result_values(doc, ids=None):
    """Clear solved values.  The markup the designer typed is left alone."""
    DB = _db()
    targets = []
    if ids:
        for rid in ids:
            el = doc.GetElement(make_id(rid))
            if el is not None:
                targets.append(el)
    else:
        for el in DB.FilteredElementCollector(doc).WhereElementIsNotElementType().ToElements():
            if el.LookupParameter("PHCP Flow") is not None or el.LookupParameter("PHCP Node") is not None:
                targets.append(el)
    with _transaction(doc, "PHCP clear results"):
        for el in targets:
            for name in RESULT_PARAMS:
                found = el.LookupParameter(name)
                if found is None or found.IsReadOnly:
                    continue
                try:
                    found.ClearValue()
                except Exception:
                    if found.StorageType == DB.StorageType.String:
                        found.Set("")
                    elif found.StorageType == DB.StorageType.Integer:
                        found.Set(0)


def set_texts(doc, ids, values):
    """String parameters, the same value on each element.  None clears it."""
    with _transaction(doc, "PHCP"):
        for rid in ids:
            el = doc.GetElement(make_id(rid))
            if el is None:
                continue
            for name, text in values.items():
                found = el.LookupParameter(name)
                if found is None or found.IsReadOnly:
                    continue
                if text is None or text == "":
                    try:
                        found.ClearValue()
                    except Exception:
                        found.Set("")
                else:
                    _set(el, name, text)


def set_numbers(doc, ids, values):
    """Engine-unit numbers.  None leaves the parameter alone; a value,
    including 0, is written.
    """
    with _transaction(doc, "PHCP"):
        for rid in ids:
            el = doc.GetElement(make_id(rid))
            if el is None:
                continue
            for name, value in values.items():
                if value is None:
                    continue
                _set(el, name, value)


def set_project(doc, values):
    """values: {parameter name: text or number or bool}."""
    info = doc.ProjectInformation
    with _transaction(doc, "PHCP project"):
        for name, value in values.items():
            if value is None:
                continue
            _set(info, name, value)


def selection_ids(uidoc):
    try:
        return [element_int(i) for i in uidoc.Selection.GetElementIds()]
    except Exception:
        return []


def select_ids(uidoc, ids):
    if uidoc is None or not ids:
        return
    DB = _db()
    from System.Collections.Generic import List
    col = List[DB.ElementId]()
    seen = set()
    for rid in ids:
        if rid in seen:
            continue
        seen.add(rid)
        col.Add(make_id(rid))
    if col.Count:
        uidoc.Selection.SetElementIds(col)


def describe(doc, uidoc):
    """The PHCP parameters on the selection, as lines of text."""
    ids = selection_ids(uidoc)
    if not ids:
        return "Nothing is selected."
    lines = []
    for rid in ids:
        el = doc.GetElement(make_id(rid))
        if el is None:
            continue
        lines.append(_family(el) or el.Name or str(rid))
        for param in ELEMENT_PARAMS:
            if param.name in RESULT_PARAMS:
                continue
            found = _param(el, param.name)
            if found is None:
                continue
            if param.kind == "text":
                value = read_text(el, param.name)
            elif param.kind == "yesno":
                value = "YES" if read_bool(el, param.name) else "NO"
            else:
                number = read_number(el, param.name, param.kind)
                value = None if number is None else ("%g" % number)
            if value:
                lines.append("  %s: %s" % (param.name, value))
        lines.append("")
    return "\n".join(lines).strip() or "No PHCP parameters on the selection."


# ---------------------------------------------------------------- colour, tags
def _schema():
    DB = _db()
    from System import Guid
    from Autodesk.Revit.DB.ExtensibleStorage import AccessLevel, Schema, SchemaBuilder
    guid = Guid(_MARK_GUID)
    found = Schema.Lookup(guid)
    if found is not None and found.IsValidObject:
        return found
    builder = SchemaBuilder(guid)
    builder.SetSchemaName("PHCPMark")
    # Four characters, which is what SchemaBuilder asks for.  Public, so the
    # button can rewrite a mark it made in an earlier session.
    builder.SetVendorId("HYCD")
    builder.SetReadAccessLevel(AccessLevel.Public)
    builder.SetWriteAccessLevel(AccessLevel.Public)
    from System import String
    builder.AddSimpleField("mark", String)
    return builder.Finish()


def _mark_of(el):
    try:
        entity = el.GetEntity(_schema())
        if entity is None or not entity.IsValid():
            return ""
        return entity.Get[str]("mark") or ""
    except Exception:
        return ""


def _set_mark(el, text):
    DB = _db()
    entity = DB.ExtensibleStorage.Entity(_schema())
    entity.Set("mark", text or "")
    el.SetEntity(entity)


def colour_elements(doc, view, colours, legend_lines):
    """Projection colours on the view.  The ids are remembered on the view
    so CLEAR can take them off without touching anything else.
    """
    DB = _db()
    previous = _coloured_ids(view)
    with _transaction(doc, "PHCP colour"):
        for rid in previous:
            el_id = make_id(rid)
            try:
                view.SetElementOverrides(el_id, DB.OverrideGraphicSettings())
            except Exception:
                pass
        for rid, rgb in colours.items():
            ogs = DB.OverrideGraphicSettings()
            colour = DB.Color(int(rgb[0]), int(rgb[1]), int(rgb[2]))
            ogs.SetProjectionLineColor(colour)
            try:
                ogs.SetCutLineColor(colour)
            except Exception:
                pass
            try:
                ogs.SetProjectionLineWeight(8)
            except Exception:
                pass
            view.SetElementOverrides(make_id(rid), ogs)
        _set_mark(view, "colour:" + ",".join(str(i) for i in colours))
    return legend_lines


def _coloured_ids(view):
    mark = _mark_of(view)
    if not mark.startswith("colour:"):
        return []
    ids = []
    for bit in mark[7:].split(","):
        bit = bit.strip()
        if bit:
            try:
                ids.append(int(bit))
            except ValueError:
                pass
    return ids


def clear_colours(doc, view):
    DB = _db()
    ids = _coloured_ids(view)
    with _transaction(doc, "PHCP clear colour"):
        for rid in ids:
            try:
                view.SetElementOverrides(make_id(rid), DB.OverrideGraphicSettings())
            except Exception:
                pass
        _set_mark(view, "")
    return len(ids)


def tag_nodes(doc, view, nodes):
    """Text notes at the nodes, replacing the notes PHCP placed last time.

    A plan or a section holds a text note.  A 3D view and a schedule do not;
    the caller hears about that and the notes are simply not placed.
    """
    DB = _db()
    with _transaction(doc, "PHCP node tags"):
        _delete_tags(doc, view)
        note_type = _text_type(doc)
        if note_type is None:
            raise RevitHostError("The model has no text note type to tag nodes with.")
        options = DB.TextNoteOptions(note_type.Id)
        placed = 0
        for node in nodes:
            if not node.name:
                continue
            # 200 mm to the side, so the name is not drawn on top of the node.
            point = DB.XYZ(
                _from((node.x + 200.0), _units().Millimeters),
                _from(node.y, _units().Millimeters),
                _from(node.z, _units().Millimeters),
            )
            try:
                note = DB.TextNote.Create(doc, view.Id, point, node.name, options)
            except Exception as err:
                raise RevitHostError(
                    "This view cannot hold node tags.  Open a plan or a section. (%s)" % err)
            _set_mark(note, "tag")
            placed += 1
    return placed


def _text_type(doc):
    DB = _db()
    found = list(DB.FilteredElementCollector(doc).OfClass(DB.TextNoteType).ToElements())
    return found[0] if found else None


def _delete_tags(doc, view):
    DB = _db()
    notes = DB.FilteredElementCollector(doc, view.Id).OfClass(DB.TextNote).ToElements()
    for note in list(notes):
        if _mark_of(note) == "tag":
            doc.Delete(note.Id)


def clear_tags(doc, view):
    with _transaction(doc, "PHCP clear tags"):
        _delete_tags(doc, view)


def read_result_numbers(doc, walked):
    """Solved velocity, flow, pass and margin, in engine units, from the
    parameters CALCULATE wrote.  Colour uses these rather than solving again.
    """
    speeds = {}
    flows = {}
    outlets = {}
    pipes = {}
    for pipe in walked.pipes:
        if not pipe.revit_id or pipe.omit:
            continue
        el = doc.GetElement(make_id(pipe.revit_id))
        if el is None:
            continue
        speed = read_number(el, "PHCP Velocity", "velocity")
        flow = read_number(el, "PHCP Flow", "flow")
        if speed is not None:
            speeds[pipe.revit_id] = speed
        if flow is not None:
            flows[pipe.revit_id] = flow
        pipes[pipe.revit_id] = (pipe.n1, pipe.n2)
    for out in walked.outlets:
        if not out.revit_id:
            continue
        el = doc.GetElement(make_id(out.revit_id))
        if el is None:
            continue
        # No solved pass yet: colouring it as a failure would be a guess.
        passed = el.LookupParameter("PHCP Pass")
        if passed is None or not passed.HasValue:
            continue
        # A drop's host node is what the range pipe ends on, so the range
        # takes the outlet's colour.  The outlet element is coloured too.
        node = out.oid
        for walked_node in walked.nodes:
            if out in walked_node.drop_outlets or out in walked_node.outlets:
                node = walked_node.name
                break
        outlets[out.revit_id] = {
            "node": node,
            "pass": read_bool(el, "PHCP Pass"),
            "margin": read_number(el, "PHCP Margin", "pressure"),
        }
    return speeds, flows, outlets, pipes
