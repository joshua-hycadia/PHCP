# PHCP execution plan - command-file input and text editor

Status: PR 1 merged.  PR 2 (`.phc` language) and PR 3 (text editor, built on
PR 2) open for review.  PR 4 and PR 5 not started.

This plan replaces the spreadsheet front end with a plain-text command file
(`.phc`) and a text editor built around it.  The solver, the report, the PDF
writer and the pipe and fitting database are NOT changed by this work.

Read `CONTRIBUTING.md` before starting.  Its rules are binding.

---

## Goal

A designer types the model as short command lines - one element per line, in
any order - into an editor that colours each line as it is typed, flags errors
on the line they occur, proposes the next line, offers pipe types and fittings
from the database, and solves on one key.  Existing `.hcx` models convert
automatically and give identical results.

## Ground rules for this work

- **The engine does not change.**  `HardyCross.pm`, `HardyCross/Demand.pm`,
  `HardyCross/PipeData.pm`, `HardyCross/Report.pm` and `HardyCross/PDF.pm`
  are touched only where this plan says so.  Any change that alters a solved
  number needs Joshua's approval first.
- **The `.phc` reader translates; it does not re-implement.**  Each `.phc`
  command is turned into the equivalent `.hcx` row and handed to the existing
  `HardyCross::Parse::parse_row`.  Every check, default and unit conversion
  therefore stays in one place, and a `.phc` model cannot quietly mean
  something different from its `.hcx` equivalent.
- **Identical results are the acceptance test.**  Every example is converted
  to `.phc`; the converted file must give a report identical to the `.hcx`
  original apart from the model file name on the cover.

---

## PR 2 - the `.phc` command language

Branch: `phc-language`.

### Files

| file | purpose |
|---|---|
| `HardyCross/Phc.pm` | reader for `.phc` text, plus the line-level checks the editor uses |
| `HardyCross/Convert.pm` | `.hcx` to `.phc` writer |
| `HardyCross/Parse.pm` | `read_model` dispatches on extension: `.phc` to Phc.pm, anything else as now |
| `phcp.pl` | accepts `.phc` and `.hcx`; new `--convert in.hcx [out.phc]` |
| `examples/*.phc` | every example converted; the `.hcx` originals stay as the regression baseline |
| `tools/test_phc.pl` | language tests (below) |

### Language

General rules:

- One command per line.  The first word is the command; commands and
  keywords are case-insensitive; ids are case-sensitive as now.
- Fields are separated by spaces or tabs.  `//` starts a comment to the end of
  the line.  A blank line is ignored.
- `KEY=value` options may appear anywhere after the fixed fields.
- Element lines may appear in **any order**.  `Units`, `Method` and `Option`
  are file-wide wherever they appear, and may each name a given setting only
  once.  `Use` is the only positional command: it applies to the `Pipe` lines
  after it, until the next `Use`.
- A node used by a pipe or outlet but never given a `Node` line is an error
  that names the node and the first line using it.  (Today `.hcx` creates such
  a node at elevation 0 silently; in `.phc` it must be explicit.  The
  converter writes a `Node` line for every node, so converted files are
  unaffected.)
- Every error message carries the `.phc` line number it came from.

Commands - every element and setting PHCP has today:

```
Title    <text>                                  // PROJECT TITLE
Project  <FIELD> <text>                          // any PROJECT field: COMPANY, JOB, ...
Units    [FLOW=LPM] [PRESSURE=KPA] [LENGTH=M] [DIAMETER=MM]
Method   HW | DW
Option   <NAME> <value>                          // PROFILE HW_CONST NU TOL_FLOW TOL_LOOP
                                                 // MAXITER RELAX VEL_LIMIT FITTING_BASIS
                                                 // ORIF_STEP
Use      <PIPETYPE> [C=<c>]                      // pipe type from the database
Use      BORE [C=<c>]                            // following pipes give a bore, not a DN
Node     <id> <elevation>
Pipe     <id> <n1> <n2> <length> <size> [fittings ...] [C=] [EQV=] [EPS=] [K=]
Supply   <id> <node> STATIC <pressure> [Z=]
Supply   <id> <node> CURVE <q1> <p1> <q2> <p2> [...] [Z=]
Pump     <id> <in> <out> <q1> <p1> <q2> <p2> [...]
Head     <id> <node> [K=] [Q=] [P=] [Z=]          // sprinkler: any two of K, Q, P
Hydrant  <id> <node> [K=] [Q=] [P=] [Z=]
HoseReel <id> <node> [K=] [Q=] [P=] [Z=]
Flow     <id> <node> Q=<q> [MINP=]                // fixed flow
BFP      <id> <n1> <n2> <q1> <p1> <q2> <p2> [...]
PRV      <id> <n1> <n2> DP=<drop>
Orifice  <id> <n1> <n2> DP=<drop>  DN=|PIPEDIA= [CD=]   // sizes the plate
Orifice  <id> <n1> <n2> BORE=<d>   DN=|PIPEDIA= [CD=]   // known bore
```

- `<size>` is the nominal DN under `Use <PIPETYPE>` and the bore under
  `Use BORE`.  Before any `Use`, pipes are `Use BORE C=120`, matching `.hcx`.
- Fittings are written after the size, one token each, with an optional count:
  `2E T GV` means `FIT=2E,1T,1GV`.  The office forms `2E,1T` and `1E1T` are
  also accepted in a single token.  Fittings on a `Use BORE` pipe are an error,
  as today.
- `Units` takes the same unit codes `.hcx` accepts.
- An unrecognised `Option` is an error.  (`.hcx` silently ignores unknown
  OPTIONS - example 01 carries `TRACE FULL`, which does nothing.  The converter
  drops such lines and lists them in the header comment it writes.)

Example - `examples/01_single_branch` as `.phc`:

```
Title  SINGLE BRANCH CLOSED-FORM CHECK
Units  FLOW=LPM PRESSURE=KPA LENGTH=M DIAMETER=MM
Method HW
Option TOL_FLOW 0.001
Option TOL_LOOP 0.0005

Node   N1 0.0
Node   N2 0.0
Pipe   P1 N1 N2 100.0 100.0 C=120
Supply SUP1 N1 STATIC 900
Head   S1 N2 K=80 P=50
```

### How the reader works

1. Read every line; strip comments; tokenise with the existing
   `HardyCross::Parse::tokenize` so quoting and number rules match.
2. First pass: collect `Title`, `Project`, `Units`, `Method`, `Option`.
   Reject a second setting of the same unit or option.
3. Second pass: translate each element line into its `.hcx` row, tagged with
   its `.phc` line number, and file it under the `.hcx` block it belongs to.
4. Build `.hcx` text in the block order `PROJECT, UNITS, OPTIONS, NODES`,
   then the elements in FILE order, each run of one kind under its own block
   header.  This order matters: supply and outlet elevations default to their
   node's elevation, which must already be read.  (As built in PR 2: the
   elements are not regrouped into `PIPES, PUMPS, SUPPLIES, DISCHARGES,
   DEVICES`, because that reordered example 06, whose `.hcx` lists its devices
   before its supply, and the report's schedule rows moved with it.)
5. Parse it with the existing code.  Map any error's `.hcx` line number back
   to the `.phc` line it came from.

### Line checking for the editor

`HardyCross::Phc::check_line($line, $context)` returns, without Tk:

- `status`: `ok`, `incomplete` (still being typed) or `error`, plus a message;
- `template`: the command's field list, and which field the cursor is in, for
  the status bar;
- `choices`: for a pipe-type or fitting field, the codes from the database;
- `proposal`: the suggested next line (see PR 3).

`$context` carries the defined node ids and the current `Use`.  All of this is
tested headless in `tools/test_phc.pl`.

### Converter

`phcp.pl --convert model.hcx [model.phc]` writes `.phc` from a parsed `.hcx`:
a header comment, then settings, `Node` lines, `Use` groups, then the other
elements.  Comments in the `.hcx` are not carried over; the converter says so
in the header comment it writes.

### Tests - `tools/test_phc.pl`

- Every example: convert, solve both, compare reports - identical apart from
  the model file name.
- Every command: a valid line, a line missing each required field, a bad
  number, an unknown option, a duplicate setting.  Each error names its line.
- Any order: shuffle the element lines of each example; the solved results
  must be identical (iteration counts may differ).
- `Use` scoping, fitting tokens in all three forms, units given out of order.
- `check_line` status, template and choices for each command.

### Known issue to resolve, not hide

`FIXEDFLOW ... MINP=` is accepted by today's parser but the minimum pressure is
not used: only the flow is applied.  `.phc` must not accept `MINP=` silently.
Either make it a reported error ("not supported") or raise it with Joshua
before implementing it.  Record the decision in the README.

Resolved in PR 2, by Joshua's decision: the minimum pressure is checked (see
the checklist and README, "Fixed flows").

---

## PR 3 - the text editor

Branch: `phc-editor`.

### Files

| file | purpose |
|---|---|
| `HardyCross/Editor.pm` | editor logic with no Tk: proposals, completion, undefined nodes, results lookup |
| `phcp_editor.pl` | the Tk window, kept thin |
| `tools/test_editor.pl` | headless tests of `Editor.pm` |
| `phcp_gui.pl`, `tools/test_gui_document.pl`, `tools/test_gui_editing.pl` | **removed** - the spreadsheet is retired |
| `phcp_viewer.pl` | kept; reads `.phc` through `read_model` |
| `build_windows.bat` | builds `phcp.exe` and `phcp_editor.exe`; Tk::TableMatrix no longer needed |
| `LICENSE` | drop Tk::TableMatrix from the third-party list |

### Window

Two panes side by side - EDITOR on the left, REPORT on the right - with a
status bar and a problems list below.  Labels and menus in capitals, as the
rest of PHCP.  Monospace throughout.

### Editor behaviour

| feature | behaviour |
|---|---|
| colouring | command words in blue, comments grey; a line with an error is red, its message in the status bar when the cursor is on it and in the problems list |
| status bar | the field template of the current command, current field highlighted |
| proposals | after Enter, the likely next line is shown greyed: same command, ids stepped (P7 to P8), a pipe starting where the last one ended.  Enter or Tab accepts; typing anything else discards it.  Holding Enter repeats |
| pick list | Ctrl+Space in a `Use` type field or a fitting field opens the codes from the database, with descriptions; arrows and Enter insert |
| undefined nodes | a panel lists nodes used but not defined, with the line that first uses each |
| solve | F5 solves the buffer and fills the REPORT pane; an error moves the cursor to its line |
| results on the cursor | after a solve, the status bar shows the solved flow, velocity and end pressures for the element on the cursor's line |
| files | NEW, OPEN, SAVE, SAVE AS, WRITE REPORT (Ctrl+R, `.pdf` or `.txt`).  Opening a `.hcx` converts it into a new unsaved `.phc` buffer and says so |
| undo | Ctrl+Z / Ctrl+Y, Tk text undo |

### Tests

- `tools/test_editor.pl`, headless: proposals for each command, pick-list
  contents, undefined-node detection, results lookup after a solve.
- Window: run under Xvfb if available.  If the window itself cannot be run in
  the build environment, the README says "not yet run" for it.

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
- [x] PR 2 - `.phc` reader, converter, examples, `test_phc.pl`
- [x] PR 2 - `FIXEDFLOW MINP=` decision recorded: checked, by Joshua's decision -
  passed or failed in the report and counted in the governing outlet and demand
  point (README, "Fixed flows")
- [x] PR 3 - `Editor.pm` and `phcp_editor.pl` (light blue and black, by Joshua's choice)
- [x] PR 3 - spreadsheet removed, build script and licence updated
- [ ] PR 3 - Windows build run by Joshua
- [ ] PR 4 - AutoCAD exporter writes `.phc`; `.hcx` only through `--convert`
- [ ] PR 5 - `phcp.exe --json`, documented and tested
- [ ] PR 5 - AutoCAD SOLVE command run by Joshua
