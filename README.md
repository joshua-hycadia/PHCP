# PHCP - Perl Hydraulic Calculation Program

Copyright (c) 2026 Hycadia Pty Ltd.  MIT licence - see LICENSE, which also sets
out what the licence does NOT cover: the third-party values reproduced in
`data/`, and Tk.

Version 1.0.0

A Hardy Cross loop-balancing hydraulic solver, a plain-text command language
for the model (`.phc`), a spreadsheet front end, and a monospace ASCII
calculation report.  The whole stack is Perl.

```
./phcp.pl model.phc report.pdf           # solve and write the report as PDF
./phcp.pl model.phc report.txt           # ...or as plain ASCII text
./phcp.pl --convert model.hcx            # write model.phc from a .hcx model
perl phcp_gui.pl model.hcx               # the spreadsheet (FILE > WRITE REPORT, Ctrl+R)
perl tools/test_phc.pl                   # verify the .phc language and converter
perl tools/test_pipedata.pl              # verify the pipe and fitting database
perl tools/test_gui_document.pl          # verify the spreadsheet's load, save and undo
perl tools/stress_invariance.pl 60       # invariance stress on 60 random networks
```

`phcp.pl` reads either input format; the extension decides which.  The results
viewer, `phcp_viewer.pl`, reads models through the same call and its OPEN
dialog now lists `.phc`; the viewer itself has not yet been run with a `.phc`
file (Tk is not installed where this was built).
`.phc` is the command language described below.  `.hcx` is the older block
format, still read so existing models and the AutoCAD exporter keep working;
every example is supplied in both.  The spreadsheet reads and writes `.hcx`
only.

**Planned.**  A text editor for `.phc` will replace the spreadsheet; see
`PLAN.md`.  Until that work is merged, the spreadsheet is the graphical front
end.

## The .phc command language

The model is typed as short command lines, one element per line, in any order:

```
Title  SINGLE BRANCH CLOSED-FORM CHECK
Units  FLOW=LPM PRESSURE=KPA LENGTH=M DIAMETER=MM
Method HW
Option TOL_FLOW 0.001

Node   N1 0.0
Node   N2 0.0
Pipe   P1 N1 N2 100.0 100.0 C=120
Supply SUP1 N1 STATIC 900
Head   S1 N2 K=80 P=50
```

**Rules.**  The first word is the command.  Commands and keywords are
case-insensitive; ids are case-sensitive.  Fields are separated by spaces or
tabs, and `KEY=value` options follow the fixed fields in any order.  `//`
starts a comment to the end of the line.  `!` and `#` are not allowed outside a
comment (they are comment characters in `.hcx`, and the line would otherwise be
cut short without a word).

**Any order.**  Element lines may come in any order.  `Units`, `Method`,
`Option`, `Title` and `Project` are file-wide wherever they appear, and each
setting may be given only once - a second one is an error naming both lines.
`Use` is the one positional command: it applies to the `Pipe` lines after it,
until the next `Use`.

**Every node needs a `Node` line.**  A node used by an element but never
defined is an error naming the node and the first line that uses it.  (`.hcx`
creates such a node at elevation 0 silently, so a mistyped node name becomes a
new node.)

| command | fields |
|---|---|
| `Title` | text - the PROJECT TITLE |
| `Project` | FIELD text - any cover field: COMPANY, JOB, DESIGNER, DENSITY ... |
| `Units` | `[FLOW=] [PRESSURE=] [LENGTH=] [DIAMETER=]`, the `.hcx` unit codes |
| `Method` | `HW` or `DW` |
| `Option` | NAME value: `PROFILE HW_CONST NU TOL_FLOW TOL_LOOP MAXITER RELAX VEL_LIMIT FITTING_BASIS ORIF_STEP` |
| `Use` | PIPETYPE `[C=]` - a pipe type from the database; or `BORE [C=]` |
| `Node` | id elevation |
| `Pipe` | id n1 n2 length size `[fittings ...] [C=] [EQV=] [EPS=] [K=]` |
| `Supply` | id node `STATIC` pressure `[Z=]`, or id node `CURVE` q1 p1 q2 p2 ... `[Z=]` |
| `Pump` | id in out q1 p1 q2 p2 ... |
| `Head` | id node - any two of `K= Q= P=`, and `[Z=]` (a sprinkler) |
| `Hydrant` | id node - any two of `K= Q= P=`, and `[Z=]` |
| `HoseReel` | id node - any two of `K= Q= P=`, and `[Z=]` |
| `Flow` | id node `Q=` `[MINP=] [Z=]` - a fixed flow, with the pressure it needs |
| `BFP` | id n1 n2 q1 p1 q2 p2 ... - a backflow preventer's loss curve |
| `PRV` | id n1 n2 `DP=` |
| `Orifice` | id n1 n2 `DP=` (sizes the plate) or `BORE=` (known bore), `DN=` or `PIPEDIA=`, `[CD=]` |

**Pipe sizes and fittings.**  Under `Use <PIPETYPE>` the size is the nominal DN
and the bore comes from the database; under `Use BORE` the size is the bore.
Before any `Use`, pipes are `Use BORE C=120`, as in `.hcx`.  A pipe's own `C=`
wins over the `Use` line's.  Fittings follow the size, one token each with an
optional count - `2E T GV` - or as one office string, `2E,1T,1GV` or `1E1T`;
all three mean the same.  Fittings need a pipe type, so on a `Use BORE` pipe
they are an error: give the allowance as `EQV=` instead.

**An unknown `Option` is an error.**  `.hcx` silently ignores an OPTIONS name
it does not know - example 01 carried `TRACE FULL`, which did nothing.

**How it is read.**  Each `.phc` command is translated into the `.hcx` row that
means the same thing, and the rows are read by the same parser that reads a
`.hcx` file (`HardyCross/Phc.pm`).  Every hydraulic check, default and unit
conversion therefore exists once, and a `.phc` model cannot quietly mean
something different from its `.hcx` equivalent.  The `.phc` reader checks only
the language itself: command words, field counts, options, numbers, nodes and
duplicate settings.  Every error carries the `.phc` line number, including the
parser's own errors, which are mapped back from the translated row.

**Converting.**  `phcp.pl --convert model.hcx [model.phc]` writes a header
comment, the settings, a `Node` line for every node, then the elements in their
`.hcx` order with `Use` lines where the pipe type changes.  Values are copied
exactly as typed.  Anything the `.hcx` reader ignored - an unknown option, a
stray field, `K=` on a fixed flow - had no effect on the result, so it is
dropped and listed in the header comment.  Comments in the `.hcx` are not
carried over; the header says so.  An existing output file is never
overwritten.  Every example converts to a `.phc` whose report is identical to
the `.hcx` original's apart from the model file name.

**Fixed flows.**  A `Flow` (`.hcx`: `FIXEDFLOW`) takes exactly its `Q=`
whatever the pressure - it is a nodal demand, outside every loop - and its
`MINP=` is the pressure it needs to deliver that flow.  The minimum is CHECKED:

- Section 5 shows it as the node's REQUIRED P;
- Section 7 lists the fixed flow after the outlets, K shown as `fixed`, PASS
  or FAIL on pressure alone (its flow cannot fall short - it is set);
- the governing outlet and the demand point count it like any other outlet,
  so a fixed flow with the least pressure to spare governs, and the demand
  point is the supply pressure at which it receives exactly its minimum.

The flow itself is not reduced when the pressure is short; the report shows
the shortfall as a FAIL instead.  In `.hcx`, `P=` on a FIXEDFLOW means the same
as `MINP=`.  Until this change the minimum was read and thrown away, so a fixed
flow far below its required pressure was reported as if all were well.  The
solved flows and pressures are unchanged by it; the compliance table, and the
demand point of a model whose fixed flow governs, are new.

**Line checking.**  `HardyCross::Phc::check_line` checks one line as it is
typed, without Tk, for the text editor planned in `PLAN.md`: whether it is
complete, the command's field template and which field the cursor is in, the
pipe types or fitting codes from the database for a pick list, and a proposed
next line.  A line the language accepts is also parsed as its `.hcx` row, so a
size the pipe type does not make, or a fitting the database lacks, shows on the
line as it is typed.  It is tested headless in `tools/test_phc.pl`; no editor
uses it yet.

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
Use   ASAM                                 // .phc
Pipe  P1  A  B  12.0  100  T 2E GV CV

P1  A  B  12.0  100  TYPE=ASAM  FIT=1T,2E,1GV,1CV        ! .hcx
```

With a pipe type the size is the NOMINAL size; the bore comes from that
type's PIPE records in the database.  Fittings take the office form `2E,1T`,
the compact form `1E1T`, or (in `.phc`) separate tokens `2E T`.  A pipe with no
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

`Option FITTING_BASIS STANDARD` (`.hcx`: `OPTIONS FITTING_BASIS STANDARD`)
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

## The spreadsheet

Sheets: PROJECT, NETWORK, OTHER NODES, SUPPLIES, PUMPS, PRESSURE DEVICES, and
the computed PRESSURES, LOOPS and CONVERGENCE.  Results along the bottom,
validation on the right, both always visible.

**OTHER NODES** holds every node no pipe touches - the downstream side of an
orifice, PRV or backflow preventer.  These used to be preserved invisibly on
save; an outlet in the model but on no sheet is a trap for whoever edits next.

**PUMPS** holds pump curves as flow/pressure pairs.  Pumps used to be kept on
save but could not be edited.

**Spreadsheet editing.**

| key | action |
|---|---|
| Ctrl+C / Ctrl+X / Ctrl+V | copy, cut, paste - tab-separated, so blocks go to and from Excel |
| Delete | clear a selection of several cells (on one cell it edits text as usual) |
| Ctrl+Delete | always clear the selection |
| Ctrl+D | fill down the selection; ids step to the next one.  One row selected: copy the row above's cell |
| Ctrl+Shift+D | copy the whole row above, id incremented |
| Ctrl++ / Ctrl+- | insert a row above / delete the selected rows |
| right-click | the same, on a menu |

Every operation is one undo step.  A paste never writes a calculated or spacer
cell - it skips them and says how many - and cells are split on tabs only, so a
fitting string such as `2E,1T` arrives in one cell.

**Cell-level validation.**  As you type, a cell with a problem turns red: a
missing length, a number column holding text, a pipe type not in the database, a
DN not made in that pipe, a fitting string that returns DATA_REQUIRED, an outlet
short of two of K, flow and pressure, a curve with too few points.  The same
findings are listed in the validation panel, and clicking one opens its sheet
with the cell selected.  One list drives both, so the sheet and the panel cannot
disagree.

**Undo and redo**, Ctrl+Z and Ctrl+Y, on whole-document snapshots.  A
carry-down that writes five cells undoes as one step, and derived cells are
recomputed rather than restored, so an undo cannot bring back a value that no
longer follows from its inputs.

**`--tab NAME`** opens on a given sheet.

### Two save defects fixed

**Saving renamed outlets.**  The NETWORK sheet has no outlet-id column, so a
save invented `<node>-OUT` and turned HYD1 into HY-OUT.  Outlet ids from the
file are now kept.

**Saving degraded the model.**  The serialiser read derived cells as shown -
a derived K rounded for display to 75.89 was written back as an INPUT in place
of the exact 75.8946, turning two inputs into three.  Each save moved flows by
about 0.1 L/min.  Only typed inputs are written now; `test_gui_document.pl`
checks every parameter survives a load and save exactly.

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

The fields are entered as `.phc` `Title` and `Project` lines -
`Project HAZARD Ordinary Hazard 1` - on the spreadsheet's PROJECT sheet, or in a
`.hcx` model's PROJECT block:

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
rounding of the printed figures allowed for: 308 checks across seven models.  Its
first run found two faults that had been in the report since it was written:
outlet K printed with its unit factors inverted - 36 times too large in L/s and
bar, invisible in L/min and kPa - and loss per metre printed to four places,
too few in bar/m for PF/M x T to reproduce PF.

## PDF output

`phcp.pl model.phc report.pdf`, or FILE > WRITE REPORT with a .pdf name.  The
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

`build_windows.bat` builds `phcp.exe` and `phcp_gui.exe` on a Windows PC with
Strawberry Perl installed: it fetches Tk, Tk::TableMatrix and PAR::Packer from
CPAN, packages both programs with the pipe and fitting database inside, and runs a
smoke test on a `.hcx` and a `.phc` example.  The packaging recipe was proven on
Linux, where both packaged programs ran from an empty folder and gave a report
identical to running from source.  That was before the `.phc` modules
(`HardyCross/Phc.pm`, `HardyCross/Convert.pm`) were added to the package list;
packaging them has not yet been run.  The Windows build itself has not yet been
run.

## AutoCAD

`autocad/phcp_export.lsp` marks up a 2D AutoCAD 2026 drawing - supply, pipe
sizes, elevations, heads - and exports it as a `.hcx`.  See
`autocad/AUTOCAD.md`.  `examples/08_autocad_export_format.hcx` is a file in the
exact format the routine writes, proven to solve in PHCP.  The routine itself
has not yet been run inside AutoCAD.  Its output is `.hcx`; `phcp.pl --convert`
turns it into `.phc`.

## Settings

`Option VEL_LIMIT 6` (`.hcx`: `OPTIONS VEL_LIMIT 6`) sets the velocity flagged
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
| EPANET 2.3.5, 100 cases | 100 / 100 |
| robustness, 387 cases incl. 300 fuzz | 0 problems |
| extreme conditions, 44 cases | 0 problems |
| direct comparison with the C++ engine | worst 0.005 L/min, 0.0049 kPa |
| pipe and fitting database | 35 / 35 |
| `.phc` language, converter and line checker | 277 / 277 |
| spreadsheet load, save and undo | 12 / 12 |
| spreadsheet editing and cell validation | 18 / 18 |
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
order, the lowest-numbered farthest node taken as the centre -- and so takes
IDENTICAL iteration counts on every model compared:

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
