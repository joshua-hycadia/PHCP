#!/usr/bin/perl
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# gui_grid.pl -- a spreadsheet front end for the Perl Hardy Cross engine.
#
# WHAT THIS IS
#   A real editable grid, not a read-only listing.  Every input block of the
#   model -- nodes, pipes, supplies, outlets, devices -- is a sheet you type
#   into, exactly as you would a spreadsheet.  The model is re-solved as you
#   type, so a mistyped bore shows up as a velocity warning before you have
#   finished the next row.
#
# WHY A GRID AND NOT A FORM
#   Entering a network is hundreds of short numeric fields.  A form with
#   labelled boxes costs a mouse trip per field; a grid costs a keystroke.
#   Every hydraulics package in the industry is a grid for this reason.
#
# THE WHOLE STACK IS PERL
#   Parser, topology, solver, grid, pixels.  No compiler, nothing beyond the
#   interpreter, Tk and Tk::TableMatrix.
#
# DESIGN RULES -- the same ones the Qt and Lisp front ends follow, because they
# are rules about reading numbers rather than about a toolkit:
#   - numbers right-aligned in a monospaced face, so decimal points stack
#   - units live in the column heading, never repeated in the cells
#   - headings uppercase and quiet; the data should win the page
#   - colour carries meaning only: a fault is red, nothing is decorative
#   - input and computed cells never look alike, so nobody can type over a
#     result or quote an input as one
#==============================================================================

use strict;
use warnings;
use FindBin;
use lib $FindBin::Bin;
use Tk;
use Tk::NoteBook;
use Tk::TableMatrix;
use HardyCross;
use HardyCross::Parse;
use HardyCross::Report;
use Storable qw(dclone);

#------------------------------------------------------------------------------
# DESIGN TOKENS
# Named once and used everywhere.  A literal colour below this block is a bug:
# it means part of the interface has drifted off the palette.
#------------------------------------------------------------------------------
my $INK      = '#1D1D1F';    # primary text
my $INK2     = '#6E6E73';    # headings and secondary text
my $SURFACE  = '#FFFFFF';    # an editable cell
my $READONLY = '#F5F6F5';    # a computed cell -- tinted, never mistakable
my $HEADBG   = '#F0F1EF';    # row and column headers, chrome
my $SELECT   = '#E8F0FC';    # the active cell
my $BAD      = '#B3261E';
my $BADBG    = '#FCEEEC';   # background of a cell with a problem
my $GOOD     = '#0B6B4F';
my $WARN     = '#8A5A00';
my $GRID     = '#DCDCD8';    # hairline between cells
my $MONO     = 'Courier 10';
my $UI       = 'Helvetica 9';
my $UI_B     = 'Helvetica 9 bold';
my $UNIT     = 8;            # the spacing grid; every pad is a multiple

#------------------------------------------------------------------------------
# THE COLUMN SCHEMA
#
# One entry per editable block: heading, width in characters, and whether the
# column is numeric (and therefore right-aligned).  This is the SINGLE place
# the .hcx column order is written down -- the grid, the serialiser and the
# loader all read it, so they cannot drift apart.
#
# A column carrying 'key' is written back as KEY=value rather than
# positionally, because that is how the file format carries optional fields.
#------------------------------------------------------------------------------
#------------------------------------------------------------------------------
# THE COLUMN SCHEMA
#
# One entry per sheet: heading, width in characters, whether the column is
# numeric (and therefore right-aligned), and how it maps back to the .hcx file.
# This is the SINGLE place the layout is written down -- the grid, the loader
# and the serialiser all read it, so they cannot drift apart.
#
# A column with h => '' is a SPACER: a narrow blank gutter that separates one
# logical group of columns from the next.  It holds no data and is skipped
# everywhere.  On a wide sheet the eye needs somewhere to rest, and a gutter
# does that job better than a heavier rule would.
#
# THE NETWORK SHEET IS DENORMALISED ON PURPOSE
#
#   The file keeps nodes, pipes and outlets in three separate blocks.  This
#   sheet puts a pipe and BOTH its end nodes on one row, because that is how a
#   run is actually entered: you work along the pipework and the node data
#   arrives with the pipe, not in a separate pass.
#
#   The cost is that a node appearing on several pipes has its attributes
#   repeated, and the copies can disagree.  The rule is stated once here and
#   enforced in collect_nodes(): THE FIRST NON-BLANK VALUE WINS, and a later
#   row that contradicts it raises a warning rather than being silently
#   ignored.  Silently picking one would make a typo in an elevation
#   impossible to find.
#------------------------------------------------------------------------------
my %SCHEMA = (
    NETWORK => [
        { h => 'pipe #',        w => 10, num => 0 },
        { h => 'node A',        w => 8,  num => 0 },
        { h => 'node B',        w => 8,  num => 0 },
        { h => 'length',        w => 9,  num => 1 },
        { h => 'type',          w => 14, num => 0 },   # pipe standard, e.g. AS 1074 MEDIUM
        { h => 'dia',           w => 8,  num => 1 },
        # Accepts EITHER a fitting string such as "2E,1T" or a plain
        # equivalent length such as "8".  A number is written back as EQV=, a
        # string as FIT=.  The first version only handled the string, so a
        # model written with EQV= lost its fitting allowances the moment it was
        # loaded -- the flows were then wrong by a few percent with nothing on
        # screen to say why.
        { h => 'fittings',      w => 12, num => 0 },
        { h => '',              w => 3,  num => 0 },   # spacer
        { h => 'A elev',        w => 9,  num => 1 },
        { h => 'A type',        w => 12, num => 0 },
        { h => 'A K',           w => 8,  num => 1 },
        { h => 'A flow',       w => 9,  num => 1 },
        { h => 'A press',      w => 9,  num => 1 },
        # Which pressure device sits at this node.  DERIVED from the PRESSURE
        # DEVICES sheet, not typed here: a device is an edge between two nodes,
        # so defining one from a node column would give two places to say the
        # same thing and no rule for which wins.
        { h => 'A dev',        w => 9,  num => 0 },
        { h => '',              w => 3,  num => 0 },   # spacer
        { h => 'B elev',        w => 9,  num => 1 },
        { h => 'B type',        w => 12, num => 0 },
        { h => 'B K',           w => 8,  num => 1 },
        { h => 'B flow',       w => 9,  num => 1 },
        { h => 'B press',      w => 9,  num => 1 },
        { h => 'B dev',        w => 9,  num => 0 },
    ],
    # A supply is either STATIC -- one pressure, unlimited flow -- or a CURVE
    # of flow/pressure points.  One sheet serves both: a STATIC supply fills
    # only the first pressure cell and leaves the pairs blank.
    SUPPLIES => [
        { h => 'node #',   w => 10, num => 0 },
        { h => 'elevation',w => 10, num => 1 },
        { h => 'type',     w => 9,  num => 0 },
        { h => 'pressure', w => 10, num => 1 },        # static, or shutoff head
        { h => '',         w => 3,  num => 0 },
        (map { ({ h => "flow $_",     w => 9, num => 1 },
                { h => "pressure $_", w => 10, num => 1 }) } 1 .. 6),
    ],
    # A pump carries its curve as flow/pressure pairs, exactly as a curve
    # supply does.  Until this sheet existed pumps were kept verbatim on save
    # but could not be edited, so part of every pumped model lived only in
    # the text file.
    PUMPS => [
        { h => 'pump',    w => 10, num => 0 },
        { h => 'from',    w => 8,  num => 0 },
        { h => 'to',      w => 8,  num => 0 },
        { h => '',        w => 3,  num => 0 },
        (map { ({ h => "flow $_",     w => 9,  num => 1 },
                { h => "pressure $_", w => 10, num => 1 }) } 1 .. 6),
    ],
    # Nodes that no PIPE touches -- the downstream side of an orifice plate,
    # a PRV or a backflow preventer.  The NETWORK sheet is a list of pipes, so
    # these had nowhere to live and were preserved invisibly.  An outlet that
    # is in the model but on no sheet is a trap for whoever edits it next.
    OTHERNODES => [
        { h => 'node',      w => 10, num => 0 },
        { h => 'elevation', w => 10, num => 1 },
        { h => '',          w => 3,  num => 0 },
        { h => 'outlet',    w => 10, num => 0 },
        { h => 'type',      w => 12, num => 0 },
        { h => 'K',         w => 8,  num => 1 },
        { h => 'flow',      w => 9,  num => 1 },
        { h => 'pressure',  w => 10, num => 1 },
    ],
    DEVICES => [
        { h => 'device',   w => 10, num => 0 },
        { h => 'from',     w => 8,  num => 0 },
        { h => 'to',       w => 8,  num => 0 },
        { h => 'type',     w => 12, num => 0 },
        { h => 'drop',     w => 9,  num => 1, key => 'DP' },
        { h => 'bore',     w => 9,  num => 1, key => 'BORE' },
        { h => 'DN',       w => 7,  num => 1, key => 'DN' },
        { h => '',         w => 3,  num => 0 },
        # A BFP carries its loss curve as positional pairs after the type,
        # exactly as supplies and pumps do.  Without these columns the pairs
        # are dropped on load and the file then describes a backflow preventer
        # with no curve, which the engine rightly refuses to solve.
        (map { ({ h => "Q$_",  w => 8, num => 1 },
                { h => "dP$_", w => 8, num => 1 }) } 1 .. 4),
    ],
);

# PROJECT is a two-column key/value sheet rather than a record list, so it has
# its own small schema and its own writer.
# The PROJECT block, in three groups.  Everything the report's cover sheet
# prints comes from here; nothing on the cover is typed anywhere else.
#   details     who, what and where
#   design      the AS 2118.1 design basis the density check is made against
#   authority   who the calculation is submitted to
# There is no hose stream field: Australian practice adds no hose stream
# allowance to a sprinkler calculation.
my @DETAIL_FIELDS    = qw(TITLE PROJECT JOB COMPANY ADDRESS LICENCE DESIGNER
                          CHECKER REVISION DATE LOCATION);
my @DESIGN_FIELDS    = qw(STANDARD HAZARD DENSITY AREA_PER_SPRINKLER
                          AREA_OF_OPERATION BASE_OF_RISER DATA_SOURCE);
my @AUTHORITY_FIELDS = qw(AUTHORITY AUTHORITY_PHONE);
my @PROJECT_FIELDS   = (@DETAIL_FIELDS, @DESIGN_FIELDS, @AUTHORITY_FIELDS);

# What the PROJECT sheet shows in its FIELD column.  The file keeps the plain
# keys; the sheet shows the unit a figure must be entered in, because a density
# typed in the wrong unit is not an error anything else will catch.
my %FIELD_LABEL = (
    JOB                => 'JOB NUMBER',
    TITLE              => 'JOB NAME',
    HAZARD             => 'HAZARD CLASS',
    DENSITY            => 'DENSITY  mm/min',
    AREA_PER_SPRINKLER => 'AREA / SPRINKLER  m2',
    AREA_OF_OPERATION  => 'AREA OF OPERATION  m2',
    BASE_OF_RISER      => 'BASE OF RISER  node',
    DATA_SOURCE        => 'DATA SOURCE',
    AUTHORITY          => 'AUTHORITY',
    AUTHORITY_PHONE    => 'AUTHORITY PHONE',
    TOL_FLOW           => 'TOL_FLOW',
);
my @UNIT_FIELDS    = qw(FLOW PRESSURE LENGTH DIAMETER);
my @OPTION_FIELDS  = qw(METHOD VEL_LIMIT TOL_FLOW TOL_LOOP MAXITER);

my @INPUT  = qw(PROJECT NETWORK OTHERNODES SUPPLIES PUMPS DEVICES);
# ELEMENTS is the bottom pane, not a tab: results you have to change tab to
# see are results you look at after finishing rather than while working.
my @RESULT     = qw(ELEMENTS PRESSURES LOOPS CONVERGENCE);
my @RESULT_TAB = qw(PRESSURES LOOPS CONVERGENCE);

#------------------------------------------------------------------------------
# RESULT COLUMNS
#
# Every quantity the engine can report, with how wide it is, whether it sorts
# as a number, and how it is computed.  The user chooses which appear from the
# COLUMNS menu; the default set is the ones a hydraulic calculation is actually
# checked against.
#
# A column whose value the engine does not hold shows "-" rather than a zero.
# A zero in a schedule is a measurement; a dash is an absence, and the two must
# never look the same.
#------------------------------------------------------------------------------
my @ELEM_COLS = (
    { id => 'name',  h => 'pipe',       w => 9,  num => 0, fixed => 1 },
    { id => 'n1',    h => 'start node', w => 10, num => 0 },
    { id => 'n2',    h => 'end node',   w => 9,  num => 0 },
    { id => 'kind',  h => 'type',       w => 9,  num => 0 },
    { id => 'nom',   h => 'nominal',    w => 8,  num => 1 },
    { id => 'id',    h => 'ID',         w => 8,  num => 1 },
    { id => 'mat',   h => 'material',   w => 12, num => 0 },
    { id => 'c',     h => 'C',          w => 7,  num => 1 },
    { id => 'len',   h => 'L',          w => 8,  num => 1 },
    { id => 'ftg',   h => 'F',          w => 8,  num => 1 },
    { id => 'tot',   h => 'T',          w => 8,  num => 1 },
    { id => 'kfit',  h => 'K',          w => 7,  num => 1 },
    { id => 'q',     h => 'Q',          w => 10, num => 1 },
    { id => 'pf',    h => 'Pf',         w => 9,  num => 1 },
    { id => 'pfx',   h => 'Pf/x',       w => 9,  num => 1 },
    { id => 'pe',    h => 'Pe',         w => 8,  num => 1 },
    { id => 'ps',    h => 'Ps',         w => 8,  num => 1 },
    { id => 'pv',    h => 'Pv',         w => 8,  num => 1 },
    { id => 'vel',   h => 'Vel',        w => 7,  num => 1 },
    { id => 're',    h => 'Re',         w => 11, num => 1 },
    { id => 'f',     h => 'f',          w => 8,  num => 1 },
    { id => 'form',  h => 'formula',    w => 10, num => 0 },
);

# The default view: what a calculation is checked against.  Everything else is
# available but off, because twenty-two columns at once is a wall of figures.
my %ELEM_ON = map { $_ => 1 }
    qw(name n1 n2 kind len ftg tot q vel pf pfx pe);

my ($sort_col, $sort_desc) = ('', 0);

my %RCOLS = (
    PRESSURES   => [ ['node',10,0], ['elevation m',13,1],
                     ['pressure kpa',14,1], ['total head kpa',15,1] ],
    LOOPS       => [ ['loop',8,0], ['kind',9,0], ['elements',9,1],
                     ['signed element list',58,0] ],
    CONVERGENCE => [ ['iteration',11,1], ['max |dQ| lpm',15,1],
                     ['max |sum hf| kpa',17,1] ],
);

#------------------------------------------------------------------------------
# THE DOCUMENT
#
# %doc maps a block name to an array of rows, each row an array of cell
# strings.  Deliberately plain text all the way through: what the user typed is
# what gets written to the file, with no rounding or reformatting in between.
# A tool that silently rewrites "25.0" as "25" has already started editing the
# user's data without asking.
#------------------------------------------------------------------------------
my %doc   = map { $_ => [] } @INPUT;
my %units = (FLOW => 'LPM', PRESSURE => 'KPA', LENGTH => 'M', DIAMETER => 'MM');
my %opts  = (METHOD => 'HW');
my %project;                    # PROJECT block fields, keyed by field name
# Outlets and elevations belonging to nodes that never appear on a PIPE row --
# a node downstream of an orifice or a PRV, for instance.  The NETWORK sheet is
# a list of pipes, so those nodes have nowhere to live on it.  They are kept
# here and re-emitted verbatim on save; losing them would silently delete
# sprinklers from the model, which is exactly what the first version did.
my (%orphan_outlet, %orphan_elev);
# "row,col" => value for every NETWORK cell that is CALCULATED rather than
# typed.  Rebuilt after each edit, and consulted by the cell reader, the
# painter and the serialiser alike -- so what the sheet shows, what it refuses
# to let you edit, and what gets written to the file are always the same thing.
my %derived_now;
# The outlet ID belonging to each node on the NETWORK sheet.  That sheet has no
# outlet-id column -- it is already twenty-one columns wide -- so the id loaded
# from the file is held here and written back unchanged.  Without it a save
# invented "<node>-OUT" for every outlet, silently renaming HYD1 to HY-OUT on
# a model whose outlet references may already appear in a certified report.
my %outlet_id;
my %rdata = map { $_ => [] } @RESULT;

my $net;              # the solved network, or undef if it will not solve
my $path;             # file on disk, or undef for an unsaved model
my $dirty = 0;
my $pending;
# The text exactly as it was loaded.  Saving REWRITES only the blocks the grid
# owns and leaves every other line -- comments, the PROJECT block, PUMPS --
# byte for byte where it was.  The first version regenerated the whole file
# from the grid, which silently deleted all three the moment anyone pressed
# Save.  A tool that loses part of a model on save is worse than one that
# cannot save at all.
my $original = '';
# Comment lines that were found INSIDE a block we regenerate.  The grid has no
# row for them, so without this they vanish the first time anyone saves -- and
# a comment in a model file is usually the one place the reasoning behind a
# number is written down.  They are re-emitted at the top of their block: the
# text survives even though the exact position does not.
my %block_comments;          # after-id for the debounced re-solve

my (%grid, %rgrid);   # widget handles by sheet name
my ($status, $summary, $mw, $nb);
my ($validation, $vcount, $resgrid, $results_holder);

#------------------------------------------------------------------------------
# STATUS LINE -- one place writes it, so the tone stays consistent.
#------------------------------------------------------------------------------
sub set_status {
    my ($text, $colour) = @_;
    return unless $status;
    $status->configure(-text => '  ' . uc($text), -foreground => $colour // $GOOD);
}

sub file_label {
    my $n = defined $path ? ($path =~ s{.*/}{}r) : 'untitled.hcx';
    return uc($n) . ($dirty ? ' *' : '');
}

#==============================================================================
# SERIALISING THE GRID BACK TO .hcx
#==============================================================================

# A row counts only if something is in it.  Blank rows are how a spreadsheet
# lets you move around; they must never become empty records in the file.
sub row_has_content {
    my $row = shift or return 0;
    for my $c (@$row) { return 1 if defined $c && $c =~ /\S/ }
    return 0;
}

# Positional columns are written in order; a 'key' column is written as
# KEY=value and only when it has a value, which keeps a simple pipe on one
# short line instead of padding it with empty tokens.
# Rebuild the file: owned blocks regenerated from the grid, everything else
# preserved exactly as loaded.
sub serialise {
    return serialise_fresh() unless length $original;

    my %owned = map { $_ => 1 }
        qw(PROJECT UNITS OPTIONS NODES PIPES DISCHARGES SUPPLIES PUMPS DEVICES);
    my @out;
    my $skip = '';
    for my $line (split /\n/, $original, -1) {
        my @tk = HardyCross::Parse::tokenize($line);
        my $head = @tk ? uc $tk[0] : '';

        if ($skip) {                       # inside a block we are replacing
            $skip = '' if $head eq 'END';
            next;
        }
        if (@tk == 1 && $owned{$head}) {
            push @out, block_text($head);  # our version of it
            $skip = $head;
            next;
        }
        push @out, $line;
    }
    my $text = join("\n", @out);

    # A block the file did not have but the grid now does must still be added.
    for my $b (qw(PROJECT UNITS OPTIONS NODES PIPES DISCHARGES SUPPLIES PUMPS DEVICES)) {
        next if $original =~ /^\s*\Q$b\E\s*$/m;
        my $t = block_text($b);
        $text .= "\n" . $t . "\n" if length $t;
    }
    return $text;
}

# Gather node attributes from the NETWORK sheet.
#
# A node can appear on many pipe rows.  THE FIRST NON-BLANK VALUE WINS, and a
# later row that contradicts it is reported rather than silently dropped --
# a mistyped elevation that quietly loses to another copy is unfindable.
sub collect_nodes {
    my (%elev, %outlet, @order, @conflicts);
    my $rows_ref = $doc{NETWORK} || [];
    for my $ri (0 .. $#$rows_ref) {
        my $row = $rows_ref->[$ri];
        next unless row_has_content($row);
        # columns: 0 pipe 1 A 2 B 3 len 4 type 5 dia 6 fit 7 spacer
        #          8..13 node A block (elev type K flow press device)
        #          14 spacer, 15..20 node B block
        for my $side ([ $row->[1], 8 ], [ $row->[2], 15 ]) {
            my ($node, $base) = @$side;
            next unless defined $node && $node =~ /\S/;
            push @order, $node unless exists $elev{$node} || exists $outlet{$node};
            # Read the RAW cells -- what the user typed -- never the derived
            # map.  A derived cell is a result: its value is recomputed from
            # the inputs every time, exactly.  An earlier version read through
            # the derived map here, reasoning that the file should hold what
            # the sheet shows.  That was wrong.  The sheet shows the derived K
            # ROUNDED for display, so every save wrote a rounded 75.89 back as
            # an INPUT in place of the exact 75.8946, turned two inputs into
            # three, and moved the flows by 0.1 L/min per save.  Mirrored
            # repeat rows read as blank here, which is also correct: the
            # node's data lives on the row where it was first entered.
            my ($e, $ty, $k, $q, $p) = map { $row->[ $base + $_ ] } 0 .. 4;
            if (defined $e && $e =~ /\S/) {
                if (exists $elev{$node} && $elev{$node} ne $e) {
                    push @conflicts, "$node elevation $elev{$node} vs $e";
                } else { $elev{$node} //= $e }
            }
            if (defined $ty && $ty =~ /\S/) {
                $outlet{$node} //= { type => uc $ty, k => '', q => '', p => '' };
                $outlet{$node}{k} = $k if defined $k && $k =~ /\S/;
                $outlet{$node}{q} = $q if defined $q && $q =~ /\S/;
                $outlet{$node}{p} = $p if defined $p && $p =~ /\S/;
            }
        }
    }
    my %seen;
    @order = grep { !$seen{$_}++ } @order;
    return (\%elev, \%outlet, \@order, \@conflicts);
}

# One block, regenerated from the sheets.  Returns '' when empty, so an unused
# block does not leave a bare BLOCK/END pair behind.
sub block_text {
    my $block = shift;

    if ($block eq 'PROJECT') {
        my @l = grep { defined $project{$_} && $project{$_} =~ /\S/ } @PROJECT_FIELDS;
        return '' unless @l;
        return "PROJECT\n" . join('', map { sprintf("  %-12s %s\n", $_, $project{$_}) } @l)
               . "END";
    }
    if ($block eq 'UNITS') {
        return "UNITS\n" . join('', map { sprintf("  %s %s\n", $_, $units{$_}) }
                                 @UNIT_FIELDS) . "END";
    }
    if ($block eq 'OPTIONS') {
        return "OPTIONS\n" . join('', map { sprintf("  %s %s\n", $_, $opts{$_}) }
                                   grep { defined $opts{$_} && $opts{$_} =~ /\S/ }
                                   sort keys %opts) . "END";
    }

    # NODES, PIPES and DISCHARGES are all derived from the one NETWORK sheet.
    if ($block eq 'NODES') {
        my ($elev, $outlet, $order) = collect_nodes();
        return '' unless @$order;
        my $out = "NODES\n";
        $out .= "$_\n" for @{ $block_comments{NODES} || [] };
        $out .= sprintf("  %s %s\n", $_, $elev->{$_} // '0') for @$order;
        my %done = map { $_ => 1 } @$order;
        for my $r (@{ $doc{OTHERNODES} || [] }) {
            next unless row_has_content($r) && defined $r->[0] && $r->[0] =~ /\S/;
            next if $done{ $r->[0] }++;
            $out .= sprintf("  %s %s\n", $r->[0],
                            (defined $r->[1] && $r->[1] =~ /\S/) ? $r->[1] : 0);
        }
        return $out . "END";
    }
    if ($block eq 'PIPES') {
        my @live = grep { row_has_content($_) && defined $_->[0] && $_->[0] =~ /\S/ }
                   @{ $doc{NETWORK} || [] };
        return '' unless @live;
        my $out = "PIPES\n";
        $out .= "$_\n" for @{ $block_comments{PIPES} || [] };
        for my $r (@live) {
            my @p = ($r->[0], $r->[1], $r->[2], $r->[3], $r->[5]);
            my @extra;
            # TYPE and FIT are carried as key=value so the engine, which
            # ignores keys it does not know, still reads the file identically.
            push @extra, "TYPE=$r->[4]" if defined $r->[4] && $r->[4] =~ /\S/;
            if (defined $r->[6] && $r->[6] =~ /\S/) {
                # A bare number is an equivalent length; anything else is a
                # fitting string for the front end to resolve.
                push @extra, ($r->[6] =~ /^\s*[\d.]+\s*$/)
                             ? "EQV=$r->[6]" : "FIT=$r->[6]";
            }
            $out .= '  ' . join(' ', grep { defined && /\S/ } @p, @extra) . "\n";
        }
        return $out . "END";
    }
    if ($block eq 'DISCHARGES') {
        my ($elev, $outlet, $order) = collect_nodes();
        my @live = grep { $outlet->{$_} } @$order;
        my @other = grep { row_has_content($_) && defined $_->[4] && $_->[4] =~ /\S/ }
                    @{ $doc{OTHERNODES} || [] };
        return '' unless @live || @other;
        my $out = "DISCHARGES\n";
        $out .= "$_\n" for @{ $block_comments{DISCHARGES} || [] };
        for my $n (@live) {
            my $o = $outlet->{$n};
            # The id from the file if there was one; a generated id only for
            # an outlet typed into the sheet for the first time.
            my @p = ($outlet_id{$n} // "$n-OUT", $n, $o->{type});
            push @p, "K=$o->{k}" if $o->{k} =~ /\S/;
            push @p, "Q=$o->{q}" if $o->{q} =~ /\S/;
            push @p, "P=$o->{p}" if $o->{p} =~ /\S/;
            $out .= '  ' . join(' ', @p) . "\n";
        }
        for my $r (@other) {
            my ($n, undef, undef, $oid, $ty, $k, $q, $pr) = @$r;
            my $o = { id => ($oid =~ /\S/ ? $oid : "$n-OUT"), type => uc $ty,
                      k => $k // '', q => $q // '', p => $pr // '' };
            my @p = ($o->{id}, $n, $o->{type});
            push @p, "K=$o->{k}" if $o->{k} =~ /\S/;
            push @p, "Q=$o->{q}" if $o->{q} =~ /\S/;
            push @p, "P=$o->{p}" if $o->{p} =~ /\S/;
            $out .= '  ' . join(' ', @p) . "\n";
        }
        return $out . "END";
    }
    if ($block eq 'PUMPS') {
        my @live = grep { row_has_content($_) && defined $_->[0] && $_->[0] =~ /\S/ }
                   @{ $doc{PUMPS} || [] };
        return '' unless @live;
        my $out = "PUMPS\n";
        $out .= "$_\n" for @{ $block_comments{PUMPS} || [] };
        for my $r (@live) {
            my @p = @{$r}[0 .. 2];
            # Curve pairs are written only while BOTH halves are present: a
            # flow with no pressure beside it is not a point on a curve.
            for (my $j = 4; $j + 1 < scalar @$r; $j += 2) {
                my ($q, $pp) = ($r->[$j], $r->[ $j + 1 ]);
                next unless defined $q && $q =~ /\S/ && defined $pp && $pp =~ /\S/;
                push @p, $q, $pp;
            }
            $out .= '  ' . join(' ', grep { defined && /\S/ } @p) . "\n";
        }
        return $out . "END";
    }
    if ($block eq 'SUPPLIES') {
        my @live = grep { row_has_content($_) } @{ $doc{SUPPLIES} || [] };
        return '' unless @live;
        my $out = "SUPPLIES\n";
        $out .= "$_\n" for @{ $block_comments{SUPPLIES} || [] };
        my $i = 0;
        for my $r (@live) {
            $i++;
            my ($node, $z, $type, $p0) = @{$r}[0 .. 3];
            $type = uc($type || 'STATIC');
            my @p = ("SUP$i", $node, $type);
            if ($type eq 'STATIC') {
                push @p, $p0;
            } else {
                # The sheet shows shutoff pressure first, then flow/pressure
                # pairs; the file wants Q P pairs, so zero flow leads.
                push @p, 0, $p0 if defined $p0 && $p0 =~ /\S/;
                for (my $j = 5; $j + 1 < scalar @$r; $j += 2) {
                    my ($q, $pp) = ($r->[$j], $r->[ $j + 1 ]);
                    next unless defined $q && $q =~ /\S/ && defined $pp && $pp =~ /\S/;
                    push @p, $q, $pp;
                }
            }
            push @p, "Z=$z" if defined $z && $z =~ /\S/;
            $out .= '  ' . join(' ', grep { defined && /\S/ } @p) . "\n";
        }
        return $out . "END";
    }
    if ($block eq 'DEVICES') {
        my @live = grep { row_has_content($_) } @{ $doc{DEVICES} || [] };
        return '' unless @live;
        my $out = "DEVICES\n";
        $out .= "$_\n" for @{ $block_comments{DEVICES} || [] };
        for my $r (@live) {
            my @p = @{$r}[0 .. 3];
            push @p, grep { defined && /\S/ } @{$r}[ 8 .. $#$r ];   # curve pairs
            push @p, "DP=$r->[4]"   if defined $r->[4] && $r->[4] =~ /\S/;
            push @p, "BORE=$r->[5]" if defined $r->[5] && $r->[5] =~ /\S/;
            push @p, "DN=$r->[6]"   if defined $r->[6] && $r->[6] =~ /\S/;
            $out .= '  ' . join(' ', grep { defined && /\S/ } @p) . "\n";
        }
        return $out . "END";
    }
    return '';
}

# Used only for a model typed from scratch, where there is no original to
# preserve.
sub serialise_fresh {
    my $out = "UNITS\n";
    $out .= sprintf("  %s %s\n", $_, $units{$_}) for qw(FLOW PRESSURE LENGTH DIAMETER);
    $out .= "END\n\nOPTIONS\n";
    $out .= sprintf("  %s %s\n", $_, $opts{$_}) for sort keys %opts;
    $out .= "END\n\n";

    for my $block (@INPUT) {
        my @live = grep { row_has_content($_) } @{ $doc{$block} };
        next unless @live;
        my $cols = $SCHEMA{$block};
        $out .= "$block\n";
        for my $row (@live) {
            my @parts;
            for my $i (0 .. $#$cols) {
                my $v = $row->[$i];
                next unless defined $v && $v =~ /\S/;
                $v =~ s/^\s+|\s+$//g;
                push @parts, $cols->[$i]{key} ? "$cols->[$i]{key}=$v" : $v;
            }
            $out .= '  ' . join(' ', @parts) . "\n";
        }
        $out .= "END\n\n";
    }
    return $out;
}

# Load a .hcx file INTO the grid.
#
# Parsed here rather than by the engine, because the grid needs the RAW TOKENS
# -- what the user wrote -- not the converted internal values the engine keeps.
# Round-tripping through the engine would silently rewrite the user's numbers.
# Load a .hcx file INTO the sheets.
#
# Parsed here rather than by the engine, because the grid needs the RAW TOKENS
# -- what the user wrote -- not the converted internal values the engine keeps.
# Round-tripping through the engine would silently rewrite the user's numbers.
#
# The file's NODES, PIPES and DISCHARGES blocks are JOINED into one row per
# pipe, which is what the NETWORK sheet shows.
sub load_text {
    my $text = shift;
    $original = $text;
    %doc   = map { $_ => [] } @INPUT;
    %block_comments = ();
    %units = (FLOW => 'LPM', PRESSURE => 'KPA', LENGTH => 'M', DIAMETER => 'MM');
    %opts  = (METHOD => 'HW');
    %project = ();

    my (%nodes, %outlets, @pipes, @supplies, @devices, @pumps, @node_order);
    my $section = '';

    for my $line (split /\n/, $text) {
        my @tk = HardyCross::Parse::tokenize($line);
        if (!@tk) {
            push @{ $block_comments{$section} }, $line if $section && $line =~ /\S/;
            next;
        }
        my $head = uc $tk[0];
        if ($head =~ /^(PROJECT|UNITS|OPTIONS|NODES|PIPES|PUMPS|SUPPLIES|DISCHARGES|DEVICES)$/
            && @tk == 1) { $section = $head; next }
        if ($head eq 'END') { $section = ''; next }
        next unless $section;

        # Split every data row once into positional and KEY=value tokens.
        my (@pos, %kv);
        for my $t (@tk) {
            if ($t =~ /^([A-Za-z_]+)=(.*)$/) { $kv{ uc $1 } = $2 } else { push @pos, $t }
        }

        if ($section eq 'PROJECT') {
            # The value is the rest of the line, so a title keeps its spacing.
            my $raw = $line;
            $raw =~ s/^\s*\S+\s*//;
            $raw =~ s/\s+$//;
            $project{ uc $pos[0] } = $raw if @pos;
            next;
        }
        if ($section eq 'UNITS')   { $units{ uc $pos[0] } = uc $pos[1] if @pos >= 2; next }
        if ($section eq 'OPTIONS') { $opts{ uc $pos[0] }  = uc $pos[1] if @pos >= 2; next }
        if ($section eq 'NODES')   {
            $nodes{ $pos[0] } = $pos[1] // '';
            push @node_order, $pos[0];
            next;
        }
        if ($section eq 'PUMPS')   { push @pumps, [ \@pos, \%kv ]; next }
        if ($section eq 'PIPES')   { push @pipes, [ \@pos, \%kv ]; next }
        if ($section eq 'SUPPLIES'){ push @supplies, [ \@pos, \%kv ]; next }
        if ($section eq 'DEVICES') { push @devices, [ \@pos, \%kv ]; next }
        if ($section eq 'DISCHARGES') {
            push @node_order, $pos[1] if defined $pos[1];
            # id node TYPE [K= Q= P= MINQ= MINP=] -- keyed by NODE, because the
            # network sheet shows an outlet as a property of its node.
            $outlets{ $pos[1] } = {
                id => $pos[0], type => uc($pos[2] // ''),
                k  => $kv{K}    // '',
                q  => $kv{Q}    // $kv{MINQ} // '',
                p  => $kv{P}    // $kv{MINP} // '',
            } if @pos >= 2;
            next;
        }
    }

    # --- build the NETWORK rows -------------------------------------------
    # Any node that no pipe touches cannot be shown on this sheet; set it
    # aside so save does not drop it.
    my %on_a_pipe;
    for my $pr (@pipes) {
        $on_a_pipe{ $pr->[0][1] // '' } = 1;
        $on_a_pipe{ $pr->[0][2] // '' } = 1;
    }
    # Every node no pipe touches becomes a row on the OTHER NODES sheet, in
    # the order the file first mentions it.
    %orphan_outlet = ();
    %orphan_elev   = ();
    %outlet_id     = map { $_ => $outlets{$_}{id} } keys %outlets;
    my %placed;
    for my $n (@node_order) {
        next if $on_a_pipe{$n} || $placed{$n}++;
        my $o = $outlets{$n};
        push @{ $doc{OTHERNODES} }, [
            $n, $nodes{$n} // '', '',
            $o ? $o->{id} : '', $o ? $o->{type} : '',
            $o ? $o->{k} : '', $o ? $o->{q} : '', $o ? $o->{p} : '',
        ];
    }

    my %seen_node;
    for my $pr (@pipes) {
        my ($pos, $kv) = @$pr;
        my ($id, $na, $nb, $len, $dia, $c) = @$pos;
        my @row = ($id // '', $na // '', $nb // '', $len // '',
                   $kv->{TYPE} // '', $dia // '',
                   # FIT wins if both are present: the string is what the user
                   # wrote, the number is what it resolved to.
                   # The tokeniser turns the commas inside FIT= into '+' so
                   # they survive the split; show them as the user typed them.
                   (defined $kv->{FIT} ? ($kv->{FIT} =~ tr/+/,/r)
                                       : ($kv->{EQV} // '')), '');
        for my $n ($na, $nb) {
            my $o = $outlets{ $n // '' };
            # A node's attributes are written on the FIRST pipe row that
            # mentions it.  Repeating them on every row would look like data
            # and invite someone to edit one copy and not the other.
            my $first = !$seen_node{ $n // '' }++;
            # SIX cells per node block -- elevation, type, K, flow, pressure,
            # device -- then the spacer.  The block grew when the device column
            # was added, and pushing the old five left every node B column one
            # place to the left of its heading.
            push @row, $first ? ($nodes{ $n // '' } // '') : '',
                       $first && $o ? $o->{type} : '',
                       $first && $o ? $o->{k}    : '',
                       $first && $o ? $o->{q}    : '',
                       $first && $o ? $o->{p}    : '',
                       '',            # device: derived, never loaded
                       '';            # spacer
        }
        pop @row;                     # the trailing spacer is not a column
        push @{ $doc{NETWORK} }, \@row;
    }

    # --- PUMPS -------------------------------------------------------------
    for my $pr (@pumps) {
        my ($pos, $kv) = @$pr;
        my ($id, $n1, $n2, @curve) = @$pos;
        push @{ $doc{PUMPS} }, [ $id // '', $n1 // '', $n2 // '', '', @curve ];
    }

    # --- SUPPLIES ----------------------------------------------------------
    for my $sr (@supplies) {
        my ($pos, $kv) = @$sr;
        my ($id, $node, $type, @rest) = @$pos;
        my @row = ($node // '', $kv->{Z} // ($nodes{ $node // '' } // ''),
                   uc($type // ''), '', '');
        if (uc($type // '') eq 'STATIC') {
            $row[3] = $rest[0] // '';           # one pressure, unlimited flow
        } else {
            # Curve points are written Q P in the file; the sheet shows the
            # shutoff pressure first, then flow/pressure pairs.
            my @pairs = @rest;
            $row[3] = (@pairs >= 2 && ($pairs[0] // '') == 0) ? $pairs[1] : '';
            shift @pairs, shift @pairs if $row[3] ne '';
            while (@pairs >= 2) {
                push @row, shift(@pairs), shift(@pairs);
            }
        }
        push @{ $doc{SUPPLIES} }, \@row;
    }

    # --- DEVICES -----------------------------------------------------------
    for my $dr (@devices) {
        my ($pos, $kv) = @$dr;
        my ($id, $n1, $n2, $type, @curve) = @$pos;
        my @row = ($id // '', $n1 // '', $n2 // '', uc($type // ''),
                   $kv->{DP} // '', $kv->{BORE} // '', $kv->{DN} // '', '');
        push @row, @curve;
        push @{ $doc{DEVICES} }, \@row;
    }

    %derived_now = %{ network_derived() };
    refresh_grids();
    # The grid keeps the cell being edited in an edit buffer of its own.  When
    # the whole document is replaced -- opening a file -- that buffer still
    # holds the OLD model's text and goes on showing it: after opening a model
    # whose supply is at node SUP, the cell still read "A" from the model
    # before it, while everything else had changed.  reread throws the buffer
    # away and takes the value from the new document.  Re-activating the cell
    # instead would be worse: that COMMITS the buffer, writing the old value
    # into the new model.
    for my $t (grep { defined } values %grid) {
        $t->reread;          # drop the edit buffer of the cell being edited
        # ...and the widget's cached cell text.  The grid remembers what it
        # last DREW in each cell and does not ask again until something makes
        # it: after opening a second model, the PROJECT sheet went on showing
        # the previous model's fields -- or nothing at all -- until each row
        # was clicked.  The data underneath was right the whole time.
        eval { $t->clearCache };
        $t->update;
    }
    fit_columns('NETWORK');
    paint_derived();
    solve_now();
}

#==============================================================================
# SOLVING
#==============================================================================

# Re-solve after a short pause rather than on every keystroke.
#
# Typing "150" is three separate edits, and solving three times in a row makes
# the interface feel sticky.  250 ms is long enough to coalesce a number and
# short enough that the result still feels immediate.
sub schedule_solve {
    return unless $mw;
    $mw->afterCancel($pending) if $pending;
    $pending = $mw->after(250, \&solve_now);
}

sub solve_now {
    $pending = undef;
    my $text = serialise();

    # The engine signals a model it cannot solve honestly by dying with a
    # blessed error.  That is a REFUSAL, not a crash: show it in the engine's
    # own words, because an empty results sheet with no explanation looks like
    # a bug in the front end.
    my $n  = eval { HardyCross::Parse::read_string($text) };
    my $ok = $n ? eval { HardyCross::solve_model($n) } : undef;
    unless (defined $ok) {
        my $err = $@;
        $net = undef;
        refresh_results();
        refresh_validation();
        $summary->configure(-text => '  ' . file_label());
        set_status('cannot solve - ' .
            (HardyCross::is_model_error($err) ? $err->{msg} : ($err || 'unknown')), $BAD);
        return;
    }

    $net = $n;
    refresh_results();
    refresh_validation();
    $summary->configure(-text => sprintf(
        '  %s   |   %d LOOPS   |   %d ITERATIONS   |   CONTINUITY %.3e L/MIN',
        file_label(), scalar @{ $net->{loops} }, $net->{iters},
        HardyCross::continuity_error($net)));
    if (0) {
        # Say so rather than leaving them invisible: an outlet that is in the
        # model but not on any sheet is a trap for whoever edits it next.
        # The detail belongs in the validation panel, which is on screen; the
        # status line says only whether the answer is usable.  Saying the same
        # thing twice trains the eye to read neither.
        set_status('converged', $GOOD);
        return;
    }
    set_status($ok ? 'converged'
                   : 'did not converge - nothing in the results is usable',
               $ok ? $GOOD : $BAD);
}

#==============================================================================
# THE INPUT GRID
#==============================================================================

# TableMatrix asks for a cell's contents by "row,col" through this callback,
# and hands back an edited value the same way.
#
# Row 0 is the column heading and column 0 is the row number -- that is what
# makes the sheet read like a spreadsheet rather than a bare table.  Both are
# generated here rather than stored, so they can never fall out of step.
# The PROJECT sheet is a fixed list of fields rather than a growing record
# list, so it reads and writes %project, %units and %opts directly.
my @PROJECT_ROWS;
sub project_rows {
    # A blank row between groups reads as a field someone forgot to fill in.
    # A labelled band says what the next group IS, and costs the same height.
    @PROJECT_ROWS = ([ '#', 'PROJECT DETAILS' ],
                     (map { [ 'PROJECT', $_ ] } @DETAIL_FIELDS),
                     [ '#', 'DESIGN DATA' ],
                     (map { [ 'PROJECT', $_ ] } @DESIGN_FIELDS),
                     [ '#', 'AUTHORITY' ],
                     (map { [ 'PROJECT', $_ ] } @AUTHORITY_FIELDS),
                     [ '#', 'UNITS' ],
                     (map { [ 'UNITS',   $_ ] } @UNIT_FIELDS),
                     [ '#', 'SOLVER OPTIONS' ],
                     (map { [ 'OPTIONS', $_ ] } @OPTION_FIELDS));
    return \@PROJECT_ROWS;
}

sub project_cell {
    my ($set, $r, $c, $value) = @_;
    my $rows = project_rows();
    return ($c == 0 ? '' : ($c == 1 ? 'FIELD' : 'VALUE')) if $r == 0;
    return $r if $c == 0;
    my $spec = $rows->[ $r - 1 ] or return '';
    my ($group, $field) = @$spec;
    return ($c == 1 ? $field : '') if $group eq '#';   # a group band
    return ($FIELD_LABEL{$field} // $field) if $c == 1;
    my $store = $group eq 'PROJECT' ? \%project
              : $group eq 'UNITS'   ? \%units
              :                       \%opts;
    return '' if $group eq '#';
    if ($set) {
        push_undo() if ($store->{$field} // '') ne ($value // '');
        $store->{$field} = $value;
        $dirty = 1;
        schedule_solve();
        return $value;
    }
    return $store->{$field} // '';
}

#------------------------------------------------------------------------------
# DERIVED CELLS
#
# Three separate things on the NETWORK sheet are computed rather than typed,
# and all three are greyed so nobody can tell them apart from data they own:
#
#  1. A NODE THAT REAPPEARS.  A node's elevation, outlet type, K, flow and
#     pressure belong to the node, not to the pipe.  They are typed on the
#     first row that mentions the node and shown -- greyed -- on every later
#     row, so you can see what they are without being invited to edit a second
#     copy that would then disagree with the first.
#
#  2. THE PRESSURE DEVICE at a node.  Read from the PRESSURE DEVICES sheet,
#     because a device is an edge between two nodes and defining it from a node
#     column would give two places to say the same thing.
#
#  3. THE THIRD OF K, FLOW, PRESSURE.  Equation B1 ties them together:
#
#         K = Q / sqrt(P)     Q = K sqrt(P)     P = (Q/K)^2
#
#     so exactly TWO are input and the third follows.  With a K you give flow
#     or pressure; without one you give both.  Whichever is left over is
#     computed, displayed and greyed -- it is a result, and a result you can
#     type over is a result you cannot trust.
#------------------------------------------------------------------------------

# Devices at each node, keyed by node id, from the PRESSURE DEVICES sheet.
sub device_at_node {
    my %at;
    for my $r (@{ $doc{DEVICES} || [] }) {
        next unless row_has_content($r);
        my ($id, $n1, $n2, $type) = @{$r}[0 .. 3];
        next unless defined $id && $id =~ /\S/;
        for my $n ($n1, $n2) {
            next unless defined $n && $n =~ /\S/;
            $at{$n} = $at{$n} ? "$at{$n},$id" : $id;
        }
    }
    return \%at;
}

# Which of K, flow, pressure is derived for one outlet, and what its value is.
#
# Returns (derived_offset, value) where the offset is 2, 3 or 4 within the node
# block, or (undef) when too little has been entered to derive anything.
sub derive_kqp {
    my ($k, $q, $p, $type) = @_;
    # A fixed-flow outlet is a nodal demand, not a pressure-dependent one:
    # the flow IS the input and there is no K to find.  Equation B1 does not
    # apply to it, and deriving a K produced a number with no meaning.
    return (undef, undef) if defined $type && uc($type) =~ /^FIXED/;
    my $has = sub { defined $_[0] && $_[0] =~ /\S/ && $_[0] + 0 != 0 || (defined $_[0] && $_[0] =~ /^0*\.?0+$/ && 0) };
    my ($hk, $hq, $hp) = (scalar $has->($k), scalar $has->($q), scalar $has->($p));

    # K and flow given -> pressure follows from P = (Q/K)^2
    return (4, sprintf('%.1f', ($q / $k) ** 2)) if $hk && $hq && !$hp && $k > 0;
    # K and pressure given -> flow follows from Q = K sqrt(P)
    return (3, sprintf('%.1f', $k * sqrt($p)))  if $hk && $hp && !$hq && $p >= 0;
    # flow and pressure given -> K follows from K = Q / sqrt(P)
    return (2, sprintf('%.2f', $q / sqrt($p)))  if !$hk && $hq && $hp && $p > 0;
    return (undef, undef);
}

# Work out, for every cell on the NETWORK sheet, whether it is derived and what
# it should show.  Returns a hash of "row,col" => value for the derived cells.
sub network_derived {
    my %derived;
    my $devices = device_at_node();
    my %defined_at;                 # node => row index where it was first typed

    my $rows = $doc{NETWORK} || [];
    for my $ri (0 .. $#$rows) {
        my $row = $rows->[$ri] or next;
        for my $side ([ $row->[1], 8 ], [ $row->[2], 15 ]) {
            my ($node, $base) = @$side;
            next unless defined $node && $node =~ /\S/;

            # (2) the device column is always derived
            $derived{ ($ri + 1) . ',' . ($base + 5 + 1) } = $devices->{$node} // '';

            if (exists $defined_at{$node}) {
                # (1) a repeat: mirror the first row's values, all greyed
                my $src = $defined_at{$node};
                for my $o (0 .. 4) {
                    $derived{ ($ri + 1) . ',' . ($base + $o + 1) } =
                        $rows->[ $src->[0] ][ $src->[1] + $o ] // '';
                }
                next;
            }
            $defined_at{$node} = [ $ri, $base ];

            # (3) the third of K, flow, pressure
            my ($k, $q, $p) = @{$row}[ $base + 2 .. $base + 4 ];
            my ($off, $val) = derive_kqp($k, $q, $p, $row->[ $base + 1 ]);
            $derived{ ($ri + 1) . ',' . ($base + $off + 1) } = $val
                if defined $off;
        }
    }
    return \%derived;
}


# Repaint the grey tags.  Called after any edit, because which cells are
# derived changes as the sheet is filled in.
#------------------------------------------------------------------------------
# CELL-LEVEL VALIDATION
#
# Everything that can be pinned to a single cell is found here, as a list of
# { sev, block, r, c, what }.  The same list colours the sheet red as you type
# AND fills the validation panel, so what is marked on the grid and what is
# listed beside it cannot disagree.  Findings that belong to the whole model --
# non-convergence, a node whose copies disagree -- stay in validate_model.
#
# Row arrays are 0-based; grid rows and columns are 1-based, with row 0 the
# headings and column 0 the row numbers.
#------------------------------------------------------------------------------
my %cell_bad;          # block => { "r,c" => 'ERROR' | 'WARN' }
my $db_ready;

sub is_num_text { my $v = shift; defined $v && $v =~ /^\s*-?(\d+\.?\d*|\.\d+)([eE][-+]?\d+)?\s*$/ }
sub has { my $v = shift; defined $v && $v =~ /\S/ }

sub cell_problems {
    my @p;
    my $add = sub { my ($sev, $b, $ri, $ci, $what) = @_;
                    push @p, { sev => $sev, block => $b, r => $ri + 1, c => $ci + 1, what => $what } };
    $db_ready //= eval { HardyCross::PipeData::load(); 1 } ? 1 : 0;

    for my $b (grep { $_ ne 'PROJECT' } @INPUT) {
        my $cols = $SCHEMA{$b};
        my $rows = $doc{$b} || [];
        for my $ri (0 .. $#$rows) {
            my $r = $rows->[$ri];
            next unless row_has_content($r);
            # a number column holding something that is not a number
            for my $ci (0 .. $#$cols) {
                next unless $cols->[$ci]{num} && has($r->[$ci]);
                next if $b eq 'NETWORK' && exists $derived_now{ ($ri + 1) . ',' . ($ci + 1) };
                $add->('ERROR', $b, $ri, $ci, uc($cols->[$ci]{h}) . " must be a number, not '$r->[$ci]'")
                    unless is_num_text($r->[$ci]);
            }
            my $pairs = sub {        # count complete flow/pressure pairs from column $from
                my $from = shift; my $n = 0;
                for (my $j = $from; $j + 1 <= $#$cols; $j += 2) { $n++ if has($r->[$j]) && has($r->[$j + 1]) }
                return $n;
            };
            if ($b eq 'NETWORK') {
                $add->('ERROR', $b, $ri, 0, 'pipe has no reference')   unless has($r->[0]);
                $add->('ERROR', $b, $ri, 1, 'pipe has no NODE A')      unless has($r->[1]);
                $add->('ERROR', $b, $ri, 2, 'pipe has no NODE B')      unless has($r->[2]);
                $add->('ERROR', $b, $ri, 3, 'pipe has no length')      unless has($r->[3]);
                $add->('ERROR', $b, $ri, 5, 'pipe has no diameter')    unless has($r->[5]);
                my ($ty, $dia, $fit) = ($r->[4], $r->[5], $r->[6]);
                if (has($ty) && $db_ready) {
                    my $info = HardyCross::PipeData::pipe_type(uc $ty);
                    if (!$info) {
                        $add->('ERROR', $b, $ri, 4, "pipe type '$ty' is not in the pipe database");
                    } elsif (is_num_text($dia)
                             && !defined HardyCross::PipeData::bore(uc $ty, int($dia + 0.5))) {
                        $add->('ERROR', $b, $ri, 5, "DATA_REQUIRED: DN$dia is not tabulated for " . uc $ty);
                    } elsif (has($fit) && !is_num_text($fit) && is_num_text($dia)) {
                        my $res = HardyCross::PipeData::resolve(type => uc $ty, dn => int($dia + 0.5),
                                                                spec => $fit);
                        $add->('ERROR', $b, $ri, 6, $res->{errors}[0]) if @{ $res->{errors} };
                    }
                } elsif (has($fit) && !is_num_text($fit)) {
                    $add->('ERROR', $b, $ri, 6, 'a fitting string needs a pipe TYPE, so its table '
                                              . 'and basis bore are known');
                } elsif (has($dia)) {
                    $add->('WARN', $b, $ri, 4, 'no pipe type: the bore is taken as typed, not looked up');
                }
                # an outlet on the row where its node is first entered needs two of K, flow, pressure
                for my $base (8, 15) {
                    next if exists $derived_now{ ($ri + 1) . ',' . ($base + 1) };   # a mirrored repeat
                    my ($oty, $k, $q, $pr) = @{$r}[ $base + 1 .. $base + 4 ];
                    next unless has($oty) && uc($oty) !~ /^FIXED/;
                    my $given = grep { has($_) } ($k, $q, $pr);
                    next if $given >= 2;
                    $add->('ERROR', $b, $ri, $_, 'an outlet needs any two of K, flow and pressure')
                        for grep { !has($r->[$_]) } ($base + 2, $base + 3, $base + 4);
                }
            }
            elsif ($b eq 'OTHERNODES') {
                $add->('ERROR', $b, $ri, 0, 'row has no node') unless has($r->[0]);
                my ($oty, $k, $q, $pr) = @{$r}[4 .. 7];
                if (has($oty) && uc($oty) !~ /^FIXED/ && (grep { has($_) } ($k, $q, $pr)) < 2) {
                    $add->('ERROR', $b, $ri, $_, 'an outlet needs any two of K, flow and pressure')
                        for grep { !has($r->[$_]) } (5, 6, 7);
                }
            }
            elsif ($b eq 'SUPPLIES') {
                $add->('ERROR', $b, $ri, 0, 'supply has no node') unless has($r->[0]);
                my $ty = uc($r->[2] // '');
                if ($ty eq 'STATIC' || $ty eq '') {
                    $add->('ERROR', $b, $ri, 3, 'a static supply needs its pressure') unless has($r->[3]);
                } elsif ($ty eq 'CURVE') {
                    $add->('ERROR', $b, $ri, 5, 'a supply curve needs at least two points')
                        if $pairs->(5) + (has($r->[3]) ? 1 : 0) < 2;
                } else {
                    $add->('ERROR', $b, $ri, 2, "supply type must be STATIC or CURVE, not '$r->[2]'");
                }
            }
            elsif ($b eq 'PUMPS') {
                $add->('ERROR', $b, $ri, 0, 'pump has no reference') unless has($r->[0]);
                $add->('ERROR', $b, $ri, 1, 'pump has no FROM node') unless has($r->[1]);
                $add->('ERROR', $b, $ri, 2, 'pump has no TO node')   unless has($r->[2]);
                $add->('ERROR', $b, $ri, 4, 'a pump curve needs at least two points') if $pairs->(4) < 2;
            }
            elsif ($b eq 'DEVICES') {
                $add->('ERROR', $b, $ri, 0, 'device has no reference') unless has($r->[0]);
                $add->('ERROR', $b, $ri, 1, 'device has no FROM node') unless has($r->[1]);
                $add->('ERROR', $b, $ri, 2, 'device has no TO node')   unless has($r->[2]);
                my $ty = uc($r->[3] // '');
                if    ($ty eq '') { $add->('ERROR', $b, $ri, 3, 'device has no type') }
                elsif ($ty !~ /^(PRV|BFP|ORIFICE_P|ORIFICE_D)$/) {
                    $add->('ERROR', $b, $ri, 3, "device type must be PRV, BFP, ORIFICE_P or ORIFICE_D");
                }
                $add->('ERROR', $b, $ri, 4, "$ty needs a drop") if $ty =~ /^(PRV|ORIFICE_P)$/ && !has($r->[4]);
                $add->('ERROR', $b, $ri, 5, 'ORIFICE_D needs its bore') if $ty eq 'ORIFICE_D' && !has($r->[5]);
                $add->('ERROR', $b, $ri, 6, 'an orifice needs its DN') if $ty =~ /^ORIFICE/ && !has($r->[6]);
                $add->('ERROR', $b, $ri, 8, 'a BFP needs a loss curve of at least two points')
                    if $ty eq 'BFP' && $pairs->(8) < 2;
            }
        }
    }
    %cell_bad = ();
    for my $x (@p) {
        my $k = "$x->{r},$x->{c}";
        $cell_bad{ $x->{block} }{$k} = $x->{sev}
            unless ($cell_bad{ $x->{block} }{$k} // '') eq 'ERROR';
    }
    return \@p;
}

# Repaint every record sheet: invalid > derived > spacer > the column's own look.
sub paint_sheet {
    my $b = shift;
    my $t = $grid{$b} or return;
    my $cols = $SCHEMA{$b};
    my $nrow = scalar @{ $doc{$b} || [] };
    my %by;
    for my $r (1 .. $nrow) {
        for my $c (1 .. @$cols) {
            my $k = "$r,$c";
            my $bad = $cell_bad{$b}{$k} // '';
            my $tag = $bad eq 'ERROR' ? 'invalid'
                    : $bad eq 'WARN'  ? 'warncell'
                    : ($b eq 'NETWORK' && exists $derived_now{$k}) ? 'derived'
                    : $cols->[ $c - 1 ]{h} eq '' ? 'spacer'
                    : $cols->[ $c - 1 ]{num} ? 'num' : 'text';
            push @{ $by{$tag} }, $k;
        }
    }
    # one call per tag rather than per cell: a 200-pipe sheet is 4,000 cells
    $t->tagCell($_, @{ $by{$_} }) for keys %by;
    print STDERR "PAINT $b: ", join(' ', map { "$_=" . scalar @{ $by{$_} } } sort keys %by), "\n"
        if $ENV{PHCP_DEBUG_PAINT};
}

# Everything an edit sets off, in one place, so no operation can skip a step.
sub after_edit {
    my @blocks = @_ ? @_ : grep { $_ ne 'PROJECT' } @INPUT;
    $dirty = 1;
    ensure_blank_row($_) for @blocks;
    %derived_now = %{ network_derived() };
    cell_problems();
    fit_columns($_) for @blocks;
    paint_sheet($_) for grep { $_ ne 'PROJECT' } @INPUT;
    $_->update for grep { defined } map { $grid{$_} } @blocks;
    schedule_solve();
}

sub paint_derived {
    cell_problems();
    paint_sheet($_) for grep { $_ ne 'PROJECT' } @INPUT;
}

#------------------------------------------------------------------------------
# UNDO AND REDO
#
# Whole-document snapshots rather than per-cell reversal.  A snapshot is a deep
# copy of every sheet plus the project, units and options -- a few kilobytes
# for a real model -- and restoring one cannot leave the document half-undone,
# which a chain of individual cell reversals can when a carry-down wrote five
# cells at once.  Correctness is worth more here than the memory.
#
# The derived cells are NOT stored: they are recomputed from the restored
# data, so an undo can never bring back a derived value that no longer
# follows from its inputs.
#------------------------------------------------------------------------------
my (@undo, @redo);
my $UNDO_DEPTH = 200;

sub snapshot {
    return dclone({ doc => \%doc, project => \%project,
                    units => \%units, opts => \%opts });
}

sub push_undo {
    push @undo, snapshot();
    shift @undo while @undo > $UNDO_DEPTH;
    @redo = ();                 # a new edit invalidates anything undone
}

sub restore_snapshot {
    my $snap = shift;
    %doc     = %{ $snap->{doc} };
    %project = %{ $snap->{project} };
    %units   = %{ $snap->{units} };
    %opts    = %{ $snap->{opts} };
    $dirty   = 1;
    %derived_now = %{ network_derived() };
    refresh_grids();
    fit_columns($_) for grep { $_ ne 'PROJECT' } @INPUT;
    paint_derived();
    $_->update for grep { defined } values %grid;
    solve_now();
}

sub do_undo {
    return set_status('nothing to undo', $WARN) unless @undo;
    push @redo, snapshot();
    restore_snapshot(pop @undo);
    set_status(sprintf('undone - %d more step(s) available', scalar @undo), $GOOD);
}

sub do_redo {
    return set_status('nothing to redo', $WARN) unless @redo;
    push @undo, snapshot();
    restore_snapshot(pop @redo);
    set_status('redone', $GOOD);
}

sub grid_cell {
    # TableMatrix calls this as (SET_FLAG, row, col, value): 1 when the user
    # has committed an edit, 0 when it simply wants the text to draw.  It does
    # NOT pass a combined "row,col" index, which is what an earlier version
    # assumed -- and because Perl happily splits a bare integer on a comma,
    # the mistake showed up only as a stream of uninitialised-value warnings
    # rather than as an error.
    my ($block, $set, $r, $c, $value) = @_;
    my $cols = $SCHEMA{$block};

    return ($c == 0 ? '' : uc $cols->[ $c - 1 ]{h}) if $r == 0;
    return $r if $c == 0;

    # A spacer column holds no data: an edit there is discarded rather than
    # stored in a cell nothing will ever read back.
    return '' if $cols->[ $c - 1 ]{h} eq '';

    # A derived cell is a result.  Typing into one is refused rather than
    # stored, because a stored value would be overwritten on the next
    # recalculation anyway and the user would never know why.
    if ($set && $block eq 'NETWORK' && exists $derived_now{"$r,$c"}) {
        set_status('that cell is calculated, not entered', $WARN);
        return $derived_now{"$r,$c"};
    }

    if ($set) {
        my $old = ($doc{$block}[ $r - 1 ] || [])->[ $c - 1 ] // '';
        push_undo() if $old ne ($value // '');
    }
    if ($set) {                                 # the user typed something
        $doc{$block}[ $r - 1 ] ||= [];
        $doc{$block}[ $r - 1 ][ $c - 1 ] = $value;
        # Which cells are derived changes as the sheet is filled in -- entering
        # a K turns the pressure column from an input into a result -- and
        # which are invalid changes with every keystroke, so all of it is
        # rebuilt after every edit.
        after_edit($block);
        return $value;
    }
    # A derived cell shows the computed value, never whatever happens to be
    # sitting in the underlying array.
    if ($block eq 'NETWORK' && exists $derived_now{"$r,$c"}) {
        return $derived_now{"$r,$c"};
    }
    my $row = $doc{$block}[ $r - 1 ] or return '';
    return $row->[ $c - 1 ] // '';
}

# Always keep one blank row at the bottom.
#
# This is how a spreadsheet grows: you type on the last line and another
# appears.  The alternative -- an "add row" button -- costs a mouse trip
# between every row, which is the friction a grid exists to remove.
sub ensure_blank_row {
    my $block = shift;
    return if $block eq 'PROJECT';        # a fixed list of fields, not a list
                                          # of records: it never grows
    my $rows  = $doc{$block} ||= [];
    push @$rows, [ ('') x scalar @{ $SCHEMA{$block} } ]
        if !@$rows || row_has_content($rows->[-1]);
    if (my $t = $grid{$block}) { $t->configure(-rows => scalar(@$rows) + 1) }
    return scalar(@$rows) + 1;
}

# Size each column to what is actually in it.
#
# The schema widths are a starting guess; the data decides.  A column wide
# enough for "FIXEDFLOW" wastes nothing on a sheet where the widest entry is
# "PRV", and the saving is what lets twenty-one columns fit without scrolling.
# A minimum keeps a short heading legible; a maximum stops one long fitting
# string from pushing everything else off the edge.
sub fit_columns {
    my $block = shift;
    my $t = $grid{$block} or return;
    my $cols = $SCHEMA{$block} or return;
    for my $i (0 .. $#$cols) {
        my $need = length $cols->[$i]{h};
        my $rows = $doc{$block} || [];
        for my $ri (0 .. $#$rows) {
            # Measure what the cell will SHOW, which for a mirrored or
            # calculated cell is the derived value rather than whatever is in
            # the underlying array.
            my $v = ($block eq 'NETWORK'
                     && exists $derived_now{ ($ri + 1) . ',' . ($i + 1) })
                  ? $derived_now{ ($ri + 1) . ',' . ($i + 1) }
                  : $rows->[$ri][$i];
            $need = length $v if defined $v && length($v) > $need;
        }
        # Spacers stay narrow whatever is in them; they hold no data.
        my $w = $cols->[$i]{h} eq '' ? 2
              : $need < 4 ? 4
              : $need > 18 ? 18
              : $need + 1;
        $t->colWidth($i + 1, $w);
    }
}

sub refresh_grids {
    ensure_blank_row($_) for @INPUT;
    fit_columns($_) for grep { $_ ne 'PROJECT' } @INPUT;
    # Park the cursor on the first data cell of every sheet.
    #
    # Two reasons, both of which showed up on screen: left at its default the
    # active cell sits at 0,0 and TableMatrix draws an editor box across the
    # heading row, which reads as a corrupted header; and activating a cell
    # captures its contents into an edit buffer, so doing it before the data
    # is loaded leaves that one cell permanently blank.  After the load, both
    # problems go away.
    for my $sheet (@INPUT) {
        my $t = $grid{$sheet} or next;
        $t->activate($sheet eq 'PROJECT' ? '1,2' : '1,1');
    }
}

sub make_project_grid {
    my $parent = shift;
    my $rows = project_rows();
    my $sc = $parent->Scrolled('TableMatrix',
        -scrollbars => 'osoe',
        -rows => scalar(@$rows) + 1, -cols => 3,
        -titlerows => 1, -titlecols => 1,
        -variable => undef,
        -command => \&project_cell,
        -usecommand => 1,
        -state => 'normal',
        # The value column should use the whole sheet: a data source reference
        # is long, and truncating the one field that records provenance is the
        # worst possible thing to clip.
        -colstretchmode => 'last',
        -font => $MONO, -background => $SURFACE, -foreground => $INK,
        -highlightthickness => 0, -borderwidth => 0, -padx => 4, -pady => 2,
    )->pack(-fill => 'both', -expand => 1, -padx => $UNIT, -pady => $UNIT);
    my $t = $sc->Subwidget('scrolled');
    $t->colWidth(0, 5);
    $t->colWidth(1, 23);      # the longest label, AREA OF OPERATION  m2
    $t->colWidth(2, 40);
    $t->tagConfigure('title',  -bg => $HEADBG, -fg => $INK2, -font => $UI_B,
                     -anchor => 'w', -relief => 'flat');
    $t->tagConfigure('rownum', -bg => $HEADBG, -fg => $INK2, -font => $UI,
                     -anchor => 'e', -relief => 'flat');
    $t->tagConfigure('field',  -bg => $HEADBG, -fg => $INK2, -anchor => 'w');
    $t->tagConfigure('text',   -bg => $SURFACE, -fg => $INK, -anchor => 'w');
    $t->tagCol('field', 1);
    $t->tagCol('text', 2);
    $t->tagCol('rownum', 0);
    $t->tagRow('title', 0);
    $t->tagConfigure('band', -bg => $HEADBG, -fg => $INK2, -font => $UI_B,
                     -anchor => 'w', -relief => 'flat');
    my $prows = project_rows();
    for my $i (0 .. $#$prows) {
        $t->tagRow('band', $i + 1) if $prows->[$i][0] eq '#';
    }
    $grid{PROJECT} = $t;
    return $sc;
}

sub make_grid {
    my ($parent, $block) = @_;
    my $cols = $SCHEMA{$block};

    my $sc = $parent->Scrolled('TableMatrix',
        -scrollbars     => 'osoe',
        -rows           => 2,
        -cols           => scalar(@$cols) + 1,   # + the row-number column
        -titlerows      => 1,                    # frozen heading row
        -titlecols      => 1,                    # frozen row-number column
        -variable       => undef,
        -command        => sub { grid_cell($block, @_) },
        -usecommand     => 1,
        -state          => 'normal',
        -colstretchmode => 'none',   # keep the widths the schema asked for;
                                     # slack belongs at the right edge, not
                                     # poured into whichever column is last
        -rowstretchmode => 'none',
        -flashmode      => 0,
        -selectmode     => 'extended',
        -selecttype     => 'cell',
        -resizeborders  => 'col',
        -font           => $MONO,
        -background     => $SURFACE,
        -foreground     => $INK,
        # There is no -bordercolor: TableMatrix draws the gaps between cells
        # in its own -background, so the hairline colour is set that way.
        -highlightthickness => 0,
        -borderwidth    => 0,
        -padx           => 4,
        -pady           => 2,
    )->pack(-fill => 'both', -expand => 1, -padx => $UNIT, -pady => $UNIT);

    my $t = $sc->Subwidget('scrolled');

    # Widths come from the schema, in characters, so a column is as wide as the
    # data it holds and no wider.
    $t->colWidth(0, 5);
    $t->colWidth($_ + 1, $cols->[$_]{w}) for 0 .. $#$cols;

    # Tags do the styling.  Numeric columns are right-aligned so the decimal
    # points stack -- the single biggest difference between a schedule that can
    # be scanned and one that cannot.
    $t->tagConfigure('title',  -bg => $HEADBG, -fg => $INK2, -font => $UI_B,
                     -anchor => 'w', -relief => 'flat');
    $t->tagConfigure('rownum', -bg => $HEADBG, -fg => $INK2, -font => $UI,
                     -anchor => 'e', -relief => 'flat');
    $t->tagConfigure('num',    -anchor => 'e', -bg => $SURFACE, -fg => $INK);
    $t->tagConfigure('text',   -anchor => 'w', -bg => $SURFACE, -fg => $INK);
    # A cell with a problem.  Red is used for nothing else anywhere in the
    # program, so a red cell always means "this needs fixing".
    $t->tagConfigure('invalid',  -bg => $BADBG, -fg => $BAD, -relief => 'flat');
    $t->tagConfigure('warncell', -bg => '#FFF6E0', -fg => $WARN, -relief => 'flat');
    # A derived cell: tinted and dimmed, so it reads as a result at a glance
    # and never as something waiting to be filled in.
    $t->tagConfigure('derived', -bg => $READONLY, -fg => $INK2,
                     -anchor => 'e', -relief => 'flat');
    $t->tagConfigure('spacer',  -bg => $HEADBG, -relief => 'flat');
    $t->tagConfigure('active', -bg => $SELECT, -relief => 'flat');
    $t->tagConfigure('sel',    -bg => $SELECT);
    $t->tagConfigure('spacer', -bg => $HEADBG, -relief => 'flat')
        unless $block eq 'NETWORK';
    for my $i (0 .. $#$cols) {
        $t->tagCol($cols->[$i]{h} eq '' ? 'spacer'
                   : $cols->[$i]{num} ? 'num' : 'text', $i + 1);
    }
    $t->tagCol('rownum', 0);
    $t->tagRow('title', 0);

    # Tag PRIORITY, not tag assignment, decides what a cell looks like: every
    # column also carries a plain num/text tag, and a plain column tag that
    # outranks a cell's own tag makes a red cell look ordinary.  That is
    # exactly what happened -- the painter tagged three cells invalid and none
    # of them turned red.  The plain tags go to the bottom, so a cell's own
    # state always shows above its column's default.
    $t->tagLower($_) for qw(spacer text num);

    #--------------------------------------------------------------------------
    # KEYBOARD -- the part that decides whether the tool is quick.
    #
    #   Return / Tab   commit and step right, wrapping to the next row
    #   Shift+Tab      step back
    #   Ctrl+D         copy the cell above.  Most columns in a schedule repeat
    #                  down a run, and retyping them is where transcription
    #                  errors come from.
    #   Ctrl+Shift+D   copy the whole row above, INCREMENTING the id
    #--------------------------------------------------------------------------
    $t->bind('<Return>',      sub { move_cell($t, $block, 0, 1);  Tk->break });
    $t->bind('<Tab>',         sub { move_cell($t, $block, 0, 1);  Tk->break });
    $t->bind('<Shift-Tab>',   sub { move_cell($t, $block, 0, -1); Tk->break });
    $t->bind('<Control-d>',   sub { do_fill_down($t, $block);     Tk->break });
    $t->bind('<Control-c>',   sub { do_copy($t, $block);          Tk->break });
    $t->bind('<Control-x>',   sub { do_cut($t, $block);           Tk->break });
    $t->bind('<Control-v>',   sub { do_paste($t, $block);         Tk->break });
    # Delete clears a SELECTION of several cells; on a single cell it keeps
    # its normal in-cell meaning, so editing text still works as expected.
    # Ctrl+Delete, and Clear contents on the right-click menu, always clear.
    $t->bind('<Delete>', sub {
        my @sel = $t->curselection;
        if (@sel > 1) { do_clear($t, $block); Tk->break }
    });
    $t->bind('<Control-Delete>', sub { do_clear($t, $block);      Tk->break });
    $t->bind('<Control-plus>',   sub { do_insert_row($t, $block, 0); Tk->break });
    $t->bind('<Control-equal>',  sub { do_insert_row($t, $block, 0); Tk->break });
    $t->bind('<Control-minus>',  sub { do_delete_rows($t, $block);   Tk->break });
    context_menu($t, $block);
    $t->bind('<Control-D>',   sub { carry_down($t, $block, 1);    Tk->break });

    $grid{$block} = $t;
    return $sc;
}

# Move the active cell, wrapping off the right edge onto the next row and
# extending the sheet when the cursor runs off the bottom.
sub move_cell {
    my ($t, $block, $dr, $dc) = @_;
    my ($r, $c) = split /,/, $t->index('active');
    my $ncol = scalar @{ $SCHEMA{$block} };
    $r += $dr;
    $c += $dc;
    if ($c > $ncol) { $c = 1;     $r++ }
    if ($c < 1)     { $c = $ncol; $r-- }
    $r = 1 if $r < 1;
    ensure_blank_row($block);
    $t->activate("$r,$c");
    $t->see("$r,$c");
}

#------------------------------------------------------------------------------
# SPREADSHEET EDITING: clipboard, clear, fill down, insert and delete rows.
#
# Every operation here is ONE undo step however many cells it touches, and
# every one respects the same two rules as typing does: a spacer column holds
# nothing, and a calculated cell is never written.  A paste that lands on a
# calculated cell skips it and says so, rather than quietly storing a value the
# next recalculation would overwrite.
#
# The clipboard carries tab-separated text, which is what Excel reads and
# writes, so a block copies straight to and from a spreadsheet.  Cells are
# split on TABS ONLY: a fitting string such as "2E,1T" contains a comma and
# must arrive in one cell.
#------------------------------------------------------------------------------
sub is_input_cell {
    my ($block, $r, $c) = @_;
    my $col = $SCHEMA{$block}[ $c - 1 ] or return 0;
    return 0 if $col->{h} eq '';
    return 0 if $block eq 'NETWORK' && exists $derived_now{"$r,$c"};
    return 1;
}

# The selected rectangle, or the active cell when nothing is selected.
sub sel_rect {
    my ($t) = @_;
    my @cells = grep { my ($r, $c) = split /,/; $r >= 1 && $c >= 1 } $t->curselection;
    @cells = ($t->index('active')) unless @cells;
    my ($r0, $r1, $c0, $c1);
    for (@cells) {
        my ($r, $c) = split /,/;
        $r0 = $r if !defined $r0 || $r < $r0;  $r1 = $r if !defined $r1 || $r > $r1;
        $c0 = $c if !defined $c0 || $c < $c0;  $c1 = $c if !defined $c1 || $c > $c1;
    }
    $r0 = 1 if $r0 < 1;  $c0 = 1 if $c0 < 1;
    return ($r0, $r1, $c0, $c1);
}

sub set_cell {
    my ($block, $r, $c, $v) = @_;
    my $n = scalar @{ $SCHEMA{$block} };
    $doc{$block}[ $r - 1 ] ||= [ ('') x $n ];
    $doc{$block}[ $r - 1 ][ $c - 1 ] = $v;
}

# Reload the active cell after a bulk change: TableMatrix keeps the active
# cell's text in an edit buffer, and would otherwise go on showing -- and could
# later write back -- what was there before.
sub reload_active { my $t = shift; $t->reread }

sub do_copy {
    my ($t, $block) = @_;
    my ($r0, $r1, $c0, $c1) = sel_rect($t);
    my @lines;
    for my $r ($r0 .. $r1) {
        # what is SHOWN, calculated cells included: that is what was selected
        push @lines, join "\t", map { grid_cell($block, 0, $r, $_) // '' } $c0 .. $c1;
    }
    $mw->clipboardClear;
    $mw->clipboardAppend('--', join("\n", @lines) . "\n");
    set_status(sprintf('copied %d x %d cells', $r1 - $r0 + 1, $c1 - $c0 + 1), $GOOD);
}

sub do_clear {
    my ($t, $block, $quiet) = @_;
    my ($r0, $r1, $c0, $c1) = sel_rect($t);
    push_undo() unless $quiet;
    my $n = 0;
    for my $r ($r0 .. $r1) {
        for my $c ($c0 .. $c1) {
            next unless is_input_cell($block, $r, $c) && $doc{$block}[ $r - 1 ];
            $n++ if has($doc{$block}[ $r - 1 ][ $c - 1 ]);
            $doc{$block}[ $r - 1 ][ $c - 1 ] = '';
        }
    }
    after_edit($block);
    reload_active($t);
    set_status("cleared $n cell" . ($n == 1 ? '' : 's'), $GOOD) unless $quiet;
}

sub do_cut {
    my ($t, $block) = @_;
    do_copy($t, $block);
    push_undo();
    do_clear($t, $block, 1);
    set_status('cut to the clipboard', $GOOD);
}

sub do_paste {
    my ($t, $block) = @_;
    my $text = eval { $mw->SelectionGet(-selection => 'CLIPBOARD') };
    return set_status('nothing on the clipboard to paste', $WARN) unless defined $text && length $text;
    $text =~ s/\r\n?/\n/g;
    $text =~ s/\n\z//;
    my @rows = map { [ split /\t/, $_, -1 ] } split /\n/, $text, -1;
    my ($r0, undef, $c0) = sel_rect($t);
    my $ncol = scalar @{ $SCHEMA{$block} };
    push_undo();
    my ($put, $skipped, $cut_off) = (0, 0, 0);
    for my $i (0 .. $#rows) {
        for my $j (0 .. $#{ $rows[$i] }) {
            my ($r, $c) = ($r0 + $i, $c0 + $j);
            if ($c > $ncol) { $cut_off++; next }
            unless (is_input_cell($block, $r, $c)) {
                $skipped++ if has($rows[$i][$j]);
                next;
            }
            (my $v = $rows[$i][$j]) =~ s/^\s+|\s+$//g;
            set_cell($block, $r, $c, $v);
            $put++;
        }
    }
    after_edit($block);
    reload_active($t);
    my $msg = "pasted $put cell" . ($put == 1 ? '' : 's');
    $msg .= ", $skipped skipped (calculated or spacer cells are never written)" if $skipped;
    $msg .= ", $cut_off beyond the last column dropped" if $cut_off;
    set_status($msg, ($skipped || $cut_off) ? $WARN : $GOOD);
}

# Fill down: the top row of the selection is copied into every row below it,
# column by column -- Excel's Ctrl+D.  In the identifier column each row gets
# the NEXT id instead, because a copied id is a duplicate the solver rejects.
# With a single row selected it copies the row above, as before.
sub do_fill_down {
    my ($t, $block) = @_;
    my ($r0, $r1, $c0, $c1) = sel_rect($t);
    return carry_down($t, $block, 0) if $r0 == $r1;
    push_undo();
    my $n = 0;
    for my $c ($c0 .. $c1) {
        next unless is_input_cell($block, $r0, $c);
        my $v = ($doc{$block}[ $r0 - 1 ] || [])->[ $c - 1 ];
        next unless has($v);
        for my $r ($r0 + 1 .. $r1) {
            next unless is_input_cell($block, $r, $c);
            $v = next_id($v) if $c == 1;
            set_cell($block, $r, $c, $v);
            $n++;
        }
    }
    after_edit($block);
    reload_active($t);
    set_status("filled $n cell" . ($n == 1 ? '' : 's') . ' down', $GOOD);
}

sub do_insert_row {
    my ($t, $block, $below) = @_;
    my ($r0, $r1) = sel_rect($t);
    my $at = $below ? $r1 : $r0 - 1;              # 0-based insertion index
    push_undo();
    splice @{ $doc{$block} }, $at, 0, [ ('') x scalar @{ $SCHEMA{$block} } ];
    after_edit($block);
    $t->activate(($at + 1) . ',1');
    $t->see(($at + 1) . ',1');
    set_status('row inserted ' . ($below ? 'below' : 'above'), $GOOD);
}

sub do_delete_rows {
    my ($t, $block) = @_;
    my ($r0, $r1) = sel_rect($t);
    my $last = scalar @{ $doc{$block} || [] };
    $r1 = $last if $r1 > $last;
    return if $r1 < $r0;
    push_undo();
    splice @{ $doc{$block} }, $r0 - 1, $r1 - $r0 + 1;
    after_edit($block);
    $t->selectionClear('all');
    reload_active($t);
    my $n = $r1 - $r0 + 1;
    set_status("deleted $n row" . ($n == 1 ? '' : 's') . ' - Ctrl+Z brings them back', $GOOD);
}

# Right-click menu on a sheet.  A right-click outside the current selection
# moves the selection there first, as a spreadsheet does.
sub context_menu {
    my ($t, $block) = @_;
    my $m = $t->Menu(-tearoff => 0, -font => $UI);
    $m->command(-label => 'Cut',              -accelerator => 'Ctrl+X', -command => sub { do_cut($t, $block) });
    $m->command(-label => 'Copy',             -accelerator => 'Ctrl+C', -command => sub { do_copy($t, $block) });
    $m->command(-label => 'Paste',            -accelerator => 'Ctrl+V', -command => sub { do_paste($t, $block) });
    $m->command(-label => 'Clear contents',   -accelerator => 'Delete', -command => sub { do_clear($t, $block) });
    $m->separator;
    $m->command(-label => 'Fill down',        -accelerator => 'Ctrl+D', -command => sub { do_fill_down($t, $block) });
    $m->separator;
    $m->command(-label => 'Insert row above', -accelerator => 'Ctrl++', -command => sub { do_insert_row($t, $block, 0) });
    $m->command(-label => 'Insert row below',                           -command => sub { do_insert_row($t, $block, 1) });
    $m->command(-label => 'Delete row(s)',    -accelerator => 'Ctrl+-', -command => sub { do_delete_rows($t, $block) });
    # Posted on the button's RELEASE, not its press.  Posted on the press, the
    # release that follows a normal right-click closed the menu straight away:
    # it flashed and vanished.  There is no release left to close it this way,
    # and no chance of that release landing on the first entry and firing Cut.
    $t->bind('<ButtonRelease-3>', sub {
        my $ev = $t->XEvent or return;
        my $cell = $t->index('@' . $ev->x . ',' . $ev->y);
        my ($r, $c) = split /,/, $cell;
        if ($r >= 1 && $c >= 1 && !grep { $_ eq $cell } $t->curselection) {
            $t->selectionClear('all');
            $t->activate($cell);
            $t->selectionSet($cell);
        }
        $m->Popup(-popover => 'cursor', -popanchor => 'nw');
    });
}

# "P1" -> "P2", "BR3" -> "BR4", "P007" -> "P008".
#
# Carrying an identifier DOWN means the next one: copying it verbatim makes a
# duplicate the solver rejects, which is never what anyone wanted.  A name with
# no trailing number is left alone rather than guessed at.
sub next_id {
    my $id = shift // '';
    return $id unless $id =~ /^(.*?)(\d+)$/;
    return $1 . sprintf('%0*d', length($2), $2 + 1);
}

sub carry_down {
    my ($t, $block, $whole_row) = @_;
    my ($r, $c) = split /,/, $t->index('active');
    return if $r < 2;                       # nothing above the first data row
    push_undo();                            # a whole-row carry is ONE step
    my $above = $doc{$block}[ $r - 2 ] or return;
    my $ncol  = scalar @{ $SCHEMA{$block} };
    my ($lo, $hi) = $whole_row ? (1, $ncol) : ($c, $c);
    for my $i ($lo .. $hi) {
        my $v = $above->[ $i - 1 ];
        next unless defined $v && $v =~ /\S/;
        $v = next_id($v) if $i == 1;        # column 1 is always the identifier
        $doc{$block}[ $r - 1 ] ||= [];
        $doc{$block}[ $r - 1 ][ $i - 1 ] = $v;
    }
    $dirty = 1;
    ensure_blank_row($block);
    $t->activate($whole_row ? "$r,1" : "$r,$c");
    $t->update;
    schedule_solve();
}

#==============================================================================
# RESULT SHEETS
#
# Same grid widget, so the look and feel stay consistent, but tinted and
# read-only -- a computed cell must never be mistakable for one you can type in.
#==============================================================================
# The ELEMENTS sheet's columns are whatever the user has switched on, so they
# are rebuilt rather than looked up.
sub elem_cols {
    return [ map { [ $_->{h}, $_->{w}, $_->{num} ] }
             grep { $ELEM_ON{ $_->{id} } } @ELEM_COLS ];
}

sub result_cell {
    my ($sheet, $set, $r, $c, $value) = @_;
    return '' if $set;                # read-only: an edit is simply discarded
    my $cols = $sheet eq 'ELEMENTS' ? elem_cols() : $RCOLS{$sheet};
    return '' unless $cols && $c - 1 <= $#$cols;
    if ($r == 0) {
        return '' if $c == 0;
        my $h = uc $cols->[ $c - 1 ][0];
        # A small arrow marks the sorted column and its direction, so the
        # order on screen is never a mystery.
        $h .= $sort_desc ? ' v' : ' ^'
            if $sort_col ne '' && $cols->[ $c - 1 ][0] eq $sort_col;
        return $h;
    }
    return $r if $c == 0;
    my $row = $rdata{$sheet}[ $r - 1 ] or return '';
    return $row->[ $c - 1 ] // '';
}

sub make_result_grid {
    my ($parent, $sheet) = @_;
    my $cols = $sheet eq 'ELEMENTS' ? elem_cols() : $RCOLS{$sheet};
    my $sc = $parent->Scrolled('TableMatrix',
        -scrollbars => 'osoe',
        -rows => 2, -cols => scalar(@$cols) + 1,
        -titlerows => 1, -titlecols => 1,
        -variable => undef,
        -command => sub { result_cell($sheet, @_) },
        -usecommand => 1,
        # NOT 'disabled': a disabled TableMatrix receives no mouse events at
        # all, so the heading could never be clicked to sort.  Read-only is
        # enforced instead by result_cell discarding writes and by swallowing
        # keystrokes below -- the cells still cannot be changed, but the widget
        # can be interacted with.
        -state => 'normal',
        # NOT 'last': stretching the final column pours all the spare width
        # into it and leaves its figures marooned at the right-hand edge, a
        # hand's width from the column they belong beside.  Trailing space is
        # the lesser fault -- it is empty, and empty reads as empty.
        -colstretchmode => 'none',
        -font => $MONO, -background => $READONLY, -foreground => $INK,
        -highlightthickness => 0, -borderwidth => 0,
        -padx => 4, -pady => 2,
    )->pack(-fill => 'both', -expand => 1, -padx => $UNIT, -pady => $UNIT);

    my $t = $sc->Subwidget('scrolled');
    $t->colWidth(0, 5);
    $t->colWidth($_ + 1, $cols->[$_][1]) for 0 .. $#$cols;
    $t->tagConfigure('title',  -bg => $HEADBG, -fg => $INK2, -font => $UI_B,
                     -anchor => 'w', -relief => 'flat');
    $t->tagConfigure('rownum', -bg => $HEADBG, -fg => $INK2, -font => $UI,
                     -anchor => 'e', -relief => 'flat');
    $t->tagConfigure('num',    -anchor => 'e', -bg => $READONLY, -fg => $INK);
    $t->tagConfigure('text',   -anchor => 'w', -bg => $READONLY, -fg => $INK2);
    $t->tagCol($cols->[$_][2] ? 'num' : 'text', $_ + 1) for 0 .. $#$cols;
    $t->tagCol('rownum', 0);
    $t->tagRow('title', 0);

    # Click a heading to sort by it; click it again to reverse.
    # Typing into a results sheet does nothing, whichever key it was.
    $t->bind('<Key>', sub { Tk->break });
    $t->bind('<Return>', sub { Tk->break });

    if ($sheet eq 'ELEMENTS') {
        $t->bind('<ButtonRelease-1>', sub {
            # Perl/Tk exposes the event through the widget, not through a
            # global: $Tk::event is a Tcl idiom and is simply undef here, so
            # the binding fired and then silently did nothing.
            my $ev = $t->XEvent or return;
            my ($r, $c) = split /,/, $t->index('@' . $ev->x . ',' . $ev->y);
            return unless defined $r && $r == 0 && defined $c && $c > 0;
            my $cl = elem_cols();
            return unless $c - 1 <= $#$cl;
            my $name = $cl->[ $c - 1 ][0];
            $sort_desc = ($sort_col eq $name) ? !$sort_desc : 0;
            $sort_col  = $name;
            refresh_results();
        });
    }
    $rgrid{$sheet} = $t;
    return $sc;
}

sub refresh_results {
    %rdata = map { $_ => [] } @RESULT;

    if ($net) {
        my ($uf, $up, $ul) = @{$net}{qw(f_flow f_pres f_len)};

        # ELEMENTS -- every edge, in the order the model declared them.
        my %name = (PIPE=>'PIPE', PUMP=>'PUMP', SUPPLY_STATIC=>'STATIC',
                    SUPPLY_CURVE=>'CURVE', DISCHARGE=>'OUTLET',
                    FIXED_DROP=>'PRV', ORIFICE=>'ORIFICE',
                    ORIFICE_REQUIRED=>'ORIFICE_P', BFP=>'BFP');
        for my $ei (1 .. $#{ $net->{elems} }) {
            my $e = $net->{elems}[$ei];
            my $vel = $e->{kind} eq 'PIPE'
                    ? HardyCross::pipe_velocity($e->{q}, $e->{dia}) : undef;
            # Every quantity, computed once; the view then keeps whichever
            # columns are switched on.  Computing only the visible ones would
            # mean a different code path per view, which is how a column comes
            # to disagree with its neighbour.
            my ($hf) = HardyCross::elem_hf($e, $e->{q}, $net->{opts});
            my $pipe = $e->{kind} eq 'PIPE';
            my $ltot = $pipe ? $e->{len} + $e->{eqv} : undef;
            my $dz   = $net->{nodes}[ $e->{n2} ]{z} - $net->{nodes}[ $e->{n1} ]{z};
            my $pe   = $HardyCross::GAMMA_W * $dz;
            my $pv   = defined $vel ? 0.5 * $vel ** 2 : undef;
            my $nu   = $net->{opts}{nu} // 1.004e-6;
            my $re   = $pipe ? abs($vel) * ($e->{dia} / 1000) / $nu : undef;
            my $dw   = ($net->{opts}{method} // 'HW') eq 'DW';
            # The Darcy friction factor only exists under Darcy-Weisbach.  Under
            # Hazen-Williams there is no f, and inventing one from the loss
            # would be a number that looks like data and is not.
            my $fdw  = ($pipe && $dw) ? HardyCross::dw_friction($re, $e->{eps}, $e->{dia})
                                      : undef;
            my $n = sub { defined $_[0] ? sprintf('%.' . $_[1] . 'f', $_[0]) : '-' };

            my %v = (
                name => $e->{id},
                n1   => $net->{nodes}[ $e->{n1} ]{id},
                n2   => $net->{nodes}[ $e->{n2} ]{id},
                kind => $name{ $e->{kind} } // $e->{kind},
                # Nominal size and material come from the pipe standard, which
                # this engine does not carry: the file states a bore, not a DN.
                # Shown as "-" rather than guessed.
                nom  => '-',
                mat  => '-',
                id   => $pipe ? $n->($e->{dia}, 1) : '-',
                c    => $pipe ? ($dw ? $n->($e->{eps}, 3) : $n->($e->{c}, 0)) : '-',
                len  => $pipe ? $n->($e->{len} / $ul, 2) : '-',
                ftg  => $pipe ? $n->($e->{eqv} / $ul, 2) : '-',
                tot  => $pipe ? $n->($ltot / $ul, 2) : '-',
                # There is no per-pipe minor-loss constant in this engine; the
                # fitting allowance is an equivalent length instead.
                kfit => '-',
                q    => $n->($e->{q} / $uf, 1),
                # Friction loss applies to pipes; a device's drop is Ps.
                pf   => $pipe ? $n->($hf / $up, 2) : '-',
                pfx  => ($pipe && $ltot > $HardyCross::D_TINY)
                        ? $n->(abs($hf) / $ltot / $up * $ul, 4) : '-',
                pe   => $n->($pe / $up, 2),
                ps   => $pipe ? '-' : $n->($hf / $up, 2),
                pv   => $n->(defined $pv ? $pv / $up : undef, 2),
                vel  => $n->($vel, 2),
                re   => $pipe ? sprintf('%.3e', $re) : '-',
                f    => $n->($fdw, 5),
                form => $pipe ? ($dw ? 'DARCY' : 'HAZEN') : '-',
            );
            push @{ $rdata{ELEMENTS} },
                [ map { $v{ $_->{id} } } grep { $ELEM_ON{ $_->{id} } } @ELEM_COLS ];
        }

        # PRESSURES -- gauge pressure is total head less the elevation term,
        # which is why both columns are shown: they should differ by exactly
        # the elevation head, and a reviewer can check that by eye.
        for my $i (1 .. $#{ $net->{nodes} }) {
            my $n = $net->{nodes}[$i];
            next if $n->{id} eq 'REF';
            push @{ $rdata{PRESSURES} }, [
                $n->{id}, sprintf('%.2f', $n->{z} / $ul),
                sprintf('%.1f', ($n->{h} - $HardyCross::GAMMA_W * $n->{z}) / $up),
                sprintf('%.1f', $n->{h} / $up),
            ];
        }

        # LOOPS -- the loop set the method was applied to.  The report tells a
        # reviewer to check this FIRST, because every number downstream depends
        # on it being right.
        my $i = 0;
        for my $lp (@{ $net->{loops} }) {
            $i++;
            # A loop through the reference node is a PSEUDO-loop: a path between
            # two fixed-grade points closed via REF, rather than a ring of
            # pipework.  Both are corrected by the same equation, but a reviewer
            # should be able to tell them apart at a glance.
            my $pseudo = 0;
            for my $s (@$lp) {
                my $e = $net->{elems}[ $s->[0] ];
                $pseudo = 1 if $e->{n1} == $net->{iref} || $e->{n2} == $net->{iref};
            }
            push @{ $rdata{LOOPS} }, [
                ($pseudo ? "PL$i" : "L$i"), ($pseudo ? 'PSEUDO' : 'REAL'),
                scalar @$lp,
                join(',', map { ($_->[1] > 0 ? '+' : '-')
                                . $net->{elems}[ $_->[0] ]{id} } @$lp),
            ];
        }

        # CONVERGENCE -- thinned to about sixty rows.  The SHAPE of the curve is
        # the information; ten thousand samples of it are not.
        my $h = $net->{history} // [];
        my $step = int(@$h / 60) || 1;
        for my $j (0 .. $#$h) {
            next unless $j % $step == 0 || $j == $#$h;
            my ($it, $dq, $res) = @{ $h->[$j] };
            push @{ $rdata{CONVERGENCE} },
                [ $it, sprintf('%.3e', $dq / $uf), sprintf('%.3e', $res / $up) ];
        }
    }

    # Sort, if a heading has been clicked.  Numeric columns sort numerically:
    # sorting "1339.6" against "903.7" as text puts the larger first, which is
    # the sort of wrongness nobody questions because it looks ordered.
    if ($sort_col ne '') {
        my $cols = elem_cols();
        my ($i) = grep { $cols->[$_][0] eq $sort_col } 0 .. $#$cols;
        if (defined $i) {
            my $num = $cols->[$i][2];
            my @r = sort {
                my ($x, $y) = ($a->[$i] // '', $b->[$i] // '');
                # A dash is an absence, not a small value: it sorts last
                # whichever way round, and two of them are equal.  Letting a
                # pair of dashes fall through to the numeric comparison made
                # Perl warn on every single pass.
                return 0  if $x eq '-' && $y eq '-';
                return 1  if $x eq '-';
                return -1 if $y eq '-';
                $num ? ($x <=> $y) : (lc($x) cmp lc($y));
            } @{ $rdata{ELEMENTS} };
            @r = reverse @r if $sort_desc;
            $rdata{ELEMENTS} = \@r;
        }
    }

    for my $sheet (@RESULT) {
        my $t = $rgrid{$sheet} or next;
        $t->configure(-rows => scalar(@{ $rdata{$sheet} }) + 1);
        # Drop the cached cell text as well.  Changing the row count happens
        # to force a redraw, but a re-solve that leaves the SAME number of
        # rows -- the usual case while editing -- would otherwise be free to
        # leave old figures on screen.
        eval { $t->clearCache };
        $t->update;
    }
}

#==============================================================================
# VALIDATION
#
# Everything checkable is checked on every edit, and the findings go in a panel
# that is always on screen rather than behind a menu.  A warning you have to go
# looking for is a warning that gets found after the drawing is issued.
#
# Each finding is [severity, where, what].  Severity decides the colour and the
# sort order: errors first, because an error means the answer below is not an
# answer at all.
#==============================================================================
sub validate_model {
    my @f;
    my ($elev, $outlet, $order, $conflicts) = collect_nodes();

    # --- everything that belongs to one cell ------------------------------
    # From the same list that colours the sheet, each finding carrying the cell
    # it belongs to, so clicking it in the panel can go straight there.
    my %label = (NETWORK => 'network', OTHERNODES => 'other nodes', SUPPLIES => 'supplies',
                 PUMPS => 'pumps', DEVICES => 'devices');
    for my $x (@{ cell_problems() }) {
        my $col = uc $SCHEMA{ $x->{block} }[ $x->{c} - 1 ]{h};
        push @f, [ $x->{sev}, "$label{ $x->{block} } row $x->{r} $col", $x->{what},
                   [ $x->{block}, $x->{r}, $x->{c} ] ];
    }
    my %seen_pipe;
    my $rows = $doc{NETWORK} || [];
    for my $ri (0 .. $#$rows) {
        my $id = $rows->[$ri][0];
        next unless has($id);
        push @f, [ 'ERROR', "network row " . ($ri + 1) . " PIPE #", "duplicate pipe reference $id",
                   [ 'NETWORK', $ri + 1, 1 ] ] if $seen_pipe{$id}++;
    }

    # A node whose copies disagree.  collect_nodes has always detected this;
    # until now nothing showed it, which made a mistyped elevation effectively
    # invisible -- the first value silently won.
    push @f, [ 'ERROR', 'node', $_ ] for @$conflicts;

    # --- outlets (the two-of-K/Q/P rule is a cell finding, above) ----------
    for my $n (@$order) {
        my $o = $outlet->{$n} or next;
        push @f, [ 'WARN', "node $n", 'outlet has no elevation' ]
            unless defined $elev->{$n} && $elev->{$n} =~ /\S/;
    }

    # The design figures feed the density check on the cover sheet: a value
    # there that is not a number would silently switch the check off.
    for my $f ([ DENSITY => 'mm/min' ], [ AREA_PER_SPRINKLER => 'm2' ],
               [ AREA_OF_OPERATION => 'm2' ]) {
        my $v = $project{ $f->[0] };
        next unless defined $v && $v =~ /\S/;
        push @f, [ 'ERROR', 'project', "$f->[0] must be a number in $f->[1], not '$v'" ]
            unless $v =~ /^\s*[\d.]+\s*$/;
    }
    push @f, [ 'WARN', 'project', 'no design density and area per sprinkler: the density '
               . 'check on the cover sheet cannot be made' ]
        unless ($project{DENSITY} // '') =~ /\d/ && ($project{AREA_PER_SPRINKLER} // '') =~ /\d/;
    if (my $br = $project{BASE_OF_RISER}) {
        my ($elev) = collect_nodes();
        my %known = map { $_ => 1 } keys %$elev;
        $known{ $_->[0] } = 1 for grep { defined $_->[0] } @{ $doc{OTHERNODES} || [] };
        push @f, [ 'ERROR', 'project', "BASE_OF_RISER node '$br' is not in the model" ]
            unless $known{$br};
    }

    # --- things only the solved network knows ------------------------------
    if (!$net) {
        push @f, [ 'ERROR', 'model', 'the model does not solve - see the status line' ];
    } else {
        my ($uf, $up) = @{$net}{qw(f_flow f_pres)};
        push @f, [ 'ERROR', 'solver',
                   'did not converge: nothing in the results is usable' ]
            unless $net->{converged};

        for my $ei (1 .. $#{ $net->{elems} }) {
            my $e = $net->{elems}[$ei];
            if ($e->{kind} eq 'PIPE') {
                my $v = abs HardyCross::pipe_velocity($e->{q}, $e->{dia});
                # 6 m/s is a common sprinkler limit; it is NOT read from a
                # standard here, so it is a warning and says which figure it is.
                push @f, [ 'WARN', $e->{id},
                           sprintf('velocity %.2f m/s is over the %g m/s limit', $v,
                                   $net->{opts}{vel_limit} // 6) ]
                    if $v > ($net->{opts}{vel_limit} // 6);
            }
            push @f, [ 'ERROR', $e->{id}, 'reverse flow through a supply' ]
                if $e->{kind} =~ /^SUPPLY_/ && $e->{q} < -1e-6;
            push @f, [ 'ERROR', $e->{id}, 'reverse flow through a pump' ]
                if $e->{kind} eq 'PUMP' && $e->{q} < -1e-6;
            push @f, [ 'ERROR', $e->{id},
                       'reverse flow through a backflow preventer' ]
                if $e->{kind} eq 'BFP' && $e->{q} < -1e-6;

            next unless $e->{kind} eq 'DISCHARGE';
            my $q = abs $e->{q};
            my $p = $net->{nodes}[ $e->{n1} ]{h}
                  - $HardyCross::GAMMA_W * $e->{z};
            push @f, [ 'ERROR', $e->{id},
                sprintf('delivers %.1f at %.1f, needs %.1f at %.1f',
                        $q / $uf, $p / $up, $e->{qreq} / $uf, $e->{preq} / $up) ]
                if $q < $e->{qreq} - 1e-6 || $p < $e->{preq} - 1e-6;
        }
    }

    # Collapse repeats.  The same finding on ten pipes is ONE thing wrong with
    # the model, and printing it ten times buries whatever else is in the list
    # -- which is the opposite of what a validation panel is for.  The count
    # and the first few locations carry the same information in one line.
    my (%group, @order);
    for my $f (@f) {
        my ($sev, $where, $what, $ref) = @$f;
        my $key = "$sev\0$what";
        push @order, $key unless $group{$key};
        # the FIRST cell of a merged finding is where a click takes you
        $group{$key} ||= { sev => $sev, what => $what, where => [], ref => $ref };
        push @{ $group{$key}{where} }, $where;
    }

    my @out;
    for my $key (@order) {
        my $g = $group{$key};
        my @w = @{ $g->{where} };
        my $where = @w == 1 ? $w[0]
                  : @w <= 4 ? join(', ', @w)
                  : sprintf('%s and %d more', join(', ', @w[0 .. 2]), @w - 3);
        push @out, [ $g->{sev}, $where, $g->{what}, $g->{ref} ];
    }

    my %rank = (ERROR => 0, WARN => 1);
    return [ sort { $rank{ $a->[0] } <=> $rank{ $b->[0] } } @out ];
}

# Paint the validation panel.
sub refresh_validation {
    my $t = $validation or return;
    $t->configure(-state => 'normal');
    $t->delete('1.0', 'end');
    my $findings = validate_model();
    unless (@$findings) {
        $t->insert('end', "  NO PROBLEMS FOUND\n", 'ok');
    }
    my ($nerr, $nwarn) = (0, 0);
    my $i = 0;
    for my $f (@$findings) {
        my ($sev, $where, $what, $ref) = @$f;
        $sev eq 'ERROR' ? $nerr++ : $nwarn++;
        $i++;
        # A finding that belongs to a cell is a link: click it and the sheet
        # opens on that cell, selected.  On a long sheet, being told "row 143"
        # and having to scroll there is the friction this removes.
        my @tags = (lc $sev);
        if ($ref) {
            my $tag = "go$i";
            push @tags, $tag;
            my $sub = $t->can('Subwidget') && $t->Subwidget('scrolled') ? $t->Subwidget('scrolled') : $t;
            $sub->tagBind($tag, '<Button-1>', sub { jump_to(@$ref) });
            $sub->tagBind($tag, '<Enter>', sub { $sub->configure(-cursor => 'hand2') });
            $sub->tagBind($tag, '<Leave>', sub { $sub->configure(-cursor => 'xterm') });
        }
        $t->insert('end', sprintf("  %-7s %s%s\n", $sev, uc $where, $ref ? '  >' : ''), [@tags]);
        $t->insert('end', "$what\n", 'body');
    }
    $vcount->configure(-text => sprintf('  VALIDATION   %d ERRORS   %d WARNINGS',
                                              $nerr, $nwarn),
                             -foreground => $nerr ? $BAD : ($nwarn ? $WARN : $GOOD));
    $t->configure(-state => 'disabled');
}

# Go to a cell: raise its sheet, select it, scroll it into view.
sub jump_to {
    my ($block, $r, $c) = @_;
    my $t = $grid{$block} or return;
    $nb->raise(lc $block);
    $t->selectionClear('all');
    $t->activate("$r,$c");
    $t->selectionSet("$r,$c");
    $t->see("$r,$c");
    $t->focus;
}

# Rebuild the results grid after the column choice changes.  The widget's
# column count is fixed at creation, so it is destroyed and remade rather than
# reconfigured -- simpler, and it cannot leave a stale column behind.
sub rebuild_results_grid {
    my $holder = $results_holder or return;
    $_->destroy for $holder->children;      # drop the old grid entirely
    delete $rgrid{ELEMENTS};
    $resgrid = make_result_grid($holder, 'ELEMENTS');
    refresh_results();
}

#==============================================================================
# FILE HANDLING
#==============================================================================
sub do_open {
    my $f = $mw->getOpenFile(
        -filetypes => [ ['Hardy Cross model', '*.hcx'], ['All files', '*'] ]);
    return unless $f;
    open my $fh, '<', $f or do { set_status("cannot open $f", $BAD); return };
    # Slurp inside a do-block so the undefined $/ ends HERE and cannot reach
    # anything load_text calls -- the trap that once made the pipe database
    # read its whole data file as a single line.
    my $text = do { local $/; <$fh> };
    close $fh;
    $path = $f;
    load_text($text);
    $dirty = 0;
}

# Write the calculation report for the model as it stands on screen.
#
# It is produced from the SAME solved network the results pane is showing, so
# the printed report and the screen cannot disagree.  Refused outright if the
# model does not solve: a report of a model that failed would be a document
# with nothing true in it.
sub do_report {
    unless ($net) {
        set_status('cannot write a report - the model does not solve', $BAD);
        return;
    }
    my $default = defined $path ? ($path =~ s/\.hcx$//ir) . '_report.pdf' : 'report.pdf';
    my $f = $mw->getSaveFile(-filetypes => [ ['PDF report', '*.pdf'],
                                             ['Text report', '*.txt'] ],
                             -initialfile => ($default =~ s{.*/}{}r),
                             -defaultextension => '.txt');
    return unless $f;
    if ($f =~ /\.pdf$/i) {
        my $pages = eval { HardyCross::Report::write_pdf_report($net, $net->{converged},
                                                                 $path // 'unsaved model', $f) };
        return set_status("cannot write $f: $@", $BAD) unless $pages;
        set_status("PDF report written to $f, $pages pages", $GOOD);
        return;
    }
    open my $fh, '>', $f or do { set_status("cannot write $f", $BAD); return };
    print $fh HardyCross::Report::write_report($net, $net->{converged},
                                               $path // 'unsaved model');
    close $fh;
    set_status("report written to $f", $GOOD);
}

sub do_save {
    my $f = $path;
    unless ($f) {
        $f = $mw->getSaveFile(-filetypes => [ ['Hardy Cross model', '*.hcx'] ],
                              -defaultextension => '.hcx');
        return unless $f;
    }
    open my $fh, '>', $f or do { set_status("cannot write $f", $BAD); return };
    print $fh serialise();
    close $fh;
    $path  = $f;
    $dirty = 0;
    set_status("saved $f", $GOOD);
}

#==============================================================================
# THE WINDOW
#==============================================================================
$mw = MainWindow->new;
$mw->title('PHCP - PERL HYDRAULIC CALCULATION PROGRAM');
# Wide enough for the sheets, the results pane and the validation panel at
# once; the whole point of the layout is that none of the three is hidden.
$mw->geometry('1560x900');
$mw->configure(-background => $HEADBG);
$mw->optionAdd('*Font' => $UI);

my $menu = $mw->Menu(-type => 'menubar', -font => $UI_B);
$mw->configure(-menu => $menu);
my $fm = $menu->cascade(-label => 'FILE', -tearoff => 0);
$fm->command(-label => 'OPEN...', -accelerator => 'Ctrl+O', -command => \&do_open);
$fm->command(-label => 'SAVE',    -accelerator => 'Ctrl+S', -command => \&do_save);
$fm->command(-label => 'WRITE REPORT...', -accelerator => 'Ctrl+R', -command => \&do_report);
$fm->separator;
$fm->command(-label => 'QUIT', -command => sub { $mw->destroy });
# COLUMNS: one checkbutton per available result column.  Tearoff is on, so the
# list can be pulled off as a small floating palette and left open while
# working -- which is how it gets used when deciding what a report should show.
my $cm = $menu->cascade(-label => 'COLUMNS', -tearoff => 1);
for my $col (@ELEM_COLS) {
    if ($col->{fixed}) {
        # The pipe reference is always shown: a row of figures with nothing
        # identifying it is not a result.
        $cm->checkbutton(-label => uc($col->{h}), -state => 'disabled',
                         -variable => \$ELEM_ON{ $col->{id} });
        next;
    }
    $cm->checkbutton(
        -label    => uc($col->{h}),
        -variable => \$ELEM_ON{ $col->{id} },
        -command  => \&rebuild_results_grid,
    );
}

my $em = $menu->cascade(-label => 'EDIT', -tearoff => 0);
$em->command(-label => 'UNDO', -accelerator => 'Ctrl+Z', -command => \&do_undo);
$em->command(-label => 'REDO', -accelerator => 'Ctrl+Y', -command => \&do_redo);

my $mm = $menu->cascade(-label => 'MODEL', -tearoff => 0);
$mm->command(-label => 'RE-SOLVE', -accelerator => 'F5', -command => \&solve_now);

my $bar = $mw->Frame(-background => $HEADBG)
             ->pack(-side => 'top', -fill => 'x', -padx => $UNIT, -pady => $UNIT);
# Flat buttons: Tk's default raised bevel is heavy next to flat tables and
# hairline rules, and the toolbar is not the thing that should draw the eye.
for my $b ([ 'OPEN...', \&do_open ], [ 'SAVE', \&do_save ]) {
    $bar->Button(-text => $b->[0], -font => $UI_B, -command => $b->[1],
                 -relief => 'flat', -borderwidth => 1,
                 -background => $SURFACE, -activebackground => $SELECT,
                 -foreground => $INK, -padx => 12, -pady => 3,
                 -highlightthickness => 0)
        ->pack(-side => 'left', -padx => [ 0, $UNIT ]);
}
$summary = $bar->Label(-text => '', -font => $UI, -background => $HEADBG,
                       -foreground => $INK2, -anchor => 'w')
               ->pack(-side => 'left', -padx => $UNIT * 2);

$status = $mw->Label(-text => '  READY', -font => $UI_B, -anchor => 'w',
                     -background => $HEADBG, -foreground => $GOOD)
             ->pack(-side => 'bottom', -fill => 'x', -padx => $UNIT, -pady => $UNIT);

# The window is three regions, packed in this order so each keeps its space:
#   right   validation, always visible -- a warning behind a menu is a warning
#           found after the drawing is issued
#   bottom  results for the pipes, so a change and its effect are on screen
#           together and you never have to change tab to see what you did
#   centre  the sheets
my $body = $mw->Frame(-background => $HEADBG)
              ->pack(-fill => 'both', -expand => 1);

#--- bottom strip: results on the left, validation on the right ---------------
#
# Both were originally down the right-hand side, which cost the sheets 360 px
# of width and forced the NETWORK tab -- twenty-one columns -- to scroll
# sideways.  Scrolling across a schedule to see the node data that belongs to
# the pipe you are looking at defeats the point of putting them on one row.
# Stacking the two panes along the bottom instead gives the sheet the whole
# window width, and neither pane is hidden.
my $strip = $body->Frame(-background => $HEADBG, -height => 252)
                 ->pack(-side => 'bottom', -fill => 'x', -padx => $UNIT,
                        -pady => $UNIT);
$strip->packPropagate(0);

my $vframe = $strip->Frame(-background => $HEADBG, -width => 380)
                   # A list must be an array ref here: a bare (a, b) flattens into the option
              # list and Tk reports it as an option with no value.
              ->pack(-side => 'right', -fill => 'y', -padx => [ $UNIT, 0 ]);
$vframe->packPropagate(0);
$vcount = $vframe->Label(-text => '  VALIDATION', -font => $UI_B, -anchor => 'w',
                         -background => $HEADBG, -foreground => $INK2)
                 ->pack(-fill => 'x');
$validation = $vframe->Scrolled('Text',
    -scrollbars => 'oe', -wrap => 'word', -font => $UI, -width => 50,
    -background => $SURFACE, -foreground => $INK, -relief => 'flat',
    -highlightthickness => 0, -padx => 6, -pady => 4, -state => 'disabled',
)->pack(-fill => 'both', -expand => 1);
{
    my $t = $validation->Subwidget('scrolled');
    # Colour carries meaning only: red is an error, amber is over a limit,
    # green is the absence of both.
    $t->tagConfigure('error', -foreground => $BAD,  -font => $UI_B);
    $t->tagConfigure('warn',  -foreground => $WARN, -font => $UI_B);
    $t->tagConfigure('ok',    -foreground => $GOOD, -font => $UI_B);
    # lmargin2 governs the CONTINUATION lines of a wrapped paragraph; without
    # it a two-line finding wraps back to the left edge and stops looking like
    # it belongs to the heading above it.
    $t->tagConfigure('body', -foreground => $INK2,
                     -lmargin1 => 22, -lmargin2 => 22, -spacing3 => 4);
}

my $rframe = $strip->Frame(-background => $HEADBG)
                   ->pack(-side => 'left', -fill => 'both', -expand => 1);
$rframe->Label(-text => '  RESULTS', -font => $UI_B, -anchor => 'w',
               -background => $HEADBG, -foreground => $INK2)->pack(-fill => 'x');
# The grid lives in a holder of its own so changing the column set can throw
# the whole widget away and build a new one: TableMatrix fixes its column count
# at creation, and reconfiguring it leaves stale columns behind.
$results_holder = $rframe->Frame(-background => $HEADBG)
                         ->pack(-fill => 'both', -expand => 1);
$resgrid = make_result_grid($results_holder, 'ELEMENTS');

$nb = $body->NoteBook(-background => $HEADBG, -font => $UI_B,
                      -inactivebackground => $HEADBG)
           ->pack(-fill => 'both', -expand => 1, -padx => $UNIT);

for my $sheet (@INPUT) {
    my $page = $nb->add(lc $sheet,
        -label => ($sheet eq 'DEVICES'    ? 'PRESSURE DEVICES'
                 : $sheet eq 'OTHERNODES' ? 'OTHER NODES' : $sheet));
    if ($sheet eq 'PROJECT') { make_project_grid($page) }
    else                     { make_grid($page, $sheet) }
}
make_result_grid($nb->add(lc $_, -label => $_), $_) for @RESULT_TAB;

$mw->bind('<F5>'        => \&solve_now);
$mw->bind('<Control-o>' => \&do_open);
$mw->bind('<Control-s>' => \&do_save);
$mw->bind('<Control-r>' => \&do_report);
# Bound on every grid as well as the window: the table widget takes keyboard
# focus, and a binding on the toplevel alone never sees the keystroke.
for my $t (grep { defined } values %grid) {
    $t->bind('<Control-z>' => sub { do_undo(); Tk->break });
    $t->bind('<Control-y>' => sub { do_redo(); Tk->break });
}
$mw->bind('<Control-z>' => \&do_undo);
$mw->bind('<Control-y>' => \&do_redo);

# A starter model, so the grid is never an intimidating blank sheet.
my $STARTER = <<'HCX';
UNITS
  FLOW LPM
  PRESSURE KPA
  LENGTH M
  DIAMETER MM
END
OPTIONS
  METHOD HW
END
NODES
  A 0.0
  B 3.0
END
PIPES
  P1 A B 25 100 120
END
SUPPLIES
  SUP1 A STATIC 900
END
DISCHARGES
  S1 B SPRINKLER K=80 P=50
END
HCX

# --tab NAME opens on a given sheet.  Useful for scripting, and it removes any
# dependence on screen coordinates when capturing a particular sheet -- which
# is how a mis-scaled click once made a working sort look broken.
my $open_tab;
for my $i (0 .. $#ARGV - 1) {
    if ($ARGV[$i] eq '--tab') { $open_tab = lc $ARGV[ $i + 1 ]; splice @ARGV, $i, 2; last }
}

if (@ARGV && -r $ARGV[0]) {
    open my $fh, '<', $ARGV[0] or die "cannot open $ARGV[0]: $!\n";
    local $/;
    my $text = <$fh>;
    close $fh;
    $path = $ARGV[0];
    load_text($text);
} else {
    load_text($STARTER);
}
$dirty = 0;

# NoteBook has no 'exists' query; it lists its pages.  An unknown sheet name
# is simply ignored rather than stopping the program from starting.
$nb->raise($open_tab)
    if defined $open_tab && grep { $_ eq $open_tab } $nb->info('pages');
MainLoop;
