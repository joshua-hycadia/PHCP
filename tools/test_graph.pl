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
#   6. UNITS.  The same supply in L/s and bar.
#   7. IN A MODEL'S REPORT.  SUPPLYGRAPH adds the sheet: an appendix to the
#      text, a page after it in the PDF, numbered with the report; a graph
#      that cannot be read is a warning, and the report is still written.
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

#==============================================================================
print "6. UNITS - the same supply in L/s and bar\n";
#==============================================================================
{
    # Example 10's figures in L/s and bar: flows / 60, pressures / 100.
    my $m = HardyCross::Graph::read_file($EX);
    my $g = HardyCross::Graph::read_file($EX);
    $g->{units} = { FLOW => 'LPS', PRESSURE => 'BAR' };
    for my $c (qw(A B D)) {
        for my $r (@{ $g->{$c} }) { $r->[0] /= 60 if length $r->[0]; $r->[1] /= 100 if length $r->[1] }
    }
    for my $r (@{ $g->{duty} }) { $r->[2] /= 60 if length $r->[2]; $r->[3] /= 100 if length $r->[3] }
    my $sm = HardyCross::Graph::series(HardyCross::Graph::check($m));
    my $sg = HardyCross::Graph::series(HardyCross::Graph::check($g));
    my @off = grep { abs($sg->{duty}[$_]{margin} * 100 - $sm->{duty}[$_]{margin}) > 1e-6 } 0 .. 1;
    is(sprintf('every duty\'s margin is the same: %.2f and %.2f kPa, as %.4f and %.4f bar',
               $sm->{duty}[0]{margin}, $sm->{duty}[1]{margin}, $sg->{duty}[0]{margin}, $sg->{duty}[1]{margin}),
       !@off && @{ $sg->{duty} } == 2);
    is('the flow axis stops at a round number of L/s: 60', $sg->{qmax} == 60, $sg->{qmax});
    HardyCross::Graph::write_file($g, "$TMP/u.phg");
    my $back = HardyCross::Graph::read_file("$TMP/u.phg");
    is('UNITS written to the .phg and read back', $back->{units}{FLOW} eq 'LPS' && $back->{units}{PRESSURE} eq 'BAR'
       && slurp_lines("$TMP/u.phg") =~ /^UNITS\s+FLOW LPS$/m);
    HardyCross::Graph::write_pdf($g, "$TMP/u.pdf");
    open my $fh, '<:raw', "$TMP/u.pdf" or die;
    my $P = do { local $/; <$fh> };
    close $fh;
    is('the sheet names L/s and bar', $P =~ /\(FLOW, L\/s, ON A FLOW\^1\.85 SCALE\)/ && $P =~ /\(PRESSURE, bar\)/);
    is('a graph with no UNITS is L/min and kPa, as before', HardyCross::Graph::units(HardyCross::Graph::new_graph())->{FLOW} eq 'LPM');
    open my $o, '>', "$TMP/badu.phg" or die;
    print $o "UNITS FLOW LPH\n";
    close $o;
    my $r = eval { HardyCross::Graph::read_file("$TMP/badu.phg"); 1 };
    is('an unknown unit is refused with its line', !$r && $@ =~ /^LINE 1: UNITS TAKES FLOW/, $@);
}
sub slurp_lines { open my $f, '<', shift or die; local $/; <$f> }

print "7. IN A MODEL'S REPORT - SUPPLYGRAPH\n";
{
    require HardyCross::Phc;
    require HardyCross::Report;
    require File::Copy;
    my $dir = tempdir(CLEANUP => 1);
    File::Copy::copy($EX, "$dir/town.phg") or die;
    my $model = slurp_lines("$FindBin::Bin/../examples/01_single_branch.phc");
    my $write = sub { open my $f, '>', "$dir/m.phc" or die; print $f $model, @_; close $f; "$dir/m.phc" };
    my $net = HardyCross::Phc::read_model($write->("SUPPLYGRAPH town.phg\n"));
    HardyCross::solve_model($net);
    is('SUPPLYGRAPH town.phg: read from the model\'s folder, no warning',
       @{ $net->{graph_sheets} || [] } == 1 && !grep { /supply graph/ } @{ $net->{warnings} });
    my $rep = HardyCross::Report::write_report($net, 1, 'm.phc');
    my $sr = HardyCross::Graph::series(HardyCross::Graph::check($net->{graph_sheets}[0]{graph}));
    my %d = map { $_->{label} => $_ } @{ $sr->{duty} };
    is('   the text report has it as APPENDIX A, before the end',
       $rep =~ /APPENDIX A\. SUPPLY GRAPH - TOWN\.PHG.*END OF CALCULATION/s);
    is(sprintf('   with each duty against E: 1 has %.1f, margin %.1f', $d{1}{avail}, $d{1}{margin}),
       $rep =~ /^ 1\s+1500\s+700\s+\Q@{[ sprintf '%.4g', $d{1}{avail} ]}\E\s+\Q@{[ sprintf '%.4g', $d{1}{margin} ]}\E\s+SPRINKLERS/m);
    is('   and stays 7-bit ASCII', $rep !~ /[^\x0A\x20-\x7E]/);
    my ($with, $without) = ("$dir/with.pdf", "$dir/without.pdf");
    HardyCross::Report::write_pdf_report($net, 1, "$dir/m.phc", $with);
    my $plain = HardyCross::Phc::read_model($write->(''));
    HardyCross::solve_model($plain);
    HardyCross::Report::write_pdf_report($plain, 1, "$dir/m.phc", $without);
    my ($pw, $po) = map { my $b = do { open my $f, '<:raw', $_ or die; local $/; <$f> }; $b } $with, $without;
    my ($nw) = $pw =~ m{/Type /Pages .*?/Count (\d+)}s;
    my ($no) = $po =~ m{/Type /Pages .*?/Count (\d+)}s;
    is("   the PDF has one page more: $no without, $nw with", $nw == $no + 1);
    my $streams = () = $pw =~ /PHCP-SHEET PLOT/g;
    is('   the sheet is drawn once, framed as the last page of the report',
       $streams == 1 && $pw =~ /\(Page $nw of $nw\)/ && $po =~ /\(Page $no of $no\)/);
    $net = HardyCross::Phc::read_model($write->("SUPPLYGRAPH none.phg\n"));
    my ($w) = grep { /supply graph/ } @{ $net->{warnings} };
    is('a graph that cannot be read: a warning naming it and its line, nothing more',
       $net && ($w // '') =~ /^supply graph none\.phg \(line \d+\) is not in the report: CANNOT READ/ && !$net->{graph_sheets}, $w);
    open my $b, '>', "$dir/bad.phg" or die; print $b "A 0 500\nDUTY 100 200 1\n"; close $b;
    $net = HardyCross::Phc::read_model($write->("SUPPLYGRAPH bad.phg\n"));
    ($w) = grep { /supply graph/ } @{ $net->{warnings} };
    is('a graph its own tab would refuse: a warning with the reason', ($w // '') =~ /^supply graph bad\.phg .*: \S/, $w);
    $net = HardyCross::Phc::read_string($model . "SUPPLYGRAPH town.phg\n");
    is('read without a folder (a re-read for a re-solve): no sheets, no warning',
       !$net->{graph_sheets} && !grep { /supply graph/ } @{ $net->{warnings} });
    my $a = HardyCross::Phc::analyse('SUPPLYGRAPH');
    is('the line checker asks for the FILE', $a->{status} eq 'incomplete' && $a->{msg} =~ /FILE/);
    $a = HardyCross::Phc::analyse('SUPPLYGRAPH My Graphs/Town Main.phg');
    is('   and keeps a file name with spaces as typed', $a->{status} eq 'ok' && $a->{text} eq 'My Graphs/Town Main.phg');
}

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
