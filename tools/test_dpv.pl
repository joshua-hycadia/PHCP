#!/usr/bin/perl
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# test_dpv.pl -- the dry pipe valve, DPV.
#
#   perl tools/test_dpv.pl
#
#   1. THE LANGUAGE.  RATIO and TRIP, ON and OFF, the loss as points, one
#      fixed loss, or EQL and a length; DPVMODEL and DPVAIR; and every bad
#      line refused on its line.
#   2. THE HYDRAULICS, BY HAND.  The loss across the valve against the
#      Hazen-Williams formula for its equivalent length, worked here without
#      the engine; against its loss points; and a fixed loss.  The trip
#      setting and the accelerator change no number.
#   3. VALIDATION.  No loss data, water backwards through the valve, an
#      unusual trip ratio, an unlikely trip pressure.
#   4. THE OUTPUT.  Section 13 of the report and the JSON: the configuration,
#      the steady-state flow and loss, and no delivery time - which is not
#      calculated and is never implied.
#
# The valve is solved tripped and fully open.  Nothing here tests a trip or
# delivery time: there is no transient calculation to test.
#==============================================================================
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";
use HardyCross;
use HardyCross::Phc;
use HardyCross::Validate;
use HardyCross::Json;
use HardyCross::Report;

my $GW = $HardyCross::GAMMA_W;
my ($pass, $fail) = (0, 0);
sub is {
    my ($name, $ok, $why) = @_;
    printf "  %-68s %s\n", $name, $ok ? 'ok' : '*** FAIL';
    print "      $why\n" if !$ok && defined $why;
    $ok ? $pass++ : $fail++;
}
sub near { my ($a, $b, $t) = @_; defined $a && defined $b && abs($a - $b) <= $t }

sub model {
    my ($dpv, %o) = @_;
    return join "\n", 'UNITS LENGTH M', 'UNITS ELEVATION M', 'UNITS SIZE MM',
        'UNITS PRESSURE ' . ($o{pres} // 'KPA'), 'UNITS FLOW LPM', 'UNITS KFACTOR LPM/KPA', 'METHOD HW',
        'USE BORE 120',
        $o{water} // 'WATER W 0 700 2000 500',
        'NODE A 0', 'SPRINKLER S1 3 -100 80', 'SPRINKLER S2 3 -100 80',
        'PIPE P12 W A 10 100', $dpv, @{ $o{more} || [] },
        'PIPE P2 A S1 5 50', 'PIPE P3 A S2 8 50', '';
}
sub solve {
    my $net = HardyCross::Phc::read_string(shift);
    my $ok = HardyCross::solve_model($net);
    return ($net, $ok, HardyCross::Validate::validate($net, $ok));
}
sub dpv { my $n = shift; my ($e) = grep { $_->{kind} eq 'DPV' } @{ $n->{elems} }[1 .. $#{ $n->{elems} }]; $e }
sub refused {
    my $text = shift;
    return eval { HardyCross::Phc::read_string($text); 1 } ? '' : ($@->{msg} // "$@");
}
sub loss { my ($n, $e) = @_; return $n->{nodes}[ $e->{n1} ]{h} - $n->{nodes}[ $e->{n2} ]{h} }
sub codes { my $v = shift; my %c; $c{ $_->{code} } = $_->{severity} for @{ $v->{findings} }; \%c }

#==============================================================================
print "1. THE LANGUAGE\n";
#==============================================================================
{
    my ($n) = solve(model('DPV P12 100 RATIO 5.5:1 ON 1000 15 3000 40', more => [
        'DPVMODEL P12 MAKER X MODEL 100', 'DPVAIR P12 280' ]));
    my $e = dpv($n);
    is('RATIO 5.5:1 ON with loss points: read', $e && $e->{trip_mode} eq 'RATIO' && $e->{trip_ratio} == 5.5
       && $e->{accelerator} eq 'ON' && $e->{loss} eq 'CURVE' && $e->{size} == 100);
    is('   the valve is P12.DPV, in pipe P12', $e->{id} eq 'P12.DPV' && $e->{host_id} eq 'P12');
    is('   DPVMODEL kept as typed', ($e->{model} // '') eq 'MAKER X MODEL 100');
    is('   DPVAIR kept for the transient model, in kPa', near($e->{transient}{air_initial}, 280, 1e-9));
    is('   the transient record reserves every field, delivery time undefined',
       $e->{transient}{state} eq 'TRIPPED_OPEN' && !defined $e->{transient}{delivery_time}
       && exists $e->{transient}{dry_volume} && exists $e->{transient}{venting}
       && "@{ $e->{transient}{states} }" eq 'SET PRESSURE_DECAY TRIPPED FILLING WATER_DELIVERY');
}
{
    my ($n) = solve(model('DPV P12 100 TRIP 1.4 OFF EQL 6.1', pres => 'BAR',
                          water => 'WATER W 0 7 2000 5'));
    my $e = dpv($n);
    is('TRIP 1.4 in bar is 140 kPa; accelerator OFF; EQL', near($e->{trip_pressure}, 140, 1e-9)
       && $e->{accelerator} eq 'OFF' && $e->{loss} eq 'EQL' && near($e->{eql}, 6.1, 1e-12));
}
{
    my ($n) = solve(model('DPV P12 4 RATIO 6 ON 0 20') =~ s/UNITS SIZE MM/UNITS SIZE IN/r =~ s/PIPE (\S+) (\S+) (\S+) (\S+) (\d+)/"PIPE $1 $2 $3 $4 " . ($5 \/ 25)/ger);
    my $e = dpv($n);
    is('a size in inches: 4 is DN100; one pair at flow 0 is a fixed loss',
       $e && $e->{size} == 100 && near($e->{fixed_loss}, 20, 1e-9));
}
for my $bad ([ 'DPV P12 100 RATIO 1 ON',          'MORE THAN 1:1' ],
             [ 'DPV P12 100 RATIO X ON',          'IS NOT A RATIO' ],
             [ 'DPV P12 100 TRIP 0 ON',           'MORE THAN 0' ],
             [ 'DPV P12 100 PRESSURE 140 ON',     'RATIO .* OR TRIP' ],
             [ 'DPV P12 100 RATIO 5.5 MAYBE',     'ON OR OFF' ],
             [ 'DPV P12 100 RATIO 5.5 ON EQL',    'NEEDS THE EQUIVALENT LENGTH' ],
             [ 'DPV P12 100 RATIO 5.5 ON EQL 0',  'MORE THAN 0' ],
             [ 'DPV P12 100 RATIO 5.5 ON 1000',   'NEEDS THE LOSS TO PAIR' ],
             [ 'DPV P12 100 RATIO 5.5 ON 100 5',  'ITS FLOW MUST BE 0' ],
             [ 'DPV P12 100 RATIO 5.5 ON 0 5 X',  'IS NOT A NUMBER' ]) {
    my ($line, $want) = @$bad;
    my $e = refused(model($line));
    is("refused: $line", $e =~ /$want/, $e);
}
{
    my $e = refused(model('BFP P12 0 10', more => [ 'DPVMODEL P12 X' ]));
    is('refused: DPVMODEL on a pipe with no dry pipe valve', $e =~ /HAS NO DRY PIPE VALVE/, $e);
    $e = refused(model('DPV P12 100 RATIO 5.5 ON EQL 6', more => [ 'BFP P12 0 10' ]));
    is('refused: a second device in the same pipe', $e =~ /ALREADY HAS A DEVICE/, $e);
}

#==============================================================================
print "2. THE HYDRAULICS, BY HAND\n";
#==============================================================================
{
    # Hazen-Williams, AS 2118.1 metric form: p = 6.05e7 L Q^1.85 / (C^1.85 d^4.87)
    # kPa, Q in L/min, d in mm.  The valve's 6.1 m of 100 mm pipe at C 120.
    my ($n, $ok, $v) = solve(model('DPV P12 100 RATIO 5.5:1 ON EQL 6.1'));
    my $e = dpv($n);
    my $hand = 6.05e7 * 6.1 * $e->{q} ** 1.85 / (120 ** 1.85 * 100 ** 4.87);
    is(sprintf('EQL: the loss across the valve is the HW loss of 6.1 m (%.4f against %.4f kPa)', loss($n, $e), $hand),
       $ok && near(loss($n, $e), $hand, 1e-6));
    is("   ACCEPTED ($v->{acceptance}), the DPV checks pass", $v->{acceptance} eq 'ACCEPTED'
       && !grep { $_->{code} =~ /^DPV/ && $_->{severity} eq 'error' } @{ $v->{findings} });
}
{
    # Loss points 1000 L/min at 15 kPa and 3000 at 40, straight in Q^1.85
    # between them, as every curve in PHCP is read.
    my ($n, $ok) = solve(model('DPV P12 100 RATIO 5.5:1 ON 1000 15 3000 40'));
    my $e = dpv($n);
    my $x = ($e->{q} ** 1.85 - 1000 ** 1.85) / (3000 ** 1.85 - 1000 ** 1.85);
    my $hand = 15 + 25 * $x;
    is(sprintf('CURVE: the loss is read off its points (%.4f against %.4f kPa)', loss($n, $e), $hand),
       $ok && $e->{q} > 1000 && $e->{q} < 3000 && near(loss($n, $e), $hand, 1e-6));
}
{
    my ($n, $ok) = solve(model('DPV P12 100 RATIO 5.5:1 ON 0 20'));
    my $e = dpv($n);
    is(sprintf('a fixed loss of 20 kPa (%.4f)', loss($n, $e)), $ok && near(loss($n, $e), 20, 1e-6));
}
{
    my ($a) = solve(model('DPV P12 100 RATIO 5.5:1 ON EQL 6.1'));
    my ($b) = solve(model('DPV P12 100 RATIO 6:1 OFF EQL 6.1'));
    my ($c) = solve(model('DPV P12 100 TRIP 140 ON EQL 6.1'));
    is('the trip setting and the accelerator change no flow',
       near(dpv($a)->{q}, dpv($b)->{q}, 1e-9) && near(dpv($a)->{q}, dpv($c)->{q}, 1e-9));
    my ($p) = solve(join "\n", grep { !/^DPV/ } split /\n/, model('DPV P12 100 RATIO 5.5 ON EQL 6.1') =~ s/PIPE P12 W A 10 100/PIPE P12 W A 16.1 100/r);
    my ($q12) = grep { $_->{id} eq 'P12' } @{ $p->{elems} }[1 .. $#{ $p->{elems} }];
    is('   EQL 6.1 m solves as the same pipe 6.1 m longer', near(dpv($a)->{q}, $q12->{q}, 1e-4),
       dpv($a)->{q} . " $q12->{q}");
}

#==============================================================================
print "3. VALIDATION\n";
#==============================================================================
{
    my ($n, $ok, $v) = solve(model('DPV P12 100 RATIO 5.5:1 ON'));
    is('no loss data: REJECTED, DPV_NO_LOSS_DATA (no loss is assumed)',
       $v->{acceptance} eq 'REJECTED' && codes($v)->{DPV_NO_LOSS_DATA}, $v->{acceptance});
}
{
    my ($n, $ok, $v) = solve(model('DPV P12 100 RATIO 12:1 ON EQL 6.1'));
    is('a ratio of 12:1: a warning to check it, not a failure',
       (codes($v)->{DPV_RATIO_RANGE} // '') eq 'warning' && $v->{acceptance} eq 'ACCEPTED', $v->{acceptance});
}
{
    my ($n, $ok, $v) = solve(model('DPV P12 100 TRIP 900 ON EQL 6.1'));
    is('an air trip pressure of 900 kPa: REJECTED, DPV_TRIP_PRESSURE',
       $v->{acceptance} eq 'REJECTED' && codes($v)->{DPV_TRIP_PRESSURE}, $v->{acceptance});
}
{
    my ($n, $ok, $v) = solve(model('DPV P12 15 RATIO 5.5 ON EQL 6.1'));
    is('DN15 is not a dry pipe valve: REJECTED, DPV_SIZE', $v->{acceptance} eq 'REJECTED' && codes($v)->{DPV_SIZE});
}
{
    # A stronger supply downstream drives water back through the valve.
    my ($n, $ok, $v) = solve(model('DPV P12 100 RATIO 5.5 ON EQL 6.1', more => [ 'WATER W2 0 900', 'PIPE P9 W2 A 5 100' ]));
    is('water backwards through the valve: REJECTED, DPV_REVERSE',
       dpv($n)->{q} < 0 && $v->{acceptance} eq 'REJECTED' && codes($v)->{DPV_REVERSE}, dpv($n)->{q});
}

#==============================================================================
print "3a. VALVES FROM THE DATABASE\n";
#==============================================================================
{
    # Each against a figure printed on its data sheet: the loss at a flow.
    require HardyCross::PipeData;
    for my $c ([ 'TYCO', 'DPV-1', 100, 600, 1.25, 'TFP1020 Graph A' ], [ 'VIKING', 'VXR', 100, 1000, 7.59, 'chart F_110325' ],
               [ 'VIKING', 'F-1', 150, 1750, 4.85, 'chart F_061909' ], [ 'VIKING', 'VXR', 65, 400, 7.92, 'chart F_110525' ]) {
        my ($mk, $md, $dn, $gpm, $psi, $src) = @$c;
        my ($n) = solve(model("DPV P12 $dn RATIO 6 ON VALVE $mk $md", water => 'WATER W 0 1000'));
        my $e = dpv($n);
        my ($hf) = HardyCross::elem_hf($e, $gpm * 3.785411784, $n->{opts});
        is(sprintf('%s %s DN%d: %.3f psi at %d gpm against %.2f printed (%s)', $mk, $md, $dn, $hf / 6.894757, $gpm, $psi, $src),
           abs($hf / 6.894757 - $psi) <= 0.01 * $psi + 0.005);
    }
    my ($n, $ok, $v) = solve(model('DPV P12 100 RATIO 5.5 ON VALVE TYCO DPV-1'));
    is("TYCO DPV-1 DN100 in a model: $v->{acceptance}, its loss across the valve",
       $v->{acceptance} eq 'ACCEPTED' && near(loss($n, dpv($n)), (HardyCross::elem_hf(dpv($n), dpv($n)->{q}, $n->{opts}))[0], 1e-9));
    (undef, undef, $v) = solve(model('DPV P12 80 RATIO 5.5 ON VALVE TYCO DPV-1'));
    is('TYCO DPV-1 DN80: the data sheet\'s own conflict is a warning (DPV_DATA_NOTE)',
       (codes($v)->{DPV_DATA_NOTE} // '') eq 'warning');
    (undef, undef, $v) = solve(model('DPV P12 100 RATIO 5.5 ON VALVE RELIABLE DDX-LP'));
    is('a low-pressure valve given a ratio: a warning (DPV_RATIO_DB)', (codes($v)->{DPV_RATIO_DB} // '') eq 'warning');
    (undef, undef, $v) = solve(model('DPV P12 100 RATIO 3 ON VALVE VIKING F-1'));
    is('a ratio far from the data sheet\'s: a warning (DPV_RATIO_DB)', (codes($v)->{DPV_RATIO_DB} // '') eq 'warning');
    (undef, undef, $v) = solve(model('DPV P12 100 RATIO 6 ON VALVE RELIABLE D'));
    is('a legacy valve: a warning (DPV_LEGACY)', (codes($v)->{DPV_LEGACY} // '') eq 'warning');
    (undef, undef, $v) = solve(model('DPV P12 100 RATIO 6 ON VALVE VIKING F-1', water => 'WATER W 0 1600'));
    is('above its rated working pressure (175 psi): REJECTED, DPV_PRESSURE_RATING',
       $v->{acceptance} eq 'REJECTED' && (codes($v)->{DPV_PRESSURE_RATING} // '') eq 'error', $v->{acceptance});
    {
        # Victaulic: a flow coefficient, dP psi = (Q gpm / Cv)^2, Cv 350 for
        # the 768N DN100 (31.80).
        my ($nv, $kv, $vv) = solve(model('DPV P12 100 RATIO 6 ON VALVE VICTAULIC 768N'));
        my $gpm = dpv($nv)->{q} / 3.785411784;
        is(sprintf('VICTAULIC 768N DN100: the loss is (Q/Cv)^2 at its flow (%.4f kPa)', loss($nv, dpv($nv))),
           near(loss($nv, dpv($nv)), ($gpm / 350) ** 2 * 6.894757, 1e-6));
        my $rv = HardyCross::Report::write_report($nv, $kv, 'v.phc');
        is('   the report gives the Cv and its source', $rv =~ /flow\s+coefficient Cv 350/ && $rv =~ /31\.80/);
        my $e756 = refused(model('DPV P12 100 RATIO 6 ON VALVE VICTAULIC 756'));
        is('refused: the 756, whose sheet gives no usable loss, with the reason', $e756 =~ /NO USABLE LOSS.*NO CV/, $e756);
    }
    my $e = refused(model('DPV P12 100 RATIO 6 ON VALVE ACME X1'));
    is('refused: a valve not in the database, the ones that are listed', $e =~ /IS NOT A DRY PIPE VALVE IN THE DATABASE \(.*TYCO DPV-1/, $e);
    $e = refused(model('DPV P12 200 RATIO 6 ON VALVE VIKING F-1'));
    is('refused: a size the valve does not come in, the sizes it does', $e =~ /IN DN80, DN100, DN150 ONLY, NOT DN200/, $e);
    my $net = HardyCross::Phc::read_string(model('DPV P12 100 RATIO 5.5 ON VALVE TYCO DPV-1'));
    my $k = HardyCross::solve_model($net);
    my $rep = HardyCross::Report::write_report($net, $k, 'dpv.phc');
    is('the report names the database valve, its basis and its source',
       $rep =~ /the pipe and fitting database: TYCO DPV-1 DN100, 8\.9 ft of Schedule 40 pipe/ && $rep =~ /TFP1020/);
}

#==============================================================================
print "4. THE OUTPUT\n";
#==============================================================================
{
    my $net = HardyCross::Phc::read_string(model('DPV P12 100 RATIO 5.5:1 ON EQL 6.1',
                                                 more => [ 'DPVMODEL P12 MAKER X' ]));
    my $ok = HardyCross::solve_model($net);
    my $rep = HardyCross::Report::write_report($net, $ok, 'dpv.phc');
    is('the report has Section 13, DRY PIPE VALVES', $rep =~ /13\. DRY PIPE VALVES/);
    is('   the trip, the accelerator, the model and the loss basis',
       $rep =~ /differential ratio 5\.50:1/ && $rep =~ /Accelerator\s+ON/ && $rep =~ /MAKER X/
       && $rep =~ /equivalent length 6\.10 m of pipe P12/);
    my $words = join '\s+', map { quotemeta } split ' ', 'No trip time, transit time or water delivery time is calculated';
    is('   and says no delivery time is calculated', $rep =~ /$words/);
    my $j = HardyCross::Json::results($net, $ok, 'dpv.phc', demand => 0);
    my ($d) = @{ $j->{dry_pipe_valves} };
    my ($hf) = HardyCross::elem_hf(dpv($net), dpv($net)->{q}, $net->{opts});
    is('the JSON lists the valve: ratio, accelerator, flow and loss',
       $d && $d->{trip_method} eq 'RATIO' && $d->{trip_ratio} == 5.5 && $d->{accelerator} eq 'ON'
       && near($d->{flow}, dpv($net)->{q}, 1e-3) && near($d->{loss}, $hf, 1e-3) && $d->{validation} eq 'PASS');
    is('   delivery time null, and marked not calculated', !defined $d->{delivery_time}
       && !$d->{delivery_time_calculated});
    is('   the steady-state assumption is in the traceability',
       grep { /dry pipe valve tripped and fully open/ } @{ $j->{traceability}{assumptions} });
}

printf "\n%d passed, %d failed\n", $pass, $fail;
exit($fail ? 1 : 0);
