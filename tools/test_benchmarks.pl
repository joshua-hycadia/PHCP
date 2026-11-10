#!/usr/bin/perl
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# test_benchmarks.pl -- PHCP against reference values it did not compute.
#
#   perl tools/test_benchmarks.pl
#
# HardyCross::Validate checks that the solved network satisfies PHCP's own
# element equations.  That shows the answer is CONSISTENT; it cannot show the
# equations are RIGHT, since the check and the solver share them.  Here every
# reference value is worked without any PHCP function: from the published
# form of each equation, written out again in this file, with its unit
# conversions done here, and -- for whole networks -- by a different method
# of solution altogether.
#
#   A. ELEMENT EQUATIONS, each against its published form
#      Hazen-Williams      the NFPA 13 US-unit form, 4.52 Q^1.85/(C^1.85
#                          d^4.87) psi/ft, converted here (independent of
#                          the 6.05 x 10^5 bar/m form PHCP uses)
#      Darcy-Weisbach      the Colebrook-White equation iterated to 1e-14 in
#                          f, and a Moody chart point
#      elevation           the conventional metre of water, 9.80665 kPa
#                          (ISO 80000-4), applied by hand
#      equivalent length   a pipe of L with EQV E against one of L + E
#      K-factor            q = K sqrt(P), the definition of K
#      orifice plate       ISO 5167-2: the differential from Q = Cd/sqrt(1 -
#                          b^4) (pi d^2/4) sqrt(2 dP / rho), the permanent
#                          loss ratio from ISO 5167-2 clause 5.4, rho 999.1
#      pump curve          P = Pc - (Pc - P1)(Q/Q1)^1.85 through two points
#      water supply curve  the same N^1.85 form a flow test is plotted on
#      dry pipe valve      a flow coefficient's own definition, dP psi =
#                          (Q gpm / Cv)^2; an equivalent length of a stated
#                          pipe and C by the US-unit Hazen-Williams form
#   B. NETWORKS, against a NODAL NEWTON solve written here
#      Hardy Cross balances LOOP flows; the reference below solves NODE heads
#      by Newton's method with a numerical Jacobian -- a different set of
#      unknowns, equations and iteration, sharing no code with HardyCross.pm.
#      series, branched, looped, gridded, two supplies (one static, one on a
#      curve) with elevations and a fixed flow, and a pump.
#
# The closed-form case of examples/01 (Q = 80 sqrt(900 - 1.5677E-4 Q^1.85))
# is worked by bisection as well.  (Its comment printed 1.5689E-4 until 11
# November 2026, 0.08 % high; the resistance is now read from the comment and
# checked, so the two cannot drift apart again.)
#
# Agreement here is evidence that PHCP solves the published equations as
# published.  It is not evidence that those equations describe any real
# installation, nor external certification of PHCP.
#==============================================================================
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";
use HardyCross;
use HardyCross::Phc;
use HardyCross::Validate;

my ($pass, $fail) = (0, 0);
sub is {
    my ($name, $ok, $why) = @_;
    printf "  %-72s %s\n", $name, $ok ? 'ok' : '*** FAIL';
    print "      $why\n" if !$ok && defined $why;
    $ok ? $pass++ : $fail++;
}
sub rel { my ($a, $b) = @_; abs($a - $b) / (abs($b) > 1e-12 ? abs($b) : 1) }

# Unit conversions, written out here from their definitions.
my $GPM  = 3.785411784;          # L/min per US gpm (US gallon 3.785411784 L exactly)
my $IN   = 25.4;                 # mm per inch (exact)
my $FT   = 0.3048;               # m per foot (exact)
my $PSI  = 6.894757293168;       # kPa per psi (lbf/in2)
my $MH2O = 9.80665;              # kPa per conventional metre of water (ISO 80000-4)

# hw_us -- Hazen-Williams loss in kPa over $l m, by the NFPA 13 US form.
sub hw_us {
    my ($q_lpm, $c, $d_mm, $l_m) = @_;
    my $psi_ft = 4.52 * ($q_lpm / $GPM) ** 1.85 / ($c ** 1.85 * ($d_mm / $IN) ** 4.87);
    return $psi_ft * $PSI / $FT * $l_m;
}

my $HEAD = join "\n", 'UNITS LENGTH M', 'UNITS ELEVATION M', 'UNITS SIZE MM', 'UNITS PRESSURE KPA',
                      'UNITS FLOW LPM', 'UNITS KFACTOR LPM/KPA', '';
my $TIGHT = "OPTION TOL_FLOW 1E-7\nOPTION TOL_LOOP 1E-8\nOPTION MAXITER 200000\n";
sub solve {
    my $text = shift;
    my $n = HardyCross::Phc::read_string($text);
    my $ok = HardyCross::solve_model($n);
    return ($n, $ok);
}
sub elem { my ($n, $id) = @_; my ($e) = grep { ($_->{id} // '') eq $id } @{ $n->{elems} }[1 .. $#{ $n->{elems} }]; $e }
sub node { my ($n, $id) = @_; my ($x) = grep { $_->{id} eq $id } @{ $n->{nodes} }[1 .. $#{ $n->{nodes} }]; $x }
sub gauge { my ($n, $id) = @_; my $x = node($n, $id); $x->{h} - $HardyCross::GAMMA_W * $x->{z} }

#==============================================================================
print "A. ELEMENT EQUATIONS\n";
#==============================================================================
{
    # Hazen-Williams: PHCP's 6.05E7 metric form against the NFPA 13 US form,
    # over flows and bores a sprinkler system uses.
    my $worst = 0;
    for my $q (50, 200, 1000, 3000, 8000) {
        for my $d (27.3, 53.1, 105.3, 155.1) {
            my $e = { kind => 'PIPE', len => 100, eqv => 0, dia => $d, c => 120, q => $q };
            my ($hf) = HardyCross::elem_hf($e, $q, { method => 'HW', hwk => $HardyCross::HWK_DEF, hwq => 1.85, hwd => 4.87 });
            my $r = rel($hf, hw_us($q, 120, $d, 100));
            $worst = $r if $r > $worst;
        }
    }
    is(sprintf('Hazen-Williams: within 0.1 %% of the NFPA 13 US form at every flow and bore (worst %.3f %%)', 100 * $worst),
       $worst < 0.001);

    # Darcy-Weisbach: Colebrook-White iterated to convergence.
    my $colebrook = sub {
        my ($re, $rr) = @_;
        my $x = 0.02;
        for (1 .. 200) { my $n = (-2 * log($rr / 3.7 + 2.51 / ($re * sqrt $x)) / log(10)) ** -2; last if abs($n - $x) < 1e-14; $x = $n }
        return $x;
    };
    my $wd = 0;
    for my $q (100, 1000, 5000) {
        for my $d (53.1, 105.3) {
            my $e = { kind => 'PIPE', len => 50, eqv => 0, dia => $d, c => 120, eps => 0.045, q => $q };
            my ($hf) = HardyCross::elem_hf($e, $q, { method => 'DW', nu => 1.004e-6 });
            my $v = ($q / 60000) / (3.14159265358979 * ($d / 1000) ** 2 / 4);
            my $re = $v * ($d / 1000) / 1.004e-6;
            my $f = $colebrook->($re, 0.045 / $d);
            my $ref = $f * (50 / ($d / 1000)) * 998.2 / 1000 * $v ** 2 / 2;     # kPa, rho 998.2
            my $r = rel($hf, $ref);
            $wd = $r if $r > $wd;
        }
    }
    # PHCP's DW loss is f (L/D) v^2/2 x gamma_w/g with gamma_w 9.80665, i.e. rho 1000;
    # the reference takes rho 998.2 (water at 20 C), so 0.18 % apart by design.
    is(sprintf('Darcy-Weisbach: within 0.5 %% of Colebrook-White (worst %.3f %%; 0.18 %% is rho 1000 against 998.2)',
               100 * $wd), $wd < 0.005);
    my $fm = $colebrook->(1e5, 1e-4);
    is(sprintf('  ... Colebrook at Re 1e5, e/D 1e-4 gives f = %.4f (Moody chart: 0.0185)', $fm), abs($fm - 0.0185) < 0.0003);
    is('  ... PHCP\'s friction factor there within 0.1 % of Colebrook',
       rel(HardyCross::dw_friction(1e5, 0.01, 100), $colebrook->(1e5, 1e-4)) < 0.001);

    # Elevation: a sprinkler 10 m up, its pressure the supply less the friction
    # (by the US form) less 10 m of water.
    my ($n, $ok) = solve($HEAD . "METHOD HW\n$TIGHT" . "USE BORE 120\nWATER S 0 600\nSPRINKLER H 10 -50 80\nPIPE P1 S H 30 53.1\n");
    my $q = elem($n, 'P1')->{q};
    my $ref = 600 - hw_us($q, 120, 53.1, 30) - 10 * $MH2O;
    # To within the 0.02 % the two Hazen-Williams forms differ by on the friction.
    my $hfr = hw_us($q, 120, 53.1, 30);
    is(sprintf('elevation: 10 m of rise costs 98.07 kPa (%.3f against %.3f kPa)', gauge($n, 'H'), $ref),
       abs(gauge($n, 'H') - $ref) < 0.001 * $hfr + 0.01);

    # Equivalent length: L 20 with EQV 15 is a pipe of 35.
    my ($n1) = solve($HEAD . "METHOD HW\n$TIGHT" . "USE BORE 120\nWATER S 0 600\nSPRINKLER H 0 -50 80\nPIPE P1 S H 20 53.1\nEQV P1 15\n");
    my ($n2) = solve($HEAD . "METHOD HW\n$TIGHT" . "USE BORE 120\nWATER S 0 600\nSPRINKLER H 0 -50 80\nPIPE P1 S H 35 53.1\n");
    is('equivalent length: a pipe of 20 m with 15 m EQV is a pipe of 35 m',
       abs(elem($n1, 'P1')->{q} - elem($n2, 'P1')->{q}) < 1e-4);

    # K-factor: q = K sqrt(P) at the solved pressure.
    is(sprintf('K-factor: the sprinkler gives K sqrt(P) at its pressure (%.4f against %.4f)', $q, 80 * sqrt(gauge($n, 'H'))),
       abs($q - 80 * sqrt(gauge($n, 'H'))) < 1e-3);

    # Orifice plate, ISO 5167-2.  The differential across the tappings from
    # Q = Cd E (pi d^2 / 4) sqrt(2 dP / rho), E = 1/sqrt(1 - b^4); the
    # permanent loss, the differential times the ISO 5167-2 ratio.
    my $iso = sub {
        my ($q_lpm, $d, $bigd, $cd) = @_;
        my $b = $d / $bigd;
        my $area = 3.14159265358979 * ($d / 1000) ** 2 / 4;
        my $qs = $q_lpm / 60000;
        my $diff = 999.1 / 2 * ($qs * sqrt(1 - $b ** 4) / ($cd * $area)) ** 2 / 1000;     # kPa
        my $s = sqrt(1 - $b ** 4 * (1 - $cd ** 2));
        return $diff * ($s - $cd * $b ** 2) / ($s + $cd * $b ** 2);
    };
    my $wo = 0;
    for my $c ([500, 25, 53.1], [1500, 35, 53.1], [2500, 60, 105.3], [800, 15, 27.3]) {
        my $r = rel(HardyCross::orifice_dp($c->[0], $c->[1], $c->[2], 0.596), $iso->(@$c, 0.596));
        $wo = $r if $r > $wo;
    }
    is(sprintf('orifice plate: within 0.1 %% of ISO 5167-2 (worst %.3f %%)', 100 * $wo), $wo < 0.001);

    # Pump curve: two points, churn 400 and 300 at 2000 L/min, P = 400 -
    # 100 (Q/2000)^1.85.
    my ($pn, $pok) = solve($HEAD . "METHOD HW\n$TIGHT" . "USE BORE 120\nWATER S 0 200\nNODE D 0\nSPRINKLER H 0 -50 80\n"
                           . "PUMP FP S D 400 2000 300\nPIPE P1 D H 40 105.3\n");
    my $qp = elem($pn, 'FP')->{q};
    my $rise = gauge($pn, 'D') - gauge($pn, 'S');
    is(sprintf('pump: its rise at %.1f L/min is 400 - 100 (Q/2000)^1.85 (%.3f against %.3f kPa)', $qp, $rise,
               400 - 100 * ($qp / 2000) ** 1.85), $pok && abs($rise - (400 - 100 * ($qp / 2000) ** 1.85)) < 0.01);

    # Water supply curve: the N^1.85 form a flow test is plotted on.
    my ($sn, $sok) = solve($HEAD . "METHOD HW\n$TIGHT" . "USE BORE 120\nWATER S 0 700 3000 500\nSPRINKLER H 0 -50 80\n"
                           . "PIPE P1 S H 40 105.3\n");
    my $qs = elem($sn, 'S')->{q};
    is(sprintf('water supply: at %.1f L/min it gives 700 - 200 (Q/3000)^1.85 (%.3f kPa)', $qs, gauge($sn, 'S')),
       $sok && abs(gauge($sn, 'S') - (700 - 200 * ($qs / 3000) ** 1.85)) < 0.01);

    # Dry pipe valve, flow coefficient: dP psi = (Q gpm / Cv)^2.
    my $dpv = { kind => 'DPV', loss => 'DB', cv => 1500, q => 2000 };
    my ($hcv) = HardyCross::elem_hf($dpv, 2000, {});
    is(sprintf('dry pipe valve Cv 1500 at 2000 L/min: %.4f kPa against (Q gpm / Cv)^2 psi', $hcv),
       rel($hcv, ((2000 / $GPM) / 1500) ** 2 * $PSI) < 1e-6);
    # ... and an equivalent length of a stated pipe and C, by the US form.
    my $dpe = { kind => 'DPV', loss => 'DB', eql => 9.5, ref_bore => 102.3, ref_c => 120, q => 2000 };
    my ($heq) = HardyCross::elem_hf($dpe, 2000, {});
    is(sprintf('dry pipe valve 9.5 m of 102.3 mm C 120 at 2000 L/min: %.4f kPa, within 0.1 %% of the US form', $heq),
       rel($heq, hw_us(2000, 120, 102.3, 9.5)) < 0.001);

    # The closed-form case of examples/01.
    my $r1 = 6.05e7 * 100 / (120 ** 1.85 * 100 ** 4.87);
    my $ex1 = do { local $/; open my $f, '<', "$FindBin::Bin/../examples/01_single_branch.phc" or die; <$f> };
    my ($said) = $ex1 =~ /SQRT\(900 - ([\d.]+E-?\d+)\*Q/;
    is(sprintf('examples/01: its resistance is %.5g, as its comment says (%s)', $r1, $said // 'none'),
       defined $said && abs($r1 - $said) < 5e-9);
    my ($lo, $hi) = (0, 3000);
    for (1 .. 100) { my $m = ($lo + $hi) / 2; if ($m < 80 * sqrt(900 - $r1 * $m ** 1.85)) { $lo = $m } else { $hi = $m } }
    my ($en) = solve($ex1);
    is(sprintf('examples/01: PHCP %.4f L/min against the closed form %.4f', elem($en, 'P1')->{q}, $lo),
       abs(elem($en, 'P1')->{q} - $lo) < 0.01);
}

#==============================================================================
print "B. NETWORKS, AGAINST A NODAL NEWTON SOLVE\n";
#==============================================================================
# A network is given as data, written out as .phc for PHCP and solved here
# by Newton's method on the node heads, with no PHCP function.
#   nodes    [ id, z ]
#   static   [ id, z, p ]                    a static supply
#   curve    [ id, z, pc, q1, p1 ]           a supply on the N^1.85 form
#   heads    [ id, z, preq, K ]              a sprinkler
#   pipes    [ id, a, b, L, d ]              C 120
#   pumps    [ id, in, out, pc, q1, p1 ]
#   fixed    [ id, node, q ]
sub phc_of {
    my $m = shift;
    my $t = $HEAD . "METHOD HW\n$TIGHT" . "USE BORE 120\n";
    $t .= "WATER $_->[0] $_->[1] $_->[2]\n" for @{ $m->{static} || [] };
    $t .= "WATER $_->[0] $_->[1] $_->[2] $_->[3] $_->[4]\n" for @{ $m->{curve} || [] };
    $t .= "NODE $_->[0] $_->[1]\n" for @{ $m->{nodes} || [] };
    $t .= "SPRINKLER $_->[0] $_->[1] -$_->[2] $_->[3]\n" for @{ $m->{heads} || [] };
    $t .= "PIPE @$_\n" for @{ $m->{pipes} || [] };
    $t .= "PUMP @$_\n" for @{ $m->{pumps} || [] };
    $t .= "FIXEDFLOW $_->[0] $_->[1] $_->[2]\n" for @{ $m->{fixed} || [] };
    return $t;
}
sub nodal {
    my $m = shift;
    my (%z, %fixedH, @free);
    $z{ $_->[0] } = $_->[1] for @{ $m->{nodes} || [] }, @{ $m->{heads} || [] }, @{ $m->{curve} || [] };
    for (@{ $m->{static} || [] }) { $z{ $_->[0] } = $_->[1]; $fixedH{ $_->[0] } = $_->[2] + $MH2O * $_->[1] }
    @free = sort grep { !exists $fixedH{$_} } keys %z;
    my %ix; @ix{@free} = 0 .. $#free;
    my $R = sub { my ($l, $d) = @_; 6.05e7 * $l / (120 ** 1.85 * $d ** 4.87) };
    my $flows = sub {
        my $H = shift;
        my $h = sub { exists $fixedH{ $_[0] } ? $fixedH{ $_[0] } : $H->[ $ix{ $_[0] } ] };
        my (%q, %net);
        for my $p (@{ $m->{pipes} || [] }) {
            my ($id, $a, $b, $l, $d) = @$p;
            my $dh = $h->($a) - $h->($b);
            my $f = ($dh <=> 0) * (abs($dh) / $R->($l, $d)) ** (1 / 1.85);
            $q{$id} = $f; $net{$a} -= $f; $net{$b} += $f;
        }
        for my $p (@{ $m->{pumps} || [] }) {
            my ($id, $i, $o, $pc, $q1, $p1) = @$p;
            my $lift = $h->($o) - $h->($i);
            my $f = $lift >= $pc ? 0 : $q1 * (($pc - $lift) / ($pc - $p1)) ** (1 / 1.85);
            $q{$id} = $f; $net{$i} -= $f; $net{$o} += $f;
        }
        for my $s (@{ $m->{heads} || [] }) {
            my $p = $h->($s->[0]) - $MH2O * $s->[1];
            my $f = $s->[3] * sqrt($p > 0 ? $p : 0);
            $q{"out:$s->[0]"} = $f; $net{ $s->[0] } -= $f;
        }
        for my $c (@{ $m->{curve} || [] }) {
            my ($id, $zz, $pc, $q1, $p1) = @$c;
            my $p = $h->($id) - $MH2O * $zz;
            my $f = $p >= $pc ? 0 : $q1 * (($pc - $p) / ($pc - $p1)) ** (1 / 1.85);
            $q{$id} = $f; $net{$id} += $f;
        }
        for my $x (@{ $m->{fixed} || [] }) { $net{ $x->[1] } -= $x->[2] }
        return (\%q, [ map { $net{$_} // 0 } @free ]);
    };
    my ($hmax) = sort { $b <=> $a } (values %fixedH, map { $_->[2] + $MH2O * $_->[1] } @{ $m->{curve} || [] });
    my @H = map { $hmax - 1 - $_ } 0 .. $#free;
    my $norm = sub { my $r = shift; my $s = 0; $s += $_ ** 2 for @$r; sqrt $s };
    my (undef, $r) = $flows->(\@H);
    for my $it (1 .. 400) {
        last if $norm->($r) < 1e-10;
        my $n = @free;
        my @J;
        for my $j (0 .. $n - 1) {
            my @Hp = @H; my $dh = 1e-7 * (abs($H[$j]) > 1 ? abs($H[$j]) : 1); $Hp[$j] += $dh;
            my (undef, $rp) = $flows->(\@Hp);
            $J[$_][$j] = ($rp->[$_] - $r->[$_]) / $dh for 0 .. $n - 1;
        }
        # Gaussian elimination with partial pivoting: J dx = -r.
        my @A = map { [ @{ $J[$_] }, -$r->[$_] ] } 0 .. $n - 1;
        for my $c (0 .. $n - 1) {
            my ($p) = sort { abs($A[$b][$c]) <=> abs($A[$a][$c]) } $c .. $n - 1;
            @A[$c, $p] = @A[$p, $c];
            for my $i ($c + 1 .. $n - 1) {
                my $k = $A[$i][$c] / $A[$c][$c];
                $A[$i][$_] -= $k * $A[$c][$_] for $c .. $n;
            }
        }
        my @dx = (0) x $n;
        for my $i (reverse 0 .. $n - 1) {
            my $s = $A[$i][$n];
            $s -= $A[$i][$_] * $dx[$_] for $i + 1 .. $n - 1;
            $dx[$i] = $s / $A[$i][$i];
        }
        # Damped: halve the step until the residual falls.
        my $t = 1;
        for (1 .. 40) {
            my @Hn = map { $H[$_] + $t * $dx[$_] } 0 .. $n - 1;
            my (undef, $rn) = $flows->(\@Hn);
            if ($norm->($rn) < $norm->($r) || $t < 1e-9) { @H = @Hn; $r = $rn; last }
            $t /= 2;
        }
    }
    my ($q) = $flows->(\@H);
    my %p = map { $_ => (exists $fixedH{$_} ? $fixedH{$_} : $H[ $ix{$_} ]) - $MH2O * $z{$_} } keys %z;
    return ($q, \%p, $norm->($r));
}
sub compare {
    my ($name, $m) = @_;
    my ($n, $ok) = solve(phc_of($m));
    my ($q, $p, $res) = nodal($m);
    my ($wq, $wp, $at) = (0, 0, '');
    for my $id (keys %$q) {
        my $eid = $id =~ /^out:(.*)/ ? $1 : $id;
        my $e = elem($n, $eid) or next;
        my $d = abs($e->{q} - $q->{$id});
        ($wq, $at) = ($d, $id) if $d > $wq;
    }
    for my $id (keys %$p) { my $d = abs(gauge($n, $id) - $p->{$id}); $wp = $d if $d > $wp }
    my $v = HardyCross::Validate::validate($n, $ok);
    is(sprintf('%-16s flows within 0.01 L/min, pressures within 0.01 kPa (worst %.2e, %.2e)', $name, $wq, $wp),
       $ok && $res < 1e-6 && $wq < 0.01 && $wp < 0.01, "worst flow at $at; reference residual $res");
    # The same network at PHCP's DEFAULT tolerances: within the verification limit.
    (my $text = phc_of($m)) =~ s/^OPTION (TOL_FLOW|TOL_LOOP|MAXITER) .*\n//mg;
    my ($nd, $okd) = solve($text);
    my $wd = 0;
    for my $id (keys %$p) { my $d = abs(gauge($nd, $id) - $p->{$id}); $wd = $d if $d > $wd }
    is(sprintf('%-16s at the default tolerances, pressures within the 0.1 kPa limit (%.3f)', $name, $wd),
       $okd && $wd <= $HardyCross::Validate::VERIFY_P);
}

compare('series', { static => [[ 'S', 0, 900 ]], heads => [[ 'H', 0, 50, 80 ]],
                    pipes => [[ 'P1', 'S', 'H', 100, 100 ]] });
compare('branched', { static => [[ 'S', 0, 700 ]], nodes => [[ 'A', 0 ], [ 'B', 3 ]],
                      heads => [[ 'H1', 3, 50, 80 ], [ 'H2', 3, 50, 80 ], [ 'H3', 0, 70, 115 ]],
                      pipes => [[ 'M', 'S', 'A', 40, 105.3 ], [ 'R', 'A', 'B', 3, 53.1 ], [ 'B1', 'B', 'H1', 4, 27.3 ],
                                [ 'B2', 'B', 'H2', 8, 27.3 ], [ 'B3', 'A', 'H3', 12, 41.9 ]] });
compare('looped', { static => [[ 'S', 0, 700 ]], nodes => [[ 'A', 0 ], [ 'B', 0 ], [ 'C', 0 ]],
                    heads => [[ 'H', 0, 50, 80 ]],
                    pipes => [[ 'P1', 'S', 'A', 10, 100 ], [ 'P2', 'A', 'B', 50, 50 ], [ 'P3', 'A', 'C', 20, 25 ],
                              [ 'P4', 'C', 'B', 20, 25 ], [ 'P5', 'B', 'H', 5, 50 ]] });
{
    # A 3 x 3 grid fed at one corner, four sprinklers at the far side.
    my (@nodes, @pipes, @heads);
    for my $i (1 .. 3) { for my $j (1 .. 3) { push @nodes, [ "G$i$j", 4 ] } }
    for my $i (1 .. 3) {
        for my $j (1 .. 3) {
            push @pipes, [ "X$i$j", "G$i$j", 'G' . $i . ($j + 1), 3.5, 36.0 ] if $j < 3;
            push @pipes, [ "Y$i$j", "G$i$j", 'G' . ($i + 1) . $j, 3.0, 41.9 ] if $i < 3;
        }
    }
    for my $k (1 .. 3) { push @heads, [ "H$k", 4, 50, 80 ]; push @pipes, [ "D$k", "G${k}3", "H$k", 0.6, 27.3 ] }
    push @heads, [ 'H4', 4, 50, 80 ]; push @pipes, [ 'D4', 'G32', 'H4', 0.6, 27.3 ];
    compare('gridded', { static => [[ 'S', 0, 650 ]], nodes => \@nodes, heads => \@heads,
                         pipes => [[ 'F', 'S', 'G11', 25, 80.9 ], @pipes] });
}
compare('two supplies', { static => [[ 'A', 0, 950 ]], curve => [[ 'D', 4, 900, 5000, 400 ]],
                          nodes => [[ 'B', 2 ]],
                          heads => [[ 'C', 2, 50, 80 ], [ 'E', 4, 50, 115 ], [ 'F', 6, 50, 80 ]],
                          pipes => [[ 'P1', 'A', 'B', 25, 150 ], [ 'P2', 'B', 'C', 30, 100 ], [ 'P3', 'C', 'D', 22, 100 ],
                                    [ 'P4', 'D', 'B', 35, 80 ], [ 'P5', 'C', 'E', 18, 80 ], [ 'P6', 'E', 'D', 20, 65 ],
                                    [ 'P7', 'E', 'F', 15, 50 ]],
                          fixed => [[ 'F1', 'B', 400 ]] });
compare('pump', { static => [[ 'S', 0, 200 ]], nodes => [[ 'D', 0 ], [ 'J', 6 ]],
                  heads => [[ 'H1', 6, 50, 80 ], [ 'H2', 6, 50, 80 ]],
                  pipes => [[ 'P1', 'D', 'J', 60, 105.3 ], [ 'B1', 'J', 'H1', 6, 41.9 ], [ 'B2', 'J', 'H2', 12, 41.9 ]],
                  pumps => [[ 'FP', 'S', 'D', 600, 3000, 450 ]] });

printf "\n%d passed, %d failed\n", $pass, $fail;
exit($fail ? 1 : 0);
