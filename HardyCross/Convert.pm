#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
# Convert.pm -- .hcx to .phc.
#
# The acceptance test for the .phc language is that a converted model gives a
# report IDENTICAL to its .hcx original, apart from the model file name.  So
# the converter copies every value exactly as it was typed -- "100.0" stays
# "100.0", a fitting string keeps its spelling, units stay the units the model
# was written in -- and decides nothing about hydraulics.
#
# It works from the .hcx ROWS, not from the parsed network.  The network has
# already converted every value to internal units, folded fixed flows into
# nodal demands and derived the third of K, Q and P; writing it back would
# change the model (the "saving degraded the model" defect in the README is
# exactly that mistake).  The .hcx is still parsed first, with the real
# parser, so a file that does not read is refused, not half-converted.
#
# Whatever the .hcx reader ignores -- an unknown OPTIONS name, a stray field, a
# K= on a fixed flow -- did nothing to the result and so cannot be carried
# into .phc, which refuses such things.  It is dropped, and the header comment
# of the .phc lists every line dropped and why.  Comments are not carried over;
# the header says that too.
#
# How it is laid out:
#   hcx_to_phc        the entry point: parse, convert each part, assemble, check
#   rows              the .hcx file as rows, walked as the parser walks it
#   check_units_first refuse a file whose UNITS come after data
#   setting_lines     Title, Project, Units, Method, Option
#   node_lines        one Node line per node, in the parser's order
#   element_lines     the elements in row order, with Use lines placed
#   pipe_line, pump_line, supply_line, discharge_line, device_line
#                     one .hcx element row each
#   split_fields      a row's KEY=value fields, first of each kept, the rest
#                     reported as ignored -- the way HardyCross::Parse::kv reads
#
# A conversion carries its state in one hash, $cv:
#   net      the parsed network (node order, the method as understood)
#   rows     the rows, from rows()
#   dropped  the header notes, one per thing dropped

package HardyCross::Convert;

use strict;
use warnings;
use HardyCross;
use HardyCross::Parse;
use HardyCross::Phc;

# The .hcx UNITS short names, as HardyCross::set_unit reads them.
my %UNIT_ALIAS = (PRES => 'PRESSURE', LEN => 'LENGTH', DIA => 'DIAMETER');

# The .hcx blocks that hold elements.
my %ELEMENT_BLOCK = map { $_ => 1 } qw(PIPES PUMPS SUPPLIES DISCHARGES DEVICES);

# Each outlet type's .phc command, padded to the column the converter aligns
# values on.  FIXEDFLOW (and its short form FIXED) is the Flow command.
my %OUTLET = (SPRINKLER => 'Head    ', HYDRANT => 'Hydrant ', HOSEREEL => 'HoseReel');

#------------------------------------------------------------------------------
# hcx_to_phc -- the .phc text for a .hcx model.
#
#   $text   the .hcx file's contents
#   $name   the .hcx file's name, for the header comment
#
# Fails (HardyCross::fail) when the .hcx does not parse, or holds something
# .phc cannot express without changing the result; the message names the
# .hcx line.
#------------------------------------------------------------------------------
sub hcx_to_phc {
    my ($text, $name) = @_;
    $name //= 'model.hcx';

    # Parse it for real first.  A model the parser refuses is not converted.
    my $cv = { net => HardyCross::Parse::read_string($text),
               rows => [ rows($text) ], dropped => [] };

    check_units_first($cv);
    my @settings = setting_lines($cv);
    my @nodes    = node_lines($cv);
    my @elements = element_lines($cv);

    # The header, then the three groups separated by blank lines.
    my @out = ("// $name - converted from .hcx by PHCP $HardyCross::VERSION.",
               '// Comments in the .hcx file are not carried over.');
    if (@{ $cv->{dropped} }) {
        push @out, '// Dropped from the .hcx because they had no effect on the result:',
                   map { "//   $_" } @{ $cv->{dropped} };
    }
    for my $group (\@settings, \@nodes, \@elements) {
        push @out, '', @$group if @$group;
    }
    my $phc = join("\n", @out) . "\n";

    # The result must read, or nothing is written.  The usual reason it does
    # not is a value the .hcx reader accepted without checking -- text where a
    # number belongs, which it reads as 0 -- and which .phc refuses.  The
    # message quotes the converted line so the .hcx value can be found.
    my $ok = eval { HardyCross::Phc::read_string($phc); 1 };
    unless ($ok) {
        my $e = $@;
        die $e unless HardyCross::is_model_error($e);
        my ($n, $msg) = $e->{msg} =~ /^line (\d+): (.*)\z/s;
        my $line = defined $n ? (split /\n/, $phc)[ $n - 1 ] : undef;
        HardyCross::fail("the model converts to .phc that does not read: %s%s.  "
                       . "The .hcx probably holds a value its reader accepted without "
                       . "checking (text where a number belongs is read as 0); correct "
                       . "it and convert again", $msg // $e->{msg},
                         defined $line ? " - in the line '$line'" : '');
    }
    return $phc;
}

#------------------------------------------------------------------------------
# rows -- the .hcx file as rows, the way HardyCross::Parse::read_string walks it.
#
# Each row: { sec (block), tk (tokens), n (line number), raw (PROJECT value) }.
# Block headers, END, blank and comment lines produce no row.
#------------------------------------------------------------------------------
sub rows {
    my $text = shift;
    my ($section, $n, @rows) = ('', 0);
    for my $line (split /\n/, $text, -1) {
        $n++;
        my @tk = HardyCross::Parse::tokenize($line);
        next unless @tk;
        my $head = uc $tk[0];
        if ($head =~ /^(PROJECT|UNITS|OPTIONS|NODES|PIPES|PUMPS|SUPPLIES|DISCHARGES|DEVICES)$/
            && @tk == 1) {
            $section = $head;
            next;
        }
        if ($head eq 'END') { $section = ''; next }
        next if $section eq '';
        my $r = { sec => $section, tk => \@tk, n => $n };
        if ($section eq 'PROJECT') {
            # The same extraction as the parser's, so the value is the one the
            # report prints.
            (my $raw = $line) =~ s/^\s*\S+\s*//;
            $raw =~ s/[!#].*$//;
            $raw =~ s/[^\x20-\x7E]//g;
            $raw =~ s/\s+$//;
            $r->{raw} = $raw;
        }
        push @rows, $r;
    }
    return @rows;
}

# drop -- record a row, or part of one, left out of the .phc, and why.
sub drop {
    my ($cv, $r, $why) = @_;
    push @{ $cv->{dropped} },
        sprintf('line %d: %s %s - %s', $r->{n}, $r->{sec}, join(' ', @{ $r->{tk} }), $why);
}

# fail_at -- stop the conversion, naming the .hcx line.
sub fail_at {
    my ($r, $fmt, @args) = @_;
    HardyCross::fail("line %d: %s", $r->{n}, sprintf($fmt, @args));
}

# in_block -- the rows of one .hcx block, in file order.
sub in_block {
    my ($cv, $sec) = @_;
    return grep { $_->{sec} eq $sec } @{ $cv->{rows} };
}

#------------------------------------------------------------------------------
# check_units_first -- refuse a file with UNITS after model data.
#
# The .hcx parser applies UNITS factors to the rows after them, so a UNITS row
# below data means the data above it was read in other units.  .phc Units are
# file-wide; such a file cannot be converted without changing what it means.
#------------------------------------------------------------------------------
sub check_units_first {
    my $cv = shift;
    my $data_seen;
    for my $r (@{ $cv->{rows} }) {
        if ($r->{sec} eq 'UNITS') {
            fail_at($r, 'UNITS comes after model data, which the .hcx reader read in '
                      . 'the units in force before it; move the UNITS block to the top '
                      . 'and check the values, then convert') if $data_seen;
        } elsif ($r->{sec} ne 'PROJECT') {
            $data_seen = 1;
        }
    }
}

#------------------------------------------------------------------------------
# setting_lines -- Title, Project, Units, Method and Option lines.
#
# In .hcx a setting given twice silently takes the last value; in .phc it is
# an error.  So the last of each is written, and the earlier ones are listed
# as dropped -- they never had an effect.
#------------------------------------------------------------------------------
sub setting_lines {
    my $cv = shift;
    my @lines;

    #-------------------------------------------------- Title and Project
    my %last;
    for my $r (in_block($cv, 'PROJECT')) {
        my $f = uc $r->{tk}[0];
        drop($cv, $last{$f}, "PROJECT $f is given again on line $r->{n}") if $last{$f};
        $last{$f} = $r;
    }
    for my $r (in_block($cv, 'PROJECT')) {
        my $f = uc $r->{tk}[0];
        next unless $last{$f} == $r;
        if ($r->{raw} eq '') {
            drop($cv, $r, 'no text');
            next;
        }
        fail_at($r, "PROJECT %s contains '//', which starts a comment in .phc", $f)
            if $r->{raw} =~ m{//};
        push @lines, $f eq 'TITLE' ? "Title    $r->{raw}" : "Project  $f $r->{raw}";
    }

    #-------------------------------------------------- Units, on one line
    my %unit;
    for my $r (in_block($cv, 'UNITS')) {
        my $q = uc $r->{tk}[0];
        $q = $UNIT_ALIAS{$q} // $q;
        drop($cv, $unit{$q}{r}, "UNITS $q is given again on line $r->{n}") if $unit{$q};
        $unit{$q} = { r => $r, v => uc($r->{tk}[1] // '') };
    }
    my @u = map { "$_=$unit{$_}{v}" } grep { $unit{$_} } @HardyCross::Phc::UNIT_KEYS;
    push @lines, 'Units    ' . join(' ', @u) if @u;

    #-------------------------------------------------- Method and Option
    my (%opt, @order);
    my %known = map { $_ => 1 } @HardyCross::Phc::OPTIONS, 'METHOD';
    for my $r (in_block($cv, 'OPTIONS')) {
        my $k = uc $r->{tk}[0];
        my $v = $r->{tk}[1] // '';
        unless ($known{$k}) {
            drop($cv, $r, 'not an option the .hcx reader acts on');
            next;
        }
        if ($k eq 'PROFILE' && uc $v ne 'EPANET') {
            drop($cv, $r, 'PROFILE acts only on EPANET');
            next;
        }
        if ($opt{$k}) { drop($cv, $opt{$k}{r}, "$k is given again on line $r->{n}") }
        else          { push @order, $k }
        # An absent value is read by the .hcx parser as 0 (num('') is 0).
        $opt{$k} = { r => $r, v => (length $v ? $v : '0') };
    }
    # The method as the parser understood it: HAZEN and DARCY are spelt HW
    # and DW, the only two words the Method command takes.
    push @lines, "Method   $cv->{net}{opts}{method}" if $opt{METHOD};
    push @lines, "Option   $_ $opt{$_}{v}" for grep { $_ ne 'METHOD' } @order;
    return @lines;
}

#------------------------------------------------------------------------------
# node_lines -- one Node line for every node.
#
# In the parser's order -- the order the nodes were first named, which the
# solver's spanning tree depends on -- with the elevation as typed on the
# node's last NODES row, or 0 for a node the .hcx created implicitly by naming
# it in an element.  .phc requires a Node line for every node, so this is what
# lets every converted file read.
#------------------------------------------------------------------------------
sub node_lines {
    my $cv = shift;
    my %elev;
    for my $r (in_block($cv, 'NODES')) {
        $elev{ $r->{tk}[0] } = $r->{tk}[1] if defined $r->{tk}[1];
        drop($cv, $r, 'fields after the elevation are not read') if @{ $r->{tk} } > 2;
    }
    my $nodes = $cv->{net}{nodes};
    return map { "Node     $_->{id} " . ($elev{ $_->{id} } // '0') }
           grep { $_->{id} ne 'REF' } @{$nodes}[1 .. $#$nodes];
}

#------------------------------------------------------------------------------
# element_lines -- every element, in .hcx row order, with Use lines placed.
#
# Row order is the parser's element order, which the .phc reader keeps (see
# @SETTING_BLOCKS in HardyCross::Phc) and the report's schedules follow.  A
# blank line goes between runs of different kinds so the file reads in the
# groups the .hcx had.
#
# A Use line goes in wherever the pipe type changes from the pipe before.  Use
# affects only Pipe lines, so it stays in force across the other kinds of line
# and is only ever needed in front of a pipe.
#------------------------------------------------------------------------------
sub element_lines {
    my $cv = shift;
    my %convert = (PIPES => \&pipe_line, PUMPS => \&pump_line,
                   SUPPLIES => \&supply_line, DISCHARGES => \&discharge_line,
                   DEVICES => \&device_line);
    my (@lines, $kind, $use);
    for my $r (grep { $ELEMENT_BLOCK{ $_->{sec} } } @{ $cv->{rows} }) {
        my ($line, $type) = $convert{ $r->{sec} }->($cv, $r);
        push @lines, '' if defined $kind && $r->{sec} ne $kind;
        $kind = $r->{sec};
        if (defined $type) {
            push @lines, "Use      $type" if !defined $use || $type ne $use;
            $use = $type;
        }
        push @lines, $line;
    }
    return @lines;
}

#------------------------------------------------------------------------------
# split_fields -- a row's KEY=value fields from field $from on.
#
# Returns (\%value, \@ignored, \@plain):
#   %value    for each key in @$keys, the FIRST value given -- that is the one
#             HardyCross::Parse::kv reads; keys are upper-cased
#   @ignored  KEY=value tokens the parser never reads: a repeated key, or one
#             this kind of row does not take
#   @plain    the fields that are not KEY=value, in order
#------------------------------------------------------------------------------
sub split_fields {
    my ($r, $keys, $from) = @_;
    my %want = map { $_ => 1 } @$keys;
    my (%v, @ignored, @plain);
    my @tk = @{ $r->{tk} };
    for my $t (@tk[$from .. $#tk]) {
        if ($t =~ /^([^=]+)=(.*)\z/) {
            my $k = uc $1;
            if ($want{$k} && !exists $v{$k}) { $v{$k} = $2 }
            else                             { push @ignored, $t }
        } else {
            push @plain, $t;
        }
    }
    return (\%v, \@ignored, \@plain);
}

# key_fields -- "KEY=value" for each of @keys present in %$v, in that order.
sub key_fields {
    my ($v, @keys) = @_;
    return map { "$_=$v->{$_}" } grep { exists $v->{$_} } @keys;
}

# note_ignored -- drop() the fields the .hcx reader never read, if any.
sub note_ignored {
    my ($cv, $r, @ignored) = @_;
    drop($cv, $r, 'ignored by the .hcx reader: ' . join(' ', @ignored)) if @ignored;
}

#------------------------------------------------------------------------------
# pipe_line -- "id n1 n2 length diameter [C] [TYPE= FIT= C= EQV= EPS= K=]".
#
# Returns (Pipe line, pipe type or BORE).
#------------------------------------------------------------------------------
sub pipe_line {
    my ($cv, $r) = @_;
    my @tk = @{ $r->{tk} };
    my ($v, $ign, $plain) = split_fields($r, [qw(TYPE FIT C EQV EPS K)], 5);
    # The parser takes field 6 as C, but only when it is not KEY=value and no
    # C= is given anywhere on the row.  Any other plain field is not read.
    if (defined $tk[5] && $tk[5] !~ /=/) {
        shift @$plain;
        if (exists $v->{C}) { push @$ign, $tk[5] }
        else                { $v->{C} = $tk[5] }
    }
    note_ignored($cv, $r, @$ign, @$plain);
    my $type = exists $v->{TYPE} ? uc $v->{TYPE} : 'BORE';
    # The tokeniser protects the commas inside FIT= as '+'.  Each piece is
    # written as one fitting token, and the .phc reader joins the tokens back
    # with commas -- the same string, so the report prints the same fittings.
    my @fit = grep { length } split /\+/, ($v->{FIT} // '');
    return (join(' ', 'Pipe    ', @tk[0 .. 4], @fit, key_fields($v, qw(C EQV EPS K))), $type);
}

#------------------------------------------------------------------------------
# pump_line -- "id n1 n2 q1 p1 q2 p2 ...".
#------------------------------------------------------------------------------
sub pump_line {
    my ($cv, $r) = @_;
    my ($v, $ign, $plain) = split_fields($r, [], 3);
    note_ignored($cv, $r, @$ign);
    return join ' ', 'Pump    ', @{ $r->{tk} }[0 .. 2], @$plain;
}

#------------------------------------------------------------------------------
# supply_line -- "id node STATIC p [Z=]" or "id node CURVE q1 p1 ... [Z=]".
#------------------------------------------------------------------------------
sub supply_line {
    my ($cv, $r) = @_;
    my @tk = @{ $r->{tk} };
    my ($v, $ign, $plain) = split_fields($r, ['Z'], 3);
    my $mode = uc $tk[2];
    my @pts = @$plain;
    if ($mode eq 'STATIC') {
        # Only the first value is the pressure; the parser reads no more.
        push @$ign, splice(@pts, 1);
    } elsif ($mode ne 'CURVE') {
        # The parser reads any word other than STATIC as a curve.
        drop($cv, $r, "$tk[2] is read by the .hcx reader as CURVE");
        $mode = 'CURVE';
    }
    note_ignored($cv, $r, @$ign);
    return join ' ', 'Supply  ', @tk[0, 1], $mode, @pts, key_fields($v, 'Z');
}

#------------------------------------------------------------------------------
# discharge_line -- "id node TYPE [K=] [Q=] [P=] [Z=]".
#
# Q falls back to MINQ and P to MINP, as in the parser, and the .phc line
# carries the value under its plain name.
#------------------------------------------------------------------------------
sub discharge_line {
    my ($cv, $r) = @_;
    my @tk = @{ $r->{tk} };
    my $ty = uc $tk[2];
    my ($v, $ign, $plain) = split_fields($r, [qw(K Q MINQ P MINP Z)], 3);
    my @ignored = (@$ign, @$plain);
    if (exists $v->{MINQ}) {
        if (exists $v->{Q}) { push @ignored, "MINQ=$v->{MINQ}" }
        else                { $v->{Q} = $v->{MINQ} }
    }
    if ($ty eq 'FIXEDFLOW' || $ty eq 'FIXED') {
        # A fixed flow is a nodal demand with a minimum pressure that is
        # checked.  The parser takes P= before MINP= as that minimum (kv('P')
        # // kv('MINP')); .phc spells it MINP= only.  K has no meaning here.
        if (exists $v->{P}) {
            push @ignored, "MINP=$v->{MINP}" if exists $v->{MINP};
            $v->{MINP} = $v->{P};
        }
        push @ignored, "K=$v->{K}" if exists $v->{K};
        drop($cv, $r, 'not used for a fixed flow: ' . join(' ', @ignored)) if @ignored;
        return join ' ', 'Flow    ', @tk[0, 1], key_fields($v, qw(Q MINP Z));
    }
    fail_at($r, 'discharge type %s has no .phc command (SPRINKLER, HYDRANT, '
              . 'HOSEREEL and FIXEDFLOW do)', $tk[2]) unless $OUTLET{$ty};
    if (exists $v->{MINP}) {
        if (exists $v->{P}) { push @ignored, "MINP=$v->{MINP}" }
        else                { $v->{P} = $v->{MINP} }
    }
    note_ignored($cv, $r, @ignored);
    return join ' ', $OUTLET{$ty}, @tk[0, 1], key_fields($v, qw(K Q P Z));
}

#------------------------------------------------------------------------------
# device_line -- "id n1 n2 TYPE ...": BFP, PRV, ORIFICE_P or ORIFICE_D.
#
# Each type reads only its own keys; an ORIFICE_P's BORE= or an ORIFICE_D's
# DP=, for instance, is never read and is dropped.
#------------------------------------------------------------------------------
sub device_line {
    my ($cv, $r) = @_;
    my @tk = @{ $r->{tk} };
    my $ty = uc $tk[3];
    my %keys = (PRV => ['DP'], ORIFICE_P => [qw(DP DN PIPEDIA CD)],
                ORIFICE_D => [qw(BORE DN PIPEDIA CD)], BFP => []);
    my ($v, $ign, $plain) = split_fields($r, $keys{$ty} || [], 4);
    # A BFP's plain fields are its loss curve; any other device has none.
    note_ignored($cv, $r, @$ign, ($ty eq 'BFP' ? () : @$plain));
    return join ' ', 'BFP     ', @tk[0 .. 2], @$plain        if $ty eq 'BFP';
    return join ' ', 'PRV     ', @tk[0 .. 2], key_fields($v, 'DP') if $ty eq 'PRV';
    return join ' ', 'Orifice ', @tk[0 .. 2], key_fields($v, @{ $keys{$ty} });
}

1;
