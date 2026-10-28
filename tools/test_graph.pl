#!/usr/bin/perl
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# test_graph.pl -- the Q^1.85 water supply graph (HardyCross::Graph), headless.
#
#   perl tools/test_graph.pl
#
# What it proves, in order:
#
#   1. THE CURVES.  C = A - B and E = C + D at equal flow, each straight in
#      flow^1.85 between its points -- checked against figures worked here,
#      by a formula written out in this file, not by the engine's own code.
#      A single loss point is a line through the origin.
#   2. THE DUTIES.  Each compared with E when there is a pump, C when not.
#   3. REFUSED.  Every rule the tab enforces, each naming its row.
#   4. THE FILE.  A .phg file written and read back is the same graph; a bad
#      line is refused with its line number.
#   5. THE SHEET.  The PDF is well formed, one page, the typeface embedded;
#      the plot, the curves, the duty points and their table are where the
#      figures put them.
#==============================================================================
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";
use File::Temp qw(tempdir);
use HardyCross::Graph;

my ($pass, $fail) = (0, 0);
sub is {
    my ($name, $ok, $why) = @_;
    printf "  %-68s %s\n", $name, $ok ? 'ok' : '*** FAIL';
    print "      $why\n" if !$ok && defined $why;
    $ok ? $pass++ : $fail++;
}
my $TMP = tempdir(CLEANUP => 1);
my $EX  = "$FindBin::Bin/../examples/10_supply_graph.phg";

# hand -- a curve through points, straight in Q^1.85 between them: the
# pressure at $q, for $q within the points.  Written out here on purpose.
sub hand {
    my ($pts, $q) = @_;
    for my $i (0 .. $#$pts - 1) {
        my ($q1, $p1) = @{ $pts->[$i] };
        my ($q2, $p2) = @{ $pts->[ $i + 1 ] };
        next unless $q >= $q1 && $q <= $q2;
        my $f = ($q ** 1.85 - $q1 ** 1.85) / ($q2 ** 1.85 - $q1 ** 1.85);
        return $p1 + ($p2 - $p1) * $f;
    }
    die "flow $q is outside the points\n";
}
sub near { abs($_[0] - $_[1]) < ($_[2] // 1e-6) }

# graph -- a graph from short lists, as the tab would hold it.
sub graph {
    my %o = @_;
    my $g = HardyCross::Graph::new_graph();
    for my $c (qw(A B D)) {
        my @p = @{ $o{$c} || [] };
        $g->{$c}[$_] = [ @{ $p[$_] } ] for 0 .. $#p;
    }
    my @d = @{ $o{duty} || [] };
    $g->{duty}[$_] = [ @{ $d[$_] } ] for 0 .. $#d;
    $g->{axis}{$_} = $o{$_} for grep { exists $o{$_} } qw(PMAX PSTEP QMAX);
    return $g;
}

my @A = ([ 0, 650 ], [ 1800, 560 ], [ 3600, 400 ]);
my @B = ([ 0, 0 ], [ 1000, 40 ], [ 2000, 140 ], [ 3600, 400 ]);
my @D = ([ 0, 480 ], [ 1200, 460 ], [ 2400, 400 ], [ 3600, 290 ]);

#==============================================================================
print "1. THE CURVES - C = A - B and E = C + D, straight in flow^1.85\n";
#==============================================================================
{
    my $chk = HardyCross::Graph::check(graph(A => \@A, B => \@B, D => \@D));
    is('three curves, four duties of nothing: accepted', $chk->{ok},
       join '; ', map { $_->[1] } @{ $chk->{errors} });
    my $sr = HardyCross::Graph::series($chk);
    my $bad = 0;
    for my $pt (@{ $sr->{lines}{C} }) {
        my $q = $pt->[0];
        $bad++ unless near($pt->[1], hand(\@A, $q) - hand(\@B, $q));
    }
    is('C = A - B at every sample (201 flows)', !$bad && @{ $sr->{lines}{C} } == 201);
    $bad = 0;
    for my $pt (@{ $sr->{lines}{E} }) {
        my $q = $pt->[0];
        $bad++ unless near($pt->[1], hand(\@A, $q) - hand(\@B, $q) + hand(\@D, $q));
    }
    is('E = C + D at every sample', !$bad);
    is('every entered point is on its own curve',
       !grep { my $c = $_; grep { !near(hand(\@{ { A => \@A, B => \@B, D => \@D }->{$c} }, $_->[0]), $_->[1]) }
               @{ $sr->{points}{$c} } } qw(A B D));
    is('samples evenly spaced along the flow^1.85 axis',
       near($sr->{lines}{A}[100][0] ** 1.85, $sr->{qmax} ** 1.85 / 2, 1e-3 * $sr->{qmax} ** 1.85));
    is('the flow axis: the largest flow, rounded up to 100 (3600)', $sr->{qmax} == 3600);
    is('the design curve is E when there is a pump', $sr->{design} eq 'E');

    # One loss point: a line through the origin, rising as flow^1.85.
    my $one = HardyCross::Graph::series(HardyCross::Graph::check(graph(A => \@A, B => [ [ 2400, 120 ] ])));
    $bad = 0;
    for my $pt (@{ $one->{lines}{B} }) {
        next if $pt->[0] > 2400;
        $bad++ unless near($pt->[1], 120 * ($pt->[0] / 2400) ** 1.85);
    }
    is('one loss point: B = 120 x (Q/2400)^1.85, through the origin', !$bad);
    is('no pump: the design curve is C, and there is no D or E',
       $one->{design} eq 'C' && !$one->{lines}{D} && !$one->{lines}{E});
    my $none = HardyCross::Graph::series(HardyCross::Graph::check(graph(A => \@A)));
    is('no loss and no pump: C is A', !grep { !near($none->{lines}{C}[$_][1], $none->{lines}{A}[$_][1]) } 0 .. 200);
    my $ax = HardyCross::Graph::series(HardyCross::Graph::check(graph(A => \@A, PMAX => 900, PSTEP => 150, QMAX => 5000)));
    is('axes as set: 0 to 900 kPa every 150, 0 to 5000 L/min',
       $ax->{pmax} == 900 && $ax->{qmax} == 5000 && "@{ $ax->{yticks} }" eq '0 150 300 450 600 750 900');
}

#==============================================================================
print "2. THE DUTIES - each against the design curve\n";
#==============================================================================
{
    my $duty = [ [ '1', 'SPRINKLERS', 1500, 700 ], [ '', 'HYDRANTS', 2400, 900 ] ];
    my $sr = HardyCross::Graph::series(HardyCross::Graph::check(graph(A => \@A, B => \@B, D => \@D, duty => $duty)));
    my ($d1, $d2) = @{ $sr->{duty} };
    my $e = sub { hand(\@A, $_[0]) - hand(\@B, $_[0]) + hand(\@D, $_[0]) };
    is(sprintf('duty 1: E at 1500 L/min is %.2f kPa, margin %.2f', $e->(1500), $e->(1500) - 700),
       near($d1->{avail}, $e->(1500)) && near($d1->{margin}, $e->(1500) - 700));
    is(sprintf('duty 2: short by %.2f kPa', 900 - $e->(2400)), near($d2->{margin}, $e->(2400) - 900) && $d2->{margin} < 0);
    is('a duty with no label takes its row number', $d2->{label} eq '2');
    my $nopump = HardyCross::Graph::series(HardyCross::Graph::check(graph(A => \@A, B => \@B, duty => $duty)));
    is('without a pump the duties are against C',
       near($nopump->{duty}[0]{avail}, hand(\@A, 1500) - hand(\@B, 1500)));
    my $ex = HardyCross::Graph::series(HardyCross::Graph::check(HardyCross::Graph::read_file($EX)));
    my $e2 = hand([ [ 0, 650 ], [ 1800, 560 ], [ 3600, 400 ] ], 2400) - 120 + 400;
    is(sprintf('example 10, duty 2: E at 2400 = 516.83 - 120 + 400 = %.2f kPa', $e2),
       near($ex->{duty}[1]{avail}, $e2) && near($e2, 796.84, 0.01));
}

#==============================================================================
print "3. REFUSED - each problem named, with its row\n";
#==============================================================================
{
    my $err = sub {
        my ($name, $g, $field, $re) = @_;
        my $chk = HardyCross::Graph::check($g);
        my ($e) = grep { $_->[0] eq $field } @{ $chk->{errors} };
        is($name, !$chk->{ok} && $e && $e->[1] =~ $re,
           $e ? "got [$e->[0]] $e->[1]" : 'errors: ' . join('; ', map { "[$_->[0]] $_->[1]" } @{ $chk->{errors} }));
    };
    $err->('A with one point', graph(A => [ [ 0, 650 ] ]), 'A1', qr/AT LEAST TWO POINTS/);
    $err->('A empty', graph(), 'A1', qr/AT LEAST TWO POINTS/);
    $err->('a flow with no pressure', graph(A => [ @A, [ 4000, '' ] ]), 'A4', qr/A ROW 4: FLOW AND PRESSURE ARE BOTH NEEDED/);
    $err->('a letter O for a zero', graph(A => [ [ 0, 650 ], [ '18OO', 560 ] ]), 'A2', qr/FLOW '18OO' IS NOT A NUMBER/);
    $err->('flows not rising', graph(A => [ [ 0, 650 ], [ 1800, 560 ], [ 1800, 500 ] ]), 'A3', qr/MUST RISE/);
    $err->('a gap in the rows', graph(A => [ [ 0, 650 ], [ '', '' ], [ 1800, 560 ] ]), 'A3', qr/ROW 2 IS EMPTY/);
    $err->('a negative flow', graph(A => [ [ -10, 650 ], [ 1800, 560 ] ]), 'A1', qr/CANNOT BE NEGATIVE/);
    $err->('a pump with one point', graph(A => \@A, D => [ [ 0, 480 ] ]), 'D2', qr/AT LEAST TWO POINTS - OR NONE/);
    $err->('a pump not starting at churn', graph(A => \@A, D => [ [ 500, 480 ], [ 1500, 400 ] ]), 'D1', qr/CHURN/);
    $err->('a duty with no pressure', graph(A => \@A, duty => [ [ '1', 'X', 1500, '' ] ]), 'DUTY1', qr/BOTH NEEDED/);
    $err->('an axis of zero', graph(A => \@A, PMAX => 0), 'PMAX', qr/ABOVE ZERO, OR BLANK/);
    my $ok = HardyCross::Graph::check(graph(A => \@A, duty => [ [ '', '', '', '' ], [ '', 'NOTE', 900, 300 ] ]));
    is('an empty duty row before a filled one is allowed', $ok->{ok});
}

#==============================================================================
print "4. THE FILE - .phg written and read back\n";
#==============================================================================
{
    my $g = HardyCross::Graph::read_file($EX);
    is('example 10 reads', $g->{project}{JOB} eq 'HC-DEMO-010' && $g->{A}[2][0] eq '3600'
       && $g->{duty}[1][1] eq 'HYDRANTS - TWO AT 10 L/S');
    HardyCross::Graph::write_file($g, "$TMP/a.phg");
    my $back = HardyCross::Graph::read_file("$TMP/a.phg");
    my $flat = sub { my $x = shift; join '|', map({ $x->{project}{$_} } @HardyCross::Graph::PROJECT),
                     map({ $x->{axis}{$_} } @HardyCross::Graph::AXIS), map({ map { @$_ } @{ $x->{$_} } } qw(A B D)),
                     map { @$_ } @{ $x->{duty} } };
    is('written and read back: the same graph', $flat->($g) eq $flat->($back));
    open my $o, '>', "$TMP/bad.phg" or die;
    print $o "PROJECT X\nA 0 600\nPIPE 1 2\n";
    close $o;
    my $r = eval { HardyCross::Graph::read_file("$TMP/bad.phg"); 1 };
    is('an unknown word is refused with its line number', !$r && $@ =~ /^LINE 3: UNKNOWN WORD PIPE/, $@);
    open $o, '>', "$TMP/many.phg" or die;
    print $o map { "A $_ 500\n" } 1 .. 9;
    close $o;
    $r = eval { HardyCross::Graph::read_file("$TMP/many.phg"); 1 };
    is('more than eight points on a curve is refused', !$r && $@ =~ /MORE THAN 8 POINTS/, $@);
}

#==============================================================================
print "5. THE SHEET - the PDF\n";
#==============================================================================
{
    my $g = HardyCross::Graph::read_file($EX);
    my $sr = HardyCross::Graph::write_pdf($g, "$TMP/g.pdf");
    open my $fh, '<:raw', "$TMP/g.pdf" or die;
    my $P = do { local $/; <$fh> };
    close $fh;
    is('a PDF, one page', $P =~ /^%PDF-1\.4/ && $P =~ m{/Type /Pages /Kids \[\S+ 0 R\] /Count 1});
    my ($sx) = $P =~ /startxref\n(\d+)\n%%EOF\n\z/;
    my ($first) = substr($P, $sx) =~ /^xref\n(\d+) \d+\n/;
    my @e = substr($P, $sx) =~ /^(\d{10}) \d{5} ([nf]) ?\r?\n/mg;
    my $bad = 0;
    for (my $k = 0; $k < @e; $k += 2) {
        next unless $e[ $k + 1 ] eq 'n';
        my $num = $first + $k / 2;
        $bad++ unless substr($P, $e[$k], length "$num 0 obj") eq "$num 0 obj";
    }
    is('every xref offset lands on its object', !$bad);
    is('the typeface embedded', $P =~ m{/BaseFont /DejaVuSansMono /} && $P =~ m{/FontFile2 });
    my ($s) = $P =~ /stream\n(.*?% PHCP-SHEET PLOT.*?)endstream/s;
    my ($pl, $pb, $pw, $ph, $qmax, $pmax) = $s =~ /% PHCP-SHEET PLOT (\S+) (\S+) (\S+) (\S+) (\S+) (\S+)/;
    is('the plot is drawn, 0 to 3600 L/min and 0 to 1400 kPa', defined $pl && $qmax == 3600 && $pmax == 1400);
    my %n = $s =~ /% PHCP-SHEET LINE (\S) (\d+)/g;
    is('curves A B C D E drawn, 201 points each', join(' ', map { "$_$n{$_}" } sort keys %n) eq 'A201 B201 C201 D201 E201');
    my $X = sub { $pl + ($_[0] / $qmax) ** 1.85 * $pw };
    my $Y = sub { $pb + $_[0] / $pmax * $ph };
    my @dp = $s =~ /% PHCP-SHEET DUTY (\S+) (\S+) (\S+)/g;
    is('duty 1 drawn at 1500 L/min, 700 kPa on the q^1.85 axis',
       $dp[0] eq '1' && near($dp[1], $X->(1500), 0.01) && near($dp[2], $Y->(700), 0.01));
    is('duty 2 drawn at 2400 L/min, 600 kPa', $dp[3] eq '2' && near($dp[4], $X->(2400), 0.01) && near($dp[5], $Y->(600), 0.01));
    my @pt = $s =~ /% PHCP-SHEET POINT (\S) /g;
    is('every point entered is marked (3 A, 1 B, 4 D)', join('', @pt) eq 'AAABDDDD', join '', @pt);
    my @rows = $s =~ /% PHCP-SHEET ROW (\S+) (\S+) (\S+) (\S+) (\S+)/g;
    is('the duty table: 2400 L/min at 600, has 796.8, margin 196.8',
       "@rows[5 .. 9]" eq '2 2400.0 600.0 796.8 196.8', "@rows");
    my @tk = $s =~ /% PHCP-SHEET XTICK (\S+) (\S+)/g;
    my ($tb, $prev) = (0, undef);
    for (my $k = 0; $k < @tk; $k += 2) {
        $tb++ if abs($tk[ $k + 1 ] - $X->($tk[$k])) > 0.01;
        $tb++ if defined $prev && $tk[ $k + 1 ] - $prev < 6;
        $prev = $tk[ $k + 1 ];
    }
    is('every flow label at its place on the axis, none overlapping', @tk && !$tb);
    my $r = eval { HardyCross::Graph::write_pdf(graph(A => [ [ 0, 600 ] ]), "$TMP/x.pdf"); 1 };
    is('a graph with problems is not printed, and says why', !$r && $@ =~ /AT LEAST TWO POINTS/ && !-e "$TMP/x.pdf");
}

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
