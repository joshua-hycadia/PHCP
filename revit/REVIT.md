# PHCP for Revit 2022 to 2027

`revit/PHCP.extension` is a pyRevit extension.  It walks the pipework in a
Revit model, writes a `.phc` model, and runs the PHCP engine on it.  The
engine is called as a program (`phcp.exe --json`, or `phcp.pl --json`), the
same way AutoCAD calls it.  The extension does not solve anything itself.

The file is `.phc`, the engine's model language.  There is no `.phcp` file.

Copyright (c) 2026 Hycadia Pty Ltd - MIT licence, see LICENSE.  The licence
covers this source.  It does not cover the pipe and fitting database in
`data/`.

## Load it

pyRevit 4.8 or later, with the CPython 3 engine.  Revit 2025 to 2027 are
.NET 8, so IronPython is not used.  Revit 2022 and 2023 work on the same
extension.

1. Install pyRevit and set its engine to CPython 3.
2. In pyRevit, **Settings, Custom Extension Directories**, add the `revit`
   folder (the folder that contains `PHCP.extension`, not the extension
   folder itself).
3. Reload pyRevit.  A **PHCP** tab appears, with panels **SETUP**, **MODEL**,
   **CALCULATE** and **SHOW**.

## First use, on a model

1. **PARAMETERS** - creates the shared parameters and binds them.  Run this
   once on each model, and again after an update that adds parameters.
   The other buttons refuse to run until it has.
2. **ENGINE** - choose `phcp.exe` (or `phcp.pl`).  The path is remembered in
   `%APPDATA%\PHCP\revit.ini` on this machine, or `~/.config/PHCP/revit.ini`.
   `PHCP_EXE` overrides it.  That file is not the Perl program's
   `settings.ini`.
3. **PROJECT** - the cover sheet, the method (HW or DW), velocity pressure,
   hose allowance, the velocity limit (blank is 6 m/s), the join tolerance
   (blank is 5 mm), and the sizing goal, margin and design area.
4. Mark up the pipes, the supply and the outlets, below.
5. **CHECK**, then **CALCULATE** or **EXPORT**.

## The ribbon

| button | what it does |
|---|---|
| ENGINE | Remember where `phcp.exe` or `phcp.pl` is. |
| PARAMETERS | Bind the shared parameters. |
| PROJECT | Cover sheet and the options written at the top of the `.phc`. |
| FITTING MAP | Project rules that turn a family name into a fitting code. |
| SUPPLY | One selected element becomes the water supply. |
| AREA | The design-area name on the selected outlets. Blank clears it. |
| OUTLETS | Role, K, minimum flow and pressure, drop and elevation on the selection. |
| PIPES | Pipe type, DN, C, fittings and a length override on the selection. |
| DEVICE | A booster, a loss curve, a reducing valve, an orifice plate or a ratio valve. |
| OVERRIDE | Equivalent length and a fixed pressure loss on the selection. |
| RENUMBER | New ids for copied elements. The original keeps its name. |
| INFO | The PHCP data on the selected element. |
| CHECK | Walk the network and list the problems. Errors are selected. |
| EXPORT | Walk, then write a `.phc`. Nothing is solved. |
| CALCULATE | Walk, solve, write the report, and put the results on the elements. |
| SUGGEST | Ask the engine which DN it would use. The modelled size stays. |
| APPLY | Copy that DN onto PHCP DN. The Revit diameter is not changed. |
| VELOCITY | Colour the view by velocity, against the limit. |
| FLOW | Colour the view by flow. |
| ABILITY | Colour the view by whether an outlet can flow. |
| SELECT | Select the outlets that fail, or the pipes over the velocity limit. |
| TAG NODES | Text notes of the node names, the pipe names, or both. |
| CLEAR | Colour, tags and the colour key, the written results, or both. |

CHECK, EXPORT, CALCULATE, SUGGEST and the colour and tag buttons ask which
pipes to walk:

- **CONNECTED NETWORK** - start from the selection and follow connectors,
  and ends within the join tolerance.  A pipe that is not joined to that
  selection is left out.
- **ACTIVE VIEW** - the pipes, fittings and outlets visible in the view.
- **WHOLE MODEL** - every pipe the collector finds.

A flex pipe is skipped, with a warning.  It has no single nominal size.

## Parameters

**PARAMETERS** writes a shared-parameter file at
`%APPDATA%\PHCP\PHCP-shared-parameters.txt` (UTF-16) and binds the
definitions into the model.  The GUIDs are fixed, so binding them again, on
another machine, does not create a second copy of the same name.

They are the markup a designer edits, and the results CALCULATE writes back.
A length, a pressure, a flow and a velocity are stored in Revit's units and
shown in the project's.  The extension converts: the engine always sees
metres, kPa, L/min and m/s.  A DN, a C, a K and the join tolerance are plain
numbers, so a project in feet does not rescale them.

On an element:

| parameter | meaning |
|---|---|
| PHCP ID | The name written into the `.phc`. Kept, so the next export uses it again. |
| PHCP Role | WATER, SPRINKLER, HYDRANT, HREEL or FIXEDFLOW. Blank: taken from the category. |
| PHCP Pipe Type | A code from the pipe and fitting database, such as ASAM. |
| PHCP DN | Nominal size, mm. 0 asks the engine to size the pipe. Blank: the Revit diameter. |
| PHCP C | Hazen-Williams C, or roughness in mm under Darcy-Weisbach. Blank: the database. |
| PHCP Fittings | Codes such as `2E T GV`. Blank: counted from the families. NONE clears them. |
| PHCP Length | Length override, m, for a riser drawn short. |
| PHCP Equivalent Length | Extra equivalent length, on top of the fittings. 0 clears it. |
| PHCP Pressure Loss | A loss that does not vary with flow, kPa. 0 clears it. |
| PHCP Device | BP, BFP, PRV, OPP, OFD or PRA. A pipe holds one, at its start. |
| PHCP Device Data | The device's figures. See Devices. |
| PHCP Pump Duty | Flow and pressure of a booster's rated duty. |
| PHCP Static | Supply pressure at zero flow, kPa. |
| PHCP Curve | Test points: flow, pressure, flow, pressure. L/min and kPa. |
| PHCP K | K-factor, L/min per square root of kPa. |
| PHCP Min Flow | Least flow the outlet must give, L/min. |
| PHCP Min Pressure | Least pressure the outlet must have, kPa. |
| PHCP Set Flow | A fixed flow, taken whatever the pressure. |
| PHCP Elevation | Elevation override, m. Blank: the height in the model. |
| PHCP Drop DN | Drop size, mm, when the outlet sits below its pipe. |
| PHCP Drop Type | Pipe type of a drop. Blank: ASAM. |
| PHCP Area | Design area. Outlets with the same name flow together. |
| PHCP Supply End | A or B, when the supply is that end of a pipe. A is the curve start. |
| PHCP Supply ID | The supply's name, when it is stored on a pipe. |

Written back by CALCULATE, and cleared by CLEAR.  The markup above is left:

| parameter | meaning |
|---|---|
| PHCP Flow | Solved flow. On a pipe, positive from end A to end B. |
| PHCP Velocity | Solved velocity, m/s. |
| PHCP Friction Loss | Solved friction loss along the pipe, kPa. |
| PHCP Pressure | Solved gauge pressure, kPa. |
| PHCP Margin | Pressure to spare at an outlet, kPa. |
| PHCP Pass | The outlet meets its flow and its pressure. |
| PHCP Suggested DN | The nominal size SUGGEST would use. The modelled size is not changed. |
| PHCP Node | Node name from the last walk. |

On Project Information: the title, job, company, designer, hazard, density,
area per sprinkler and authority (the cover sheet); method; velocity
pressure; hose allowance; velocity limit; join tolerance; sizing goal;
sizing margin; design area; fitting map.

## A supply

Select one element and run **SUPPLY**.

- A pipe: the supply is that pipe's end.  A is the start of the curve, B the
  other end.  The name is stored in PHCP Supply ID, not PHCP ID, so the pipe
  keeps its own pipe name.
- Anything else: the element itself is the supply, and the name is PHCP ID.

A static pressure is required.  A curve is optional: pairs of flow and
pressure, in L/min and kPa, after the static pressure.  An elevation, if
given, overrides the height of that end.

## Outlets

**OUTLETS** sets the selection in one step.  Blank leaves a field as it is.

| field | parameter |
|---|---|
| SPRINKLER, HYDRANT, HREEL or FIXEDFLOW | PHCP Role |
| K | PHCP K. 0 shuts the outlet. |
| minimum flow, L/min | PHCP Min Flow |
| minimum pressure, kPa | PHCP Min Pressure |
| fixed flow, L/min | PHCP Set Flow |
| drop size, mm, and drop type | PHCP Drop DN, PHCP Drop Type |
| elevation, m | PHCP Elevation |

A row of heads at one level is an elevation on the selection.  A riser drawn
as a short line is a length override on **PIPES**: the metres to use instead
of the drawn length.  CLEAR on that field removes the override.

## An area

**AREA** sets PHCP Area on the selected outlets.  Outlets that share a name
are one design area: they flow together, and the others are shut.  Blank
clears the name.  PROJECT's design area, if set, is the one the engine
solves; blank solves every area and reports the governing one.

## Families and fitting codes

A fitting is not modelled as a body.  Its equivalent length, from the pipe
and fitting database, is added to a pipe.  The walk reads the family name
and the Revit part type.

Built in, when no project rule matches: a long-radius elbow is EL, a 45
degree elbow is E45, any other elbow is E, a tee, wye or cross is T, a gate
valve is GV (and GV25, GV50, GV75 when the name says how far open it is), a
check or alarm valve is CV, a butterfly check is CVB, a butterfly valve is
BV, a globe valve is GLV, an angle valve is AV.  A coupling is CPL only when
a pipe at it is CPVC; the steel tables have no coupling.  A cap closes an
end.  It is not a fitting loss.  "DN25" in a name is not a 25% open valve.

**FITTING MAP** stores rules on the project, one a line: the text to find in
the family name, then the code, separated by `=`, `|` or spaces.  The first
match wins, and a project rule wins over the built-in one.  A code the
engine does not know is refused when the map is saved.

A pipe with PHCP Fittings set is not given fittings from its families.  The
string is the same compact form the engine reads: `2E,1T` or `1E1T`.  On the
way out, the codes are written in a fixed order (elbows, then a tee, then
the rest alphabetically) and a count of 1 is left off, so two exports of the
same pipe match.  `1T 2E 1GV 1CV` is written `2E T CV GV`.

Where a fitting sits: a tee's equivalent length goes on the branch, the pair
of pipes most nearly in a straight line being the through main.  An elbow or
a valve goes on the smaller pipe, and on the later pipe when the sizes
match.  It is counted once.

## Walking, and the join tolerance

Connectors that Revit has already joined are one node, even when the fitting
body holds the ends apart.  A gap wider than ten times the tolerance (and at
least 50 mm) is still joined, and reported, because the connector says they
meet.  An outlet sitting under a pipe in plan is a drop, not that warning.

Ends with no connector, within the join tolerance (PHCP Join Tolerance,
default 5 mm), are the same node, with a warning that they were joined on
tolerance.  A gap past the tolerance and within that near-miss distance is
reported and not joined.  A pipe end that lands on the middle of another
pipe is an error: split the pipe at the branch.

An open end is an error.  A cap is a warning.  Two outlets, two supplies, or
a supply and an outlet on one node are errors.  A supply or an outlet that
is not on a pipe is an error.  A disconnected run of pipes that has outlets
and no supply is an error.  A stub with no supply and no outlet is left out
of the model, with a warning.

Pipe length is the Revit curve length, which is already the 3D length, or
PHCP Length when that is set.  Elevation is not added on top of it.  The
length of a fitting body is not added either: the equivalent length stands
in for the fitting.

A drop is an outlet whose plan position is within the tolerance of a pipe
end, at a different height, or a connector bond whose ends differ in height
by more than the tolerance.  It is written as `<outlet>_D`, from the pipe's
node down to the outlet's own node, with a tee unless a family already put
one there.  An elbow on a pipe that has only that one pipe is moved onto the
drop.

Node elevation is the mean height of the pipe ends at that node, then a
supply's elevation override.  An outlet's elevation does not move the node
it hangs from; it sets the outlet and the drop length.

## Node names

A supply and an outlet name their own nodes, so SUP1 and S1 in the report
are the elements with those PHCP IDs.  Plain junctions are N2, N3, ... in
pipe order.  The first junction after a supply is not N1: the supply took
the first number and then renamed it.  Pipe and outlet ids are stored and
stay.  Node names can change when the network changes.  **TAG NODES** places
a text note 200 mm to the side of each node, a pipe name 200 mm off the
middle of the pipe, or both, and replaces the notes from the last run.  A
3D view and a schedule cannot hold a text note; open a plan or a section.

## Overrides

**OVERRIDE** sets two things, either or both:

- PHCP Equivalent Length, metres, written as `EQV` on top of the fittings.
- PHCP Pressure Loss, kPa, written as a fixed loss (`BFP` with one pair at
  flow 0).  It does not vary with flow.

Blank leaves the value.  0 clears it.

## Devices

**DEVICE** puts one device in each selected pipe, at the start of the pipe.
NONE clears it.  A fixed pressure loss and a device on the same pipe are
refused: a pipe holds one.

| device | figures | written as |
|---|---|---|
| BP | churn pressure, then flow and pressure pairs. Duty, optional: flow and pressure | `BP`, and `PUMPDUTY` when a duty is set |
| BFP | flow and loss, in pairs. One pair is a fixed loss, so its flow is 0 | `BFP` |
| PRV | the same pairs. `0 50` is 50 kPa at any flow | `PRV` |
| OPP | the drop wanted, kPa, and a discharge coefficient if you have one | `OPP` |
| OFD | the plate's bore, mm, and a discharge coefficient if you have one | `OFD` |
| PRA | the ratio, such as `3:1`, then a minimum inlet and a band if you have them | `PRA` |

A discharge coefficient is more than 0 and not more than 1.  A ratio is more
than 1.  The report checks a booster's curve against its duty: at the duty,
at shut-off (AS 2941-2013, at most 140 % of the duty pressure), and at 150 %
flow for information.

## Copies

Copying a pipe or a head copies its PHCP ID.  **CHECK** reports the duplicate
and stops.  **RENUMBER** gives the copies the next free name with the same
letters.  The element with the lower Revit id keeps the name, which is the
one that was there before the copy.  Selected copies, or every copy in the
model.

## Colour

Colour is a view override.  It is not a pass or fail rule, and it does not
change the model.  Each colouring also places the key as a text note inside
the crop of the view.  CLEAR removes the overrides, the tags and that key.

**SELECT**, after a calculation, selects the outlets that fail, or the pipes
over the velocity limit.

**VELOCITY**, as fractions of the limit (6 m/s unless PROJECT sets another):

| colour | band |
|---|---|
| green | up to half the limit |
| lighter green | half to 80% of the limit |
| amber | 80% of the limit, up to the limit |
| red | over the limit |

**FLOW**, L/min: 0 to 100, 100 to 500, 500 to 1500, 1500 to 3000, and over.
Darker is more flow.

**ABILITY** colours the outlet, and the pipes that end at that outlet's
node.  A drop uses the node it hangs from, so the range pipe is coloured.  A
main with no outlet at either end stays as it was.

| colour | meaning |
|---|---|
| red | the outlet fails |
| amber | it passes, with less than 50 kPa to spare |
| green | it passes |

The 50 kPa is for the view only.  The engine's pass is unchanged.  An outlet
with no PHCP Pass yet is not treated as a failure: calculate first.

## Suggest a size

**SUGGEST** asks the engine to size pipes (size 0 in the model it is handed).
The Revit diameter is not changed.  The DN the engine chooses is written to
PHCP Suggested DN, and the dialog lists each one, for example `P3  40 -> 50`.
**APPLY** copies that DN onto PHCP DN, on the selection or on every pipe that
has a suggestion, so the next calculation uses it.  The Revit diameter is
still not changed.  A suggestion of 0 is not a size and is not copied.

- **OVER THE VELOCITY LIMIT** solves once, writes the results back, and
  sizes the pipes faster than the limit.
- **SELECTED PIPES** sizes the pipes in the selection.
- **EVERY PIPE** sizes the whole walked network.

The sizing goal and margin are the PROJECT settings: SMALLEST or VOLUME, and
a margin such as `10%` or `50`.  Blank is the smallest pipes that will do,
with no margin.

## Export and calculate

**EXPORT** asks for a path and writes the `.phc`.  It does not run the
engine.  Open the file in the PHCP editor, or run `phcp.exe model.phc
report.pdf`.

**CALCULATE** writes `<model>.phc` and `<model>-phcp.pdf` beside the Revit
file (or in the temp folder, if the model has not been saved), runs
`phcp.exe --json --report`, and shows the engine's summary.  The `.phc`
beside the model is overwritten each time, as the AutoCAD solve command
does.  Results are written back only when the engine exits 0.  Exit 1 did
not converge: the results are not used.  Exit 2 is an input error.

The units written are always length m, elevation m, size mm, pressure kPa,
flow L/min, K-factor L/min per square root of kPa.  The method is
Hazen-Williams unless PROJECT says DW.

K is worked out when it was not given and both a minimum flow and a minimum
pressure were.  When both are set and the flow is more than K at that
pressure, the flow is what is required; otherwise the pressure is, written
as a negative number, which is how the language encodes a minimum pressure.

## Where a diameter comes from

PHCP DN, when set, is the size.  Otherwise the outside diameter or the bore
is matched against the pipe and fitting database, within 2 mm, and the
closest DN wins.  A tie prefers the DN name, then the outside diameter, then
the bore.  114.3 mm on ASAM is DN100, not DN125.  A diameter that is already
a DN name matches that DN.

The database is `pipes.dat` from `PHCP_DATABASE_DIR` if that is set, else
`data/pipes.dat` beside the engine, else `pipes.dat` beside the engine.  If
none of those can be read, a DN is matched only when the Revit size is
within 2 mm of the DN name itself.  The extension does not copy the
database's diameters into its source.

## Not yet run inside Revit

The walk, the `.phc` it writes, the fitting codes, the devices, the colours
and the size suggestions are checked by `python3 tools/test_revit.py`, with
no Revit present.  That test builds the same network as
`examples/08_autocad_export_format.phc`, solves it with `phcp.pl`, and
compares the flows and pressures with
`tools/baseline/08_autocad_export_format.expected`.  It also checks that
every ribbon button calls a command that exists.

It has not been clicked inside Revit 2022, 2023, 2024, 2025, 2026 or 2027.
The shared-parameter binding, the view overrides and the text notes are
written against the Revit API and have not been exercised on it.  Try it
first on a copy of a small model: a supply, a main, two branches and two
heads, and compare the export with the model.
