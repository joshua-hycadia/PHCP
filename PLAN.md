# PHCP execution plan - command-file input and text editor

Status: PR 1 merged.  PR 2 (`.phc` language) being reworked to the positional
layout Joshua chose on 28 October 2026; PR 3 (editor) open on top of it.

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
PRA       <PIPE> ...                                    // pressure ratio valve: awaiting the
                                                       // technical data; a new solver element
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
- [ ] PR 2 - PRA pressure ratio valve in the solver (engine change, data from Joshua)
- [x] PR 2 - supply, pump and loss curves interpolated on Q^1.85 through every point
  (engine change, approved by Joshua 28 October 2026; `tools/test_curves.pl`)
- [x] PR 2 - `FIXEDFLOW MINP=` decision recorded: checked, by Joshua's decision -
  passed or failed in the report and counted in the governing outlet and demand
  point (README, "Fixed flows")
- [ ] PR 3 - `Editor.pm` and `phcp_editor.pl`
- [ ] PR 3 - spreadsheet removed, build script and licence updated
- [ ] PR 3 - Windows build run by Joshua
