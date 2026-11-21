# PHCP execution plan - the Python port, and replacing Perl

Status, 19 November 2026.  All six stages done, the Perl removed, and an
audit after them: every Perl test suite and tool ported check for check
(stage 7 and the sections after it), the command line's error paths and byte
handling made the Perl's, and the parity harness kept for good as
`tools/compare_perl.py` (900 / 900 comparison models identical in text,
JSON and exit status), run in CI against the last Perl release (PHCP 1.6.0,
commit cfafeef), which stays the specification.  Read `CONTRIBUTING.md`
before starting.  Its rules are binding, and apply to the Python source
exactly as to the Perl.

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

## Stage 6 - remove the Perl (done on this branch)

The Perl files, the PAR packaging and the Perl CI legs deleted; `phcp.py`
became `phcp` (run as `./phcp`, built as `phcp.exe`).  PHCP now names the
Python Hydraulic Calculation Program: the banner, the report cover, the
graph sheet and the README say so.  The Perl test suites retired with the
program they tested - their ground is held by the frozen comparison set,
kept in `comparison/`, which the port was verified against, and by the
examples the build's smoke test solves; the parity harness
(`tools/compare_python.py`, retired) compared the two programs on every
one of them, text, JSON, report and exit status, before the Perl was
deleted.

## Stage 7 - the remaining suites and tools ported

Nine more of the retired Perl tools ported check for check, each run beside
its Perl original on the same inputs:

| Python | Perl | checks |
|---|---|---|
| `tools/test_pipedata.py` | `test_pipedata.pl` | 39 / 39, output identical |
| `tools/test_dbedit.py` | `test_dbedit.pl` | 42 / 42, output identical |
| `tools/test_tools.py` | `test_tools.pl` | 76 / 76, output identical |
| `tools/test_manual.py` | `test_manual.pl` | 15 / 15, output identical |
| `tools/test_sheet.py` | `test_sheet.pl` | 107 / 107, output identical |
| `tools/check_lisp.py` | `check_lisp.pl` | 5 / 5, identical, also on a broken copy |
| `tools/stress_resolver.py` | `stress_resolver.pl` | 0 problems, identical counts |
| `tools/stress_invariance.py` | `stress_invariance.pl` | identical results (seeds 20260921, 7, 12345) |
| `tools/doc_screenshots.py` | `doc_screenshots.pl` | 15 pictures, under Xvfb |

The stress tools reproduce Perl's random numbers (drand48, and List::Util's
shuffle), so a seed gives the same networks and fitting strings as it did in
Perl; the only difference in their output is the engine named in the
heading.

Two port bugs found and fixed, both outside the comparison set:

- `hardycross/pipedata.py` `resolve`: a fitting on CPVC pipe (a source with
  no corrections, so no basis type) raised a KeyError, which the program
  reported as `MODEL ERROR: 'basis_type'`; the Perl stores undef and solves
  the model.
- `hardycross/sheet.py` `problems`: called before `to_text` had built the
  line map, it raised a KeyError; the Perl's look-up autovivifies to undef.

One Perl check was vacuous: `test_tools.pl`'s "CD of 0" matches
`/MORE THAN 0/`, but both programs answer `CD MUST BE ABOVE ZERO`; the Perl
check passed only through the empty-list-in-`is()` bug.  The Python suite
asserts the words both programs give.

## Suites ported after stage 6

`tools/test_phc.py` (314), `test_json.py` (109), `test_results.py` (28),
`test_acceptance.py` (99), `test_report_checks.py` (615 checks) and
`test_pdf.py` (188 checks): check-for-check ports of the Perl suites, run
against the Perl original first for their counts, which the Python matches.
Part 3 of `test_phc.py` reproduces Perl's drand48 and List::Util's shuffle,
so the same shuffled orders are solved.  Four checks the Perl passed
vacuously (a failed match in `is()`'s list context: the CD and PRA band
messages are in capitals, the patterns were not) are tested for real,
against the messages the Perl gives.

Port bugs these suites found, each checked against the Perl on the same
input and fixed to match it:

- a `.hcx` (or any non-`.phc`) file reached the `.phc` reader and failed on
  its first line; `parse.read_model` now refuses it by name first, as
  `Parse.pm` does (exit 2, `... IS NOT A .PHC MODEL. PHCP READS .PHC FILES
  ONLY`).
- a database dry pipe valve on Schedule 40 pipe (TYCO DPV-1) crashed the
  solve: the reference bore was the database's text.  `pipedata.dry_valve`
  now makes it a number.
- `DPVTRIP`'s open-sprinkler count and air temperature stayed text, so the
  trip estimate crashed and the JSON would print `"open" : "1"` where the
  Perl prints `1`; `phc.py` now stores them as numbers.
- the report's Section 13 printed `DN%d` from the database's text (a
  crash), and dropped every estimated-time row (`dry_time_rows` built the
  rows and threw them away); both fixed, and its note names
  `HardyCross::DryTime` as the Perl's does.
- `jsonout.FALSE` was true in a boolean test; it now tests false, as
  `JSON::PP::false` does.

## The audit of 19 November 2026

What the comparison set does not reach, found by porting the suites and by
`tools/compare_perl.py` beyond it, each fixed to do what the Perl does:

| area | the port did | the Perl does |
|---|---|---|
| usage error | exit 1 | exit 255 (die) |
| report, PDF, --annotate or --save file not writable | a traceback, exit 1 | `cannot write X: reason`, exit errno |
| a file that is not .phc | read it as .phc | `X IS NOT A .PHC MODEL`, exit 2 |
| a model with a Latin-1 byte | refused (UTF-8 decode error) | solved; bytes passed through |
| stdout and --save on Windows | CRLF | LF (binmode) |
| CRLF model, model_sha256 on Linux | hashed without the CRs | hashed as read |
| CPVC pipe with fittings | refused, `MODEL ERROR: 'basis_type'` | solved |
| database dry pipe valve on Schedule 40 | crashed in the friction loss | solved |
| DPVTRIP counts and temperature | text: the trip estimate crashed | numbers |
| report section 13 | crashed on a database DN; trip, transit and delivery rows dropped | printed |
| SCENARIO percentages | crashed the assessment and the JSON | numbers where used |
| auto sizing, tied savings | smallest DN first (example 12: 226 solves in trial 2) | largest first (242) |
| auto sizing, unconverged operating point | went on with its velocities | trial failed |
| OPTION SIZING_TRIALS | crashed | used |
| supply graph file | crashed writing a number; own message for a missing file | as written; `CANNOT READ` |
| JSON false | true when tested | false |
| spreadsheet problems before to_text | KeyError | none |
| database editor SAVE on Windows | failed: os.rename will not replace pipes.dat (found by CI's Windows run) | replaced; a failure is `CANNOT REPLACE` |
| the editor's and spreadsheet's .phc, the editor's text report, on Windows | LF; the sheet in the locale's encoding | text mode: CRLF on Windows, UTF-8 |

Outside the engine: the Revit ENGINE button ran `phcp` directly, which
Windows cannot start (now run with Python); `comparison/tools/rerun_phcp.py`
still ran the deleted `phcp.pl`; `build_windows.py` left the programs in
dist\, away from the office `data\pipes.dat`, and did not read the icon
back as it said (now beside the source, checked by `tools/check_exe_icon.py`);
CI ran 3 of the suites and no parity check (now every suite, the stress,
the screenshots, the icon checks, the Windows suites and the parity job).

Five Perl checks (four in test_phc, one in test_tools) passed without
testing anything: a failed match inside `is(...)`'s arguments shifts the
explanation into the result.  The Python checks test the messages both
programs really give; the counts are unchanged.

## The line-by-line audit of 20 November 2026: the solver core, the network builder, the settings and the command line

`HardyCross.pm`, `HardyCross/Parse.pm`, `HardyCross/PumpCheck.pm`,
`HardyCross/Settings.pm` and `phcp.pl` read side by side with their Python,
every function, and each suspected difference run through both programs.
Each one below was confirmed against the Perl 1.6.0 and fixed to do what it
does; `tools/test_phc.py` section 12 (24 checks) and `tools/test_curves.py`
section 7 (8 checks) hold them.

| area | the port did | the Perl does |
|---|---|---|
| a pipe that carries nothing, in no loop (a ring with no outlet, hung off the network by one pipe) | `Q BR -0.0000` | `Q BR 0.0000` where the flows that cancel are whole numbers (Perl adds those as integers), `-0.0000` where they are not |
| an elevation or a value typed `-0`, `-0.0` | minus zero: `-0.000` in the report and the saved results | plain zero (`$t + 0`) |
| a figure too large to raise to a power (a bore of 1E80 mm, a K of 1E200, a curve point at 1E300) | refused, `MODEL ERROR: (34, 'Numerical result out of range')`, exit 2 | infinity: solved |
| a solve that runs away to not-a-number | `Q P1 nan` | `Q P1 NaN` (and `Inf`, `-Inf`) |
| a nominal size no integer holds (`PIPE ... 1e30` under a pipe type) | `DN1000000000000000019884624838656` | `DN-1`, as `%d` prints it |
| a report path ending `.pdf` and a newline | the text report | the PDF (`/\.pdf$/i`) |
| `fit=2E,1T` in a row (lower case) | cut at the commas | one token, as `FIT=` is (`/gie`) |
| digits that are not 0-9 (Arabic-Indic, full-width) handed to `is_num` | a number | not a number |
| a row shorter than its section expects (`SUPPLIES S N STATIC`, `PUMPDUTY P1`, an empty row) | IndexError | the missing token is undef: 0, or the section's own refusal |
| `DPV ... MODE=TRIP` with no `TRIP=` | TypeError | a trip pressure of 0 |
| an element of no known kind | the message without its newline | `internal error: ...` and the newline |
| `b3_reference_flow` of a DN held as text | 5000 | 500 for "50" and "65" |
| settings file with a byte that is not UTF-8 (a Latin-1 folder name) | UnicodeDecodeError | read, byte for byte |
| settings: a lone carriage return, a no-break space or a control character at the end of a value | a line end; trimmed | part of the value |
| `PHCP_DATABASE_DIR` set to nothing | the file's `DATABASE_DIR` | the program's own database (`//`) |
| `PHCP_SETTINGS=0`; `HOME` empty, `.` or with `//` in it | used as the file; `./.config/...`, `/a//b/.config/...` | not set; `/.config/...`, `.config/...`, `/a/b/.config/...` (File::Spec) |
| a settings file that cannot be written | `[Errno 21] Is a directory: ...` | `cannot write the settings file X: Is a directory` |
| an error nothing catches (a fault in the program, a damaged font file) | a traceback, exit 1 | one line, exit 255 (die); the Python prints its own words, one line, exit 255 |

Left as it is, and why: a solve that runs away carries flows past 2^53 for the
one sweep in which it is found to have diverged (INDETERMINATE, exit 1), and
those flows are printed.  Perl adds whole numbers that large as exact 64-bit
integers where a float rounds, so they can differ from the Perl's in the last
digits (`Q P68 -13666017801514226.0000` for `...224.0000`).  Below 2^53, which
is every solve that converges, the two are the same arithmetic.

Also left: a typed pipe given a C of 0 (`USE ASAM 0`), or a bore
below about 1E-66 mm, divides by zero in the friction loss.  Both programs
refuse the model with exit status 2; the Perl's reason is its interpreter's
own, naming its source file and line (`Illegal division by zero at
.../HardyCross.pm line 322.`), the Python's is `float division by zero`.

## The line-by-line audit of 20-21 November 2026

After 2.0.0 was merged, every Perl sub was read beside its Python
translation (seven reviews: the solver core, parser and command line; the
.phc reader, database and sizing; validation, demand and supplies; the
report, JSON and results block; the PDF, graph, tools and database editor;
the editor, spreadsheet and isometric logic; the three Tk windows, with the
Perl windows run under Perl/Tk beside the Python ones).  Each difference was
confirmed by running both programs, corrected, and given a check in the
module's suite.  `tools/fuzz_perl.py` was added: good models with random
changes, through both programs.  What it and the reviews found is in the
tables above and in the suites' "port audit" sections; the ones a user
could have met:

- `--json` crashed when the governing outlet was a fixed flow with a
  minimum pressure; the report crashed when a supply took water in
- `phcp_editor.py model.phc` did not open the model; WRITE REPORT with no
  name crashed; a discarded proposal came back on Ctrl+Y
- the spreadsheet's VALIDATION tab, its PROJECT drop-downs and its
  CALCULATE state did not follow the sheet; dragging a point in the
  isometric window did nothing; a click in the DATABASE tab took the row
  below
- a model or database with a Latin-1 byte was refused or re-encoded
- the PDF's font streams were deflated differently (memLevel 8, the Perl 9)

### Differences that remain, deliberately

| what | the Perl | the Python | why |
|---|---|---|---|
| a node head that is not finite | crashes in Validate.pm line 233 (exit 255) | the NONFINITE finding, INDETERMINATE (exit 1) | the finding is what the Perl meant to make |
| whole numbers past 2^53 (a solve that has run away; `"value"` and `MARGIN` figures that size) | exact 64-bit integers | floats | only in solves both report as diverged, or on absurd inputs; matching it means carrying integer typing through the engine |
| several things wrong at once in a refused model | names one of them, which one changes from run to run (hash order) | the first in file order | the Perl is not one answer |
| an internal failure's words (`Illegal division by zero at ... line 322.`) | the interpreter's | Python's, on one line, same exit status | not the program's own text |
| Perl `use warnings` lines on stderr | printed | not printed | diagnostics, not output |

Copied from the Perl although they are defects there (say if the better
behaviour is wanted instead): a pipes.dat with no newline at its end cannot
be saved over from the DATABASE tab (`THE DATABASE WAS SAVED BY SOMEONE
ELSE`); in the spreadsheet a grid refreshed in place takes the keyboard
focus off the cell.

Not verified: the JSON of `examples/04_grid1000` against the Perl (the Perl
does not finish it in the time there is; its text output is identical);
anything inside AutoCAD or Revit; the windows on Windows itself beyond the
suites CI runs there.
