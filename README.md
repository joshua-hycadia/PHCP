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
perl phcp_viewer.pl model.phc            # read-only results viewer
perl tools/test_phc.pl                   # verify the .phc language
perl tools/test_editor.pl                # verify the editor's logic
perl tools/test_editor_window.pl         # drive the editor window (uses xvfb-run if no display)
perl tools/test_pipedata.pl              # verify the pipe and fitting database
perl tools/stress_invariance.pl 60       # invariance stress on 60 random networks
```

`phcp.pl` and the viewer, `phcp_viewer.pl`, read either input format; the
extension decides which.  `.phc` is the command language described below.
`.hcx` is the older block format, still read so the AutoCAD exporter keeps
working; every example is supplied in both, the `.hcx` as the baseline the
`.phc` is tested against.  The editor works in `.phc` only.

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
| `PRA` | PIPE RATIO [MININLET] - a pressure ratio valve, ratio written `3:1` or `1.5` |

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
or if the drops did not settle.  The nominal ratio is used; the valve holds it
to within 5 % of the inlet pressure in the manufacturer's data.

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
(K 8 for a K80 head); it is not yet confirmed as the default.

**How it is read.**  Each `.phc` command is translated into the `.hcx` rows
that mean the same thing, and the rows are read by the same parser that reads
a `.hcx` file (`HardyCross/Phc.pm`).  Every hydraulic check and default
therefore exists once.  The `.phc` reader checks the language itself - command
words, fields, numbers, units, names - and converts lengths and elevations to
metres, using the engine's own unit factors for everything else.  Every error
carries the `.phc` line number, including the parser's own, mapped back from
the translated row.

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
the shortfall as a FAIL instead.  (In `.hcx`, `FIXEDFLOW ... MINP=` or `P=`.
Until this change the minimum was read and thrown away.)  Solved flows and
pressures are unchanged by it; the compliance rows, and the demand point of a
model whose fixed flow governs, are new.

**Examples.**  Every example is supplied as `.phc`, with its `.hcx` original
kept as the baseline: `tools/test_phc.pl` solves both and requires the same
pipe flows and node pressures.  In `.phc` a supply or outlet takes its node's
name, a device sits in a pipe of no length where the `.hcx` had it between two
nodes, and example 04's sprinkler on the supply node has a node of its own -
so the reports differ in those names, not in the numbers.

**Line checking.**  `HardyCross::Phc::check_line` checks one line as it is
typed, without Tk, for the text editor: whether it is complete, the command's
field template and which field the cursor is in, the pipe types or fitting
codes from the database for a pick list, and a proposed next line.  A line the
language accepts is also parsed as its `.hcx` row, so a size the pipe type does
not make, or a fitting the database lacks, shows on the line as it is typed.

## Pipe and fitting database

`data/pipes.dat` holds the pipe dimensions and fitting equivalent lengths.  It
is a plain text file and is meant to be edited: add a pipe type, a size or a
fitting, or correct a value, with any text editor.  The file's header explains
the record format.

101 pipe sizes across eight pipe types, 219 fitting equivalent lengths, and 19
PPI factors for PE.

**Traceability.**  Because the data can change, every report states the
database's DATASET name and date, its file name and the SHA-256 of the exact
bytes read (Section 4).  A calculation can always be tied back to the data it
used.  Change the DATASET line whenever you change the content, and re-run
`tools/test_pipedata.pl` after any edit.

**Where it is read from**, first found wins: `data/pipes.dat` beside the source;
inside a packaged `.exe`; `data/pipes.dat` beside the `.exe`.  The last lets the
office update the data without rebuilding the program.

### Writing a pipe

```
USE   ASAM                                 // .phc
PIPE  P1  A  B  12000  100  T 2E G CV

P1  A  B  12.0  100  TYPE=ASAM  FIT=1T,2E,1GV,1CV        ! .hcx
```

With a pipe type the size is the NOMINAL size; the bore comes from that
type's PIPE records in the database.  Fittings take the office form `2E,1T`,
the compact form `1E1T`, or (in `.phc`) separate codes `2E T`.  A pipe with no
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

`OPTION FITTING_BASIS STANDARD` (`.hcx`: `OPTIONS FITTING_BASIS STANDARD`)
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
| PROJECT tab | PROJECT DETAILS and DESIGN BASIS (the report's cover sheet), UNITS (each a drop-down, the default marked), CALCULATION (METHOD and the options; a blank option takes its default).  Text is kept in capitals |
| PIPES | 21 columns: NAME, SNODE, ENODE, NOM, I.D., MAT, C (C factor, or absolute roughness under `METHOD DW`), L, F, T, FIT K, Q, PF, PF/M, PE, PS (loss across a device in the pipe), PV, VEL, RE, F (Darcy) and FORMULA.  A right click on the headings opens the column chooser; NAME to PF, PS and VEL are shown at first |
| NODES, OUTLETS | every node with its type, elevation, pressure, discharge, requirement and margin; every outlet and fixed flow with the required and achieved flow and pressure, the margin and PASS or FAIL |
| sorting | a click on a heading sorts on it, a second click reverses; the heading shows the direction |
| HIDE | HIDE NON-FLOWING PIPES and HIDE INACTIVE NODES |
| files | NEW, OPEN, SAVE, SAVE AS, WRITE REPORT (Ctrl+R, `.pdf` or `.txt`; it validates and calculates first if needed).  Any file but a `.phc` is refused with the reason |
| undo | Ctrl+Z and Ctrl+Y.  A proposal that was only offered is never part of the undo record |

The window is thin.  Every decision it shows - a line's status, the three
lists, the proposal, the pick list, what VALIDATE finds and why, the tables
and their sorting - is made by
`HardyCross/Editor.pm`, which has no Tk in it and calls the same `.phc`
reader the solver uses, so the editor cannot call a line good that the solve
refuses.  `tools/test_editor.pl` checks those decisions headless;
`tools/test_editor_window.pl` drives the window itself under a virtual
display (it runs itself under `xvfb-run` when there is no display, and says
SKIPPED when there is neither display nor `xvfb-run`).  Both have been run on
Linux with Tk 804.036; the window has not yet been run on Windows.

The spreadsheet front end it replaces, `phcp_gui.pl`, is retired with its
tests, and Tk::TableMatrix is no longer needed.

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
`PROJECT HAZARD Ordinary Hazard 1` - or in a `.hcx` model's PROJECT block:

```
PROJECT
  COMPANY            Hycadia Pty Ltd
  ADDRESS            1 Example Road, Sydney NSW 2000
  LICENCE            NSW DBP DEP0000000, FPAS F000000X
  LOCATION           12 Example Street, Sydney NSW 2000
  HAZARD             Ordinary Hazard 1
  DENSITY            5.0         ! mm/min
  AREA_PER_SPRINKLER 12.0        ! m2
  AREA_OF_OPERATION  72.0        ! m2, optional
  BASE_OF_RISER      R1          ! a node in the model
  AUTHORITY          Fire and Rescue NSW
  AUTHORITY_PHONE    02 9265 2999
END
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

**Tested on the page.**  `tools/test_report_checks.pl` reads the printed report
as text and redoes every hand-check it tells the reader to make, with the
rounding of the printed figures allowed for: 659 checks across fourteen models
(every example, in `.hcx` and in `.phc`).  Its
first run found two faults that had been in the report since it was written:
outlet K printed with its unit factors inverted - 36 times too large in L/s and
bar, invisible in L/min and kPa - and loss per metre printed to four places,
too few in bar/m for PF/M x T to reproduce PF.

## PDF output

`phcp.pl model.phc report.pdf`, or FILE > WRITE REPORT in the editor with a
.pdf name.  The
PDF is a faithful print of the text report - the same characters in the same
columns, Courier 9 pt on A4 landscape - with a running header (title, job,
revision, date) and a footer (program, model, page n of m).  Both come from
one call on the same solved network, so they cannot disagree.

Page breaks follow the report's structure: a section heading is never left at
the foot of a page; a table that runs onto a new page repeats its column
headings under "(continued)"; the supply graph and short note paragraphs move
to the next page whole rather than split.

It is written in core Perl.  The report is 7-bit ASCII by construction, so it
needs only Courier - one of the fourteen fonts every PDF reader supplies - and
nothing is embedded or installed.  `tools/test_pdf.pl` checks each file the way
the specification says a reader should: every cross-reference offset landing on
its object, stream lengths exact, the page count true, and every line of the
text report present.  Readers silently repair broken PDFs, so "it opened" is
not evidence; this is.

## Windows

`build_windows.bat` builds `phcp.exe` and `phcp_editor.exe` on a Windows PC
with Strawberry Perl installed: it fetches Tk and PAR::Packer from CPAN,
packages both programs with the pipe and fitting database inside, and runs a
smoke test on a `.hcx` and a `.phc` example.

The packaging recipe has been run on Linux (PAR::Packer 1.061, Tk 804.036)
with the same module lists: from an empty folder the packaged `phcp` solved
examples and wrote a report identical to running from source, and the
packaged `phcp_editor` opened its window with a model loaded.  That run found
and fixed a defect - the packaged editor exited without opening a window.  It
was run again after the editor's layout changed, with the new Tk modules in
the list.
The Windows build itself has not yet been run.

## AutoCAD

`autocad/phcp_export.lsp` marks up a 2D AutoCAD 2026 drawing - supply, pipe
sizes, elevations, heads - and exports it as a `.hcx`.  See
`autocad/AUTOCAD.md`.  `examples/08_autocad_export_format.hcx` is a file in the
exact format the routine writes, proven to solve in PHCP.  The routine itself
has not yet been run inside AutoCAD.  Its output is `.hcx`, which `phcp.pl`
still reads; making it write `.phc` is planned (`PLAN.md`, PR 4).

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

`OPTION VEL_LIMIT 6` (`.hcx`: `OPTIONS VEL_LIMIT 6`) sets the velocity flagged
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
| EPANET 2.3.5, 100 cases (before the Q^1.85 curves - not re-run) | 100 / 100 |
| robustness, 387 cases incl. 300 fuzz (prototype suite, not in this repository) | 0 problems |
| extreme conditions, 44 cases (prototype suite, not in this repository) | 0 problems |
| direct comparison with the C++ engine (before the Q^1.85 curves - not re-run; the C++ engine is not in this repository) | worst 0.005 L/min, 0.0049 kPa |
| pipe and fitting database | 35 / 35 |
| `.phc` language, line checker and pressure ratio valves | 256 / 256 |
| supply, pump and loss curves | 14 / 14 |
| report hand-checks, 14 models | 659 / 659 |
| PDF structure, 14 models | 98 / 98 |
| text editor logic, headless | 114 / 114 |
| text editor window, under Xvfb | 92 / 92 |
| invariance stress | 9 574 / 9 574 |

## Stress testing

`tools/stress_invariance.pl` needs no reference program.  It takes a random
looped network and describes it differently -- elements shuffled, pipes
reversed, the whole site raised, a pipe split in two, nodes renamed, every
quantity in different units, the same text solved twice -- and demands the
same answer every time.  It also fuzzes the pipe database resolver with 4000
fitting strings.

| run | result |
|---|---|
| 60 random networks x 7 transforms + resolver fuzz | 9 574 checks, 0 failed |
| worst disagreement, any transform | 8e-6 L/min |

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
model, not the standard's tables.  Agreement with EPANET and with other
implementations does not validate a reading of a standard.  The database is
user editable: a value changed in it is only as good as the source it was
taken from.
