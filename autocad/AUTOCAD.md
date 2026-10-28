# PHCP export for AutoCAD 2026

`phcp_export.lsp` turns a 2D pipework layout into a PHCP model (`.phc`), so the
network is never typed in by hand.

Copyright (c) 2026 Hycadia Pty Ltd - MIT licence, see LICENSE.

## Load it

`APPLOAD`, select `phcp_export.lsp`, Load.  To load it every session, add it to
the Startup Suite in the same dialog.

## Mark up a drawing

Snap to pipe ENDpoints throughout - a symbol placed a few millimetres off a pipe
end is not on the network.

1. **PHCPSETUP** - PHCP layers and symbols, and the symbol size (150 mm default).
2. **PHCPPROJECT** - job name, number, company, designer, hazard class, design
   density, area per sprinkler and authority, for the cover sheet.  Stored in
   the drawing.
3. **PHCPSUPPLY** - pick the connection point; a static pressure, or for a curve
   the static pressure (at zero flow) and then the flow and pressure points of
   a flow test or water authority statement.
4. **PHCPPIPE** - select lines or polylines of one size; give pipe type, DN,
   optional C, fittings (`2E,1T` or `1E1T`), and a length override for a riser.
   Each size is one selection; the last values are the defaults.
5. **PHCPELEV** - pick the nodes at one elevation, Enter; repeat per level.
6. **PHCPHEAD** - **Tag** the sprinkler blocks already in the drawing, or
   **Place** PHCP head symbols.  Two of K, minimum pressure and minimum flow.
   Give a head elevation and drop size to model the drop from the branch line.
7. **PHCPCHECK** - checks without exporting.  Faults are listed, and the objects
   responsible are selected on screen.
8. **PHCPEXPORT** - checks, then writes the `.phc` and optionally tags node and
   pipe IDs on layer PHCP-TAGS, so the calculation reads against the drawing.

Open the `.phc` in the PHCP editor to validate, calculate and write the report,
or run `phcp.exe model.phc report.pdf`.

9. **PHCPSOLVE** - exports to a `.phc` beside the drawing, runs
   `phcp.exe --json` on it, and shows the result at the command line and in a
   box: whether it converged, the governing outlet and its margin, every
   outlet that fails, and whether the supply meets the demand.  The first time,
   it asks where `phcp.exe` is and remembers it.

## What the export looks like

`examples/08_autocad_export_format.phc` is a file exactly as PHCPEXPORT
writes it: the cover sheet from PHCPPROJECT, the units and method, then

```
WATER     SUP1 0.000 900.000 1500.000 700.000 3000.000 400.000
NODE      N2 4.500
SPRINKLER S1 4.200 -50.000 80.000
USE       ASAM
PIPE      P1 SUP1 N2 12.845 100 1T 2E 1GV 1CV
PIPE      S1_D N4 S1 0.300 25 1T
```

- The supply names its node with its own ID (`SUP1`), and a head names the
  node it sits on with its ID (`S1`), so the results read against the
  drawing.  Plain junctions are `N1`, `N2` ...
- A head is written with two of its three values: K, and the minimum
  pressure as a negative number (`-50`) or the minimum flow.  Given minimum
  pressure and flow without K, K is worked out from them.
- A head given its own elevation gets the drop pipe `<ID>_D` from the
  branch-line node to its own node.
- A `USE` line is written wherever the pipe type or C factor changes.

## Drawing rules

- **Break mains at every branch.**  A branch drawn to the middle of a main that
  is not broken there looks connected but is not.  PHCPCHECK finds these:
  "a pipe end meets another pipe mid-length".
- **A polyline is one pipe.**  Its bends are fittings - include them in its
  fitting string.
- **Heads sit on pipe ends.**
- **Risers:** vertical, so draw a short line and give it a length override.
- **Drops:** give the head its own elevation and a drop size; the drop is added
  as a pipe automatically.
- **Copied lines keep their pipe ID.**  PHCPCHECK reports the duplicate; run
  PHCPPIPE on the copy to give it a new one.
- **One supply or head per pipe end.**  Each names its node, so two cannot share
  one.  Give a head on the supply connection its own elevation (a drop).
- **Every ID once.**  A supply's or head's ID must not be a pipe's or another
  head's.

## Where the data is

Pipe, head, supply and elevation data are extended data (XDATA, application
`PHCP`) on the objects themselves.  Move, copy or stretch a line and its size
goes with it.  `PHCPINFO` lists the PHCP data on any object.

Pipe and head IDs are written back to the drawing on first export and kept,
so P12 stays P12 in every revision.  Node names follow pipe order and can
change between exports; the PHCP-TAGS layer is refreshed on each export.

## Not yet tested in AutoCAD

This routine was written and structurally checked away from AutoCAD
(`perl tools/check_lisp.pl`: brackets matched, every function it calls
defined, every command it announces present, no trace of the old `.hcx`
format), and the file it writes - example 08 - solves in PHCP exactly as the
same network did in the old format.  It has not yet been run inside AutoCAD
2026.  Try it first on a copy of a small drawing: a supply, a main, two
branches and four heads, and compare the export against the drawing.
