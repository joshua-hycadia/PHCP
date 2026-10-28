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
our $VERSION = '1.0.0';

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
# Curves for supplies, pumps and backflow preventer losses.
#
# Two points fit P = a0 + a2 Q^2 exactly; three or more are least squares
# quadratic.  Outside the fitted window the curve continues LINEARLY at the end
# slope, so P and P' stay finite and monotone everywhere -- which is what keeps
# the loop correction well posed when an iterate overshoots past runout.
# ---------------------------------------------------------------------------
sub solve3 {
    my ($m, $b) = @_;
    my @a = map { [@$_] } @$m;
    my @v = @$b;
    for my $k (0 .. 2) {
        my $piv = $k;
        for my $i ($k + 1 .. 2) {
            $piv = $i if abs($a[$i][$k]) > abs($a[$piv][$k]);
        }
        return undef if abs($a[$piv][$k]) < 1e-30;
        if ($piv != $k) {
            @a[$k, $piv] = @a[$piv, $k];
            @v[$k, $piv] = @v[$piv, $k];
        }
        for my $i ($k + 1 .. 2) {
            my $f = $a[$i][$k] / $a[$k][$k];
            $a[$i][$_] -= $f * $a[$k][$_] for $k .. 2;
            $v[$i] -= $f * $v[$k];
        }
    }
    my @x = (0, 0, 0);
    for my $i (reverse 0 .. 2) {
        my $s = $v[$i];
        $s -= $a[$i][$_] * $x[$_] for $i + 1 .. 2;
        $x[$i] = $s / $a[$i][$i];
    }
    return \@x;
}

sub fit_curve {
    my ($c, $rising) = @_;
    my @q = @{ $c->{q} };
    my @p = @{ $c->{p} };
    fail("curve needs at least 2 points") if @q < 2;

    if (@q == 2) {
        my $det = $q[1] ** 2 - $q[0] ** 2;
        fail("curve points have identical flow") if abs($det) < $D_TINY;
        $c->{a2} = ($p[1] - $p[0]) / $det;
        $c->{a1} = 0;
        $c->{a0} = $p[0] - $c->{a2} * $q[0] ** 2;
    } else {
        my ($s1, $s2, $s3, $s4, $t0, $t1, $t2) = (0) x 7;
        for my $i (0 .. $#q) {
            my ($qq, $pp) = ($q[$i], $p[$i]);
            $s1 += $qq; $s2 += $qq ** 2; $s3 += $qq ** 3; $s4 += $qq ** 4;
            $t0 += $pp; $t1 += $pp * $qq; $t2 += $pp * $qq ** 2;
        }
        my $sol = solve3([[scalar @q, $s1, $s2], [$s1, $s2, $s3], [$s2, $s3, $s4]],
                         [$t0, $t1, $t2]);
        fail("curve fit singular - check for duplicate flows") unless $sol;
        ($c->{a0}, $c->{a1}, $c->{a2}) = @$sol;
    }

    my ($qlo, $qhi) = (0, $q[0]);
    for (@q) { $qlo = $_ if $_ < $qlo; $qhi = $_ if $_ > $qhi }
    $qhi = $qlo + 1 if $qhi <= $qlo;
    $c->{qlo} = $qlo;
    $c->{qhi} = $qhi;

    my $at    = sub { $c->{a0} + $c->{a1} * $_[0] + $c->{a2} * $_[0] ** 2 };
    my $slope = sub { $c->{a1} + 2 * $c->{a2} * $_[0] };
    $c->{plo} = $at->($qlo);
    $c->{phi} = $at->($qhi);
    $c->{slo} = $slope->($qlo);
    $c->{shi} = $slope->($qhi);

    # Guard the extrapolation slopes so the Jacobian cannot degenerate: a zero
    # slope puts a zero in the denominator of the loop correction the first
    # time an iterate wanders outside the fitted range.
    my $span  = ($qhi - $qlo) > $D_TINY ? ($qhi - $qlo) : $D_TINY;
    my $chord = 2 * ($c->{phi} - $c->{plo}) / $span;
    if ($rising) {
        $c->{slo} = ($chord > $D_TINY ? $chord : $D_TINY) if $c->{slo} < $D_TINY;
        $c->{shi} = ($chord > $D_TINY ? $chord : $D_TINY) if $c->{shi} < $D_TINY;
    } else {
        $c->{slo} = ($chord < -$D_TINY ? $chord : -$D_TINY) if $c->{slo} > -$D_TINY;
        $c->{shi} = ($chord < -$D_TINY ? $chord : -$D_TINY) if $c->{shi} > -$D_TINY;
    }
    return $c;
}

sub curve_eval {
    my ($c, $q) = @_;
    return $c->{plo} + $c->{slo} * ($q - $c->{qlo}) if $q < $c->{qlo};
    return $c->{phi} + $c->{shi} * ($q - $c->{qhi}) if $q > $c->{qhi};
    return $c->{a0} + $c->{a1} * $q + $c->{a2} * $q ** 2;
}

sub curve_slope {
    my ($c, $q) = @_;
    return $c->{slo} if $q < $c->{qlo};
    return $c->{shi} if $q > $c->{qhi};
    return $c->{a1} + 2 * $c->{a2} * $q;
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
    #   dP = 633.28 (Q^2/d^4)(1-b^4) R,  b = d/D,  Cd = 0.596
    #   R  = [s - Cd b^2]/[s + Cd b^2],  s = sqrt(1 - b^4(1-Cd^2))
    # R is the ISO 5167 permanent pressure loss ratio, so dP is the NET loss
    # across the plate rather than the differential across the tappings --
    # which is the quantity a network calculation needs.
    my ($aq, $d, $bigd, $cd) = @_;
    return 0 if $d <= $D_TINY || $aq <= 0;
    my $beta = $bigd > $D_TINY ? ($d / $bigd < 0.99999 ? $d / $bigd : 0.99999) : 0;
    my $b4   = $beta ** 4;
    my $s    = sqrt(1 - $b4 * (1 - $cd ** 2) > 1e-12
                    ? 1 - $b4 * (1 - $cd ** 2) : 1e-12);
    my $cb2  = $cd * $beta ** 2;
    my $r    = ($s - $cb2) / ($s + $cb2);
    $r = 0 if $r < 0;
    return 633.28 * $aq ** 2 / $d ** 4 * (1 - $b4) * $r;
}

sub orifice_size {
    # dP falls monotonically with bore, so bisection is unconditionally safe.
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
        # The engine nevertheless applies K under BOTH formulas, because
        # EPANET does, and matching EPANET is the only way the validation
        # suite means anything.  The place to enforce the engineering rule is
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
        return ($sg * ($aq / $kf) ** 2 + $GAMMA_W * $e->{z}, $dh);
    }
    # An ORIFICE_P whose bore has not been sized yet behaves as a fixed drop
    # of the pressure it is required to produce.  It MUST be listed here: it
    # used to fall through to the default at the bottom of this routine and
    # contribute ZERO, so the first solve ran as if the plate were absent, the
    # plate was then sized against that wrong duty, and the answer came out one
    # rounding step off -- 34.0 mm where the correct duty gives 33.5.  EPANET
    # validation could not catch it, because EPANET has no concept of sizing a
    # plate; only the direct comparison against the C++ engine did.
    if ($k eq 'FIXED_DROP' || $k eq 'ORIFICE_REQUIRED') {
        # Contributes to the loop sum but not to the denominator.
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
    my $iter = 0;

    while ($iter < $maxiter) {
        $iter++;
        my ($maxdq, $maxres) = (0, 0);
        for my $lp (@{ $net->{loops} }) {
            my ($sumh, $sumd, $qscale) = (0, 0, 0);
            for my $step (@$lp) {
                my $e = $elems->[ $step->[0] ];
                my ($hf, $dh) = elem_hf($e, $e->{q}, $o);
                $sumh += $step->[1] * $hf;
                $sumd += $dh;
                $qscale = abs $e->{q} if abs $e->{q} > $qscale;
            }
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

        # A solver that runs away must say so, not keep iterating until the
        # numbers become infinities and the report fills with plausible rubbish.
        for my $ei (1 .. $#$elems) {
            my $q = $elems->[$ei]{q};
            if ($q != $q || abs($q) > 1e15) {
                $net->{iters} = $iter;
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
    recover_heads($net);
    return $net->{converged};
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
        my $step = $net->{opts}{orif_step} // 0.5;
        $bore = int($bore / $step + 0.5) * $step if $step > 0;
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

    for my $ei (1 .. $#{ $net->{elems} }) {
        my $e = $net->{elems}[$ei];
        next unless $e->{kind} eq 'PUMP';
        next if ($e->{nflips} // 0) > $MAX_FLIP;

        if (!$e->{closed}) {
            if ($e->{q} < -$Q_TINY) {
                $e->{closed} = 1;
                $e->{q} = 0;
                $e->{nflips}++;
                $changed = 1;
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
    # closure is reverted rather than left to fail later: an unreachable node
    # is a modelling problem to report, not a solver state to settle into.
    my $isolated = !eval { build_tree($net); 1 };
    if ($isolated) {
        for my $ei (1 .. $#{ $net->{elems} }) {
            my $e = $net->{elems}[$ei];
            next unless $e->{kind} eq 'PUMP' && $e->{closed};
            $e->{closed} = 0;
            $e->{nflips} = $MAX_FLIP + 1;     # stop reconsidering it
        }
        $net->{warnings} ||= [];
        push @{ $net->{warnings} },
            'closing a pump check valve would isolate part of the network, '
          . 'so the pump has been left open; the reverse flow reported '
          . 'through it is not physically possible';
        build_tree($net);
        return 0;
    }
    build_loops($net);
    init_flows($net);
    return 1;
}

sub solve_model {
    my $net = shift;
    build_tree($net);
    build_loops($net);
    init_flows($net);
    my $ok = solve_network($net,
        maxiter  => $net->{opts}{maxiter},
        tol_flow => $net->{opts}{tol_flow},
        tol_loop => $net->{opts}{tol_loop});
    # Outer loop: size orifice plates and settle pump check valves, re-solving
    # after either changes anything.  Both are discrete decisions taken on a
    # converged answer, so they cannot live inside the Hardy Cross iteration.
    # Bounded: each settles in a pass or two, and an unbounded loop would hang
    # on a duty that cannot be met.
    for (1 .. 25) {
        my $sized  = size_orifices($net);
        my $pumped = pump_status($net);
        last unless $sized || $pumped;
        $ok = solve_network($net,
            maxiter  => $net->{opts}{maxiter},
            tol_flow => $net->{opts}{tol_flow},
            tol_loop => $net->{opts}{tol_loop});
    }
    return $ok;
}

1;
