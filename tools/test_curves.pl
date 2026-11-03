#!/usr/bin/perl
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# test_curves.pl -- supply, pump and loss-device curves, and the orifice
# plate's discharge coefficient.
#
#   perl tools/test_curves.pl
#
# A curve must pass EXACTLY through every point entered, be linear in Q^1.85
# between points, continue in a straight line beyond them, and never offer the
# loop correction a zero slope to divide by.  Each is checked here against
# figures worked by hand, independently of the engine's own code.
#==============================================================================
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";
use HardyCross;
use HardyCross::Demand;

my ($pass, $fail) = (0, 0);
sub is {
    my ($name, $ok, $why) = @_;
    printf "  %-66s %s\n", $name, $ok ? 'ok' : '*** FAIL';
    print "      $why\n" if !$ok && defined $why;
    $ok ? $pass++ : $fail++;
}
sub curve { my ($rising, @qp) = @_;
    my $c = { q => [], p => [] };
    while (@qp) { push @{ $c->{q} }, shift @qp; push @{ $c->{p} }, shift @qp }
    return HardyCross::fit_curve($c, $rising);
}
my $E = \&HardyCross::curve_eval;
my $S = \&HardyCross::curve_slope;

print "1. EVERY POINT REPRODUCED EXACTLY\n";
{
    # Three points: the old least-squares quadratic missed all three.
    my $c = curve(0, 0, 1000, 3000, 700, 6000, 300);
    is('town main (0,1000) (3000,700) (6000,300): through every point',
       abs($E->($c, 0) - 1000) < 1e-9 && abs($E->($c, 3000) - 700) < 1e-9 && abs($E->($c, 6000) - 300) < 1e-9);
    my $p = curve(0, 0, 850, 2500, 800, 4000, 600, 5000, 380);
    is('pump, four points: through every point',
       !grep { abs($E->($p, $_->[0]) - $_->[1]) > 1e-9 } [0, 850], [2500, 800], [4000, 600], [5000, 380]);
    my $u = curve(0, 4000, 600, 0, 850, 2500, 800);
    is('points given out of order are sorted', abs($E->($u, 2500) - 800) < 1e-9 && abs($E->($u, 0) - 850) < 1e-9);
}

print "2. LINEAR IN Q^1.85 BETWEEN POINTS\n";
{
    # A supply of static 1100 kPa and 1035 kPa residual at 7570 L/min.  By hand,
    # P(Q) = 1100 - 65 (Q / 7570)^1.85.  At 5000 L/min:
    #   (5000/7570)^1.85 = 0.66050^1.85 = 0.46427;  1100 - 65 x 0.46427 = 1069.82.
    my $c = curve(0, 0, 1100, 7570, 1035);
    my $hand = 1100 - 65 * (5000 / 7570) ** 1.85;
    is(sprintf('static + one residual: P(5000) = %.2f kPa, as worked by hand', $E->($c, 5000)),
       abs($E->($c, 5000) - $hand) < 1e-9 && abs($hand - 1069.82) < 0.005);
    # Between the second and third points of a three-point curve:
    #   x = Q^1.85;  P = 700 + (300 - 700) (x(4500) - x(3000)) / (x(6000) - x(3000))
    my $t = curve(0, 0, 1000, 3000, 700, 6000, 300);
    my $x = sub { $_[0] ** 1.85 };
    my $h2 = 700 + (300 - 700) * ($x->(4500) - $x->(3000)) / ($x->(6000) - $x->(3000));
    is(sprintf('three-point curve, P(4500) = %.2f kPa, the second segment', $E->($t, 4500)),
       abs($E->($t, 4500) - $h2) < 1e-9);
    is('it is not the straight line between the points (that would be 500)', abs($E->($t, 4500) - 500) > 5);
    # The slope matches a numerical derivative of the curve itself.
    my $d = ($E->($t, 4501) - $E->($t, 4499)) / 2;
    is(sprintf('slope at 4500: %.5f kPa per L/min, as the curve itself', $S->($t, 4500)), abs($S->($t, 4500) - $d) < 1e-6);
}

print "3. BEYOND THE POINTS, AND NO ZERO SLOPE\n";
{
    my $c = curve(0, 0, 1100, 7570, 1035);
    my $s = $S->($c, 7570);
    is('beyond the last point: a straight line at the end slope',
       abs($E->($c, 9570) - (1035 + 2000 * $s)) < 1e-9 && $s < 0);
    is('at zero flow the Q^1.85 scale is flat; the slope offered is not zero',
       $S->($c, 0) < 0 && $S->($c, 1e-9) < 0);
    is('reverse flow through a supply: a straight line, finite', abs($E->($c, -100) - (1100 - 100 * $S->($c, -1))) < 1e-6);
    my $b = curve(1, 0, 0, 1000, 25, 2000, 55, 3000, 95);
    is('a loss curve (backflow preventer): rising, through its points, slope positive',
       abs($E->($b, 2000) - 55) < 1e-9 && $S->($b, 0) > 0 && $S->($b, 3500) > 0);
}

print "4. REFUSED\n";
{
    my $r = eval { curve(0, 100, 900, 100, 800); 1 };
    is('two points at the same flow are refused', !$r && HardyCross::is_model_error($@));
    $r = eval { curve(0, 0, 900); 1 };
    is('one point is refused', !$r && HardyCross::is_model_error($@));
    $r = eval { curve(0, -100, 900, 1000, 800); 1 };
    is('a negative flow is refused', !$r && HardyCross::is_model_error($@));
}

print "5. SUPPLIES COMBINED - FLOWS ADDED AT EQUAL PRESSURE\n";
{
    # Two supply curves, worked by hand.  A: 900 kPa at no flow, 600 at 3000.
    # B: 850 at no flow, 520 at 2400.  Each is straight in Q^1.85 between, so
    # at pressure p, A gives 3000 x ((900-p)/300)^(1/1.85) and B gives
    # 2400 x ((850-p)/330)^(1/1.85).
    my $A = { kind => 'SUPPLY_CURVE', curve => curve(0, 0, 900, 3000, 600) };
    my $B = { kind => 'SUPPLY_CURVE', curve => curve(0, 0, 850, 2400, 520) };
    my $qa = sub { 3000 * ((900 - $_[0]) / 300) ** (1 / 1.85) };
    my $qb = sub { 2400 * ((850 - $_[0]) / 330) ** (1 / 1.85) };
    my $c = HardyCross::Demand::combined_avail($A, $B);
    my $bad = 0;
    for my $p (610, 650, 700, 800, 849) {      # within both curves' entered points
        my $q = $qa->($p) + $qb->($p);
        $bad++ if abs($c->($q) - $p) > 1e-6;
    }
    is('two curves: at each pressure the combined flow is their sum', !$bad);
    is('above the lower curve\'s shut-off, only the higher gives water',
       abs($c->($qa->(870)) - 870) < 1e-6);
    is('three identical curves: three times the flow at the same pressure',
       abs(HardyCross::Demand::combined_avail($A, $A, $A)->(3 * $qa->(700)) - 700) < 1e-6);
    # A static supply gives any flow at its pressure, so the combined curve
    # never falls below it; above it, the curve gives the flow.
    my $T = { kind => 'SUPPLY_STATIC', pstat => 700 };
    my $ct = HardyCross::Demand::combined_avail($A, $T);
    is('with a static supply: never below the static pressure',
       abs($ct->(1e6) - 700) < 1e-9 && abs($ct->($qa->(800)) - 800) < 1e-6);
}

print "6. ORIFICE PLATES - THE DISCHARGE COEFFICIENT\n";
{
    # The plate's net loss is the differential across it times the ISO 5167
    # permanent-loss ratio R:
    #   differential = (224.954 / Cd^2) (Q^2/d^4) (1 - b^4)   kPa, L/min, mm
    #   R            = [s - Cd b^2]/[s + Cd b^2],  s = sqrt(1 - b^4(1-Cd^2))
    # 224.954 = 633.28 x 0.596^2, the constant PHCP has always used at its
    # default Cd.  R is worked here by hand, so dividing it out leaves the
    # differential, which at fixed bore and beta must go as 1/Cd^2.
    my $dp = \&HardyCross::orifice_dp;
    my ($q, $d, $bigd) = (500, 38.5, 60);              # beta 0.642
    my $b4 = ($d / $bigd) ** 4;
    my $R  = sub { my $cd = shift;
        my $s = sqrt(1 - $b4 * (1 - $cd ** 2));
        ($s - $cd * $b4 ** 0.5) / ($s + $cd * $b4 ** 0.5) };
    my $diff = sub { my $cd = shift; $dp->($q, $d, $bigd, $cd) / $R->($cd) };
    my $ref  = $diff->(0.596) * 0.596 ** 2;
    my $bad  = 0;
    for my $cd (0.55, 0.596, 0.61, 0.7, 0.7826, 0.9) {
        $bad++ if abs($diff->($cd) * $cd ** 2 / $ref - 1) > 1e-12;
    }
    is('differential x Cd^2 is the same for every Cd (bore, beta fixed)', !$bad);
    is('Cd 0.7826 vs 0.596: differential in the ratio (0.596/0.7826)^2',
       abs($diff->(0.7826) / $diff->(0.596) - (0.596 / 0.7826) ** 2) < 1e-12);
    # At the default the drop is exactly what it was before the main term
    # took Cd: 633.28 (Q^2/d^4)(1-b^4) R.
    my $old = 633.28 * $q ** 2 / $d ** 4 * (1 - $b4) * $R->(0.596);
    is('default Cd 0.596: the drop is unchanged',
       abs($dp->($q, $d, $bigd, 0.596) / $old - 1) < 1e-12,
       sprintf('%.6f against %.6f kPa', $dp->($q, $d, $bigd, 0.596), $old));
    # The constant is rho/2 (1/60000)^2 (4/pi)^2 1e12 at about 999.1 kg/m3;
    # at 998.2 kg/m3 it would be 224.75 - within 0.1%.
    my $pi = 4 * atan2(1, 1);
    my $k998 = 998.2 / 2 * (4 / $pi) ** 2 / 3.6e9 * 1e12 / 1000;
    is('the constant is within 0.1% of the 998.2 kg/m3 value (224.75)',
       abs($ref / ($q ** 2 / $d ** 4 * (1 - $b4)) / $k998 - 1) < 1e-3);
    # OPP sizes with the same Cd: the bore found gives the drop asked for,
    # and a higher Cd needs a smaller bore for the same drop.
    my ($b596, $b783) = map { HardyCross::orifice_size($q, 150, $bigd, $_) } 0.596, 0.7826;
    is('OPP: the bore sized at Cd 0.7826 gives the drop asked for',
       abs($dp->($q, $b783, $bigd, 0.7826) - 150) < 1e-6,
       sprintf('bore %.4f mm gives %.6f kPa', $b783, $dp->($q, $b783, $bigd, 0.7826)));
    is('OPP: a higher Cd needs a smaller bore for the same drop', $b783 < $b596,
       sprintf('%.3f mm at 0.7826, %.3f mm at 0.596', $b783, $b596));
}

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
