#!/usr/bin/perl
# HardyCross.pm -- the Hardy Cross loop engine behind PHCP, the Perl Hydraulic
# Calculation Program.
#
# SCOPE
# Parser, topology and solver -- the calculation, not the report.  Eight full
# implementations already agree line for line on the report text; a ninth
# report writer would prove nothing.  What is worth having is another
# independent derivation of the FLOWS, checked numerically against the C++
# engine by crosscheck.pl.
#
# It covers Hazen-Williams and Darcy-Weisbach, unit conversion on input, pumps,
# static and curve supplies, pressure-dependent outlets, fixed-flow demands,
# PRVs, backflow preventers, orifice plates of known bore, and the outer loop
# that sizes an ORIFICE_P against AS 2118.1 equation B3 and re-solves.
#
# THE MODEL, unchanged from every other implementation
# Everything is an EDGE.  A single virtual REFERENCE node sits at total head
# zero -- atmosphere at datum.  Supplies are edges from REF into the network;
# discharges are edges from a node back to REF.  Fundamental loops built over
# that graph produce real loops AND pseudo-loops between fixed-grade nodes with
# no special-case code, which is what makes multiple supplies fall out of plain
# Hardy Cross rather than needing a separate mechanism.

package HardyCross;

# The PHCP version.  Printed on every report: a calculation submitted for
# certification has to identify the software AND the build that produced it,
# so that a result can be reproduced -- or recalled -- later.
our $VERSION = '1.3.0';

use strict;
use warnings;
use POSIX qw(floor);

our $GAMMA_W = 9.80665;      # kPa per metre of water
our $Q_TINY  = 1.0e-6;
our $D_TINY  = 1.0e-9;
our $HWK_DEF = 6.05e7;       # AS 2118.1 / NFPA 13 metric form, kPa/m basis

# ---------------------------------------------------------------------------
# Errors.
#
# die with a blessed hash rather than a plain string, so a caller can tell a
# model error (report it to the user) from a programming error (a bug worth
# seeing the stack for).  Perl makes it far too easy to conflate the two.
# ---------------------------------------------------------------------------
sub fail {
    my ($fmt, @args) = @_;
    die bless { msg => sprintf($fmt, @args) }, 'HardyCross::ModelError';
}

sub is_model_error { ref($_[0]) eq 'HardyCross::ModelError' }

# ---------------------------------------------------------------------------
# Units.  Internal working units are L/min, kPa, m and mm; every factor
# multiplies a user value to give the internal one, and conversion happens once
# on the way in.  Never in the solver, where a stray factor would be almost
# impossible to find.
# ---------------------------------------------------------------------------
my %UNIT_TABLE = (
    FLOW => { LPM => 1, 'L/MIN' => 1, LPS => 60, 'L/S' => 60,
              M3H => 1000/60, 'M3/H' => 1000/60,
              GPM => 3.785411784, USGPM => 3.785411784, IGPM => 4.54609 },
    PRESSURE => { KPA => 1, BAR => 100, MPA => 1000, PSI => 6.894757,
                  M => $GAMMA_W, MH2O => $GAMMA_W, MWC => $GAMMA_W,
                  FTH2O => $GAMMA_W * 0.3048, FT => $GAMMA_W * 0.3048 },
    LENGTH => { M => 1, MM => 0.001, FT => 0.3048, IN => 0.0254 },
    DIAMETER => { MM => 1, M => 1000, IN => 25.4 },
);
my %UNIT_ALIAS = (PRES => 'FLOW');   # placeholder, fixed below

sub set_unit {
    my ($net, $quantity, $name) = @_;
    my %alias = (PRES => 'PRESSURE', LEN => 'LENGTH', DIA => 'DIAMETER');
    $quantity = $alias{$quantity} // $quantity;
    my $tbl = $UNIT_TABLE{$quantity} or fail("unknown UNITS entry %s", $quantity);
    my $f = $tbl->{$name};
    defined $f or fail("unknown unit %s for %s", $name, $quantity);
    my %slot = (FLOW => 'f_flow', PRESSURE => 'f_pres',
                LENGTH => 'f_len', DIAMETER => 'f_dia');
    my %nslot = (FLOW => 'u_flow', PRESSURE => 'u_pres',
                 LENGTH => 'u_len', DIAMETER => 'u_dia');
    $net->{ $slot{$quantity} }  = $f;
    $net->{ $nslot{$quantity} } = $name;
}

# ---------------------------------------------------------------------------
# Curves for supplies, pumps and loss devices (backflow preventers, PRVs).
#
# The curve passes EXACTLY through every point given, interpolated piecewise
# on a Q^1.85 scale: between two points, pressure is linear in Q^1.85.  That
# is the scale water supply test results are plotted on in sprinkler practice,
# because a main's pressure falls with friction and Hazen-Williams friction
# goes as Q^1.85 -- so a supply given by its static and one residual point is
# reproduced the way the flow test is read.  (decided 28 October
# 2026.  The curve used to be one quadratic: exact through two points, but a
# least-squares fit through three or more that did NOT pass through the
# points entered.)
#
# Outside the points the curve continues LINEARLY at the end slope, so P and
# P' stay finite and monotone everywhere -- which keeps the loop correction
# well posed when an iterate overshoots past the last point, or flow runs
# backwards through a supply.
#
# The curve record holds the points sorted by flow, q[] and p[], their Q^1.85
# values x[], and the guarded end slopes slo and shi.
# ---------------------------------------------------------------------------
my $CURVE_N = 1.85;

sub fit_curve {
    my ($c, $rising) = @_;
    my @pt = sort { $a->[0] <=> $b->[0] } map { [ $c->{q}[$_], $c->{p}[$_] ] } 0 .. $#{ $c->{q} };
    fail("curve needs at least 2 points") if @pt < 2;
    for my $i (1 .. $#pt) {
        fail("curve points have identical flow") if abs($pt[$i][0] - $pt[$i - 1][0]) < $D_TINY;
    }
    fail("curve flows cannot be negative") if $pt[0][0] < 0;
    $c->{q} = [ map { $_->[0] } @pt ];
    $c->{p} = [ map { $_->[1] } @pt ];
    $c->{x} = [ map { $_->[0] ** $CURVE_N } @pt ];
    $c->{qlo} = $c->{q}[0];
    $c->{qhi} = $c->{q}[-1];
    $c->{plo} = $c->{p}[0];
    $c->{phi} = $c->{p}[-1];
    $c->{slo} = curve_inner_slope($c, $c->{qlo});
    $c->{shi} = curve_inner_slope($c, $c->{qhi});

    # Guard the end slopes so the Jacobian cannot degenerate: at zero flow the
    # Q^1.85 scale has zero slope, and a zero puts a zero in the denominator
    # of the loop correction the first time an iterate wanders outside the
    # points.  The chord over the whole curve stands in, as before.
    my $span  = ($c->{qhi} - $c->{qlo}) > $D_TINY ? ($c->{qhi} - $c->{qlo}) : $D_TINY;
    my $chord = ($c->{phi} - $c->{plo}) / $span;
    if ($rising) {
        $c->{slo} = ($chord > $D_TINY ? $chord : $D_TINY) if $c->{slo} < $D_TINY;
        $c->{shi} = ($chord > $D_TINY ? $chord : $D_TINY) if $c->{shi} < $D_TINY;
    } else {
        $c->{slo} = ($chord < -$D_TINY ? $chord : -$D_TINY) if $c->{slo} > -$D_TINY;
        $c->{shi} = ($chord < -$D_TINY ? $chord : -$D_TINY) if $c->{shi} > -$D_TINY;
    }
    return $c;
}

# curve_segment -- the index i of the segment [q[i], q[i+1]] holding $q.
sub curve_segment {
    my ($c, $q) = @_;
    my $n = $#{ $c->{q} };
    for my $i (0 .. $n - 2) { return $i if $q <= $c->{q}[ $i + 1 ] }
    return $n - 1;
}

# curve_inner_slope -- dP/dQ inside the points: linear in x = Q^1.85, so
# dP/dQ = (dP/dx) * 1.85 Q^0.85.  At the last point the last segment's slope
# is used; at the first, the first's.
sub curve_inner_slope {
    my ($c, $q) = @_;
    my $i = curve_segment($c, $q);
    my $m = ($c->{p}[ $i + 1 ] - $c->{p}[$i]) / ($c->{x}[ $i + 1 ] - $c->{x}[$i]);
    return $m * $CURVE_N * ($q > 0 ? $q ** ($CURVE_N - 1) : 0);
}

sub curve_eval {
    my ($c, $q) = @_;
    return $c->{plo} + $c->{slo} * ($q - $c->{qlo}) if $q < $c->{qlo};
    return $c->{phi} + $c->{shi} * ($q - $c->{qhi}) if $q > $c->{qhi};
    my $i = curve_segment($c, $q);
    my ($x0, $x1) = ($c->{x}[$i], $c->{x}[ $i + 1 ]);
    return $c->{p}[$i] + ($c->{p}[ $i + 1 ] - $c->{p}[$i]) * ($q ** $CURVE_N - $x0) / ($x1 - $x0);
}

sub curve_slope {
    my ($c, $q) = @_;
    return $c->{slo} if $q < $c->{qlo};
    return $c->{shi} if $q > $c->{qhi};
    my $s = curve_inner_slope($c, $q);
    # The same guard inside the points: the Q^1.85 scale is flat at zero flow,
    # and the loop correction divides by this slope.
    return $c->{slo} if abs($s) < $D_TINY;
    return $s;
}

# ---------------------------------------------------------------------------
# Element hydraulics.
#
# hf is the head DROP from n1 to n2 for the element's own signed flow, and is
# odd-symmetric in q, so a loop traversed either way sums correctly and reverse
# flow needs no special case.  dhdq is always non-negative, which is what the
# Hardy Cross denominator wants.
#
# Perl has no dispatch worth using here, so this is a table of closures keyed
# by kind -- which at least keeps each element's physics in one place instead
# of scattered through a long if/elsif chain.
# ---------------------------------------------------------------------------
sub pipe_velocity {
    my ($q, $dia) = @_;
    return 0 if $dia <= $D_TINY;
    return ($q / 60000) / (3.14159265358979 * ($dia / 1000) ** 2 / 4);
}

sub dw_friction {
    my ($re, $eps, $d) = @_;
    return 0 if $re < 1;
    return 64 / $re if $re < 2000;
    my $rr = $eps / (3.7 * $d);
    my $lg = sub { log($_[0]) / log(10) };
    my $a = -2 * $lg->($rr + 12 / $re);
    my $b = -2 * $lg->($rr + 2.51 * $a / $re);
    my $c = -2 * $lg->($rr + 2.51 * $b / $re);
    my $den = $c - 2 * $b + $a;
    my $f = abs($den) < 1e-12 ? 1 / ($a ** 2)
                              : 1 / (($a - ($b - $a) ** 2 / $den) ** 2);
    if ($re < 4000) {
        my $t = ($re - 2000) / 2000;
        $f = (1 - $t) * (64 / $re) + $t * $f;
    }
    return $f;
}

sub pipe_hf_dw {
    my ($e, $aq, $o) = @_;
    my $ltot = $e->{len} + $e->{eqv};
    my $dm   = $e->{dia} / 1000;
    my $vel  = pipe_velocity($aq, $e->{dia});
    my $nu   = $o->{nu} // 1.004e-6;
    my $re   = $vel * $dm / $nu;
    my $f    = dw_friction($re, $e->{eps}, $e->{dia});
    return $f * ($ltot / $dm) * $vel ** 2 / (2 * $GAMMA_W) * $GAMMA_W;
}

sub orifice_dp {
    # Fitted model, NOT part of AS 2118.1:
    #   dP = 633.28 (0.596/Cd)^2 (Q^2/d^4)(1-b^4) R,  b = d/D
    #   R  = [s - Cd b^2]/[s + Cd b^2],  s = sqrt(1 - b^4(1-Cd^2))
    # The first part is the differential across the tappings,
    # (rho/2)(Q/(Cd A))^2 (1-b^4).  In kPa with Q in L/min and d in mm its
    # constant is 224.954/Cd^2; 224.954 = 633.28 x 0.596^2 is the value PHCP
    # has always used at its default Cd of 0.596 (rho about 999.1 kg/m3, within
    # 0.1% of the 224.75 that 998.2 kg/m3 gives).  It is written as
    # 633.28 (0.596/Cd)^2 so that the default gives exactly the drop it always
    # has, and a CD given on the plate scales the differential as 1/Cd^2.
    # R is the ISO 5167 permanent pressure loss ratio, so dP is the NET loss
    # across the plate rather than the differential across the tappings --
    # which is the quantity a network calculation needs.
    my ($aq, $d, $bigd, $cd) = @_;
    $cd //= 0.596;
    return 0 if $d <= $D_TINY || $aq <= 0;
    my $beta = $bigd > $D_TINY ? ($d / $bigd < 0.99999 ? $d / $bigd : 0.99999) : 0;
    my $b4   = $beta ** 4;
    my $s    = sqrt(1 - $b4 * (1 - $cd ** 2) > 1e-12
                    ? 1 - $b4 * (1 - $cd ** 2) : 1e-12);
    my $cb2  = $cd * $beta ** 2;
    my $r    = ($s - $cb2) / ($s + $cb2);
    $r = 0 if $r < 0;
    return 633.28 * (0.596 / $cd) ** 2 * $aq ** 2 / $d ** 4 * (1 - $b4) * $r;
}

sub orifice_size {
    # dP falls monotonically with bore, so bisection is unconditionally safe.
    # The bore is found with orifice_dp itself, at the plate's own Cd, so a
    # plate sized here gives back exactly the drop it was sized for.
    # A fixed-point iteration on the approach factor oscillates once beta gets
    # large and is deliberately not used.
    my ($aq, $target, $bigd, $cd) = @_;
    return 0 if $aq <= $Q_TINY || $target <= $D_TINY || $bigd <= $D_TINY;
    my ($lo, $hi) = (0.001 * $bigd, 0.9995 * $bigd);
    return $hi if orifice_dp($aq, $hi, $bigd, $cd) > $target;
    return $lo if orifice_dp($aq, $lo, $bigd, $cd) < $target;
    for (1 .. 200) {
        my $mid = 0.5 * ($lo + $hi);
        if (orifice_dp($aq, $mid, $bigd, $cd) > $target) { $lo = $mid } else { $hi = $mid }
        last if $hi - $lo < 1e-9 * $bigd;
    }
    return 0.5 * ($lo + $hi);
}

sub b3_reference_flow { my $dn = shift; ($dn == 50 || $dn == 65) ? 500 : 5000 }

sub elem_hf {
    my ($e, $q, $o) = @_;
    my $aq = abs $q;
    my $sg = ($q < 0 && $aq >= $Q_TINY) ? -1 : 1;
    my $k  = $e->{kind};

    if ($k eq 'PIPE') {
        # Minor loss from fittings expressed as a velocity-head multiplier:
        #   hf = K v^2 / 2g * gamma
        #
        # WHICH METHOD THIS BELONGS TO
        # In Australian sprinkler practice a fitting allowance under
        # Hazen-Williams is an EQUIVALENT LENGTH, not a K: that is what
        # AS 2118.1 and the FM tables give, and mixing a velocity-head term
        # into an HW calculation is not how the method is meant to be used.
        # K belongs with Darcy-Weisbach.
        #
        # The engine nevertheless applies K under BOTH formulas, as general
        # network solvers do, so that a model means the same thing whichever
        # formula it is solved with.  The place to enforce the engineering rule is
        # the front end -- offer K on the Darcy-Weisbach path and equivalent
        # length on the Hazen-Williams one -- not here, where silently
        # dropping a term the user wrote would make the two engines disagree
        # with no way to see why.  That is exactly what happened: K was not
        # implemented at all, and 82 of 100 validation cases failed.
        my $minor = ($e->{kfit} // 0) > 0
                  ? sub { my $v = pipe_velocity($_[0], $e->{dia});
                          $e->{kfit} * $v ** 2 / (2 * $GAMMA_W) * $GAMMA_W }
                  : sub { 0 };

        if (($o->{method} // 'HW') eq 'DW') {
            # Under Darcy-Weisbach the friction factor itself varies with flow,
            # so n*hf/Q is not the derivative and it is formed numerically.
            my $hf = pipe_hf_dw($e, $aq, $o) + $minor->($aq);
            my $dq = 1e-4 > 1e-5 * $aq ? 1e-4 : 1e-5 * $aq;
            my $hp = pipe_hf_dw($e, $aq + $dq, $o) + $minor->($aq + $dq);
            my $lo = $aq - $dq > 0 ? $aq - $dq : 0;
            my $hm = pipe_hf_dw($e, $lo, $o) + $minor->($lo);
            return ($sg * $hf, ($hp - $hm) / (2 * $dq));
        }
        my $ltot = $e->{len} + $e->{eqv};
        my ($hwk, $nq, $nd) = ($o->{hwk}, $o->{hwq}, $o->{hwd});
        my $friction = $aq > 0
               ? $hwk * $ltot * $aq ** $nq / ($e->{c} ** $nq * $e->{dia} ** $nd)
               : 0;
        my $hf = $friction + $minor->($aq);
        # The exact Cross derivative is n*hf/Q with n the flow exponent in
        # force -- not 2*hf/Q, which only holds for n = 2.  That closed form
        # covers the FRICTION term only: a minor-loss term goes as v^2, a
        # different power, so once one is present the derivative is formed
        # numerically instead of adding two incompatible closed forms.
        if (($e->{kfit} // 0) > 0) {
            my $dq = 1e-4 > 1e-5 * $aq ? 1e-4 : 1e-5 * $aq;
            my $f = sub {
                my $q = shift;
                my $fr = $q > 0 ? $hwk * $ltot * $q ** $nq
                                  / ($e->{c} ** $nq * $e->{dia} ** $nd) : 0;
                return $fr + $minor->($q);
            };
            my $lo = $aq - $dq > 0 ? $aq - $dq : 0;
            return ($sg * $hf, ($f->($aq + $dq) - $f->($lo)) / (2 * $dq));
        }
        my $dh = $aq > $Q_TINY
               ? $nq * $friction / $aq
               : $nq * $hwk * $ltot * $Q_TINY ** ($nq - 1)
                 / ($e->{c} ** $nq * ($e->{dia} > $D_TINY ? $e->{dia} : $D_TINY) ** $nd);
        return ($sg * $hf, $dh);
    }
    if ($k eq 'PUMP') {
        # A booster in line: H2 = H1 + Ppump(q), so hf is negative.
        return (-curve_eval($e->{curve}, $q), abs curve_slope($e->{curve}, $q));
    }
    if ($k eq 'SUPPLY_STATIC') {
        # Edge REF -> node, so hf is a head GAIN and therefore negative.
        return (-($e->{pstat} + $GAMMA_W * $e->{z}), 0);
    }
    if ($k eq 'SUPPLY_CURVE') {
        return (-(curve_eval($e->{curve}, $q) + $GAMMA_W * $e->{z}),
                abs curve_slope($e->{curve}, $q));
    }
    if ($k eq 'DISCHARGE') {
        # Edge node -> REF: the pressure the outlet needs, plus its elevation
        # head, since REF sits at datum.
        my $kf = $e->{k} > $D_TINY ? $e->{k} : $D_TINY;
        my $dh = 2 * $aq / $kf ** 2;
        $dh = 2 * $Q_TINY / $kf ** 2 if $dh < $D_TINY;
        my $hf = $sg * ($aq / $kf) ** 2 + $GAMMA_W * $e->{z};
        # With OPTION VELOCITY_PRESSURE ON, a sprinkler discharges on the
        # normal pressure Pn = Pt - Pv, so the total pressure it needs is
        # (q/K)^2 + Pv.  Pv is set by the outer loop (velocity_pressures) from
        # the converged flows and held fixed while the loops balance, like a
        # ratio valve's drop, so it adds nothing to the derivative.  It is
        # only ever added when set: with the option OFF no outlet carries a
        # pv, and the arithmetic is exactly what it always was.
        $hf += $e->{pv} if $e->{pv};
        return ($hf, $dh);
    }
    # An ORIFICE_P whose bore has not been sized yet behaves as a fixed drop
    # of the pressure it is required to produce.  It MUST be listed here: it
    # used to fall through to the default at the bottom of this routine and
    # contribute ZERO, so the first solve ran as if the plate were absent, the
    # plate was then sized against that wrong duty, and the answer came out one
    # rounding step off -- 34.0 mm where the correct duty gives 33.5.  A
    # comparison with a general network solver could not catch it, because
    # such a solver has no concept of sizing a plate; only the direct
    # comparison against the C++ engine did.
    if ($k eq 'FIXED_DROP' || $k eq 'ORIFICE_REQUIRED' || $k eq 'RATIO') {
        # Contributes to the loop sum but not to the denominator.  A pressure
        # ratio valve's drop is set from its inlet pressure by the outer loop
        # (ratio_valves), and held fixed while the loops balance.
        return ($sg * $e->{dp}, 0);
    }
    if ($k eq 'ORIFICE') {
        my $pd = orifice_dp($aq, $e->{bore}, $e->{pipedia}, $e->{cd});
        my $dh = $aq > $Q_TINY
               ? 2 * $pd / $aq
               : 2 * orifice_dp($Q_TINY, $e->{bore}, $e->{pipedia}, $e->{cd}) / $Q_TINY;
        return ($sg * $pd, $dh);
    }
    if ($k eq 'BFP') {
        return ($sg * curve_eval($e->{curve}, $aq),
                abs curve_slope($e->{curve}, $aq));
    }
    if ($k eq 'DPV') {
        # A dry pipe valve, taken as TRIPPED AND FULLY OPEN: the steady state
        # after the clapper has released and the system has filled.  Its loss
        # is one of two things, chosen on the DPV line and printed in the
        # report as the basis used:
        #
        #   CURVE  the manufacturer's flow/loss points, read exactly as a
        #          backflow preventer's loss curve is (through every point,
        #          straight in Q^1.85 between them, extrapolated beyond).
        #   EQL    an equivalent length of the pipe the valve is in, at that
        #          pipe's bore and C (or roughness), by the pipe's own
        #          formula -- the form valve data is usually published in.
        #
        # With neither there is no loss data at all.  The valve then adds
        # nothing to the loop sum, and HardyCross::Validate REJECTS the
        # calculation: a zero loss is never assumed silently.
        #
        # Nothing about the trip -- ratio, trip pressure, accelerator, air --
        # enters here.  Those are kept on the element for the report and for a
        # future water delivery time calculation, which is a transient problem
        # and is deliberately not part of this steady-state solver.
        my $basis = $e->{loss} // 'NONE';
        if ($basis eq 'CURVE') {
            return ($sg * curve_eval($e->{curve}, $aq),
                    abs curve_slope($e->{curve}, $aq));
        }
        if ($basis eq 'DB' && $e->{cv}) {
            # A flow coefficient: dP psi = (Q gpm / Cv)^2, the data sheet's
            # own definition, in the engine's L/min and kPa.
            my $kq = 6.894757 / ($e->{cv} * 3.785411784) ** 2;
            my $dh = 2 * $kq * ($aq > $Q_TINY ? $aq : $Q_TINY);
            return ($sg * $kq * $aq ** 2, $dh);
        }
        if ($basis eq 'DB') {
            # A valve from the database: its published equivalent length of
            # its published reference pipe (bore and C), by Hazen-Williams in
            # the AS 2118.1 metric form -- the basis the data sheets state.
            # The loss is the valve's own, whatever pipe it is installed in,
            # and whichever friction formula the network is solved by.
            my $l = $e->{eql};
            my $hf = $aq > 0 ? $HWK_DEF * $l * $aq ** 1.85 / ($e->{ref_c} ** 1.85 * $e->{ref_bore} ** 4.87) : 0;
            my $dh = $aq > $Q_TINY ? 1.85 * $hf / $aq
                   : 1.85 * $HWK_DEF * $l * $Q_TINY ** 0.85 / ($e->{ref_c} ** 1.85 * $e->{ref_bore} ** 4.87);
            return ($sg * $hf, $dh);
        }
        if ($basis eq 'EQL' && $e->{host}) {
            # The equivalent length as a pipe of its own, built once from the
            # host pipe's data.  No fittings and no K: the length IS the
            # allowance for the valve.
            $e->{pseudo} //= { kind => 'PIPE', id => "$e->{id}.EQL", len => $e->{eql}, eqv => 0,
                               dia => $e->{host}{dia}, c => $e->{host}{c}, eps => $e->{host}{eps} };
            return elem_hf($e->{pseudo}, $q, $o);
        }
        return (0, 0);
    }
    # Every element kind must be handled above.  Returning a silent zero for an
    # unrecognised one is exactly how the ORIFICE_P fault went unnoticed, so an
    # unknown kind is now a hard error rather than an element with no effect.
    die "internal error: no hydraulics for element kind '$k'\n";
}

# ---------------------------------------------------------------------------
# Topology.
#
# Loops come from a spanning tree: every edge outside it is a chord, and each
# chord defines exactly one fundamental loop, guaranteeing P-N+1 independent
# loops with no chance of a missing or dependent one.  Discharges are kept out
# of the tree where an alternative exists, so each becomes a chord whose loop
# runs back through real pipework to a supply -- the path a hand-worked
# calculation sheet follows.
# ---------------------------------------------------------------------------
sub elem_rank {
    my $k = shift->{kind};
    return 2 if $k eq 'SUPPLY_STATIC' || $k eq 'SUPPLY_CURVE';
    return 3 if $k eq 'DISCHARGE';
    return 1;
}

# ---------------------------------------------------------------------------
# A central node of the pipework, found by double-sweep breadth-first search.
#
# The tree edge set fixes the length of every fundamental loop.  Grown from a
# node at one edge of the network -- which is what taking the first junction
# in the file usually gives -- the tree is deep, its loops are long, and long
# loops share many pipes, so each correction disturbs its neighbours and the
# iteration count climbs.  Grown from the middle, loops are short and overlap
# less.
#
# Sweep one: from any junction, the last node reached is an end of a longest
# shortest path.  Sweep two: from that end, the last node reached is the other
# end.  The node halfway along that path is central.  Two sweeps, linear time,
# and the answer does not change -- only how quickly it is reached.  Only
# pipework is walked: supplies and outlets meet at the reference node, and
# walking through it would make every supply adjacent to every outlet.
# ---------------------------------------------------------------------------
sub central_root {
    my ($net, $adj) = @_;
    my $iref = $net->{iref};
    my ($start) = grep { $_ != $iref && @{ $adj->[$_] } } 1 .. $#$adj;
    return $iref unless defined $start;

    # The farthest node is the LOWEST-NUMBERED node at the greatest distance,
    # not whichever happened to leave the queue last.  Both are "a farthest
    # node"; only this one matches the reference engine, and a different pick
    # gives a different centre and so a different tree.
    my $sweep = sub {
        my $s = shift;
        my %dist = ($s => 0);
        my %par;
        my @q = ($s);
        while (@q) {
            my $v = shift @q;
            for my $l (@{ $adj->[$v] }) {
                my ($w, $ei) = @$l;
                next if exists $dist{$w};
                next if elem_rank($net->{elems}[$ei]) != 1;
                $dist{$w} = $dist{$v} + 1;
                $par{$w} = $v;
                push @q, $w;
            }
        }
        my ($best, $far) = (-1, $s);
        for my $i (1 .. $#$adj) {
            next if $i == $iref || !exists $dist{$i};
            ($best, $far) = ($dist{$i}, $i) if $dist{$i} > $best;
        }
        return ($far, \%par, \%dist);
    };
    my ($u) = $sweep->($start);
    my ($v, $par, $dist) = $sweep->($u);
    # Walk half the path length back from the far end.
    for (1 .. int($dist->{$v} / 2)) {
        last unless defined $par->{$v};
        $v = $par->{$v};
    }
    return $v;
}

sub build_tree {
    my $net = shift;
    my $nn  = $#{ $net->{nodes} };
    my $ne  = $#{ $net->{elems} };
    my @adj = map { [] } 0 .. $nn;
    for my $ei (1 .. $ne) {
        my $e = $net->{elems}[$ei];
        # A pump shut on its check valve is REMOVED from the graph, not given
        # zero flow and left in it.  Left in, it would still be a tree edge or
        # a chord, and the solver would keep trying to drive flow through a
        # valve that is shut.
        next if $e->{closed};
        # unshift, not push: each node's neighbours are visited in REVERSE
        # element order.  That is what the reference C++ engine does -- its
        # adjacency is a linked list built by inserting at the head -- and on
        # a gridded network the order neighbours are visited in decides which
        # spanning tree is grown, which decides the loop set, which decides how
        # fast Hardy Cross converges.  With push, this engine grew a different
        # tree and needed twice the iterations on a 16x16 grid (1231 vs 600)
        # for the same answer.  On a tree network the pipework forces the
        # spanning tree, which is why the two always agreed there.
        unshift @{ $adj[ $e->{n1} ] }, [ $e->{n2}, $ei ];
        unshift @{ $adj[ $e->{n2} ] }, [ $e->{n1}, $ei ];
    }
    for my $i (1 .. $nn) {
        my $n = $net->{nodes}[$i];
        @{$n}{qw(visited pelem pnode depth)} = (0, 0, 0, 0);
    }
    $_->{in_tree} = 0 for @{ $net->{elems} }[1 .. $ne];

    my $root = central_root($net, \@adj);
    $net->{nodes}[$root]{visited} = 1;

    for my $phase (1 .. 3) {
        my @queue = $phase == 1 ? ($root)
                                : grep { $net->{nodes}[$_]{visited} } 1 .. $nn;
        while (@queue) {
            my $v = shift @queue;
            for my $link (@{ $adj[$v] }) {
                my ($w, $ei) = @$link;
                my $e = $net->{elems}[$ei];
                next if elem_rank($e) > $phase || $net->{nodes}[$w]{visited};
                $net->{nodes}[$w]{visited} = 1;
                $e->{in_tree} = 1;
                push @queue, $w;
            }
        }
    }

    fail("the network has no supply and no discharge - nothing anchors it to datum")
        unless $net->{nodes}[ $net->{iref} ]{visited};
    for my $i (1 .. $nn) {
        fail("node %s is not connected to the rest of the network",
             $net->{nodes}[$i]{id})
            unless $net->{nodes}[$i]{visited};
    }

    # Re-root at REF.  The tree PATH between any two nodes -- and therefore
    # every loop -- is unaffected by the choice of root; this only makes head
    # recovery start at datum.
    my @seen = (0) x ($nn + 1);
    my @queue = ($net->{iref});
    $seen[ $net->{iref} ] = 1;
    while (@queue) {
        my $v = shift @queue;
        for my $link (@{ $adj[$v] }) {
            my ($w, $ei) = @$link;
            next unless $net->{elems}[$ei]{in_tree} && !$seen[$w];
            $seen[$w] = 1;
            @{ $net->{nodes}[$w] }{qw(pelem pnode depth)} =
                ($ei, $v, $net->{nodes}[$v]{depth} + 1);
            push @queue, $w;
        }
    }
    return $net;
}

sub build_loops {
    my $net = shift;
    my $ne  = $#{ $net->{elems} };
    my @loops;
    for my $ei (1 .. $ne) {
        my $e = $net->{elems}[$ei];
        next if $e->{in_tree} || $e->{closed};
        my ($a, $b) = ($e->{n1}, $e->{n2});
        my (@pa, @pb);
        my $climb = sub {
            my ($v, $acc) = @_;
            my $n  = $net->{nodes}[$v];
            my $pe = $net->{elems}[ $n->{pelem} ];
            push @$acc, [ $n->{pelem}, ($pe->{n1} == $v ? 1 : -1) ];
            return $n->{pnode};
        };
        $a = $climb->($a, \@pa) while $net->{nodes}[$a]{depth} > $net->{nodes}[$b]{depth};
        $b = $climb->($b, \@pb) while $net->{nodes}[$b]{depth} > $net->{nodes}[$a]{depth};
        while ($a != $b) { $a = $climb->($a, \@pa); $b = $climb->($b, \@pb) }
        # chord n1->n2, up from n2 to the ancestor, back down to n1
        push @loops, [ [ $ei, 1 ], @pb, map { [ $_->[0], -$_->[1] ] } reverse @pa ];
    }
    $net->{loops} = \@loops;
    return $net;
}

# ---------------------------------------------------------------------------
# Initial flows: seed the chords, then back-solve the tree from the leaves
# inward, so continuity is exact to machine precision.  Hardy Cross only ever
# adds a circulating dQ around a closed loop, so once continuity holds here it
# holds for every later iterate -- it is never something the solution has to
# converge towards.
# ---------------------------------------------------------------------------
sub init_flows {
    my $net = shift;
    my $nn  = $#{ $net->{nodes} };
    my $ne  = $#{ $net->{elems} };

    my $qtot = 0;
    $qtot += $net->{nodes}[$_]{demand} for 1 .. $nn;
    for my $ei (1 .. $ne) {
        my $e = $net->{elems}[$ei];
        next unless $e->{kind} eq 'DISCHARGE';
        my $seed = $e->{k} * sqrt($e->{preq} > 0 ? $e->{preq} : 0);
        $qtot += $e->{qreq} > $seed ? $e->{qreq} : $seed;
    }
    my $q0 = 0.5 * $qtot;
    $q0 = 50 if $q0 < 50;
    $net->{opts}{q0} = $q0;

    for my $ei (1 .. $ne) {
        my $e = $net->{elems}[$ei];
        if ($e->{closed}) { $e->{q} = 0; next }
        next if $e->{in_tree};
        if ($e->{kind} eq 'DISCHARGE') {
            my $seed = $e->{qreq};
            $seed = $e->{k} * sqrt($e->{preq} > 50 ? $e->{preq} : 50) if $seed <= $Q_TINY;
            $seed = $q0 if $seed <= $Q_TINY;
            $e->{q} = $seed;
        } else {
            $e->{q} = $q0;
        }
    }

    my @acc = (0) x ($nn + 1);
    $acc[$_] = $net->{nodes}[$_]{demand} for 1 .. $nn;
    for my $ei (1 .. $ne) {
        my $e = $net->{elems}[$ei];
        next if $e->{in_tree} || $e->{closed};
        $acc[ $e->{n1} ] += $e->{q};
        $acc[ $e->{n2} ] -= $e->{q};
    }
    my $maxd = 0;
    for (1 .. $nn) { $maxd = $net->{nodes}[$_]{depth} if $net->{nodes}[$_]{depth} > $maxd }
    for my $d (reverse 1 .. $maxd) {
        for my $v (1 .. $nn) {
            my $n = $net->{nodes}[$v];
            next unless $n->{depth} == $d && $n->{pelem};
            my $e = $net->{elems}[ $n->{pelem} ];
            my $s = $acc[$v];
            $e->{q} = $e->{n2} == $v ? $s : -$s;
            $acc[ $n->{pnode} ] += $s;
            $acc[$v] = 0;
        }
    }
    return $net;
}

sub continuity_error {
    my $net = shift;
    my $nn  = $#{ $net->{nodes} };
    my @acc = (0) x ($nn + 1);
    $acc[$_] = $net->{nodes}[$_]{demand} for 1 .. $nn;
    for my $ei (1 .. $#{ $net->{elems} }) {
        my $e = $net->{elems}[$ei];
        next if $e->{closed};
        $acc[ $e->{n1} ] += $e->{q};
        $acc[ $e->{n2} ] -= $e->{q};
    }
    $acc[ $net->{iref} ] = 0;
    my $m = 0;
    for (1 .. $nn) { $m = abs $acc[$_] if abs $acc[$_] > $m }
    return $m;
}

sub recover_heads {
    # Walking the spanning tree IS the calculation sheet.
    my $net = shift;
    my $nn  = $#{ $net->{nodes} };
    $net->{nodes}[$_]{h} = 0 for 1 .. $nn;
    my $maxd = 0;
    for (1 .. $nn) { $maxd = $net->{nodes}[$_]{depth} if $net->{nodes}[$_]{depth} > $maxd }
    for my $d (1 .. $maxd) {
        for my $v (1 .. $nn) {
            my $n = $net->{nodes}[$v];
            next unless $n->{depth} == $d && $n->{pelem};
            my $e = $net->{elems}[ $n->{pelem} ];
            my ($hf) = elem_hf($e, $e->{q}, $net->{opts});
            my $ph = $net->{nodes}[ $n->{pnode} ]{h};
            $n->{h} = $e->{n1} == $n->{pnode} ? $ph - $hf : $ph + $hf;
        }
    }
    return $net;
}

# ---------------------------------------------------------------------------
#   dQ = -SUM(s*hf) / SUM(|dhf/dq|)
# applied as q += s*dQ around each loop, one loop at a time, which is Cross's
# original sequential form.
# ---------------------------------------------------------------------------
sub solve_network {
    my ($net, %a) = @_;
    my $maxiter = $a{maxiter} // 50000;
    my $tolflow = $a{tol_flow} // 0.05;
    my $tolloop = $a{tol_loop} // 0.01;
    my $q0      = $net->{opts}{q0} // 100;
    my $elems   = $net->{elems};
    my $o       = $net->{opts};

    $net->{converged} = 0;
    $net->{history}   = [];
    $net->{degenerate} = [];
    my $iter = 0;

    while ($iter < $maxiter) {
        $iter++;
        my ($maxdq, $maxres) = (0, 0);
        my %degen;
        for my $li (0 .. $#{ $net->{loops} }) {
            my $lp = $net->{loops}[$li];
            my ($sumh, $sumd, $qscale) = (0, 0, 0);
            for my $step (@$lp) {
                my $e = $elems->[ $step->[0] ];
                my ($hf, $dh) = elem_hf($e, $e->{q}, $o);
                $sumh += $step->[1] * $hf;
                $sumd += $dh;
                $qscale = abs $e->{q} if abs $e->{q} > $qscale;
            }
            # A loop whose every element has no flow derivative (static
            # supplies and fixed drops only) cannot be corrected at all: the
            # Cross denominator is zero.  It is left alone, as before, but
            # recorded when it is out of balance, so that a stall is reported
            # as what it is rather than as slow convergence.
            $degen{$li} = 1 if $sumd < 1e-10 && abs($sumh) > $tolloop;
            my $dq = $sumd < 1e-10 ? 0 : -$sumh / $sumd;
            # Trust region: stops the first sweeps launching the iterate into
            # nonsense when the seed is far off.  Inactive near the solution,
            # so the converged answer is unaffected.
            my $lim = 2 * ($qscale + $q0);
            $dq = $dq > 0 ? $lim : -$lim if abs($dq) > $lim;
            $maxres = abs $sumh if abs $sumh > $maxres;
            $maxdq  = abs $dq   if abs $dq   > $maxdq;
            $elems->[ $_->[0] ]{q} += $_->[1] * $dq for @$lp;
        }
        push @{ $net->{history} }, [ $iter, $maxdq, $maxres ];
        $net->{degenerate} = [ sort { $a <=> $b } keys %degen ];

        # A solver that runs away must say so, not keep iterating until the
        # numbers become infinities and the report fills with plausible rubbish.
        for my $ei (1 .. $#$elems) {
            my $q = $elems->[$ei]{q};
            if ($q != $q || abs($q) > 1e15) {
                $net->{iters} = $iter;
                $net->{nonconv} = 'diverged';
                return 0;
            }
        }
        if ($maxdq <= $tolflow && $maxres <= $tolloop) {
            # The residuals above were measured DURING the sweep, each before
            # its own loop's correction -- and every later correction in the
            # same sweep disturbs loops already corrected.  On a large grid
            # the true closure at exit came out at 0.034 kPa against a stated
            # tolerance of 0.01, found by the stress test.  So before
            # declaring convergence, measure every loop against the flows as
            # they now stand, and carry on if any is still out.
            my $true = 0;
            for my $lp (@{ $net->{loops} }) {
                my $sumh = 0;
                for my $step (@$lp) {
                    my $e = $elems->[ $step->[0] ];
                    my ($hf) = elem_hf($e, $e->{q}, $o);
                    $sumh += $step->[1] * $hf;
                }
                $true = abs $sumh if abs $sumh > $true;
            }
            if ($true <= $tolloop) {
                $net->{converged} = 1;
                last;
            }
        }
    }
    $net->{iters} = $iter;
    $net->{nonconv} = $net->{converged} ? undef : iteration_diagnosis($net->{history});
    recover_heads($net);
    return $net->{converged};
}

#------------------------------------------------------------------------------
# iteration_diagnosis -- why an iteration that used up MAXITER did not finish,
# read from its history of [iter, max |dQ|, max |residual|]:
#
#   diverging    the corrections over the last tenth are larger than over the
#                tenth before it, and growing
#   oscillating  the largest correction changes direction of travel -- rises
#                and falls -- on most sweeps of the last tenth, without the
#                level coming down
#   stalled      the corrections have stopped falling: over the last tenth they
#                came down by less than 1 %
#   slow         still falling, but MAXITER was reached first
#
# This is a diagnosis for the report and the JSON only.  It never changes a
# result and never turns a failure into a pass; "slow" is as unconverged as
# the rest.
#------------------------------------------------------------------------------
sub iteration_diagnosis {
    my $h = shift;
    return 'no_iterations' unless $h && @$h;
    my $n = @$h;
    return 'slow' if $n < 20;
    my $w = int($n / 10);
    my @last = map { $_->[1] } @$h[ $n - $w .. $n - 1 ];
    my @prev = map { $_->[1] } @$h[ $n - 2 * $w .. $n - $w - 1 ];
    my $mean = sub { my $s = 0; $s += $_ for @_; $s / @_ };
    my ($ml, $mp) = ($mean->(@last), $mean->(@prev));
    return 'diverging' if $ml > 1.5 * $mp && $last[-1] > $last[0];
    my $turns = 0;
    for my $i (1 .. $#last - 1) {
        my ($d1, $d2) = ($last[$i] - $last[ $i - 1 ], $last[ $i + 1 ] - $last[$i]);
        $turns++ if $d1 * $d2 < 0;
    }
    return 'oscillating' if $#last > 2 && $turns > 0.5 * ($#last - 1) && $ml >= 0.9 * $mp;
    return 'stalled' if $ml >= 0.99 * $mp;
    return 'slow';
}

# ---------------------------------------------------------------------------
# The outer loop: size any ORIFICE_P against its converged duty, then re-solve.
# ---------------------------------------------------------------------------
sub size_orifices {
    my $net = shift;
    my $changed = 0;
    for my $ei (1 .. $#{ $net->{elems} }) {
        my $e = $net->{elems}[$ei];
        next unless $e->{kind} eq 'ORIFICE_REQUIRED';
        my $q    = abs $e->{q};
        my $bore = orifice_size($q, $e->{dp}, $e->{pipedia}, $e->{cd});
        # What the plate was sized for, kept so the final plate can be checked
        # against it (HardyCross::Validate): the duty, the exact bore before
        # rounding, and whether the bisection ran into either end of its
        # bracket.  orifice_size returns the end of the bracket when the
        # target cannot be reached -- a drop smaller than a plate of nearly
        # the full pipe bore gives, or larger than one of 0.1 % of it -- and
        # that bore used to be accepted as if it met the duty.
        my ($lo, $hi) = (0.001 * $e->{pipedia}, 0.9995 * $e->{pipedia});
        $e->{dp_target}  = $e->{dp};
        $e->{q_sized}    = $q;
        $e->{bore_exact} = $bore;
        $e->{size_clamp} = $q <= $Q_TINY                                          ? 'NO_FLOW'
                         : orifice_dp($q, $hi, $e->{pipedia}, $e->{cd}) > $e->{dp} ? 'BORE_MAX'
                         : orifice_dp($q, $lo, $e->{pipedia}, $e->{cd}) < $e->{dp} ? 'BORE_MIN'
                         : undef;
        my $step = $net->{opts}{orif_step} // 0.5;
        if ($step > 0) {
            my $r = int($bore / $step + 0.5) * $step;
            # Rounding to the nearest step must still give a plate: rounding
            # 0.9995 D up made a bore EQUAL to the pipe's (50.0 mm in a 50.0
            # mm pipe on a test model), and a tiny bore rounds to nothing.
            # The step below the pipe bore, or one step, is taken instead and
            # the adjustment kept for the report; a plate that cannot meet
            # its duty is still refused by HardyCross::Validate.
            if ($r >= $e->{pipedia} - 1e-9) {
                $r = (POSIX::ceil($e->{pipedia} / $step) - 1) * $step;
                $e->{bore_rounding} = 'DOWN_BELOW_PIPE_BORE';
            } elsif ($r <= 0) {
                $r = $step;
                $e->{bore_rounding} = 'UP_TO_ONE_STEP';
            }
            $bore = $r;
        }
        $e->{kind} = 'ORIFICE';
        $e->{bore} = $bore;
        $changed = 1;
    }
    return $changed;
}

# ---------------------------------------------------------------------------
# Pump check valves.
#
# A pump cannot pass reverse flow: it has a check valve.  A converged solution
# that runs one backwards is arithmetically consistent and physically
# impossible, so the pump is CLOSED -- removed from the graph -- and the network
# solved again without it.  This was missing entirely, and it is why every
# validation case containing a pump failed: the engine settled on a pump
# running backwards at over a thousand L/min and reported it as an answer.
#
# A closed pump is also re-checked: if the head it would have to lift has
# fallen below its shut-off head, it could deliver again, so it is reopened.
# That is discrete status switching, which plain Hardy Cross has no mechanism
# for, so it lives in the outer loop alongside orifice sizing.
#
# The flip count is capped.  A pump sitting exactly at the boundary could
# otherwise open and close on alternate passes forever.
# ---------------------------------------------------------------------------
my $MAX_FLIP = 8;

sub pump_status {
    my $net = shift;
    my $changed = 0;
    my @closed_now;

    for my $ei (1 .. $#{ $net->{elems} }) {
        my $e = $net->{elems}[$ei];
        next unless $e->{kind} eq 'PUMP';
        # A pump past the flip limit is no longer switched.  It is MARKED, so
        # that whatever state it is left in is checked by
        # HardyCross::Validate rather than taken as settled: the limit stops
        # the outer loop cycling, it does not make the state right.
        if (($e->{nflips} // 0) > $MAX_FLIP) {
            $e->{flip_limit} = 1 unless $e->{isolating};
            next;
        }

        if (!$e->{closed}) {
            if ($e->{q} < -$Q_TINY) {
                $e->{closed} = 1;
                $e->{q} = 0;
                $e->{nflips}++;
                $changed = 1;
                push @closed_now, $e;
            }
        } else {
            my $shut = curve_eval($e->{curve}, 0);
            my $lift = $net->{nodes}[ $e->{n2} ]{h} - $net->{nodes}[ $e->{n1} ]{h};
            if ($lift < $shut - $Q_TINY) {
                $e->{closed} = 0;
                $e->{nflips}++;
                $changed = 1;
            }
        }
    }
    return 0 unless $changed;

    # The graph has changed, so the tree, the loop set and the seed flows must
    # all be rebuilt.  If closing a pump would isolate part of the network the
    # closure is reverted: the network cannot be solved without it.  The
    # pump is then left OPEN, running backwards, which is physically
    # impossible -- so it is marked isolating, and HardyCross::Validate
    # rejects the calculation.  It is NOT a solver state to settle into.
    #
    # Two faults were corrected here (10 November 2026).  The revert reopened
    # EVERY closed pump, including ones closed correctly on an earlier pass;
    # it now reopens only those closed on this one.  And it returned "no
    # change" after rebuilding the tree but not the loops or the flows: the
    # closed pump's flow had been set to zero, so the network handed back
    # broke continuity at both ends of the pump -- by 200 L/min on a test
    # model -- and the outer loop took it as settled.  The network is now
    # rebuilt in full and solved again.
    my $isolated = !eval { build_tree($net); 1 };
    if ($isolated) {
        for my $e (@closed_now) {
            $e->{closed} = 0;
            $e->{isolating} = 1;
            $e->{nflips} = $MAX_FLIP + 1;     # stop reconsidering it
        }
        $net->{warnings} ||= [];
        push @{ $net->{warnings} },
            'closing a pump check valve would isolate part of the network, '
          . 'so the pump has been left open; the reverse flow reported '
          . 'through it is not physically possible';
        build_tree($net);
    }
    build_loops($net);
    init_flows($net);
    return 1;
}

#------------------------------------------------------------------------------
# ratio_valves -- set each pressure ratio valve's drop from its inlet pressure.
#
# A pressure ratio valve holds its outlet at its inlet pressure divided by its
# ratio: a 3:1 valve with 1500 kPa upstream gives 500 kPa downstream, so it
# drops 1500 x (1 - 1/3) = 1000 kPa.  The drop depends on a PRESSURE, which the
# loop balance does not know until it has converged, so it is set here from
# the converged inlet pressure and the network solved again, until the drops
# stop changing.
#
# THE BAND.  The manufacturer's data says the valve "will hold the downstream
# pressure to within +/- 5% of the inlet pressure": at 1500 kPa in, a 3:1
# valve gives anywhere from 500 - 75 = 425 to 500 + 75 = 575 kPa.  The design
# must hold wherever in that band the valve sits, so the calculation uses the
# BOTTOM of the band (decided 28 October 2026):
#
#     outlet = inlet x (1/ratio - band)      drop = inlet - outlet
#
# and every outlet downstream is then checked against the least the valve
# can be relied on to give.  The top of the band matters for pressure ratings
# downstream: a solve with opts{pra_side} = 'HIGH' sets every valve to
# inlet x (1/ratio + band), and the report states the highest pressures it
# gives.  The band is each valve's own (band, a fraction; 5 % unless the model
# says otherwise); a band of 0 is the nominal ratio exactly.
#
# Returns true if any drop moved by more than the loop tolerance.
#------------------------------------------------------------------------------
sub ratio_valves {
    my $net = shift;
    my $tol = $net->{opts}{tol_loop} // 0.01;
    my $side = ($net->{opts}{pra_side} // 'LOW') eq 'HIGH' ? 1 : -1;
    my $changed = 0;
    for my $e (grep { $_->{kind} eq 'RATIO' } @{ $net->{elems} }[1 .. $#{ $net->{elems} }]) {
        my $n   = $net->{nodes}[ $e->{n1} ];
        my $pin = $n->{h} - $GAMMA_W * $n->{z};
        my $out = $pin * (1 / $e->{ratio} + $side * ($e->{band} // 0.05));
        my $dp  = $pin > 0 ? $pin - ($out > 0 ? $out : 0) : 0;
        if (abs($dp - $e->{dp}) > $tol) {
            $e->{dp} = $dp;
            $changed = 1;
        }
        $e->{pin} = $pin;
    }
    return $changed;
}

# ratio_warnings -- what a solve must say about its pressure ratio valves.
sub ratio_warnings {
    my ($net, $settled) = @_;
    my @w;
    for my $e (grep { $_->{kind} eq 'RATIO' } @{ $net->{elems} }[1 .. $#{ $net->{elems} }]) {
        push @w, "pressure ratio valve $e->{id}: flow runs backwards through it, which a ratio "
               . 'valve does not pass - the model needs another route for that water'
            if $e->{q} < -$Q_TINY;
        push @w, sprintf('pressure ratio valve %s: inlet pressure %.1f kPa is below its minimum '
                       . 'inlet pressure of %.1f kPa; it will not hold its ratio', $e->{id},
                         $e->{pin} // 0, $e->{mininlet})
            if defined $e->{mininlet} && ($e->{pin} // 0) < $e->{mininlet};
    }
    push @w, 'the pressure ratio valve drops had not settled when the solve stopped; '
           . 'the results must be checked' unless $settled;
    return @w;
}

#------------------------------------------------------------------------------
# velocity_pressures -- set each sprinkler's velocity pressure from the flows.
#
# OPTION VELOCITY_PRESSURE ON (default OFF).  AS 2118.1:2017 Clause 14.15
# leaves the inclusion of velocity pressures to the designer and, where they
# are included, requires them for both range pipes and distribution mains.
# It gives no method, so PHCP's convention is set out here (agreed with the
# maintainer 4 November 2026):
#
#   - SPRINKLER outlets only.  Hydrants, hose reels and fixed flows stay on
#     total pressure: the clause is in the sprinkler Standard.
#   - At a flowing sprinkler, q = K sqrt(Pn) with Pn = Pt - Pv, and
#     Pv = rho v^2 / 2 = 0.5 v^2 kPa (v in m/s, water at 1000 kg/m3) -- the
#     figure the pipe schedule has always printed.
#   - v is the velocity in the PIPE carrying flow INTO the node.  Where two
#     or more pipes feed it (a grid or a loop), the one bringing the most
#     water.  A node fed only through a device has no pipe velocity, Pv 0.
#   - An END outlet -- one whose node has no pipe or device carrying water on
#     beyond it, the end of a range, a drop or an armover -- discharges on
#     total pressure.  So in practice only in-line heads change.
#   - It applies across all the pipework at once, range pipes and
#     distribution mains alike: PHCP does not tag what a pipe is for, and the
#     clause does not allow one without the other.  There is no Pn at a branch
#     take-off: every branch is solved in full, in total pressure.
#
# Pv depends on a solved flow, so it is set here, on a converged answer, and
# the network solved again until no Pv moves by more than the loop tolerance
# -- the same outer loop as the ratio valves.  Flow directions are re-read on
# every pass, so a head that becomes an end outlet goes back to total pressure.
#
# Each sprinkler is left with pv (kPa, 0 for an end outlet), pv_pipe (the id
# of the pipe whose velocity set it, or undef) and pv_end (true for an end
# outlet).  Returns true if any pv moved by more than the loop tolerance.
#------------------------------------------------------------------------------
sub velocity_pressures {
    my $net = shift;
    return 0 unless $net->{opts}{vel_press};
    my $tol   = $net->{opts}{tol_loop} // 0.01;
    my $elems = $net->{elems};

    # One pass over the elements: at every node, the pipe bringing the most
    # water in, and whether anything carries water out.  Outlets themselves
    # (edges to REF) are not pipework and are skipped.
    my (%feed, %fq, %out);
    for my $ei (1 .. $#$elems) {
        my $e = $elems->[$ei];
        next if $e->{closed} || $e->{kind} eq 'DISCHARGE';
        next unless abs($e->{q}) > $Q_TINY;
        my ($to, $from) = $e->{q} > 0 ? ($e->{n2}, $e->{n1}) : ($e->{n1}, $e->{n2});
        $out{$from} = 1;
        if ($e->{kind} eq 'PIPE' && abs($e->{q}) > ($fq{$to} // 0)) {
            ($feed{$to}, $fq{$to}) = ($e, abs $e->{q});
        }
    }

    my $changed = 0;
    for my $e (@$elems[1 .. $#$elems]) {
        next unless $e->{kind} eq 'DISCHARGE' && uc($e->{otype} // '') eq 'SPRINKLER';
        my $v  = $e->{n1};
        my $f  = $out{$v} ? $feed{$v} : undef;
        my $pv = $f ? 0.5 * pipe_velocity($fq{$v}, $f->{dia}) ** 2 : 0;
        $changed = 1 if abs($pv - ($e->{pv} // 0)) > $tol;
        $e->{pv}      = $pv;
        $e->{pv_pipe} = $f ? $f->{id} : undef;
        $e->{pv_end}  = !$out{$v};
    }
    return $changed;
}

# outlet_pressure -- the pressure an outlet discharges on, kPa: its gauge
# pressure (total pressure, Pt), less its velocity pressure when one is
# applied (OPTION VELOCITY_PRESSURE ON), so q = K sqrt(outlet_pressure).
# Works for a fixed-flow record too (no pv).  Everything that checks an outlet
# against its minimum pressure uses this, so the report, the margins, the
# demand point and the JSON cannot disagree on the basis.
sub outlet_pressure {
    my ($net, $e) = @_;
    my $p = $net->{nodes}[ $e->{n1} ]{h} - $GAMMA_W * $e->{z};
    $p -= $e->{pv} if $e->{pv};
    return $p;
}

# The most outer passes a solve may take before it is declared unsettled.
# A package variable so a test can lower it and check that an unsettled solve
# is refused; it is not a user option.
our $MAX_OUTER = 60;

# link_devices -- give each device that needs its pipe's data a reference to
# that pipe: a dry pipe valve whose loss is an equivalent length (DPV ... EQL)
# takes the bore and C of the pipe it sits in.  Done once, before the solve.
sub link_devices {
    my $net = shift;
    my %pipe = map { $_->{id} => $_ } grep { $_->{kind} eq 'PIPE' } @{ $net->{elems} }[1 .. $#{ $net->{elems} }];
    for my $e (grep { $_->{kind} eq 'DPV' } @{ $net->{elems} }[1 .. $#{ $net->{elems} }]) {
        next unless defined $e->{host_id};
        $e->{host} = $pipe{ $e->{host_id} };
        delete $e->{pseudo};
    }
}

sub solve_model {
    my $net = shift;
    # A network solved again is validated again (HardyCross::Validate::assess).
    delete $net->{assessment};
    link_devices($net);
    build_tree($net);
    build_loops($net);
    init_flows($net);
    my $ok = solve_network($net,
        maxiter  => $net->{opts}{maxiter},
        tol_flow => $net->{opts}{tol_flow},
        tol_loop => $net->{opts}{tol_loop});
    # Outer loop: size orifice plates, settle pump check valves and set
    # pressure ratio valve drops, re-solving after any of them changes
    # anything.  Each is decided on a converged answer, so none can live
    # inside the Hardy Cross iteration.  Bounded: plates and pumps settle in a
    # pass or two and ratio valves in a few; an unbounded loop would hang on a
    # duty that cannot be met.
    #
    # Two rules, added 10 November 2026, so that the result returned is one
    # whose every device state has been decided on a converged answer:
    #
    #   - No device is adjusted on an UNCONVERGED inner solve.  A plate sized,
    #     a pump switched or a ratio set from flows that do not balance is
    #     sized, switched or set from nonsense.  The outer loop stops there
    #     and the solve is reported as not converged.
    #   - The solve succeeds only if the outer loop SETTLED: a pass in which
    #     nothing changed.  Before, a solve that used up its outer passes
    #     still returned the last inner result as converged, with only a
    #     warning for ratio valves and velocity pressures and nothing at all
    #     for plates and pumps.
    #
    # Both are recorded on the network for the report, the JSON and
    # HardyCross::Validate: hc_converged (the last Hardy Cross solve
    # converged), outer_settled, outer_passes, and outer_stop (why the outer
    # loop ended: settled, inner_not_converged or pass_limit).
    my ($settled, $passes, $stop) = (0, 0, 'pass_limit');
    for (1 .. $MAX_OUTER) {
        unless ($ok) { $stop = 'inner_not_converged'; last }
        $passes++;
        my $sized  = size_orifices($net);
        my $pumped = pump_status($net);
        my $ratio  = ratio_valves($net);
        my $vp     = velocity_pressures($net);
        unless ($sized || $pumped || $ratio || $vp) { ($settled, $stop) = (1, 'settled'); last }
        $ok = solve_network($net,
            maxiter  => $net->{opts}{maxiter},
            tol_flow => $net->{opts}{tol_flow},
            tol_loop => $net->{opts}{tol_loop});
    }
    @{$net}{qw(hc_converged outer_settled outer_passes outer_stop)} = ($ok ? 1 : 0, $settled, $passes, $stop);
    push @{ $net->{warnings} }, ratio_warnings($net, $settled)
        if grep { $_->{kind} eq 'RATIO' } @{ $net->{elems} }[1 .. $#{ $net->{elems} }];
    push @{ $net->{warnings} }, 'the sprinkler velocity pressures had not settled when the solve '
                              . 'stopped; the results must be checked'
        if $net->{opts}{vel_press} && !$settled;
    push @{ $net->{warnings} }, sprintf('the device states (orifice plates, pump check valves, ratio valves, '
                              . 'velocity pressures) had not settled after %d outer passes; the solve is '
                              . 'not converged', $passes)
        if $ok && !$settled;
    return $ok && $settled ? 1 : 0;
}

1;
