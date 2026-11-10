#!/usr/bin/perl
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# test_supplies.pl -- several water supplies (HardyCross::Supplies).
#
#   perl tools/test_supplies.pl
#
#   1. OPERATING.  Each supply's own flow and pressure; their signed sum
#      against the net demand; a supply taking water in is named.
#   2. ONE SUPPLY.  The conditional and the joint demand of a model with one
#      supply are its demand point (HardyCross::Demand), found independently.
#   3. CONDITIONAL.  At each supply's conditional minimum the governing outlet
#      receives its minimum, the others as modelled, and half a kPa less is
#      not enough.  A supply the others can do without is NOT REQUIRED.
#   4. JOINT.  One solve: re-solved at the derating found, the governing
#      margin is zero, the flows add up, and every supply has the same margin
#      on the DERATE basis; on SCALE every pressure is the same fraction of
#      what the supply gives.  The joint contribution is not the conditional
#      minimum.
#   5. SCENARIOS.  Each supply alone and each out of service, and the SCENARIO
#      lines: each solved and validated on its own; a SCENARIO line that is not
#      ACCEPTED fails the design.  The language refuses a bad SCENARIO.
#   6. REPORT AND JSON.  Section 12 and the JSON supplies block, the same
#      numbers.
#
# These tests check PHCP against the conditions it sets itself; they are not
# evidence of external certification.
#==============================================================================
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";
use HardyCross;
use HardyCross::Parse;
use HardyCross::Phc;
use HardyCross::Demand;
use HardyCross::Supplies;
use HardyCross::Validate;
use HardyCross::Json;
use HardyCross::Report;

my $EX = "$FindBin::Bin/../examples";
my ($pass, $fail) = (0, 0);
sub is {
    my ($name, $ok, $why) = @_;
    printf "  %-68s %s\n", $name, $ok ? 'ok' : '*** FAIL';
    print "      $why\n" if !$ok && defined $why;
    $ok ? $pass++ : $fail++;
}
sub near { my ($a, $b, $t) = @_; defined $a && defined $b && abs($a - $b) <= $t }

my $HEAD = join "\n", 'UNITS LENGTH M', 'UNITS ELEVATION M', 'UNITS SIZE MM', 'UNITS PRESSURE KPA',
                      'UNITS FLOW LPM', 'UNITS KFACTOR LPM/KPA', 'METHOD HW', 'USE BORE 120', '';
# Two supplies of different strength, at different elevations and places,
# feeding two sprinklers and a hydrant.
my $TWO = $HEAD . <<'EOF';
WATER WA 0 700 1500 550 3000 300
WATER WB 2 450 1000 380 2000 200
NODE J1 0
NODE J2 1
SPRINKLER S1 4 -100 80
SPRINKLER S2 4 -100 80
HYDRANT H1 1 -350 65
PIPE A1 WA J1 30 150
PIPE B1 WB J2 60 100
PIPE J12 J1 J2 50 100
PIPE R1 J2 S1 10 50
PIPE R2 J2 S2 15 50
PIPE HY J1 H1 20 100
EOF
sub solved { my $n = HardyCross::Phc::read_string(shift); my $ok = HardyCross::solve_model($n); ($n, $ok) }
sub sup { my ($n, $id) = @_; my ($s) = grep { $_->{id} eq $id } HardyCross::Demand::supplies($n); $s }

my ($net, $ok) = solved($TWO);
my $r = HardyCross::Supplies::analyse($net, $ok);

#==============================================================================
print "1. OPERATING\n";
#==============================================================================
is('two supplies: solved and ACCEPTED', $ok && HardyCross::Validate::validate($net, $ok)->{acceptance} eq 'ACCEPTED');
is(sprintf('the signed sum of the supplies is the net demand (%.3g L/min apart)', $r->{balance}),
   abs($r->{balance}) < 1e-6);
my %op = map { $_->{id} => $_ } @{ $r->{operating} };
is('each supply has its own flow, unequal', abs($op{WA}{flow} - $op{WB}{flow}) > 100,
   "$op{WA}{flow} $op{WB}{flow}");
is('each supply has its own pressure, unequal', abs($op{WA}{pressure} - $op{WB}{pressure}) > 10);
is('   and each is on its own curve at its own flow',
   near($op{WA}{pressure}, HardyCross::curve_eval(sup($net, 'WA')->{curve}, $op{WA}{flow}), 0.02)
   && near($op{WB}{pressure}, HardyCross::curve_eval(sup($net, 'WB')->{curve}, $op{WB}{flow}), 0.02));
is('the shares add to 100 %', near($op{WA}{share} + $op{WB}{share}, 100, 1e-9));
{
    my ($n, $k) = solved($HEAD . "WATER WA 0 800\nWATER WB 0 200\nNODE A 0\nSPRINKLER S1 0 -50 80\n"
                         . "PIPE P1 WA A 10 50\nPIPE P2 WB A 10 50\nPIPE P3 A S1 5 25\n");
    my $o = HardyCross::Supplies::operating($n);
    my ($wb) = grep { $_->{id} eq 'WB' } @$o;
    is('a supply taking water in is REVERSE, its flow negative', $wb->{status} eq 'REVERSE' && $wb->{flow} < 0);
}

#==============================================================================
print "2. ONE SUPPLY\n";
#==============================================================================
{
    my ($n, $k) = solved(do { local $/; open my $f, '<', "$EX/01_single_branch.phc" or die; <$f> });
    my $dm = HardyCross::Demand::demand_point($n);
    my $c  = HardyCross::Supplies::conditional($n, $dm->{supply}{id});
    my $j  = HardyCross::Supplies::joint($n);
    is(sprintf('the conditional minimum is the demand point (%.2f against %.2f kPa)', $c->{pressure}, $dm->{p_demand}),
       near($c->{pressure}, $dm->{p_demand}, 0.05));
    my ($js) = @{ $j->{supplies} };
    is(sprintf('the joint demand is the demand point (%.2f against %.2f kPa)', $js->{pressure}, $dm->{p_demand}),
       near($js->{pressure}, $dm->{p_demand}, 0.05) && near($js->{flow}, $dm->{q_system}, 0.001 * $dm->{q_system}));
    is('   and its margin is the demand point\'s', near($j->{margin}, $dm->{margin}, 0.05), "$j->{margin} $dm->{margin}");
}

#==============================================================================
print "3. CONDITIONAL\n";
#==============================================================================
for my $c (@{ $r->{conditional} }) {
    is("$c->{id}: REQUIRED, ACCEPTED", $c->{status} eq 'REQUIRED' && $c->{acceptance} eq 'ACCEPTED',
       "$c->{status} $c->{acceptance}");
    my ($k1, $n1) = HardyCross::Demand::solve_at($net->{source_text}, $c->{id}, $c->{pressure});
    my (undef, $m1) = HardyCross::Demand::governing_outlet($n1);
    my ($k2, $n2) = HardyCross::Demand::solve_at($net->{source_text}, $c->{id}, $c->{pressure} - 0.5);
    my (undef, $m2) = HardyCross::Demand::governing_outlet($n2);
    is(sprintf('   at %.2f kPa the governing margin is zero (%.4f), 0.5 kPa less fails', $c->{pressure}, $m1),
       $k1 && $m1 >= 0 && $m1 < 0.05 && $m2 < 0);
    is('   the other supply as modelled (its curve), not reversed', !@{ $c->{others_reverse} });
}
{
    my ($n, $k) = solved(do { local $/; open my $f, '<', "$EX/09_parallel_pumps.phc" or die; <$f> });
    my $c = HardyCross::Supplies::conditional($n, 'PA');
    is('09: PA is NOT REQUIRED - the other two meet every outlet without it', $c->{status} eq 'NOT_REQUIRED');
}

#==============================================================================
print "4. JOINT\n";
#==============================================================================
my $j = $r->{joint};
is("DERATE: found, ACCEPTED, D = " . sprintf('%.2f kPa', $j->{delta} // 0),
   !$j->{reason} && $j->{acceptance} eq 'ACCEPTED' && defined $j->{delta});
{
    my $n = HardyCross::Phc::read_string($TWO);
    for my $s (HardyCross::Demand::supplies($n)) {
        $s->{curve} = HardyCross::Supplies::shifted($s->{curve}, sub { $_[0] - $j->{delta} });
    }
    my $k = HardyCross::solve_model($n);
    my (undef, $m) = HardyCross::Demand::governing_outlet($n);
    is(sprintf('   one solve: re-solved at D the governing margin is zero (%.4f kPa)', $m), $k && $m >= 0 && $m < 0.05);
    my $qt = 0;
    $qt += $_->{q} for HardyCross::Demand::supplies($n);
    is('   its flows are the joint flows, and add to the total',
       near($qt, $j->{q_total}, 1e-6) && !grep { !near($_->{flow}, sup($n, $_->{id})->{q}, 1e-6) } @{ $j->{supplies} });
}
is('   every supply has the same margin, D',
   !grep { !near($_->{margin}, $j->{delta}, 1e-6) } @{ $j->{supplies} });
is('   each supply at its own pressure, not one common pressure',
   abs($j->{supplies}[0]{pressure} - $j->{supplies}[1]{pressure}) > 10);
my %cond = map { $_->{id} => $_ } @{ $r->{conditional} };
is('   the joint contribution is not the conditional minimum',
   !grep { near($_->{flow}, $cond{ $_->{id} }{flow}, 1) } @{ $j->{supplies} });
{
    my ($n, $k) = solved($TWO . "OPTION JOINT_BASIS SCALE\n");
    my $js = HardyCross::Supplies::joint($n);
    is(sprintf('SCALE: found, F = %.4f', $js->{factor} // 0), !$js->{reason} && defined $js->{factor});
    is('   every supply\'s pressure is F times what it gives at its flow',
       !grep { !near($_->{pressure}, $js->{factor} * $_->{available}, 0.01) } @{ $js->{supplies} });
}

#==============================================================================
print "5. SCENARIOS\n";
#==============================================================================
my %sc = map { $_->{name} => $_ } @{ $r->{scenarios} };
is('each supply alone and each out of service (ONLY-WA, ONLY-WB)', $sc{'ONLY-WA'} && $sc{'ONLY-WB'});
is('   with two supplies, WITHOUT-WA is ONLY-WB and is not repeated', !$sc{'WITHOUT-WA'});
is('   a supply out of service gives nothing',
   !grep { $_->{status} eq 'OUT_OF_SERVICE' && $_->{flow} != 0 } map { @{ $_->{supplies} } } values %sc);
is('   each is validated on its own', !grep { !$_->{acceptance} } values %sc);
{
    my ($n, $k) = solved($TWO . "SCENARIO WEAKA WA 70\n");
    my $as = HardyCross::Validate::assess($n, $k);
    my ($w) = grep { $_->{name} eq 'WEAKA' } @{ $as->{supplies}{scenarios} };
    is("SCENARIO WEAKA (WA at 70 %): solved, $w->{acceptance}", $w && $w->{required});
    my ($wa) = grep { $_->{id} eq 'WA' } @{ $w->{supplies} };
    is('   WA at 70 % of its pressure', $wa->{percent} == 70);
    is('   not ACCEPTED, so the design fails on it (SCENARIO)', $w->{acceptance} ne 'ACCEPTED'
       && grep { $_->{code} eq 'SCENARIO' && $_->{item} eq 'WEAKA' } @{ $as->{validation}{findings} });
    my ($n2, $k2) = solved($TWO . "OPTION SUPPLY_SCENARIOS OFF\nSCENARIO NOB WB 0\n");
    my $r2 = HardyCross::Supplies::analyse($n2, $k2);
    is('OPTION SUPPLY_SCENARIOS OFF: only the SCENARIO lines', @{ $r2->{scenarios} } == 1
       && $r2->{scenarios}[0]{name} eq 'NOB');
}
for my $bad ([ 'SCENARIO X WC 0', 'NOT DEFINED' ], [ 'SCENARIO X J1 0', 'NOT A WATER SUPPLY' ],
             [ 'SCENARIO X WA 120', '0 \(OUT OF SERVICE\) TO 100' ], [ 'SCENARIO X WA 50 WA 20', 'TWICE' ]) {
    my ($line, $want) = @$bad;
    my $e = eval { HardyCross::Phc::read_string($TWO . "$line\n"); 1 } ? '' : $@->{msg};
    is("refused: $line", $e =~ /$want/, $e);
}
{
    # With one supply there is nothing for a scenario to share out, and the
    # line would otherwise be read and never solved.
    my $one = $HEAD . "WATER W 0 500\nNODE A 0\nSPRINKLER S1 0 -50 80\nPIPE P1 W A 10 50\nPIPE P2 A S1 5 25\n";
    my $e = eval { HardyCross::Phc::read_string($one . "SCENARIO LOW W 80\n"); 1 } ? '' : $@->{msg};
    is('refused: a SCENARIO in a model with one supply', $e =~ /MORE THAN ONE WATER SUPPLY/, $e);
}

#==============================================================================
print "6. REPORT AND JSON\n";
#==============================================================================
{
    my $rep = HardyCross::Report::write_report($net, $ok, 'two.phc');
    is('the report has Section 12, MULTIPLE WATER SUPPLIES', $rep =~ /12\. MULTIPLE WATER SUPPLIES/);
    is('   operating, conditional, joint and scenarios', $rep =~ /A\. OPERATING/ && $rep =~ /B\. CONDITIONAL/
       && $rep =~ /C\. JOINT DEMAND/ && $rep =~ /D\. SUPPLY SCENARIOS/);
    is('   saying the conditional minima are not added', $rep =~ /they are not\s+added/);
    my $jj = HardyCross::Json::results($net, $ok, 'two.phc');
    is('the JSON has the supplies block, with the same derating',
       $jj->{supplies} && near($jj->{supplies}{joint}{derating}, $j->{delta}, 1e-3));
    is('   and the same conditional minima', !grep { my $c = $_;
        !near($c->{required_pressure}, $cond{ $c->{id} }{pressure}, 1e-3) } @{ $jj->{supplies}{conditional} });
}

printf "\n%d passed, %d failed\n", $pass, $fail;
exit($fail ? 1 : 0);
