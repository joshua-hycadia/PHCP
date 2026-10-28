# PHCP - Perl Hydraulic Calculation Program

Copyright (c) 2026 Hycadia Pty Ltd.  MIT licence - see LICENSE, which also sets
out what the licence does NOT cover: the third-party values reproduced in
`data/`, and Tk.

Version 1.0.0

A Hardy Cross loop-balancing hydraulic solver, a plain-text command language
for the model (`.phc`), a text editor built around it, and a monospace ASCII
calculation report.  The whole stack is Perl.

```
perl phcp_editor.pl model.phc            # the editor (F4 validates, F5 calculates, Ctrl+R writes the report)
./phcp.pl model.phc report.pdf           # solve and write the report as PDF
./phcp.pl model.phc report.txt           # ...or as plain ASCII text
./phcp.pl --json model.phc               # the results as JSON, for another program
perl phcp_viewer.pl model.phc            # read-only results viewer
perl tools/test_phc.pl                   # verify the .phc language
perl tools/test_editor.pl                # verify the editor's logic
perl tools/test_editor_window.pl         # drive the editor window (uses xvfb-run if no display)
perl tools/test_pipedata.pl              # verify the pipe and fitting database
perl tools/test_graph.pl                 # verify the Q^1.85 water supply graph
perl tools/stress_invariance.pl 60       # invariance stress on 60 random networks
```

One model file type: `.phc`, the command language described below.  `phcp.pl`,
the editor, the viewer and the AutoCAD exporter all read or write it, and a
file of any other type is refused with the reason.  (The editor's GRAPH tab,
which draws a water supply graph from figures typed in rather than from a
model, keeps those figures in a `.phg` file of its own - see Water supply
graph.)

## The .phc command language

The model is typed as short command lines - one element per line, fields by
position, no `KEY=value` - in any order:

```
// TANK AND PUMP ROOM
UNITS     ELEVATION M
USE       S20 120
PIPE      4    2    101  7000  300  G T
PIPE      5    3    109  7000  300  G
WATER     2    31.5  1100  7570 1035
NODE      101  31.5
SPRINKLER 4101 47.076  81  8
FIXEDFLOW HOSE 2105  1900  250
```

**Rules.**  The first word is the command, written in capitals (lower case is
read the same).  Fields are separated by spaces or tabs and go by position.
`//` starts a comment to the end of the line; `!` and `#` are not allowed
outside one.  Names are case-sensitive.

**Any order.**  Lines may come in any order.  Settings (`TITLE`, `PROJECT`,
`UNITS`, `METHOD`, `OPTION`) are file-wide wherever they appear, and each is
given once - a second is an error naming both lines.  `USE` is the one
positional command: it applies to the `PIPE` lines after it.

**Every node is defined exactly once**, by `NODE`, `WATER`, `SPRINKLER`,
`HYDRANT`, `HREEL` or a copy (`NC`), and every node a pipe, pump or fixed flow
names must be defined; an undefined node is an error naming it and the first
line that uses it.  Every pipe name is unique.

| command | fields |
|---|---|
| `TITLE` | text |
| `PROJECT` | FIELD text - any cover field: COMPANY, JOB, DESIGNER, DENSITY ... |
| `UNITS` | QUANTITY UNIT - see Units |
| `METHOD` | `HW` or `DW` |
| `OPTION` | NAME value: `PROFILE HW_CONST NU TOL_FLOW TOL_LOOP MAXITER RELAX VEL_LIMIT FITTING_BASIS ORIF_STEP` |
| `USE` (`U`) | PIPETYPE [C] - a type from the database, and its C (under `METHOD DW`, its roughness); or `BORE` [C] |
| `PIPE` (`P`) | NAME START END LENGTH SIZE [FITTINGS ...] |
| `PC` | SOURCE, then NAME START END for each copy - copies of a pipe |
| `CHANGEPIPE` (`CHP`) | PIPE LENGTH SIZE [FITTINGS ...] - changes a pipe (a copy keeps the original) |
| `EQV` | PIPE LENGTH - an equivalent length added to a pipe |
| `NODE` (`N`) | NAME ELEVATION |
| `NC` | SOURCE NAME [NAME ...] - copies of a node, whatever defined it |
| `WATER` (`W`) | NAME ELEVATION STATIC [FLOW PRESSURE ...] - a water supply; any number of them |
| `SPRINKLER` | NAME ELEVATION MINFLOW K |
| `HYDRANT` | NAME ELEVATION MINFLOW K |
| `HREEL` | NAME ELEVATION MINFLOW K - a hose reel |
| `FIXEDFLOW` | NAME NODE FLOW [MINPRESSURE] |
| `PUMP` | NAME IN OUT CHURN FLOW PRESSURE [FLOW PRESSURE ...] |
| `BP` | PIPE CHURN FLOW PRESSURE [...] - a pump in a pipe |
| `BFP` | PIPE FLOW LOSS [FLOW LOSS ...] - a backflow preventer in a pipe |
| `PRV` | PIPE FLOW LOSS [FLOW LOSS ...] - a pressure reducing valve in a pipe |
| `OPP` | PIPE DROP [CD] - an orifice plate sized for that drop |
| `OFD` | PIPE BORE [CD] - an orifice plate of that bore; the drop is calculated |
| `PRA` | PIPE RATIO [MININLET] [BAND] - a pressure ratio valve, ratio written `3:1` or `1.5`; BAND in % of the inlet pressure, 5 if not given; MININLET 0 for none |

**Outlets.**  `SPRINKLER`, `HYDRANT` and `HREEL` define their node and the
outlet on it together, so the report counts sprinklers apart from hydrants and
hose reels.  MINFLOW is the least flow the outlet must give; a negative MINFLOW
is instead the least pressure (`-50` is 50 kPa).  A K of 0 turns the outlet
off and leaves the node.

**Devices in pipes.**  `BP`, `BFP`, `PRV`, `OPP`, `OFD` and `PRA` name the pipe they
sit in, one device to a pipe.  The device is placed at the pipe's start: PHCP
splits the pipe at a node named `<pipe>~` at the start node's elevation, and
the device appears in the report as `<pipe>.<device>` (`51.BP`).  A `BFP` or
`PRV` with one pair at flow 0 (`BFP 51 0 35`) is a loss that does not vary with
flow.  An orifice plate takes its pipe's nominal size and its bore from the
pipe and fitting database.

**Pressure ratio valves.**  A `PRA` holds its outlet at its inlet pressure
divided by its ratio: 1500 kPa into a 3:1 valve gives 500 kPa out.  The drop
depends on the inlet pressure, which the loop balance only knows once it has
converged, so the solver sets each valve's drop from the solved inlet pressure
and solves again until the drops settle.  Section 10 of the report shows each
valve's ratio, inlet and outlet pressure.  The report warns if the inlet is
below the MININLET given (the manufacturer's minimum, 200 kPa screwed or
300 kPa flanged in the data supplied), if flow runs backwards through a valve,
or if the drops did not settle.

The valve holds its ratio only to within a band - "within +/- 5% of the inlet
pressure" in the manufacturer's data - so 1500 kPa into a 3:1 valve gives
anywhere from 425 to 575 kPa.  The calculation uses the BOTTOM of the band,
outlet = inlet x (1/ratio - band), so every outlet downstream is checked
against the least pressure the valve can be relied on to give (decided 28
October 2026).  Section 10 shows each valve's band, and the report solves the
network once more with every valve at the TOP of its band and states the
highest pressure that gives downstream, for the pipe, fitting and head
ratings.  A valve with other data takes its own band, `PRA P2 3:1 300 3`;
`0` is the nominal ratio exactly.  A band wider than the ratio passes - 40 %
on a 3:1 valve, which passes 33 % - is refused.

**Sizes and fittings.**  Under `USE <PIPETYPE>` the size is the nominal size
and the bore comes from the database; under `USE BORE` it is the bore.  Before
any `USE`, pipes are `USE BORE 120`.  Fittings follow the size, one code each
with an optional count - `2E T GV` - in the database codes, plus the short
forms `G` (gate valve, `GV`), `C` (check valve, `CV`) and `B` (butterfly
valve, `BV`).  Fittings need a pipe type, so on a `USE BORE` pipe they are an
error: give the allowance with `EQV` instead.

**Units.**  One `UNITS` line per quantity; anything not set takes the office
default.  Velocity is reported in m/s.

| quantity | units | default |
|---|---|---|
| `LENGTH` - pipe and equivalent lengths | MM CM M IN FT | MM |
| `ELEVATION` | MM CM M IN FT | M |
| `SIZE` - nominal sizes, bores, roughness | MM IN | MM |
| `PRESSURE` | KPA BAR MPA PSI M (head) | KPA |
| `FLOW` | LPM LPS M3H GPM | LPM |
| `KFACTOR` | LPM/KPA LPM/BAR LPS/KPA LPS/BAR GPM/PSI | LPM/KPA |

A length or elevation may carry its own unit: `12M`, `300MM`, `2.5CM`,
`14'3"`.  The K-factor default is the unit the office's existing data uses
(K 8 for a K80 head), confirmed as the default on 28 October 2026.

**How it is read.**  Each `.phc` command is translated into internal rows
that mean the same thing, and each row is added to the network by one network
builder (`HardyCross/Phc.pm` translates, `HardyCross/Parse.pm` builds) - an
internal step a user never sees.  Every hydraulic check and default
therefore exists once.  The `.phc` reader checks the language itself - command
words, fields, numbers, units, names - and converts lengths and elevations to
metres, using the engine's own unit factors for everything else.  Every error
carries the `.phc` line number, including the network builder's own, named
from the line the row was made from.

**Fixed flows.**  A `FIXEDFLOW` takes exactly its FLOW whatever the pressure -
it is a nodal demand, outside every loop - and its MINPRESSURE is the pressure
it needs to deliver that flow.  The minimum is CHECKED:

- Section 5 shows it as the node's REQUIRED P;
- Section 7 lists the fixed flow after the outlets, K shown as `fixed`, PASS
  or FAIL on pressure alone (its flow cannot fall short - it is set);
- the governing outlet and the demand point count it like any other outlet,
  so a fixed flow with the least pressure to spare governs, and the demand
  point is the supply pressure at which it receives exactly its minimum.

The flow itself is not reduced when the pressure is short; the report shows
the shortfall as a FAIL instead.  (Until this change the minimum was read and
thrown away.)  Solved flows and
pressures are unchanged by it; the compliance rows, and the demand point of a
model whose fixed flow governs, are new.

**Examples.**  Every example is supplied as `.phc`.  Its solved pipe flows and
node pressures are frozen in `tools/baseline/<example>.expected`, taken from an
independent description of the same network solved at tight tolerances, and
`tools/test_phc.pl` requires the example to reproduce them to 1e-4.  Example 04,
the 1000-node grid, has only its pipe and node names frozen: its solve takes many
minutes, so it is checked to hold every pipe and node, and solved only with
`--full`.

**Line checking.**  `HardyCross::Phc::check_line` checks one line as it is
typed, without Tk, for the text editor: whether it is complete, the command's
field template and which field the cursor is in, the pipe types or fitting
codes from the database for a pick list, and a proposed next line.  A line the
language accepts is also parsed as its internal row, so a size the pipe type does
not make, or a fitting the database lacks, shows on the line as it is typed.

## Pipe and fitting database

`data/pipes.dat` holds the pipe dimensions and fitting equivalent lengths.  It
is a plain text file and is meant to be edited: add a pipe type, a size or a
fitting, or correct a value - in the editor's DATABASE tab, or with any text
editor.  The file's header explains the record format.

**The DATABASE tab.**  The database as four tables - pipe types, pipe sizes,
fittings, K' factors - with a filter.  It opens read-only; ticking EDIT THE
DATABASE lets a row be changed, added or deleted.  SAVE CHANGES checks every
row (numbers where numbers belong or DASH, a size only for a pipe type that
exists, no two rows for the same thing, a bore smaller than its OD), reads the
whole file with the solver's own reader before it replaces the old one, dates
the DATASET line, and makes it the database in use; a model must then be
validated again before it is calculated.  Comments, blank lines and order are
kept, and a field not edited keeps its exact text.

**Where the database is.**  In order, the first that is set or exists:

| | |
|---|---|
| a team folder | set on each machine with CHOOSE FOLDER... in the DATABASE tab (or the environment variable `PHCP_DATABASE_DIR`) - for example a folder on a network drive that a whole team points at.  If that folder cannot be read, the program stops and says where; it does not quietly use other data |
| beside the program | `data\pipes.dat` next to `phcp.exe` - an office copy that wins over the built-in one; the DATABASE tab saves here when the built-in copy is packed inside the `.exe` |
| built-in | the copy the program ships with |

The choice is kept per machine in `%APPDATA%\PHCP\settings.ini` on Windows
(`~/.config/phcp/settings.ini` elsewhere).  CHOOSE FOLDER on a folder with no
`pipes.dat` offers to copy the database in use there, which is how a team
starts its shared database; USE BUILT-IN goes back.  When two people edit the
shared database at once, the second SAVE is refused - the file changed after
they opened it - rather than overwrite the first person's change.

101 pipe sizes across eight pipe types, 219 fitting equivalent lengths, and 19
PPI factors for PE.

**Traceability.**  Because the data can change, every report states the
database's DATASET name and date, its file name and the SHA-256 of the exact
bytes read (Section 4) - with its full path when it is a team folder's or an
office copy, so shared data and a local copy cannot be confused.  A
calculation can always be tied back to the data it used.  Change the DATASET line whenever you change the content, and re-run
`tools/test_pipedata.pl` after any edit.

**Where it is read from**, first found wins: `data/pipes.dat` beside the source;
inside a packaged `.exe`; `data/pipes.dat` beside the `.exe`.  The last lets the
office update the data without rebuilding the program.

### Writing a pipe

```
USE   ASAM
PIPE  P1  A  B  12000  100  T 2E G CV
```

With a pipe type the size is the NOMINAL size; the bore comes from that
type's PIPE records in the database.  Fittings take the office form `2E,1T`,
the compact form `1E1T`, or separate codes `2E T`.  A pipe with no
type works as before, with the bore entered directly - and the report says it
carries no database provenance.

### Which fitting source applies

Each FIT record starts with a source code; the report's SRC column uses the
same codes.

| pipe type | source code | fitting source | corrections |
|---|---|---|---|
| ASAM, ASAH, S40 to DN150 | AS | AS 2118.1:2017 Table 14.11.1 | C and diameter, against AS 1074 Medium |
| S20, S40 from DN200 | FM | FM Global DS 3-0 Table 12(a) | C and diameter, against Schedule 40 |
| CPVC | CPVC | BlazeMaster IH-1900 Table F2 | none |
| PE11, PE9 | PPI | PPI Handbook, Le = K'd | none |
| PVCM16 | AS / FM | fallback | both - status ASSUMPTION_REQUIRED |

C multiplier: (C / 120)^1.85.  Diameter modifier: (d installed / d basis)^4.87.

A dash, an unsupported size or an unknown fitting is `DATA_REQUIRED`: the
solve stops and names the component.  It is never zero and never interpolated.

Each table row has its own code, so nothing is folded silently:

| code | fitting | code | fitting |
|---|---|---|---|
| E | standard elbow - SCREWED at DN200+ (office decision) | GV | gate valve, open |
| EF | flanged / medium sweep elbow (FM) | GV75 GV50 GV25 | gate valve part open (FM) |
| EL | long radius elbow | CV | swing check / alarm valve |
| E45 | 45 deg elbow | CVM CVB | mushroom / butterfly check (AS) |
| T | tee, flow turned 90 deg | BV AV | butterfly / angle valve (FM) |
| TR CPL | tee run, coupling - not counted | GLV | globe valve (PE) |

**`E` is the screwed elbow** - an office decision, 21 September 2026.  FM
publishes the screwed elbow only to DN300, so `E` on a DN350+ main returns
`DATA_REQUIRED` and the message says to use `EF` for a flanged, grooved or
medium-sweep elbow.

`OPTION FITTING_BASIS STANDARD` (FITTING LENGTHS in the editor's PROJECT tab)
is the "published Standard alone" election:
AS 2118.1 values unmodified, no diameter modifier, and the report states it.
`CORRECTED`, the default, applies both corrections.

### Database checks

`tools/test_pipedata.pl`, 35 checks: C multipliers and diameter modifiers
reproduced to three decimals at a spread of types and sizes; every pipe K in
the database reproduced from its own bore and C (worst 0.4%); a hand-checked
DN300 Schedule 20 tee (20.748 m, exact modifier 1.13378); and every rule above.
If an edit to the database makes it fail, either the edit is wrong or the
expected value must be re-derived by hand - never just changed to match.

## The text editor

`perl phcp_editor.pl [model.phc]`

```
+------------------------------------------------------------------+
| NEW OPEN SAVE | VALIDATE  CALCULATE | WRITE REPORT    [ status ] |
+------------------------------------------------------------------+
| NETWORK | PROJECT                                                 |
|  USE PIPE PC ... | NODE NC WATER ... | PUMP BP BFP ...  (strip)   |
|  +----+--------------------------------------+ +---------------+ |
|  |  1 | WATER     SUP 0 650                  | | ERRORS        | |
|  |  2 | NODE      R1 4.5                     | | WARNINGS      | |
|  +----+--------------------------------------+ | NODES         | |
|  status bar: the field template | the line's results             |
+------------------------------------------------------------------+
| VALIDATION | PIPES | NODES | OUTLETS | REPORT      [ ] HIDE ...   |
+------------------------------------------------------------------+
```

A white, flat window: one-pixel grey rules instead of bevels, blue and
black used only to highlight, red for what is wrong.  Monospace for the
model and the results, a plain sans-serif for the window's own labels, and
everything in capitals.

**The editor holds the network only.**  The title, project details, units,
method and options are set in the PROJECT tab.  The `.phc` file still holds
them, as lines at its head, so a saved file is complete and `phcp.pl` reads
it unchanged; the editor takes them out when a file is opened and writes
them back when it is saved.  A setting typed into the network is marked as
an error that says so.

**VALIDATE before CALCULATE.**  CALCULATE (F5) is available only when the
model is exactly as it was when it last passed VALIDATE (F4); any change, in
the editor or the PROJECT tab, turns it off again.  VALIDATE checks every
line, the settings, nodes undefined or unconnected, and the network's
structure as the solver will, and lists each problem in the VALIDATION tab:

| column | holds |
|---|---|
| WHERE | the line, or PROJECT TAB |
| FIELD | the field at fault: SIZE, START, MINFLOW, ... or the PROJECT tab field |
| WHAT IS WRONG | the problem |
| WHY | what the program needs and why, in plain words - and for a line that stops short, how the command is written |

Each fault is marked on its own field in the editor; a click on a row goes
there and selects it.

| feature | behaviour |
|---|---|
| syntax colours | command words blue and bold; a name being defined black and bold; references black; numbers dark blue; pipe types, fittings and units blue; comments grey italic.  A line in error has a pale red band and a red line number |
| line numbers | a gutter beside the editor, scrolled with it; the cursor's line in black.  A click on a number goes to the line |
| command strip | the network commands, in their three groups.  A click starts a line with that command |
| status bar | the field template of the current command, the field the cursor is in highlighted; then the line's error, or after a calculation the element's results |
| proposals | after Enter the likely next line is shown greyed: the same command, names stepped past any already used (P7 to P8), a pipe starting where the last one ended.  Enter or Tab accepts it; typing anything else discards it |
| pick list | Ctrl+Space in a `USE` type or a pipe's fittings lists the codes with descriptions |
| ERRORS / WARNINGS / NODES | live as you type: lines the reader refuses; the last calculation's warnings; nodes undefined or unconnected.  A click goes to the line, or to the PROJECT tab field |
| PROJECT tab | PROJECT DETAILS and DESIGN BASIS (the report's cover sheet), UNITS (each a drop-down, the default marked), CALCULATION (each option with a plain label, its `.phc` name beside it, and a line saying what it does and what a blank means; the rarely needed ones under SOLVER - ADVANCED).  Text is kept in capitals; the tab scrolls |
| PIPES | 21 columns: NAME, SNODE, ENODE, NOM, I.D., MAT, C (C factor, or absolute roughness under `METHOD DW`), L, F, T, FIT K, Q, PF, PF/M, PE, PS (loss across a device in the pipe), PV, VEL, RE, F (Darcy) and FORMULA.  A right click on the headings opens the column chooser; NAME to PF, PS and VEL are shown at first |
| NODES, OUTLETS | every node with its type, elevation, pressure, discharge, requirement and margin; every outlet and fixed flow with the required and achieved flow and pressure, the margin and PASS or FAIL |
| sorting | a click on a heading sorts on it, a second click reverses; the heading shows the direction |
| HIDE | HIDE NON-FLOWING PIPES and HIDE INACTIVE NODES, each with the count of rows it would hide beside it - (NONE), and greyed, when every pipe flows or every node is active |
| files | NEW, OPEN, SAVE, SAVE AS, WRITE REPORT (Ctrl+R, `.pdf` or `.txt`; it validates and calculates first if needed).  Any file but a `.phc` is refused with the reason |
| undo | Ctrl+Z and Ctrl+Y.  A proposal that was only offered is never part of the undo record |
| GRAPH tab | a Q^1.85 water supply graph from figures typed in, independent of the model.  See Water supply graph |
| DATABASE tab | the pipe and fitting database: view, filter, and - once EDIT THE DATABASE is ticked - change; choose a team folder for it.  See Pipe and fitting database |
| dividers | the grey bands between the editor, the lists and the results can be dragged |
| mouse wheel | scrolls the pane under the pointer, whichever has the keyboard focus |
| sharp on any screen | the editor tells Windows it is DPI-aware, so at 125 or 150 % scaling it is drawn at the screen's resolution rather than stretched; fonts are sized in points, and padding and widths are scaled to match |

The window is thin.  Every decision it shows - a line's status, the three
lists, the proposal, the pick list, what VALIDATE finds and why, the tables
and their sorting - is made by
`HardyCross/Editor.pm`, which has no Tk in it and calls the same `.phc`
reader the solver uses, so the editor cannot call a line good that the solve
refuses.  `tools/test_editor.pl` checks those decisions headless;
`tools/test_editor_window.pl` drives the window itself under a virtual
display (it runs itself under `xvfb-run` when there is no display, and says
SKIPPED when there is neither display nor `xvfb-run`).  Both have been run on
Linux with Tk 804.036.  The window has been run on Windows 11
(see Windows below); the test suites themselves have been run on Linux only.

The spreadsheet front end it replaces, `phcp_gui.pl`, is retired with its
tests, and Tk::TableMatrix is no longer needed.

## Water supply graph

The editor's GRAPH tab draws a water supply graph on Q^1.85 paper from figures
typed in - before a network is modelled, or from a flow test and a pump's data
sheet.  It is independent of the model: nothing is read from the network or
from a calculation, and nothing in it changes them.  Flows in L/min, pressures
in kPa.

| curve | what it is |
|---|---|
| A | the water supply as measured - a flow test - at least two points |
| B | the loss from the supply to the datum the duties are stated at (pipework, meter, backflow device, height).  One point is a loss line through the origin, rising as Q^1.85; none is no loss |
| C | the supply available at the datum: A - B |
| D | a pump curve from churn (0 L/min) out; or none |
| E | the supply available at the datum with the pump: C + D |

Up to ten DUTY points - a flow needed at a pressure, with a number and a
description - are each compared with the curve designed against (E with a
pump, C without): the pressure that curve has at the duty's flow, and the
margin, or the shortfall.  Each curve passes through its points and is
straight between them on this paper, by the solver's own curve rule (the same
as a supply or pump in a model); beyond its last point it continues straight
in flow.  The axes are worked out from the figures unless set.

The tab has the figures on the left and the graph on the right, redrawn as
they are typed, with a key under it giving each duty's margin.  A problem -
a flow with no pressure, flows not rising row by row, a gap between rows, a
pump not starting at churn, a letter O for a zero - is listed under the
graph with its row; its fields are shaded, and a click on it goes to the
field.  PRINT TO PDF writes the sheet: A4 landscape in the report's typeface
and frame, the graph on the left; on the right the key, the duty points with
the pressure each has and its margin, and the points entered.  The curve
designed against is the heavy line.  SAVE GRAPH and OPEN GRAPH keep the
figures in a `.phg` file - plain text, a keyword and its fields on each line
(`PROJECT`, `JOB`, `DATE`, `BY`, `PMAX`, `PSTEP`, `QMAX`, `A`, `B`, `D`,
`DUTY <flow> <pressure> <number> <description>`).  `examples/10_supply_graph.phg`
is a town main with a booster pump, checked against a sprinkler and a hydrant
duty.

`HardyCross/Graph.pm` makes every decision - what is wrong, where the curves
go, what the sheet shows - with no Tk in it; `tools/test_graph.pl` checks
the curves against figures worked by a formula written out in the test,
every refusal, the file, and the sheet's PDF (where the plot, curves, points
and duties are drawn).

## The report: cover sheet

Page 1 is a submittal cover modelled on the NFPA style, adapted for Australia:

- **Details** - company, address, licence, designer, checker, date, revision,
  job name, project, job number, location, model file.
- **Design data** - standard, hazard class, design density (mm/min), area per
  sprinkler (m2), area of operation (m2, or sprinklers x area if not entered),
  sprinklers flowing, pipe data source.
- **Flow data** - total sprinkler flow, hydrant and hose reel flow where the
  model has any, total water required at the supply, base of riser flow and
  pressure, pressure at the supply connection.
- **Density check** - minimum flow per sprinkler (density x area), the lowest
  sprinkler flow and which head, computed density, and whether it meets.
- **Supply** - pressure available, demand pressure, cushion, maximum velocity.
- **Authority** having jurisdiction, and phone.

No hose stream allowance is included; Australian practice does not add one to a
sprinkler calculation.

Flow and density figures are given at two conditions, side by side: the DEMAND
POINT, where the governing outlet receives exactly its minimum (the design
condition), and the OPERATING POINT, with the supply connected.  The schedules
are at the operating point, and the cover says so.

The fields are entered as `.phc` `TITLE` and `PROJECT` lines -
`PROJECT HAZARD ORDINARY HAZARD 1` - which the editor's PROJECT tab writes:

```
TITLE     LEVEL 2 SPRINKLER RANGE
PROJECT   COMPANY HYCADIA PTY LTD
PROJECT   ADDRESS 1 EXAMPLE ROAD, SYDNEY NSW 2000
PROJECT   LICENCE NSW DBP DEP0000000, FPAS F000000X
PROJECT   LOCATION 12 EXAMPLE STREET, SYDNEY NSW 2000
PROJECT   HAZARD ORDINARY HAZARD 1
PROJECT   DENSITY 5.0                  // MM/MIN
PROJECT   AREA_PER_SPRINKLER 12.0      // M2
PROJECT   AREA_OF_OPERATION 72.0       // M2, OPTIONAL
PROJECT   BASE_OF_RISER R1             // A NODE IN THE MODEL
PROJECT   AUTHORITY FIRE AND RESCUE NSW
PROJECT   AUTHORITY_PHONE 02 9265 2999
```

Long values wrap on the cover rather than being cut off.

## Page layout

In the PDF every numbered section starts on a page of its own, so any part of
the calculation can be found, filed or replaced by itself.  The cover keeps
page 1.

## The report: pipe schedule

Section 6 is laid out as the NFPA hydraulic worksheet - four lines per pipe,
the form fire authorities are used to reading:

```
 PIPE     BEG          ELEV   FLOW         K-FACTOR           LENGTH       C-FACTOR      PRESSURE
 NO.                    (m)   L/min        FITTINGS           FTG m        FRI-LOSS      (kPa)
 TYPE     END          ELEV                DIAMETER mm        TOTAL m      (kPa/m)
          SUP         0.000   q=        -  K= -               L=    12.00                Pt    650.0  Pt    650.0
 M1                           Q=   3576.8  F= 1T,2E,1GV,1CV   F=    19.40  C= 120        Pe    44.13  Pv    23.61
 ASAM                       Vel=     6.87  D= 105.10         TL=    31.40  4.6134        Pf   144.86  Pn    626.4
 DN100    R1          4.500                                                              Pt    461.0
```

Each pipe is written in the direction of flow, so BEG is upstream and Pt falls
by Pe + Pf.  q and K are an outlet's discharge and K-factor, printed once, beside
the node it belongs to - on the END line for a terminal head.  Pv and Pn are
shown in the NFPA manner for reference only: PHCP works in total pressure, as FM
DS 3-0 does, so every discharge is q = K sqrt(Pt), not K sqrt(Pn), and the
report says so under the table.

In the PDF each four-line pipe block moves to a new page whole, under repeated
headings, so a pipe's two end pressures are never on different pages.

## The report: flow path and supply

**Section 8, flow path to the governing outlet.**  The governing outlet is the
one with the least pressure to spare over its requirement - the first to fail as
the supply weakens, which is not necessarily the one furthest away on the
drawing.  The path is traced back from it, taking at each node the element that
brings in the most water, until a supply is reached.  The pressure is then
worked forward row by row, P TO = P FROM - PF - PE, and printed beside the
solved pressure.  Head is the same at a node by whatever route it is reached, so
the two must agree; the DIFF column is that check.

**Section 9, supply and demand.**  In a solved network the supply always meets
the system exactly, so the operating point shows no margin.  The DEMAND is the
pressure the system needs at the supply connection for the governing outlet to
receive exactly its minimum.  It is found by re-solving the whole network at
trial supply pressures - pump check valves and orifice sizing included - until
that outlet's margin is zero, then compared with what the supply has at that
flow.  A graph on a flow^1.85 axis shows the supply, the system curve (every
point a full solve), the demand point and the operating point.  With more than
one supply a single demand point is not defined, and the report says so rather
than inventing one.

With more than one supply, each supply has a graph of its own instead: its
curve, its system curve and its operating point, with no demand point.  The
system curve is the system as that supply sees it - the whole network re-solved
with this supply held at each of a range of pressures and the other supplies
connected as modelled.  Only solves that converge with water leaving this
supply are plotted: near no flow, with the other supplies pushing back, the
network may not settle.  Beside each graph the key gives the supply's
operating flow and pressure and its share of the flow of all the supplies.

Then all the supplies are graphed COMBINED, as pumps in parallel on one header
are: the supply curves added in flow at equal pressure (pressures are not
adjusted), each supply's own curve drawn lightly beneath and named.  The
COMBINED DUTY is found on the same basis - every supply held at one common
pressure, raised until the governing outlet receives exactly its minimum, and
the flows of all the supplies then added - and is marked D with its margin to
the combined curve.  Where the supplies run at one pressure in the modelled
network (within 2 %), their operating flows added are the combined operating
point O.  How the total splits between the supplies in the common-pressure
solve follows the pipework, not their curves, so it is not reported supply by
supply.  Where supplies connect at different points the combined figures
describe them taken together; each is also on its own graph.  Example 09 is
three pumps in parallel.

The graph is worked out once and drawn twice from the same numbers.  The text
report draws it in characters.  The PDF draws it on flow^1.85 graph paper:
gridlines at round flows crowding to the right as on printed hydraulic graph
paper, the supply as a solid line (straight between its entered points, which
are marked), the system curve dashed through its solved points, D and O
marked, the margin dimensioned at the demand flow, and beside it a key and the
four figures of Section 9.  Black on white in the report's typeface.
`tools/test_pdf.pl` checks that there is one drawn graph for each in the text,
that D and O sit where the report's own figures put them - worked independently from the printed numbers - and that every flow
label is at its place on the q^1.85 axis and clear of the next.

**Tested on the page.**  `tools/test_report_checks.pl` reads the printed report
as text and redoes every hand-check it tells the reader to make, with the
rounding of the printed figures allowed for: 351 checks across the seven
examples.  Its
first run found two faults that had been in the report since it was written:
outlet K printed with its unit factors inverted - 36 times too large in L/s and
bar, invisible in L/min and kPa - and loss per metre printed to four places,
too few in bar/m for PF/M x T to reproduce PF.

## PDF output

`phcp.pl model.phc report.pdf`, or FILE > WRITE REPORT in the editor with a
.pdf name.  The
PDF is a faithful print of the text report - the same characters in the same
columns, DejaVu Sans Mono 9 pt on A4 landscape - with a running header (title,
job, revision, date) and a footer (program, model, page n of m).  The rules of
the text report are drawn as ruled lines, and the supply graph is drawn (see
Section 9 above).  Both come from one call on the same solved network, so they
cannot disagree.

Page breaks follow the report's structure: a section heading is never left at
the foot of a page; a table that runs onto a new page repeats its column
headings under "(continued)"; the supply graph and short note paragraphs move
to the next page whole rather than split.

It is written in core Perl.  The typeface, DejaVu Sans Mono, is embedded from
`data/fonts` (its own licence is beside it, and LICENSE says so): Courier, the
one monospace face every PDF reader supplies, printed thin and looked dated.
The fonts are compressed into each PDF whole, about 400 kB a report; if the
font files are missing the PDF falls back to Courier rather than fail.
`tools/test_pdf.pl` checks each file the way the specification says a reader
should: every cross-reference offset landing on its object, stream lengths
exact, the page count true, every line of the text report present and every
rule drawn, the typeface embedded, and the graph as above.  Readers silently repair broken PDFs, so "it opened" is
not evidence; this is.

## Windows

`build_windows.bat` builds `phcp.exe` and `phcp_editor.exe` on a Windows PC
with Strawberry Perl installed: it fetches Tk and PAR::Packer from CPAN,
packages both programs with the pipe and fitting database inside, and runs a
smoke test on the `.phc` examples.

The packaging recipe has been run on Linux (PAR::Packer 1.061, Tk 804.036)
with the same module lists: from an empty folder the packaged `phcp` solved
examples and wrote a report identical to running from source, and the
packaged `phcp_editor` opened its window with a model loaded.  That run found
and fixed a defect - the packaged editor exited without opening a window.  It
was run again after the editor's layout changed, with the new Tk modules in
the list.
The Windows build was run on 28 October 2026 (Strawberry Perl 5.42.3, GCC
13.2.0): Tk compiled from the patched release, both programs built, and the
smoke test solved the examples and wrote a PDF.  The editor ran on Windows 11
at 150 % display scaling; what that run showed - blurred text, dividers too
thin to drag, the mouse wheel scrolling the wrong pane - is fixed as below.
The script also packs Win32::API, which the editor uses to be sharp on a
scaled display.

**The icon.**  `data/phcp.ico` is the PHCP icon - a blue tile with a two-loop
pipe network and a red sprinkler at the far node.  The editor sets the same
picture on its window and taskbar button itself, from PNG data held in
`phcp_editor.pl`, so it shows whether run from source or built.  The `.exe`
files themselves keep the default icon in Explorer: PAR::Packer removed its
`--icon` option, and rewriting a packed program's resources afterwards risks
the archive appended to it.

## Calling PHCP from another program

Other programs run `phcp.exe` and read what it prints - a program to call,
not a library to link (decided 28 October 2026).  AutoCAD does so now (see
below); Revit could later.

```
phcp.exe --json model.phc                     results as JSON on standard output
phcp.exe --json -                             the model read from standard input
phcp.exe --json model.phc --report out.pdf    ...and the report written too
```

The exit status says how it went - 0 converged, 1 solved but did not
converge (the results must not be used), 2 the model could not be read or
solved - and one JSON object is printed in every case, so a caller always has
something to read.  Abridged, for example 07:

```
{
   "interface" : 1,
   "status" : "converged",
   "converged" : true,
   "iterations" : 15,
   "units" : { "flow" : "L/min", "pressure" : "kPa", "length" : "m", ... },
   "database" : { "name" : "Hycadia pipe and fitting database", "sha256" : "0b74...", ... },
   "pipes" : [ { "id" : "M1", "from" : "SUP", "to" : "R1", "flow" : 3576.7756,
                 "velocity" : 6.871, "friction_loss" : 144.8598, ... }, ... ],
   "elements" : [ { "id" : "SUP", "kind" : "WATER", "from" : null, "to" : "SUP", ... } ],
   "nodes" : [ { "id" : "R1", "elevation" : 4.5, "pressure" : 461.0082 }, ... ],
   "outlets" : [ { "id" : "H2", "type" : "SPRINKLER", "required_pressure" : 50,
                   "pressure" : 182.2904, "margin" : 132.2904, "pass" : true, ... } ],
   "governing" : { "id" : "H2", "margin" : 132.2904 },
   "demand" : { "supply" : "SUP", "flow" : 1889.5674, "pressure" : 223.864,
                "available" : 650, "margin" : 426.136, "meets" : true },
   "warnings" : [],
   "errors" : [],
   "summary" : [
      "CONVERGED IN 15 ITERATIONS",
      "GOVERNING OUTLET H2: 182.3 KPA AGAINST 50.0 REQUIRED, MARGIN 132.3 KPA",
      "EVERY OUTLET PASSES",
      "SUPPLY SUP MEETS THE DEMAND: 650.0 KPA AVAILABLE AT 1889.6 L/MIN, 223.9 NEEDED",
      "5 PIPES OVER THE VELOCITY LIMIT"
   ]
}
```

Flows and pressures are in the model's own units, named in `units`; lengths
and elevations in m, sizes in mm, velocity in m/s.  A pipe's flow is signed,
positive from `from` to `to` as the model wrote it.  On an error, `status` is
`error` and `errors` holds the message with its `.phc` line.  The `summary`
is what a caller shows a user, one line to a string; the JSON is written one
value to a line, so even a caller with no JSON reader can find it line by
line, as AutoCAD's PHCPSOLVE does.  The contract is versioned - `interface`
is 1, a field is never renamed or changed in meaning under that number, and
new fields may be added - and is described in full in `HardyCross/Json.pm`.
`tools/test_json.pl` runs `phcp.pl` as a caller would and checks every
example's JSON against the plain output of the same solve.

## AutoCAD

`autocad/phcp_export.lsp` marks up a 2D AutoCAD 2026 drawing - supply, pipe
sizes, elevations, heads - and exports it as a `.phc`.  See
`autocad/AUTOCAD.md`.  `examples/08_autocad_export_format.phc` is a file in the
exact form the routine writes, and solves exactly as the same network did in
the old format.  The routine has not yet been run inside AutoCAD; what can be
checked without it is, by `tools/check_lisp.pl` - brackets matched, every
function it calls defined, every command it announces present.  PHCPSOLVE
exports the drawing, runs `phcp.exe --json` on it, and shows the summary.

## Supply, pump and loss curves

A `WATER` supply with flow/pressure points, a `PUMP` or `BP`, and a `BFP` or
`PRV` with more than one point are curves.  The curve passes exactly through
every point entered; between two points pressure is linear in Q^1.85 - the
scale water supply test results are plotted on, since a main loses pressure to
friction and Hazen-Williams friction goes as Q^1.85.  Beyond the last point,
and below the first, it continues in a straight line at the end slope, so a
solve that overshoots still has a well-behaved curve to work on.  The report
states this in Section 4 whenever a model has a curve.

Until 28 October 2026 a curve was a single quadratic: exact through two
points, but a least-squares fit through three or more that did not pass
through the points entered.  The change moved the results of every example
with a curve: example 02's town main by 232 L/min and 30 kPa (its supply has
three points), examples 03, 05 and 08 by under 8 L/min and 1 kPa.
`tools/test_curves.pl` checks the curves directly.

## Settings

`OPTION VEL_LIMIT 6` (VELOCITY WARNING LIMIT in the PROJECT tab) sets the velocity flagged
in validation and the report.
It is a setting, not a requirement of AS 2118.1, and the report prints the value
in force and whether it was set in the model or is the program default.

## The report

132-column monospace, 7-bit ASCII only - it survives printing, email, pasting
and diffing unchanged.  Sections 2, 3 and 4 state the pipe types and standards,
every fitting allowance with its source and multipliers, the assumptions and
elections, and the database used.  Every figure can be checked by hand from
others on the page, and the report says which check to make.

## Verification

| suite | result |
|---|---|
| robustness, 387 cases incl. 300 fuzz (prototype suite, not in this repository) | 0 problems |
| extreme conditions, 44 cases (prototype suite, not in this repository) | 0 problems |
| direct comparison with the C++ engine (before the Q^1.85 curves - not re-run; the C++ engine is not in this repository) | worst 0.005 L/min, 0.0049 kPa |
| pipe and fitting database | 35 / 35 |
| `.phc` language, line checker and pressure ratio valves | 266 / 266 |
| AutoCAD exporter, structure | 5 / 5 |
| JSON interface | 81 / 81 |
| supply, pump and loss curves, and supplies combined | 18 / 18 |
| report hand-checks, 8 models | 419 / 419 |
| PDF structure, typeface and graphs, 8 models | 158 / 158 |
| text editor logic, headless | 117 / 117 |
| text editor window, under Xvfb | 130 / 130 |
| water supply graph | 43 / 43 |
| database editing and location | 37 / 37 |
| invariance stress | 9 584 / 9 584 |

## Stress testing

`tools/stress_invariance.pl` needs no reference program.  It takes a random
looped network and describes it differently -- elements shuffled, pipes
reversed, the whole site raised, a pipe split in two, nodes renamed, every
quantity in different units, the same text solved twice -- and demands the
same answer every time.  It also fuzzes the pipe database resolver with 4000
fitting strings.

| run | result |
|---|---|
| 60 random networks x 7 transforms + resolver fuzz | 9 584 checks, 0 failed |
| worst disagreement, any transform | 2e-5 L/min |

### Scale

| model | wall time | iterations |
|---|---|---|
| 10 x 10 grid, 100 nodes | 0.7 s | 146 |
| 16 x 16 grid, 256 nodes | 10 s | 600 |
| 20 x 25 grid, 500 nodes | 86 s | 3441 |
| 20 x 50 grid, 1000 nodes | over 200 s | - |
| tree, 1000 nodes | 17 s | 2630 |
| tree, 2000 nodes | over 200 s | - |

Memory stays at 12-19 MiB.  A design-area calculation of a few hundred nodes
solves in seconds; a 1000-node gridded system is beyond PHCP's practical limit
(the C++ reference does it in about 17 s).

## Convergence

Loops come from a spanning tree grown from a central node.  PHCP builds that
tree exactly as the C++ reference does -- neighbours visited in reverse element
order, the lowest-numbered farthest node taken as the centre -- and so took
IDENTICAL iteration counts on every model compared (before the Q^1.85 curves,
which change the iterations of models with curves - example 02 now takes 7):

    10x10 grid 146   16x16 grid 600   5x5 grid 138   pump case 12
    01 5   02 9   03 11   05 19   06 2

Before that was matched, PHCP grew a different tree on gridded networks and
needed twice the iterations for the same answer (1231 vs 600 on a 16x16 grid).
On a tree network the pipework forces the spanning tree, which is why the two
always agreed there.  The remaining speed gap is Perl's cost per iteration,
not the method.

## Caveats

AS 1074 Medium as the basis bore for AS 2118.1 Table 14.11.1 is an office
assumption; the Standard does not state one.  Orifice sizing uses a fitted
model, not the standard's tables.  Agreement with other
implementations does not validate a reading of a standard.  The database is
user editable: a value changed in it is only as good as the source it was
taken from.
