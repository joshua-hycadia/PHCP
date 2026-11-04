#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
# Sheet.pm -- the spreadsheet model behind phcp_sheet.pl.
#
# A second window on the same engine.  The text editor (phcp_editor.pl,
# HardyCross::Editor) is not used by this module and is not changed by it.
# What is here is the grid: pipes, the nodes taken from those pipes, the
# supplies and the pressure devices.  It reads and writes .phc by calling
# the reader and the editor's document functions, so a file saved from the
# sheet is a file phcp.pl and the text editor already understand.  Nothing
# here solves, sizes or checks hydraulics; HardyCross::Phc and
# HardyCross::Editor do.
#
# Perl 5, the same language as the rest of PHCP.  The defined-or operator
# (//) needs Perl 5.10, which the engine already requires.  No signatures
# and no try/catch, so the Perl 5.38 this tree is developed on and the
# Perl 5.42 the Windows build uses both run it.
#
# How a sheet is laid out:
#   pipes     one row of the SYSTEM grid, in the order the rows are shown
#   nodes     the values typed for a node, keyed by the node number.  A node
#             that drops out of the system keeps its values here, so typing
#             it again brings them back.  The NODES grid shows node_rows.
#   devices   one record per pressure device.  A device whose node type
#             asked for it is "tied": it is shown only while that node is
#             on the grid and still of that type.  A device read from a
#             file stays, even when its node is an outlet rather than the
#             device, because the file had the device in a pipe.
#   notes     comment lines, written back at the top of the network
#   extras    lines the grid does not edit (AREA, SUPPLYGRAPH, a line the
#             reader did not accept), written back after the grid
#
# The NODES grid does not invent nodes.  node_rows walks the pipes and
# lists each node number the first time it appears, FROM NODE then TO NODE.
# A node that a file defines and no pipe names is kept too, so opening a
# file cannot drop a supply that has not been piped yet.
#
# A blank node type is a node.  The word is not stored and not shown: the
# default does not have to be stated.  SPRINKLER, HYDRANT, HREEL and SUPPLY
# are the other node kinds.  PUMP, BP, BFP, PRV, OPP, OFD and PRA are
# pressure devices: choosing one adds a row to that device's table.

package HardyCross::Sheet;

use strict;
use warnings;
use HardyCross::Phc;
use HardyCross::Editor;
use HardyCross::Tools;

#------------------------------------------------------------------------------
# The node types.  The first is the default: a node, stored as a blank.
# 'A NODE' is the words the menu shows for that blank, not a value.
#------------------------------------------------------------------------------
our @TYPE_CHOICES = (
    [ '',         'A NODE' ],
    [ 'SPRINKLER','SPRINKLER' ],
    [ 'HYDRANT',  'HYDRANT' ],
    [ 'HREEL',    'HREEL' ],
    [ 'SUPPLY',   'SUPPLY' ],
    [ 'PUMP',     'PUMP' ],
    [ 'BP',       'BP' ],
    [ 'BFP',      'BFP' ],
    [ 'PRV',      'PRV' ],
    [ 'OPP',      'OPP' ],
    [ 'OFD',      'OFD' ],
    [ 'PRA',      'PRA' ],
);
our @DEVICE_TYPES = qw(PUMP BP BFP PRV OPP OFD PRA);
my %DEVICE = map { $_ => 1 } @DEVICE_TYPES;
my %OUTLET = (SPRINKLER => 1, HYDRANT => 1, HREEL => 1);

# How many flow/pressure pairs a supply or a device curve shows at least.
# One more than the pairs already typed is added on top, so the next point
# has a cell.  Example 02's backflow preventer has four pairs.
our $MIN_PAIRS = 4;

#------------------------------------------------------------------------------
# trim / normal_type -- a cell's text, and a node type brought to the words
# the sheet stores.  NODE, A NODE and ANODE are the default, so they become
# a blank: the type is not written down when it is only "a node".
#------------------------------------------------------------------------------
sub trim {
    my $v = shift // '';
    $v =~ s/^\s+|\s+\z//g;
    return $v;
}

sub normal_type {
    my $t = uc trim(shift);
    return '' if $t eq '' || $t eq 'NODE' || $t eq 'A NODE' || $t eq 'ANODE';
    return 'SUPPLY' if $t eq 'SUPPLY' || $t eq 'WATER';
    return 'HREEL'  if $t eq 'HREEL' || $t eq 'HOSEREEL' || $t eq 'HOSE REEL';
    return $t;
}

sub is_device { return $DEVICE{ normal_type(shift) } ? 1 : 0 }
sub is_outlet { return $OUTLET{ normal_type(shift) } ? 1 : 0 }

#------------------------------------------------------------------------------
# Empty records.  Every field is a string the grid can show, except pairs
# (a flat list of flow, pressure or flow, loss) and the flags.
#------------------------------------------------------------------------------
sub empty_pipe {
    return { pipe => '', from => '', to => '', length => '', type => '', c => '',
             diam => '', fittings => '', eqv => '', note => '', use_note => '' };
}

sub empty_node {
    return { type => '', elev => '', fixed_flow => '', fixed_name => '', fixed_min_p => '',
             min_flow => '', min_p => '', k => '', static => '', pairs => [],
             keep => 0, defined_in_file => 0, seq => 0, note => '' };
}

sub empty_device {
    my $type = shift;
    return { type => $type, node => '', tied => 0, name => '', pipe => '',
             in => '', out => '', churn => '', drop => '', bore => '', cd => '',
             ratio => '', min_inlet => '', band => '',
             duty_flow => '', duty_pressure => '', pairs => [], note => '' };
}

sub pipe_is_blank {
    my $p = shift or return 1;
    return !grep { length trim($p->{$_} // '') } qw(pipe from to length type c diam fittings eqv);
}

# new_sheet -- an empty sheet.  $settings is the PROJECT tab's hash when the
# window has one, so the fields and the file stay the same hash.
sub new_sheet {
    my $settings = shift // HardyCross::Editor::new_settings();
    return { settings => $settings, pipes => [], nodes => {}, devices => [],
             notes => [], extras => [], map => {}, at => {}, seq => 0,
             network => '', text => '' };
}

sub ensure_node {
    my ($sheet, $id) = @_;
    $id = trim($id);
    return unless length $id;
    return $sheet->{nodes}{$id} if $sheet->{nodes}{$id};
    my $n = empty_node();
    $n->{seq} = ++$sheet->{seq};
    $sheet->{nodes}{$id} = $n;
    return $n;
}

#==============================================================================
# Which rows the grids show.
#==============================================================================

# node_rows -- the node numbers, in the order the SYSTEM grid introduces
# them, then any node a file defined that no pipe names.
sub node_rows {
    my $sheet = shift;
    my (@ids, %seen);
    for my $p (@{ $sheet->{pipes} }) {
        next if pipe_is_blank($p);
        for my $end (qw(from to)) {
            my $id = trim($p->{$end} // '');
            next unless length $id;
            next if $seen{$id}++;
            ensure_node($sheet, $id);
            push @ids, $id;
        }
    }
    my @rest = sort { ($sheet->{nodes}{$a}{seq} || 0) <=> ($sheet->{nodes}{$b}{seq} || 0) }
               grep { !$seen{$_} && $sheet->{nodes}{$_}{keep} } keys %{ $sheet->{nodes} };
    push @ids, @rest;
    return @ids;
}

# supply_rows -- the nodes whose type is SUPPLY, in node_rows order.
sub supply_rows {
    my $sheet = shift;
    return grep { normal_type($sheet->{nodes}{$_}{type}) eq 'SUPPLY' } node_rows($sheet);
}

# device_rows -- the devices of one type that the PRESSURE DEVICES tab shows.
# A tied device is shown only while its node is on the grid and still of
# that type.  An untied device (one the file had, whose node is something
# else) is always shown.
sub device_rows {
    my ($sheet, $type) = @_;
    my %live = map { $_ => 1 } node_rows($sheet);
    return grep {
        $_->{type} eq $type && (
            !$_->{tied}
            || ($live{ $_->{node} // '' }
                && normal_type($sheet->{nodes}{ $_->{node} }{type}) eq $type)
        );
    } @{ $sheet->{devices} };
}

# pair_slots -- how many flow/pressure pairs to show.  At least MIN_PAIRS,
# and always one empty pair past the last one that has a number in it.
sub pair_slots {
    my ($sheet, $which) = @_;
    my $used = 0;
    my $count = sub {
        my $pairs = shift || [];
        my $n = 0;
        for my $i (0 .. $#$pairs) { $n = int($i / 2) + 1 if length trim($pairs->[$i] // '') }
        $used = $n if $n > $used;
    };
    if ($which eq 'SUPPLY') {
        $count->($sheet->{nodes}{$_}{pairs}) for supply_rows($sheet);
    } else {
        $count->($_->{pairs}) for device_rows($sheet, $which);
    }
    my $n = $used + 1;
    return $n < $MIN_PAIRS ? $MIN_PAIRS : $n;
}

# default_pipe -- the pipe a device at this node most likely sits in: the
# pipe that arrives there, else the pipe that leaves.
sub default_pipe {
    my ($sheet, $id) = @_;
    my ($to) = grep { trim($_->{to} // '') eq $id && length trim($_->{pipe} // '') } @{ $sheet->{pipes} };
    return trim($to->{pipe}) if $to;
    my ($from) = grep { trim($_->{from} // '') eq $id && length trim($_->{pipe} // '') } @{ $sheet->{pipes} };
    return $from ? trim($from->{pipe}) : '';
}

#------------------------------------------------------------------------------
# reconcile -- make the device list follow the node types.
#
# Choosing PRV on a node adds one PRV row, tied to that node, the first time.
# Choosing something else hides it (the record stays, so choosing PRV again
# brings the numbers back).  Called when a type changes and before the file
# is written, so a type cannot be saved without its device.
#------------------------------------------------------------------------------
sub reconcile {
    my $sheet = shift;
    for my $id (node_rows($sheet)) {
        my $n = $sheet->{nodes}{$id};
        my $t = normal_type($n->{type});
        $n->{type} = $t;
        next unless is_device($t);
        my ($d) = grep { ($_->{node} // '') eq $id && $_->{type} eq $t } @{ $sheet->{devices} };
        unless ($d) {
            $d = empty_device($t);
            $d->{node} = $id;
            if ($t eq 'PUMP') {
                $d->{name} = 'P-' . $id;
                $d->{out}  = $id;
            } else {
                $d->{pipe} = default_pipe($sheet, $id);
            }
            push @{ $sheet->{devices} }, $d;
        }
        $d->{tied} = 1;
    }
    return $sheet;
}

#==============================================================================
# The columns.  The window paints these; the tests read the same list, so a
# heading cannot drift away from the field the file is built from.
#
# C and EQV are the two columns the SYSTEM grid adds to the ones asked for.
# C is the figure on the USE line: a Hazen-Williams C, or under Darcy-Weisbach
# the roughness in the size unit.  Without it a bore pipe opened from a file
# would be written back as the reader's default (120, or the database's
# roughness) and a model that had stated another figure would change.
# EQV is an equivalent length added to the pipe, the EQV command.  The
# fitting string is the fittings; EQV is the extra length a file can carry.
#==============================================================================
sub _col {
    my ($key, $head, $width, $hint, %o) = @_;
    return { key => $key, head => $head, width => $width, hint => $hint, %o };
}

sub system_columns {
    my $sheet = shift;
    my $u = $sheet->{settings}{units};
    my $len = $u->{LENGTH} || 'MM';
    my $sz  = $u->{SIZE}   || 'MM';
    return (
        _col('pipe',     'PIPE',            12, 'THE PIPE NUMBER. EACH NUMBER IS USED ONCE.'),
        _col('from',     'FROM NODE',       12, 'THE NODE THE PIPE LEAVES. THE NODES TAB IS FILLED FROM THESE, AND FROM TO NODE.'),
        _col('to',       'TO NODE',         12, 'THE NODE THE PIPE ARRIVES AT.'),
        _col('length',   "LENGTH ($len)",   12, 'THE PIPE LENGTH, IN THE LENGTH UNIT SET IN THE PROJECT TAB.'),
        _col('type',     'PIPE TYPE',       12, 'A TYPE FROM THE DATABASE, OR BORE WHEN THE DIAMETER IS A BORE. BLANK INHERITS THE PREVIOUS ROW. CHOOSE IT FROM THE LIST.', kind => 'pipetype'),
        _col('c',        'C / ROUGHNESS',   14, 'THE USE FIGURE: HAZEN-WILLIAMS C, OR ROUGHNESS IN THE SIZE UNIT UNDER DARCY-WEISBACH. BLANK: THE DATABASE\'S, OR 120 FOR A BORE.'),
        _col('diam',     "PIPE DIAM ($sz)", 14, 'THE NOMINAL SIZE FOR THAT TYPE, IN THE SIZE UNIT. 0 ASKS FOR THE PIPE TO BE SIZED. A BORE IS TYPED, NOT CHOSEN.', kind => 'diam'),
        _col('fittings', 'FITTING STRING',  22, 'FITTINGS AFTER THE SIZE, ONE CODE EACH, A COUNT OPTIONAL: 2E T GV. G, C AND B ARE THE GATE, CHECK AND BUTTERFLY VALVES.'),
        _col('eqv',      "EQV ($len)",      10, 'AN EQUIVALENT LENGTH ADDED TO THE PIPE. THE FITTING STRING IS THE FITTINGS; THIS IS EXTRA.'),
    );
}

# pipe_type_choices -- the PIPE TYPE list: every type in the database, then
# BORE.  BORE means the diameter is a bore the user types, not a nominal size.
# The codes are the ones a USE line already accepts.
sub pipe_type_choices {
    return HardyCross::Tools::pipe_types();
}

# effective_type -- the pipe type a row is using.  A blank cell inherits the
# nearest row above that names one, the same way a USE line covers the pipes
# under it until the next USE.  The diameter list is that type's.
sub effective_type {
    my ($sheet, $r) = @_;
    return '' unless $sheet && defined $r;
    for (my $i = $r; $i >= 0; $i--) {
        my $p = $sheet->{pipes}[$i] or next;
        my $t = uc trim($p->{type} // '');
        return $t if length $t;
    }
    return '';
}

# diam_choices -- the PIPE DIAM list for a type, in the project's SIZE unit.
# 0 is first, because a size of 0 still asks for the pipe to be sized.
# An empty list means the diameter is typed: BORE, a blank with nothing
# above it to inherit, or a type the database does not know.  The text
# already in the cell is left as it is; this list does not replace it.
sub diam_choices {
    my ($sheet, $type) = @_;
    $type = uc trim($type // '');
    return () if $type eq '' || $type eq 'BORE';
    my @dn = HardyCross::Tools::sizes($type);
    return () unless @dn;
    my $unit = uc($sheet->{settings}{units}{SIZE} || 'MM');
    my @out = ('0');
    if ($unit eq 'IN') {
        # Nominal inches, not the millimetre DN.  A DN with no inch name is
        # left off the list: the cell would otherwise write a millimetre
        # figure into a file whose size unit is inches.
        my %inch = reverse HardyCross::Phc::inch_sizes();
        for my $dn (@dn) {
            next unless exists $inch{$dn};
            push @out, $inch{$dn};
        }
    } else {
        push @out, map { $_ + 0 } @dn;
    }
    return @out;
}

sub node_columns {
    my $sheet = shift;
    my $u = $sheet->{settings}{units};
    my ($el, $fl, $pr, $k) = map { $u->{$_} || '' } qw(ELEVATION FLOW PRESSURE KFACTOR);
    return (
        _col('node',       'NODE',              12, 'THE NODE NUMBER, TAKEN FROM THE SYSTEM TAB. IT IS NOT TYPED HERE.', ro => 1),
        _col('type',       'NODE TYPE',         14, 'BLANK IS A NODE, AND THE WORD IS NOT WRITTEN. CHOOSE SPRINKLER, HYDRANT, HREEL, SUPPLY, OR A PRESSURE DEVICE FROM THE LIST.', kind => 'type'),
        _col('elev',       "ELEVATION ($el)",   14, 'THE NODE\'S ELEVATION, IN THE ELEVATION UNIT.'),
        _col('fixed_flow', "FIXED FLOW ($fl)",  16, 'A FLOW THE NODE TAKES WHATEVER THE PRESSURE. BLANK: NONE.'),
        _col('min_flow',   "MIN FLOW ($fl)",    14, 'THE LEAST FLOW AN OUTLET MUST GIVE. FOR A NODE THAT IS NOT AN OUTLET, LEAVE IT BLANK.'),
        _col('min_p',      "MIN P ($pr)",       12, 'THE LEAST PRESSURE. FOR AN OUTLET THIS IS USED WHEN MIN FLOW IS BLANK. FOR A FIXED FLOW IT IS THE PRESSURE THE FLOW NEEDS.'),
        _col('k',          "K ($k)",            12, 'THE K-FACTOR OF A SPRINKLER, HYDRANT OR HOSE REEL. 0 TURNS THE OUTLET OFF AND LEAVES THE NODE.'),
    );
}

sub supply_columns {
    my $sheet = shift;
    my $u = $sheet->{settings}{units};
    my ($fl, $pr) = ($u->{FLOW} || 'LPM', $u->{PRESSURE} || 'KPA');
    my @c = (
        _col('node',   'NODE',            12, 'THE SUPPLY NODE. SET THE NODE\'S TYPE TO SUPPLY AND THE ROW APPEARS. ELEVATION IS ON THE NODES TAB.', ro => 1),
        _col('static', "STATIC ($pr)",    12, 'THE PRESSURE AT NO FLOW.'),
    );
    for my $i (1 .. pair_slots($sheet, 'SUPPLY')) {
        push @c, _col("q$i", "FLOW $i ($fl)",     12, 'A POINT ON THE SUPPLY CURVE: THE FLOW.');
        push @c, _col("p$i", "PRESSURE $i ($pr)", 14, 'THE PRESSURE AT THAT FLOW. THE CURVE STARTS AT THE STATIC PRESSURE AT NO FLOW.');
    }
    return @c;
}

# device_columns -- the columns that type needs, and no others.
#   PUMP   name, the node it draws from, the node it delivers to, churn
#          pressure, then flow/pressure points, and the duty it is checked at
#   BP     the pipe the booster sits in, then the same curve and duty
#   BFP    the pipe, then flow/loss points (one pair at flow 0 is a fixed loss)
#   PRV    the same columns as a backflow preventer
#   OPP    the pipe, the drop the plate is sized for, and an optional Cd
#   OFD    the pipe, the bore, and an optional Cd
#   PRA    the pipe, the ratio, the least inlet pressure, and the band
sub device_columns {
    my ($sheet, $type) = @_;
    my $u = $sheet->{settings}{units};
    my ($fl, $pr, $sz) = ($u->{FLOW} || 'LPM', $u->{PRESSURE} || 'KPA', $u->{SIZE} || 'MM');
    my $node = _col('node', 'NODE', 12, 'THE NODE WHOSE TYPE IS THIS DEVICE. CHOOSING THE TYPE ADDS THE ROW.', ro => 1);
    my $pipe = _col('pipe', 'PIPE', 12, 'THE PIPE THE DEVICE SITS IN. IT IS PLACED AT THAT PIPE\'S START.');
    my @c = ($node);
    if ($type eq 'PUMP') {
        push @c,
            _col('name',  'NAME',           12, 'THE PUMP\'S NAME. A NEW ROW IS NAMED P- AND THE NODE NUMBER.'),
            _col('in',    'IN',             12, 'THE NODE THE PUMP DRAWS FROM.'),
            _col('out',   'OUT',            12, 'THE NODE THE PUMP DELIVERS TO. A NEW ROW USES THE NODE WHOSE TYPE IS PUMP.'),
            _col('churn', "CHURN ($pr)",    12, 'THE PRESSURE AT NO FLOW.');
        for my $i (1 .. pair_slots($sheet, 'PUMP')) {
            push @c, _col("q$i", "FLOW $i ($fl)",     12, 'A POINT ON THE PUMP CURVE.');
            push @c, _col("p$i", "PRESSURE $i ($pr)", 14, 'THE PRESSURE AT THAT FLOW.');
        }
        push @c,
            _col('duty_flow', "DUTY FLOW ($fl)",  14, 'THE RATED FLOW, IF THE PUMP IS TO BE CHECKED AGAINST ITS CURVE. BLANK: NOT CHECKED.'),
            _col('duty_p',    "DUTY P ($pr)",     12, 'THE RATED PRESSURE AT THAT FLOW.');
    } elsif ($type eq 'BP') {
        push @c, $pipe, _col('churn', "CHURN ($pr)", 12, 'THE PRESSURE AT NO FLOW.');
        for my $i (1 .. pair_slots($sheet, 'BP')) {
            push @c, _col("q$i", "FLOW $i ($fl)",     12, 'A POINT ON THE BOOSTER CURVE.');
            push @c, _col("p$i", "PRESSURE $i ($pr)", 14, 'THE PRESSURE AT THAT FLOW.');
        }
        push @c,
            _col('duty_flow', "DUTY FLOW ($fl)", 14, 'THE RATED FLOW. THE DUTY NAMES THE PIPE. BLANK: NOT CHECKED.'),
            _col('duty_p',    "DUTY P ($pr)",    12, 'THE RATED PRESSURE AT THAT FLOW.');
    } elsif ($type eq 'BFP' || $type eq 'PRV') {
        my $what = $type eq 'BFP' ? 'BACKFLOW PREVENTER' : 'PRESSURE REDUCING VALVE';
        push @c, $pipe;
        for my $i (1 .. pair_slots($sheet, $type)) {
            push @c, _col("q$i", "FLOW $i ($fl)",  12, "A POINT ON THE $what LOSS CURVE. ONE PAIR AT FLOW 0 IS A LOSS THAT DOES NOT VARY.");
            push @c, _col("l$i", "LOSS $i ($pr)",  12, 'THE PRESSURE LOSS AT THAT FLOW.');
        }
    } elsif ($type eq 'OPP') {
        push @c, $pipe,
            _col('drop', "DROP ($pr)", 12, 'THE NET DROP THE PLATE IS SIZED TO GIVE.'),
            _col('cd',   'CD',          8, 'THE DISCHARGE COEFFICIENT. BLANK: 0.596.');
    } elsif ($type eq 'OFD') {
        push @c, $pipe,
            _col('bore', "BORE ($sz)", 12, 'THE PLATE\'S BORE. THE DROP IS CALCULATED.'),
            _col('cd',   'CD',          8, 'THE DISCHARGE COEFFICIENT. BLANK: 0.596.');
    } elsif ($type eq 'PRA') {
        push @c, $pipe,
            _col('ratio',     'RATIO',          10, 'THE PRESSURE RATIO, WRITTEN 3:1 OR 1.5. THE OUTLET IS THE INLET DIVIDED BY THE RATIO.'),
            _col('min_inlet', "MIN INLET ($pr)", 14, 'THE LEAST INLET PRESSURE THE VALVE IS RATED FOR. BLANK, OR 0: NO MINIMUM.'),
            _col('band',      'BAND (%)',       10, 'HOW FAR EITHER SIDE OF THE RATIO, AS A PERCENTAGE OF THE INLET. BLANK: 5.');
    }
    return @c;
}

#==============================================================================
# Reading a .phc file into the grids.
#==============================================================================

# code_and_note -- the line's code, and a // comment if it has one.
sub code_and_note {
    my $line = shift // '';
    $line =~ s/\r\z//;
    my $i = index $line, '//';
    return ($line, '') if $i < 0;
    my $note = substr($line, $i);
    my $code = substr($line, 0, $i);
    $code =~ s/\s+\z//;
    return ($code, $note);
}

# split_min -- an outlet's MINFLOW.  Below zero it is a minimum pressure,
# which the sheet keeps in MIN P so the two columns stay separate.
sub split_min {
    my $v = trim(shift // '');
    return ('', '') unless length $v;
    return ('', $1) if $v =~ /^\-(.+)\z/;
    return ($v, '');
}

# read_text -- a .phc text as a sheet.  Settings come out through the same
# split the text editor uses, so the PROJECT tab holds the same fields.
# Copies (PC, NC) are expanded into rows, because a grid has no copy
# command: each pipe and each node is its own row, with the source's values.
# A CHANGEPIPE is applied to that one row.  The commands are then the same
# network the reader would have built.
sub read_text {
    my $text = shift // '';
    my $doc = HardyCross::Editor::split_file($text);
    my $sheet = new_sheet($doc->{settings});
    my (%by, %change, %eqv, @nc, @fixed, %duty);
    my $use = { type => '', c => '', note => '' };

    for my $raw (split /\n/, $doc->{network}, -1) {
        $raw =~ s/\r\z//;
        next if $raw =~ /^\s*$/;
        if ($raw =~ /^\s*\/\//) { push @{ $sheet->{notes} }, $raw; next }
        my (undef, $note) = code_and_note($raw);
        my $a = HardyCross::Phc::analyse($raw);
        if ($a->{status} ne 'ok') { push @{ $sheet->{extras} }, $raw; next }
        my $spec = HardyCross::Phc::command_spec($a->{key});
        if ($spec && $spec->{kind} eq 'setting') { push @{ $sheet->{extras} }, $raw; next }
        my ($k, @p) = ($a->{key}, @{ $a->{pos} });

        if ($k eq 'USE') {
            $use = { type => $p[0], c => $a->{opt}[0] // '', note => $note };
        } elsif ($k eq 'PIPE') {
            my $p = empty_pipe();
            @$p{qw(pipe from to length diam)} = @p[0 .. 4];
            $p->{type} = $use->{type};
            $p->{c} = $use->{c};
            $p->{use_note} = $use->{note} // '';
            $use->{note} = '';
            $p->{fittings} = join ' ', @{ $a->{rest} };
            $p->{note} = $note;
            push @{ $sheet->{pipes} }, $p;
            $by{ $p->{pipe} } = $p;
        } elsif ($k eq 'PC') {
            my @r = @{ $a->{rest} };
            my $first = 1;
            while (my ($name, $s, $e) = splice @r, 0, 3) {
                my $p = empty_pipe();
                @$p{qw(pipe from to)} = ($name, $s, $e);
                $p->{copy_of} = $p[0];
                $p->{note} = $note if $first;
                $first = 0;
                push @{ $sheet->{pipes} }, $p;
                $by{$name} = $p;
            }
        } elsif ($k eq 'CHANGEPIPE') {
            $change{$p[0]} = { length => $p[1], diam => $p[2],
                               fittings => join(' ', @{ $a->{rest} }), raw => $raw };
        } elsif ($k eq 'EQV') {
            $eqv{$p[0]} = { eqv => $p[1], raw => $raw };
        } elsif ($k eq 'NODE') {
            my $n = ensure_node($sheet, $p[0]);
            $n->{elev} = $p[1];
            $n->{defined_in_file} = 1;
            $n->{note} = $note;
        } elsif ($k eq 'WATER') {
            my $n = ensure_node($sheet, $p[0]);
            $n->{type} = 'SUPPLY';
            $n->{elev} = $p[1];
            $n->{static} = $p[2];
            $n->{pairs} = [ @{ $a->{rest} } ];
            $n->{defined_in_file} = 1;
            $n->{note} = $note;
        } elsif ($OUTLET{$k}) {
            my $n = ensure_node($sheet, $p[0]);
            $n->{type} = $k;
            $n->{elev} = $p[1];
            ($n->{min_flow}, $n->{min_p}) = split_min($p[2]);
            $n->{k} = $p[3];
            $n->{defined_in_file} = 1;
            $n->{note} = $note;
        } elsif ($k eq 'NC') {
            push @nc, { source => $p[0], names => [ @{ $a->{rest} } ], raw => $raw, note => $note };
        } elsif ($k eq 'FIXEDFLOW') {
            push @fixed, { name => $p[0], node => $p[1], flow => $p[2],
                           minp => $a->{opt}[0] // '', raw => $raw };
        } elsif ($k eq 'PUMP') {
            my $d = empty_device('PUMP');
            @$d{qw(name in out churn)} = @p[0 .. 3];
            $d->{pairs} = [ @{ $a->{rest} } ];
            $d->{note} = $note;
            push @{ $sheet->{devices} }, $d;
        } elsif ($k eq 'PUMPDUTY') {
            $duty{$p[0]} = { q => $p[1], p => $p[2] };
        } elsif ($DEVICE{$k}) {
            my $d = empty_device($k);
            $d->{pipe} = $p[0];
            $d->{note} = $note;
            if ($k eq 'BP') {
                $d->{churn} = $p[1];
                $d->{pairs} = [ @{ $a->{rest} } ];
            } elsif ($k eq 'BFP' || $k eq 'PRV') {
                $d->{pairs} = [ @{ $a->{rest} } ];
            } elsif ($k eq 'OPP') {
                $d->{drop} = $p[1];
                $d->{cd} = $a->{opt}[0] // '';
            } elsif ($k eq 'OFD') {
                $d->{bore} = $p[1];
                $d->{cd} = $a->{opt}[0] // '';
            } elsif ($k eq 'PRA') {
                $d->{ratio} = $p[1];
                $d->{min_inlet} = $a->{opt}[0] // '';
                $d->{band} = $a->{opt}[1] // '';
            }
            push @{ $sheet->{devices} }, $d;
        } else {
            # AREA, SUPPLYGRAPH, and anything the grid has no column for.
            push @{ $sheet->{extras} }, $raw;
        }
    }

    _resolve_pipe_copies($sheet, \%by);
    for my $name (keys %change) {
        my $p = $by{$name};
        if ($p) { @$p{qw(length diam fittings)} = @{$change{$name}}{qw(length diam fittings)} }
        else    { push @{ $sheet->{extras} }, $change{$name}{raw} }
    }
    for my $name (keys %eqv) {
        my $p = $by{$name};
        if ($p) { $p->{eqv} = $eqv{$name}{eqv} }
        else    { push @{ $sheet->{extras} }, $eqv{$name}{raw} }
    }
    _resolve_node_copies($sheet, \@nc);
    for my $f (@fixed) {
        my $n = $sheet->{nodes}{ $f->{node} };
        if ($n && !length($n->{fixed_flow})) {
            $n->{fixed_name} = $f->{name};
            $n->{fixed_flow} = $f->{flow};
            # An outlet already uses MIN P for its own minimum.  The fixed
            # flow's minimum is kept beside it so neither is thrown away.
            if (is_outlet($n->{type})) { $n->{fixed_min_p} = $f->{minp} }
            else { $n->{min_p} = $f->{minp} unless length $n->{min_p}; $n->{fixed_min_p} = $f->{minp} }
        } else {
            push @{ $sheet->{extras} }, $f->{raw};
        }
    }
    for my $d (@{ $sheet->{devices} }) {
        my $key = $d->{type} eq 'PUMP' ? $d->{name} : $d->{type} eq 'BP' ? $d->{pipe} : '';
        next unless length $key && $duty{$key};
        $d->{duty_flow} = $duty{$key}{q};
        $d->{duty_p}    = $duty{$key}{p};
        delete $duty{$key};
    }
    # A duty that named nothing is kept, so the file does not lose it.
    push @{ $sheet->{extras} }, sprintf('%-9s %s %s %s', 'PUMPDUTY', $_, $duty{$_}{q}, $duty{$_}{p})
        for sort keys %duty;

    _tie_devices($sheet, \%by);
    _mark_keepers($sheet);
    reconcile($sheet);
    return $sheet;
}

# _resolve_pipe_copies -- a PC row takes its length, type, C, diameter and
# fittings from the source pipe.  A source may itself be a copy.  The
# equivalent length is not copied: EQV belongs to the pipe it names.
sub _resolve_pipe_copies {
    my ($sheet, $by) = @_;
    for my $p (@{ $sheet->{pipes} }) {
        next unless $p->{copy_of};
        my ($name, %seen) = ($p->{copy_of});
        my $src;
        while (length $name && !$seen{$name}++) {
            $src = $by->{$name} or last;
            last unless $src->{copy_of};
            $name = $src->{copy_of};
        }
        if ($src && !$src->{copy_of}) {
            @$p{qw(length type c diam fittings)} = @$src{qw(length type c diam fittings)};
        }
        delete $p->{copy_of};
    }
}

# _resolve_node_copies -- an NC name takes the source node's kind, elevation
# and outlet or supply figures.  A fixed flow is not part of the node, so
# it is not copied.  A copy may name another copy, and the lines may come
# in any order, so each pass resolves the ones whose source is already
# known and the rest wait.
sub _resolve_node_copies {
    my ($sheet, $nc) = @_;
    my @left = @$nc;
    my $guard = @left + 2;
    while (@left && $guard--) {
        my @still;
        for my $c (@left) {
            my $src = $sheet->{nodes}{ $c->{source} };
            if (!$src || !$src->{defined_in_file}) { push @still, $c; next }
            my $first = 1;
            for my $id (@{ $c->{names} }) {
                if ($sheet->{nodes}{$id} && $sheet->{nodes}{$id}{defined_in_file}) {
                    push @{ $sheet->{extras} }, $c->{raw} if $first;
                    $first = 0;
                    next;
                }
                my $n = ensure_node($sheet, $id);
                my $seq = $n->{seq};
                %$n = (%$src, pairs => [ @{ $src->{pairs} || [] } ], seq => $seq,
                       fixed_flow => '', fixed_name => '', fixed_min_p => '',
                       note => $first ? ($c->{note} // '') : '', defined_in_file => 1, keep => 0);
                $first = 0;
            }
        }
        last if @still == @left;
        @left = @still;
    }
    push @{ $sheet->{extras} }, $_->{raw} for @left;
}

# _tie_devices -- where a file's device can be shown as a node type.
# Only the node the pipe arrives at (the pump's delivery node).  If that
# node is still a plain node, its type becomes the device and the row is
# tied to it.  If it is already an outlet or a supply, the type stays and
# the device remains on its table untied: the file had both, and the
# junction upstream of the device is not relabelled as the device.
sub _tie_devices {
    my ($sheet, $by) = @_;
    for my $d (@{ $sheet->{devices} }) {
        my $id;
        if ($d->{type} eq 'PUMP') { $id = trim($d->{out} // '') }
        else {
            my $p = $by->{ $d->{pipe} // '' };
            $id = $p ? trim($p->{to} // '') : '';
        }
        next unless length $id && $sheet->{nodes}{$id};
        $d->{node} = $id;
        next if length normal_type($sheet->{nodes}{$id}{type});
        $sheet->{nodes}{$id}{type} = $d->{type};
        $d->{tied} = 1;
    }
}

# _mark_keepers -- a node a file defines, which no pipe names, stays on the
# NODES grid.  Without this a supply that only a pump names would vanish on
# save, and the pump would name a node the file no longer defines.
sub _mark_keepers {
    my $sheet = shift;
    my %end;
    for my $p (@{ $sheet->{pipes} }) {
        next if pipe_is_blank($p);
        $end{ trim($p->{$_} // '') } = 1 for qw(from to);
    }
    for my $id (keys %{ $sheet->{nodes} }) {
        $sheet->{nodes}{$id}{keep} = !$end{$id} && $sheet->{nodes}{$id}{defined_in_file} ? 1 : 0;
    }
}

#==============================================================================
# Writing the grids back to .phc.
#==============================================================================

# cmd -- one command line, in the editor's padding.  Empty fields at the end
# are left off, so a node with no elevation yet is "NODE N1", which the
# reader reports as incomplete rather than as a nought nobody typed.
sub cmd {
    my ($word, @f) = @_;
    pop @f while @f && !length(trim($f[-1] // ''));
    return sprintf('%-9s %s', $word, join(' ', map { trim($_) } @f));
}

# to_text -- the whole .phc file.  The map records, for each network line,
# the cell it came from, so a problem the reader reports can be shown there.
# reconcile runs first: a node type of PRV with no PRV row would save a
# type the file has no command for.
sub to_text {
    my $sheet = shift;
    reconcile($sheet);
    my @nodes = node_rows($sheet);
    my %nrow = map { $nodes[$_] => $_ } 0 .. $#nodes;
    my @sup  = supply_rows($sheet);
    my %srow = map { $sup[$_] => $_ } 0 .. $#sup;
    my @out;
    $sheet->{map} = {};
    $sheet->{at} = { node => {}, pipe => {} };
    my $add = sub {
        my ($text, $loc) = @_;
        push @out, $text;
        $sheet->{map}{ scalar @out } = $loc if $loc;
    };

    for my $note (@{ $sheet->{notes} }) { $add->($note) }
    $add->('') if @{ $sheet->{notes} } && @nodes;

    for my $id (@nodes) {
        my $n = $sheet->{nodes}{$id};
        my $t = normal_type($n->{type});
        my $row = $nrow{$id};
        my $loc = { tab => 'NODES', row => $row, col => 'elev', node => $id };
        my $line;
        if ($t eq 'SUPPLY') {
            $loc = { tab => 'SUPPLIES', row => $srow{$id}, col => 'static', node => $id };
            my @pairs = @{ $n->{pairs} || [] };
            pop @pairs while @pairs && !length trim($pairs[-1] // '');
            if (!length trim($n->{elev}))       { $line = cmd('WATER', $id) }
            elsif (!length trim($n->{static}))  { $line = cmd('WATER', $id, $n->{elev}) }
            else                                 { $line = cmd('WATER', $id, $n->{elev}, $n->{static}, @pairs) }
        } elsif (is_outlet($t)) {
            my $min = length(trim($n->{min_flow})) ? trim($n->{min_flow})
                    : length(trim($n->{min_p}))    ? '-' . trim($n->{min_p})
                    : '';
            $loc->{col} = length(trim($n->{min_flow})) ? 'min_flow'
                        : length(trim($n->{min_p}))    ? 'min_p'
                        : 'k';
            if (!length trim($n->{elev})) { $line = cmd($t, $id) }
            elsif (!length $min)          { $line = cmd($t, $id, $n->{elev}) }
            else                           { $line = cmd($t, $id, $n->{elev}, $min, $n->{k}) }
        } else {
            # A plain node, and a node that hosts a device: the device is
            # its own command.  The node still has an elevation.
            $line = length(trim($n->{elev})) ? cmd('NODE', $id, $n->{elev}) : cmd('NODE', $id);
        }
        $line .= ' ' . $n->{note} if length($n->{note} // '');
        $add->($line, $loc);
        $sheet->{at}{node}{$id} = scalar @out;

        next unless length trim($n->{fixed_flow});
        my $fname = length(trim($n->{fixed_name})) ? trim($n->{fixed_name}) : 'FF-' . $id;
        my $mp = is_outlet($t) ? $n->{fixed_min_p}
                               : (length(trim($n->{min_p})) ? $n->{min_p} : $n->{fixed_min_p});
        my @ff = ($fname, $id, trim($n->{fixed_flow}));
        push @ff, trim($mp) if length trim($mp // '');
        $add->(cmd('FIXEDFLOW', @ff), { tab => 'NODES', row => $row, col => 'fixed_flow', node => $id });
    }

    my $prev;
    for my $i (0 .. $#{ $sheet->{pipes} }) {
        my $p = $sheet->{pipes}[$i];
        next if pipe_is_blank($p);
        next unless length trim($p->{pipe});
        my $type = uc trim($p->{type});
        my $c = trim($p->{c});
        my $key = $type . "\0" . $c;
        if (length $type && (!defined $prev || $prev ne $key)) {
            my $line = length $c ? cmd('USE', $type, $c) : cmd('USE', $type);
            $line .= ' ' . $p->{use_note} if length($p->{use_note} // '');
            $add->($line, { tab => 'SYSTEM', row => $i, col => length($c) && $type eq uc(trim($p->{type})) ? 'c' : 'type', pipe => $i });
            $prev = $key;
        }
        my @fits = grep { length } split /\s+/, trim($p->{fittings});
        my $line = cmd('PIPE', trim($p->{pipe}), trim($p->{from}), trim($p->{to}),
                       trim($p->{length}), trim($p->{diam}), @fits);
        $line .= ' ' . $p->{note} if length($p->{note} // '');
        $add->($line, { tab => 'SYSTEM', row => $i, col => 'pipe', pipe => $i });
        $sheet->{at}{pipe}{$i} = scalar @out;
        $add->(cmd('EQV', trim($p->{pipe}), trim($p->{eqv})),
              { tab => 'SYSTEM', row => $i, col => 'eqv', pipe => $i })
            if length trim($p->{eqv});
    }

    for my $type (@DEVICE_TYPES) {
        my @rows = device_rows($sheet, $type);
        for my $i (0 .. $#rows) {
            my $d = $rows[$i];
            my $loc = { tab => 'PRESSURE DEVICES', device => $type, row => $i, col => 'pipe', node => $d->{node} };
            my $line = _device_line($d, $loc);
            $line .= ' ' . $d->{note} if length($d->{note} // '');
            $add->($line, $loc);
            my $duty_name = $type eq 'PUMP' ? ($d->{name} || ('P-' . ($d->{node} // '')))
                          : $type eq 'BP'   ? $d->{pipe}
                          : '';
            if (length $duty_name && (length(trim($d->{duty_flow})) || length(trim($d->{duty_p})))) {
                $add->(cmd('PUMPDUTY', $duty_name, $d->{duty_flow}, $d->{duty_p}),
                      { %$loc, col => 'duty_flow' });
            }
        }
    }

    $add->($_) for @{ $sheet->{extras} };
    my $network = join("\n", @out);
    $network .= "\n" if length $network && $network !~ /\n\z/;
    $sheet->{network} = $network;
    ($sheet->{text}) = HardyCross::Editor::join_file($sheet->{settings}, $network);
    return $sheet->{text};
}

# _device_line -- the .phc command for one device, and the cell a missing
# field should point at ($loc is updated).
sub _device_line {
    my ($d, $loc) = @_;
    my $type = $d->{type};
    my @pairs = @{ $d->{pairs} || [] };
    pop @pairs while @pairs && !length trim($pairs[-1] // '');
    if ($type eq 'PUMP') {
        my $name = length(trim($d->{name})) ? trim($d->{name}) : 'P-' . $d->{node};
        $loc->{col} = !length(trim($d->{in})) ? 'in' : !length(trim($d->{churn})) ? 'churn' : 'q1';
        return cmd('PUMP', $name, $d->{in}, $d->{out}, $d->{churn}, @pairs);
    }
    if ($type eq 'BP') {
        $loc->{col} = !length(trim($d->{pipe})) ? 'pipe' : 'churn';
        return cmd('BP', $d->{pipe}, $d->{churn}, @pairs);
    }
    if ($type eq 'BFP' || $type eq 'PRV') {
        $loc->{col} = !length(trim($d->{pipe})) ? 'pipe' : 'q1';
        return cmd($type, $d->{pipe}, @pairs);
    }
    if ($type eq 'OPP') {
        $loc->{col} = !length(trim($d->{pipe})) ? 'pipe' : 'drop';
        return length(trim($d->{cd})) ? cmd('OPP', $d->{pipe}, $d->{drop}, $d->{cd})
                                      : cmd('OPP', $d->{pipe}, $d->{drop});
    }
    if ($type eq 'OFD') {
        $loc->{col} = !length(trim($d->{pipe})) ? 'pipe' : 'bore';
        return length(trim($d->{cd})) ? cmd('OFD', $d->{pipe}, $d->{bore}, $d->{cd})
                                      : cmd('OFD', $d->{pipe}, $d->{bore});
    }
    if ($type eq 'PRA') {
        $loc->{col} = !length(trim($d->{pipe})) ? 'pipe' : 'ratio';
        # A band with no minimum is written as minimum 0: the reader treats
        # 0 as "no minimum", and an empty field would slide the band into it.
        my @f = ($d->{pipe}, $d->{ratio});
        if (length trim($d->{band})) {
            push @f, (length trim($d->{min_inlet}) ? trim($d->{min_inlet}) : '0'), trim($d->{band});
        } elsif (length trim($d->{min_inlet})) {
            push @f, trim($d->{min_inlet});
        }
        return cmd('PRA', @f);
    }
    return cmd($type);
}

#------------------------------------------------------------------------------
# problems -- what the grids can say that a generated line would only say
# sideways.  An outlet has one minimum in the file, so MIN FLOW and MIN P
# together would keep one and drop the other; that is reported here, on the
# cell, before the file is trusted.  K or MIN FLOW on a plain node has
# nowhere to go, and is reported for the same reason.
#------------------------------------------------------------------------------
sub problems {
    my $sheet = shift;
    my @it;
    my @ids = node_rows($sheet);
    my %row = map { $ids[$_] => $_ } 0 .. $#ids;
    for my $id (@ids) {
        my $n = $sheet->{nodes}{$id};
        my $t = normal_type($n->{type});
        my $loc = { tab => 'NODES', row => $row{$id}, col => 'type', node => $id };
        my $line = $sheet->{at}{node}{$id};
        if (is_outlet($t) && length(trim($n->{min_flow})) && length(trim($n->{min_p}))) {
            push @it, { what => "NODE $id: AN OUTLET TAKES MIN FLOW OR MIN P, NOT BOTH",
                        why  => 'THE FILE HAS ONE MINIMUM FOR AN OUTLET: A FLOW, OR, WRITTEN AS A NEGATIVE FLOW, A PRESSURE. '
                              . 'CLEAR ONE OF THE TWO CELLS.',
                        field => 'MIN P', line => $line, loc => { %$loc, col => 'min_p' } };
        } elsif (!is_outlet($t) && (length(trim($n->{min_flow})) || length(trim($n->{k})))) {
            my $col = length(trim($n->{k})) ? 'k' : 'min_flow';
            push @it, { what => "NODE $id: MIN FLOW AND K BELONG TO A SPRINKLER, HYDRANT OR HOSE REEL",
                        why  => 'THE NODE\'S TYPE IS BLANK, A SUPPLY OR A DEVICE, SO THOSE CELLS ARE NOT WRITTEN. '
                              . 'SET THE TYPE, OR CLEAR THEM.',
                        field => 'NODE TYPE', line => $line, loc => { %$loc, col => $col } };
        }
    }
    return @it;
}

# locate -- the cell a validation row points at.  The map knows the line;
# the message names the field when it is not the line's first one.
sub locate {
    my ($sheet, $item) = @_;
    return $item->{loc} if $item->{loc};
    return { tab => 'PROJECT', field => $item->{field} } if ($item->{tab} // '') eq 'PROJECT';
    my $line = $item->{line};
    return unless defined $line && $sheet->{map}{$line};
    my $loc = { %{ $sheet->{map}{$line} } };
    my $msg = uc($item->{what} // '');
    if ($loc->{node} && $msg =~ /ELEVATION/) {
        my @ids = node_rows($sheet);
        my %row = map { $ids[$_] => $_ } 0 .. $#ids;
        return { %$loc, tab => 'NODES', row => $row{ $loc->{node} }, col => 'elev' } if defined $row{ $loc->{node} };
    }
    if ($msg =~ /STATIC/ && $loc->{tab} && $loc->{tab} eq 'SUPPLIES') { $loc->{col} = 'static' }
    elsif ($msg =~ /MINFLOW/) { $loc->{col} = 'min_flow'; $loc->{tab} = 'NODES' if $loc->{node} }
    elsif ($msg =~ /FITTING/) { $loc->{col} = 'fittings' }
    elsif ($msg =~ /PIPE TYPE|UNKNOWN PIPE/) { $loc->{col} = 'type' }
    elsif ($msg =~ /\bLENGTH\b/) { $loc->{col} = 'length' }
    elsif ($msg =~ /\bSIZE\b|\bBORE\b/) { $loc->{col} = $loc->{tab} && $loc->{tab} eq 'PRESSURE DEVICES' ? 'bore' : 'diam' }
    return $loc;
}

1;
