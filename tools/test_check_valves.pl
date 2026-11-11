#!/usr/bin/perl
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# test_check_valves.pl -- non-return (check) valves at water supplies, and the
# defects found in the audit of 11 November 2026 (second stage).
#
#   perl tools/test_check_valves.pl
#
# Every case was written BEFORE the code it tests and failed on main at
# 1e196b8 (PHCP 1.5.0 with the acceptance hardening of PR 47).  The parts:
#
#   1. DEFECTS.  A gravity tank -- a supply at 0 kPa gauge, high above the
#      outlets, the reference manual's own example -- was REJECTED as "not
#      reachable from any supply", and its demand point came out a hair ABOVE
#      zero, so the supply failed its adequacy check by -0.0 kPa.
#   2. THE NRV COMMAND.  What it accepts and what it refuses.
#   3. NO CHANGE WHERE NONE IS DUE.  A check valve with no loss on a supply
#      that delivers leaves every flow and pressure exactly as before.
#   4. CLOSING.  A supply that would take water in closes, carries nothing,
#      and the rest of the network is solved without it -- to the same answer
#      as the model with that supply deleted.
#   5. REOPENING.  A closed supply whose pressure would now drive water in
#      opens again; one that cannot settle is not taken as settled.
#   6. ISOLATION.  A single supply whose valve closes leaves the outlets with
#      no water: that is LOSS OF SUPPLY (NONCOMPLIANT, SUPPLY_ISOLATED), not a
#      numerical failure and not a pass.  Part of a network isolated the same
#      way is reported for that part only.
#   7. CHANGING DEMAND.  A weak supply closed at a small demand opens at a
#      large one.
#   8. DEMAND SEARCHES.  The joint demand, the conditional minima and the
#      scenarios run with the valves operating: a supply shut on its valve is
#      not a supply found too weak, and not an invalid trial.
#   9. THE VALVE'S LOSS.  Its opening pressure and its Cv loss, checked from
#      the solved heads against the data-sheet definition worked here.
#  10. REPORTING.  The JSON and the report give each supply's valve, state,
#      flow, pressure and loss, and agree with each other on acceptance.
#  11. EQUIVALENT DESCRIPTIONS.  Renamed nodes, reordered lines, pipes drawn
#      the other way and other units give the same answer.
#
# These tests check PHCP against the conditions it sets itself.  They are not
# evidence of conformance with any Standard or of external certification.
#==============================================================================
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";
use HardyCross;
use HardyCross::Phc;
use HardyCross::Validate;
use HardyCross::Demand;
use HardyCross::Supplies;
use HardyCross::Json;
use HardyCross::Report;
use JSON::PP;

my ($pass, $fail) = (0, 0);
sub is {
    my ($name, $ok, $why) = @_;
    printf "  %-70s %s\n", $name, $ok ? 'ok' : '*** FAIL';
    print "      $why\n" if !$ok && defined $why;
    $ok ? $pass++ : $fail++;
}
sub near { my ($a, $b, $t) = @_; defined $a && defined $b && abs($a - $b) <= $t }

my $HEAD = join "\n", 'UNITS LENGTH M', 'UNITS ELEVATION M', 'UNITS SIZE MM', 'UNITS PRESSURE KPA',
                      'UNITS FLOW LPM', 'UNITS KFACTOR LPM/KPA', 'METHOD HW', 'USE BORE 120', '';
# WA is strong and far, WB weak and next to the sprinkler: as modelled
# without a check valve, WB takes water in (tools/impossible/supply_takes_water_in.phc).
my $TWO = "WATER WA 0 1000\nWATER WB 0 520\nNODE J1 0\nNODE J2 0\nSPRINKLER S1 0 -100 80\n"
        . "PIPE A1 WA J1 40 65\nPIPE B1 WB J2 5 100\nPIPE J12 J1 J2 5 100\nPIPE R1 J2 S1 5 50\n";
# The same network with WB deleted (its pipe B1 too): what the valve closing
# must reproduce.
my $ONLY_A = "WATER WA 0 1000\nNODE J1 0\nNODE J2 0\nSPRINKLER S1 0 -100 80\n"
           . "PIPE A1 WA J1 40 65\nPIPE J12 J1 J2 5 100\nPIPE R1 J2 S1 5 50\n";

sub refused {
    my $text = shift;
    my $n = eval { HardyCross::Phc::read_string($text) };
    return undef if $n;
    my $e = $@;
    return ref $e ? $e->{msg} : "$e";
}
sub solve {
    my $net = HardyCross::Phc::read_string(shift);
    my $ok = HardyCross::solve_model($net);
    return ($net, $ok);
}
sub assessed {
    my ($net, $ok) = solve(shift);
    return ($net, $ok, HardyCross::Validate::assess($net, $ok));
}
sub errs { my $v = shift; my %c; $c{ $_->{code} }++ for grep { $_->{severity} eq 'error' } @{ $v->{findings} }; \%c }
sub elem { my ($n, $id) = @_; my ($e) = grep { ($_->{id} // '') eq $id } @{ $n->{elems} }[1 .. $#{ $n->{elems} }]; $e }
sub node { my ($n, $id) = @_; my ($x) = grep { ($_->{id} // '') eq $id } @{ $n->{nodes} }[1 .. $#{ $n->{nodes} }]; $x }
sub gauge { my ($n, $id) = @_; my $x = node($n, $id); $x->{h} - $HardyCross::GAMMA_W * $x->{z} }
sub list { my $h = shift; join(',', sort keys %$h) || 'none' }

#==============================================================================
print "1. DEFECTS\n";
#==============================================================================
{
    # A tank 30 m above the outlets, open to air: 0 kPa gauge at its surface,
    # 294 kPa of head at the sprinkler's level before losses.
    my $TANK = "WATER TANK 30 0\nNODE J1 0\nSPRINKLER S1 0 60 80\nPIPE A1 TANK J1 10 100\nPIPE R1 J1 S1 5 65\n";
    my ($n, $ok, $as) = assessed($HEAD . $TANK);
    my $v = $as->{validation};
    is('gravity tank at 0 kPa: not reported unreachable', !errs($v)->{DEMAND_UNCONNECTED}, list(errs($v)));
    is('gravity tank at 0 kPa: ACCEPTED (it delivers 60 L/min with head to spare)',
       $v->{acceptance} eq 'ACCEPTED', "$v->{acceptance}: " . list(errs($v)));
    my $dm = $as->{demand};
    is('gravity tank: demand point FOUND at 0 kPa gauge (met by its elevation alone)',
       ($dm->{status} // '') eq 'FOUND' && near($dm->{p_demand}, 0, 1e-12), "p_demand $dm->{p_demand}");
    is('gravity tank: margin not negative', defined $dm->{margin} && $dm->{margin} >= 0, "margin $dm->{margin}");
    is('gravity tank: demand point says it is met at zero gauge pressure', $dm->{at_floor} ? 1 : 0);
    # A supply that really gives nothing is still not a supply: a static
    # supply at 0 kPa at the outlets' own level cannot move water.
    my ($n2, $ok2, $as2) = assessed($HEAD . "WATER W 0 0\nSPRINKLER S1 0 60 80\nPIPE A1 W S1 10 100\n");
    is('a supply at 0 kPa on the level delivers nothing: not ACCEPTED',
       $as2->{validation}{acceptance} ne 'ACCEPTED', $as2->{validation}{acceptance});

    # The floor trial is made only when every other trial passed.  Tried
    # first on every model, behind a backflow preventer and a pressure
    # reducing valve a 0 kPa supply cannot drive the network, and that trial
    # ran the Hardy Cross iteration to its limit: the round 2 device
    # benchmark ran 26 times slower (comparison/RERUN_2026-11-11.md).  So
    # count the searches' trials at 0 kPa on such a model: there must be none.
    my @zero;
    my $real = \&HardyCross::Demand::solve_at;
    no warnings 'redefine';
    local *HardyCross::Demand::solve_at = sub { push @zero, $_[2] if $_[2] < 0.005; $real->(@_) };
    use warnings 'redefine';
    my ($n3, $ok3, $as3) = assessed($HEAD . "WATER W 0 500\nNODE J 0\nNODE K 0\nSPRINKLER S1 0 80 50\n"
        . "PIPE P1 W J 10 100\nBFP P1 0 40 1000 60 2000 100\nPIPE P2 J K 10 100\nPRV P2 0 80\nPIPE P3 K S1 5 50\n");
    my $dm3 = $as3->{demand};
    is('behind a BFP and a PRV: demand point FOUND, well above 0 kPa',
       ($dm3->{status} // '') eq 'FOUND' && $dm3->{p_demand} > 100 && !$dm3->{at_floor},
       sprintf('%s at %s', $dm3->{status} // '-', $dm3->{p_demand} // '-'));
    is('behind a BFP and a PRV: no search tries a 0 kPa supply it does not need', !@zero,
       scalar(@zero) . ' trials at 0 kPa');
}

#==============================================================================
print "2. THE NRV COMMAND\n";
#==============================================================================
{
    is('NRV on a water supply reads', !refused($HEAD . $TWO . "NRV WB 0\n"), refused($HEAD . $TWO . "NRV WB 0\n"));
    is('NRV with a Cv and an opening pressure reads', !refused($HEAD . $TWO . "NRV WB 600 7\n"));
    is('NRV on a node that is not a supply is refused', defined refused($HEAD . $TWO . "NRV J1 0\n"));
    is('NRV on an undefined name is refused', defined refused($HEAD . $TWO . "NRV NOPE 0\n"));
    is('NRV with a negative Cv is refused', defined refused($HEAD . $TWO . "NRV WB -5\n"));
    is('NRV with a negative opening pressure is refused', defined refused($HEAD . $TWO . "NRV WB 0 -1\n"));
    is('NRV twice on one supply is refused', defined refused($HEAD . $TWO . "NRV WB 0\nNRV WB 0\n"));
    is('NRVMODEL without an NRV is refused', defined refused($HEAD . $TWO . "NRVMODEL WB SOME VALVE\n"));
    is('NRVMODEL with an NRV reads', !refused($HEAD . $TWO . "NRV WB 600\nNRVMODEL WB ACME 100 MM SWING CHECK\n"));
    my $n = HardyCross::Phc::read_string($HEAD . $TWO . "NRV WB 600 7\nNRVMODEL WB ACME SWING\n");
    my $wb = elem($n, 'WB');
    is('the supply carries its valve: Cv, opening pressure, make and model',
       $wb->{nrv} && $wb->{nrv}{cv} == 600 && near($wb->{nrv}{crack}, 7, 1e-12) && $wb->{nrv}{model} eq 'ACME SWING');
    is('a supply with no NRV line has no valve', !elem($n, 'WA')->{nrv});
    # In other pressure units the opening pressure is converted like any other.
    (my $bar = $HEAD . $TWO) =~ s/UNITS PRESSURE KPA/UNITS PRESSURE BAR/;
    $bar =~ s/WATER WA 0 1000/WATER WA 0 10/; $bar =~ s/WATER WB 0 520/WATER WB 0 5.2/;
    my $nb = HardyCross::Phc::read_string($bar . "NRV WB 600 0.07\n");
    is('an opening pressure in bar is converted to kPa', near(elem($nb, 'WB')->{nrv}{crack}, 7, 1e-9),
       elem($nb, 'WB')->{nrv}{crack});
}

#==============================================================================
print "3. NO CHANGE WHERE NONE IS DUE\n";
#==============================================================================
{
    # Both supplies deliver here (WB is strong); a lossless valve must change
    # nothing at all.
    (my $both = $TWO) =~ s/WATER WB 0 520/WATER WB 0 900/;
    my ($a) = solve($HEAD . $both);
    my ($b, $okb) = solve($HEAD . $both . "NRV WA 0\nNRV WB 0\n");
    my $same = 1;
    for my $id (qw(WA WB A1 B1 J12 R1 S1)) { $same = 0 unless near(elem($a, $id)->{q}, elem($b, $id)->{q}, 1e-12) }
    is('lossless valves on delivering supplies: every flow identical', $same && $okb);
    is('lossless valves on delivering supplies: every pressure identical',
       near(gauge($a, 'S1'), gauge($b, 'S1'), 1e-12) && near(gauge($a, 'J2'), gauge($b, 'J2'), 1e-12));
    is('neither valve closed', !elem($b, 'WA')->{closed} && !elem($b, 'WB')->{closed});
}

#==============================================================================
print "4. CLOSING\n";
#==============================================================================
{
    my ($w, $okw, $asw) = assessed($HEAD . $TWO);
    is('without a valve, WB takes water in and the calculation is REJECTED',
       $asw->{validation}{acceptance} eq 'REJECTED' && errs($asw->{validation})->{SUPPLY_REVERSE});

    my ($n, $ok, $as) = assessed($HEAD . $TWO . "NRV WB 0\n");
    my $v = $as->{validation};
    my $wb = elem($n, 'WB');
    is('with a valve, WB closes', $wb->{closed} && $wb->{check_closed});
    is('the closed valve carries exactly nothing', $wb->{q} == 0);
    is('no reverse supply flow is reported', !errs($v)->{SUPPLY_REVERSE});
    is('the solve converges and settles', $ok && $n->{outer_settled});
    is('the calculation is ACCEPTED: WA alone meets the sprinkler',
       $v->{acceptance} eq 'ACCEPTED', "$v->{acceptance}: " . list(errs($v)));
    # Independent: the network with WB deleted.
    my ($r) = solve($HEAD . $ONLY_A);
    my $same = 1;
    for my $id (qw(WA A1 J12 R1 S1)) { $same = 0 unless near(elem($n, $id)->{q}, elem($r, $id)->{q}, 1e-9) }
    is('every flow equals the model with WB deleted', $same);
    is('every pressure equals the model with WB deleted',
       near(gauge($n, 'S1'), gauge($r, 'S1'), 1e-9) && near(gauge($n, 'J2'), gauge($r, 'J2'), 1e-9));
    # Closed is consistent: WB's pressure could not open it against J2.
    is('closed state consistent: J2 is above what WB could give', gauge($n, 'J2') >= 520 - 1e-9, gauge($n, 'J2'));
    # A valve on the strong supply as well changes nothing more.
    my ($n2, $ok2, $as2) = assessed($HEAD . $TWO . "NRV WA 0\nNRV WB 0\n");
    is('valves on both supplies: same answer, WA open, WB closed',
       !elem($n2, 'WA')->{closed} && elem($n2, 'WB')->{closed} && near(elem($n2, 'S1')->{q}, elem($n, 'S1')->{q}, 1e-9));
}

#==============================================================================
print "5. REOPENING\n";
#==============================================================================
{
    # Both supplies have valves here: raised, WB would otherwise push water
    # into WA, which is a supply taking water in, and REJECTED.
    my ($n, $ok) = solve($HEAD . $TWO . "NRV WA 0\nNRV WB 0\n");
    my $wb = elem($n, 'WB');
    is('WB closed at 520 kPa', $wb->{closed});
    # Raise WB well above the network at J2 and solve again from the closed state.
    $wb->{pstat} = 2000;
    my $ok2 = HardyCross::solve_model($n);
    my $v = HardyCross::Validate::validate($n, $ok2);
    is('raised to 2000 kPa, WB reopens', !$wb->{closed});
    is('reopened, WB delivers', $wb->{q} > 1, $wb->{q});
    is('reopened, the solve is valid', $v->{acceptance} eq 'ACCEPTED' || $v->{acceptance} eq 'NONCOMPLIANT',
       $v->{acceptance});
    # The same, from a fresh read: the same answer whichever state it began in.
    (my $hi = $TWO) =~ s/WATER WB 0 520/WATER WB 0 2000/;
    my ($f) = solve($HEAD . $hi . "NRV WA 0\nNRV WB 0\n");
    is('the reopened answer equals a fresh solve', near(elem($f, 'WB')->{q}, $wb->{q}, 1e-6));

    # A valve that keeps changing state is not taken as settled.  The switch
    # count is set past its limit on a valve whose state is wrong, which is
    # what an oscillating valve reaches.
    my ($m) = solve($HEAD . $TWO . "NRV WA 0\nNRV WB 0\n");
    my $mb = elem($m, 'WB');
    $mb->{pstat} = 2000;
    $mb->{nflips} = 99;
    my $ok3 = HardyCross::solve_model($m);
    my $v3 = HardyCross::Validate::validate($m, $ok3);
    is('an unsettled valve: marked at its switch limit', $mb->{flip_limit});
    is('an unsettled valve: INDETERMINATE, not ACCEPTED', $v3->{acceptance} eq 'INDETERMINATE', $v3->{acceptance});
    is('an unsettled valve: SUPPLY_CHECK_UNRESOLVED', errs($v3)->{SUPPLY_CHECK_UNRESOLVED}, list(errs($v3)));
    # A valve at its limit but already in the right state is settled.
    my ($s) = solve($HEAD . $TWO . "NRV WB 0\n");
    elem($s, 'WB')->{nflips} = 99;
    my $ok4 = HardyCross::solve_model($s);
    my $v4 = HardyCross::Validate::validate($s, $ok4);
    is('a valve at its limit in the right state is settled', !errs($v4)->{SUPPLY_CHECK_UNRESOLVED} && $v4->{acceptance} eq 'ACCEPTED',
       "$v4->{acceptance}: " . list(errs($v4)));
}

#==============================================================================
print "6. ISOLATION\n";
#==============================================================================
{
    # One supply at 50 kPa, the sprinkler 10 m above it (98 kPa of lift).
    my $LIFT = "WATER W 0 50\nNODE J1 0\nSPRINKLER S1 10 60 80\nPIPE A1 W J1 10 100\nPIPE R1 J1 S1 10 65\n";
    my ($w, $okw, $asw) = assessed($HEAD . $LIFT);
    is('without a valve: water runs backwards, REJECTED', $asw->{validation}{acceptance} eq 'REJECTED',
       $asw->{validation}{acceptance});
    my ($n, $ok, $as) = assessed($HEAD . $LIFT . "NRV W 0\n");
    my $v = $as->{validation};
    my $e = errs($v);
    is('with a valve: the valve closes', elem($n, 'W')->{closed});
    is('loss of supply is reported: SUPPLY_ISOLATED', $e->{SUPPLY_ISOLATED}, list($e));
    is('loss of supply is NONCOMPLIANT, not ACCEPTED', $v->{acceptance} eq 'NONCOMPLIANT', "$v->{acceptance}: " . list($e));
    is('loss of supply is not a numerical failure', $v->{numerical}{status} eq 'PASS', $v->{numerical}{status});
    is('loss of supply is not a physical failure', $v->{physical}{status} eq 'PASS', list($e));
    is('no valve was held open to keep the network connected', !elem($n, 'W')->{isolating});
    my $zero = 1;
    $zero = 0 for grep { !$_->{kind} || abs($_->{q}) > 0 } @{ $n->{elems} }[1 .. $#{ $n->{elems} }];
    is('every flow is zero: no water is manufactured', $zero);
    is('no pressure is reported at the isolated nodes', near(gauge($n, 'S1'), 0, 1e-9) && near(gauge($n, 'J1'), 0, 1e-9));
    is('the network records which nodes lost their supply',
       $n->{supply_isolated} && join(',', sort @{ $n->{supply_isolated}{nodes} }) eq 'J1,S1,W',
       $n->{supply_isolated} ? join(',', sort @{ $n->{supply_isolated}{nodes} }) : 'none');
    my $dm = $as->{demand};
    is('the demand search does not call the isolated supply a numerical failure',
       ($dm->{status} // '') ne 'UNRESOLVED' || $dm->{reason} !~ /converge/, $dm->{reason});

    # Two separate networks, each with its own supply; only the second loses it.
    my $PART = "WATER WA 0 600\nNODE A1N 0\nSPRINKLER SA 0 60 80\nPIPE PA WA A1N 10 100\nPIPE RA A1N SA 5 65\n"
             . "WATER WB 0 50\nNODE B1N 0\nSPRINKLER SB 10 60 80\nPIPE PB WB B1N 10 100\nPIPE RB B1N SB 10 65\n";
    my ($p, $okp, $asp) = assessed($HEAD . $PART . "NRV WA 0\nNRV WB 0\n");
    my $vp = $asp->{validation};
    is('part isolated: WA stays open, WB closes', !elem($p, 'WA')->{closed} && elem($p, 'WB')->{closed});
    is('part isolated: SUPPLY_ISOLATED names the sprinkler that lost its supply',
       (grep { $_->{code} eq 'SUPPLY_ISOLATED' && ($_->{item} // '') =~ /\bSB\b/ } @{ $vp->{findings} }) ? 1 : 0);
    is('part isolated: NONCOMPLIANT', $vp->{acceptance} eq 'NONCOMPLIANT', "$vp->{acceptance}: " . list(errs($vp)));
    my ($sa) = solve($HEAD . "WATER WA 0 600\nNODE A1N 0\nSPRINKLER SA 0 60 80\nPIPE PA WA A1N 10 100\nPIPE RA A1N SA 5 65\n");
    is('part isolated: the supplied part solves as it does on its own',
       near(elem($p, 'SA')->{q}, elem($sa, 'SA')->{q}, 1e-9) && near(gauge($p, 'SA'), gauge($sa, 'SA'), 1e-9));
}

#==============================================================================
print "7. CHANGING DEMAND\n";
#==============================================================================
{
    # WA strong and far, WB 520 kPa beside the outlet.  At a small demand the
    # network at J2 stands above 520 and WB stays shut; at a large one it falls
    # below and WB opens.
    my $mk = sub { my $k = shift; (my $t = $TWO) =~ s/SPRINKLER S1 0 -100 80/SPRINKLER S1 0 -100 $k/; $HEAD . $t . "NRV WB 0\n" };
    my ($lo) = solve($mk->(40));
    my ($hi, $okh) = solve($mk->(400));
    is('small demand: WB shut', elem($lo, 'WB')->{closed});
    is('large demand: WB open and delivering', !elem($hi, 'WB')->{closed} && elem($hi, 'WB')->{q} > 1, elem($hi, 'WB')->{q});
    is('large demand: J2 below WB, as an open valve needs', gauge($hi, 'J2') < 520);
    my $v = HardyCross::Validate::validate($hi, $okh);
    is('large demand: valid', $v->{numerical}{status} eq 'PASS' && $v->{physical}{status} eq 'PASS', list(errs($v)));
}

#==============================================================================
print "8. DEMAND SEARCHES\n";
#==============================================================================
{
    my ($w, $okw, $asw) = assessed($HEAD . $TWO);
    is('without a valve the joint demand is UNRESOLVED (WB takes water in)',
       ($asw->{supplies}{joint}{status} // '') eq 'UNRESOLVED', $asw->{supplies}{joint}{status});
    my ($n, $ok, $as) = assessed($HEAD . $TWO . "NRV WB 0\n");
    my $j = $as->{supplies}{joint};
    is('with a valve the joint demand is FOUND', ($j->{status} // '') eq 'FOUND', $j->{reason});
    my ($rb) = grep { $_->{id} eq 'WB' } @{ $j->{supplies} || [] };
    is('joint demand: WB shut on its valve, no flow, not active',
       $rb && $rb->{flow} == 0 && !$rb->{active} && ($rb->{status} // '') eq 'CLOSED', $rb ? $rb->{status} : 'no row');
    is('joint demand: the signed supplies balance the net demand', $j->{balance_pass});
    my ($cb) = grep { $_->{id} eq 'WB' } @{ $as->{supplies}{conditional} || [] };
    is('conditional: WB NOT_REQUIRED (WA alone meets the outlet)', $cb && $cb->{status} eq 'NOT_REQUIRED',
       $cb ? "$cb->{status} " . ($cb->{reason} // '') : 'none');
    my ($ca) = grep { $_->{id} eq 'WA' } @{ $as->{supplies}{conditional} || [] };
    # WB at 520 kPa beside the sprinkler meets it alone, so WA is not needed:
    # found on valid trials.
    is('conditional: WA NOT_REQUIRED (WB alone meets the outlet), on valid trials',
       $ca && $ca->{status} eq 'NOT_REQUIRED' && !@{ $ca->{findings} || [] },
       $ca ? "$ca->{status} " . ($ca->{reason} // '') : 'none');
    is('demand assessment DEMONSTRATED', $as->{validation}{demand_assessment}{status} eq 'DEMONSTRATED',
       $as->{validation}{demand_assessment}{status});
    is('the whole calculation ACCEPTED', $as->{validation}{acceptance} eq 'ACCEPTED',
       "$as->{validation}{acceptance}: " . list(errs($as->{validation})));
    my @sc = @{ $as->{supplies}{scenarios} || [] };
    my ($wb_out) = grep { ($_->{name} // '') =~ /WB/ && ($_->{name} // '') =~ /OUT|WITHOUT/i } @sc;
    is('scenarios run with the valve: no scenario REJECTED for reverse flow',
       !(grep { grep { $_ eq 'SUPPLY_REVERSE' } @{ $_->{findings} || [] } } @sc));
    my ($wb_row) = map { grep { $_->{id} eq 'WB' } @{ $_->{supplies} } } grep { !grep { $_->{status} eq 'OUT_OF_SERVICE' } @{ $_->{supplies} } } @sc;
    is('scenarios: a supply shut on its valve is reported CLOSED, not REVERSE',
       !(grep { $_->{status} eq 'REVERSE' } map { @{ $_->{supplies} } } @sc));

    # A single supply with a valve: its demand point is found as without one.
    my $ONE = "WATER W 0 900\nNODE J 0\nSPRINKLER S1 0 -50 80\nPIPE P1 W J 100 100\nPIPE P2 J S1 5 50\n";
    my ($a1, $o1, $s1) = assessed($HEAD . $ONE);
    my ($b1, $o2, $s2) = assessed($HEAD . $ONE . "NRV W 0\n");
    is('one supply: demand point unchanged by a lossless valve', near($s1->{demand}{p_demand}, $s2->{demand}{p_demand}, 1e-9),
       "$s1->{demand}{p_demand} vs $s2->{demand}{p_demand}");
    # With a loss the supply needs more pressure, by the valve's loss at the demand flow.
    my ($c1, $o3, $s3) = assessed($HEAD . $ONE . "NRV W 300 10\n");
    my $q = $s3->{demand}{q_system};
    my $loss = 10 + 6.894757 * ($q / 3.785411784 / 300) ** 2;
    is('one supply: a valve with a loss raises the demand by that loss (within the 0.01 kPa search)',
       near($s3->{demand}{p_demand} - $s1->{demand}{p_demand}, $loss, 0.05),
       sprintf('%.3f vs %.3f', $s3->{demand}{p_demand} - $s1->{demand}{p_demand}, $loss));
}

#==============================================================================
print "9. THE VALVE'S LOSS\n";
#==============================================================================
{
    # Both deliver (WB 900); WB's valve has Cv 300 and opens at 10 kPa.  Its
    # loss is the data-sheet definition dP psi = (Q gpm / Cv)^2, plus the
    # opening pressure, worked here from the solved flow.
    (my $both = $TWO) =~ s/WATER WB 0 520/WATER WB 0 900/;
    my ($n, $ok) = solve($HEAD . $both . "NRV WB 300 10\n");
    my $wb = elem($n, 'WB');
    my $q = $wb->{q};
    my $want = 10 + 6.894757 * ($q / 3.785411784 / 300) ** 2;
    my $got = 900 - gauge($n, 'WB');
    # To the loop tolerance: WB's node is reached through the spanning tree,
    # and a chord closes its loop to TOL_LOOP (0.01 kPa), not to round-off.
    is('open valve: supply pressure less node pressure = opening + Cv loss', near($got, $want, 0.01),
       sprintf('%.6f vs %.6f at %.3f L/min', $got, $want, $q));
    my $v = HardyCross::Validate::validate($n, $ok);
    is('open valve with a loss: valid', $v->{numerical}{status} eq 'PASS' && $v->{physical}{status} eq 'PASS', list(errs($v)));

    # An opening pressure larger than the supply's advantage keeps it shut.
    # WB 520 against J2: with WA at 1000 and the outlet at K 400, WB opens with
    # no opening pressure; at 300 kPa opening pressure it cannot.
    (my $t = $TWO) =~ s/SPRINKLER S1 0 -100 80/SPRINKLER S1 0 -100 400/;
    my ($o) = solve($HEAD . $t . "NRV WB 0\n");
    my ($c, $okc) = solve($HEAD . $t . "NRV WB 0 300\n");
    is('no opening pressure: WB opens at the large demand', !elem($o, 'WB')->{closed});
    is('300 kPa opening pressure: WB stays shut', elem($c, 'WB')->{closed});
    is('shut on its opening pressure: consistent (520 - J2 below 300)', 520 - gauge($c, 'J2') <= 300 + 1e-6,
       520 - gauge($c, 'J2'));
    my $vc = HardyCross::Validate::validate($c, $okc);
    is('shut on its opening pressure: no unresolved valve', !errs($vc)->{SUPPLY_CHECK_UNRESOLVED}, list(errs($vc)));
}

#==============================================================================
print "10. REPORTING\n";
#==============================================================================
{
    my $text = $HEAD . $TWO . "NRV WB 300 7\nNRVMODEL WB ACME 100 SWING\n";
    my ($n, $ok) = solve($text);
    my $j = decode_json(HardyCross::Json::encode(HardyCross::Json::results($n, $ok, "m.phc")));
    my %cv = map { $_->{supply} => $_ } @{ $j->{supply_check_valves} || [] };
    is('JSON: every supply listed under supply_check_valves', $cv{WA} && $cv{WB});
    is('JSON: WA has no valve', $cv{WA} && !$cv{WA}{installed} && $cv{WA}{state} eq 'NONE');
    is('JSON: WB valve installed, CLOSED, no flow',
       $cv{WB} && $cv{WB}{installed} && $cv{WB}{state} eq 'CLOSED' && $cv{WB}{flow} == 0);
    is('JSON: WB Cv, opening pressure, make and model',
       $cv{WB} && $cv{WB}{cv} == 300 && $cv{WB}{opening_pressure} == 7 && $cv{WB}{model} eq 'ACME 100 SWING');
    is('JSON: acceptance ACCEPTED', $j->{acceptance} eq 'ACCEPTED', $j->{acceptance});
    my $r = HardyCross::Report::write_report($n, $ok, "m.phc");
    is('report: lists the supply check valves', $r =~ /SUPPLY CHECK VALVES/);
    is('report: WB shown CLOSED with its make and model', $r =~ /WB\s.*CLOSED/ && $r =~ /ACME 100 SWING/);
    is('report: acceptance agrees with the JSON', $r =~ /ACCEPTED - numerically valid/);

    my ($m, $okm) = solve($HEAD . "WATER W 0 50\nNODE J1 0\nSPRINKLER S1 10 60 80\nPIPE A1 W J1 10 100\n"
                        . "PIPE R1 J1 S1 10 65\nNRV W 0\n");
    my $jm = decode_json(HardyCross::Json::encode(HardyCross::Json::results($m, $okm, "m.phc")));
    my ($w) = @{ $jm->{supply_check_valves} };
    is('JSON: an isolated supply is ISOLATED', $w && $w->{state} eq 'ISOLATED', $w ? $w->{state} : 'none');
    is('JSON: isolated: NONCOMPLIANT and not approved', $jm->{acceptance} eq 'NONCOMPLIANT' && !$jm->{approved});
    my $rm = HardyCross::Report::write_report($m, $okm, "m.phc");
    is('report: an isolated supply says LOSS OF SUPPLY', $rm =~ /LOSS OF SUPPLY/);
}

#==============================================================================
print "11. EQUIVALENT DESCRIPTIONS\n";
#==============================================================================
{
    my $base = $HEAD . $TWO . "NRV WB 300 7\n";
    my ($b) = solve($base);
    my %ref = map { $_ => elem($b, $_)->{q} } qw(WA WB A1 J12 R1 S1);
    my $cmp = sub {
        my ($name, $text, $map, $flip) = @_;
        my ($n, $ok) = solve($text);
        my $same = $ok ? 1 : 0;
        for my $id (keys %ref) {
            my $e = elem($n, $map->{$id} // $id) or ($same = 0, next);
            my $q = $flip->{$id} ? -$e->{q} : $e->{q};
            $same = 0 unless near($q, $ref{$id}, 1e-6 * (1 + abs $ref{$id}));
        }
        is($name, $same);
    };
    # Nodes renamed.
    (my $ren = $base) =~ s/\bJ1\b/X9/g; $ren =~ s/\bJ2\b/AA/g;
    $cmp->('nodes renamed: same flows', $ren, {});
    # Lines in another order.
    my @l = split /\n/, $TWO;
    $cmp->('lines reordered: same flows', $HEAD . join("\n", reverse @l) . "\nNRV WB 300 7\n", {});
    # A pipe drawn the other way: its flow changes sign, nothing else.
    (my $rev = $base) =~ s/PIPE J12 J1 J2 5 100/PIPE J12 J2 J1 5 100/;
    $cmp->('a pipe drawn the other way: same flows, that one negated', $rev, {}, { J12 => 1 });
    # Pressures in bar and flows in m3/h: the same water.
    (my $si = $base) =~ s/UNITS PRESSURE KPA/UNITS PRESSURE BAR/;
    $si =~ s/WATER WA 0 1000/WATER WA 0 10/; $si =~ s/WATER WB 0 520/WATER WB 0 5.2/;
    $si =~ s/NRV WB 300 7/NRV WB 300 0.07/;
    $si =~ s/SPRINKLER S1 0 -100 80/SPRINKLER S1 0 -1 800/; # K 80 L/min/kPa^0.5 x sqrt(100 kPa/bar) = K 800 L/min/bar^0.5
    $si =~ s/UNITS KFACTOR LPM\/KPA/UNITS KFACTOR LPM\/BAR/;
    my ($sn, $sok) = solve($si);
    my $wbq = elem($sn, 'WB') ? elem($sn, 'WB')->{q} : undef;
    is('pressures in bar: the same state (WB shut) and the same outlet flow',
       elem($sn, 'WB') && elem($sn, 'WB')->{closed} && near(elem($sn, 'S1')->{q}, $ref{S1}, 1e-6 * $ref{S1}),
       defined $wbq ? $wbq : 'no WB');
}

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
