# PHCP execution plan - the Python port, and replacing Perl

Status, 17 November 2026.  On branch `job/python-port`, not yet merged: the
engine and the command-line program ported to Python (`hardycross/`,
`phcp.py`), verified byte for byte against the Perl on the frozen comparison
set.  Nothing in the Perl has been changed: the port runs beside it, and the
Perl stays the released program until the last stage is merged.  Read
`CONTRIBUTING.md` before starting.  Its rules are binding, and apply to the
Python source exactly as to the Perl.

## Goal

The same program, in Python: the same `.phc` language, the same solver, the
same validation and acceptance, the same report, the same JSON, the same exit
statuses - until the Perl can be removed without any caller noticing.  The
port is judged on one thing only: **byte-for-byte agreement with the Perl**
on the frozen comparison set (`comparison/models/`, 300 models with frozen
results), on the text output, the JSON output and the exit status of each,
and on the saved results block (`--save`).  A number that differs is a bug
in the port, not a rounding choice.

## Ground rules for this work

- **The Perl is the specification.**  The Python is a translation of it,
  module by module, function by function; where the two could disagree the
  Perl is right until the maintainer says otherwise.  A change that alters a
  solved number needs the maintainer's approval first.
- **Byte parity, not "close enough".**  The harness (`tools/compare_python.py`)
  runs both programs on every comparison model and diffs the output and the
  exit status.  The stage is done when the diff is empty.
- **Pure standard-library Python.**  No third-party packages in the engine,
  so the program installs anywhere Python is.  (The pyRevit extension
  already calls the engine as a subprocess; it is unaffected.)
- **The Perl keeps running.**  No stage removes a Perl file.  The final
  stage - removing the Perl - is its own pull request, after everything
  else has been merged and run in the field.

## Module map

| Perl | Python | what it is |
|---|---|---|
| `phcp.pl` | `phcp.py` | the command-line driver |
| `HardyCross.pm` | `hardycross/__init__.py` | the solver core |
| `HardyCross/Parse.pm` | `hardycross/parse.py` | the `.hcx` command parser |
| `HardyCross/Phc.pm` | `hardycross/phc.py` | the `.phc` reader and line checks |
| `HardyCross/PipeData.pm` | `hardycross/pipedata.py` | the pipe and fitting database |
| `HardyCross/Settings.pm` | `hardycross/settings.py` | the settings file |
| `HardyCross/PumpCheck.pm` | `hardycross/pumpcheck.py` | pump duty checks |
| `HardyCross/Validate.pm` | `hardycross/validate.py` | validation, acceptance, assessment |
| `HardyCross/Demand.pm` | `hardycross/demand.py` | the demand point |
| `HardyCross/Supplies.pm` | `hardycross/supplies.py` | several supplies |
| `HardyCross/DryTime.pm` | `hardycross/drytime.py` | dry pipe valve trip and transit |
| `HardyCross/Results.pm` | `hardycross/results.py` | the results block saved in the model |
| `HardyCross/Json.pm` | `hardycross/jsonout.py` | the JSON interface (2) |
| `HardyCross/Report.pm` | `hardycross/report.py` | the ASCII report (unit helpers so far) |
| `HardyCross/Sizing.pm` | `hardycross/sizing.py` | auto pipe sizing |
| `HardyCross/Areas.pm` | `hardycross/areas.py` | design areas |

Perl semantics the port keeps deliberately, so numbers cannot drift: nodes
and elements are 1-based with a `None` at index 0; adjacency is built in the
Perl order (append, then the reverse pass where Perl unshifts); number
formatting uses the Perl stringifications (`%.10g` for row text, `%.15g` for
JSON numbers); the JSON encoder reproduces JSON::PP's canonical-pretty-ascii
output (3-space indent, sorted keys) byte for byte.

## Stage 1 - the engine and the command line (this branch)

**Done.**  The solver, the parser and `.phc` reader, the validation and
assessment layer, the demand point, the multiple-supply schedule, the dry
pipe valve estimates, the results block and the JSON - all of it that the
comparison set exercises - ported and verified:

- `tools/compare_python.py --text-only`: **300 of 300 models identical**
  (text output and exit status).
- `tools/compare_python.py --json-only`: the JSON interface, including the
  demand point and the supply schedule.
- stdin (`phcp.py --json -`), `--strict` (exit 4 on NONCOMPLIANT), `--save`
  (results block identical, timestamp line aside) all verified against the
  Perl.

Still to port in later stages: the three windows and the Windows packaging.

## Stage 2 - the ASCII report and the PDF (done on this branch)

`Report.pm` ported in full (`hardycross/report.py`): the cover sheet, the
15 numbered sections, the supply graph appendices and `--save`-side helpers,
verified byte for byte on the comparison set
(`phcp.py model.phc report.txt` against `phcp.pl model.phc report.txt`;
`tools/compare_python.py --report` runs both on a model and diffs).
`PDF.pm` ported as `hardycross/pdfout.py`: the same paginated print of the
ASCII report, with the fonts embedded whole and the supply graph drawn from
the same numbers.  A report PDF written by each agrees byte for byte except
the creation timestamp and the compressed font streams (the zlib in this
sandbox's Perl and its Python differ); the fonts themselves decompress to
identical bytes.  The `.phg` supply-graph file, its sheet and its PDF page
(`Graph.pm` -> `hardycross/graph.py`) are ported with the same parity
checks (text sheet identical; sheet content stream identical).

## Stage 3 - the remaining engine surface (done on this branch)

`Sizing.pm` -> `hardycross/sizing.py`, `Areas.pm` -> `hardycross/areas.py`,
`Tools.pm` -> `hardycross/tools.py` and `DbEdit.pm` -> `hardycross/dbedit.py`
ported.  The calculators behind QUICK TOOLS and ORIFICE PLATE were checked
case by case against the Perl (velocity, K-factor, K conversion, loss by
both methods, fittings, orifice plate in both modes, unit conversions, every
error message), and the database editor headlessly (row edits that keep the
original text of unchanged fields, add/delete with the cross-checks,
check_all on a broken file, save with the SHA-256 guard, unchanged file
round-trips to the same bytes).

## Stage 4 - the windows (done on this branch)

The editor, spreadsheet and isometric windows in Tkinter (already the
toolkit of `phcp_editor.pl`), one window per pull request if they are
large.  Headless test harnesses first, driven windows second, as the
Perl's are.  All three are ported and green, each beside the Perl suite
it mirrors:

- `hardycross/editor.py` + `hardycross/window/editor.py` +
  `phcp_editor.py`: `tools/test_editor.py` 117/117,
  `tools/test_editor_window.py` 167/167.
- `hardycross/sheet.py` + `phcp_sheet.py`:
  `tools/test_sheet_window.py` 62/62.
- `hardycross/isometric.py` + `hardycross/window/isometric.py` +
  `phcp_isometric.py`: `tools/test_isometric.py` 42/42 (the model,
  including byte-identical read/write round-trips against the Perl on
  the smoke networks), `tools/test_isometric_window.py` 31/31 (the
  Perl's own suite is 29/29; the Python's has the two checks the
  Perl's empty-list bug left vacuous, probed and asserted for real).

One vacuous Perl check was found and confirmed live in the process: a
`run-in-progress` click on an existing off-axis point is refused by the
Perl and the Python alike; the Perl's test never actually verified its
intended claim through the `is(name, COND1 && COND2, $why)` empty-list
path.  The Python suite asserts both the shared refusal and the intended
join after the tool switch.

## Stage 5 - packaging and CI (done on this branch)

`build_windows.py` builds `phcp.exe`, `phcp_editor.exe`, `phcp_sheet.exe`
and `phcp_isometric.exe` from the Python source with PyInstaller, the
counterpart of `build_windows.bat` (the Perl, PAR::Packer): the database,
the PDF typefaces and the icon packed inside the one file, the same
smoke test run against the built `phcp.exe`.  `hardycross.pipedata`,
`pdfout` and `win` look for their data in `sys._MEIPASS` as well, so a
one-file build is self-contained.

CI runs the Perl and Python suites side by side (`test-linux`), the
byte-parity harness on every push (`test-parity`: the frozen comparison
set, text, JSON and exit status, solved both ways), and the PyInstaller
build on Windows (`build-windows-python`) beside the PAR::Packer one
(`build-windows`).  `tools/test_impossible.py` ports the last
Perl-only suite the CI ran through the built program.

Two port bugs this stage's own checks caught, both in the dry pipe
valve path the comparison set does not reach: the database DN lookup
(Perl stringifies a hash key, the port's `dry_valve` now normalises
with `_dnkey`) and the JSON writer's Perl numification of database
text (`0 + $dn`), now `_numify` in `hardycross/jsonout.py`.  After both,
`tools/impossible/dpv_no_loss_data.phc` is byte-identical in text and
JSON and the impossible-model suite is 20/20 against the Perl's 20/20.

## Stage 6 - remove the Perl

Branch: `job/remove-perl`.  The Perl files, the PAR packaging and the Perl
CI legs deleted; `phcp.py` becomes `phcp`.  Not before stage 5 has run in
the field for a release cycle.
