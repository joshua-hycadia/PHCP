# PHCP - rules for contributors

PHCP is Hycadia's Hardy Cross hydraulic calculation program for fire sprinkler
and hydrant networks, written entirely in Python (the Perl original was
retired after the port was verified byte for byte against it; see
PYTHON_PORT.md).  Its results go into calculations submitted to authorities,
so correctness and honesty about status come before speed.

Read `PLAN.md` first.  It is the execution plan for the current work and says
which pull request is next.

## Binding rules

### Process

- Work on a feature branch named in `PLAN.md`.  Never push to `main`, never
  merge.  Open a pull request; the maintainer reviews and merges.
- One pull request per plan stage.  Do not start the next stage until the
  previous one is merged, unless the maintainer says otherwise.
- Run every test below before each commit.  Report the results in the pull
  request.
- Update `PLAN.md` (status line and checklist) in the same pull request.

### The engine

- Do not change `hardycross/__init__.py`, `hardycross/demand.py`,
  `hardycross/pipedata.py`, `hardycross/report.py` or `hardycross/pdfout.py`
  except where `PLAN.md` says to.  Any change that alters a solved number
  needs the maintainer's approval first; ask, do not decide.
- New input formats translate into the existing parser; they do not
  re-implement its checks, defaults or unit handling.

### Naming - what not to mention

- Do not name any other hydraulic calculation program as the model for PHCP's
  input language, editor or features, in code, comments, documentation,
  commit messages or pull requests.  Describe PHCP's features on their own
  terms.
- Do not refer to any internal Hycadia document, document number or revision as
  the source of the pipe and fitting data.  It is "the pipe and fitting
  database", `data/pipes.dat`.  Published standards (AS 2118.1, FM Global
  DS 3-0, AS 1074 and so on) may be named as the source of individual values,
  as they are now.

### The pipe and fitting database

- `data/pipes.dat` is user editable.  The report prints its DATASET name,
  file name and SHA-256; keep it that way.
- Never change a value in it without the maintainer asking.  If a test against it
  fails, report the failure; do not edit the expected value to match.

### README.md - keep it current, always

`README.md` must describe the program as it is on the branch being committed.
A stale README is a defect.

- Update it in the same commit as the change, never in a later "docs" commit.
- Check it whenever a change touches: command-line usage, input format,
  editor keys or menus, report sections, build routes or platform status,
  files added, removed or renamed, or solver behaviour.
- Before each commit, re-read the README sections the diff touches.  If
  nothing needs changing, say so in the pull request.
- Be honest about status: write "untested" or "not yet run" until something
  has actually been run.  Never claim conformance with a standard that has
  not been checked against it.
- `docs/USER_GUIDE.md` is held to the same rule for what a designer sees: a
  window, a tab, a key, a result or an exit code.  Its pictures come from
  `tools/doc_screenshots.pl`.  When a window changes, take them again: CI's
  Linux job keeps a fresh set as the `user-guide-screenshots` artefact on
  every run, so copy those into `docs/images/` rather than taking them by hand.
- The guide and the reference manual are published as Word and PDF
  (`docs/PHCP_User_Guide.*`, `docs/PHCP_Reference_Manual.*`).  Edit the
  Markdown, never the .docx, and rebuild both with `python tools/build_docs.py`
  in the same commit: on a PC with Word for the best PDF, or LibreOffice.
  In a release commit add `--release`, so the title page and footers name
  the version alone, as the tag will, not the commit before it.

### Style

- Australian practice: L/min, kPa, m, mm, AS 2118.1.
- Code full of comments: say why, not just what, so a stranger can follow
  and check it.  Match the density of the existing modules.
- Reports are 7-bit ASCII, monospace.  The PDF prints the same text in an
  embedded monospace face (data/fonts), with rules and the supply graph drawn.  User interface labels and menus in
  capitals.
- No emojis anywhere.  Clear, concise prose.

## Tests - run all before every commit

```
python3 tools/test_editor.py            # the editor's logic, headless
python3 tools/test_isometric.py         # the isometric drawing, and the .phc it writes
python3 tools/test_revit.py             # the Revit extension, without Revit
python3 tools/test_editor_window.py     # the editor window (re-runs under xvfb-run)
python3 tools/test_sheet_window.py     # the spreadsheet window (re-runs under xvfb-run)
python3 tools/test_isometric_window.py  # the isometric window (re-runs under xvfb-run)
python3 tools/test_impossible.py       # tools/impossible/: models that must not be accepted
python3 tools/test_validate.py             # validation and the false positives it catches
python3 tools/test_velocity_pressure.py    # OPTION VELOCITY_PRESSURE, against a hand check
python3 tools/test_curves.py               # supply, pump and loss curves, the orifice plate Cd
python3 tools/test_drytime.py              # the dry pipe valve trip and transit estimates
python3 tools/test_sizing.py               # auto pipe sizing
python3 tools/test_graph.py                # the Q^1.85 supply graph, its file, sheet and report appendix
```

CI (`.github/workflows/ci.yml`) runs these on Linux and the build on
Windows, on every pull request.

Add the new suites from `PLAN.md` to this list as they are written.
No packages beyond PyInstaller (for the Windows build) and python-docx
(for the docs); everything else is the standard library.
