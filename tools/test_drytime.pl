#!/usr/bin/perl
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# test_drytime.pl -- the ESTIMATED trip and transit times (HardyCross::DryTime).
#
#   perl tools/test_drytime.pl
#
#   1. THE FORMULA.  t = 0.0352 V / (An sqrt T0) ln(pa0/pa) against the
#      worked example of the ASPE Pipeline article it is taken from, and its
#      constant against the isothermal choked blow-down it comes from, worked
#      here from the properties of air.
#   2. A MODEL, BY HAND.  The dry volume, the trip pressure (from the ratio,
#      from TRIP, from a given static), the trip time, the path time (sum of
#      L / v), the fill time (volume / flow) and the delivery estimate, each
#      worked again here from the solved network.
#   3. WHAT IT DOES NOT DO.  It changes no flow and no acceptance; it is not
#      worked without its inputs; a valve that cannot be set is rejected; a
#      dry part reaching a supply is refused; a trip below choked flow and an
#      accelerator are flagged.
#   4. THE LANGUAGE AND THE OUTPUT.  DPVTRIP refused when wrong; the report,
#      the JSON and the results block give the same times.
#
# These are estimates.  The tests check the arithmetic and the method as
# stated; they say nothing about how close an estimate is to a real system.
#==============================================================================
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";
use HardyCross;
use HardyCross::Phc;
use HardyCross::DryTime;
use HardyCross::Validate;
use HardyCross::Report;
use HardyCross::Json;
use HardyCross::Results;

my ($pass, $fail) = (0, 0);
sub is {
    my ($name, $ok, $why) = @_;
    printf "  %-68s %s\n", $name, $ok ? 'ok' : '*** FAIL';
    print "      $why\n" if !$ok && defined $why;
    $ok ? $pass++ : $fail++;
}
sub near { my ($a, $b, $t) = @_; defined $a && defined $b && abs($a - $b) <= $t }
my $PI = 3.14159265358979;

sub model {
    my (%o) = @_;
    return join "\n", 'UNITS LENGTH M', 'UNITS ELEVATION M', 'UNITS SIZE MM', 'UNITS PRESSURE KPA', 'UNITS FLOW LPM',
        'UNITS KFACTOR LPM/KPA', 'METHOD HW', 'USE BORE 120',
        $o{water} // 'WATER W 0 700 2000 500', 'NODE A 0', 'NODE B 3', 'SPRINKLER S1 3 -100 80', 'SPRINKLER S2 3 -100 80',
        'PIPE P12 W A 10 100', $o{dpv} // 'DPV P12 100 RATIO 5.5:1 ON VALVE TYCO DPV-1',
        (exists $o{air} ? ($o{air} // ()) : 'DPVAIR P12 280'), (exists $o{trip} ? ($o{trip} // ()) : 'DPVTRIP P12 12.7 1 5'),
        'PIPE PM A B 60 80', 'PIPE P2 B S1 5 50', 'PIPE P3 B S2 12 50', @{ $o{more} || [] }, '';
}
sub solved {
    my $net = HardyCross::Phc::read_string(shift);
    my $ok = HardyCross::solve_model($net);
    my $as = HardyCross::Validate::assess($net, $ok);
    return ($net, $ok, $as);
}
sub elem { my ($n, $id) = @_; my ($e) = grep { $_->{id} eq $id } @{ $n->{elems} }[1 .. $#{ $n->{elems} }]; $e }
sub codes { my $v = shift; my %c; $c{ $_->{code} } = $_->{severity} for @{ $v->{findings} }; \%c }
sub refused { my $t = shift; eval { HardyCross::Phc::read_string($t); 1 } ? '' : ($@->{msg} // "$@") }

#==============================================================================
print "1. THE FORMULA\n";
#==============================================================================
{
    # ASPE Pipeline, 19 August 2026: 800 gal, a 0.5 in. orifice, 11 F (the
    # article takes 471 R), 48.34 psia to 28.34 psia; the article gives
    # 67.94 s.
    my $v  = 800 * 0.13368;
    my $an = $PI * (0.5 / 12) ** 2 / 4;
    my $t  = HardyCross::DryTime::trip_time($v, $an, 471, 48.34, 28.34);
    is(sprintf('the article\'s worked example: %.2f s against its 67.94 s', $t), near($t, 67.94, 0.1));
    # The constant, from an isothermal blow-down of an ideal gas through a
    # choked orifice of discharge coefficient 1: air, gamma 1.4, R 1716 ft
    # lbf/(slug R).
    my ($g, $r) = (1.4, 1716);
    my $c = 1 / (sqrt($g * $r) * (2 / ($g + 1)) ** (($g + 1) / (2 * ($g - 1))));
    is(sprintf('the constant 0.0352 is the choked isothermal blow-down of air (%.5f)', $c), abs($c / 0.0352 - 1) < 0.005);
    # The same in SI: R 287.05 J/(kg K), V m3, A m2, T K.
    my $csi = 1 / (sqrt($g * 287.05) * (2 / ($g + 1)) ** (($g + 1) / (2 * ($g - 1))));
    my $tsi = $csi * ($v * 0.028316846592) / ($an * 0.09290304 * sqrt(471 / 1.8)) * log(48.34 / 28.34);
    is(sprintf('   and worked in SI it gives the same time (%.2f s)', $tsi), abs($tsi / $t - 1) < 0.005);
}

#==============================================================================
print "2. A MODEL, BY HAND\n";
#==============================================================================
my ($net, $ok, $as) = solved(model());
my ($d) = @{ $as->{dry} };
{
    my $vol = 0;
    $vol += $PI / 4 * (elem($net, $_)->{dia} / 1000) ** 2 * elem($net, $_)->{len} for qw(P12 PM P2 P3);
    is(sprintf('the dry volume is the four pipes downstream of the valve (%.4f m3)', $vol), near($d->{volume}, $vol, 1e-9));
    is('   and not the pipe or supply upstream of it', $d->{pipes} == 4);
    my $t = $d->{trip};
    is(sprintf('the trip pressure is the 700 kPa static / 5.5 (%.2f kPa)', $t->{trip_gauge}), near($t->{trip_gauge}, 700 / 5.5, 1e-9));
    my $hand = 0.0352 * ($vol / 0.028316846592) / ($PI / 4 * (12.7 / 25.4 / 12) ** 2 * sqrt((5 + 273.15) * 1.8))
             * log((280 + 101.325) / (700 / 5.5 + 101.325));
    is(sprintf('the trip time, by hand from those (%.3f s)', $hand), near($t->{seconds}, $hand, 1e-6), $t->{seconds});
    is('   it is an ESTIMATE, choked, the accelerator flagged', $t->{status} eq 'ESTIMATE' && $t->{choked}
       && $t->{accelerator_ignored});

    # The transit, at the demand point's flows.
    my $x = $d->{transit};
    my $fn = $as->{demand}{net};
    is("   the transit is at the demand point's flows ($x->{basis})", $x->{basis} eq 'demand point' && $fn);
    my $tp = 0;
    for my $id (qw(P12 PM P3)) {
        my $e = elem($fn, $id);
        $tp += $e->{len} / abs(HardyCross::pipe_velocity($e->{q}, $e->{dia}));
    }
    is(sprintf('the path P12 PM P3 to S2, sum of L / v by hand (%.3f s)', $tp),
       "@{ $x->{path_pipes} }" eq 'P12 PM P3' && $x->{remote} eq 'S2' && near($x->{path_seconds}, $tp, 1e-9));
    my $fill = $vol / (elem($fn, 'P12.DPV')->{q} / 60000);
    is(sprintf('the fill time, volume / the valve flow by hand (%.3f s)', $fill), near($x->{fill_seconds}, $fill, 1e-9));
    my $tr = $tp > $fill ? $tp : $fill;
    is('the transit is the larger, the delivery trip + transit',
       near($x->{seconds}, $tr, 1e-9) && near($d->{delivery}, $t->{seconds} + $tr, 1e-9));
}
{
    my (undef, undef, $a2) = solved(model(dpv => 'DPV P12 100 TRIP 140 ON VALVE TYCO DPV-1'));
    is('TRIP 140: the trip pressure is the setting, 140 kPa', near($a2->{dry}[0]{trip}{trip_gauge}, 140, 1e-9));
    (undef, undef, $a2) = solved(model(trip => 'DPVTRIP P12 12.7 2 5 600'));
    is('a static of 600 given, two heads open: 600 / 5.5, twice the area',
       near($a2->{dry}[0]{trip}{trip_gauge}, 600 / 5.5, 1e-9) && near($a2->{dry}[0]{trip}{area}, $d->{trip}{area} * 2, 1e-12)
       && $a2->{dry}[0]{trip}{static_given});
}

#==============================================================================
print "3. WHAT IT DOES NOT DO\n";
#==============================================================================
{
    my ($n2, $k2, $a2) = solved(model(air => undef, trip => undef));
    my $same = !grep { abs(elem($n2, $_->{id})->{q} - $_->{q}) > 1e-9 } grep { $_->{kind} eq 'PIPE' } @{ $net->{elems} }[1 .. $#{ $net->{elems} }];
    is('without DPVAIR and DPVTRIP: every flow the same, the same acceptance',
       $same && $a2->{validation}{acceptance} eq $as->{validation}{acceptance}, $a2->{validation}{acceptance});
    is('   and no trip time, saying what it needs', $a2->{dry}[0]{trip}{status} eq 'NOT_CALCULATED'
       && $a2->{dry}[0]{trip}{reason} =~ /DPVAIR.*DPVTRIP/);
    is('   the transit is still estimated: it needs no air data', $a2->{dry}[0]{transit}{status} eq 'ESTIMATE');
}
{
    my (undef, undef, $a2) = solved(model(air => 'DPVAIR P12 100'));
    is('set air 100 kPa below the 127 kPa trip: REJECTED, DPV_AIR_BELOW_TRIP',
       $a2->{validation}{acceptance} eq 'REJECTED' && (codes($a2->{validation})->{DPV_AIR_BELOW_TRIP} // '') eq 'error',
       $a2->{validation}{acceptance});
    (undef, undef, $a2) = solved(model(dpv => 'DPV P12 100 TRIP 40 ON VALVE TYCO DPV-1'));
    is('a trip of 40 kPa, below choked flow: a warning, DPV_TRIP_NOT_CHOKED',
       (codes($a2->{validation})->{DPV_TRIP_NOT_CHOKED} // '') eq 'warning' && !$a2->{dry}[0]{trip}{choked});
    (undef, undef, $a2) = solved(model(more => [ 'WATER W2 3 300', 'PIPE PX W2 B 20 50' ]));
    is('a dry part fed by a second supply: refused, DPV_NOT_DRY',
       (codes($a2->{validation})->{DPV_NOT_DRY} // '') eq 'error' && $a2->{dry}[0]{error});
}

#==============================================================================
print "4. THE LANGUAGE AND THE OUTPUT\n";
#==============================================================================
for my $bad ([ 'DPVTRIP P12 12.7 0', 'WHOLE NUMBER' ], [ 'DPVTRIP P12 12.7 1 70', 'OUTSIDE -50 TO 60' ],
             [ 'DPVTRIP P12 0', 'MORE THAN 0' ]) {
    my ($line, $want) = @$bad;
    my $e = refused(model(trip => $line));
    is("refused: $line", $e =~ /$want/, $e);
}
{
    my $e = refused(model(dpv => 'BFP P12 0 10', air => undef));
    is('refused: DPVTRIP on a pipe with no dry pipe valve', $e =~ /HAS NO DRY PIPE VALVE/, $e);
}
{
    my $rep = HardyCross::Report::write_report($net, $ok, 'dt.phc');
    my ($rt) = $rep =~ /TRIP TIME, ESTIMATE\s+([\d.]+) s/;
    my ($rx) = $rep =~ /TRANSIT TIME, ESTIMATE\s+([\d.]+) s/;
    my ($rd) = $rep =~ /DELIVERY TIME, ESTIMATE\s+([\d.]+) s/;
    is("the report: trip $rt, transit $rx, delivery $rd s", defined $rd && near($rt, $d->{trip}{seconds}, 0.05)
       && near($rx, $d->{transit}{seconds}, 0.05) && near($rd, $d->{delivery}, 0.05));
    is('   labelled estimates, not a listed method', $rep =~ /not a listed method/ && $rep =~ /lower bound/);
    my $j = HardyCross::Json::results($net, $ok, 'dt.phc');
    my $je = $j->{dry_pipe_valves}[0]{estimate};
    is('the JSON: the same times, delivery_time itself still null',
       near($je->{trip}{seconds}, $d->{trip}{seconds}, 0.05) && near($je->{delivery_seconds}, $d->{delivery}, 0.05)
       && !defined $j->{dry_pipe_valves}[0]{delivery_time});
    my $blk = HardyCross::Results::block($net, $ok, $net->{source_text});
    my ($bt) = $blk =~ /TRIP_S ([\d.]+)/;
    is("the results block: TRIP_S $bt", near($bt, $d->{trip}{seconds}, 0.05));
}

printf "\n%d passed, %d failed\n", $pass, $fail;
exit($fail ? 1 : 0);
