# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
# The shared parameters the Revit extension creates.
#
# They are the markup a designer edits in the properties palette, and the
# results CALCULATE writes back so a schedule or a tag can show them.  The
# GUIDs are fixed: creating the parameters again on another machine binds the
# same definitions instead of a second copy with the same name.
#
# Kinds are the engine's quantities, not Revit's internal units.  The Revit
# host converts when it reads and writes.  A Number is unitless on purpose
# (a DN, a C, a K, a tolerance in mm) so a project set in feet does not
# rescale it.

from collections import namedtuple

Param = namedtuple("Param", "name guid kind scope description")

# scope "element": pipes, fittings, sprinklers, accessories, equipment, fixtures.
# scope "project": Project Information.

ELEMENT = "element"
PROJECT = "project"

# kind tells the host which Revit spec to create and how to convert.
TEXT = "text"
NUMBER = "number"
LENGTH = "length"          # metres in the engine
PRESSURE = "pressure"      # kPa
FLOW = "flow"              # L/min
VELOCITY = "velocity"      # m/s
YESNO = "yesno"

_P = [
    ("PHCP ID", "dfd1507b-6b12-5a10-a2a7-44ee8d0e6499", TEXT, ELEMENT,
     "Stable PHCP name. Kept on the element so the next export uses it again."),
    ("PHCP Role", "b1356869-5320-5a07-b75d-615c83d8fe84", TEXT, ELEMENT,
     "WATER, SPRINKLER, HYDRANT, HREEL or FIXEDFLOW. Blank: inferred from the category."),
    ("PHCP Pipe Type", "8f994b70-759f-59bb-8b5c-7c004ff0474c", TEXT, ELEMENT,
     "Pipe type code from the pipe and fitting database, such as ASAM or S40."),
    ("PHCP DN", "2172fb56-fcf3-5655-b5cf-0ace5bb02186", NUMBER, ELEMENT,
     "Nominal size in mm. 0: PHCP sizes the pipe. Blank: taken from the Revit diameter."),
    ("PHCP C", "4cf4bbc5-fe45-54ec-b818-a375e151eb23", NUMBER, ELEMENT,
     "Hazen-Williams C, or roughness in mm under Darcy-Weisbach. Blank: the database's."),
    ("PHCP Fittings", "d569da13-c9ca-5488-8c17-f31972b9992e", TEXT, ELEMENT,
     "Fitting codes, such as 2E T GV. Blank: counted from the families on the pipe."),
    ("PHCP Length", "d6f42386-c7a1-5c30-a357-831edeff5958", LENGTH, ELEMENT,
     "Length override in metres, for a riser drawn as a short line."),
    ("PHCP Equivalent Length", "fbff7409-1d8b-5566-ac95-a00818962c40", LENGTH, ELEMENT,
     "Equivalent length added to the pipe, on top of its fittings."),
    ("PHCP Pressure Loss", "9c91b63b-d98a-5aed-9b4c-86294ea0c2e5", PRESSURE, ELEMENT,
     "A fixed pressure loss that does not vary with flow."),
    ("PHCP Static", "5d1c8d0b-2003-5922-8b07-e4dd6f0339a5", PRESSURE, ELEMENT,
     "Supply static pressure, the pressure at zero flow."),
    ("PHCP Curve", "a214a5e5-e094-51c1-a818-e654c5f2beaf", TEXT, ELEMENT,
     "Supply test points: flow, pressure, flow, pressure, in L/min and kPa."),
    ("PHCP K", "25fed7be-6479-590c-8cc0-2f8495f6484d", NUMBER, ELEMENT,
     "K-factor, L/min per square root of kPa."),
    ("PHCP Min Flow", "2077a279-78d7-5fc2-b28b-26163dbb7434", FLOW, ELEMENT,
     "Least flow an outlet must give."),
    ("PHCP Min Pressure", "efb7a882-266f-5bc3-9385-38b610d9b787", PRESSURE, ELEMENT,
     "Least pressure an outlet must have."),
    ("PHCP Set Flow", "4932b6ca-2262-5b83-9909-9891c6aa9804", FLOW, ELEMENT,
     "The flow of a fixed flow. It is taken whatever the pressure."),
    ("PHCP Elevation", "a0c1bf39-eba4-5910-953a-7be32e47a8da", LENGTH, ELEMENT,
     "Elevation override in metres. Blank: the height of the element in the model."),
    ("PHCP Drop DN", "bc00ab5f-3501-547b-b182-60f8f5559d0a", NUMBER, ELEMENT,
     "Drop size in mm, when the outlet sits below the pipe it is fed from."),
    ("PHCP Drop Type", "11ebcb92-c396-51a3-a842-fdc4454c12e7", TEXT, ELEMENT,
     "Pipe type of a drop. Blank: ASAM."),
    ("PHCP Area", "73a87641-aea0-5c7e-af12-5583e0790ef0", TEXT, ELEMENT,
     "Design area. Outlets with the same name flow together; the rest are shut."),
    ("PHCP Supply End", "cb71e442-5009-5e2c-98e3-2be319fcf5d0", TEXT, ELEMENT,
     "A or B, when the supply is this pipe's end rather than its own element."),
    ("PHCP Supply ID", "176b0252-8335-505a-96f7-11f41c8de0c6", TEXT, ELEMENT,
     "The supply's name, when the supply is stored on a pipe."),
    ("PHCP Flow", "3e0ee1bb-5779-5853-a0aa-f284d287d3c6", FLOW, ELEMENT,
     "Solved flow. On a pipe, positive from end A (the curve start) to end B."),
    ("PHCP Velocity", "fa6e5a18-9f3e-5cd3-bc1d-0701b4689add", VELOCITY, ELEMENT,
     "Solved velocity."),
    ("PHCP Friction Loss", "da8b301e-c36f-5b2d-806b-d558c3b5ead2", PRESSURE, ELEMENT,
     "Solved friction loss along the pipe."),
    ("PHCP Pressure", "c50b0eb0-e021-59a2-a165-d49d3b2eb705", PRESSURE, ELEMENT,
     "Solved gauge pressure."),
    ("PHCP Margin", "0f9087a5-b288-59c2-9fa5-8949b4a00d02", PRESSURE, ELEMENT,
     "Pressure to spare at an outlet, against what it must have."),
    ("PHCP Pass", "95e67f05-43cf-5ea5-9a2a-a3d4da391dbf", YESNO, ELEMENT,
     "The outlet meets its flow and its pressure."),
    ("PHCP Suggested DN", "98ae2caa-ff30-56e3-875e-ea2bb9ae07b7", NUMBER, ELEMENT,
     "The nominal size PHCP's auto sizing would use. The modelled size is not changed."),
    ("PHCP Node", "564503da-d667-56c8-b8cb-301dd61022ff", TEXT, ELEMENT,
     "Node name from the last walk."),
    ("PHCP Title", "10b06af2-2660-5c94-9807-80519da337f2", TEXT, PROJECT,
     "Calculation title, for the cover sheet."),
    ("PHCP Job", "d9d64cc7-70e7-5450-89c3-ac4734dc5c08", TEXT, PROJECT,
     "Job number."),
    ("PHCP Company", "3ca57bce-39c0-5f44-8d69-5c29bdc65733", TEXT, PROJECT,
     "Company, for the cover sheet."),
    ("PHCP Designer", "877eb100-40c9-511e-a2af-b473e3b0a9e9", TEXT, PROJECT,
     "Designer, for the cover sheet."),
    ("PHCP Hazard", "98d0ac54-30f7-5b3e-b1ef-c76d5710078d", TEXT, PROJECT,
     "Hazard class, for the cover sheet."),
    ("PHCP Density", "c8529185-7196-5d64-b149-db4da3045d86", TEXT, PROJECT,
     "Design density, for the cover sheet."),
    ("PHCP Area Per Sprinkler", "cc27ebdc-2269-550e-a74d-dd47ce6bdd1a", TEXT, PROJECT,
     "Area per sprinkler, for the cover sheet."),
    ("PHCP Authority", "0e693790-093c-5eef-b9e9-252e1da205c5", TEXT, PROJECT,
     "Authority, for the cover sheet."),
    ("PHCP Method", "ef5971fd-e82a-5e75-ae63-8a840f647882", TEXT, PROJECT,
     "HW or DW. Blank: Hazen-Williams."),
    ("PHCP Velocity Pressure", "5b897b8f-aa77-5ecd-b74a-04a01709cdbd", YESNO, PROJECT,
     "ON: in-line sprinklers discharge on normal pressure. Blank: off."),
    ("PHCP Hose Allowance", "9d8a7320-7f9e-54c2-9d48-b6fe7c57de5a", FLOW, PROJECT,
     "Hose stream allowance, added to the demand at the supply."),
    ("PHCP Velocity Limit", "973ce654-302a-566c-87c8-a0ae8c2c41e9", NUMBER, PROJECT,
     "Velocity limit in m/s. Blank: 6. Pipes faster than this are listed, and sizing keeps to it."),
    ("PHCP Join Tolerance", "5161ddd5-9ea1-5996-b633-ce6c713882b6", NUMBER, PROJECT,
     "How far apart, in mm, two ends may be and still be the same node. Blank: 5."),
    ("PHCP Sizing Goal", "67407883-3750-5021-8c90-a5173da0e336", TEXT, PROJECT,
     "SMALLEST or VOLUME, for SUGGEST. Blank: the smallest pipes that will do."),
    ("PHCP Sizing Margin", "08e90758-30ad-5cf2-b697-53f409223d6f", TEXT, PROJECT,
     "Margin under the supply when sizing, such as 10% or 50. Blank: none."),
    ("PHCP Design Area", "9bf25e9c-8caf-5a7a-9485-f23fee9413a7", TEXT, PROJECT,
     "Solve this design area only. Blank: every area, and the governing one is reported."),
    ("PHCP Fitting Map", "3b771caf-1c53-521e-ab37-a6bccc2b6766", TEXT, PROJECT,
     "Family-name rules, one a line: the text to find, then the fitting code. These win over the built-in rules."),
]

PARAMS = [Param(*row) for row in _P]
BY_NAME = {p.name: p for p in PARAMS}
ELEMENT_PARAMS = [p for p in PARAMS if p.scope == ELEMENT]
PROJECT_PARAMS = [p for p in PARAMS if p.scope == PROJECT]

# Cover-sheet fields, in the order the .phc writer emits PROJECT lines.
PROJECT_FIELDS = [
    ("PHCP Job", "JOB"),
    ("PHCP Company", "COMPANY"),
    ("PHCP Designer", "DESIGNER"),
    ("PHCP Hazard", "HAZARD"),
    ("PHCP Density", "DENSITY"),
    ("PHCP Area Per Sprinkler", "AREA_PER_SPRINKLER"),
    ("PHCP Authority", "AUTHORITY"),
]

# Result parameters CLEAR may wipe.  The markup the designer typed is left.
RESULT_PARAMS = [
    "PHCP Flow", "PHCP Velocity", "PHCP Friction Loss", "PHCP Pressure",
    "PHCP Margin", "PHCP Pass", "PHCP Suggested DN", "PHCP Node",
]

DEFAULT_TOLERANCE_MM = 5.0
DEFAULT_VELOCITY_LIMIT = 6.0
DEFAULT_DROP_TYPE = "ASAM"


def guid_of(name):
    """The parameter's GUID, braced, as a shared-parameter file writes it."""
    return "{" + BY_NAME[name].guid + "}"
