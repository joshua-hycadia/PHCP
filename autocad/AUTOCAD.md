# PHCP export for AutoCAD 2026

`phcp_export.lsp` turns a 2D pipework layout into a PHCP model (`.hcx`), so the
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
3. **PHCPSUPPLY** - pick the connection point; static pressure, or a curve of
   flow and pressure points from a flow test or water authority statement.
4. **PHCPPIPE** - select lines or polylines of one size; give pipe type, DN,
   optional C, fittings (`2E,1T` or `1E1T`), and a length override for a riser.
   Each size is one selection; the last values are the defaults.
5. **PHCPELEV** - pick the nodes at one elevation, Enter; repeat per level.
6. **PHCPHEAD** - **Tag** the sprinkler blocks already in the drawing, or
   **Place** PHCP head symbols.  Two of K, minimum pressure and minimum flow.
   Give a head elevation and drop size to model the drop from the branch line.
7. **PHCPCHECK** - checks without exporting.  Faults are listed, and the objects
   responsible are selected on screen.
8. **PHCPEXPORT** - checks, then writes the `.hcx` and optionally tags node and
   pipe IDs on layer PHCP-TAGS, so the calculation reads against the drawing.

Open the `.hcx` in PHCP to solve, check and write the report.

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

## Where the data is

Pipe, head, supply and elevation data are extended data (XDATA, application
`PHCP`) on the objects themselves.  Move, copy or stretch a line and its size
goes with it.  `PHCPINFO` lists the PHCP data on any object.

Pipe and head IDs are written back to the drawing on first export and kept,
so P12 stays P12 in every revision.  Node names follow pipe order and can
change between exports; the PHCP-TAGS layer is refreshed on each export.

## Not yet tested in AutoCAD

This routine was written and structurally checked away from AutoCAD, and the
file it writes has been proven against PHCP.  It has not yet been run inside
AutoCAD 2026.  Try it first on a copy of a small drawing: a supply, a main, two
branches and four heads, and compare the export against the drawing.
