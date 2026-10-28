# PHCP execution plan - command-file input and text editor

Status: PR 1, PR 2 (`.phc` language, positional layout) and PR 3 (text editor)
merged.  Open for review: the editor fixes from the Windows run, the drawn
supply graph and PDF typeface, the DATABASE tab, PR 4 (one file type) and
PR 5 (the JSON interface).

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
  number needs the maintainer's approval first.
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
prototype's examples (decided 28 October 2026), and the examples are rewritten
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

Velocity is reported in m/s.  Defaults are the office's (decided 28 October
2026); the K-factor default, LPM/KPA, confirmed the same day.

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

`FIXEDFLOW`'s minimum pressure is checked (decided): passed or failed
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

The layout and look (decided 28 October 2026): a white, flat window - blue and
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

Update `build_windows.bat`; Windows remains "not yet run" until it is run there.

---

## PR 4 - one file type

Decided: there are no `.hcx` models in use - the format only ever
served the prototype - so `.phc` is the one file type a user sees.  (The
`--convert` command and the editor's conversion planned here were removed in
PR 2 and PR 3, before any user had a `.hcx` to convert.)

| file | change |
|---|---|
| `autocad/phcp_export.lsp`, `autocad/AUTOCAD.md` | the exporter writes positional `.phc`: a supply or head names its node, `USE` lines where the type or C changes, drops as `<ID>_D`; PHCPSUPPLY asks for the static pressure first; new checks for two items on one node and IDs used twice |
| `tools/check_lisp.pl` | structural checks of the exporter, which cannot run without AutoCAD |
| `HardyCross/Parse.pm` | `read_model` refuses any file but `.phc`, with the reason |
| `phcp.pl`, `phcp_viewer.pl` | `.phc` only |
| `examples/*.hcx` | moved to `tools/baseline/`, the independent description each example is checked against |
| `examples/08_autocad_export_format.phc` | exactly what the new exporter writes; solves exactly as its baseline |
| `tools/test_report_checks.pl`, `tools/test_pdf.pl` | run on `examples/*.phc` |
| `build_windows.bat` | smoke test on `.phc` only |
| `README.md` | one format |

Inside, `.phc` lines were still translated into `.hcx` rows for the existing
parser at this stage; v1.0 removed that step (below).

## PR 5 - the phcp.exe JSON interface

Decided: other programs call `phcp.exe`, not a DLL.  AutoCAD first,
possibly Revit later.

    phcp.exe --json model.phc          results as JSON on standard output
    phcp.exe --json -                  the model read from standard input
    phcp.exe --json model.phc --report out.pdf

| file | change |
|---|---|
| `HardyCross/Json.pm` | the results as one JSON object, versioned (`"interface": 1`), the contract described at its head |
| `phcp.pl` | `--json`, `-` for standard input, `--report`; the plain output unchanged without `--json` |
| `autocad/phcp_export.lsp` | PHCPSOLVE: export, run `phcp.exe --json`, show the summary |
| `tools/test_json.pl` | every example's JSON against the plain output of the same solve; input error, `.hcx`, no convergence; standard input; `--report`; the summary read line by line as AutoCAD reads it |
| `build_windows.bat` | packs `HardyCross::Json` and `JSON::PP`; smoke test of `--json` |

- Exit status as before - 0 converged, 1 not converged, 2 input error - and
  the JSON written in every case.
- JSON::PP, which is core Perl.  Written one value to a line in a fixed key
  order, so AutoLISP can find the summary lines without a JSON reader.

## v1.0 - release cleanup

Decided: before v1.0, the `.hcx` text goes entirely, no other program is
named, and no person is named.

| file | change |
|---|---|
| `HardyCross/Phc.pm` | `translate` returns rows; `read_string` hands each to the network builder directly - no `.hcx` text in between |
| `HardyCross/Parse.pm` | the block-text reader removed; `parse_row` is the network builder |
| `HardyCross/Demand.pm`, `HardyCross/Report.pm` | the demand point and the PRA top-of-band solve re-read the `.phc` text (engine files: approved) |
| `tools/baseline/*.hcx` | replaced by `*.expected`: each example's solved flows and pressures, frozen from the `.hcx` solve before it was removed (example 04: pipe and node names only) |
| `tools/stress_invariance.pl` | builds its random networks as `.phc` |
| `OPTION PROFILE`, `epanet_adapter.pl`, `crosscheck.py` | removed: they served a comparison against another program, and the C++ engine, neither in this repository |
| every file | no person named; decisions carry their date |

## v1.0 - the GRAPH tab

Asked for: a tab that makes Q^1.85 water supply graphs and prints them,
independent of the calculation.

| file | change |
|---|---|
| `HardyCross/Graph.pm` | new: the figures, their checks, the curves (A supply, B loss, C = A - B, D pump, E = C + D) by the solver's own curve rule, the duties against the design curve, the `.phg` file, and the PDF sheet |
| `HardyCross/PDF.pm` | the page frame and the file writing split out (`frame`, `fonts`, `geometry`, `write_pages`) so the sheet is printed exactly as the report is; the report's PDF is byte-identical.  The font folder is found from the module's own place (it looked one folder too high, and found the fonts only when run from the repository root) |
| `phcp_editor.pl` | the GRAPH tab: the figures, the live graph, the problems list, NEW / OPEN / SAVE GRAPH and PRINT TO PDF |
| `examples/10_supply_graph.phg` | a town main with a booster pump |
| `tools/test_graph.pl`, `tools/test_editor_window.pl` | the graph headless, and the tab driven |
| `build_windows.bat` | packs HardyCross::Graph |

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
  (engine change, approved 28 October 2026; `tools/test_curves.pl`)
- [x] PR 2 - `FIXEDFLOW MINP=` decision recorded: checked, by decision -
  passed or failed in the report and counted in the governing outlet and demand
  point (README, "Fixed flows")
- [x] PR 3 - `Editor.pm` and `phcp_editor.pl`
- [x] PR 3 - spreadsheet removed, build script and licence updated
- [x] PR 3 - The agreed layout: results tables below, ERRORS / WARNINGS / NODES at right, command strip, all capitals
- [x] PR 3 - white flat look, syntax colours, line numbers, PROJECT tab for settings, VALIDATE before CALCULATE
- [x] PR 3 - Windows build run (28 October 2026, Perl 5.42.3)
- [x] DATABASE tab: view and edit the pipe and fitting database (read-only until EDIT is ticked); a team folder for it, else the built-in (decided 28 October 2026)
- [x] Editor fixes from the Windows run: sharp at 150 %, draggable dividers, wheel under the pointer, HIDE counts, option labels
- [x] PR 4 - AutoCAD exporter writes `.phc`; `.phc` the one file type
- [ ] PR 4 - exporter run inside AutoCAD
- [x] PR 5 - `phcp.exe --json`, documented and tested
- [x] Pressure ratio valve band: designed to the bottom of +/-5% of inlet, top of band reported (engine change, approved 28 October 2026)
- [x] Report: the supply graph drawn in the PDF on q^1.85 graph paper, from the numbers the text graph uses (engine change, approved 28 October 2026)
- [x] Report: the PDF set in embedded DejaVu Sans Mono, rules drawn as lines
- [ ] PR 5 - AutoCAD SOLVE command run inside AutoCAD
- [x] v1.0 - `.hcx` removed throughout, no other program or person named
- [x] v1.0 - program icon on the editor window and taskbar (the .exe files keep the default: PAR::Packer has no --icon)
- [x] Report: a supply graph for each supply when there are several, then all combined - flows added at equal pressure, the combined duty at one common pressure; example 09, three pumps in parallel (engine files Report, PDF, Demand: no solved number changes)
- [x] v1.0 - GRAPH tab: Q^1.85 water supply graphs from figures typed in, printed to PDF
