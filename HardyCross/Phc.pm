#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
# Phc.pm -- the .phc command language.
#
# A .phc file is the model typed as short command lines, one element per line,
# fields by position, in any order:
#
#     UNITS     ELEVATION M
#     USE       S20 120
#     PIPE      4  2  101  7000  300  G T
#     NODE      101  31.5
#     WATER     2  31.5  1100  7570 1035
#     SPRINKLER 4101  47.076  81  8
#     FIXEDFLOW HOSE  2105  1900  250
#
# THIS MODULE TRANSLATES; IT DOES NOT RE-IMPLEMENT.  Every command becomes the
# rows that mean the same thing -- a section word (NODES, PIPES, SUPPLIES ...)
# and its tokens -- and each row is added to the network by
# HardyCross::Parse::parse_row, the network builder.  Every hydraulic check and
# default therefore lives in one place.  What is done HERE is what belongs to the language: the command words
# and their fields, numbers, units, that every node is defined once and every
# node used is defined, the copy and change commands, and devices placed in
# pipes.
#
# Units are the one thing converted here.  A .phc file chooses a unit for each
# quantity separately (pipe lengths in mm, elevations in m ...), and the
# network builder has a single length unit, so lengths and elevations are
# given to it in metres.  Flow and pressure factors come from the engine's own unit table
# (HardyCross::set_unit), so there is still one table of those.
#
# Every error carries the .phc line number it came from: each row keeps the
# line it was made from, and read_string below names that line.
#
# How the file is laid out:
#   vocabulary          commands, fields, units, fitting short forms
#   values              lengths with units, sizes, ratios, K-factor units
#   analyse             the syntax of one line
#   translate           a whole file to rows, each with its .phc line
#   pipe_row/device_row the rows for a pipe and for a device in a pipe
#   read_string/model   a .phc model read into a network
#   check_line etc.     the editor's checks of one line, without Tk

package HardyCross::Phc;

use strict;
use warnings;
use HardyCross;
use HardyCross::Parse;
use HardyCross::PipeData;

#==============================================================================
# The vocabulary.
#==============================================================================

# Solver options, as the network builder takes them (METHOD has its own
# command).  The builder silently ignores an unknown option name; in .phc it
# is an error, so a setting that does nothing cannot look as if it works.
our @OPTIONS = qw(HW_CONST NU TOL_FLOW TOL_LOOP MAXITER RELAX
                  VEL_LIMIT FITTING_BASIS ORIF_STEP);
my %OPTION = map { $_ => 1 } @OPTIONS;
my %NUM_OPTION = map { $_ => 1 } qw(HW_CONST NU TOL_FLOW TOL_LOOP MAXITER
                                    RELAX VEL_LIMIT ORIF_STEP);

#------------------------------------------------------------------------------
# Units.  One UNITS line per quantity; anything not set takes the office
# default.  Each quantity has the units it may be given in.
#------------------------------------------------------------------------------
our @UNIT_QUANTITIES = qw(LENGTH ELEVATION SIZE PRESSURE FLOW KFACTOR);
our %UNIT_CHOICES = (
    LENGTH    => [qw(MM CM M IN FT)],            # pipe and equivalent lengths
    ELEVATION => [qw(MM CM M IN FT)],
    SIZE      => [qw(MM IN)],                    # nominal sizes, bores, roughness
    PRESSURE  => [qw(KPA BAR MPA PSI M)],        # M: metres head of water
    FLOW      => [qw(LPM LPS M3H GPM)],
    KFACTOR   => [qw(LPM/KPA LPM/BAR LPS/KPA LPS/BAR GPM/PSI)],
);
# The office defaults (decided 28 October 2026).  The K-factor default is the
# unit the office's existing data is written in: K 8 for a K80 head.
our %UNIT_DEFAULT = (LENGTH => 'MM', ELEVATION => 'M', SIZE => 'MM',
                     PRESSURE => 'KPA', FLOW => 'LPM', KFACTOR => 'LPM/KPA');
# Other spellings a user may type for a unit.
my %UNIT_SPELLING = ('L/MIN' => 'LPM', 'L/S' => 'LPS', 'M3/H' => 'M3H',
                     USGPM => 'GPM', 'L/MIN/KPA' => 'LPM/KPA', 'L/MIN/BAR' => 'LPM/BAR');
# Lengths to metres.
my %TO_METRE = (MM => 0.001, CM => 0.01, M => 1, IN => 0.0254, FT => 0.3048);
# Nominal sizes in inches, to DN.
my %INCH_DN = ('0.5' => 15, '0.75' => 20, '1' => 25, '1.25' => 32, '1.5' => 40,
               '2' => 50, '2.5' => 65, '3' => 80, '3.5' => 90, '4' => 100,
               '5' => 125, '6' => 150, '8' => 200, '10' => 250, '12' => 300,
               '14' => 350, '16' => 400, '18' => 450, '20' => 500, '24' => 600);

#------------------------------------------------------------------------------
# Fitting short forms: single letters for the three valves typed most often,
# translated to database codes.  Every other fitting is written with its
# database code (E, T, EF, EL, E45, GV, CV, BV, AV, GLV ...).
#------------------------------------------------------------------------------
our %FIT_SHORT = (G => 'GV', C => 'CV', B => 'BV');

#------------------------------------------------------------------------------
# The commands.  For each:
#   kind   setting, use, pipe, node, element or device
#   fixed  the fields that must be given, each [label, type]
#   opt    fields that may follow, each [label, type]
#   rest   what may follow those: fittings, pairs, copies (PC), names (NC)
#   min    for pairs: how many at least
#   otype  for an outlet, the network builder's discharge type
# Field types:
#   text field         free text; a PROJECT field name
#   quantity unit      a UNITS quantity and its unit
#   method option value pipetype ratio
#   new                a new name (pipe, node, element)
#   node pipe          a node or pipe named elsewhere
#   length elev size   a length, an elevation, a nominal size or bore
#   pressure flow num  numbers; minflow: a flow, or below zero a pressure
#   kfactor
#------------------------------------------------------------------------------
my %CMD = (
    TITLE     => { kind => 'setting', fixed => [ [ 'TEXT', 'text' ] ] },
    PROJECT   => { kind => 'setting', fixed => [ [ 'FIELD', 'field' ], [ 'TEXT', 'text' ] ] },
    UNITS     => { kind => 'setting', fixed => [ [ 'QUANTITY', 'quantity' ], [ 'UNIT', 'unit' ] ] },
    METHOD    => { kind => 'setting', fixed => [ [ 'HW|DW', 'method' ] ] },
    OPTION    => { kind => 'setting', fixed => [ [ 'NAME', 'option' ], [ 'VALUE', 'value' ] ] },
    USE       => { kind => 'use', fixed => [ [ 'PIPETYPE', 'pipetype' ] ],
                   opt => [ [ 'C', 'num' ] ] },
    PIPE      => { kind => 'pipe', fixed => [ [ 'NAME', 'new' ], [ 'START', 'node' ], [ 'END', 'node' ],
                   [ 'LENGTH', 'length' ], [ 'SIZE', 'size' ] ], rest => 'fittings' },
    PC        => { kind => 'pipe', fixed => [ [ 'SOURCE', 'pipe' ] ], rest => 'copies' },
    CHANGEPIPE => { kind => 'pipe', fixed => [ [ 'PIPE', 'pipe' ], [ 'LENGTH', 'length' ],
                   [ 'SIZE', 'size' ] ], rest => 'fittings' },
    EQV       => { kind => 'pipe', fixed => [ [ 'PIPE', 'pipe' ], [ 'LENGTH', 'length' ] ] },
    NODE      => { kind => 'node', fixed => [ [ 'NAME', 'new' ], [ 'ELEVATION', 'elev' ] ] },
    NC        => { kind => 'node', fixed => [ [ 'SOURCE', 'node' ] ], rest => 'names' },
    WATER     => { kind => 'node', fixed => [ [ 'NAME', 'new' ], [ 'ELEVATION', 'elev' ],
                   [ 'STATIC', 'pressure' ] ], rest => 'pairs', min => 0 },
    SPRINKLER => { kind => 'node', otype => 'SPRINKLER', fixed => [ [ 'NAME', 'new' ],
                   [ 'ELEVATION', 'elev' ], [ 'MINFLOW', 'minflow' ], [ 'K', 'kfactor' ] ] },
    HYDRANT   => { kind => 'node', otype => 'HYDRANT', fixed => [ [ 'NAME', 'new' ],
                   [ 'ELEVATION', 'elev' ], [ 'MINFLOW', 'minflow' ], [ 'K', 'kfactor' ] ] },
    HREEL     => { kind => 'node', otype => 'HOSEREEL', fixed => [ [ 'NAME', 'new' ],
                   [ 'ELEVATION', 'elev' ], [ 'MINFLOW', 'minflow' ], [ 'K', 'kfactor' ] ] },
    FIXEDFLOW => { kind => 'element', fixed => [ [ 'NAME', 'new' ], [ 'NODE', 'node' ],
                   [ 'FLOW', 'flow' ] ], opt => [ [ 'MINPRESSURE', 'pressure' ] ] },
    PUMP      => { kind => 'element', fixed => [ [ 'NAME', 'new' ], [ 'IN', 'node' ], [ 'OUT', 'node' ],
                   [ 'CHURN', 'pressure' ] ], rest => 'pairs', min => 1 },
    BP        => { kind => 'device', fixed => [ [ 'PIPE', 'pipe' ], [ 'CHURN', 'pressure' ] ],
                   rest => 'pairs', min => 1 },
    BFP       => { kind => 'device', fixed => [ [ 'PIPE', 'pipe' ] ], rest => 'pairs', min => 1 },
    PRV       => { kind => 'device', fixed => [ [ 'PIPE', 'pipe' ] ], rest => 'pairs', min => 1 },
    OPP       => { kind => 'device', fixed => [ [ 'PIPE', 'pipe' ], [ 'DROP', 'pressure' ] ],
                   opt => [ [ 'CD', 'num' ] ] },
    OFD       => { kind => 'device', fixed => [ [ 'PIPE', 'pipe' ], [ 'BORE', 'size' ] ],
                   opt => [ [ 'CD', 'num' ] ] },
    PRA       => { kind => 'device', fixed => [ [ 'PIPE', 'pipe' ], [ 'RATIO', 'ratio' ] ],
                   opt => [ [ 'MININLET', 'pressure' ], [ 'BAND', 'num' ] ] },
);
$CMD{$_}{name} = $_ for keys %CMD;

# Short forms of the commonest commands.
my %ALIAS = (P => 'PIPE', U => 'USE', N => 'NODE', W => 'WATER', CHP => 'CHANGEPIPE');

# The commands in the order the command strip shows them, grouped.
our @COMMAND_GROUPS = (
    [qw(TITLE PROJECT UNITS METHOD OPTION)],
    [qw(USE PIPE PC CHANGEPIPE EQV)],
    [qw(NODE NC WATER SPRINKLER HYDRANT HREEL FIXEDFLOW)],
    [qw(PUMP BP BFP PRV OPP OFD PRA)],
);
our @COMMANDS = map { @$_ } @COMMAND_GROUPS;

# command_spec -- the table entry for a command word or alias, or undef.
sub command_spec {
    my $w = uc(shift // '');
    return $CMD{ $ALIAS{$w} // $w };
}

#------------------------------------------------------------------------------
# template_fields / template_text -- a command's fields as the status bar
# shows them: "PIPE <NAME> <START> <END> <LENGTH> <SIZE> [FITTINGS ...]".
#------------------------------------------------------------------------------
my %REST_LABEL = (fittings => 'FITTINGS ...', pairs => 'FLOW PRESSURE ...',
                  copies => 'NAME START END ...', names => 'NAME ...');
sub template_fields {
    my $c = shift;
    my @f = map { $_->[0] } @{ $c->{fixed} };
    push @f, map { $_->[0] } @{ $c->{opt} || [] };
    push @f, $REST_LABEL{ $c->{rest} } if $c->{rest};
    return @f;
}
sub template_text {
    my $c = command_spec(shift) or return '';
    my $nfix = @{ $c->{fixed} };
    my @f = template_fields($c);
    return join ' ', $c->{name}, map { $_ < $nfix ? "<$f[$_]>" : "[$f[$_]]" } 0 .. $#f;
}

#==============================================================================
# Values.
#==============================================================================

# length_metres -- a length or elevation token as metres, or undef if it is
# not one.  A plain number is in the quantity's unit; a number may carry its
# own: 12M, 300MM, 2.5CM, 6IN, 10FT, 14'3", 14'3, 6', 3".
sub length_metres {
    my ($t, $unit) = @_;
    return undef unless defined $t;
    return HardyCross::Parse::num($t) * $TO_METRE{$unit} if HardyCross::Parse::is_num($t);
    return $1 * $TO_METRE{ uc $2 } if $t =~ /^([-+]?(?:\d+\.?\d*|\.\d+))(MM|CM|M|IN|FT)\z/i;
    if ($t =~ /^([-+]?)(\d+(?:\.\d+)?)'(?:(\d+(?:\.\d+)?)"?)?\z/) {
        my $m = $2 * 0.3048 + ($3 // 0) * 0.0254;
        return $1 eq '-' ? -$m : $m;
    }
    return ($1 eq '-' ? -1 : 1) * $2 * 0.0254 if $t =~ /^([-+]?)(\d+(?:\.\d+)?)"\z/;
    return undef;
}

# size_dn -- a nominal size as a DN, or undef: millimetres rounded, or inches
# looked up (1.5 is DN40).
sub size_dn {
    my ($t, $unit) = @_;
    return undef unless HardyCross::Parse::is_num($t);
    return int($t + 0.5) if $unit eq 'MM';
    return $INCH_DN{ 0 + $t };
}

# size_mm -- a bore or roughness in the SIZE unit, as millimetres.
sub size_mm {
    my ($t, $unit) = @_;
    return undef unless HardyCross::Parse::is_num($t);
    return $unit eq 'MM' ? 0 + $t : $t * 25.4;
}

# ratio_value -- "3:1", "3:2" or a plain number, as the ratio; undef if none.
sub ratio_value {
    my $t = shift // '';
    return $1 / $2 if $t =~ /^(\d+(?:\.\d+)?):(\d+(?:\.\d+)?)\z/ && $2 > 0;
    return 0 + $t if HardyCross::Parse::is_num($t);
    return undef;
}

# unit_code -- a unit as typed, in its standard spelling.
sub unit_code { my $u = uc(shift // ''); return $UNIT_SPELLING{$u} // $u }

# unit_factor -- the engine's factor for a flow or pressure unit: what a value
# in that unit is multiplied by to give L/min or kPa.
sub unit_factor {
    my ($q, $u) = @_;
    my $net = HardyCross::Parse::new_net();
    HardyCross::set_unit($net, $q, $u);
    return $q eq 'FLOW' ? $net->{f_flow} : $net->{f_pres};
}

# k_factor_to_model -- a K given in the KFACTOR unit, as the K the network
# builder expects: the model's flow unit per square root of its pressure unit.
# K = Q / sqrt(P), so K scales as (flow factor) / sqrt(pressure factor).
sub k_factor_to_model {
    my ($k, $units) = @_;
    my ($kq, $kp) = split m{/}, $units->{KFACTOR};
    my $qf = unit_factor('FLOW', $kq) / unit_factor('FLOW', $units->{FLOW});
    my $pf = unit_factor('PRESSURE', $kp) / unit_factor('PRESSURE', $units->{PRESSURE});
    return $k * $qf / sqrt($pf);
}

# fmt -- a computed number for a row: ten significant figures, enough
# that the rounding never shows in a result.
sub fmt { sprintf '%.10g', shift }

#==============================================================================
# analyse -- the syntax of one .phc line.
#
# Returns a hash:
#   status    blank, ok, incomplete (fields still to be typed) or error
#   msg       why, for incomplete and error
#   key       the command (aliases resolved)
#   pos       the fixed fields, as typed (keywords upper-cased: units,
#             methods, option names, pipe types)
#   opt       the optional fields given
#   rest      the tokens after them (fittings, pairs, copies, names)
#   text      for TITLE and PROJECT, the raw text
#
# $partial is true while the line is being typed with the cursor at its end:
# a lone word that begins a command is then "incomplete", not "unknown".
#==============================================================================
sub strip_comment {
    my $l = shift // '';
    $l =~ s/\r?\n\z//;
    $l =~ s{//.*}{}s;
    return $l;
}

sub analyse {
    my ($raw, $partial) = @_;
    my $code = strip_comment($raw);
    my %a = (status => 'ok', pos => [], opt => [], rest => []);
    my $bad  = sub { %a = (%a, status => 'error',      msg => sprintf(shift, @_)); \%a };
    my $more = sub { %a = (%a, status => 'incomplete', msg => sprintf(shift, @_)); \%a };

    # '!' and '#' start a comment in the tokeniser this reader shares with the
    # network builder, so a line holding one would be cut short without a word.  They are refused.
    return $bad->("'%s' CANNOT BE USED IN A .PHC LINE; COMMENTS START WITH //", $1)
        if $code =~ /([!#])/;
    my @tk = HardyCross::Parse::tokenize($code);
    return { %a, status => 'blank' } unless @tk;

    my $word = uc $tk[0];
    my $c = command_spec($word);
    unless ($c) {
        if ($partial && @tk == 1 && $code !~ /\s\z/
            && grep { index($_, $word) == 0 } @COMMANDS) {
            return $more->('A COMMAND: %s', join(' ', @COMMANDS));
        }
        return $bad->('UNKNOWN COMMAND %s', uc $tk[0]);
    }
    $a{key} = $c->{name};

    #---------------------------------------------------------- TITLE, PROJECT
    # The value is the rest of the raw line, so a title keeps its spacing.
    if ($a{key} eq 'TITLE' || $a{key} eq 'PROJECT') {
        (my $t = $code) =~ s/^\s*\S+\s*//;
        if ($a{key} eq 'PROJECT') {
            return $more->('FIELD') unless @tk > 1;
            push @{ $a{pos} }, uc $tk[1];
            # END is a reserved word, never a name or a field.
            return $bad->('END CANNOT BE A PROJECT FIELD') if uc $tk[1] eq 'END';
            $t =~ s/^\S+\s*//;
        }
        $t =~ s/\s+\z//;
        return $more->('TEXT') unless length $t;
        $a{text} = $t;
        return \%a;
    }

    #---------------------------------------------------------- the fields
    my @f = @tk[1 .. $#tk];
    for (@f) {
        return $bad->("'%s': FIELDS GO BY POSITION - THERE ARE NO KEY=VALUE OPTIONS", $_) if /=/;
    }
    for my $fd (@{ $c->{fixed} }) {
        return $more->('%s', $fd->[0]) unless @f;
        my $err = check_field($fd->[1], shift(@f), \%a, $fd->[0]);
        return $bad->('%s', $err) if defined $err;
    }
    for my $fd (@{ $c->{opt} || [] }) {
        last unless @f;
        my $err = check_field($fd->[1], shift(@f), \%a, $fd->[0], 1);
        return $bad->('%s', $err) if defined $err;
    }
    $a{rest} = [@f];

    #---------------------------------------------------------- what follows
    my $rest = $c->{rest} // '';
    if ($rest eq 'fittings') {
        for (@f) {
            return $bad->("'%s' IS NOT A FITTING: A CODE WITH AN OPTIONAL COUNT, SUCH AS 2E", $_)
                unless /^\d*[A-Z][A-Z0-9]*\z/i;
        }
    } elsif ($rest eq 'pairs') {
        for (@f) {
            return $bad->("'%s' IS NOT A NUMBER", $_) unless HardyCross::Parse::is_num($_);
            return $bad->('FLOWS AND PRESSURES CANNOT BE NEGATIVE') if $_ < 0;
        }
        return $more->('THE PRESSURE TO PAIR WITH FLOW %s', $f[-1]) if @f % 2;
        return $more->('FLOW PRESSURE') if @f / 2 < ($c->{min} // 0);
    } elsif ($rest eq 'copies') {
        return $more->('NAME START END') unless @f;
        return $more->('%s', @f % 3 == 1 ? 'START END' : 'END') if @f % 3;
        for my $i (0 .. $#f) {
            my $err = check_field($i % 3 ? 'node' : 'new', $f[$i], {}, $i % 3 ? 'NODE' : 'NAME');
            return $bad->('%s', $err) if defined $err;
        }
    } elsif ($rest eq 'names') {
        return $more->('NAME') unless @f;
        for (@f) {
            my $err = check_field('new', $_, {}, 'NAME');
            return $bad->('%s', $err) if defined $err;
        }
    } elsif (@f) {
        return $bad->("UNEXPECTED FIELD '%s'", $f[0]);
    }
    return \%a;
}

#------------------------------------------------------------------------------
# check_field -- one field checked for its type.  The value (normalised where
# it is a keyword) is pushed onto pos, or opt for an optional field.  Returns
# an error message, or undef.  The checks are of the language only: a unit is
# known, a pipe type is in the database, a number is a number.
#------------------------------------------------------------------------------
sub check_field {
    my ($type, $v, $a, $label, $optional) = @_;
    my $push = sub { push @{ $a->{ $optional ? 'opt' : 'pos' } }, shift; undef };
    my $is_num = HardyCross::Parse::is_num($v);
    if ($type eq 'new' || $type eq 'node' || $type eq 'pipe') {
        return 'END CANNOT BE A NAME' if uc $v eq 'END';
        return "'~' IS RESERVED FOR NAMES PHCP MAKES ITSELF" if $type eq 'new' && $v =~ /~/;
        return $push->($v);
    }
    if ($type eq 'length' || $type eq 'elev') {
        my $m = length_metres($v, 'M');
        return "$label '$v' IS NOT A LENGTH" unless defined $m;
        return "$label CANNOT BE NEGATIVE" if $type eq 'length' && $m < 0;
        return $push->($v);
    }
    if ($type =~ /^(size|num|pressure|flow|kfactor|minflow)\z/) {
        return "$label '$v' IS NOT A NUMBER" unless $is_num;
        return "$label CANNOT BE NEGATIVE" if $v < 0 && $type ne 'minflow';
        return $push->($v);
    }
    if ($type eq 'ratio') {
        my $r = ratio_value($v);
        return "RATIO '$v' IS NOT A RATIO: WRITE IT 3:1 OR 1.5" unless defined $r;
        return 'A PRESSURE RATIO VALVE REDUCES PRESSURE: ITS RATIO MUST BE MORE THAN 1' if $r <= 1;
        return $push->($v);
    }
    return $push->(uc $v) if $type eq 'field';
    if ($type eq 'quantity') {
        my $q = uc $v;
        return "UNKNOWN UNITS QUANTITY $v (" . join(' ', @UNIT_QUANTITIES) . ')' unless $UNIT_CHOICES{$q};
        return $push->($q);
    }
    if ($type eq 'unit') {
        my $q = $a->{pos}[0];
        my $u = unit_code($v);
        return "UNKNOWN UNIT $v FOR $q (" . join(' ', @{ $UNIT_CHOICES{$q} }) . ')'
            unless grep { $_ eq $u } @{ $UNIT_CHOICES{$q} };
        return $push->($u);
    }
    if ($type eq 'method') {
        my $m = uc $v;
        $m = 'HW' if $m eq 'HAZEN';
        $m = 'DW' if $m eq 'DARCY';
        return 'METHOD IS HW (HAZEN-WILLIAMS) OR DW (DARCY-WEISBACH)' unless $m eq 'HW' || $m eq 'DW';
        return $push->($m);
    }
    if ($type eq 'option') {
        my $o = uc $v;
        return 'METHOD HAS A COMMAND OF ITS OWN: METHOD HW OR METHOD DW' if $o eq 'METHOD';
        return "UNKNOWN OPTION $v (" . join(' ', @OPTIONS) . ')' unless $OPTION{$o};
        return $push->($o);
    }
    if ($type eq 'value') {
        my $o = $a->{pos}[0];
        if ($NUM_OPTION{$o}) {
            return "$o VALUE '$v' IS NOT A NUMBER" unless $is_num;
            return $push->($v);
        }
        return $push->(uc $v);
    }
    if ($type eq 'pipetype') {
        my $p = uc $v;
        unless ($p eq 'BORE') {
            HardyCross::Parse::ensure_db();
            return "UNKNOWN PIPE TYPE $v (THE PIPE DATABASE LISTS "
                 . join(' ', HardyCross::PipeData::pipe_types()) . '; BORE FOR A PIPE GIVEN BY ITS BORE)'
                unless HardyCross::PipeData::pipe_type($p);
        }
        return $push->($p);
    }
    return $push->($v) if $type eq 'text';
    die "check_field: unknown type $type\n";     # a programming error
}

#------------------------------------------------------------------------------
# What a line names.
#------------------------------------------------------------------------------

# nodes_used -- the node names a line refers to (not those it defines).
sub nodes_used {
    my $a = shift;
    my $c = command_spec($a->{key} // '') or return;
    my @fixed = @{ $c->{fixed} };
    my @n = map { $a->{pos}[$_] } grep { $fixed[$_][1] eq 'node' } 0 .. $#fixed;
    # A PC copy names its start and end nodes.
    if ($a->{key} eq 'PC') {
        my @r = @{ $a->{rest} };
        push @n, map { @r[ $_ + 1, $_ + 2 ] } grep { $_ % 3 == 0 && $_ + 2 <= $#r } 0 .. $#r;
    }
    return grep { defined } @n;
}

# nodes_defined -- the node names a line defines.
sub nodes_defined {
    my $a = shift;
    my $k = $a->{key} // '';
    return @{ $a->{rest} } if $k eq 'NC';
    my $c = command_spec($k) or return;
    return $c->{kind} eq 'node' ? ($a->{pos}[0]) : ();
}

# names_defined -- the pipe and element names a line defines.
sub names_defined {
    my $a = shift;
    my $k = $a->{key} // '';
    return $a->{pos}[0] if $k eq 'PIPE' || $k eq 'FIXEDFLOW' || $k eq 'PUMP';
    if ($k eq 'PC') {
        my @r = @{ $a->{rest} };
        return map { $r[$_] } grep { $_ % 3 == 0 } 0 .. $#r;
    }
    return;
}

#------------------------------------------------------------------------------
# setting_keys -- the names of the settings a line sets, for the once-only
# rule.  Shared with the editor so the two cannot disagree.
#------------------------------------------------------------------------------
sub setting_keys {
    my $a = shift;
    my $k = $a->{key} // '';
    return 'TITLE'                 if $k eq 'TITLE';
    return "PROJECT $a->{pos}[0]"  if $k eq 'PROJECT';
    return "UNITS $a->{pos}[0]"    if $k eq 'UNITS';
    return 'METHOD'                if $k eq 'METHOD';
    return "OPTION $a->{pos}[0]"   if $k eq 'OPTION';
    return;
}

#==============================================================================
# translate -- .phc text to the rows the network is built from.
#
# Returns (rows, units).  Each row is [ section, text, line ]: which part of
# the network it builds (UNITS, OPTIONS, NODES, PIPES, PUMPS, SUPPLIES,
# DISCHARGES, DEVICES, or PROJECT for the cover sheet), the row's fields as
# HardyCross::Parse::parse_row takes them, and the .phc line it came from.
# Fails, naming the .phc line, on anything the language itself does not
# allow; parse_row then makes the hydraulic checks, and read_string names the
# .phc line for those too.
#==============================================================================
sub translate {
    my $text = shift // '';
    my @lines = split /\n/, $text, -1;
    my $at = sub { my $n = shift; HardyCross::fail("line %d: %s", $n, sprintf(shift, @_)) };

    #---------------------------------------------------- read every line
    my @rows;
    for my $n (1 .. @lines) {
        my $a = analyse($lines[ $n - 1 ]);
        next if $a->{status} eq 'blank';
        $at->($n, '%s NEEDS %s', $a->{key}, $a->{msg}) if $a->{status} eq 'incomplete';
        $at->($n, '%s', $a->{msg}) if $a->{status} ne 'ok';
        push @rows, [ $n, $a ];
    }
    my $kind = sub { command_spec($_[0]{key})->{kind} };

    #---------------------------------------------------- settings, file-wide
    # Each may be given once: a second is an error naming both lines, because
    # "the last one wins" in a file read in any order is a trap.
    my (%seen, @project, @options, $method);
    my %units = %UNIT_DEFAULT;
    for (grep { $kind->($_->[1]) eq 'setting' } @rows) {
        my ($n, $a) = @$_;
        for my $k (setting_keys($a)) {
            $at->($n, '%s IS ALREADY SET ON LINE %d', $k, $seen{$k}) if $seen{$k};
            $seen{$k} = $n;
        }
        my ($k, @p) = ($a->{key}, @{ $a->{pos} });
        push @project, [ "TITLE $a->{text}", $n ]  if $k eq 'TITLE';
        push @project, [ "$p[0] $a->{text}", $n ]  if $k eq 'PROJECT';
        $units{ $p[0] } = $p[1]                    if $k eq 'UNITS';
        $method = [ $p[0], $n ]                    if $k eq 'METHOD';
        push @options, [ "$p[0] $p[1]", $n ]       if $k eq 'OPTION';
    }
    my $dw = $method && $method->[0] eq 'DW';

    #---------------------------------------------------- definitions
    # Nodes, pipes and elements are collected first and written afterwards,
    # because a copy (PC, NC), a change (CHANGEPIPE, EQV) or a device may come
    # before or after the thing it refers to.
    my (%node, @node_order, %pipe, %name_line, %change, %eqv, %device, @items);
    my $use = { type => 'BORE' };
    my $define_node = sub {
        my ($name, $n, $def) = @_;
        $at->($n, 'NODE %s IS ALREADY DEFINED ON LINE %d', $name, $node{$name}{line}) if $node{$name};
        $node{$name} = { %$def, line => $n };
        push @node_order, $name;
    };
    my $define_name = sub {
        my ($name, $n) = @_;
        $at->($n, 'THE NAME %s IS ALREADY USED ON LINE %d', $name, $name_line{$name}) if $name_line{$name};
        $name_line{$name} = $n;
    };
    my $once = sub {
        my ($tbl, $name, $n, $what) = @_;
        $at->($n, 'PIPE %s ALREADY HAS %s, ON LINE %d', $name, $what, $tbl->{$name}{line})
            if $tbl->{$name};
    };
    for (grep { $kind->($_->[1]) ne 'setting' } @rows) {
        my ($n, $a) = @$_;
        my ($k, @p) = ($a->{key}, @{ $a->{pos} });
        if ($k eq 'USE') {
            $use = { type => $p[0], c => $a->{opt}[0], line => $n };
        } elsif ($k eq 'PIPE') {
            $define_name->($p[0], $n);
            $pipe{ $p[0] } = { line => $n, use => $use, start => $p[1], end => $p[2],
                               len => $p[3], size => $p[4], fits => [ @{ $a->{rest} } ] };
            push @items, [ 'PIPE', $p[0], $n ];
        } elsif ($k eq 'PC') {
            my @r = @{ $a->{rest} };
            while (my ($name, $s, $e) = splice @r, 0, 3) {
                $define_name->($name, $n);
                $pipe{$name} = { line => $n, copy_of => $p[0], start => $s, end => $e };
                push @items, [ 'PIPE', $name, $n ];
            }
        } elsif ($k eq 'CHANGEPIPE') {
            $once->(\%change, $p[0], $n, 'A CHANGEPIPE');
            $change{ $p[0] } = { line => $n, len => $p[1], size => $p[2], fits => [ @{ $a->{rest} } ] };
        } elsif ($k eq 'EQV') {
            $once->(\%eqv, $p[0], $n, 'AN EQV');
            $eqv{ $p[0] } = { line => $n, len => $p[1] };
        } elsif ($k eq 'NODE') {
            $define_node->($p[0], $n, { kind => 'NODE', z => $p[1] });
        } elsif ($k eq 'WATER') {
            $define_node->($p[0], $n, { kind => 'WATER', z => $p[1], static => $p[2],
                                        pairs => [ @{ $a->{rest} } ] });
            push @items, [ 'SUPPLY', $p[0], $n ];
        } elsif (command_spec($k)->{otype}) {
            $define_node->($p[0], $n, { kind => $k, z => $p[1], minflow => $p[2], k => $p[3] });
            push @items, [ 'OUTLET', $p[0], $n ];
        } elsif ($k eq 'NC') {
            # Copies are resolved below, once every definition is known; the
            # names are reserved now, so a clash is reported on this line.
            for my $name (@{ $a->{rest} }) {
                $define_node->($name, $n, { kind => 'COPY', source => $p[0] });
                push @items, [ 'COPY', $name, $n ];
            }
        } elsif ($k eq 'FIXEDFLOW' || $k eq 'PUMP') {
            $define_name->($p[0], $n);
            push @items, [ $k, $p[0], $n, $a ];
        } elsif (command_spec($k)->{kind} eq 'device') {
            $at->($n, 'PIPE %s ALREADY HAS A DEVICE, %s ON LINE %d', $p[0],
                  $device{ $p[0] }{key}, $device{ $p[0] }{line}) if $device{ $p[0] };
            $device{ $p[0] } = { line => $n, key => $k, a => $a };
            push @items, [ 'DEVICE', $p[0], $n ];
        }
    }

    #---------------------------------------------------- resolve copies
    # A PC copy takes everything but its nodes from its source pipe; an NC
    # copy takes everything from its source node.  A source may itself be a
    # copy; a chain that comes back on itself is an error.
    for my $name (grep { $pipe{$_}{copy_of} } keys %pipe) {
        my ($p, %trail) = ($pipe{$name});
        my $src = $p->{copy_of};
        while (1) {
            my $s = $pipe{$src} or $at->($p->{line}, 'PIPE %s, COPIED AS %s, IS NOT DEFINED', $src, $name);
            $at->($p->{line}, 'PIPE %s IS COPIED FROM ITSELF', $name) if $trail{$src}++;
            unless ($s->{copy_of}) { $p->{$_} = $s->{$_} for qw(use len size fits); last }
            $src = $s->{copy_of};
        }
    }
    for my $name (grep { $node{$_}{kind} eq 'COPY' } keys %node) {
        my ($c, %trail) = ($node{$name});
        my $src = $c->{source};
        while (1) {
            my $s = $node{$src} or $at->($c->{line}, 'NODE %s, COPIED AS %s, IS NOT DEFINED', $src, $name);
            $at->($c->{line}, 'NODE %s IS COPIED FROM ITSELF', $name) if $trail{$src}++;
            if ($s->{kind} ne 'COPY') { %$c = (%$s, line => $c->{line}); last }
            $src = $s->{source};
        }
    }
    # CHANGEPIPE applies after copying: a copy keeps its source's original.
    for my $pname (keys %change) {
        my $p = $pipe{$pname} or $at->($change{$pname}{line}, 'PIPE %s IS NOT DEFINED', $pname);
        $p->{$_} = $change{$pname}{$_} for qw(len size fits);
    }
    for my $tbl (\%eqv, \%device) {
        for my $pname (keys %$tbl) {
            $at->($tbl->{$pname}{line}, 'PIPE %s IS NOT DEFINED', $pname) unless $pipe{$pname};
        }
    }

    #---------------------------------------------------- every node defined
    # A node named by an element but defined nowhere is an error naming the
    # node and the first line that uses it.  (The network builder would create
    # it at elevation 0 without a word, so a mistyped name became a new node.)
    my (%first_use, @used);
    my $need = sub {
        my ($name, $n) = @_;
        return if $node{$name} || $first_use{$name};
        $first_use{$name} = $n;
        push @used, $name;
    };
    for my $it (@items) {
        my ($what, $name, $n, $a) = @$it;
        $need->($pipe{$name}{$_}, $n) for $what eq 'PIPE' ? qw(start end) : ();
        $need->($a->{pos}[1], $n) if $what eq 'FIXEDFLOW';
        $need->($a->{pos}[$_], $n) for $what eq 'PUMP' ? (1, 2) : ();
    }
    if (@used) {
        @used = sort { $first_use{$a} <=> $first_use{$b} } @used;
        my $id = shift @used;
        $at->($first_use{$id}, 'NODE %s IS NOT DEFINED%s', $id,
              @used ? ' (ALSO ' . join(', ', map { "$_ ON LINE $first_use{$_}" } @used) . ')' : '');
    }

    #---------------------------------------------------- the rows
    my (@nodes_out, @elems);
    my $z = sub { fmt(length_metres($node{ $_[0] }{z}, $units{ELEVATION})) };
    push @nodes_out, [ "$_ " . $z->($_), $node{$_}{line} ] for @node_order;
    # A device in a pipe splits the pipe at its start: the device runs from the
    # start node to a node "<pipe>~" at the same elevation, the pipe from there.
    for my $pname (sort { $device{$a}{line} <=> $device{$b}{line} } keys %device) {
        push @nodes_out, [ "$pname~ " . $z->($pipe{$pname}{start}), $device{$pname}{line} ];
    }
    for my $it (@items) {
        my ($what, $name, $n, $a) = @$it;
        my $d = $node{$name};
        if ($what eq 'PIPE') {
            push @elems, [ 'PIPES', pipe_row($pipe{$name}, $name, $device{$name} ? "$name~" : undef,
                                             $eqv{$name}, \%units, $dw, $at), $n ];
        } elsif (($what eq 'SUPPLY' || $what eq 'COPY') && $d->{kind} eq 'WATER') {
            # Static only: a supply at that pressure whatever the flow.  With
            # flow/pressure pairs: a curve starting at the static at no flow.
            my @pairs = @{ $d->{pairs} };
            push @elems, [ 'SUPPLIES', @pairs
                ? join(' ', $name, $name, 'CURVE', 0, $d->{static}, @pairs)
                : join(' ', $name, $name, 'STATIC', $d->{static}), $n ];
        } elsif (($what eq 'OUTLET' || $what eq 'COPY') && $CMD{ $d->{kind} }{otype}) {
            # A K of zero turns the outlet off: the node stays, discharging nothing.
            next if $d->{k} == 0;
            my $kk = fmt(k_factor_to_model($d->{k}, \%units));
            # MINFLOW is the least flow the outlet must give; below zero it is
            # the least PRESSURE instead.
            my $req = $d->{minflow} < 0 ? 'P=' . (-$d->{minflow}) : "Q=$d->{minflow}";
            push @elems, [ 'DISCHARGES', "$name $name $CMD{ $d->{kind} }{otype} K=$kk $req", $n ];
        } elsif ($what eq 'FIXEDFLOW') {
            my @p = @{ $a->{pos} };
            push @elems, [ 'DISCHARGES', join(' ', $p[0], $p[1], 'FIXEDFLOW', "Q=$p[2]",
                                              (@{ $a->{opt} } ? "MINP=$a->{opt}[0]" : ())), $n ];
        } elsif ($what eq 'PUMP') {
            my @p = @{ $a->{pos} };
            push @elems, [ 'PUMPS', join(' ', @p[0 .. 2], 0, $p[3], @{ $a->{rest} }), $n ];
        } elsif ($what eq 'DEVICE') {
            push @elems, [ device_row($device{$name}, $pipe{$name}, $name, \%units, $at) ];
        }
    }

    #---------------------------------------------------- in order
    # The rows in the order the network is built in: the cover sheet, the
    # units, the options, every node, then the elements as the file gives
    # them.  Lengths and elevations are written in metres and diameters in
    # mm; flow and pressure stay in the file's own units, which the network
    # builder converts.  Each row carries the .phc line it came from (undef
    # for one the reader adds itself).
    my @built = ((map { [ 'PROJECT', @$_ ] } @project),
                [ 'UNITS', "FLOW $units{FLOW}", $seen{'UNITS FLOW'} ],
                [ 'UNITS', "PRESSURE $units{PRESSURE}", $seen{'UNITS PRESSURE'} ],
                [ 'UNITS', 'LENGTH M', undef ], [ 'UNITS', 'DIAMETER MM', undef ],
                ($method ? [ 'OPTIONS', "METHOD $method->[0]", $method->[1] ] : ()),
                (map { [ 'OPTIONS', @$_ ] } @options),
                (map { [ 'NODES', @$_ ] } @nodes_out),
                @elems);
    return (\@built, \%units);
}

#------------------------------------------------------------------------------
# pipe_row -- the PIPES row for one pipe.
#
#   $p      { line, use, start, end, len, size, fits }
#   $from   the node the pipe starts at when a device takes its start, or undef
#   $eqv    { len } from an EQV line, or undef
#
# Under a pipe type the size is the nominal size, made a DN; under BORE it is
# the bore.  The USE line's figure is a Hazen-Williams C, or under METHOD DW
# an absolute roughness in the SIZE unit.  Fittings go to FIT=, joined by
# commas, short forms (G C B) made database codes.
#------------------------------------------------------------------------------
sub pipe_row {
    my ($p, $name, $from, $eqv, $units, $dw, $at) = @_;
    my $n = $p->{line};
    my $use = $p->{use} || { type => 'BORE' };
    my @row = ($name, $from // $p->{start}, $p->{end},
               fmt(length_metres($p->{len}, $units->{LENGTH})));
    if ($use->{type} eq 'BORE') {
        $at->($n, 'PIPE %s: FITTINGS NEED A PIPE TYPE - PUT A USE <PIPETYPE> LINE BEFORE IT, '
                . 'OR GIVE THE ALLOWANCE WITH EQV', $name) if @{ $p->{fits} };
        push @row, fmt(size_mm($p->{size}, $units->{SIZE}));
    } else {
        my $dn = size_dn($p->{size}, $units->{SIZE});
        $at->($n, 'PIPE %s: %s IS NOT A NOMINAL SIZE IN INCHES', $name, $p->{size}) unless defined $dn;
        push @row, $dn, "TYPE=$use->{type}";
        my @fit = map { fitting_code($_) } @{ $p->{fits} };
        push @row, 'FIT=' . join(',', @fit) if @fit;
    }
    push @row, $dw ? 'EPS=' . fmt(size_mm($use->{c}, $units->{SIZE})) : "C=$use->{c}"
        if defined $use->{c};
    push @row, 'EQV=' . fmt(length_metres($eqv->{len}, $units->{LENGTH})) if $eqv;
    return join ' ', @row;
}

# fitting_code -- one fitting token with its short form made a database code:
# "2G" is "2GV".  Anything else is left for the resolver to accept or refuse.
sub fitting_code {
    my ($count, $code) = uc(shift) =~ /^(\d*)([A-Z][A-Z0-9]*)\z/;
    return $count . ($FIT_SHORT{$code} // $code);
}

#------------------------------------------------------------------------------
# device_row -- (block, row, line) for a device in a pipe.
#
# The device runs from the pipe's start node to "<pipe>~".  Its id is the
# pipe's name and the device's: "51.BP".
#------------------------------------------------------------------------------
sub device_row {
    my ($d, $p, $pname, $units, $at) = @_;
    my ($k, $a, $n) = ($d->{key}, $d->{a}, $d->{line});
    my @r = @{ $a->{rest} };
    my ($s, $x, $id) = ($p->{start}, "$pname~", "$pname.$k");
    return ('PUMPS', join(' ', $id, $s, $x, 0, $a->{pos}[1], @r), $n) if $k eq 'BP';
    if ($k eq 'BFP' || $k eq 'PRV') {
        # A single pair at flow zero is a loss that does not vary with flow.
        if (@r == 2) {
            $at->($n, '%s WITH ONE FLOW/LOSS PAIR IS A FIXED LOSS: ITS FLOW MUST BE 0', $k) if $r[0] != 0;
            $at->($n, '%s: A FIXED LOSS MUST BE MORE THAN 0', $k) if $r[1] <= 0;
            return ('DEVICES', "$id $s $x PRV DP=$r[1]", $n);
        }
        return ('DEVICES', join(' ', $id, $s, $x, 'BFP', @r), $n);
    }
    if ($k eq 'OPP' || $k eq 'OFD') {
        # The plate takes its pipe's nominal size and bore.
        my ($dn, $bore) = pipe_size($p, $units);
        my @where = ((defined $dn ? "DN=$dn" : ()), 'PIPEDIA=' . fmt($bore));
        my @cd = @{ $a->{opt} } ? ("CD=$a->{opt}[0]") : ();
        return ('DEVICES', join(' ', $id, $s, $x, 'ORIFICE_P', "DP=$a->{pos}[1]", @where, @cd), $n)
            if $k eq 'OPP';
        return ('DEVICES', join(' ', $id, $s, $x, 'ORIFICE_D',
                                'BORE=' . fmt(size_mm($a->{pos}[1], $units->{SIZE})), @where, @cd), $n);
    }
    if ($k eq 'PRA') {
        # Outlet pressure = inlet / ratio; the solver sets the drop from the
        # solved inlet pressure.
        # MININLET 0 is "no minimum", so a BAND can be given without one.
        # BAND is a percentage of the inlet pressure; 5 unless given.
        my ($mi, $band) = @{ $a->{opt} };
        return ('DEVICES', join(' ', $id, $s, $x, 'PRA', 'RATIO=' . fmt(ratio_value($a->{pos}[1])),
                                (defined $mi && $mi > 0 ? "MININLET=$mi" : ()),
                                (defined $band ? "BAND=$band" : ())), $n);
    }
    die "device_row: no translation for $k\n";    # a programming error
}

# pipe_size -- a pipe's DN (undef for a bore pipe) and its bore in mm.
sub pipe_size {
    my ($p, $units) = @_;
    my $use = $p->{use} || { type => 'BORE' };
    return (undef, size_mm($p->{size}, $units->{SIZE})) if $use->{type} eq 'BORE';
    my $dn = size_dn($p->{size}, $units->{SIZE});
    HardyCross::Parse::ensure_db();
    return ($dn, HardyCross::PipeData::bore($use->{type}, $dn // 0) // 0);
}

#==============================================================================
# read_string / read_model -- a .phc model read into a network.
#
# Each translated row is added to the network by HardyCross::Parse::parse_row.
# An error names the .phc line the row came from.  The network keeps the .phc
# text as source_text: the demand calculation and the pressure ratio valve's
# top-of-band solve re-read it.
#==============================================================================
sub read_string {
    my $text = shift;
    my ($rows, $units) = translate($text);
    my $net = HardyCross::Parse::new_net();
    for my $r (@$rows) {
        my ($section, $row, $n) = @$r;
        if ($section eq 'PROJECT') {
            # A cover-sheet field: the value is the rest of the line as typed.
            my ($f, $v) = split ' ', $row, 2;
            ($v //= '') =~ s/[^\x20-\x7E]//g;
            $v =~ s/\s+\z//;
            $net->{project}{ uc $f } = $v;
            next;
        }
        my $ok = eval { HardyCross::Parse::parse_row($net, $section, [ HardyCross::Parse::tokenize($row) ]); 1 };
        next if $ok;
        my $e = $@;
        die $e unless HardyCross::is_model_error($e);
        HardyCross::fail(defined $n ? "line %d: %s" : '%s', (defined $n ? $n : ()), uc $e->{msg});
    }
    HardyCross::fail('THE FILE HOLDS NO MODEL: NO NODES AND NO PIPES')
        if @{ $net->{nodes} } <= 2 && @{ $net->{elems} } <= 1;
    # The .phc text is kept so the demand point and the ratio valve band can
    # re-solve the model from exactly what was read (HardyCross::Demand,
    # HardyCross::Report).
    $net->{source_text} = $text;
    $net->{phc_text}    = $text;
    $net->{phc_units}   = $units;
    # An assumed roughness is flagged wherever the warnings go: the editor's
    # WARNINGS list, the report's warnings and the JSON.
    push @{ $net->{warnings} }, HardyCross::Parse::roughness_warning($net);
    return $net;
}

sub read_model {
    my $path = shift;
    open my $fh, '<', $path or HardyCross::fail("cannot open input file %s", $path);
    # Slurped in a do-block so the undefined $/ cannot leak into the pipe
    # database load -- see HardyCross::Parse::read_model.
    my $text = do { local $/; <$fh> };
    close $fh;
    return read_string($text);
}

#==============================================================================
# The editor's checks of one line.
#==============================================================================

# The fitting codes in the database, read once from the file PipeData loaded,
# with their descriptions, for the pick list.  PipeData resolves fittings but
# does not list them; reading the same file means the list always matches
# what the resolver accepts.
my (%FITCODE, %KPCODE, %DNS);
sub fitting_tables {
    return if %FITCODE;
    HardyCross::Parse::ensure_db();
    open my $fh, '<:encoding(UTF-8)', HardyCross::PipeData::path() or return;
    local $/ = "\n";
    while (my $l = <$fh>) {
        chomp $l;
        next if $l =~ /^\s*(#|$)/;
        my @f = split /\|/, $l;
        if    ($f[0] eq 'FIT')    { $FITCODE{ $f[1] }{ $f[2] } //= ascii($f[3]) }
        elsif ($f[0] eq 'KPRIME') { $KPCODE{ $f[1] } //= ascii($f[2]) }
        elsif ($f[0] eq 'PIPE')   { push @{ $DNS{ $f[1] } }, $f[2] }
    }
    close $fh;
}
# reset_db_cache -- forget the lists above, after the database is edited and
# reloaded, so the next pick list is read from the new file.
sub reset_db_cache { %FITCODE = %KPCODE = %DNS = () }

# The user interface is 7-bit ASCII in capitals, like the report.
sub ascii { my $s = shift // ''; $s =~ s/\x{B0}/ DEG/g; $s =~ s/[^\x20-\x7E]//g; uc $s }

sub pipe_type_choices {
    HardyCross::Parse::ensure_db();
    return ((map { [ $_, ascii(HardyCross::PipeData::pipe_type($_)->{name}) ] }
             HardyCross::PipeData::pipe_types()),
            [ 'BORE', 'PIPES GIVEN BY THEIR BORE, WITH NO PIPE TYPE' ]);
}

# fitting_choices -- the codes a pipe of this type can take at this DN (or at
# any of its sizes when the DN is not known yet), short forms first.
sub fitting_choices {
    my ($type, $dn) = @_;
    return () if !defined $type || $type eq 'BORE';
    fitting_tables();
    my @dns = (defined $dn && grep { $_ == $dn } @{ $DNS{$type} || [] })
            ? ($dn) : @{ $DNS{$type} || [] };
    my (%label, @order);
    my %src = map { HardyCross::PipeData::governing_source($type, $_)->{table} => 1 } @dns;
    for my $s (sort keys %src) {
        my $tbl = $s eq 'PPI' ? \%KPCODE : ($FITCODE{$s} || {});
        for my $code (sort keys %$tbl) {
            push @order, $code unless exists $label{$code};
            $label{$code} //= $tbl->{$code};
        }
    }
    my @short = map { [ $_, "SHORT FOR $FIT_SHORT{$_}: $label{ $FIT_SHORT{$_} }" ] }
                grep { exists $label{ $FIT_SHORT{$_} } } sort keys %FIT_SHORT;
    return (@short, map { [ $_, $label{$_} ] } @order);
}

# step_id -- the next name in a series: P7 -> P8, N09 -> N10, 4101 -> 4102.
sub step_id {
    my $id = shift // '';
    return $1 . sprintf('%0*d', length $2, $2 + 1) if $id =~ /^(.*?)(\d+)\z/;
    return $id . '2';
}

#------------------------------------------------------------------------------
# propose -- the likely next line after a complete line.
#
# The same command with its names stepped.  A pipe starts where the last one
# ended, keeps its length and size, and drops its fittings.  Settings, USE and
# the copy and change commands propose nothing.
#------------------------------------------------------------------------------
sub propose {
    my $a = analyse(shift);
    return undef unless $a->{status} eq 'ok';
    my $k = $a->{key};
    my @p = @{ $a->{pos} };
    my @more = (@{ $a->{opt} }, @{ $a->{rest} });
    return join ' ', 'PIPE', step_id($p[0]), $p[2], step_id($p[2]), @p[3, 4] if $k eq 'PIPE';
    return join ' ', $k, step_id($p[0]), @p[1 .. $#p], @more
        if $k =~ /^(NODE|WATER|SPRINKLER|HYDRANT|HREEL|PUMP)\z/
        || command_spec($k)->{kind} eq 'device';
    return join ' ', $k, step_id($p[0]), step_id($p[1]), @p[2 .. $#p], @more if $k eq 'FIXEDFLOW';
    return undef;
}

#------------------------------------------------------------------------------
# check_line -- one line, checked as it is typed.
#
#   $context  {
#     use     => 'ASAM' or 'BORE', or { type, c }: the USE in force
#     units   => { LENGTH => 'M', ... }: the file's units (defaults otherwise)
#     method  => 'HW' or 'DW'
#     options => { FITTING_BASIS => 'STANDARD' }
#     nodes   => [ names ] or { name => 1 }: the defined nodes
#     cursor  => the cursor's column (default: end of line)
#   }
#
# Returns { status, message, template => { command, text, fields, current },
# choices => [ [code, description] ], proposal, undefined => [ nodes ] }.
#
# A PIPE, outlet, PUMP or WATER line the language accepts is also built as its
# row by the network builder itself, so a DN the pipe type does not make
# or a fitting the database lacks is an error as it is typed -- by the same
# rule and in the same words as when the model is solved.
#------------------------------------------------------------------------------
sub check_line {
    my ($line, $ctx) = @_;
    $ctx ||= {};
    $line //= '';
    my $cursor = $ctx->{cursor} // length $line;
    my $use = $ctx->{use} // 'BORE';
    $use = { type => uc $use } unless ref $use;
    my %units = (%UNIT_DEFAULT, %{ $ctx->{units} || {} });

    my $a = analyse($line, $cursor >= length(strip_comment($line)));
    my %r = (status => $a->{status} eq 'blank' ? 'ok' : $a->{status},
             message => $a->{msg} // '', choices => [], proposal => undef, undefined => []);
    return \%r if $a->{status} eq 'blank';
    my $c = command_spec($a->{key} // '');
    $r{message} = "$c->{name} NEEDS $a->{msg}" if $c && $a->{status} eq 'incomplete';

    #---------------------------------------------- the cursor's field
    # Words before the cursor; inside or at the end of a word, that word is
    # the current one, otherwise a new one is starting.
    my $before = substr(strip_comment($line), 0, $cursor);
    my @w = split ' ', $before;
    my $idx = $before =~ /\S\z/ ? $#w : scalar @w;      # word index; 0 is the command
    if ($c) {
        my @fields = template_fields($c);
        my $cur = $idx <= 0 ? -1 : $idx - 1;
        $cur = $#fields if $cur > $#fields;             # text, fittings, pairs run on
        $r{template} = { command => $c->{name}, text => template_text($c->{name}),
                         fields => \@fields, current => $cur };
        my $label = $cur >= 0 ? $fields[$cur] : '';
        my $q = uc($w[1] // '');
        if ($c->{name} eq 'USE' && $cur == 0) {
            $r{choices} = [ pipe_type_choices() ];
        } elsif ($c->{name} =~ /^(PIPE|CHANGEPIPE)\z/ && $label eq 'FITTINGS ...') {
            my $sz = $a->{pos}[ $c->{name} eq 'PIPE' ? 4 : 2 ];
            $r{choices} = [ fitting_choices($use->{type}, defined $sz ? size_dn($sz, $units{SIZE}) : undef) ];
        } elsif ($c->{name} eq 'UNITS' && $cur == 0) {
            $r{choices} = [ map { [ $_, join(' ', @{ $UNIT_CHOICES{$_} }) ] } @UNIT_QUANTITIES ];
        } elsif ($c->{name} eq 'UNITS' && $cur == 1 && $UNIT_CHOICES{$q}) {
            $r{choices} = [ map { [ $_, $_ eq $UNIT_DEFAULT{$q} ? 'DEFAULT' : '' ] } @{ $UNIT_CHOICES{$q} } ];
        } elsif ($c->{name} eq 'METHOD' && $cur == 0) {
            $r{choices} = [ [ 'HW', 'HAZEN-WILLIAMS' ], [ 'DW', 'DARCY-WEISBACH' ] ];
        } elsif ($c->{name} eq 'OPTION' && $cur == 0) {
            $r{choices} = [ map { [ $_, '' ] } @OPTIONS ];
        }
    } else {
        $r{template} = { command => '', text => '', fields => [], current => -1 };
    }
    return \%r unless $r{status} eq 'ok';

    #---------------------------------------------- the parser's verdict
    my $net = HardyCross::Parse::new_net();
    my $ok = eval {
        HardyCross::set_unit($net, 'FLOW', $units{FLOW});
        HardyCross::set_unit($net, 'PRESSURE', $units{PRESSURE});
        my $opts = $ctx->{options} || {};
        HardyCross::Parse::parse_row($net, 'OPTIONS', [ $_, $opts->{$_} ])
            for grep { defined $opts->{$_} } sort keys %$opts;
        my $at = sub { shift; HardyCross::fail(shift, @_) };
        my ($k, @p) = ($a->{key}, @{ $a->{pos} });
        if ($k eq 'PIPE') {
            my $row = pipe_row({ line => 0, use => $use, start => $p[1], end => $p[2],
                                 len => $p[3], size => $p[4], fits => $a->{rest} },
                               $p[0], undef, undef, \%units, ($ctx->{method} // '') eq 'DW', $at);
            HardyCross::Parse::parse_row($net, 'PIPES', [ HardyCross::Parse::tokenize($row) ]);
        } elsif ($c->{otype} && $p[3] != 0) {
            my $req = $p[2] < 0 ? 'P=' . (-$p[2]) : "Q=$p[2]";
            HardyCross::Parse::parse_row($net, 'DISCHARGES', [ $p[0], $p[0], $c->{otype},
                'K=' . fmt(k_factor_to_model($p[3], \%units)), $req ]);
        } elsif ($k eq 'PUMP') {
            HardyCross::Parse::parse_row($net, 'PUMPS', [ @p[0 .. 2], 0, $p[3], @{ $a->{rest} } ]);
        } elsif ($k eq 'WATER' && @{ $a->{rest} }) {
            HardyCross::Parse::parse_row($net, 'SUPPLIES', [ $p[0], $p[0], 'CURVE', 0, $p[2], @{ $a->{rest} } ]);
        }
        1;
    };
    unless ($ok) {
        my $e = $@;
        die $e unless HardyCross::is_model_error($e);
        @r{qw(status message)} = ('error', uc $e->{msg});
        return \%r;
    }

    #---------------------------------------------- nodes, and what is next
    if (my $known = $ctx->{nodes}) {
        my %k = ref $known eq 'HASH' ? %$known : map { $_ => 1 } @$known;
        $r{undefined} = [ grep { !$k{$_} } nodes_used($a) ];
    }
    $r{proposal} = propose($line);
    return \%r;
}

1;
