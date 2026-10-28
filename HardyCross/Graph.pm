#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# HardyCross/Graph.pm -- a Q^1.85 water supply graph, made by hand.
#
# WHAT THIS IS
#   The editor's GRAPH tab: a water supply graph drawn from figures typed in,
#   independent of any calculation.  It answers the question asked before a
#   network is modelled, or from another program's results: does this supply,
#   with this pump, meet these duties?
#
#   Five curves, all pressure against flow:
#     A  the water supply as measured (a flow test), at the test point
#     B  the loss from the supply to the datum the duties are stated at --
#        pipework, meter, backflow device, height; a single point is a loss
#        line through the origin, rising as flow^1.85
#     C  the supply available at the datum: A - B
#     D  a pump curve, from churn (no flow) out
#     E  the supply available at the datum with the pump: C + D
#   and up to ten DUTY points -- a flow needed at a pressure -- each compared
#   with the curve designed against (E with a pump, C without): the pressure
#   available at its flow, and the margin.
#
#   Every curve passes through the points entered and is straight between
#   them on this paper -- linear in flow^1.85 -- by the engine's own curve
#   (HardyCross::fit_curve and curve_eval), the same rule as a supply or pump
#   in a model.  Beyond its last point a curve continues in a straight line
#   in flow.  Pressures and flows are added and subtracted at equal flow;
#   nothing else is assumed.
#
#   Units are L/min and kPa.
#
# THE FILE
#   A graph is saved as a .phg file: plain text, one line per item, in the
#   same spirit as .phc -- a keyword and its fields:
#     PROJECT <text>   JOB <text>   DATE <text>   BY <text>
#     PMAX <kPa>       PSTEP <kPa>  QMAX <L/min>
#     A <flow> <pressure>     (one line per point; likewise B and D)
#     DUTY <flow> <pressure> <label> <description ...>
#   Lines starting // are comments.
#
# HOW IT IS LAID OUT
#   new_graph            an empty graph: the fields the tab edits, as text
#   check                every field checked; the numbers, and what is wrong
#   series               the curves and duties worked out for drawing
#   read_file/write_file the .phg file
#   write_pdf            the graph on an A4 landscape sheet, in the report's
#                        typeface and frame (HardyCross::PDF)
#==============================================================================
package HardyCross::Graph;

use strict;
use warnings;
use POSIX ();
use HardyCross;
use HardyCross::PDF;
use HardyCross::Report;       # nice_ticks: the same round gridlines as the report

our $ROWS      = 8;      # points per curve
our $DUTY_ROWS = 10;     # duty points
our @CURVES    = qw(A B D);
our %CURVE_NAME = (
    A => 'WATER SUPPLY, AS MEASURED',
    B => 'LOSS, SUPPLY TO DATUM',
    C => 'AVAILABLE AT DATUM (A - B)',
    D => 'PUMP',
    E => 'WITH THE PUMP, AT DATUM (C + D)',
);
our @PROJECT = qw(PROJECT JOB DATE BY);
our %PROJECT_LABEL = (PROJECT => 'PROJECT', JOB => 'JOB NO', DATE => 'DATE', BY => 'PREPARED BY');
our @AXIS = qw(PMAX PSTEP QMAX);
our %AXIS_LABEL = (PMAX => 'PRESSURE AXIS TO, KPA', PSTEP => 'PRESSURE GRIDLINES EVERY, KPA',
                   QMAX => 'FLOW AXIS TO, L/MIN');

#------------------------------------------------------------------------------
# new_graph -- an empty graph.  Every field is text, as typed, so the tab can
# hold exactly what the user wrote, mistakes included, until it is checked.
#   project  { PROJECT, JOB, DATE, BY }
#   axis     { PMAX, PSTEP, QMAX }     blank: worked out from the figures
#   A, B, D  [ [flow, pressure] x $ROWS ]
#   duty     [ [label, description, flow, pressure] x $DUTY_ROWS ]
#------------------------------------------------------------------------------
sub new_graph {
    return {
        project => { map { $_ => '' } @PROJECT },
        axis    => { map { $_ => '' } @AXIS },
        (map { my $c = $_; ($c => [ map { [ '', '' ] } 1 .. $ROWS ]) } @CURVES),
        duty    => [ map { [ '', '', '', '' ] } 1 .. $DUTY_ROWS ],
    };
}

sub is_num { defined $_[0] && $_[0] =~ /^\s*[-+]?(\d+\.?\d*|\.\d+)([eE][-+]?\d+)?\s*\z/ }
sub blank  { !defined $_[0] || $_[0] !~ /\S/ }

#------------------------------------------------------------------------------
# check -- every field checked.  Returns
#   { ok, errors => [ [field, message] ],
#     points => { A|B|D => [ [q, p] ] },  curve => { A|B|D => fitted or undef },
#     duty => [ { label, desc, q, p, row } ], axis => { PMAX, PSTEP, QMAX } }
# A field is named as the tab names it: A3 (curve A, row 3, either column),
# DUTY2, PMAX.  Each message says what is wrong and how to put it right.
#------------------------------------------------------------------------------
sub check {
    my $g = shift;
    my (@err, %pts, %curve, @duty, %axis);
    my $bad = sub { push @err, [ @_ ] };

    for my $c (@CURVES) {
        my @rows = @{ $g->{$c} };
        my ($gap, @p);
        for my $i (0 .. $#rows) {
            my ($q, $p) = @{ $rows[$i] };
            my $f = "$c" . ($i + 1);
            if (blank($q) && blank($p)) { $gap //= $i + 1; next }
            if (blank($q) || blank($p)) { $bad->($f, "$c ROW " . ($i + 1) . ': FLOW AND PRESSURE ARE BOTH NEEDED'); next }
            unless (is_num($q) && is_num($p)) {
                $bad->($f, "$c ROW " . ($i + 1) . ': ' . (is_num($q) ? "PRESSURE '$p'" : "FLOW '$q'") . ' IS NOT A NUMBER');
                next;
            }
            if (defined $gap) {
                $bad->($f, "$c ROW " . ($i + 1) . ": ROW $gap IS EMPTY - FILL THE ROWS IN ORDER, WITH NO GAPS");
                $gap = undef;
            }
            if ($q < 0) { $bad->($f, "$c ROW " . ($i + 1) . ': A FLOW CANNOT BE NEGATIVE'); next }
            if ($p < 0) { $bad->($f, "$c ROW " . ($i + 1) . ': A PRESSURE CANNOT BE NEGATIVE'); next }
            if (@p && $q <= $p[-1][0]) {
                $bad->($f, "$c ROW " . ($i + 1) . ': FLOWS MUST RISE FROM ROW TO ROW, WITH NO FLOW TWICE');
                next;
            }
            push @p, [ $q + 0, $p + 0 ];
        }
        $pts{$c} = \@p;
    }
    $bad->('A1', 'A, THE WATER SUPPLY, NEEDS AT LEAST TWO POINTS') if @{ $pts{A} } < 2;
    $bad->('D2', 'D, THE PUMP, NEEDS AT LEAST TWO POINTS - OR NONE, FOR NO PUMP') if @{ $pts{D} } == 1;
    $bad->('D1', 'D ROW 1: A PUMP CURVE STARTS AT CHURN - 0 L/MIN')
        if @{ $pts{D} } && $pts{D}[0][0] != 0;

    # The curves, by the engine's own rule.  A single loss point is a line
    # through the origin, rising as flow^1.85.
    unless (grep { $_->[0] =~ /^[AD]/ } @err) {
        for my $c (qw(A D)) {
            next unless @{ $pts{$c} } >= 2;
            $curve{$c} = fit($pts{$c}, 0);
        }
    }
    unless (grep { $_->[0] =~ /^B/ } @err) {
        my @b = @{ $pts{B} };
        unshift @b, [ 0, 0 ] if @b == 1 && $b[0][0] > 0;
        $curve{B} = fit(\@b, 1) if @b >= 2;
    }

    for my $i (0 .. $#{ $g->{duty} }) {
        my ($label, $desc, $q, $p) = @{ $g->{duty}[$i] };
        my $f = 'DUTY' . ($i + 1);
        next if blank($label) && blank($desc) && blank($q) && blank($p);
        if (blank($q) || blank($p)) { $bad->($f, 'DUTY ROW ' . ($i + 1) . ': FLOW AND PRESSURE ARE BOTH NEEDED'); next }
        unless (is_num($q) && is_num($p)) {
            $bad->($f, 'DUTY ROW ' . ($i + 1) . ': ' . (is_num($q) ? "PRESSURE '$p'" : "FLOW '$q'") . ' IS NOT A NUMBER');
            next;
        }
        if ($q < 0) { $bad->($f, 'DUTY ROW ' . ($i + 1) . ': A FLOW CANNOT BE NEGATIVE'); next }
        push @duty, { label => (blank($label) ? $i + 1 : clean($label)), desc => clean($desc // ''),
                      q => $q + 0, p => $p + 0, row => $i + 1 };
    }

    for my $k (@AXIS) {
        my $v = $g->{axis}{$k};
        next if blank($v);
        if (!is_num($v) || $v <= 0) { $bad->($k, "$AXIS_LABEL{$k}: '$v' MUST BE A NUMBER ABOVE ZERO, OR BLANK"); next }
        $axis{$k} = $v + 0;
    }
    return { ok => !@err, errors => \@err, points => \%pts, curve => \%curve, duty => \@duty, axis => \%axis };
}

# clean -- text for the sheet: printable ASCII, capitals, single spaces.
sub clean {
    (my $t = uc(shift // '')) =~ s/[^\x20-\x7E]+/ /g;
    $t =~ s/\s+/ /g;
    $t =~ s/^ | \z//g;
    return $t;
}

# fit -- a curve through [ [q, p] ... ] by HardyCross::fit_curve; $rising for
# a loss, which grows with flow.
sub fit {
    my ($pts, $rising) = @_;
    return HardyCross::fit_curve({ q => [ map { $_->[0] } @$pts ], p => [ map { $_->[1] } @$pts ] }, $rising);
}

#------------------------------------------------------------------------------
# series -- the graph worked out for drawing, from a check that passed:
#   qmax, pmax, xticks, yticks   the axes: flow 0 .. qmax on a flow^1.85
#                                scale, pressure 0 .. pmax
#   lines  { A B C D E => [ [q, p] ... ] }   each curve sampled finely along
#                                the flow^1.85 axis (B, D and E only if given)
#   points { A B D => [ [q, p] ] }    the points as entered
#   design 'E' or 'C', the curve the duties are compared with
#   duty   [ { label, desc, q, p, avail, margin } ]
#------------------------------------------------------------------------------
sub series {
    my $chk = shift;
    my %cv = %{ $chk->{curve} };
    my $ev = sub { my ($c, $q) = @_; $cv{$c} ? HardyCross::curve_eval($cv{$c}, $q) : 0 };
    my %at = (
        A => sub { $ev->('A', $_[0]) },
        B => sub { $ev->('B', $_[0]) },
        C => sub { $ev->('A', $_[0]) - $ev->('B', $_[0]) },
        D => sub { $ev->('D', $_[0]) },
        E => sub { $ev->('A', $_[0]) - $ev->('B', $_[0]) + $ev->('D', $_[0]) },
    );
    my $design = $cv{D} ? 'E' : 'C';

    # The flow axis: as set, or the largest flow entered rounded up to 100.
    my @q = (map({ map { $_->[0] } @$_ } values %{ $chk->{points} }), map { $_->{q} } @{ $chk->{duty} });
    my ($qbig) = sort { $b <=> $a } @q, 100;
    my $qmax = $chk->{axis}{QMAX} // 100 * POSIX::ceil($qbig / 100);

    my @names = ('A', ($cv{B} ? 'B' : ()), 'C', ($cv{D} ? ('D', 'E') : ()));
    my %lines;
    for my $n (@names) {
        $lines{$n} = [ map { my $q = $qmax * ($_ / 200) ** (1 / 1.85); [ $q, $at{$n}->($q) ] } 0 .. 200 ];
    }

    # The pressure axis: as set, or a tenth above the highest pressure shown,
    # to the gridline step.
    my ($pbig) = sort { $b <=> $a } (map { $_->[1] } map { @$_ } values %lines),
                                    (map { $_->{p} } @{ $chk->{duty} }), 100;
    my $pstep = $chk->{axis}{PSTEP};
    my $pmax = $chk->{axis}{PMAX};
    unless ($pmax) {
        my @t = HardyCross::Report::nice_ticks($pbig * 1.1, 8);
        $pstep //= @t > 1 ? $t[1] - $t[0] : $pbig;
        $pmax = $pstep * POSIX::ceil($pbig * 1.1 / $pstep);
    }
    my @yt = $pstep ? map { $_ * $pstep } 0 .. int($pmax / $pstep + 1e-9)
                    : HardyCross::Report::nice_ticks($pmax, 8);

    my @duty = map {
        my $a = $at{$design}->($_->{q});
        +{ %$_, avail => $a, margin => $a - $_->{p} }
    } @{ $chk->{duty} };

    return { qmax => $qmax, pmax => $pmax, design => $design, lines => \%lines,
             points => { map { $_ => $chk->{points}{$_} } grep { @{ $chk->{points}{$_} } } @CURVES },
             xticks => [ HardyCross::Report::nice_ticks($qmax, 10) ], yticks => \@yt, duty => \@duty };
}

#------------------------------------------------------------------------------
# The .phg file.
#------------------------------------------------------------------------------
sub write_file {
    my ($g, $path) = @_;
    my @l = ('// PHCP Q^1.85 WATER SUPPLY GRAPH', '');
    for my $k (@PROJECT) { push @l, sprintf '%-7s %s', $k, $g->{project}{$k} unless blank($g->{project}{$k}) }
    for my $k (@AXIS)    { push @l, sprintf '%-7s %s', $k, $g->{axis}{$k}    unless blank($g->{axis}{$k}) }
    for my $c (@CURVES) {
        push @l, '', "// $c - $CURVE_NAME{$c}: FLOW L/MIN, PRESSURE KPA";
        for my $r (@{ $g->{$c} }) {
            next if blank($r->[0]) && blank($r->[1]);
            push @l, sprintf '%-7s %s %s', $c, map { blank($_) ? '-' : $_ } @$r;
        }
    }
    push @l, '', '// DUTY: FLOW, PRESSURE, LABEL, DESCRIPTION';
    for my $r (@{ $g->{duty} }) {
        next unless grep { !blank($_) } @$r;
        my ($label, $desc, $q, $p) = @$r;
        push @l, join ' ', 'DUTY   ', (blank($q) ? '-' : $q), (blank($p) ? '-' : $p),
                           (blank($label) ? '-' : $label =~ s/\s+/_/gr), (blank($desc) ? () : $desc);
    }
    open my $fh, '>', $path or die "CANNOT WRITE $path: $!\n";
    print $fh map { "$_\n" } @l;
    close $fh;
    return 1;
}

# read_file -- a graph from a .phg file; dies with the line at fault.
sub read_file {
    my $path = shift;
    open my $fh, '<', $path or die "CANNOT READ $path: $!\n";
    my $g = new_graph();
    my %n = (A => 0, B => 0, D => 0, DUTY => 0);
    my $ln = 0;
    while (my $l = <$fh>) {
        $ln++;
        $l =~ s/\r?\n\z//;
        $l =~ s/[^\x20-\x7E]/ /g;
        next if $l =~ m{^\s*(//|$)};
        my ($k, $rest) = $l =~ /^\s*(\S+)\s*(.*?)\s*\z/;
        $k = uc $k;
        my $dash = sub { my $v = shift; defined $v && $v ne '-' ? $v : '' };
        if (grep { $_ eq $k } @PROJECT) { $g->{project}{$k} = $rest; next }
        if (grep { $_ eq $k } @AXIS)    { $g->{axis}{$k} = $rest; next }
        if (grep { $_ eq $k } @CURVES) {
            die "LINE $ln: MORE THAN $ROWS POINTS ON CURVE $k\n" if $n{$k} >= $ROWS;
            my ($q, $p) = split ' ', $rest;
            $g->{$k}[ $n{$k}++ ] = [ $dash->($q), $dash->($p) ];
            next;
        }
        if ($k eq 'DUTY') {
            die "LINE $ln: MORE THAN $DUTY_ROWS DUTY POINTS\n" if $n{DUTY} >= $DUTY_ROWS;
            my ($q, $p, $label, $desc) = split ' ', $rest, 4;
            $g->{duty}[ $n{DUTY}++ ] = [ $dash->($label) =~ s/_/ /gr, $desc // '', $dash->($q), $dash->($p) ];
            next;
        }
        die "LINE $ln: UNKNOWN WORD $k - A .PHG LINE STARTS WITH PROJECT JOB DATE BY PMAX PSTEP QMAX A B D OR DUTY\n";
    }
    close $fh;
    return $g;
}

#------------------------------------------------------------------------------
# write_pdf -- the graph on one A4 landscape sheet: the report's frame and
# typeface; the plot on the left; on the right the key, the duty points with
# the pressure available to each and its margin, and the points entered.
#
# Black on white, so it prints and photocopies.  The curve designed against
# (E with a pump, C without) is the heavy solid line; the others are lighter
# or dashed, each named at its right-hand end.  Each element is preceded by a
# comment (% PHCP-SHEET ...) giving where it was drawn, which a PDF reader
# ignores and tools/test_graph.pl checks.
#------------------------------------------------------------------------------
sub write_pdf {
    my ($g, $path, %meta) = @_;
    my $chk = check($g);
    die join("\n", map { $_->[1] } @{ $chk->{errors} }) . "\n" unless $chk->{ok};
    my $sr = series($chk);
    my ($reg, $bold) = HardyCross::PDF::fonts();
    my $geo = HardyCross::PDF::geometry();
    my ($L, $cw, $adv) = @{$geo}{qw(left char_w advance)};
    my $R = $L + $geo->{cols} * $cw;
    my $esc = \&HardyCross::PDF::esc;
    my $txt = sub {
        my ($x, $y, $t, $size, $b, $al) = @_;
        my $w = length($t) * $adv * $size;
        $x -= ($al // 'l') eq 'r' ? $w : ($al // 'l') eq 'c' ? $w / 2 : 0;
        sprintf "BT /F%d %s Tf %.2f %.2f Td (%s) Tj ET\n", $b ? 2 : 1, $size, $x, $y, $esc->($t);
    };
    my $pj = $g->{project};
    my %m = (header => 'PHCP  Q^1.85 WATER SUPPLY GRAPH', title => clean($pj->{PROJECT}),
             job => clean($pj->{JOB}), date => clean($pj->{DATE}), designer => clean($pj->{BY}),
             program => $meta{program} // "PHCP $HardyCross::VERSION - Perl Hydraulic Calculation Program",
             model => $meta{model} // '');
    my $s = HardyCross::PDF::frame(1, 1, %m);

    # Title block.
    my $y = $geo->{top};
    $s .= $txt->($L, $y, 'Q^1.85 WATER SUPPLY GRAPH' . (length $m{title} ? " - $m{title}" : ''), 10, 1);
    $s .= $txt->($R, $y, join('   ', grep { length } ($m{designer} ? "PREPARED BY $m{designer}" : '')), 8, 0, 'r');

    # The plot.
    my ($pl, $pr, $pt, $pb) = ($L + 8 * $cw, $L + 84 * $cw, $y - 26, 92);
    my ($pw, $ph) = ($pr - $pl, $pt - $pb);
    my ($qmax, $pmax) = @{$sr}{qw(qmax pmax)};
    my $X = sub { $pl + ($_[0] > 0 ? ($_[0] / $qmax) ** 1.85 : 0) * $pw };
    my $Y = sub { $pb + $_[0] / $pmax * $ph };
    $s .= sprintf "%% PHCP-SHEET PLOT %.3f %.3f %.3f %.3f %.10g %.10g\n", $pl, $pb, $pw, $ph, $qmax, $pmax;
    $s .= "q 0.82 G 0.3 w\n";
    for my $p (@{ $sr->{yticks} }) {
        next if $p > $pmax + 1e-9;
        $s .= sprintf "%.2f %.2f m %.2f %.2f l S\n", $pl, $Y->($p), $pr, $Y->($p);
    }
    for my $q (@{ $sr->{xticks} }) {
        next if $q > $qmax + 1e-9;
        $s .= sprintf "%.2f %.2f m %.2f %.2f l S\n", $X->($q), $pb, $X->($q), $pt;
    }
    $s .= "Q\n";
    for my $p (@{ $sr->{yticks} }) {
        next if $p > $pmax + 1e-9;
        $s .= $txt->($pl - 4, $Y->($p) - 2.4, sprintf('%g', $p), 7, 0, 'r');
    }
    my $last = -1e9;
    for my $q (@{ $sr->{xticks} }) {
        next if $q > $qmax + 1e-9;
        my $t = sprintf '%g', $q;
        my $w = length($t) * $adv * 7;
        my $x = $X->($q);
        next if $x - $w / 2 < $last + 6;
        $s .= sprintf "%% PHCP-SHEET XTICK %s %.3f\n", $t, $x;
        $s .= $txt->($x, $pb - 10, $t, 7, 0, 'c');
        $last = $x + $w / 2;
    }
    $s .= $txt->($pl - 4, $pt + 6, 'PRESSURE, kPa', 7, 1);
    $s .= $txt->(($pl + $pr) / 2, $pb - 22, 'FLOW, L/min, ON A FLOW^1.85 SCALE', 7, 1, 'c');
    $s .= sprintf "0 G 0.6 w %.2f %.2f %.2f %.2f re S\n", $pl, $pb, $pw, $ph;

    # Curves, clipped to the plot.  Line styles: [width, dash, grey].
    # A thin, B dotted, D dash-dot; the design curve heavy, and C dashed when
    # it is not the design curve (with a pump, E is).
    my %style = (A => [ 0.8, '', 0 ], B => [ 0.8, '[1 2]', 0 ], C => [ 0.8, '[4 2]', 0 ],
                 D => [ 0.8, '[6 2 1 2]', 0 ], E => [ 0.8, '[4 2]', 0 ]);
    $style{ $sr->{design} } = [ 1.8, '', 0 ];
    $s .= sprintf "q %.2f %.2f %.2f %.2f re W n 1 J 1 j\n", $pl, $pb, $pw, $ph;
    my @names = grep { $sr->{lines}{$_} } qw(A B C D E);
    for my $n (@names) {
        my ($w, $d) = @{ $style{$n} };
        my @pt = @{ $sr->{lines}{$n} };
        $s .= sprintf "%% PHCP-SHEET LINE %s %d\n", $n, scalar @pt;
        $s .= sprintf "%s 0 d %.2f w %.2f %.2f m\n", $d || '[]', $w, $X->($pt[0][0]), $Y->($pt[0][1]);
        $s .= sprintf "%.2f %.2f l\n", $X->($_->[0]), $Y->($_->[1]) for @pt[1 .. $#pt];
        $s .= "S [] 0 d\n";
    }
    for my $c (sort keys %{ $sr->{points} }) {
        for my $p (@{ $sr->{points}{$c} }) {
            $s .= sprintf "%% PHCP-SHEET POINT %s %.3f %.3f\n", $c, $X->($p->[0]), $Y->($p->[1]);
            $s .= "0.7 w 1 g\n" . HardyCross::PDF::circle($X->($p->[0]), $Y->($p->[1]), 2.2, 'B') . "0 g\n";
        }
    }
    $s .= "Q\n";
    # Each curve named on itself, the letters staggered along the flow axis
    # so that curves meeting at one end are still told apart.
    my %along = (A => 0.30, B => 0.62, C => 0.46, D => 0.78, E => 0.90);
    for my $n (@names) {
        my ($at) = grep { $X->($_->[0]) >= $pl + $along{$n} * $pw } @{ $sr->{lines}{$n} };
        next unless $at && $at->[1] >= 0 && $at->[1] <= $pmax;
        $s .= sprintf "%% PHCP-SHEET NAME %s %.3f %.3f\n", $n, $X->($at->[0]), $Y->($at->[1]);
        $s .= "1 g\n" . sprintf("%.2f %.2f 7 9 re f\n", $X->($at->[0]) - 3.5, $Y->($at->[1]) + 1.5) . "0 g\n";
        $s .= $txt->($X->($at->[0]), $Y->($at->[1]) + 3, $n, 8, 1, 'c');
    }
    # Duty points: a filled square, numbered.
    for my $d (@{ $sr->{duty} }) {
        my ($x, $yy) = ($X->($d->{q}), $Y->($d->{p}));
        next if $d->{q} > $qmax || $d->{p} > $pmax;
        $s .= sprintf "%% PHCP-SHEET DUTY %s %.3f %.3f\n", $d->{label}, $x, $yy;
        $s .= sprintf "0 g %.2f %.2f 5 5 re f\n", $x - 2.5, $yy - 2.5;
        $s .= $txt->($x + 4, $yy + 3, $d->{label}, 7, 1);
    }

    # The key.
    my $kx = $L + 90 * $cw;
    my $ky = $pt;
    my $line = sub { $ky -= 12 };
    my $head = sub {
        $s .= $txt->($kx, $ky, shift, 8, 1);
        $s .= sprintf "0.4 w %.2f %.2f m %.2f %.2f l S\n", $kx, $ky - 4, $R, $ky - 4;
    };
    $head->('KEY');
    for my $n (@names) {
        $line->();
        my ($w, $d) = @{ $style{$n} };
        $s .= sprintf "%s 0 d %.2f w %.2f %.2f m %.2f %.2f l S [] 0 d\n", $d || '[]', $w, $kx, $ky + 2.5, $kx + 20, $ky + 2.5;
        $s .= $txt->($kx + 26, $ky, "$n  $CURVE_NAME{$n}", 7, $n eq $sr->{design});
    }
    $line->();
    $s .= $txt->($kx + 26, $ky, "THE HEAVY LINE, $sr->{design}, IS THE CURVE DESIGNED AGAINST", 7);
    if (%{ $sr->{points} }) {
        $line->();
        $s .= "0.7 w 1 g\n" . HardyCross::PDF::circle($kx + 10, $ky + 2.5, 2.2, 'B') . "0 g\n";
        $s .= $txt->($kx + 26, $ky, 'POINTS AS ENTERED', 7);
    }
    if (@{ $sr->{duty} }) {
        $line->();
        $s .= sprintf "0 g %.2f %.2f 5 5 re f\n", $kx + 7.5, $ky;
        $s .= $txt->($kx + 26, $ky, 'DUTY POINT, NUMBERED', 7);

        # The duties against the design curve.
        $line->(); $line->();
        $head->("DUTY POINTS - AGAINST $sr->{design}");
        $line->();
        my @col = ($kx, $kx + 64, $kx + 112, $kx + 160, $R);
        $s .= $txt->($col[0], $ky, 'NO', 7, 1);
        $s .= $txt->($col[1], $ky, 'FLOW', 7, 1, 'r');
        $s .= $txt->($col[2], $ky, 'NEEDS', 7, 1, 'r');
        $s .= $txt->($col[3], $ky, 'HAS', 7, 1, 'r');
        $s .= $txt->($col[4], $ky, 'MARGIN', 7, 1, 'r');
        $line->();
        $s .= $txt->($col[1], $ky + 3, 'L/min', 6, 0, 'r');
        $s .= $txt->($col[2], $ky + 3, 'kPa', 6, 0, 'r');
        $s .= $txt->($col[3], $ky + 3, 'kPa', 6, 0, 'r');
        $s .= $txt->($col[4], $ky + 3, 'kPa', 6, 0, 'r');
        for my $d (@{ $sr->{duty} }) {
            $line->();
            $s .= sprintf "%% PHCP-SHEET ROW %s %.1f %.1f %.1f %.1f\n", $d->{label}, $d->{q}, $d->{p},
                $d->{avail}, $d->{margin};
            $s .= $txt->($col[0], $ky, HardyCross::PDF::fit($d->{label}, 8), 7);
            $s .= $txt->($col[1], $ky, sprintf('%.0f', $d->{q}), 7, 0, 'r');
            $s .= $txt->($col[2], $ky, sprintf('%.0f', $d->{p}), 7, 0, 'r');
            $s .= $txt->($col[3], $ky, sprintf('%.0f', $d->{avail}), 7, 0, 'r');
            $s .= $txt->($col[4], $ky, ($d->{margin} < 0 ? 'SHORT ' : '') . sprintf('%.0f', abs $d->{margin}),
                         7, $d->{margin} < 0, 'r');
            if (length $d->{desc}) {
                $ky -= 9;
                $s .= $txt->($col[0] + 10, $ky, HardyCross::PDF::fit($d->{desc}, 44), 6);
            }
        }
    }

    # The points entered, for the record.
    $line->(); $line->();
    $head->('POINTS ENTERED, L/min AT kPa');
    for my $c (sort keys %{ $sr->{points} }) {
        $line->();
        my $t = "$c  " . join('   ', map { sprintf '%g at %g', @$_ } @{ $sr->{points}{$c} });
        for my $part (wrap_to($t, 52)) {
            $s .= $txt->($kx, $ky, $part, 6.5);
            $ky -= 9;
        }
        $ky += 9;
    }
    $line->(); $line->();
    for my $part (wrap_to('Every curve passes through its points and is straight between them on this paper; '
                        . 'beyond its last point it continues straight in flow. C = A - B and E = C + D, '
                        . 'at equal flow. ' . ($g->{B} && grep({ !blank($_->[0]) } @{ $g->{B} }) == 1
                             ? 'B, one point, is a loss line through the origin. ' : '')
                        . 'Not a calculation of a network: the figures are as entered.', 60)) {
        $s .= $txt->($kx, $ky, $part, 6);
        $ky -= 8;
    }

    HardyCross::PDF::write_pages([ $s ], $path, $reg, $bold, %m,
                                 title => 'Q^1.85 water supply graph' . (length $m{title} ? " - $m{title}" : ''));
    return $sr;
}

# wrap_to -- text cut into lines of at most $w characters, at spaces.
sub wrap_to {
    my ($t, $w) = @_;
    my @out;
    my $cur = '';
    for my $word (split ' ', $t) {
        if (length($cur) + length($word) + 1 > $w && length $cur) { push @out, $cur; $cur = $word }
        else { $cur = length $cur ? "$cur $word" : $word }
    }
    push @out, $cur if length $cur;
    return @out;
}

1;
