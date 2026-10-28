# PHCP .phc Language Reference Manual

PHCP 1.1 - the `.phc` model file, command by command.

This manual is the reference for every command, field, unit and option the
`.phc` reader accepts. The README explains how PHCP works and what its report
contains. This manual explains how to write a model.

`tools/test_manual.pl` checks the manual against the program, so it cannot
fall behind. It confirms that every command, option, unit and fitting code the
reader knows is described here, and that every complete example in this
manual reads and solves.

---

## Contents

1. The file
2. Values: numbers, lengths, sizes, names
3. Units
4. Command summary
5. Settings: TITLE, PROJECT, UNITS, METHOD, OPTION
6. Pipes: USE, PIPE, PC, CHANGEPIPE, EQV
7. Nodes and outlets: NODE, NC, WATER, SPRINKLER, HYDRANT, HREEL, FIXEDFLOW
8. Pumps and devices: PUMP, PUMPDUTY, BP, BFP, PRV, OPP, OFD, PRA
9. Design and reporting: AREA, SUPPLYGRAPH
10. Fittings
11. Pipe types
12. Names PHCP makes itself
13. Messages
14. A complete model

---

## 1. The file

A `.phc` file is plain text. The program reads a file with Windows or Unix
line endings alike.

**One command to a line.** The first word is the command. The fields follow
it, separated by spaces or tabs. Fields go by position: there is no
`KEY=value` form, and a field containing `=` is refused.

```
PIPE  P1  A  B  6000  50  2E T
```

**Comments.** `//` starts a comment that runs to the end of the line. A line
may be all comment, or a command followed by one.

```
// RISER 1, LEVEL 3
PIPE  P1  A  B  6000  50     // DROP TO THE FIRST BRANCH
```

`!` and `#` are refused anywhere outside a comment.

**Case.** Command words, units, method names, option names and pipe types may
be typed in any case. `pipe`, `Pipe` and `PIPE` are the same command. Names of
pipes, nodes, outlets and areas are case-sensitive: `S1` and `s1` are two
different nodes.

**Order.** Lines may come in any order, with two exceptions:

- **USE** applies to the PIPE lines below it, up to the next USE.
- **Settings are file-wide.** TITLE, PROJECT, UNITS, METHOD and OPTION apply
  to the whole file wherever they appear. Each may be given only once: a
  second one is an error that names both lines.

**Every node is defined exactly once.** A node is defined by NODE, WATER,
SPRINKLER, HYDRANT, HREEL or NC. A node that a pipe, pump or fixed flow names
but nothing defines is an error. It names the node and the first line that
uses it.

**Line numbers.** Every error the reader reports carries the line it comes
from: `line 14: PIPE P7: 47 IS NOT A NOMINAL SIZE ...`. This includes the
hydraulic checks made once the network is built.

**Blank lines** are ignored.

---

## 2. Values

### Numbers

Numbers are plain decimals, optionally signed and with an exponent: `12`,
`0.5`, `.5`, `-50`, `1.5e3`. A thousands separator is not allowed. `1,500` is
not a number.

### Lengths and elevations

A plain number is in the file's LENGTH or ELEVATION unit (see Section 3). A
length may instead carry its own unit, written straight after the number:

| written | means |
|---|---|
| `12M` | 12 m |
| `300MM` | 300 mm |
| `2.5CM` | 2.5 cm |
| `6IN` | 6 in |
| `10FT` | 10 ft |
| `14'3"` or `14'3` | 14 ft 3 in |
| `6'` | 6 ft |
| `3"` | 3 in |

A pipe length cannot be negative. An elevation may be negative (below datum).

### Sizes

The SIZE field of a pipe means one of two things, depending on the `USE` line
in force:

| under | SIZE is | in SIZE unit MM | in SIZE unit IN |
|---|---|---|---|
| `USE <pipe type>` | the nominal size | the DN: `50`, `100` | the nominal inch size: `2`, `1.5`, `4` |
| `USE BORE` | the internal bore | millimetres: `52.5` | inches: `2.067` |

Nominal inch sizes accepted, and the DN each one means:

| in | 0.5 | 0.75 | 1 | 1.25 | 1.5 | 2 | 2.5 | 3 | 3.5 | 4 | 5 | 6 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| DN | 15 | 20 | 25 | 32 | 40 | 50 | 65 | 80 | 90 | 100 | 125 | 150 |

| in | 8 | 10 | 12 | 14 | 16 | 18 | 20 | 24 |
|---|---|---|---|---|---|---|---|---|
| DN | 200 | 250 | 300 | 350 | 400 | 450 | 500 | 600 |

A size the pipe type is not made in is an error on its line. For example,
`ASAM DN47` gives DATA_REQUIRED.

### Names

A name is any run of characters without spaces: `P1`, `4101`, `RISER-2`,
`L3.BR4`. Two restrictions apply:

- `END` cannot be a name. It is reserved.
- `~` cannot appear in a name. PHCP uses it for names it makes itself (see
  Section 12).

A pipe name is unique among pipes. A node name is unique among nodes.
FIXEDFLOW and PUMP names share the pipe names: a pipe and a pump cannot have
the same name.

### Ratios

A pressure ratio is written `3:1`, `3:2` or as a number, such as `1.5`.

---

## 3. Units

Each quantity has its own unit, set by one `UNITS` line. A quantity that is not
set takes the office default.

| quantity | used for | units | default |
|---|---|---|---|
| `LENGTH` | pipe lengths, EQV lengths | `MM` `CM` `M` `IN` `FT` | `MM` |
| `ELEVATION` | node elevations | `MM` `CM` `M` `IN` `FT` | `M` |
| `SIZE` | nominal sizes, bores, orifice bores, roughness | `MM` `IN` | `MM` |
| `PRESSURE` | every pressure | `KPA` `BAR` `MPA` `PSI` `M` (metres head of water) | `KPA` |
| `FLOW` | every flow | `LPM` `LPS` `M3H` `GPM` | `LPM` |
| `KFACTOR` | outlet K-factors | `LPM/KPA` `LPM/BAR` `LPS/KPA` `LPS/BAR` `GPM/PSI` | `LPM/KPA` |

These alternative spellings are also accepted:

| typed | read as |
|---|---|
| `L/MIN` | `LPM` |
| `L/S` | `LPS` |
| `M3/H` | `M3H` |
| `USGPM` | `GPM` |
| `L/MIN/KPA` | `LPM/KPA` |
| `L/MIN/BAR` | `LPM/BAR` |

**The K-factor unit.** K is flow divided by the square root of pressure, so
the same head has a different K in each unit. A K80 head (80 L/min at 1 bar)
is:

| KFACTOR unit | K |
|---|---|
| `LPM/BAR` | 80 |
| `LPM/KPA` (the default) | 8 |
| `GPM/PSI` | 5.6 |

The KFACTOR unit is independent of the FLOW and PRESSURE units. PHCP converts
between them.

**The report** uses the file's FLOW and PRESSURE units, and gives velocity in
m/s.

---

## 4. Command summary

The commands as the editor's command strip groups them. A short form, where
there is one, is in brackets.

| command | fields | section |
|---|---|---|
| `TITLE` | TEXT | 5.1 |
| `PROJECT` | FIELD TEXT | 5.2 |
| `UNITS` | QUANTITY UNIT | 5.3 |
| `METHOD` | HW or DW | 5.4 |
| `OPTION` | NAME VALUE | 5.5 |
| `USE` (`U`) | PIPETYPE [C] | 6.1 |
| `PIPE` (`P`) | NAME START END LENGTH SIZE [FITTINGS ...] | 6.2 |
| `PC` | SOURCE NAME START END [NAME START END ...] | 6.3 |
| `CHANGEPIPE` (`CHP`) | PIPE LENGTH SIZE [FITTINGS ...] | 6.4 |
| `EQV` | PIPE LENGTH | 6.5 |
| `NODE` (`N`) | NAME ELEVATION | 7.1 |
| `NC` | SOURCE NAME [NAME ...] | 7.2 |
| `WATER` (`W`) | NAME ELEVATION STATIC [FLOW PRESSURE ...] | 7.3 |
| `SPRINKLER` | NAME ELEVATION MINFLOW K | 7.4 |
| `HYDRANT` | NAME ELEVATION MINFLOW K | 7.4 |
| `HREEL` | NAME ELEVATION MINFLOW K | 7.4 |
| `FIXEDFLOW` | NAME NODE FLOW [MINPRESSURE] | 7.5 |
| `PUMP` | NAME IN OUT CHURN FLOW PRESSURE [FLOW PRESSURE ...] | 8.1 |
| `PUMPDUTY` | PUMP FLOW PRESSURE | 8.2 |
| `BP` | PIPE CHURN FLOW PRESSURE [FLOW PRESSURE ...] | 8.3 |
| `BFP` | PIPE FLOW LOSS [FLOW LOSS ...] | 8.4 |
| `PRV` | PIPE FLOW LOSS [FLOW LOSS ...] | 8.4 |
| `OPP` | PIPE DROP [CD] | 8.5 |
| `OFD` | PIPE BORE [CD] | 8.5 |
| `PRA` | PIPE RATIO [MININLET] [BAND] | 8.6 |
| `AREA` | NAME OUTLET [OUTLET ...] | 9.1 |
| `SUPPLYGRAPH` | FILE | 9.2 |

In the syntax lines below, `<FIELD>` must be given and `[FIELD]` may be left
off. Optional fields go in order: to give the second, give the first.

---

## 5. Settings

Settings are file-wide and each is given once. In the editor, settings are
made in the PROJECT tab rather than typed.

### 5.1 TITLE

```
TITLE <TEXT>
```

The job name, printed on the cover sheet and as the PDF's title. The text is
the rest of the line, spaces included.

```
TITLE WAREHOUSE EXTENSION - STAGE 2
```

### 5.2 PROJECT

```
PROJECT <FIELD> <TEXT>
```

One cover-sheet field. The text is the rest of the line. Each field may be
given once. The cover sheet uses:

| field | | field | |
|---|---|---|---|
| `PROJECT` | project name | `STANDARD` | design standard |
| `JOB` | job number | `HAZARD` | hazard class |
| `COMPANY` | | `DENSITY` | design density, mm/min |
| `ADDRESS` | | `AREA_PER_SPRINKLER` | m2 |
| `LICENCE` | | `AREA_OF_OPERATION` | m2 |
| `LOCATION` | | `BASE_OF_RISER` | |
| `DESIGNER` | | `AUTHORITY` | approving authority |
| `CHECKER` | | `AUTHORITY_PHONE` | |
| `REVISION` | | `DATA_SOURCE` | where the water supply data came from |
| `DATE` | | | |

With both DENSITY and AREA_PER_SPRINKLER given, the cover sheet checks the
density each sprinkler delivers. Other field names are accepted and kept, but
nothing prints them.

```
PROJECT JOB      HC-2026-041
PROJECT DESIGNER J. SMITH
PROJECT DENSITY  10.2
```

### 5.3 UNITS

```
UNITS <QUANTITY> <UNIT>
```

Sets one quantity's unit for the whole file (see Section 3). Each quantity may
be set once.

```
UNITS LENGTH M
UNITS FLOW   LPS
UNITS KFACTOR LPM/BAR
```

### 5.4 METHOD

```
METHOD <HW|DW>
```

The friction method for every pipe:

| value | method |
|---|---|
| `HW` (default; also `HAZEN`) | Hazen-Williams, to AS 2118.1:2017 Clause 14.10. Each pipe uses its C. |
| `DW` (also `DARCY`) | Darcy-Weisbach with the Colebrook-White friction factor. Each pipe uses its absolute roughness. |

Under DW, a pipe's roughness comes from its USE line or, if that line gives
none, from the database for the pipe type. A `USE BORE` pipe with no
roughness is given 0.045 mm. That value is ASSUMED, and the report flags it
in its warnings.

### 5.5 OPTION

```
OPTION <NAME> <VALUE>
```

A solver or design setting. Each option may be given once. An unknown option
name is an error. A numeric option's value must be a number.

| option | value | default | meaning |
|---|---|---|---|
| `HOSE_ALLOWANCE` | flow, FLOW unit | none | A hose stream flow added at the supply. The demand is checked at the system's flow plus this. It cannot be negative. |
| `DESIGN_AREA` | an AREA name | none | Solve and report that one design area only (Section 9.1). |
| `FITTING_BASIS` | `CORRECTED` or `STANDARD` | `CORRECTED` | CORRECTED corrects fitting lengths for C and for the installed bore. STANDARD uses the AS 2118.1 values unmodified (the "published Standard alone" election), and the report says so. |
| `VEL_LIMIT` | m/s, above 0 | 6 | Pipes faster than this are listed in the warnings. A setting, not a clause of a Standard, and the report says which. |
| `HW_CONST` | number | 6.05e7 | The Hazen-Williams constant: P = k Q^1.85 / (C^1.85 d^4.87), P in kPa/m, Q in L/min, d in mm. |
| `NU` | m2/s, above 0 | 1.004e-6 | Kinematic viscosity of water, for Darcy-Weisbach. The default is water at 20 C. |
| `TOL_FLOW` | flow, FLOW unit | 0.05 L/min | Convergence tolerance on flow. |
| `TOL_LOOP` | pressure, PRESSURE unit | 0.01 kPa | Convergence tolerance on each loop's pressure balance. |
| `MAXITER` | count | 50000 | The most Hardy Cross iterations. A solve that has not converged by then is reported NOT CONVERGED. |
| `ORIF_STEP` | mm | 0.5 | The step an orifice plate sized by OPP is rounded to. |
| `RELAX` | above 0, at most 2 | none | Accepted and range-checked for compatibility. The present solver does not use it. |

```
OPTION HOSE_ALLOWANCE 500
OPTION VEL_LIMIT      7.5
OPTION FITTING_BASIS  STANDARD
```

---

## 6. Pipes

### 6.1 USE

```
USE <PIPETYPE> [C]
```

Sets the pipe type for the PIPE lines below it, up to the next USE.

| field | meaning |
|---|---|
| PIPETYPE | A pipe type code from the database (Section 11), or `BORE` for pipes given by their bore. |
| C | Under METHOD HW, the Hazen-Williams C. Under METHOD DW, the absolute roughness, in the SIZE unit. If it is left off, the database's value for the pipe type is used. |

Before the first USE line, pipes are `USE BORE 120`.

Fittings need a pipe type, because their equivalent lengths come from the
database by type and size. A pipe under `USE BORE` cannot list fittings: give
its allowance with EQV instead.

```
USE ASAM            // AS 1074 MEDIUM, C FROM THE DATABASE (120)
USE S20 110         // SCHEDULE 20 AT C 110
USE BORE 100        // PIPES GIVEN BY BORE, C 100
```

### 6.2 PIPE

```
PIPE <NAME> <START> <END> <LENGTH> <SIZE> [FITTINGS ...]
```

| field | meaning |
|---|---|
| NAME | The pipe's name, unique among pipes. |
| START, END | The nodes at each end. Positive flow runs START to END, and the report signs flows that way. |
| LENGTH | The pipe's length, LENGTH unit (or with its own unit). |
| SIZE | The nominal size, or under USE BORE the bore (Section 2). |
| FITTINGS | Fitting codes, each with an optional count: `2E T GV`. See Section 10. |

The pipe takes the type and C of the USE line above it.

```
USE  ASAM
PIPE P1  W   R1  12000  100  E GV C
PIPE P2  R1  J1  3500   80   2E T
```

### 6.3 PC - copy a pipe

```
PC <SOURCE> <NAME> <START> <END> [<NAME> <START> <END> ...]
```

Makes one or more pipes that are the same as SOURCE, with the same type, C,
length, size and fittings, between new nodes. Each copy is three fields:
NAME START END.

A copy takes its source as defined, before any CHANGEPIPE on the source. A
source may itself be a copy. A chain of copies that comes back on itself is
an error.

```
PIPE P10 J1 S1 3000 25 T
PC   P10 P11 J2 S2  P12 J3 S3  P13 J4 S4
```

### 6.4 CHANGEPIPE - change a pipe

```
CHANGEPIPE <PIPE> <LENGTH> <SIZE> [FITTINGS ...]
```

Replaces a pipe's length, size and fittings, keeping its name, nodes, type
and C. It is normally used on a copy, to make it different from its source.
The source keeps its original values. Each pipe may be changed once.

```
PC         P10 P14 J5 S5
CHANGEPIPE P14 4500 32 E T
```

### 6.5 EQV - add an equivalent length

```
EQV <PIPE> <LENGTH>
```

Adds a length to the pipe's equivalent length, on top of its fittings. It is
the way to give a fitting allowance on a `USE BORE` pipe, or one the database
does not hold. Each pipe takes one EQV.

```
USE  BORE 120
PIPE P5 A B 6000 52.5
EQV  P5 3.2M
```

---

## 7. Nodes and outlets

### 7.1 NODE

```
NODE <NAME> <ELEVATION>
```

A junction, at an elevation above the datum, in the ELEVATION unit. All
elevations in a file share one datum.

```
NODE R1  0
NODE J1  6.5
```

### 7.2 NC - copy a node

```
NC <SOURCE> <NAME> [NAME ...]
```

Makes nodes that are the same as SOURCE: the same elevation and, for an
outlet, the same kind, MINFLOW and K. A copy of a SPRINKLER is a sprinkler.

```
SPRINKLER S1 6.5 -50 8
NC        S1 S2 S3 S4 S5
```

### 7.3 WATER - a water supply

```
WATER <NAME> <ELEVATION> <STATIC> [FLOW PRESSURE ...]
```

A supply connection, defining its node. A model may have any number of
supplies.

| field | meaning |
|---|---|
| ELEVATION | The elevation the pressures are measured at. |
| STATIC | The pressure at no flow. |
| FLOW PRESSURE | Further points on the supply curve: residual pressure at each flow. |

With no pairs, the supply holds STATIC at any flow, like a tank or a fixed
head. With pairs, the supply is a curve from STATIC at no flow through every
point given. Between points, pressure is a straight line on Q^1.85 paper.
Beyond the last point, the curve continues in a straight line in flow.

```
WATER TOWN 0 650 1800 560 3600 400
WATER TANK 12 0
```

With one supply, the report finds the demand point: the supply pressure at
which the governing outlet has exactly its requirement.

### 7.4 SPRINKLER, HYDRANT, HREEL - outlets

```
SPRINKLER <NAME> <ELEVATION> <MINFLOW> <K>
HYDRANT   <NAME> <ELEVATION> <MINFLOW> <K>
HREEL     <NAME> <ELEVATION> <MINFLOW> <K>
```

Defines the outlet's node and the outlet on it together. The kind matters to
the report, which counts sprinklers apart from hydrants and hose reels.

| field | meaning |
|---|---|
| ELEVATION | The outlet's elevation. |
| MINFLOW | The least the outlet must give. A positive value is a flow (FLOW unit). A negative value is instead a pressure (PRESSURE unit): `-50` means at least 50 kPa. |
| K | The K-factor, in the KFACTOR unit. Flow = K x sqrt(pressure). A K of 0 shuts the outlet: its node stays, discharging nothing. |

Every outlet is checked, PASS or FAIL. The outlet with the least pressure to
spare over its requirement is the governing outlet.

```
SPRINKLER S1  6.5  -50   8      // AT LEAST 50 KPA, K 8 L/MIN/KPA^0.5
SPRINKLER S2  6.5   61   8      // AT LEAST 61 L/MIN
HYDRANT   H1  0.5  600   21
HREEL     HR1 1.0  20    3
```

### 7.5 FIXEDFLOW - a fixed demand

```
FIXEDFLOW <NAME> <NODE> <FLOW> [MINPRESSURE]
```

A flow taken from a node whatever its pressure: a hose stream, a process
draw, a flow measured elsewhere. It is a nodal demand, outside every loop.
NAME shares the pipe names, and NODE must be defined elsewhere.

MINPRESSURE, when given, is the pressure needed to deliver the flow, and it
is checked. The fixed flow is listed with the outlets, PASS or FAIL on
pressure alone. A fixed flow with the least pressure to spare governs like
any outlet. Its flow is never reduced when pressure is short: the report
shows the shortfall as a FAIL instead.

```
FIXEDFLOW HOSE1 J4 450 250
```

---

## 8. Pumps and devices

### 8.1 PUMP

```
PUMP <NAME> <IN> <OUT> <CHURN> <FLOW> <PRESSURE> [FLOW PRESSURE ...]
```

A pump between two nodes, adding pressure from IN to OUT. CHURN is the boost
at no flow. Each FLOW PRESSURE pair is a further point on its curve, read as a
supply curve is (Section 7.3). At least one pair is required. NAME shares the
pipe names.

A pump does not run backwards. If the network would push water from OUT to
IN, the pump's check valve closes it.

```
PUMP FP1 SUC DIS 700 2000 600 3000 450
```

### 8.2 PUMPDUTY - a pump's rated duty

```
PUMPDUTY <PUMP> <FLOW> <PRESSURE>
```

The rated duty of a PUMP, given by its name, or of a booster in a pipe (BP),
given by the pipe's name. The report's PUMP CURVES section reads the curve
against it:

| check | rule | counts as |
|---|---|---|
| AT DUTY | the curve at the duty flow gives at least the duty pressure | a check; a failure is a warning |
| SHUT-OFF | the curve at no flow is at most 140 % of the duty pressure (AS 2941-2013, from the Pump Industry Australia fire pump checklist) | a check; a failure is a warning |
| 150 % FLOW | the curve at 150 % of the duty flow gives at least 65 % of the duty pressure (NFPA 20, 6.2) | for information only, never a failure |

A reading beyond the curve's last point is marked EXTRAPOLATED. Each pump
takes one duty. A pump without a duty is listed with its shut-off pressure
only.

```
PUMPDUTY FP1 2000 600
```

### 8.3 BP - a booster pump in a pipe

```
BP <PIPE> <CHURN> <FLOW> <PRESSURE> [FLOW PRESSURE ...]
```

A pump in a pipe, at the pipe's start. The fields are as for PUMP after the
nodes. The device is named `<pipe>.BP` in the report (Section 12).

```
BP P1 300 1500 250 2500 180
```

### 8.4 BFP, PRV - a backflow preventer or pressure reducing valve

```
BFP <PIPE> <FLOW> <LOSS> [FLOW LOSS ...]
PRV <PIPE> <FLOW> <LOSS> [FLOW LOSS ...]
```

A device in a pipe, at the pipe's start, that loses pressure with flow along
the curve given: LOSS at each FLOW, in the PRESSURE and FLOW units, read as a
supply curve is.

A single pair at flow 0 is a FIXED loss that does not vary with flow:
`BFP P1 0 35` is 35 kPa at any flow. A single pair at any other flow is an
error, and a fixed loss must be more than 0.

```
BFP P1 0 10 2000 40 4000 75
PRV P9 0 50
```

### 8.5 OPP, OFD - orifice plates

```
OPP <PIPE> <DROP> [CD]
OFD <PIPE> <BORE> [CD]
```

An orifice plate in a pipe, at the pipe's start. It takes its pipe's nominal
size and bore.

| command | given | found |
|---|---|---|
| OPP | the DROP wanted, PRESSURE unit | the plate's bore, rounded to ORIF_STEP (0.5 mm unless set) |
| OFD | the plate's BORE, SIZE unit | the drop at the solved flow |

CD is the discharge coefficient, 0.596 unless given.

```
OPP P7 120
OFD P8 38.5 0.61
```

### 8.6 PRA - a pressure ratio valve

```
PRA <PIPE> <RATIO> [MININLET] [BAND]
```

A pressure ratio valve in a pipe, at its start. It holds its outlet at its
inlet pressure divided by RATIO.

| field | meaning |
|---|---|
| RATIO | `3:1`, `2:1`, `1.5`, ... It must be more than 1: a ratio valve reduces pressure. |
| MININLET | The manufacturer's least inlet pressure. An inlet below it is a warning. 0 means no minimum, so a BAND can be given without one. |
| BAND | The valve's tolerance, in % of the inlet pressure. 5 if not given. 0 means the nominal ratio exactly. |

The calculation uses the BOTTOM of the band, outlet = inlet x (1/ratio -
band), so every outlet is checked against the least pressure the valve can be
relied on to give. The report solves the network once more with every valve
at the TOP of its band, and states the highest pressure that gives
downstream. A band wider than the ratio passes is refused.

```
PRA P2 3:1 300
PRA P3 2:1 0 3
```

**One device to a pipe.** BP, BFP, PRV, OPP, OFD and PRA name the pipe they
sit in, and a pipe holds one device. A second one is an error naming the
first.

---

## 9. Design and reporting

### 9.1 AREA - a design area

```
AREA <NAME> <OUTLET> [OUTLET ...]
```

Names outlets that flow together. A model may hold more outlets than ever
flow at once (a whole floor, of which the design area is one part), and each
AREA names one set. A second AREA line with the same name adds to that area.

Each OUTLET must be a SPRINKLER, HYDRANT or HREEL node, or a copy of one. An
outlet named in no AREA, such as a hydrant or hose reel, flows in every area.

With AREA lines, PHCP solves each area on its own, with the other areas'
outlets shut, and reports the one that governs:

1. an area whose solve did not converge, first;
2. else, with one supply, the area with the least margin at the supply;
3. else the area whose governing outlet has the least pressure to spare.

Section 1 of the report lists every area and marks the one that governs. To
solve and report one area only, name it with `OPTION DESIGN_AREA`.

```
AREA NEAR A1 A2 A3 A4
AREA FAR  B1 B2 B3 B4
AREA MID  A3 A4
AREA MID  B1 B2
```

### 9.2 SUPPLYGRAPH - a graph sheet in the report

```
SUPPLYGRAPH <FILE>
```

Adds a water supply graph made in the editor's GRAPH tab (a `.phg` file) to
the model's report:

- in the text report, an appendix with the graph's points and its duty
  points against the curve designed against;
- in the PDF, the sheet itself, on a page after the text.

FILE is the rest of the line, so a name with spaces is fine. A relative name
is found from the model's folder, or the current folder for a model not yet
saved. More than one may be given; they become appendices A, B and so on.

A graph that cannot be read, or that the GRAPH tab would refuse, is listed in
the warnings, and the report is written without it.

```
SUPPLYGRAPH town main.phg
SUPPLYGRAPH C:\JOBS\HC-041\PUMP TEST.phg
```

---

## 10. Fittings

Fittings follow a pipe's SIZE, or a CHANGEPIPE's. Each is a code with an
optional count in front: `E`, `2E`, `T`, `3GV`. They may also be run
together or comma-separated, `2E,1T` or `2E1T`, as written on many
calculation sheets. A count must be 1 to 99.

**Short forms.**

| typed | read as |
|---|---|
| `G` | `GV` |
| `C` | `CV` |
| `B` | `BV` |

**Which table applies.** Each length comes from the database, by the pipe's
type and size:

| pipe type | table | correction |
|---|---|---|
| ASAM, ASAH, S20, S40, DN150 and below | AS 2118.1:2017 Table 14.11.1 | for C and for the installed bore, unless OPTION FITTING_BASIS STANDARD |
| the same, above DN150 | FM Global DS 3-0 Table 12(a) | as above |
| CPVC | the manufacturer's table | none |
| PE11, PE9 | Le = K' x d (PPI Handbook of PE Pipe), d the actual bore | none |
| PVCM16 | the steel tables as a controlled fallback | as for steel; the report states the assumption |

**Codes.** Each table holds only some codes, and a code the table lacks for
that pipe is an error. So is a size the table has no value for: a missing
value is never taken as zero.

| code | AS 2118.1 (DN150 and below) | FM DS 3-0 (above DN150) |
|---|---|---|
| `E` | 90 deg standard elbow | standard screwed elbow, or run of tee reduced 1/2 |
| `EL` | 90 deg long radius elbow | 90 deg long radius flanged elbow |
| `E45` | 45 deg elbow | 45 deg elbow |
| `EF` | - | 90 deg flanged or medium sweep elbow, or tee reduced 1/4 |
| `T` | tee or cross, flow turned 90 deg | standard tee or cross, flow turned 90 deg |
| `GV` | gate valve | gate valve, fully open |
| `GV75` `GV50` `GV25` | - | gate valve, 75 %, 50 %, 25 % open |
| `CV` | check or alarm valve (swing) | swing check, alarm check or dry pipe valve |
| `CVM` | check or alarm valve (mushroom) | - |
| `CVB` | check or alarm valve (butterfly) | - |
| `BV` | - | butterfly valve, fully open |
| `AV` | - | angle valve |

| code | CPVC |
|---|---|
| `E` | 90 deg elbow |
| `E45` | 45 deg elbow |
| `T` | tee, branch (flow turned 90 deg) |
| `TR` | tee, run: published, but not counted |
| `CPL` | coupling |

| code | PE (K') | | code | PE (K') |
|---|---|---|---|---|
| `E` | 90 deg moulded elbow (40) | | `E45M2` | 45 deg fabricated, 2+ mitres (15) |
| `E45` | 45 deg moulded elbow (21) | | `E45M1` | 45 deg fabricated, 1 mitre (12) |
| `E15` | 15 deg moulded elbow (6) | | `E30M2` | 30 deg fabricated, 2+ mitres (8) |
| `EM3` | 90 deg fabricated, 3+ mitres (24) | | `E30M1` | 30 deg fabricated, 1 mitre (8) |
| `EM2` | 90 deg fabricated, 2 mitres (30) | | `E15M1` | 15 deg fabricated, 1 mitre (6) |
| `EM1` | 90 deg fabricated, 1 mitre (60) | | `T` | tee, run to branch (60) |
| `E60M2` | 60 deg fabricated, 2+ mitres (25) | | `TR` | tee, run to run (20): not counted |
| `E60M1` | 60 deg fabricated, 1 mitre (16) | | `GLV` | globe valve (340) |
| `AV` | angle valve (145) | | `BV` | butterfly valve, over 8 in (40) |
| `CV` | check valve, swing (135) | | | |

The database is the authority. Its exact contents, and any changes made in
the DATABASE tab, can be seen there. The editor's pick list offers the codes
that exist for the pipe on the line.

---

## 11. Pipe types

The pipe types in the database as supplied. The DATABASE tab shows the
current list, with every size's bore.

| code | pipe | standard | sizes | C | roughness, mm |
|---|---|---|---|---|---|
| `ASAM` | AS 1074 medium steel tube | AS 1074 | DN20-DN150 | 120 | 0.045 |
| `ASAH` | AS 1074 heavy steel tube | AS 1074 | DN20-DN150 | 120 | 0.045 |
| `S20` | Australian Schedule 20 steel | ASME B36.10M | DN200-DN600 | 120 | 0.045 |
| `S40` | Schedule 40 steel | ASME B36.10M | DN25-DN600 | 120 | 0.045 |
| `CPVC` | BlazeMaster CPVC, SDR 13.5 | ASTM F442 | DN20-DN80 | 150 | 0.003 |
| `PE11` | PE100, SDR 11, PN16 | AS/NZS 4130 | DN63-DN630 | 150 | 0.007 |
| `PE9` | PE100, SDR 9, PN20 | AS/NZS 4130 | DN63-DN630 | 150 | 0.007 |
| `PVCM16` | PVC-M, Series 2, PN16 | AS/NZS 4765 | DN100-DN450 | 150 | 0.003 |
| `BORE` | not a type: the pipe is given by its bore | | any | as USE gives, else 120 | as USE gives, else 0.045 assumed |

---

## 12. Names PHCP makes itself

A device in a pipe (BP, BFP, PRV, OPP, OFD, PRA) sits at the pipe's start.
PHCP splits the pipe there:

- a new node `<pipe>~`, at the start node's elevation;
- the device, from the start node to `<pipe>~`, named `<pipe>.<command>`
  (for example `P1.BP`);
- the pipe itself, from `<pipe>~` to its end node.

These names appear in the report and the JSON. This is why `~` is reserved.

---

## 13. Messages

The reader stops at the first error and names its line. The editor shows
every line's state as it is typed. The messages below are the commonest; the
words in capitals are as PHCP prints them.

| message | cause |
|---|---|
| `UNKNOWN COMMAND X` | The first word is not a command or a short form. |
| `PIPE NEEDS SIZE` | A field is missing. Each missing field is named. |
| `'X': FIELDS GO BY POSITION - THERE ARE NO KEY=VALUE OPTIONS` | A field contains `=`. |
| `'!' CANNOT BE USED IN A .PHC LINE; COMMENTS START WITH //` | A `!` or `#` outside a comment. |
| `X IS ALREADY SET ON LINE N` | A setting given twice. |
| `NODE X IS ALREADY DEFINED ON LINE N` | A node defined twice. |
| `THE NAME X IS ALREADY USED ON LINE N` | A pipe, pump or fixed flow name used twice. |
| `NODE X IS NOT DEFINED` | A node named but defined nowhere. Others are listed with it. |
| `PIPE X ALREADY HAS A DEVICE, BP ON LINE N` | A second device in one pipe. |
| `UNKNOWN PIPE TYPE X (...)` | Not in the database. The message lists the types. |
| `DATA_REQUIRED: DN47 IS NOT IN THE DATABASE FOR PIPE TYPE ASAM` | A size the type is not made in, or a fitting with no published value. |
| `PIPE X: FITTINGS NEED A PIPE TYPE ...` | Fittings on a USE BORE pipe. Use EQV. |
| `UNKNOWN UNIT X FOR FLOW (...)` | Not a unit of that quantity. The message lists them. |
| `UNKNOWN OPTION X (...)` | Not an option. The message lists them. |
| `A PRESSURE RATIO VALVE REDUCES PRESSURE: ITS RATIO MUST BE MORE THAN 1` | PRA ratio of 1 or less. |
| `PUMPDUTY X: NO PUMP OF THAT NAME, AND NO PIPE WITH A BOOSTER (BP) IN IT` | The duty names nothing it can check. |
| `AREA A: X IS NOT AN OUTLET (SPRINKLER, HYDRANT OR HREEL)` | An AREA names a plain node. |
| `DESIGN_AREA X: NO AREA OF THAT NAME (...)` | The option names an area the file does not have. |
| `THE FILE HOLDS NO MODEL: NO NODES AND NO PIPES` | Nothing but settings and comments. |

**Warnings** do not stop the solve. They are listed in Section 12 of the
report, in the editor's WARNINGS list and in the JSON. Among them: a pipe over
VEL_LIMIT, an assumed roughness, a pump short of its duty, a ratio valve's
inlet below its minimum, and a supply graph that could not be read.

---

## 14. A complete model

A single branch from a town main, through a backflow preventer, to four
sprinklers and a hose reel. It is typed here in full, settings included. In
the editor, the settings would be in the PROJECT tab and only the network
lines typed.

```phc
// COMPLETE EXAMPLE FROM THE REFERENCE MANUAL
TITLE     REFERENCE MANUAL EXAMPLE
PROJECT   JOB HC-REF-001
UNITS     LENGTH M
UNITS     KFACTOR LPM/BAR
METHOD    HW
OPTION    HOSE_ALLOWANCE 250

// SUPPLY: TOWN MAIN, FLOW TEST 450 KPA STATIC
WATER     TOWN 0 450 1000 380 2000 250

// RISER AND MAIN
NODE      R0  0
NODE      R1  4
USE       ASAM
PIPE      M1  TOWN R0  30  100  GV
BFP       M1  0 10 1000 35 2000 60
PIPE      RS  R0  R1   4   100  E

// BRANCH LINE: FOUR K80 HEADS AT 100 KPA MINIMUM
SPRINKLER S1  4 -100 80
NC        S1  S2 S3 S4
PIPE      L1  R1  S1   3   65   T
PIPE      L2  S1  S2   3   50
PIPE      L3  S2  S3   3   40
PIPE      L4  S3  S4   3   32

// HOSE REEL OFF THE RISER, GIVEN BY BORE WITH AN ALLOWANCE
USE       BORE 120
HREEL     HR1 1  20  30
PIPE      HRP R0  HR1  5   27.3
EQV       HRP 2.5
```
