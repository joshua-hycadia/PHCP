#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# HardyCross/Isometric.pm -- an isometric drawing of a network.
#
# WHAT THIS IS
#   The other way to enter a calculation, used by phcp_isometric.pl.  The
#   text editor types the model as commands.  This draws the same model:
#   nodes on a 30-degree grid, pipes along the grid axes, the elevation on
#   the vertical axis.  A pipe is two clicks, and the length is the grid
#   distance, or a length (and a size, fittings and C) typed first, and the
#   click only chooses the direction.  Drawing writes .phc.  Nothing here
#   solves, sizes or checks; the reader and the solver do, on the text this
#   writes.
#
#   The drawing is a view, not a second model.  A length and an elevation
#   stay as they were typed until a point is moved; the move then sets them
#   from the grid, in the model's units.  Positions live in comments the
#   reader skips, so a file saved from the drawing calculates exactly as the
#   same commands calculate without them:
#
#       //ISO GRID 1
#       //ISO N1 0 0 0
#       //ISO N2 6 0 4.5
#
#   GRID is the metres of one grid step, on every axis.  The three numbers
#   are the point's steps along the two plan axes and the vertical.  A point
#   with no //ISO line is placed from the pipes and the elevations.
#
#   Copies are written out in full (a PC or NC line becomes the pipes or
#   nodes it means) because a drawing has no source to copy.  A CHANGEPIPE is
#   applied to the one pipe it names, and a copy keeps the source's original,
#   which is what the reader does.  Lines the drawing does not edit -- AREA,
#   PUMPDUTY, SUPPLYGRAPH, and any comment that is not //ISO -- are kept and
#   written back after the network.
#
# THIS MODULE HAS NO TK.  The window is HardyCross/Window/Isometric.pm.
# tools/test_isometric.pl drives what is here.
#==============================================================================
package HardyCross::Isometric;

use strict;
use warnings;
use HardyCross::Phc;
use HardyCross::Parse;

# The same metres factors as HardyCross::Phc.  Duplicated because that table
# is private; tools/test_isometric.pl checks a value converted and read back.
my %TO_METRE = (MM => 0.001, CM => 0.01, M => 1, IN => 0.0254, FT => 0.3048);

# 30 degrees: the two plan axes of an isometric, equally foreshortened, with
# the vertical upright.  One grid step is SCALE pixels along each axis.
my $COS30 = 0.8660254037844386;
my $SIN30 = 0.5;

my %NODE_KIND = map { $_ => 1 } qw(NODE WATER SPRINKLER HYDRANT HREEL);
my %DEVICE = map { $_ => 1 } qw(BP BFP PRV OPP OFD PRA);

#------------------------------------------------------------------------------
# read_network -- a drawing from the editor's network text.
#
# $units is the PROJECT tab's units (LENGTH, ELEVATION, ...).  Anything not
# given takes the office default.  The text is the network only: settings
# have already been taken out by the editor.  A line this does not understand
# is kept, not dropped.
#------------------------------------------------------------------------------
sub read_network {
    my ($text, $units) = @_;
    $units = { %HardyCross::Phc::UNIT_DEFAULT, %{ $units || {} } };
    my $d = {
        units => $units, grid => 1, nodes => {}, node_order => [], pipes => [],
        pumps => [], flows => [], extras => [], warnings => [], occ => {},
    };
    my $use = { type => 'BORE', c => undef };     # pipes before any USE
    my (%pipe, @pc, @nc, @change, @eqv, @device);

    my $n = 0;
    for my $line (split /\n/, defined $text ? $text : '', -1) {
        $n++;
        $line =~ s/\r\z//;
        next if $line =~ /^\s*$/;
        if ($line =~ /^\s*\/\//) {
            iso_line($d, $line);
            next;
        }
        my $note = ($line =~ m{//(.*)\z}) ? $1 : undef;
        $note =~ s/^\s+// if defined $note;
        my $a = HardyCross::Phc::analyse($line);
        if ($a->{status} ne 'ok') { push @{ $d->{extras} }, $line; next }
        my $spec = HardyCross::Phc::command_spec($a->{key});
        if ($spec && $spec->{kind} eq 'setting') { push @{ $d->{extras} }, $line; next }
        my ($k, @p) = ($a->{key}, @{ $a->{pos} });

        if ($k eq 'USE') {
            $use = { type => $p[0], c => (@{ $a->{opt} } ? $a->{opt}[0] : undef) };
        } elsif ($k eq 'PIPE') {
            my $p_ = pipe_rec($p[0], $p[1], $p[2], $p[3], $p[4], $a->{rest}, $use, $note);
            $pipe{ $p[0] } = $p_;
            push @{ $d->{pipes} }, $p_;
        } elsif ($k eq 'PC') {
            push @pc, [ $line, $p[0], [ @{ $a->{rest} } ], $note ];
        } elsif ($k eq 'CHANGEPIPE') {
            push @change, [ $line, $p[0], $p[1], $p[2], [ @{ $a->{rest} } ] ];
        } elsif ($k eq 'EQV') {
            push @eqv, [ $line, $p[0], $p[1], $note ];
        } elsif ($NODE_KIND{$k}) {
            add_read_node($d, $k, \@p, $a, $note);
        } elsif ($k eq 'NC') {
            push @nc, [ $line, $p[0], [ @{ $a->{rest} } ] ];
        } elsif ($k eq 'FIXEDFLOW') {
            push @{ $d->{flows} }, { name => $p[0], node => $p[1], flow => $p[2],
                minp => (@{ $a->{opt} } ? $a->{opt}[0] : undef), note => $note };
        } elsif ($k eq 'PUMP') {
            push @{ $d->{pumps} }, { name => $p[0], in => $p[1], out => $p[2],
                churn => $p[3], pairs => [ @{ $a->{rest} } ], note => $note };
        } elsif ($DEVICE{$k}) {
            my @args = $k =~ /^(BFP|PRV)\z/ ? @{ $a->{rest} }
                     : ( $p[1], ($k =~ /^(OPP|OFD|PRA)\z/ ? @{ $a->{opt} } : @{ $a->{rest} }) );
            push @device, [ $line, $k, $p[0], \@args ];
        } else {
            push @{ $d->{extras} }, $line;     # AREA, PUMPDUTY, SUPPLYGRAPH
        }
    }

    resolve_copies($d, \%pipe, \@nc, \@pc);
    apply_pins($d);
    # A change applies to the named pipe after copying, so a copy still has
    # the source's original.  The snapshot was taken in resolve_copies.
    for my $c (@change) {
        my ($line, $name, $len, $size, $fits) = @$c;
        my $p = $pipe{$name};
        unless ($p) { push @{ $d->{extras} }, $line; next }
        $p->{len} = $len; $p->{size} = $size; $p->{fits} = [ @$fits ];
    }
    for my $e (@eqv) {
        my ($line, $name, $len, $note) = @$e;
        my $p = $pipe{$name};
        unless ($p && !defined $p->{eqv}) { push @{ $d->{extras} }, $line; next }
        $p->{eqv} = $len; $p->{eqv_note} = $note;
    }
    for my $e (@device) {
        my ($line, $kind, $name, $args) = @$e;
        my $p = $pipe{$name};
        unless ($p && !$p->{device}) { push @{ $d->{extras} }, $line; next }
        $p->{device} = { kind => $kind, args => $args };
    }

    layout($d);
    rebuild_occ($d);
    return $d;
}

# iso_line -- one //ISO comment.  Anything else that starts with // is kept.
sub iso_line {
    my ($d, $line) = @_;
    if ($line =~ /^\s*\/\/ISO\s+GRID\s+(\S+)\s*$/i) {
        my $g = $1;
        if (HardyCross::Parse::is_num($g) && $g > 0) { $d->{grid} = $g + 0 }
        else { push @{ $d->{warnings} }, 'ISO GRID MUST BE A LENGTH GREATER THAN ZERO' }
        return;
    }
    if ($line =~ /^\s*\/\/ISO\s+(\S+)\s+(-?\d+)\s+(-?\d+)\s+(-?\d+(?:\.\d+)?)\s*$/i) {
        $d->{pin}{$1} = [ $2 + 0, $3 + 0, $4 + 0 ];
        return;
    }
    if ($line =~ /^\s*\/\/ISO\b/i) {
        push @{ $d->{warnings} }, 'AN ISO LINE WAS NOT GRID OR A POINT, AND WAS IGNORED';
        return;
    }
    push @{ $d->{extras} }, $line;
}

sub pipe_rec {
    my ($name, $start, $end, $len, $size, $fits, $use, $note) = @_;
    return { name => $name, start => $start, end => $end, len => $len, size => $size,
             fits => [ @$fits ], use_type => $use->{type}, use_c => $use->{c}, note => $note };
}

sub add_read_node {
    my ($d, $kind, $p, $a, $note) = @_;
    my $name = $p->[0];
    my $node = { name => $name, kind => $kind, elev => $p->[1], note => $note, pairs => [] };
    if ($kind eq 'WATER') {
        $node->{static} = $p->[2];
        $node->{pairs} = [ @{ $a->{rest} } ];
    } elsif ($kind ne 'NODE') {
        $node->{minflow} = $p->[2];
        $node->{k} = $p->[3];
    }
    if ($d->{pin}{$name}) {
        ($node->{ix}, $node->{iy}, $node->{iz}) = @{ $d->{pin}{$name} };
        $node->{pinned} = 1;
    }
    $d->{nodes}{$name} = $node;
    push @{ $d->{node_order} }, $name;
}

# resolve_copies -- NC and PC, in the reader's order: copy first, from the
# source as it was typed, and only then does the caller apply CHANGEPIPE.
sub resolve_copies {
    my ($d, $pipe, $nc, $pc) = @_;
    # A copy may name a copy, so walk until nothing further resolves.  What
    # is left names a source the file never defines; the line is kept for
    # the reader to refuse.
    my @left = @$nc;
    while (@left) {
        my (@next, $moved);
        for my $row (@left) {
            my ($line, $src, $names) = @$row;
            my $s = $d->{nodes}{$src};
            unless ($s) { push @next, $row; next }
            $moved = 1;
            for my $name (@$names) {
                $d->{nodes}{$name} = { name => $name, kind => $s->{kind}, elev => $s->{elev},
                    static => $s->{static}, minflow => $s->{minflow}, k => $s->{k},
                    pairs => [ @{ $s->{pairs} || [] } ] };
                push @{ $d->{node_order} }, $name;
            }
        }
        if (!$moved) { push @{ $d->{extras} }, $_->[0] for @next; last }
        @left = @next;
    }
    # The original of each real pipe, before any change and before copies
    # read it.  A copy of a copy reads that original, not a later change.
    for my $p (values %$pipe) {
        $p->{orig} = { len => $p->{len}, size => $p->{size}, fits => [ @{ $p->{fits} } ],
                       use_type => $p->{use_type}, use_c => $p->{use_c} };
    }
    @left = @$pc;
    while (@left) {
        my (@next, $moved);
        for my $row (@left) {
            my ($line, $src, $rest) = @$row;
            my $source = $pipe->{$src};
            unless ($source && $source->{orig}) { push @next, $row; next }
            $moved = 1;
            my @r = @$rest;
            my $o = $source->{orig};
            while (@r >= 3) {
                my ($name, $s, $e) = splice @r, 0, 3;
                my $p_ = pipe_rec($name, $s, $e, $o->{len}, $o->{size}, $o->{fits},
                                  { type => $o->{use_type}, c => $o->{use_c} }, undef);
                $p_->{orig} = { len => $o->{len}, size => $o->{size}, fits => [ @{ $o->{fits} } ],
                                use_type => $o->{use_type}, use_c => $o->{use_c} };
                $pipe->{$name} = $p_;
                push @{ $d->{pipes} }, $p_;
            }
            push @{ $d->{extras} }, $line if @r;     # a short tail is the reader's error to show
        }
        if (!$moved) { push @{ $d->{extras} }, $_->[0] for @next; last }
        @left = @next;
    }
}

# apply_pins -- //ISO may sit above or below the point it names.
sub apply_pins {
    my $d = shift;
    for my $name (@{ $d->{node_order} }) {
        next unless $d->{pin}{$name};
        my $n = $d->{nodes}{$name};
        ($n->{ix}, $n->{iy}, $n->{iz}) = @{ $d->{pin}{$name} };
        $n->{pinned} = 1;
    }
    for my $name (keys %{ $d->{pin} || {} }) {
        push @{ $d->{warnings} }, "ISO NAMES $name, WHICH IS NOT A POINT"
            unless $d->{nodes}{$name};
    }
}

#------------------------------------------------------------------------------
# layout -- plan positions for every point that has none.
#
# The vertical is the elevation, in grid steps, unless a //ISO line gave one.
# Each new point is put along a grid axis from the point it is piped to, by
# the pipe's length, so a tree reads as an isometric.  A loop joins points
# already placed; that pipe is drawn straight between them even when it is
# not on one axis.  A pipe of no length (a device sat at a point) is drawn
# one step away so the two points can be told apart; its length is not changed.
#------------------------------------------------------------------------------
sub layout {
    my $d = shift;
    my $g = $d->{grid} || 1;
    for my $name (@{ $d->{node_order} }) {
        my $n = $d->{nodes}{$name};
        unless ($n->{pinned}) {
            my $m = elev_metres($d, $n);
            $n->{iz} = $m / $g;
        }
    }
    rebuild_occ($d);

    my %adj;
    my $link = sub {
        my ($a, $b, $len) = @_;
        return unless $d->{nodes}{$a} && $d->{nodes}{$b};
        push @{ $adj{$a} }, [ $b, $len ];
        push @{ $adj{$b} }, [ $a, $len ];
    };
    for my $p (@{ $d->{pipes} }) {
        my $m = HardyCross::Phc::length_metres($p->{len}, $d->{units}{LENGTH});
        $link->($p->{start}, $p->{end}, defined $m ? $m : 0);
    }
    for my $p (@{ $d->{pumps} }) { $link->($p->{in}, $p->{out}, 2 * $g) }

    my %seen;
    my $cursor = 0;
    for my $name (@{ $d->{node_order} }) {
        next if $seen{$name};
        my $n = $d->{nodes}{$name};
        unless (defined $n->{ix}) {
            my $ix = $cursor;
            $ix++ while !cell_free($d, $ix, 0, $n->{iz});
            set_cell($d, $n, $ix, 0);
            $cursor = $ix + 4;
        }
        my @q = ($name);
        $seen{$name} = 1;
        while (@q) {
            my $p = shift @q;
            my $slot = 0;
            for my $e (@{ $adj{$p} || [] }) {
                my ($c, $len) = @$e;
                next if $seen{$c};
                place_child($d, $d->{nodes}{$p}, $d->{nodes}{$c}, $len, $slot) unless defined $d->{nodes}{$c}{ix};
                $seen{$c} = 1;
                $slot++;
                push @q, $c;
            }
        }
    }
}

sub place_child {
    my ($d, $parent, $child, $len_m, $slot) = @_;
    my $g = $d->{grid} || 1;
    my $vert = abs($child->{iz} - $parent->{iz}) * $g;
    my $horiz = ($len_m > $vert) ? sqrt($len_m * $len_m - $vert * $vert) : 0;
    # No length, or the whole length is the rise: keep the plan point, unless
    # that cell is this point's own (a device in a pipe of no length).
    my $steps = ($len_m <= 0) ? 1 : ($horiz < 0.25 * $g ? 0 : iround($horiz / $g));
    $steps = 1 if $steps < 1 && $len_m <= 0;
    if ($steps == 0 && cell_free($d, $parent->{ix}, $parent->{iy}, $child->{iz})) {
        set_cell($d, $child, $parent->{ix}, $parent->{iy});
        return;
    }
    $steps = 1 if $steps < 1;
    my @dirs = ([1, 0], [0, 1], [-1, 0], [0, -1]);
    @dirs = (@dirs[ $slot % 4 .. $#dirs ], @dirs[ 0 .. ($slot % 4) - 1 ]) if $slot % 4;
    for my $dir (@dirs) {
        my ($ix, $iy) = ($parent->{ix} + $dir->[0] * $steps, $parent->{iy} + $dir->[1] * $steps);
        if (cell_free($d, $ix, $iy, $child->{iz})) { set_cell($d, $child, $ix, $iy); return }
    }
    for (my $k = 1; $k < 500; $k++) {
        my $ix = $parent->{ix} + $steps + $k;
        next unless cell_free($d, $ix, $parent->{iy}, $child->{iz});
        set_cell($d, $child, $ix, $parent->{iy});
        return;
    }
}

sub cell_free {
    my ($d, $ix, $iy, $iz) = @_;
    return !$d->{occ}{ occ_key($ix, $iy, $iz) };
}
sub set_cell {
    my ($d, $n, $ix, $iy) = @_;
    $n->{ix} = iround($ix);
    $n->{iy} = iround($iy);
    $d->{occ}{ occ_key($n->{ix}, $n->{iy}, $n->{iz}) } = $n->{name};
}
sub rebuild_occ {
    my $d = shift;
    $d->{occ} = {};
    for my $name (@{ $d->{node_order} }) {
        my $n = $d->{nodes}{$name};
        next unless defined $n->{ix};
        $d->{occ}{ occ_key($n->{ix}, $n->{iy}, $n->{iz}) } = $name;
    }
}
sub occ_key { sprintf '%d,%d,%.4f', iround($_[0]), iround($_[1]), $_[2] }
sub iround { my $x = shift; return int($x >= 0 ? $x + 0.5 : $x - 0.5) }

sub elev_metres {
    my ($d, $n) = @_;
    my $m = HardyCross::Phc::length_metres($n->{elev}, $d->{units}{ELEVATION});
    return defined $m ? $m : 0;
}

#------------------------------------------------------------------------------
# write_network -- the network text of a drawing, //ISO lines first.
#
# Empty is an empty string, as a new editor buffer is.  Otherwise the text
# ends with a newline.
#------------------------------------------------------------------------------
sub write_network {
    my $d = shift;
    my @out;
    push @out, '//ISO GRID ' . clean_num($d->{grid} || 1);
    for my $name (@{ $d->{node_order} }) {
        my $n = $d->{nodes}{$name};
        next unless defined $n->{ix};
        push @out, sprintf '//ISO %s %d %d %s', $name, $n->{ix}, $n->{iy}, clean_num($n->{iz});
    }
    for my $name (@{ $d->{node_order} }) {
        my $n = $d->{nodes}{$name};
        my @f = ($n->{name}, $n->{elev});
        if ($n->{kind} eq 'WATER') { push @f, $n->{static}, @{ $n->{pairs} || [] } }
        elsif ($n->{kind} ne 'NODE') { push @f, $n->{minflow}, $n->{k} }
        push @out, emit(sprintf('%-9s %s', $n->{kind}, join(' ', @f)), $n->{note});
    }
    for my $f (@{ $d->{flows} }) {
        my @f_ = ($f->{name}, $f->{node}, $f->{flow});
        push @f_, $f->{minp} if defined $f->{minp} && $f->{minp} ne '';
        push @out, emit(sprintf('%-9s %s', 'FIXEDFLOW', join(' ', @f_)), $f->{note});
    }
    my $prev = "BORE\0";          # the use a pipe has when no USE was written
    for my $p (@{ $d->{pipes} }) {
        my $key = $p->{use_type} . "\0" . (defined $p->{use_c} ? $p->{use_c} : '');
        if ($key ne $prev) {
            my @u = ($p->{use_type});
            push @u, $p->{use_c} if defined $p->{use_c} && $p->{use_c} ne '';
            push @out, sprintf '%-9s %s', 'USE', join(' ', @u);
            $prev = $key;
        }
        push @out, emit(sprintf('%-9s %s', 'PIPE', join(' ', $p->{name}, $p->{start}, $p->{end},
            $p->{len}, $p->{size}, @{ $p->{fits} || [] })), $p->{note});
        push @out, emit(sprintf('%-9s %s %s', 'EQV', $p->{name}, $p->{eqv}), $p->{eqv_note})
            if defined $p->{eqv};
        if ($p->{device}) {
            push @out, sprintf '%-9s %s', $p->{device}{kind},
                join(' ', $p->{name}, @{ $p->{device}{args} || [] });
        }
    }
    for my $p (@{ $d->{pumps} }) {
        push @out, emit(sprintf('%-9s %s', 'PUMP', join(' ', $p->{name}, $p->{in}, $p->{out},
            $p->{churn}, @{ $p->{pairs} || [] })), $p->{note});
    }
    push @out, @{ $d->{extras} } if @{ $d->{extras} };
    return @out ? join("\n", @out) . "\n" : '';
}

sub emit {
    my ($line, $note) = @_;
    $line .= "  //$note" if defined $note && $note ne '';
    return $line;
}

#------------------------------------------------------------------------------
# The picture.  project and cell_at are inverses: a grid point drawn and
# picked again is the same point.  hit is what a click lands on.
#
# LOCK uses a whole-pixel step on each axis.  A floating cos(30) makes a long
# pipe's slope drift off the grid's, so the pipe looks bent beside the grid.
# The same integer step for every pipe on an axis keeps them parallel and
# straight.  Unlocked, the true 30 degrees is used, and a pipe is the one
# straight line between its ends even when that line is on no axis.
#------------------------------------------------------------------------------
sub _basis {
    my $view = shift;
    return unless $view && $view->{lock};
    my $s = $view->{scale} || 1;
    my $dx = int($s * $COS30 + 0.5); $dx = 1 if $dx < 1;
    my $dy = int($s * $SIN30 + 0.5); $dy = 1 if $dy < 1;
    my $dz = int($s + 0.5);          $dz = 1 if $dz < 1;
    return ($dx, $dy, $dz);
}

sub project {
    my ($ix, $iy, $iz, $view) = @_;
    my ($dx, $dy, $dz) = _basis($view);
    if ($dx) {
        return ($view->{ox} + ($ix - $iy) * $dx,
                $view->{oy} + ($ix + $iy) * $dy - $iz * $dz);
    }
    my $s = $view->{scale};
    my $sx = $view->{ox} + ($ix - $iy) * $s * $COS30;
    my $sy = $view->{oy} + ($ix + $iy) * $s * $SIN30 - $iz * $s;
    return ($sx, $sy);
}

sub cell_at {
    my ($sx, $sy, $view, $iz) = @_;
    $iz = 0 unless defined $iz;
    my ($dx, $dy, $dz) = _basis($view);
    my ($u, $v);
    if ($dx) {
        $u = ($sx - $view->{ox}) / $dx;
        $v = ($sy - $view->{oy} + $iz * $dz) / $dy;
    } else {
        my $s = $view->{scale} || 1;
        $u = ($sx - $view->{ox}) / ($s * $COS30);
        $v = ($sy - $view->{oy} + $iz * $s) / ($s * $SIN30);
    }
    return (iround(($u + $v) / 2), iround(($v - $u) / 2), $iz);
}

# axis_run -- the corners of a pipe drawn only along the grid axes, X then Y
# then Z.  A pipe already on one axis is just its two ends.  Each leg changes
# one coordinate, so each leg is straight on the isometric.
sub axis_run {
    my ($ax, $ay, $az, $bx, $by, $bz) = @_;
    my @p = ([$ax, $ay, $az]);
    if (abs($bx - $ax) > 1e-9) { $ax = $bx; push @p, [ $ax, $ay, $az ] }
    if (abs($by - $ay) > 1e-9) { $ay = $by; push @p, [ $ax, $ay, $az ] }
    if (abs($bz - $az) > 1e-6) { $az = $bz; push @p, [ $ax, $ay, $az ] }
    return @p;
}

sub hit {
    my ($d, $sx, $sy, $view, $node_r, $pipe_r) = @_;
    $node_r = 14 unless defined $node_r;
    $pipe_r = 8 unless defined $pipe_r;
    my ($best, $bestd);
    for my $name (@{ $d->{node_order} }) {
        my $n = $d->{nodes}{$name};
        next unless defined $n->{ix};
        my ($x, $y) = project($n->{ix}, $n->{iy}, $n->{iz}, $view);
        my $dist = hypot($sx - $x, $sy - $y);
        next if $dist > $node_r;
        if (!defined $bestd || $dist < $bestd) { $bestd = $dist; $best = { kind => 'node', name => $name } }
    }
    return $best if $best;
    for my $p (@{ $d->{pipes} }, map { { name => $_->{name}, start => $_->{in}, end => $_->{out}, pump => 1 } } @{ $d->{pumps} }) {
        my ($a, $b) = ($d->{nodes}{ $p->{start} }, $d->{nodes}{ $p->{end} });
        next unless $a && $b && defined $a->{ix} && defined $b->{ix};
        my @run = $view->{lock}
            ? axis_run($a->{ix}, $a->{iy}, $a->{iz}, $b->{ix}, $b->{iy}, $b->{iz})
            : ([$a->{ix}, $a->{iy}, $a->{iz}], [$b->{ix}, $b->{iy}, $b->{iz}]);
        my $dist;
        for my $i (0 .. $#run - 1) {
            my ($x1, $y1) = project(@{ $run[$i] }, $view);
            my ($x2, $y2) = project(@{ $run[$i + 1] }, $view);
            my $d = seg_dist($sx, $sy, $x1, $y1, $x2, $y2);
            $dist = $d if !defined $dist || $d < $dist;
        }
        next unless defined $dist && $dist <= $pipe_r;
        if (!defined $bestd || $dist < $bestd) {
            $bestd = $dist;
            $best = { kind => $p->{pump} ? 'pump' : 'pipe', name => $p->{name} };
        }
    }
    return $best;
}

sub hypot { sqrt($_[0] * $_[0] + $_[1] * $_[1]) }
sub seg_dist {
    my ($px, $py, $x1, $y1, $x2, $y2) = @_;
    my ($dx, $dy) = ($x2 - $x1, $y2 - $y1);
    my $l2 = $dx * $dx + $dy * $dy;
    return hypot($px - $x1, $py - $y1) if $l2 < 1e-9;
    my $t = (($px - $x1) * $dx + ($py - $y1) * $dy) / $l2;
    $t = 0 if $t < 0;
    $t = 1 if $t > 1;
    return hypot($px - ($x1 + $t * $dx), $py - ($y1 + $t * $dy));
}

# snap_axis -- the grid point on one axis from $node, nearest the click.
# A pipe is drawn along one axis; the click chooses which, and how far.
sub snap_axis {
    my ($node, $ix, $iy, $iz) = @_;
    my ($dx, $dy, $dz) = ($ix - $node->{ix}, $iy - $node->{iy}, $iz - $node->{iz});
    my ($ax, $ay, $az) = (abs($dx), abs($dy), abs($dz));
    return ($node->{ix}, $node->{iy}, $node->{iz}) if $ax < 1e-9 && $ay < 1e-9 && $az < 1e-9;
    if ($ax >= $ay && $ax >= $az) { return (iround($ix), $node->{iy}, $node->{iz}) }
    if ($ay >= $ax && $ay >= $az) { return ($node->{ix}, iround($iy), $node->{iz}) }
    return ($node->{ix}, $node->{iy}, $iz);
}

# steps_for_length -- how many grid steps a typed length is.
# Blank is undef: the click chooses the cell, and the length follows it.
# A length that is not a length is undef as well; known_ok says which.
# Zero stays zero (a device, not a point stacked on its start).  Anything
# shorter than half a step is still one step, so the two ends do not sit
# on top of each other; the typed length is what gets stored.
sub steps_for_length {
    my ($d, $token) = @_;
    return undef if !defined $token || $token !~ /\S/;
    my $m = HardyCross::Phc::length_metres($token, $d->{units}{LENGTH});
    return undef unless defined $m && $m >= 0;
    return 0 if $m == 0;
    my $steps = iround($m / ($d->{grid} || 1));
    return $steps < 1 ? 1 : $steps;
}

# cell_along -- $steps from $node, on the one axis the click chose.
# ($ix, $iy, $iz) is only the direction.  A click with no direction comes
# back as the node's own cell, and the window asks for a click along an axis.
sub cell_along {
    my ($node, $ix, $iy, $iz, $steps) = @_;
    my ($sx, $sy, $sz) = snap_axis($node, $ix, $iy, $iz);
    my ($dx, $dy, $dz) = ($sx - $node->{ix}, $sy - $node->{iy}, $sz - $node->{iz});
    $steps = iround($steps || 0);
    $steps = 0 if $steps < 0;
    if (abs($dx) >= 1e-9) {
        return ($node->{ix} + ($dx > 0 ? $steps : -$steps), $node->{iy}, $node->{iz});
    }
    if (abs($dy) >= 1e-9) {
        return ($node->{ix}, $node->{iy} + ($dy > 0 ? $steps : -$steps), $node->{iz});
    }
    if (abs($dz) > 1e-6) {
        return ($node->{ix}, $node->{iy}, $node->{iz} + ($dz > 0 ? $steps : -$steps));
    }
    return ($node->{ix}, $node->{iy}, $node->{iz});
}

# known_ok -- a length, size and C typed ahead of the click, or a blank.
# Blank means "use what the click, or the last pipe, would have used".
sub known_ok {
    my ($d, $known) = @_;
    return '' unless $known && ref $known eq 'HASH';
    if (defined $known->{len} && $known->{len} =~ /\S/) {
        my $m = HardyCross::Phc::length_metres($known->{len}, $d->{units}{LENGTH});
        return 'LENGTH IS NOT A LENGTH' unless defined $m;
        return 'A LENGTH CANNOT BE NEGATIVE' if $m < 0;
    }
    if (defined $known->{size} && $known->{size} =~ /\S/) {
        return 'SIZE IS NOT A NUMBER' unless HardyCross::Parse::is_num($known->{size}) && $known->{size} >= 0;
    }
    if (defined $known->{c} && $known->{c} =~ /\S/) {
        return 'C IS NOT A NUMBER' unless HardyCross::Parse::is_num($known->{c}) && $known->{c} >= 0;
    }
    return '';
}

sub axis_aligned {
    my ($a, $b) = @_;
    return 0 unless defined $a->{ix} && defined $b->{ix};
    my $n = (abs($a->{ix} - $b->{ix}) > 1e-9 ? 1 : 0)
          + (abs($a->{iy} - $b->{iy}) > 1e-9 ? 1 : 0)
          + (abs($a->{iz} - $b->{iz}) > 1e-6 ? 1 : 0);
    return $n == 1;
}

sub node_at {
    my ($d, $ix, $iy, $iz) = @_;
    return $d->{occ}{ occ_key($ix, $iy, $iz) };
}

# geom_metres -- the length a pipe has on the grid, in metres.
sub geom_metres {
    my ($d, $p) = @_;
    my ($a, $b) = ($d->{nodes}{ $p->{start} }, $d->{nodes}{ $p->{end} });
    return undef unless $a && $b && defined $a->{ix} && defined $b->{ix};
    my $g = $d->{grid} || 1;
    my ($dx, $dy, $dz) = (($a->{ix} - $b->{ix}) * $g, ($a->{iy} - $b->{iy}) * $g, ($a->{iz} - $b->{iz}) * $g);
    return sqrt($dx * $dx + $dy * $dy + $dz * $dz);
}

#------------------------------------------------------------------------------
# Editing.  Each returns an empty string, or the reason it refused, in
# capitals, for the status line.  add_node and add_pipe and add_pump also
# return the new name.
#------------------------------------------------------------------------------
sub add_node {
    my ($d, $kind, $ix, $iy, $iz, $elev) = @_;
    return 'UNKNOWN POINT' unless $NODE_KIND{$kind};
    $ix = iround($ix); $iy = iround($iy);
    $iz = 0 unless defined $iz;
    return 'THAT POINT IS ALREADY USED' if node_at($d, $ix, $iy, $iz);
    $elev = metres_to_token($d, $iz * ($d->{grid} || 1), 'ELEVATION') if !defined $elev || $elev eq '';
    my $m = HardyCross::Phc::length_metres($elev, $d->{units}{ELEVATION});
    return 'ELEVATION IS NOT AN ELEVATION' unless defined $m;
    my $name = fresh_node($d, { NODE => 'N', WATER => 'W', SPRINKLER => 'S', HYDRANT => 'H', HREEL => 'R' }->{$kind});
    my $n = { name => $name, kind => $kind, elev => $elev, ix => $ix, iy => $iy, iz => $iz, pairs => [] };
    if ($kind eq 'WATER') { $n->{static} = '500' }
    elsif ($kind eq 'SPRINKLER') { $n->{minflow} = '-50'; $n->{k} = '80' }
    elsif ($kind eq 'HYDRANT')   { $n->{minflow} = '400'; $n->{k} = '80' }
    elsif ($kind eq 'HREEL')     { $n->{minflow} = '20';  $n->{k} = '30' }
    $d->{nodes}{$name} = $n;
    push @{ $d->{node_order} }, $name;
    rebuild_occ($d);
    return ('', $name);
}

# $known, when given, is what was typed before the click: len, size, fits, c.
# A blank field is the ordinary default (the grid distance, the office size,
# no fittings, the previous pipe's C).  A filled field is stored as typed,
# including a length that the grid had to round to whole steps.
sub add_pipe {
    my ($d, $start, $end, $known) = @_;
    my $err = ends_ok($d, $start, $end);
    return $err if $err;
    $err = known_ok($d, $known);
    return $err if $err;
    my ($a, $b) = ($d->{nodes}{$start}, $d->{nodes}{$end});
    return 'A PIPE RUNS ALONG ONE GRID AXIS' unless axis_aligned($a, $b);
    $known ||= {};
    my $name = fresh_link($d, 'P');
    my $use = @{ $d->{pipes} } ? $d->{pipes}[-1] : { use_type => 'BORE', use_c => '120' };
    my $size = $d->{units}{SIZE} eq 'IN' ? '1' : '25';
    $size = $known->{size} if defined $known->{size} && $known->{size} =~ /\S/;
    my $fits = (defined $known->{fits} && $known->{fits} =~ /\S/)
        ? [ grep { length } split /\s+/, $known->{fits} ] : [];
    my $c = $use->{use_c};
    $c = $known->{c} if defined $known->{c} && $known->{c} =~ /\S/;
    my $p = { name => $name, start => $start, end => $end, size => $size,
              fits => $fits, use_type => $use->{use_type}, use_c => $c };
    if (defined $known->{len} && $known->{len} =~ /\S/) {
        $p->{len} = $known->{len};
    } else {
        $p->{len} = metres_to_token($d, geom_metres($d, $p), 'LENGTH');
    }
    push @{ $d->{pipes} }, $p;
    return ('', $name);
}

sub add_pump {
    my ($d, $in, $out) = @_;
    my $err = ends_ok($d, $in, $out);
    return $err if $err;
    return 'A PUMP RUNS ALONG ONE GRID AXIS' unless axis_aligned($d->{nodes}{$in}, $d->{nodes}{$out});
    my $name = fresh_link($d, 'PU');
    push @{ $d->{pumps} }, { name => $name, in => $in, out => $out, churn => '800', pairs => [ '1000', '700' ] };
    return ('', $name);
}

sub add_fixedflow {
    my ($d, $node) = @_;
    return 'CHOOSE A POINT FOR THE FIXED FLOW' unless $d->{nodes}{$node};
    my $name = fresh_link($d, 'F');
    push @{ $d->{flows} }, { name => $name, node => $node, flow => '100' };
    return ('', $name);
}

sub ends_ok {
    my ($d, $a, $b) = @_;
    return 'CHOOSE TWO POINTS' unless $d->{nodes}{$a} && $d->{nodes}{$b};
    return 'A PIPE NEEDS TWO POINTS' if $a eq $b;
    return '';
}

sub move_node {
    my ($d, $name, $ix, $iy, $iz) = @_;
    my $n = $d->{nodes}{$name} or return 'NO SUCH POINT';
    $ix = iround($ix); $iy = iround($iy);
    $iz = $n->{iz} unless defined $iz;
    my $at = node_at($d, $ix, $iy, $iz);
    return 'THAT POINT IS ALREADY USED' if $at && $at ne $name;
    my $z_moved = abs($iz - $n->{iz}) > 1e-9;
    $n->{ix} = $ix; $n->{iy} = $iy; $n->{iz} = $iz;
    if ($z_moved) {
        $n->{elev} = metres_to_token($d, $iz * ($d->{grid} || 1), 'ELEVATION');
    }
    rebuild_occ($d);
    retouch($d, $name);
    return '';
}

# retouch -- pipes on a point take their length from the grid.  The typed
# length was a picture of the old geometry; the point has moved.
sub retouch {
    my ($d, $name) = @_;
    for my $p (@{ $d->{pipes} }) {
        next unless $p->{start} eq $name || $p->{end} eq $name;
        my $m = geom_metres($d, $p);
        $p->{len} = metres_to_token($d, $m, 'LENGTH') if defined $m;
    }
}

sub delete_item {
    my ($d, $kind, $name) = @_;
    if ($kind eq 'node') {
        return 'NO SUCH POINT' unless $d->{nodes}{$name};
        @{ $d->{pipes} } = grep { $_->{start} ne $name && $_->{end} ne $name } @{ $d->{pipes} };
        @{ $d->{pumps} } = grep { $_->{in} ne $name && $_->{out} ne $name } @{ $d->{pumps} };
        @{ $d->{flows} } = grep { $_->{node} ne $name } @{ $d->{flows} };
        delete $d->{nodes}{$name};
        @{ $d->{node_order} } = grep { $_ ne $name } @{ $d->{node_order} };
        # An AREA line naming it stays, and VALIDATE will say so.
    } elsif ($kind eq 'pipe') {
        my $had = grep { $_->{name} eq $name } @{ $d->{pipes} };
        return 'NO SUCH PIPE' unless $had;
        @{ $d->{pipes} } = grep { $_->{name} ne $name } @{ $d->{pipes} };
    } elsif ($kind eq 'pump') {
        my $had = grep { $_->{name} eq $name } @{ $d->{pumps} };
        return 'NO SUCH PUMP' unless $had;
        @{ $d->{pumps} } = grep { $_->{name} ne $name } @{ $d->{pumps} };
    } else {
        return 'NOTHING TO DELETE';
    }
    rebuild_occ($d);
    return '';
}

sub set_node {
    my ($d, $name, $field, $value) = @_;
    my $n = $d->{nodes}{$name} or return 'NO SUCH POINT';
    $value = '' unless defined $value;
    $value =~ s/^\s+|\s+\z//g;
    if ($field eq 'NAME') {
        return '' if $value eq $name;
        return 'END CANNOT BE A NAME' if uc $value eq 'END';
        return 'A NAME CANNOT CONTAIN A SPACE OR ~' if $value =~ /\s|~/ || $value eq '';
        return 'THAT NAME IS USED' if $d->{nodes}{$value};
        $d->{nodes}{$value} = $n;
        delete $d->{nodes}{$name};
        $n->{name} = $value;
        $_ = $value for grep { $_ eq $name } @{ $d->{node_order} };
        for my $p (@{ $d->{pipes} }) {
            $p->{start} = $value if $p->{start} eq $name;
            $p->{end} = $value if $p->{end} eq $name;
        }
        for my $p (@{ $d->{pumps} }) {
            $p->{in} = $value if $p->{in} eq $name;
            $p->{out} = $value if $p->{out} eq $name;
        }
        for my $f (@{ $d->{flows} }) { $f->{node} = $value if $f->{node} eq $name }
        @{ $d->{extras} } = map { rename_token($_, $name, $value) } @{ $d->{extras} };
        rebuild_occ($d);
        return '';
    }
    if ($field eq 'ELEVATION') {
        my $m = HardyCross::Phc::length_metres($value, $d->{units}{ELEVATION});
        return 'ELEVATION IS NOT AN ELEVATION' unless defined $m;
        my $iz = $m / ($d->{grid} || 1);
        my $at = node_at($d, $n->{ix}, $n->{iy}, $iz);
        return 'THAT POINT IS ALREADY USED' if $at && $at ne $name;
        $n->{elev} = $value;
        $n->{iz} = $iz;
        rebuild_occ($d);
        retouch($d, $name);
        return '';
    }
    if ($field eq 'STATIC') {
        return 'STATIC IS NOT A PRESSURE' unless HardyCross::Parse::is_num($value) && $value >= 0;
        $n->{static} = $value;
        return '';
    }
    if ($field eq 'MINFLOW') {
        return 'MIN FLOW IS NOT A NUMBER' unless HardyCross::Parse::is_num($value);
        $n->{minflow} = $value;
        return '';
    }
    if ($field eq 'K') {
        return 'K IS NOT A K-FACTOR' unless HardyCross::Parse::is_num($value) && $value >= 0;
        $n->{k} = $value;
        return '';
    }
    return 'NO SUCH FIELD';
}

sub set_pipe {
    my ($d, $name, $field, $value) = @_;
    my ($p) = grep { $_->{name} eq $name } @{ $d->{pipes} };
    return 'NO SUCH PIPE' unless $p;
    $value = '' unless defined $value;
    $value =~ s/^\s+|\s+\z//g;
    if ($field eq 'NAME') {
        return '' if $value eq $name;
        return 'END CANNOT BE A NAME' if uc $value eq 'END';
        return 'A NAME CANNOT CONTAIN A SPACE OR ~' if $value =~ /\s|~/ || $value eq '';
        return 'THAT NAME IS USED' if link_taken($d, $value);
        $p->{name} = $value;
        return '';
    }
    if ($field eq 'LENGTH') {
        my $m = HardyCross::Phc::length_metres($value, $d->{units}{LENGTH});
        return 'LENGTH IS NOT A LENGTH' unless defined $m;
        return 'A LENGTH CANNOT BE NEGATIVE' if $m < 0;
        # An axis pipe's end slides so the picture matches the typed length.
        # Zero is stored and the end stays: a device is not two stacked points.
        # retouch would replace the typed token with the grid distance, so the
        # token is put back after the move.  A length that is not a whole
        # number of steps stays as typed.
        my ($a, $b) = ($d->{nodes}{ $p->{start} }, $d->{nodes}{ $p->{end} });
        if ($m > 0 && $a && $b && axis_aligned($a, $b)) {
            my $steps = steps_for_length($d, $value);
            my ($nx, $ny, $nz) = cell_along($a, $b->{ix}, $b->{iy}, $b->{iz}, $steps);
            my $same = abs($nx - $b->{ix}) < 1e-9 && abs($ny - $b->{iy}) < 1e-9 && abs($nz - $b->{iz}) < 1e-6;
            unless ($same) {
                my $at = node_at($d, $nx, $ny, $nz);
                return 'THAT POINT IS ALREADY USED' if $at && $at ne $p->{end};
                my $move = move_node($d, $p->{end}, $nx, $ny, $nz);
                return $move if $move;
            }
        }
        $p->{len} = $value;
        return '';
    }
    if ($field eq 'SIZE') {
        return 'SIZE IS NOT A NUMBER' unless HardyCross::Parse::is_num($value) && $value >= 0;
        $p->{size} = $value;
        delete $p->{note} if defined $p->{note} && $p->{note} =~ /^AS\b/i;
        return '';
    }
    if ($field eq 'FITTINGS') {
        $p->{fits} = [ grep { length } split /\s+/, $value ];
        return '';
    }
    if ($field eq 'TYPE') {
        my $t = uc $value;
        return 'GIVE A PIPE TYPE, OR BORE' if $t eq '';
        return 'UNKNOWN PIPE TYPE' unless known_type($t);
        $p->{use_type} = $t;
        return '';
    }
    if ($field eq 'C') {
        if ($value eq '') { $p->{use_c} = undef; return '' }
        return 'C IS NOT A NUMBER' unless HardyCross::Parse::is_num($value) && $value >= 0;
        $p->{use_c} = $value;
        return '';
    }
    if ($field eq 'EQV') {
        if ($value eq '') { delete $p->{eqv}; return '' }
        my $m = HardyCross::Phc::length_metres($value, $d->{units}{LENGTH});
        return 'EQV IS NOT A LENGTH' unless defined $m && $m >= 0;
        $p->{eqv} = $value;
        return '';
    }
    return 'NO SUCH FIELD';
}

sub set_pump {
    my ($d, $name, $field, $value) = @_;
    my ($p) = grep { $_->{name} eq $name } @{ $d->{pumps} };
    return 'NO SUCH PUMP' unless $p;
    $value = '' unless defined $value;
    $value =~ s/^\s+|\s+\z//g;
    if ($field eq 'NAME') {
        return '' if $value eq $name;
        return 'END CANNOT BE A NAME' if uc $value eq 'END';
        return 'A NAME CANNOT CONTAIN A SPACE OR ~' if $value =~ /\s|~/ || $value eq '';
        return 'THAT NAME IS USED' if link_taken($d, $value);
        $p->{name} = $value;
        return '';
    }
    return 'NOT A PRESSURE' if $field eq 'CHURN' && !(HardyCross::Parse::is_num($value) && $value >= 0);
    return 'NOT A NUMBER' if $field =~ /^(FLOW|PRESSURE)\z/ && !(HardyCross::Parse::is_num($value) && $value >= 0);
    $p->{churn} = $value if $field eq 'CHURN';
    $p->{pairs}[0] = $value if $field eq 'FLOW';
    $p->{pairs}[1] = $value if $field eq 'PRESSURE';
    return 'NO SUCH FIELD' unless $field =~ /^(CHURN|FLOW|PRESSURE)\z/;
    return '';
}

sub set_grid {
    my ($d, $value) = @_;
    return 'GRID MUST BE METRES GREATER THAN ZERO' unless HardyCross::Parse::is_num($value) && $value > 0;
    $d->{grid} = $value + 0;
    # Points keep their steps.  A length already typed is left until a point
    # is moved; a new pipe uses the new step.
    return '';
}

sub known_type {
    my $t = shift;
    return 1 if $t eq 'BORE';
    eval { HardyCross::PipeData::load() };
    return grep { $_ eq $t } HardyCross::PipeData::pipe_types();
}

sub fresh_node {
    my ($d, $prefix) = @_;
    my $i = 1;
    $i++ while $d->{nodes}{ $prefix . $i };
    return $prefix . $i;
}
sub fresh_link {
    my ($d, $prefix) = @_;
    my $i = 1;
    $i++ while link_taken($d, $prefix . $i);
    return $prefix . $i;
}
sub link_taken {
    my ($d, $name) = @_;
    return 1 if grep { $_->{name} eq $name } @{ $d->{pipes} }, @{ $d->{pumps} }, @{ $d->{flows} };
    return 0;
}

# rename_token -- a whole field equal to the old name.  A comment is left,
# apart from a token of its own, so a note that names the point follows it.
sub rename_token {
    my ($line, $old, $new) = @_;
    my ($code, $com) = split m{//}, $line, 2;
    my @tk = split /(\s+)/, $code;
    $_ eq $old and $_ = $new for @tk;
    my $out = join '', @tk;
    $out .= '//' . $com if defined $com;
    return $out;
}

sub metres_to_token {
    my ($d, $metres, $quantity) = @_;
    my $unit = $d->{units}{$quantity} || 'M';
    my $f = $TO_METRE{$unit} || 1;
    return clean_num($metres / $f);
}
sub clean_num {
    my $s = sprintf '%.6f', $_[0] + 0;
    $s =~ s/0+\z//;
    $s =~ s/\.\z//;
    return $s;
}

1;
