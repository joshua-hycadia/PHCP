#!/usr/bin/perl
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# test_acceptance.pl -- the false positives found in the audit of 11 November
# 2026, each refused.
#
#   perl tools/test_acceptance.pl
#
# Every case was written BEFORE its correction and failed on PHCP 1.5.0 as
# released (main at f050571): each shows a calculation PHCP accepted, or a
# check it did not make.  The parts:
#
#   1. HYDRAULIC CONSTANTS AND SETTINGS: HW_CONST of zero, negative, in other
#      units or enormous; a non-finite number; tolerances and the orifice
#      step that are not positive; a C factor no pipe has.
#   2. SOLVER TOLERANCES AGAINST VERIFICATION LIMITS: a loose TOL_LOOP lets
#      the iteration stop early, but the final check is made to PHCP's own
#      limit, which no setting changes.
#   3. CLOSED DEVICES: a closed element carrying flow is caught on its own.
#   4. SEVERAL SUPPLIES: a joint demand at which a supply takes water in is
#      not a demand the design may rest on; a trial that is physically
#      invalid, or does not converge, is never taken for a supply too weak.
#   5. ORIFICE PLATES: the final drop against the target, to a stated
#      tolerance, with the deviation split into rounding and flow.
#   6. CURVES: non-finite points refused; operation far beyond the points
#      refused; extrapolation labelled.
#   7. DRY PIPE VALVES: a constant loss labelled, and refused at no flow; a
#      loss curve that is negative at no flow refused; a database valve with
#      no usable loss is DATA_REQUIRED, not a zero loss; the time estimates
#      decide nothing.
#   8. INTEGRATION: the strict exit status, JSON's "approved", the results
#      block (current, stale, tampered), and the command line, the JSON, the
#      editor and the report agreeing on every case above.
#
# These tests check PHCP against the conditions it sets itself.  They are not
# evidence of conformance with any Standard or of external certification.
#==============================================================================
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";
use HardyCross;
use HardyCross::Parse;
use HardyCross::Phc;
use HardyCross::Validate;
use HardyCross::Demand;
use HardyCross::Supplies;
use HardyCross::Json;
use HardyCross::Report;
use HardyCross::Results;
use JSON::PP;

my ($pass, $fail) = (0, 0);
sub is {
    my ($name, $ok, $why) = @_;
    printf "  %-70s %s\n", $name, $ok ? 'ok' : '*** FAIL';
    print "      $why\n" if !$ok && defined $why;
    $ok ? $pass++ : $fail++;
}

my $HEAD = join "\n", 'UNITS LENGTH M', 'UNITS ELEVATION M', 'UNITS SIZE MM', 'UNITS PRESSURE KPA',
                      'UNITS FLOW LPM', 'UNITS KFACTOR LPM/KPA', 'METHOD HW', '';
# One K80 sprinkler at the end of 100 m of 100 mm pipe from a 900 kPa supply.
my $ONE = "USE BORE 120\nWATER N1 0 900\nSPRINKLER N2 0 -50 80\nPIPE P1 N1 N2 100 100\n";
# A looped network: two parallel paths between A and B.
my $LOOP = "USE BORE 120\nWATER S 0 700\nNODE A 0\nNODE B 0\nNODE C 0\nSPRINKLER H 0 -50 80\n"
         . "PIPE P1 S A 10 100\nPIPE P2 A B 50 50\nPIPE P3 A C 20 25\nPIPE P4 C B 20 25\nPIPE P5 B H 5 50\n";
# Two static supplies.  WA is strong and far; WB is weak and near the
# sprinkler.  As modelled both deliver; derated together, WB takes water in
# long before the sprinkler reaches its minimum.
my $TWO = "USE BORE 120\nWATER WA 0 1000\nWATER WB 0 520\nNODE J1 0\nNODE J2 0\nSPRINKLER S1 0 -100 80\n"
        . "PIPE A1 WA J1 60 65\nPIPE B1 WB J2 5 100\nPIPE J12 J1 J2 5 100\nPIPE R1 J2 S1 5 50\n";

# refused -- the error message if model text is refused, else undef.
sub refused {
    my $text = shift;
    my $n = eval { HardyCross::Phc::read_string($text) };
    return undef if $n;
    my $e = $@;
    return ref $e ? $e->{msg} : "$e";
}
sub solve {
    my $text = shift;
    my $net = HardyCross::Phc::read_string($text);
    my $ok = HardyCross::solve_model($net);
    return ($net, $ok);
}
sub assessed {
    my ($net, $ok) = solve(shift);
    return ($net, $ok, HardyCross::Validate::assess($net, $ok));
}
sub errs { my $v = shift; my %c; $c{ $_->{code} }++ for grep { $_->{severity} eq 'error' } @{ $v->{findings} }; \%c }
sub warns { my $v = shift; my %c; $c{ $_->{code} }++ for grep { $_->{severity} eq 'warning' } @{ $v->{findings} }; \%c }
sub elem { my ($n, $id) = @_; my ($e) = grep { ($_->{id} // '') eq $id } @{ $n->{elems} }[1 .. $#{ $n->{elems} }]; $e }
sub list { my $h = shift; join(',', sort keys %$h) || 'none' }

my $TMP = "$FindBin::Bin/../.test_acceptance_tmp";
mkdir $TMP;
sub run {
    my ($text, @args) = @_;
    my $m = "$TMP/m.phc";
    open my $f, '>', $m or die; print $f $text; close $f;
    my $out = `"$^X" "$FindBin::Bin/../phcp.pl" @args "$m" 2>&1`;
    return ($? >> 8, $out);
}

#==============================================================================
print "1. HYDRAULIC CONSTANTS AND SETTINGS\n";
#==============================================================================
{
    # Each of these was solved and ACCEPTED: with HW_CONST 0 the pipe had no
    # friction at all (2400 L/min, 80 sqrt 900), with a negative one the
    # water GAINED pressure along it, and 6.05e5 -- the constant for bar/m --
    # cut every loss a hundredfold.
    for my $c (['0', 'zero'], ['-6.05E7', 'negative'], ['6.05E5', 'the bar/m constant'],
               ['4.52', 'the US-unit constant'], ['1E30', 'enormous'], ['1E999', 'overflowing to infinity']) {
        my $m = refused($HEAD . "OPTION HW_CONST $c->[0]\n" . $ONE);
        is("HW_CONST $c->[0] ($c->[1]) is refused", defined $m && $m =~ /HW_CONST/i, $m // 'accepted');
    }
    for my $c ('6.05E7', '6.0489E7', '6.1E7') {
        is("HW_CONST $c (a published form, in L/min, mm, kPa/m) is accepted", !defined refused($HEAD . "OPTION HW_CONST $c\n" . $ONE));
    }
    my $m = refused($HEAD . "OPTION HW_CONST 6.05E5\n" . $ONE) // '';
    is('the refusal names the constant PHCP expects', $m =~ /6\.05E7|6\.05 ?x ?10\^?7/i, $m);

    for my $o (['TOL_FLOW', '0'], ['TOL_FLOW', '-1'], ['TOL_LOOP', '0'], ['TOL_LOOP', '-0.01'],
               ['TOL_LOOP', '1E999'], ['ORIF_STEP', '0'], ['ORIF_STEP', '-0.5']) {
        my $m = refused($HEAD . "OPTION $o->[0] $o->[1]\n" . $ONE);
        is("$o->[0] $o->[1] is refused", defined $m && $m =~ /$o->[0]/i, $m // 'accepted');
    }
    # NU: the kinematic viscosity of water, 0.29E-6 (100 C) to 1.79E-6 (0 C)
    # m2/s.  NU 1 -- a million times water's -- made every pipe laminar, and
    # was ACCEPTED.
    (my $dw = $HEAD) =~ s/METHOD HW/METHOD DW/;
    for my $nu ('1', '1E-9') {
        my $m = refused($dw . "OPTION NU $nu\n" . $ONE);
        is("NU $nu (not water) is refused", defined $m && $m =~ /\bNU\b/, $m // 'accepted');
    }
    my $m10 = refused($dw . "OPTION NU 1.31E-6\n" . $ONE);
    is('NU 1.31E-6 (water at 10 C) is accepted', !defined $m10, $m10);
    # A number that overflows is not a number, wherever it is given.
    my $mc = refused($HEAD . "USE BORE 120\nWATER N1 0 900 1000 1E999\nSPRINKLER N2 0 -50 80\nPIPE P1 N1 N2 5 100\n");
    is('a curve point of 1E999 is refused before solving', defined $mc, 'accepted, then solved to NaN');
    # C: no pipe has a Hazen-Williams C of 5 or of 1000.
    for my $c (5, 1000) {
        my $m = refused($HEAD . "USE BORE $c\nWATER N1 0 900\nSPRINKLER N2 0 -50 80\nPIPE P1 N1 N2 100 100\n");
        is("a C factor of $c is refused", defined $m && $m =~ /\bC\b/, $m // 'accepted');
    }
    is('a C factor of 150 is accepted',
       !defined refused($HEAD . "USE BORE 150\nWATER N1 0 900\nSPRINKLER N2 0 -50 80\nPIPE P1 N1 N2 100 100\n"));
}

#==============================================================================
print "2. SOLVER TOLERANCES AGAINST VERIFICATION LIMITS\n";
#==============================================================================
{
    my ($n0, $ok0, $a0) = assessed($HEAD . $LOOP);
    is('the looped network at the default tolerances is ACCEPTED', $a0->{validation}{acceptance} eq 'ACCEPTED',
       $a0->{validation}{acceptance});
    # Was ACCEPTED with 21.4 kPa unclosed in a loop and the flow 1.7 % out.
    my ($n1, $ok1, $a1) = assessed($HEAD . "OPTION TOL_LOOP 500\nOPTION TOL_FLOW 500\n" . $LOOP);
    my $v1 = $a1->{validation};
    is('TOL_LOOP 500 kPa: the early stop is not ACCEPTED', $v1->{acceptance} ne 'ACCEPTED', $v1->{acceptance});
    is('  ... it is REJECTED for loop closure', $v1->{acceptance} eq 'REJECTED' && errs($v1)->{LOOP_CLOSURE},
       list(errs($v1)));
    is('  ... the loose setting is itself reported', warns($v1)->{SOLVER_TOLERANCE_LOOSE}, list(warns($v1)));
    my $r = $v1->{residuals}{loop};
    is('  ... the loop is checked against the verification limit, not TOL_LOOP',
       defined $r->{tolerance} && $r->{tolerance} <= 1.01 * $HardyCross::Validate::VERIFY_P,
       sprintf('tolerance %s', $r->{tolerance} // 'undef'));
    is('  ... and the solver tolerance is kept apart', abs(($v1->{solver}{tol_loop} // 0) - 500) < 1e-9,
       $v1->{solver}{tol_loop});
    is('the verification limits are given with the validation',
       ref $v1->{verification} eq 'HASH' && defined $v1->{verification}{loop} && defined $v1->{verification}{element}
       && defined $v1->{verification}{continuity});
    # Moderately loose -- above the limit, but the solve happens to close
    # better than asked: then the check passes on the residual itself.
    my ($n2, $ok2, $a2) = assessed($HEAD . "OPTION TOL_LOOP 0.05\n" . $LOOP);
    is('TOL_LOOP 0.05 kPa, closing within the limit: ACCEPTED, with the setting noted',
       $a2->{validation}{acceptance} eq 'ACCEPTED', $a2->{validation}{acceptance});
    my $rep = HardyCross::Report::write_report($n1, $ok1, 'm.phc');
    is('the report prints the solver tolerance and the verification limit',
       $rep =~ /^ Solver tolerance\s+flow .* loop 5e\+02/m && $rep =~ /^ Verification limit\s+loop closure .* 0\.1 /m);
}

#==============================================================================
print "3. CLOSED DEVICES\n";
#==============================================================================
{
    my ($n, $ok) = solve($HEAD . $LOOP);
    my $e = elem($n, 'P3');
    # Closed after the solve, its flow left: the network's continuity is
    # broken, and the closed element carrying water is named on its own.
    $e->{closed} = 1;
    my $v = HardyCross::Validate::validate($n, $ok);
    is('a closed element still carrying flow is CLOSED_FLOW', errs($v)->{CLOSED_FLOW}, list(errs($v)));
    is('  ... and the calculation is REJECTED', $v->{acceptance} eq 'REJECTED', $v->{acceptance});
    # The same network untouched: nothing closed, nothing reported.
    my ($n2, $ok2) = solve($HEAD . $LOOP);
    my $v2 = HardyCross::Validate::validate($n2, $ok2);
    is('the untouched network is not reported for closed flow', !errs($v2)->{CLOSED_FLOW}, list(errs($v2)));
}

#==============================================================================
print "4. SEVERAL SUPPLIES\n";
#==============================================================================
{
    my ($n, $ok, $a) = assessed($HEAD . $TWO);
    my $v = $a->{validation};
    my $j = $a->{supplies}{joint};
    # As released: ACCEPTED, with WB taking 550 L/min IN at the joint demand
    # and the joint margin of 367 kPa counted.
    is('as modelled both supplies deliver', !grep { $_->{status} ne 'DELIVERING' } @{ $a->{supplies}{operating} });
    is('the joint demand is not taken where a supply would take water in',
       ($j->{status} // '') eq 'UNRESOLVED', 'status ' . ($j->{status} // 'undef'));
    is('  ... the reason names the supply and what happens to it', ($j->{reason} // '') =~ /WB/,
       $j->{reason} // 'no reason');
    is('  ... and the calculation is not ACCEPTED on it', $v->{acceptance} ne 'ACCEPTED', $v->{acceptance});
    is('  ... SUPPLY_DEMAND_UNRESOLVED, not a supply found inadequate',
       errs($v)->{SUPPLY_DEMAND_UNRESOLVED} && !errs($v)->{SUPPLY_ADEQUACY}, list(errs($v)));
    is('the demand assessment is UNRESOLVED', ($v->{demand_assessment}{status} // '') eq 'UNRESOLVED',
       $v->{demand_assessment}{status} // 'undef');

    # With the near supply strong enough the joint demand is found, valid.
    (my $t2 = $TWO) =~ s/WATER WB 0 520/WATER WB 0 900/;
    my ($n2, $ok2, $a2) = assessed($HEAD . $t2);
    my $j2 = $a2->{supplies}{joint};
    is('a valid joint demand is FOUND and ACCEPTED', ($j2->{status} // '') eq 'FOUND' && $j2->{acceptance} eq 'ACCEPTED',
       ($j2->{status} // 'undef') . ' ' . ($j2->{acceptance} // ''));
    is('  ... every supply delivers at it', !grep { $_->{status} eq 'REVERSE' } @{ $j2->{supplies} });
    # Signed: the supplies' flows add to the network's demand, from the one solve.
    my $dem = 0;
    $dem += $_->{q} for grep { $_->{kind} eq 'DISCHARGE' } @{ $j2->{net}{elems} }[1 .. $#{ $j2->{net}{elems} }];
    is('  ... the signed sum of the supplies equals the net demand at the joint demand',
       abs($j2->{q_total} - $dem) < 1e-3 && $j2->{balance_pass}, sprintf('%g against %g', $j2->{q_total}, $dem));
    is('  ... every supply row carries its active state and its extrapolation',
       !grep { !defined $_->{active} || !defined $_->{extrapolated} } @{ $j2->{supplies} });
    is('the demand assessment is DEMONSTRATED', ($a2->{validation}{demand_assessment}{status} // '') eq 'DEMONSTRATED',
       $a2->{validation}{demand_assessment}{status} // 'undef');
    is('  ... and names its basis as an assumption', ($a2->{validation}{demand_assessment}{basis} // '') =~ /DERATE/
       && ($j2->{assumption} // '') =~ /assum/i, $j2->{assumption} // '');

    # A trial classifier: every trial is PASS, SHORT, INVALID or NOT_CONVERGED.
    my ($tn, $tok) = solve($HEAD . $TWO);
    my $t = HardyCross::Demand::trial($tok, $tn);
    is('a converged valid trial is PASS or SHORT', ($t->{status} // '') =~ /^(PASS|SHORT)\z/, $t->{status});
    my $t3 = HardyCross::Demand::trial(0, $tn);
    is('a trial that did not converge is NOT_CONVERGED, not SHORT', ($t3->{status} // '') eq 'NOT_CONVERGED', $t3->{status});
    elem($tn, 'WB')->{q} = -50;
    my $t4 = HardyCross::Demand::trial($tok, $tn);
    is('a trial with a supply taking water in is INVALID', ($t4->{status} // '') eq 'INVALID'
       && grep({ $_ eq 'SUPPLY_REVERSE' } @{ $t4->{codes} || [] }), $t4->{status});

    # One supply: trials that fail to converge are not "too weak".  Every
    # trial below 600 kPa is made to fail to converge; the true demand point
    # is far below that.  As released the bisection walked down into them,
    # took each as "supply too weak", and returned 600 kPa as the demand.
    {
        no warnings 'redefine';
        my $real = \&HardyCross::solve_model;
        local *HardyCross::solve_model = sub {
            my $nn = $_[0];
            my ($s) = grep { $_->{kind} eq 'SUPPLY_STATIC' && $_->{id} eq 'N1' } @{ $nn->{elems} }[1 .. $#{ $nn->{elems} }];
            my $r = $real->(@_);
            return $s && $s->{pstat} < 600 && $s->{pstat} > 100 ? 0 : $r;
        };
        my ($on, $ook) = solve($HEAD . $ONE);
        my $dm = HardyCross::Demand::demand_point($on);
        is('one supply: non-converging trials give UNRESOLVED, not a demand',
           ($dm->{status} // '') eq 'UNRESOLVED', ($dm->{status} // 'undef') . ' ' . ($dm->{p_demand} // $dm->{reason} // ''));
        my $vv = HardyCross::Validate::validate($on, $ook, demand => $dm);
        is('  ... and the design is not ACCEPTED', $vv->{acceptance} ne 'ACCEPTED'
           && errs($vv)->{SUPPLY_DEMAND_UNRESOLVED}, list(errs($vv)));
    }
    my ($on, $ook, $oa) = assessed($HEAD . $ONE);
    is('one supply, nothing interfering: the demand point is FOUND', ($oa->{demand}{status} // '') eq 'FOUND',
       $oa->{demand}{status} // 'undef');
    is('  ... its supply flow is signed, from the solve', defined $oa->{demand}{q_system} && $oa->{demand}{q_system} > 0);

    # The conditional minimum of each supply: a status that says why.
    my %cs = map { $_->{id} => $_ } @{ $a2->{supplies}{conditional} };
    is('a conditional result has a status from REQUIRED, NOT_REQUIRED, INADEQUATE, UNRESOLVED',
       !(grep { ($_->{status} // '') !~ /^(REQUIRED|NOT_REQUIRED|INADEQUATE|UNRESOLVED)\z/ } values %cs),
       join(',', map { $_->{status} } values %cs));
    is('  ... and is marked conditional, not simultaneous', !(grep { ($_->{basis} // '') ne 'CONDITIONAL' } values %cs));
}

#==============================================================================
print "5. ORIFICE PLATES\n";
#==============================================================================
{
    my $OR = "WATER SRC 0 1000\nNODE J1 0\nNODE A 0\nHYDRANT A2 0 400 28.28427125\n"
           . "USE BORE 120\nPIPE M1 SRC J1 20 100\nPIPE P1 J1 A 12 50\nUSE ASAM\nPIPE OP1 A A2 0 50\nOPP OP1 150\n";
    my ($n, $ok, $a) = assessed($HEAD . "OPTION ORIF_STEP 0.5\n" . $OR);
    my $e = elem($n, 'OP1.OPP');
    is('the plate on a 0.5 mm step meets its duty within the tolerance',
       !errs($a->{validation})->{ORIFICE_DUTY}, list(errs($a->{validation})));
    is('  ... the final drop, target, deviation and its two causes are kept',
       defined $e->{dp_final} && defined $e->{dp_target} && defined $e->{dev_pct}
       && defined $e->{dev_rounding_pct} && defined $e->{dev_flow_pct});
    is('  ... the two causes add up to the deviation',
       abs(($e->{dev_rounding_pct} // 0) + ($e->{dev_flow_pct} // 0) - ($e->{dev_pct} // 1e9)) < 0.05,
       sprintf('%s + %s against %s', map { $_ // 'undef' } @{$e}{qw(dev_rounding_pct dev_flow_pct dev_pct)}));
    # A coarse step: the nearest plate that can be made is far from the duty.
    my ($n2, $ok2, $a2) = assessed($HEAD . "OPTION ORIF_STEP 6\n" . $OR);
    my $e2 = elem($n2, 'OP1.OPP');
    is('a 6 mm step: the plate misses its duty by more than the tolerance and fails',
       errs($a2->{validation})->{ORIFICE_DUTY}, sprintf('%s, deviation %s %%', list(errs($a2->{validation})), $e2->{dev_pct} // 'undef'));
    is('  ... as a design failure: NONCOMPLIANT', $a2->{validation}{acceptance} eq 'NONCOMPLIANT', $a2->{validation}{acceptance});
    my ($n3, $ok3, $a3) = assessed($HEAD . "OPTION ORIF_STEP 6\nOPTION ORIF_DP_TOL 60\n" . $OR);
    is('the tolerance is a setting (ORIF_DP_TOL), printed in the report',
       !errs($a3->{validation})->{ORIFICE_DUTY} && HardyCross::Report::write_report($n3, $ok3, 'm.phc') =~ /ORIF_DP_TOL|DUTY TOLERANCE/i);
    is('ORIF_DP_TOL must be positive', defined refused($HEAD . "OPTION ORIF_DP_TOL 0\n" . $OR));
}

#==============================================================================
print "6. CURVES\n";
#==============================================================================
{
    # A supply curve run at three times its last point.
    my $m = "USE BORE 120\nWATER N1 0 900 300 850\nSPRINKLER N2 0 -50 80\nPIPE P1 N1 N2 10 100\n";
    my ($n, $ok, $a) = assessed($HEAD . $m);
    my $v = $a->{validation};
    my $q = elem($n, 'N1')->{q};
    is('a supply run far beyond its curve is CURVE_EXTRAPOLATION_LIMIT', errs($v)->{CURVE_EXTRAPOLATION_LIMIT},
       sprintf('%s at %.0f L/min against a last point of 300', list(errs($v)), $q));
    is('  ... and the calculation is not ACCEPTED', $v->{acceptance} ne 'ACCEPTED', $v->{acceptance});
    my $m2 = "USE BORE 120\nWATER N1 0 900 2000 850\nSPRINKLER N2 0 -50 80\nPIPE P1 N1 N2 10 100\n";
    my ($n2, $ok2, $a2) = assessed($HEAD . $m2);
    is('a little beyond the points: a warning that it is EXTRAPOLATED, no failure',
       warns($a2->{validation})->{CURVE_EXTRAPOLATED} && !errs($a2->{validation})->{CURVE_EXTRAPOLATION_LIMIT},
       list(warns($a2->{validation})));
    my $j = HardyCross::Json::results($n2, $ok2, 'm');
    my ($sj) = grep { $_->{id} eq 'N1' } @{ $j->{elements} };
    is('  ... and the JSON marks the operating point extrapolated', $sj && $sj->{extrapolated});
}

#==============================================================================
print "7. DRY PIPE VALVES\n";
#==============================================================================
{
    my $D = "USE BORE 120\nWATER W 0 700\nNODE A 0\nNODE B 0\nSPRINKLER S 0 -50 80\n"
          . "PIPE P1 W A 5 100\nPIPE P12 A B 5 100\nPIPE P2 B S 5 50\n";
    my ($n, $ok, $a) = assessed($HEAD . $D . "DPV P12 100 RATIO 5.5:1 OFF 0 20\n");
    my $v = $a->{validation};
    my $e = (grep { ($_->{kind} // '') eq 'DPV' } @{ $n->{elems} })[0];
    is('a DPV with one flow/loss pair (a constant loss) is labelled a simplified loss',
       warns($v)->{DPV_SIMPLIFIED_LOSS} && ($e->{loss_source} // '') eq 'USER_FIXED',
       list(warns($v)) . ' ' . ($e->{loss_source} // 'undef'));
    # The same valve with no flow: a constant loss with nothing flowing is a
    # pressure difference no valve can hold open.
    my ($n2, $ok2, $a2) = assessed($HEAD . "USE BORE 120\nWATER W 0 700\nNODE A 0\nSPRINKLER S 0 -50 80\n"
                                   . "NODE X 0\nPIPE P1 W A 5 100\nPIPE P12 A X 5 100\nPIPE P2 A S 5 50\n"
                                   . "DPV P12 100 RATIO 5.5:1 OFF 0 20\n");
    is('  ... with no flow through it, the constant loss is refused', errs($a2->{validation})->{DPV_FIXED_NO_FLOW},
       list(errs($a2->{validation})));
    my ($n3, $ok3, $a3) = assessed($HEAD . $D . "DPV P12 100 RATIO 5.5:1 OFF 1000 20 2000 50\n");
    is('a loss curve that is negative at no flow is refused', errs($a3->{validation})->{DPV_LOSS_AT_ZERO},
       list(errs($a3->{validation})));
    my ($n4, $ok4, $a4) = assessed($HEAD . $D . "DPV P12 100 RATIO 5.5:1 OFF 0 0 1000 20 2000 70\n");
    is('a loss curve through zero is labelled a user curve, and passes',
       !errs($a4->{validation})->{DPV_LOSS_AT_ZERO} && (( grep { ($_->{kind} // '') eq 'DPV' } @{ $n4->{elems} })[0]{loss_source} // '') eq 'USER_CURVE');
    # Victaulic 756 has no usable loss in the database: as released the model
    # was refused at reading.  It is now a valve with DATA_REQUIRED.
    my $vt = $HEAD . $D . "DPV P12 100 RATIO 5.5:1 OFF VALVE VICTAULIC 756\n";
    my $msg = refused($vt);
    if (defined $msg) {
        is('a database valve with no usable loss reads, as DATA_REQUIRED', 0, $msg);
    } else {
        my ($n5, $ok5, $a5) = assessed($vt);
        is('a database valve with no usable loss reads, as DATA_REQUIRED', errs($a5->{validation})->{DPV_NO_LOSS_DATA}
           && (( grep { ($_->{kind} // '') eq 'DPV' } @{ $n5->{elems} })[0]{data_status} // '') eq 'DATA_REQUIRED',
           list(errs($a5->{validation})));
        is('  ... REJECTED: no loss is assumed', $a5->{validation}{acceptance} eq 'REJECTED', $a5->{validation}{acceptance});
        my $j5 = HardyCross::Json::results($n5, $ok5, 'm');
        is('  ... and the JSON says DATA_REQUIRED', ($j5->{dry_pipe_valves}[0]{data_status} // '') eq 'DATA_REQUIRED');
    }
    # The estimates decide nothing: with and without DPVTRIP the acceptance is the same.
    my $base = $HEAD . $D . "DPV P12 100 RATIO 5.5:1 OFF VALVE TYCO DPV-1\nDPVAIR P12 280\n";
    my (undef, undef, $b1) = assessed($base);
    my ($n6, $ok6, $b2) = assessed($base . "DPVTRIP P12 12.7 1 5\n");
    is('the trip and transit estimates change no acceptance',
       $b1->{validation}{acceptance} eq $b2->{validation}{acceptance}, "$b1->{validation}{acceptance} / $b2->{validation}{acceptance}");
    my $j6 = HardyCross::Json::results($n6, $ok6, 'm');
    my $est = $j6->{dry_pipe_valves}[0]{estimate} // {};
    is('  ... the JSON marks them as estimates, not verified, not a delivery time calculation',
       defined $est->{verified} && !$est->{verified} && ($est->{basis} // '') =~ /ESTIMATE/
       && !$j6->{dry_pipe_valves}[0]{delivery_time_calculated});
}

#==============================================================================
print "8. INTEGRATION\n";
#==============================================================================
{
    my $nc = $HEAD . "USE BORE 120\nWATER N1 0 300\nSPRINKLER N2 0 -250 80\nPIPE P1 N1 N2 100 100\n";
    my ($x, $out) = run($nc, '--json');
    my $j = eval { decode_json($out) } || {};
    is('a NONCOMPLIANT design: exit 0 by default, as before', $x == 0, "exit $x");
    is('  ... "approved" is false', exists $j->{approved} && !$j->{approved}, $j->{approved} // 'missing');
    my ($xs) = run($nc, '--json', '--strict');
    is('  ... with --strict, exit 4', $xs == 4, "exit $xs");
    my ($xa) = run($HEAD . $ONE, '--json', '--strict');
    is('an ACCEPTED design: exit 0 with --strict', $xa == 0, "exit $xa");
    my ($xr) = run($HEAD . "OPTION TOL_LOOP 500\nOPTION TOL_FLOW 500\n" . $LOOP, '--strict');
    is('a REJECTED calculation: exit 3 with --strict', $xr == 3, "exit $xr");
    my ($xu, $ou) = run($HEAD . $TWO, '--json');
    my $ju = eval { decode_json($ou) } || {};
    is('the two-supply case: the JSON gives the demand assessment', ($ju->{demand_assessment}{status} // '') eq 'UNRESOLVED');
    is('  ... and the assumptions it rests on', ref $ju->{assumptions} eq 'HASH' && ($ju->{assumptions}{joint_basis} // '') eq 'DERATE');
    is('  ... and the verification limits', ref $ju->{validation}{verification} eq 'HASH');

    # Results block: current, stale, tampered.
    my ($n, $ok) = solve($HEAD . $ONE);
    my $text = HardyCross::Results::with_results($HEAD . $ONE, $n, $ok);
    is('a fresh results block is CURRENT', HardyCross::Results::status($text) eq 'CURRENT', HardyCross::Results::status($text));
    (my $edited = $text) =~ s/PIPE P1 N1 N2 100 100/PIPE P1 N1 N2 120 100/;
    is('the model edited: STALE', HardyCross::Results::status($edited) eq 'STALE', HardyCross::Results::status($edited));
    (my $forged2 = $text) =~ s/(\/\/= PIPE\s+P1 .*? FLOW )(\d+)/$1 . ($2 + 100)/e;
    is('  ... (the test did edit a result)', $forged2 ne $text);
    is('a result edited by hand: TAMPERED', HardyCross::Results::status($forged2) eq 'TAMPERED', HardyCross::Results::status($forged2));
    is('no block: NONE', HardyCross::Results::status($HEAD . $ONE) eq 'NONE');
    is('the block records the program and the database it came from',
       $text =~ /^\/\/= PROGRAM\s+PHCP VERSION \S+/m && $text =~ /^\/\/= DATABASE\s+.*SHA256/m);
    my ($rn, $rok) = solve($HEAD . "OPTION TOL_LOOP 500\nOPTION TOL_FLOW 500\n" . $LOOP);
    my $rt = HardyCross::Results::with_results($HEAD . "OPTION TOL_LOOP 500\nOPTION TOL_FLOW 500\n" . $LOOP, $rn, $rok);
    is('a REJECTED calculation\'s block says so in its first line, not for design use',
       $rt =~ /^\/\/== PHCP RESULTS.*REJECTED.*NOT FOR DESIGN USE/m);
    is('every line of the block is a comment the model reader ignores',
       !grep { !/^\/\// } grep { /\S/ } split /\n/, substr($rt, index($rt, $HardyCross::Results::BEGIN)));

    # The command line, the JSON, the editor's check and the report agree.
    for my $c (['loose tolerance', $HEAD . "OPTION TOL_LOOP 500\nOPTION TOL_FLOW 500\n" . $LOOP],
               ['joint unresolved', $HEAD . $TWO],
               ['coarse orifice step', $HEAD . "OPTION ORIF_STEP 6\nWATER SRC 0 1000\nNODE J1 0\nNODE A 0\n"
                                      . "HYDRANT A2 0 400 28.28427125\nUSE BORE 120\nPIPE M1 SRC J1 20 100\n"
                                      . "PIPE P1 J1 A 12 50\nUSE ASAM\nPIPE OP1 A A2 0 50\nOPP OP1 150\n"]) {
        my ($nn, $ok) = solve($c->[1]);
        my $acc = HardyCross::Validate::assess($nn, $ok)->{validation}{acceptance};
        my ($x, $o) = run($c->[1], '--json');
        my $jj = eval { decode_json($o) } || {};
        my $rep = HardyCross::Report::write_report($nn, $ok, 'm.phc');
        is("$c->[0]: the CLI JSON, the report and the assessment agree ($acc)",
           ($jj->{acceptance} // '') eq $acc && $rep =~ /CALCULATION ACCEPTANCE[^\n]*\n(?:[^\n]*\n){0,6}[^\n]*\b$acc\b/,
           "json $jj->{acceptance}");
        my $block = HardyCross::Results::with_results($c->[1], $nn, $ok);
        is("$c->[0]: the results block agrees", $block =~ /^\/\/= RESULT\s+ACCEPTANCE $acc\b/m);
    }
}

unlink glob("$TMP/*");
rmdir $TMP;
printf "\n%d passed, %d failed\n", $pass, $fail;
exit($fail ? 1 : 0);
