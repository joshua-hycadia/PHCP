# PHCP execution plan - command-file input and text editor

Status: PR 1 merged.  PR 2 (`.phc` language, reworked to the positional layout
Joshua chose on 28 October 2026) and PR 3 (text editor, built on PR 2) open for
review.  PR 4 and PR 5 not started.

This plan replaces the spreadsheet front end with a plain-text command file
(`.phc`) and a text editor built around it.  The solver, the report, the PDF
writer and the pipe and fitting database are NOT changed by this work.

Read `CONTRIBUTING.md` before starting.  Its rules are binding.

---

## Goal

A designer types the model as short command lines - one element per line, in
any order, fields by position, no `KEY=value` - into an editor that colours
each line as it is typed, flags errors on the line they occur, proposes the
next line, offers pipe types and fittings from the database, and solves on one
key.  The command layout follows the way an established command-entry
sprinkler program sets out its input; the commands, the checks and everything
behind them are PHCP's own, and better: dedicated sprinkler, hydrant, hose
reel and fixed-flow commands, any number of water supplies, units chosen per
file, and every error named on its line.

## Ground rules for this work

- **The engine does not change.**  `HardyCross.pm`, `HardyCross/Demand.pm`,
  `HardyCross/PipeData.pm`, `HardyCross/Report.pm` and `HardyCross/PDF.pm`
  are touched only where this plan says so.  Any change that alters a solved
  number needs Joshua's approval first.
- **The `.phc` reader translates; it does not re-implement.**  Each `.phc`
  command is turned into the equivalent `.hcx` rows and handed to the existing
  parser, so every hydraulic check and default stays in one place.  The one
  thing the reader converts itself is lengths and elevations, which `.phc`
  lets the user give in a unit of their own per quantity (the parser has one
  length unit); it uses the engine's own unit table to do it.
- **Same results are the acceptance test.**  Every example is rewritten in
  `.phc` and must solve to the same pipe flows and node pressures as its `.hcx`
  original (`tools/test_phc.pl`).  Names of supplies and outlets follow their
  node in `.phc`, so reports are compared on the numbers, not byte for byte.
- **Nothing is taken from another program** but the idea of the layout: no
  text, data, tables or code.  No other program is named.

---

## PR 2 - the `.phc` command language

Branch: `phc-language`.

### Files

| file | purpose |
|---|---|
| `HardyCross/Phc.pm` | reader for `.phc` text, plus the line-level checks the editor uses |
| `HardyCross/Parse.pm` | `read_model` dispatches on extension: `.phc` to Phc.pm, anything else as now |
| `phcp.pl` | accepts `.phc` and `.hcx` |
| `examples/*.phc` | every example rewritten in `.phc`; the `.hcx` originals stay as the baseline |
| `tools/test_phc.pl` | language tests (below) |

There is no `.hcx` to `.phc` converter: no models exist in `.hcx` beyond the
prototype's examples (Joshua, 28 October 2026), and the examples are rewritten
once, checked by the test above.

### Language

General rules:

- One command per line; fields by position, separated by spaces or tabs.
  Written in capitals (lower case is read the same).  Ids are case-sensitive.
- `//` starts a comment to the end of the line.  `!` and `#` are refused
  outside a comment.
- Lines may come in any order.  Settings are file-wide and each is given once.
  `USE` is positional: it applies to the `PIPE` lines after it.
- Every node is defined exactly once - by `NODE`, `WATER`, `SPRINKLER`,
  `HYDRANT`, `HREEL` or a copy (`NC`) - and every node an element names must be
  defined.  Every pipe name is unique.
- Every error carries its `.phc` line number.

Settings (PHCP's own):

```
TITLE     <text>
PROJECT   <FIELD> <text>                 // COMPANY, JOB, DESIGNER, DENSITY ...
UNITS     <QUANTITY> <UNIT>              // see Units
METHOD    HW | DW
OPTION    <NAME> <value>                 // PROFILE HW_CONST NU TOL_FLOW TOL_LOOP
                                         // MAXITER RELAX VEL_LIMIT FITTING_BASIS ORIF_STEP
```

Pipes:

```
USE       <PIPETYPE> [<C>]               // C-factor; roughness under METHOD DW
USE       BORE [<C>]                     // following pipes give a bore, not a DN
PIPE      <NAME> <START> <END> <LENGTH> <SIZE> [<fittings> ...]
PC        <SOURCE> <NAME> <START> <END> [<NAME> <START> <END> ...]   // copies of a pipe
CHANGEPIPE <NAME> <LENGTH> <SIZE> [<fittings> ...]                    // alias CHP
EQV       <PIPE> <LENGTH>                // an equivalent length added to a pipe
```

Nodes and outlets:

```
NODE      <NAME> <ELEVATION>
NC        <SOURCE> <NAME> [<NAME> ...]   // copies of any node definition
WATER     <NAME> <ELEVATION> <STATIC> [<FLOW> <PRESSURE> ...]   // a supply; any number
SPRINKLER <NAME> <ELEVATION> <MINFLOW> <K>      // MINFLOW < 0: a minimum PRESSURE
HYDRANT   <NAME> <ELEVATION> <MINFLOW> <K>
HREEL     <NAME> <ELEVATION> <MINFLOW> <K>
FIXEDFLOW <NAME> <NODE> <FLOW> [<MINPRESSURE>]   // set flow; minimum pressure checked
```

Devices - all but PUMP sit in a pipe, named by the pipe:

```
PUMP      <NAME> <IN> <OUT> <CHURN> <FLOW> <PRESSURE> [<FLOW> <PRESSURE> ...]
BP        <PIPE> <CHURN> <FLOW> <PRESSURE> [...]        // a pump in a pipe
BFP       <PIPE> <FLOW> <LOSS> [<FLOW> <LOSS> ...]      // backflow preventer; a loss curve,
                                                       // one pair at flow 0: a fixed loss
PRV       <PIPE> <FLOW> <LOSS> [<FLOW> <LOSS> ...]      // pressure reducing valve, as BFP
OPP       <PIPE> <DROP> [<CD>]                          // orifice plate: drop given, plate sized
OFD       <PIPE> <BORE> [<CD>]                          // orifice plate: bore given, drop found
PRA       <PIPE> <RATIO> [<MININLET>]                   // pressure ratio valve: outlet = inlet / ratio
```

A device in a pipe sits at the pipe's start: the pipe is split at a node named
`<PIPE>~` at the start node's elevation.  An orifice plate takes its pipe's
nominal size and bore.  One device per pipe.

Units, one `UNITS` line per quantity; defaults (the office's) in brackets:

| quantity | units |
|---|---|
| LENGTH | MM CM M IN FT (MM) - pipe lengths, equivalent lengths |
| ELEVATION | MM CM M IN FT (M) |
| SIZE | MM IN (MM) - nominal size, and orifice bores |
| PRESSURE | KPA BAR MPA PSI M (KPA) |
| FLOW | LPM LPS M3H GPM (LPM) |
| KFACTOR | LPM/KPA LPM/BAR LPS/KPA LPS/BAR GPM/PSI (LPM/KPA) |

Velocity is reported in m/s.  Defaults are the office's (Joshua, 28 October
2026); the K-factor default is not yet confirmed.

A length or elevation may carry its own unit: `12M`, `300MM`, `14'3"`, `6'`.

Fittings: database codes with an optional count (`2E T GV`), plus the short
forms `G` (gate valve, `GV`), `C` (check valve, `CV`) and `B` (butterfly
valve, `BV`).

### How the reader works

1. Read every line; strip comments; tokenise with the existing tokeniser.
2. First pass: the settings.  Second pass: nodes, pipes (with `CHANGEPIPE`,
   `EQV` and in-pipe devices applied), copies, outlets and devices.
3. Build `.hcx` text: PROJECT, UNITS, OPTIONS, NODES, then the elements in
   file order.  Lengths and elevations are written in metres.
4. Parse it with the existing code; map any error back to its `.phc` line.

### Line checking for the editor

`HardyCross::Phc::check_line($line, $context)` returns, without Tk: status
(`ok`, `incomplete`, `error`) and message; the command's field template with
the cursor's field; pick lists of pipe types and fitting codes; a proposed
next line.  Tested headless in `tools/test_phc.pl`.

### Tests - `tools/test_phc.pl`

- Every example: the `.phc` solves to the same pipe flows and node pressures
  as its `.hcx` baseline.
- Every command: a valid line, each field missing, a bad number, an unknown
  setting, duplicates.  Each error names its line.
- Any order: shuffled lines give the same results.
- Units: every quantity in other units gives the same network.
- `check_line` status, template, choices and proposals.

### Fixed flows

`FIXEDFLOW`'s minimum pressure is checked (Joshua's decision): passed or failed
in the report, and counted in the governing outlet and demand point.

---

## PR 3 - the text editor

Branch: `phc-editor`.

### Files

| file | purpose |
|---|---|
| `HardyCross/Editor.pm` | editor logic with no Tk: line checks, the three lists, proposals, completion, results tables, units |
| `phcp_editor.pl` | the Tk window, kept thin |
| `tools/test_editor.pl` | headless tests of `Editor.pm` |
| `tools/test_editor_window.pl` | the window, driven under Xvfb |
| `phcp_gui.pl`, `tools/test_gui_document.pl`, `tools/test_gui_editing.pl` | **removed** - the spreadsheet is retired |
| `phcp_viewer.pl` | kept; reads `.phc` through `read_model` |
| `build_windows.bat` | builds `phcp.exe` and `phcp_editor.exe`; Tk::TableMatrix no longer needed |
| `LICENSE` | drop Tk::TableMatrix from the third-party list |

### Window

Joshua's layout and look (28 October 2026): a white, flat window - blue and
black only as highlight colours, no bevels - with a toolbar (NEW OPEN SAVE,
VALIDATE, CALCULATE, WRITE REPORT); NETWORK and PROJECT tabs; the editor with
line numbers, syntax colours, the command strip and the status bar, and an
ERRORS / WARNINGS / NODES panel to its right; below, VALIDATION, PIPES, NODES,
OUTLETS and REPORT tabs in sortable columns, with HIDE NON-FLOWING PIPES and
HIDE INACTIVE NODES.  Everything user-visible in capitals.

### Editor behaviour

| feature | behaviour |
|---|---|
| network only | the editor holds the network; title, project details, units, method and options are set in the PROJECT tab and written at the head of the `.phc` |
| VALIDATE then CALCULATE | CALCULATE is available only while the model is as it was when it last passed VALIDATE.  VALIDATE lists what is wrong, why, and where, marks each fault in the editor, and a click goes to it |
| syntax colours, line numbers | per field: command, name, reference, number, keyword, comment; a gutter of line numbers |
| command strip | the network commands in their three groups; a click starts a line |
| status bar | the field template of the current command, current field highlighted; the line's results after a calculation |
| proposals | after Enter, the likely next line is shown greyed; Enter or Tab accepts |
| pick list | Ctrl+Space in a `USE` type or a fitting |
| ERRORS / WARNINGS / NODES | live; a click goes to the line or the PROJECT tab field |
| tables | PIPES has 21 columns with a right-click chooser; a heading click sorts, a second reverses |
| files | NEW, OPEN, SAVE, SAVE AS, WRITE REPORT.  `.phc` only |
| undo | Ctrl+Z / Ctrl+Y, Tk TextUndo |

### Tests

- `tools/test_editor.pl`, headless: line statuses and the three lists,
  proposals, pick lists, the status bar, syntax colouring, results on the
  cursor, the tables and sorting, the document (settings apart from the
  network), VALIDATE's what, why and where, files.
- `tools/test_editor_window.pl`, under Xvfb: layout and look, open, live
  checks, command strip, proposals and undo, pick list, VALIDATE before
  CALCULATE, the tables (a real heading click included), the PROJECT tab,
  files.

### Windows

Update `build_windows.bat`; Windows remains "not yet run" until Joshua runs it.

---

## PR 4 - one file type

Branch: `phc-only`.  Decided by Joshua: there are no `.hcx` models in use -
the format only ever served the prototype - so `.phc` becomes the one file
type a user sees.

| file | change |
|---|---|
| `autocad/phcp_export.lsp`, `autocad/AUTOCAD.md` | the exporter writes `.phc` |
| `phcp.pl`, `phcp_viewer.pl` | read `.phc` only; a `.hcx` is refused with "convert it first: phcp.pl --convert" |
| `phcp_editor.pl` | unchanged: OPEN still converts a `.hcx` into a new `.phc` |
| `examples/*.hcx` | moved to `tools/baseline/`, kept as the converter's regression baseline |
| `tools/test_report_checks.pl`, `tools/test_pdf.pl` | run on `examples/*.phc` |
| `README.md` | one format; `.hcx` described only as what `--convert` reads |

Inside, `.phc` lines are still translated into `.hcx` rows for the existing
parser (`HardyCross::Parse`); that is how the checks stay in one place, and
the user never sees it.  `tools/stress_invariance.pl` builds its networks as
`.hcx` text for the parser and is unaffected.

## PR 5 - the phcp.exe JSON interface

Branch: `phc-json`.  Decided by Joshua: other programs call `phcp.exe`, not a
DLL.  AutoCAD first, possibly Revit later.

    phcp.exe --json model.phc          results as JSON on standard output
    phcp.exe --json -                  the model read from standard input
    phcp.exe --json model.phc --report out.pdf

- Output: status, converged, iterations, units, every element (id, kind,
  nodes, flow, velocity for a pipe), every node (elevation, pressure), outlet
  compliance including fixed flows, the governing outlet, the demand point,
  and errors with their `.phc` line numbers.  Values in the model's units,
  the units named in the output.
- Exit status as now: 0 converged, 1 not converged, 2 input error - and the
  JSON is written in every case, so a caller always has something to read.
- JSON::PP, which is core Perl.  The contract is documented in the README
  with an example, and versioned (`"interface": 1`) so a caller can check it.
- `tools/test_json.pl`: every example, the JSON parsed back and checked
  against the solved network; an input error; standard input.
- The AutoCAD exporter gains a SOLVE command that runs `phcp.exe --json` and
  shows the governing outlet and any failing outlets; it has not been run
  inside AutoCAD until Joshua runs it.

## Definition of done, each PR

- All tests in `CONTRIBUTING.md` pass, plus the new ones.
- README describes the program as it is on the branch.
- This file's status line and checklist updated.
- Pull request opened to `main`; nothing merged by the contributor.

## Checklist

- [x] PR 1 - import PHCP, editable pipe database, report states database SHA-256
- [x] PR 2 - `.phc` reader, examples, `test_phc.pl` (first version, `KEY=value` syntax)
- [x] PR 2 - reworked to the positional layout: SPRINKLER HYDRANT HREEL FIXEDFLOW WATER,
  PC NC CHANGEPIPE EQV, BP BFP PRV OPP OFD in pipes, UNITS per quantity; converter dropped
- [x] PR 2 - PRA pressure ratio valve in the solver: outlet = inlet / ratio, set in the
  outer loop; warnings for low inlet, reverse flow, unsettled drops
- [x] PR 2 - supply, pump and loss curves interpolated on Q^1.85 through every point
  (engine change, approved by Joshua 28 October 2026; `tools/test_curves.pl`)
- [x] PR 2 - `FIXEDFLOW MINP=` decision recorded: checked, by Joshua's decision -
  passed or failed in the report and counted in the governing outlet and demand
  point (README, "Fixed flows")
- [x] PR 3 - `Editor.pm` and `phcp_editor.pl` (light blue and black, by Joshua's choice)
- [x] PR 3 - spreadsheet removed, build script and licence updated
- [x] PR 3 - Joshua's layout: results tables below, ERRORS / WARNINGS / NODES at right, command strip, all capitals
- [x] PR 3 - white flat look, syntax colours, line numbers, PROJECT tab for settings, VALIDATE before CALCULATE
- [ ] PR 3 - Windows build run by Joshua
- [x] Report: the supply graph drawn in the PDF on q^1.85 graph paper, from the numbers the text graph uses (engine change, approved by Joshua 28 October 2026)
- [x] Report: the PDF set in embedded DejaVu Sans Mono, rules drawn as lines
- [ ] PR 4 - AutoCAD exporter writes `.phc`; `.hcx` only through `--convert`
- [ ] PR 5 - `phcp.exe --json`, documented and tested
- [ ] PR 5 - AutoCAD SOLVE command run by Joshua
