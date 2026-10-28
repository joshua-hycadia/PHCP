# PHCP - rules for contributors

PHCP is Hycadia's Hardy Cross hydraulic calculation program for fire sprinkler
and hydrant networks, written entirely in Perl.  Its results go into
calculations submitted to authorities, so correctness and honesty about status
come before speed.

Read `PLAN.md` first.  It is the execution plan for the current work and says
which pull request is next.

## Binding rules

### Process

- Work on a feature branch named in `PLAN.md`.  Never push to `main`, never
  merge.  Open a pull request; Joshua reviews and merges.
- One pull request per plan stage.  Do not start the next stage until the
  previous one is merged, unless Joshua says otherwise.
- Run every test below before each commit.  Report the results in the pull
  request.
- Update `PLAN.md` (status line and checklist) in the same pull request.

### The engine

- Do not change `HardyCross.pm`, `HardyCross/Demand.pm`,
  `HardyCross/PipeData.pm`, `HardyCross/Report.pm` or `HardyCross/PDF.pm`
  except where `PLAN.md` says to.  Any change that alters a solved number
  needs Joshua's approval first; ask, do not decide.
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
- Never change a value in it without Joshua asking.  If a test against it
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
perl tools/test_phc.pl              # .phc language (--full also solves 04)
perl tools/test_curves.pl           # supply, pump and loss curves
perl tools/test_pipedata.pl         # pipe and fitting database, 35 checks
perl tools/test_report_checks.pl    # report hand-checks across the examples
perl tools/test_pdf.pl              # PDF structure checks
perl tools/stress_resolver.pl       # fitting resolver
perl tools/stress_invariance.pl 20  # invariance stress (use 60 before a PR)
perl tools/test_editor.pl           # the editor's logic, headless
perl tools/test_editor_window.pl    # the editor window (re-runs under xvfb-run)
```

Add the new suites from `PLAN.md` to this list as they are written.
No CPAN modules beyond Tk and PAR::Packer (for the
Windows build); everything else is core Perl.
