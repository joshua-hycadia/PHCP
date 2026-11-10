#!/usr/bin/perl
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# test_validate.pl -- HardyCross::Validate and the false positives it catches.
#
#   perl tools/test_validate.pl
#
# Every case says whether the model must be ACCEPTED, NONCOMPLIANT (valid but
# failing its design), REJECTED (converged but not a valid answer) or
# INDETERMINATE (no settled, converged solution), and why.  Five parts:
#
#   1. THE EXAMPLES.  Each is numerically and physically valid, and its
#      residuals are within tolerance.
#   2. THE DEFECTS FOUND (10 November 2026).  Each was reported converged and
#      used before; each is now refused, for the reason stated.  The model is
#      the smallest that shows it.
#   3. OUTER-LOOP CONVERGENCE.  An unconverged solve adjusts no device; a
#      solve whose device states have not settled is not converged.
#   4. INDEPENDENCE.  A network tampered with after the solve -- a flow, a
#      head, a NaN -- is caught: the checks are worked from the network, not
#      taken from the solver.
#   5. DESIGN, EXIT STATUS AND CONSISTENCY.  The design checks, the exit status
#      phcp.pl gives for each acceptance, and the report, the JSON and the
#      editor agreeing on it.
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
use HardyCross::Json;
use HardyCross::Report;
use JSON::PP;

my $EX = "$FindBin::Bin/../examples";
my $GW = $HardyCross::GAMMA_W;
my ($pass, $fail) = (0, 0);
sub is {
    my ($name, $ok, $why) = @_;
    printf "  %-68s %s\n", $name, $ok ? 'ok' : '*** FAIL';
    print "      $why\n" if !$ok && defined $why;
    $ok ? $pass++ : $fail++;
}

my $HEAD = join "\n", 'UNITS LENGTH M', 'UNITS ELEVATION M', 'UNITS SIZE MM', 'UNITS PRESSURE KPA',
                      'UNITS FLOW LPM', 'UNITS KFACTOR LPM/KPA', 'METHOD HW', 'USE BORE 120', '';
# solve -- (net, ok, validation) for model text (the header added).
sub solve {
    my ($body, %o) = @_;
    my $net = HardyCross::Phc::read_string(($o{bare} ? '' : $HEAD) . $body);
    my $ok = HardyCross::solve_model($net);
    return ($net, $ok, HardyCross::Validate::validate($net, $ok));
}
sub codes { my $v = shift; my %c; $c{ $_->{code} }++ for grep { $_->{severity} eq 'error' } @{ $v->{findings} }; \%c }
sub elem { my ($n, $id) = @_; my ($e) = grep { $_->{id} eq $id } @{ $n->{elems} }[1 .. $#{ $n->{elems} }]; $e }
sub slurp { my $p = shift; open my $f, '<', $p or die "$p: $!\n"; local $/; <$f> }
# run -- phcp.pl on model text: (exit, stdout).
my $TMP = "$FindBin::Bin/../.test_validate_tmp";
mkdir $TMP;
sub run {
    my ($text, @args) = @_;
    my $m = "$TMP/m.phc";
    open my $f, '>', $m or die; print $f $text; close $f;
    my $out = `"$^X" "$FindBin::Bin/../phcp.pl" @args "$m" 2>&1`;
    return ($? >> 8, $out);
}

#==============================================================================
print "1. THE EXAMPLES\n";
#==============================================================================
# 04 (the 1000-pipe grid) is left out for time; the stress test covers grids.
# 12 has pipes of size 0, which only make sense once sized: it is solved with
# its sizing, as phcp.pl does.
for my $path (grep { !/grid1000/ } sort glob("$EX/*.phc")) {
    my ($name) = $path =~ m{([^/\\]+)\.phc\z};
    my $net = HardyCross::Parse::read_model($path);
    my $ok = HardyCross::solve_model($net);
    if ($net->{auto_sizing}) { require HardyCross::Sizing; ($net, $ok) = HardyCross::Sizing::size($net, $ok) }
    if ($net->{areas})       { require HardyCross::Areas;  ($net, $ok) = HardyCross::Areas::governing($net, $ok) }
    my $v = HardyCross::Validate::validate($net, $ok);
    is("$name: numerically and physically valid ($v->{acceptance})",
       $v->{numerical}{status} eq 'PASS' && $v->{physical}{status} eq 'PASS',
       join ' ', map { "$_->{code}($_->{item})" } grep { $_->{severity} eq 'error' } @{ $v->{findings} });
    my $r = $v->{residuals};
    is("   residuals within tolerance (loop $r->{loop}{value}, continuity $r->{continuity}{value})",
       (grep { $r->{$_}{pass} } qw(continuity balance loop element)) == 4);
}

#==============================================================================
print "2. THE DEFECTS FOUND\n";
#==============================================================================

# D1.  A fixed flow at a node with no route to any supply.  The solve "fed"
# it by running 100 L/min backwards INTO sprinkler S2, and the JSON printed
# S2's flow as +100.
my $d1 = <<'EOF';
WATER W 0 500
NODE A 0
SPRINKLER S1 0 -50 80
NODE B 0
SPRINKLER S2 0 -50 80
FIXEDFLOW F B 100
PIPE P1 W A 10 50
PIPE P2 A S1 5 25
PIPE P3 B S2 5 25
EOF
{
    my ($n, $ok, $v) = solve($d1);
    my $c = codes($v);
    is('D1 demand fed through a sprinkler: REJECTED', $v->{acceptance} eq 'REJECTED', $v->{acceptance});
    is('   the backward discharge is found (OUTLET_REVERSE at S2)',
       $c->{OUTLET_REVERSE} && grep { $_->{code} eq 'OUTLET_REVERSE' && $_->{item} eq 'S2' } @{ $v->{findings} });
    is('   and the demands with no supply (DEMAND_UNCONNECTED, F and S2)', ($c->{DEMAND_UNCONNECTED} // 0) == 2);
    my $j = HardyCross::Json::results($n, $ok, 'd1', demand => 0);
    my ($s2) = grep { $_->{id} eq 'S2' } @{ $j->{outlets} };
    is('   the JSON gives S2 its signed flow, -100, and FAIL', $s2->{flow} < -99 && !$s2->{pass},
       "flow $s2->{flow}");
    my ($code) = run($HEAD . $d1, '--json');
    is('   phcp.pl exits 3 (REJECTED)', $code == 3, "exit $code");
    my $as = HardyCross::Validate::assess($n, $ok);
    is('   no supply pressure meets it: the design fails too (DEMAND_NOT_FOUND)',
       codes($as->{validation})->{DEMAND_NOT_FOUND} && $as->{validation}{design}{status} eq 'FAIL');
}

# D2.  A pump whose check valve, closing, would isolate the fixed flow it
# feeds.  The revert zeroed the pump's flow, rebuilt the tree only, and
# reported no change: continuity was out by 200 L/min at both ends of the
# pump, and the solve was reported converged.
my $d2 = <<'EOF';
WATER WB 0 900
NODE B 0
NODE A 0
FIXEDFLOW F A 200
SPRINKLER S1 0 -50 80
PIPE P1 WB B 10 100
PUMP PU A B 100 500 80 1000 50
PIPE P2 B S1 10 50
EOF
{
    my ($n, $ok, $v) = solve($d2);
    is('D2 pump isolation: continuity now holds (residual within tolerance)',
       $v->{residuals}{continuity}{pass}, "continuity $v->{residuals}{continuity}{value}");
    is('   the pump is left open with its true flow, -200', abs(elem($n, 'PU')->{q} + 200) < 1e-6,
       elem($n, 'PU')->{q});
    is('   REJECTED: PUMP_ISOLATING', $v->{acceptance} eq 'REJECTED' && codes($v)->{PUMP_ISOLATING}, $v->{acceptance});
}

# A pump whose outlet is held by a second, stronger supply above what it can
# lift to: its check valve closes and the network solves without it.  A valid
# closure is not a failure.
{
    my ($n, $ok, $v) = solve(<<'EOF');
WATER W1 0 100
WATER W2 0 900
NODE A 0
NODE B 0
SPRINKLER S1 0 -50 80
PIPE P1 W1 A 10 100
PUMP PU A B 300 500 280 1000 200
PIPE P2 W2 B 10 100
PIPE P3 B S1 10 50
EOF
    is('a pump shut on its check valve by a stronger supply: shut, not rejected',
       elem($n, 'PU')->{closed} && $v->{acceptance} =~ /^(ACCEPTED|NONCOMPLIANT)\z/, $v->{acceptance});
}

# D5.  A supply curve whose pressure RISES with flow: accepted and solved.
{
    my ($n, $ok, $v) = solve(<<'EOF');
WATER W 0 300 500 400 1000 600
NODE A 0
SPRINKLER S1 0 -50 80
PIPE P1 W A 10 50
PIPE P2 A S1 5 25
EOF
    is('D5 a rising supply curve: REJECTED, SUPPLY_CURVE_RISING',
       $v->{acceptance} eq 'REJECTED' && codes($v)->{SUPPLY_CURVE_RISING}, $v->{acceptance});
}

# D6.  Two supplies, one far weaker: water runs INTO it.  Unremarked.
{
    my ($n, $ok, $v) = solve(<<'EOF');
WATER WA 0 800
WATER WB 0 200
NODE A 0
SPRINKLER S1 0 -50 80
PIPE P1 WA A 10 50
PIPE P2 WB A 10 50
PIPE P3 A S1 5 25
EOF
    is('D6 a supply taking water in: REJECTED, SUPPLY_REVERSE at WB',
       $v->{acceptance} eq 'REJECTED' && grep { $_->{code} eq 'SUPPLY_REVERSE' && $_->{item} eq 'WB' } @{ $v->{findings} });
}

# D7.  An orifice plate asked for a drop smaller than a plate of nearly the
# full bore gives.  The bisection returned the end of its bracket, which then
# ROUNDED UP to the full pipe bore (50.0 mm in a 50.0 mm pipe), and the plate
# was accepted.
{
    my ($n, $ok, $v) = solve(<<'EOF');
WATER W 0 500
NODE A 0
SPRINKLER S1 0 -50 80
PIPE P1 W A 10 50
OPP P1 0.001
PIPE P2 A S1 5 25
EOF
    my $op = elem($n, 'P1.OPP');
    is('D7 an unachievable orifice duty: REJECTED, ORIFICE_UNACHIEVABLE',
       $v->{acceptance} eq 'REJECTED' && codes($v)->{ORIFICE_UNACHIEVABLE}, $v->{acceptance});
    is('   the rounded bore stays below the pipe bore', $op->{bore} < $op->{pipedia}, "$op->{bore} in $op->{pipedia}");
}

# A plate that meets its duty: its final drop is stated against its target.
{
    my $net = HardyCross::Parse::read_model("$EX/06_orifice.phc");
    my $ok = HardyCross::solve_model($net);
    my $v = HardyCross::Validate::validate($net, $ok);
    my @dev = grep { $_->{code} eq 'ORIFICE_DEVIATION' } @{ $v->{findings} };
    my $e = elem($net, $dev[0]{item}) if @dev;
    is('06 orifice: the final drop is stated against the target, and is the plate\'s own',
       @dev && abs($e->{dp_final} - HardyCross::orifice_dp(abs $e->{q}, $e->{bore}, $e->{pipedia}, $e->{cd})) < 1e-9
       && !$e->{size_clamp});
}

# A pressure ratio valve whose inlet is below its minimum.
{
    my ($n, $ok, $v) = solve(<<'EOF');
WATER W 0 400
NODE A 0
SPRINKLER S1 0 -20 80
PIPE P1 W A 10 100
PRA P1 3:1 600
PIPE P2 A S1 5 50
EOF
    is('a ratio valve below its minimum inlet: REJECTED, PRA_MIN_INLET',
       $v->{acceptance} eq 'REJECTED' && codes($v)->{PRA_MIN_INLET}, $v->{acceptance});
}

# A ratio valve between two supplies, flow wanting to run back through it.
# Its drop changes sign with the flow, so there is no steady answer.  Before,
# the outer loop kept adjusting the valve on unconverged solves: 60 passes of
# 50000 iterations, and then the demand point on top -- minutes, for nothing.
{
    my $t0 = time;
    my ($n, $ok, $v) = solve(<<'EOF');
WATER WA 0 1500
WATER WB 0 1400
NODE A 0
NODE B 0
SPRINKLER S1 0 -50 80
PIPE P1 WA A 10 100
PIPE P2 A B 10 100
PRA P2 3:1
PIPE P3 WB B 10 100
PIPE P4 A S1 5 25
EOF
    is('a ratio valve with no steady state: INDETERMINATE, NOT_CONVERGED',
       $v->{acceptance} eq 'INDETERMINATE' && codes($v)->{NOT_CONVERGED}, $v->{acceptance});
    is('   the outer loop stopped on the unconverged solve', ($n->{outer_stop} // '') eq 'inner_not_converged'
       && time - $t0 < 60, "$n->{outer_stop}, " . (time - $t0) . ' s');
    is("   the iteration is diagnosed (" . ($n->{nonconv} // 'none') . ')', defined $n->{nonconv});
}

# A node below the vapour pressure of water: a weak supply under a high head.
{
    my ($n, $ok, $v) = solve(<<'EOF');
WATER W 0 50
NODE A 15
FIXEDFLOW F A 100
PIPE P1 W A 20 50
EOF
    is('a pressure below the vapour pressure: REJECTED, BELOW_VAPOUR',
       $v->{acceptance} eq 'REJECTED' && codes($v)->{BELOW_VAPOUR}, $v->{acceptance});
}

#==============================================================================
print "3. OUTER-LOOP CONVERGENCE\n";
#==============================================================================
# The orifice example needs a second outer pass: the plate is sized on the
# first solve and the network solved again with it.  Allowed only one pass,
# the solve used to return converged regardless.
{
    local $HardyCross::MAX_OUTER = 1;
    my $net = HardyCross::Parse::read_model("$EX/06_orifice.phc");
    my $ok = HardyCross::solve_model($net);
    my $v = HardyCross::Validate::validate($net, $ok);
    is('device states not settled: the solve is not converged', !$ok && !$net->{outer_settled},
       "ok $ok settled $net->{outer_settled}");
    is('   INDETERMINATE, DEVICES_UNSETTLED', $v->{acceptance} eq 'INDETERMINATE' && codes($v)->{DEVICES_UNSETTLED});
}
{
    my $net = HardyCross::Parse::read_model("$EX/06_orifice.phc");
    my $ok = HardyCross::solve_model($net);
    is('   with the normal limit it settles and converges', $ok && $net->{outer_settled} && $net->{outer_passes} >= 2,
       "passes $net->{outer_passes}");
}
# An unconverged inner solve sizes no plate.
{
    my $text = slurp("$EX/06_orifice.phc") . "\nOPTION MAXITER 1\n";
    my $net = HardyCross::Phc::read_string($text);
    my $ok = HardyCross::solve_model($net);
    my $v = HardyCross::Validate::validate($net, $ok);
    my @unsized = grep { $_->{kind} eq 'ORIFICE_REQUIRED' } @{ $net->{elems} }[1 .. $#{ $net->{elems} }];
    is('an unconverged solve: no plate sized on it, INDETERMINATE',
       !$ok && @unsized && $v->{acceptance} eq 'INDETERMINATE', "ok $ok unsized " . scalar(@unsized));
}

#==============================================================================
print "4. INDEPENDENCE\n";
#==============================================================================
{
    my ($n, $ok, $v) = solve(<<'EOF');
WATER W 0 700
NODE A 0
NODE B 0
SPRINKLER S1 3 -100 80
SPRINKLER S2 3 -100 80
PIPE P1 W A 10 100
PIPE P2 A B 8 80
PIPE P3 A S1 5 50
PIPE P4 B S2 5 50
PIPE P5 S1 S2 6 50
EOF
    is('a looped network: ACCEPTED or NONCOMPLIANT', $v->{acceptance} =~ /^(ACCEPTED|NONCOMPLIANT)\z/, $v->{acceptance});
    elem($n, 'P2')->{q} += 5;
    my $t = HardyCross::Validate::validate($n, $ok);
    is('   a flow changed by 5 L/min after the solve: REJECTED, CONTINUITY',
       $t->{acceptance} eq 'REJECTED' && codes($t)->{CONTINUITY}, $t->{acceptance});
    elem($n, 'P2')->{q} -= 5;
    my ($bi) = grep { $n->{nodes}[$_]{id} eq 'B' } 1 .. $#{ $n->{nodes} };
    $n->{nodes}[$bi]{h} += 2;
    $t = HardyCross::Validate::validate($n, $ok);
    is('   a head changed by 2 kPa: REJECTED, ELEMENT_EQUATION',
       $t->{acceptance} eq 'REJECTED' && codes($t)->{ELEMENT_EQUATION}, $t->{acceptance});
    $n->{nodes}[$bi]{h} -= 2;
    elem($n, 'P5')->{q} = 9**9**9 / 9**9**9;
    $t = HardyCross::Validate::validate($n, $ok);
    is('   a NaN flow: INDETERMINATE, NONFINITE', $t->{acceptance} eq 'INDETERMINATE' && codes($t)->{NONFINITE},
       $t->{acceptance});
}

#==============================================================================
print "5. DESIGN, EXIT STATUS AND CONSISTENCY\n";
#==============================================================================
# One sprinkler well over its minimum, fed by a 50 mm pipe at some 7 m/s.
my $fast = <<'EOF';
WATER W 0 1200
NODE A 0
SPRINKLER S1 0 -50 80
PIPE P1 W A 10 50
PIPE P2 A S1 5 50
EOF
{
    my (undef, undef, $v) = solve($fast);
    my ($vl) = grep { $_->{code} eq 'VELOCITY_LIMIT' } @{ $v->{findings} };
    is('over the default velocity limit: a warning only', $vl && $vl->{severity} eq 'warning'
       && $v->{acceptance} eq 'ACCEPTED', $v->{acceptance});
    (undef, undef, $v) = solve($fast . "OPTION VEL_LIMIT 6\n");
    is('over a velocity limit the model sets: NONCOMPLIANT, VELOCITY_LIMIT',
       $v->{acceptance} eq 'NONCOMPLIANT' && codes($v)->{VELOCITY_LIMIT}, $v->{acceptance});
}
{
    # The supply has well under 1200 kPa in hand; ask for 5000.
    my $net = HardyCross::Phc::read_string($HEAD . $fast . "OPTION SUPPLY_MARGIN 5000\n");
    my $ok = HardyCross::solve_model($net);
    my $as = HardyCross::Validate::assess($net, $ok);
    is('a supply short of OPTION SUPPLY_MARGIN: NONCOMPLIANT, SUPPLY_ADEQUACY',
       $as->{validation}{acceptance} eq 'NONCOMPLIANT' && codes($as->{validation})->{SUPPLY_ADEQUACY},
       $as->{validation}{acceptance});
    my ($code) = run($HEAD . $fast . "OPTION SUPPLY_MARGIN 5000\n", '--json');
    is('   phcp.pl exits 0: a valid solution, failing its design', $code == 0, "exit $code");
}
{
    my $text = slurp("$EX/01_single_branch.phc");
    my ($code, $out) = run($text, '--json');
    my $j = eval { decode_json($out) };
    is('01: interface 2, ACCEPTED, exit 0', $j && $j->{interface} == 2 && $j->{acceptance} eq 'ACCEPTED' && $code == 0,
       "exit $code " . ($j ? $j->{acceptance} : $@));
    is('   the JSON carries the residuals and the traceability',
       $j && $j->{validation}{residuals}{loop} && $j->{traceability}{model_sha256} =~ /^[0-9a-f]{64}\z/);
    ($code) = run($text . "\nOPTION MAXITER 0\n", '--json');
    is('   with no iterations allowed: exit 1 (INDETERMINATE)', $code == 1, "exit $code");
}
# The report, the JSON and the editor give the same acceptance, for an
# accepted, a rejected and a noncompliant model.
for my $case ([ 'accepted', $HEAD . $fast ], [ 'rejected', $HEAD . $d1 ],
              [ 'noncompliant', $HEAD . $fast . "OPTION VEL_LIMIT 6\n" ]) {
    my ($what, $text) = @$case;
    my $net = HardyCross::Phc::read_string($text);
    my $ok = HardyCross::solve_model($net);
    my $rep = HardyCross::Report::write_report($net, $ok, 'm.phc');
    my $j = HardyCross::Json::results($net, $ok, 'm.phc');
    my ($racc) = $rep =~ /14\. CALCULATION ACCEPTANCE\s*\n=+\n RESULT\s+(\S+)/;
    require HardyCross::Editor;
    my $ed = HardyCross::Editor::solve_text($text, undef);
    my $eacc = HardyCross::Validate::assess($ed->{net}, $ed->{converged})->{validation}{acceptance};
    is("$what: report, JSON and editor agree ($j->{acceptance})",
       defined $racc && $racc eq $j->{acceptance} && $eacc eq $j->{acceptance}, "report $racc json $j->{acceptance} editor $eacc");
}

unlink glob("$TMP/*");
rmdir $TMP;
printf "\n%d passed, %d failed\n", $pass, $fail;
exit($fail ? 1 : 0);
