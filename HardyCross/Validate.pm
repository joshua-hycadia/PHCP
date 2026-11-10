#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# HardyCross/Validate.pm -- an independent check of every completed solve.
#
# WHY THIS EXISTS
# The Hardy Cross iteration stops when its corrections and its loop sums are
# small.  That says the ITERATION has finished.  It does not say that the
# network handed back balances, that every device in it is in a state it can
# physically be in, or that the design meets its requirements -- and PHCP has
# reported converged answers that failed each of those:
#
#   - a pump left open after its check valve was reverted, its flow zeroed,
#     continuity out by 200 L/min at both its ends, reported converged
#   - a fixed-flow demand fed only by water running backwards INTO a
#     sprinkler, the sprinkler's flow printed as positive
#   - a water supply taking in water, unremarked
#   - a supply curve whose pressure RISES with flow, accepted
#
# So nothing here trusts the solver.  Every check is worked again from the
# final network -- the flows, the recovered heads and the element equations --
# after every outer-loop adjustment (orifice sizing, pump check valves, ratio
# valves, velocity pressures) has been made.
#
# THREE RESULTS, KEPT APART
#   numerical   the network balances: every value finite, the Hardy Cross
#               iteration converged and every device state settled, continuity
#               at every node and overall, every loop closed, every element's
#               pressure difference agreeing with its own equation
#   physical    the answer can exist: no pump, check valve, backflow
#               preventer, ratio valve or dry pipe valve passing water
#               backwards; no outlet discharging backwards; no supply taking
#               water in; every supply check valve in the state its own
#               pressures put it in; curves the right way up; plates that fit their pipe
#               and meet their duty; every operating demand reachable from a
#               supply; no pressure below vapour pressure
#   design      the answer meets the design: every outlet reached by a supply
#               (SUPPLY_ISOLATED where check valves have cut it off), every outlet's flow and pressure,
#               fixed-flow minimum pressures, the velocity limit where one is
#               set, pump duties, and the supply against the demand with any
#               margin the model asks for
#
# ACCEPTANCE, from the three
#   INDETERMINATE  the iteration did not converge, a device state did not
#                  settle, or a value is not finite: there is no solution to
#                  judge, and nothing in the results may be used
#   REJECTED       a solution was found but a numerical or a physical check
#                  failed: it is not a valid answer to the model
#   NONCOMPLIANT   a valid answer, numerically and physically, that fails the
#                  design
#   ACCEPTED       everything passes
#
# A converged calculation is never ACCEPTED while a mandatory check has
# failed.  Warnings (severity "warning") are reported but do not decide the
# result; errors do.  Every finding is a structured record -- code, category,
# severity, item, value, limit, unit, message -- so the JSON carries the
# reason as data, not only as a sentence.
#
# Values in findings are in the MODEL's flow and pressure units, as the
# report prints them; residuals are given in both.
#==============================================================================
package HardyCross::Validate;

use strict;
use warnings;
use HardyCross;

my $GW   = $HardyCross::GAMMA_W;
my $QT   = $HardyCross::Q_TINY;

# Vapour pressure of water at 20 C is about 2.3 kPa absolute; at standard
# atmospheric pressure (101.325 kPa) that is -99.0 kPa gauge.  Water cannot
# be held below it: a solved pressure lower than this is not a pressure the
# pipework can have, whatever the arithmetic says.
our $VAPOUR_GAUGE = -(101.325 - 2.34);

# ISO 5167-2 range of diameter ratio for which an orifice plate's discharge
# coefficient is established.  Outside it the loss model is extrapolated.
our ($BETA_MIN, $BETA_MAX) = (0.10, 0.75);

# The range of differential trip ratio that dry pipe valves in common use
# are made to (about 5:1 to 6:1, the commonest 5.5:1).  Outside a wider band
# than that, 3:1 to 8:1, the figure is flagged for checking: it is likely a
# typing error or a valve of a kind this check does not know.
our ($DPV_RATIO_LO, $DPV_RATIO_HI) = (3.0, 8.0);

# THE VERIFICATION LIMITS -- what the final network must satisfy, whatever
# the solver was told.  OPTION TOL_LOOP and TOL_FLOW say when the Hardy Cross
# iteration may STOP; they are not the test of its answer.  As released a
# TOL_LOOP of 500 kPa was also the limit the answer was checked to, and a
# network 21 kPa out of balance round a loop, its flows 1.7 % wrong, was
# ACCEPTED.
#
#   continuity, balance   1e-6 of the largest flow (at least 1e-6 L/min).
#                 Hardy Cross keeps continuity exact by construction, so this
#                 is floating-point rounding, nothing more.
#   loop, element  VERIFY_P = 0.1 kPa, plus VERIFY_P_REL = 1e-6 of the
#                 largest head in the network for rounding.  0.1 kPa is about
#                 10 mm of water; it is ten times PHCP's default solver
#                 tolerance (0.01 kPa), so every default solve meets it with
#                 room to spare, and 1/34 of the 0.5 psi (3.4 kPa) to which
#                 NFPA 13 hand calculations are balanced at a junction.  No
#                 pressure PHCP prints can be out by more than that through
#                 the iteration stopping early.
# The default tolerance on a sized orifice plate's final drop, per cent of
# its target (OPTION ORIF_DP_TOL; see the ORIFICE check below).
our $ORIF_DP_TOL = 10;

our $VERIFY_Q_REL = 1e-6;
our $VERIFY_P     = 0.1;
our $VERIFY_P_REL = 1e-6;

#------------------------------------------------------------------------------
# validate -- the three results and the acceptance for a solved network.
#
#   $net    a network solve_model has run on
#   $ok     solve_model's return
#   %o      demand    => the single-supply demand point
#                        (HardyCross::Demand::demand_point), if worked out
#           supplies  => the multiple-supply schedule (HardyCross::Supplies),
#                        if worked out
#
# Returns {
#   acceptance  ACCEPTED | NONCOMPLIANT | REJECTED | INDETERMINATE
#   numerical   { status PASS|FAIL|INDETERMINATE, errors, warnings }
#   physical    { status PASS|FAIL|NOT_ASSESSED, errors, warnings }
#   design      { status PASS|FAIL|NOT_ASSESSED, errors, warnings }
#   residuals   { continuity, balance, loop, element }, each
#               { value, tolerance, unit, at, pass } in model units
#   solver      { method, hc_converged, outer_settled, outer_passes,
#                 outer_stop, iterations, maxiter, tol_flow, tol_loop,
#                 diagnosis }
#   findings    [ { code, category, severity, item, value, limit, unit,
#                   message } ]
# }
#------------------------------------------------------------------------------
sub validate {
    my ($net, $ok, %o) = @_;
    my @f;
    my $add = sub {
        my %r = @_;
        $r{severity} //= 'error';
        push @f, \%r;
    };
    my $v = { findings => \@f };

    numerical($net, $ok, $v, $add);
    physical($net, $add);
    # The demand assessment: whether the supplies' adequacy was shown, and on
    # what basis -- DEMONSTRATED, INADEQUATE, UNRESOLVED (the search failed;
    # the supply was not found too weak) or NOT_ASSESSED.
    my %da = (status => 'NOT_ASSESSED', basis => undef, message => 'no demand was worked out');
    design($net, $add, %o, assessment => \%da);
    $v->{demand_assessment} = \%da;
    dry_time_checks($net, $add, $o{dry}) if $o{dry};

    # The status of each category: FAIL if it has an error.  A numerical
    # failure that comes from there being no settled solution at all is
    # INDETERMINATE, and then the physical and design checks, though run,
    # judge a network that is not an answer and are NOT ASSESSED.
    my %err;
    for (@f) { $err{ $_->{category} }++ if $_->{severity} eq 'error' }
    my $count = sub {
        my ($c, $s) = @_;
        return scalar grep { $_->{category} eq $c && $_->{severity} eq $s } @f;
    };
    my $indet = $v->{indeterminate};
    for my $c (qw(numerical physical design)) {
        $v->{$c} = {
            status   => $c eq 'numerical' && $indet ? 'INDETERMINATE'
                      : $c ne 'numerical' && $indet ? 'NOT_ASSESSED'
                      : $err{$c} ? 'FAIL' : 'PASS',
            errors   => $count->($c, 'error'),
            warnings => $count->($c, 'warning'),
        };
    }
    $v->{acceptance} = $indet                                         ? 'INDETERMINATE'
                     : $err{numerical} || $err{physical}              ? 'REJECTED'
                     : $err{design}                                   ? 'NONCOMPLIANT'
                     :                                                  'ACCEPTED';
    return $v;
}

# finite -- true for an ordinary number: not NaN, not infinite.
sub finite { my $x = shift; return defined $x && $x == $x && abs($x) < 9**9**9 }

sub open_elems {
    my $net = shift;
    return grep { !$_->{closed} } @{ $net->{elems} }[1 .. $#{ $net->{elems} }];
}

sub gauge {
    my ($net, $i) = @_;
    my $n = $net->{nodes}[$i];
    return $n->{h} - $GW * $n->{z};
}

#==============================================================================
# NUMERICAL
#==============================================================================
sub numerical {
    my ($net, $ok, $v, $add) = @_;
    my ($uf, $up) = @{$net}{qw(f_flow f_pres)};
    my $o = $net->{opts};
    my $tol_flow = $o->{tol_flow} // 0.05;
    my $tol_loop = $o->{tol_loop} // 0.01;
    my $nn = $#{ $net->{nodes} };
    my @el = @{ $net->{elems} }[1 .. $#{ $net->{elems} }];

    $v->{solver} = {
        method        => $o->{method} // 'HW',
        algorithm     => 'sequential Hardy Cross (loop by loop), fundamental loops of a spanning tree',
        hc_converged  => ($net->{hc_converged} // ($ok ? 1 : 0)) ? 1 : 0,
        outer_settled => $net->{outer_settled} // 0,
        outer_passes  => $net->{outer_passes} // 0,
        outer_stop    => $net->{outer_stop} // 'not_run',
        iterations    => $net->{iters} // 0,
        maxiter       => $o->{maxiter} // 50000,
        tol_flow      => $tol_flow / $uf,
        tol_loop      => $tol_loop / $up,
        diagnosis     => $net->{nonconv},
        loops         => scalar @{ $net->{loops} || [] },
    };

    # Every value finite.  Checked first: a NaN compares false with
    # everything, so every later "is it within tolerance" test would pass it.
    my @bad = grep { !finite($_->{q}) } @el;
    my @badn = grep { !finite($net->{nodes}[$_]{h}) } 1 .. $nn;
    if (@bad || @badn) {
        $add->(code => 'NONFINITE', category => 'numerical', item => join(' ', map { $_->{id} } @bad,
               map { $net->{nodes}[$_]{id} } @badn),
               message => 'flows or pressures are not finite numbers (NaN or infinity)');
        $v->{indeterminate} = 1;
        $v->{residuals} = {};
        return;
    }

    unless ($v->{solver}{hc_converged}) {
        $add->(code => 'NOT_CONVERGED', category => 'numerical', item => undef,
               value => $v->{solver}{iterations}, limit => $v->{solver}{maxiter}, unit => 'iterations',
               message => sprintf('the Hardy Cross iteration did not converge in %d iterations%s',
                                  $v->{solver}{iterations},
                                  $net->{nonconv} ? " ($net->{nonconv})" : ''));
        $v->{indeterminate} = 1;
    }
    if ($v->{solver}{hc_converged} && !$v->{solver}{outer_settled}) {
        $add->(code => 'DEVICES_UNSETTLED', category => 'numerical', item => undef,
               value => $v->{solver}{outer_passes}, unit => 'outer passes',
               message => 'the device states (orifice plates, pump and supply check valves, ratio valves, '
                        . 'velocity pressures) had not settled when the solve stopped');
        $v->{indeterminate} = 1;
    }
    # A supply check valve that kept changing state until its switch limit,
    # and still wants to change (HardyCross::supply_status): its state was not
    # decided, so neither is anything solved with it.
    my @unsettled = grep { $_->{nrv} && $_->{flip_limit} } @el;
    if (@unsettled) {
        $add->(code => 'SUPPLY_CHECK_UNRESOLVED', category => 'numerical', item => join(' ', map { $_->{id} } @unsettled),
               value => $unsettled[0]{nflips}, unit => 'switches',
               message => sprintf('supply check valve%s %s opened and closed on alternate solves until the switch '
                                . 'limit was reached and %s still not in the state %s pressures call for: the '
                                . 'operating state is not resolved', @unsettled > 1 ? 's' : '',
                                  join(', ', map { $_->{id} } @unsettled), @unsettled > 1 ? 'are' : 'is',
                                  @unsettled > 1 ? 'their' : 'its'));
        $v->{indeterminate} = 1;
    }
    if (@{ $net->{degenerate} || [] }) {
        $add->(code => 'DEGENERATE_LOOP', category => 'numerical', item => join(' ', @{ $net->{degenerate} }),
               message => 'a loop made only of fixed-pressure elements (static supplies, fixed drops) is out '
                        . 'of balance and cannot be corrected: it has no flow-dependent loss');
    }

    #------------------------------------------------------------- continuity
    # At every node: what flows in, less what flows out, less its demand.
    # Hardy Cross keeps this exact by construction, so the tolerance is
    # rounding: one part in a million of the largest flow, or 1e-6 L/min.
    my @acc = (0) x ($nn + 1);
    $acc[$_] = $net->{nodes}[$_]{demand} // 0 for 1 .. $nn;
    my $qscale = 0;
    for my $e (open_elems($net)) {
        $acc[ $e->{n1} ] += $e->{q};
        $acc[ $e->{n2} ] -= $e->{q};
        $qscale = abs $e->{q} if abs $e->{q} > $qscale;
    }
    my $ctol = $VERIFY_Q_REL * ($qscale > 1 ? $qscale : 1);
    my $hscale = 0;
    for my $i (1 .. $nn) { my $h = abs($net->{nodes}[$i]{h} // 0); $hscale = $h if $h > $hscale }
    my $ptol = $VERIFY_P + $VERIFY_P_REL * $hscale;
    $v->{verification} = {
        continuity => $ctol / $uf, balance => $ctol / $uf, flow_unit => $net->{u_flow},
        loop => $ptol / $up, element => $ptol / $up, pressure_unit => $net->{u_pres},
        basis => sprintf('continuity and balance to %g of the largest flow; loop closure and element equations to '
                       . '%g kPa plus %g of the largest head; fixed by PHCP, not by the solver tolerances',
                         $VERIFY_Q_REL, $VERIFY_P, $VERIFY_P_REL),
    };
    if ($tol_loop > $VERIFY_P + 1e-12) {
        $add->(code => 'SOLVER_TOLERANCE_LOOSE', category => 'numerical', severity => 'warning', item => 'TOL_LOOP',
               value => $tol_loop / $up, limit => $VERIFY_P / $up, unit => $net->{u_pres},
               message => sprintf('TOL_LOOP %g %s lets the iteration stop with loops further out of balance than the '
                                . 'verification limit of %g; the answer is checked to the limit', $tol_loop / $up,
                                  $net->{u_pres}, $VERIFY_P / $up));
    }

    #----------------------------------------------------------- closed flow
    # A closed element -- a pump shut on its check valve, a supply out of
    # service -- is out of the network and must carry nothing.  Continuity
    # leaves it out, so a closed element left with its flow would otherwise
    # only show as the imbalance at its ends.
    for my $e (grep { $_->{closed} } @el) {
        next if abs($e->{q} // 0) <= $ctol;
        $add->(code => 'CLOSED_FLOW', category => 'numerical', item => $e->{id}, value => $e->{q} / $uf,
               limit => $ctol / $uf, unit => $net->{u_flow},
               message => sprintf('%s is closed but carries %.4g %s: a closed element is out of the network',
                                  $e->{id}, $e->{q} / $uf, $net->{u_flow}));
    }
    my ($cmax, $cat) = (0, undef);
    for my $i (1 .. $nn) {
        next if $i == $net->{iref};
        ($cmax, $cat) = (abs $acc[$i], $net->{nodes}[$i]{id}) if abs $acc[$i] > $cmax;
    }
    $v->{residuals}{continuity} = { value => $cmax / $uf, tolerance => $ctol / $uf,
                                    unit => $net->{u_flow}, at => $cat, pass => $cmax <= $ctol ? 1 : 0 };
    $add->(code => 'CONTINUITY', category => 'numerical', item => $cat, value => $cmax / $uf,
           limit => $ctol / $uf, unit => $net->{u_flow},
           message => sprintf('continuity fails at node %s: %.6g %s unaccounted for',
                              $cat, $cmax / $uf, $net->{u_flow}))
        if $cmax > $ctol;

    #------------------------------------------------------- overall balance
    # The signed sum of every supply's flow into the network against every
    # outlet's discharge and every fixed demand.  A supply's flow is positive
    # INTO the network; a reverse supply counts against.
    my ($qin, $qout) = (0, 0);
    for my $e (open_elems($net)) {
        $qin  += $e->{q} if $e->{kind} =~ /^SUPPLY_/;
        $qout += $e->{q} if $e->{kind} eq 'DISCHARGE';
    }
    $qout += $net->{nodes}[$_]{demand} // 0 for 1 .. $nn;
    my $bal = abs($qin - $qout);
    $v->{residuals}{balance} = { value => $bal / $uf, tolerance => $ctol / $uf, unit => $net->{u_flow},
                                 supply => $qin / $uf, demand => $qout / $uf, pass => $bal <= $ctol ? 1 : 0 };
    $add->(code => 'BALANCE', category => 'numerical', item => undef, value => $bal / $uf,
           limit => $ctol / $uf, unit => $net->{u_flow},
           message => sprintf('the supplies give %.4f %s and the outlets and demands take %.4f %s',
                              $qin / $uf, $net->{u_flow}, $qout / $uf, $net->{u_flow}))
        if $bal > $ctol;

    #------------------------------------------------------------ loop closure
    # Every fundamental loop's signed sum of losses, worked again from the
    # final flows -- not the residual the solver measured during its sweep.
    my ($lmax, $lat) = (0, undef);
    for my $li (0 .. $#{ $net->{loops} || [] }) {
        my $s = 0;
        for my $st (@{ $net->{loops}[$li] }) {
            my $e = $net->{elems}[ $st->[0] ];
            my ($hf) = HardyCross::elem_hf($e, $e->{q}, $o);
            $s += $st->[1] * $hf;
        }
        ($lmax, $lat) = (abs $s, $li + 1) if abs $s > $lmax || !finite($s);
    }
    $v->{residuals}{loop} = { value => $lmax / $up, tolerance => $ptol / $up, solver_tolerance => $tol_loop / $up,
                              unit => $net->{u_pres}, at => defined $lat ? "loop $lat" : undef,
                              pass => $lmax <= $ptol ? 1 : 0 };
    $add->(code => 'LOOP_CLOSURE', category => 'numerical', item => "loop $lat", value => $lmax / $up,
           limit => $ptol / $up, unit => $net->{u_pres},
           message => sprintf('loop %d does not close: %.6g %s against the verification limit of %g',
                              $lat, $lmax / $up, $net->{u_pres}, $ptol / $up))
        if $lmax > $ptol && !$v->{indeterminate};

    #-------------------------------------------------------- element equations
    # For every element, the head difference between its ends, taken from
    # the recovered node heads, against what the element's own equation gives
    # at its flow.  This includes every elevation: a supply's head is its
    # pressure plus its elevation head, an outlet's requirement its pressure
    # plus its own.  Tree elements agree exactly (the heads are recovered
    # along them); a chord's residual is its loop's closure, so the tolerance
    # is the loop tolerance.
    my ($emax, $eat) = (0, undef);
    for my $e (open_elems($net)) {
        my ($hf) = HardyCross::elem_hf($e, $e->{q}, $o);
        my $dh = $net->{nodes}[ $e->{n1} ]{h} - $net->{nodes}[ $e->{n2} ]{h};
        my $r  = $dh - $hf;
        ($emax, $eat) = (abs $r, $e->{id}) if abs $r > $emax;
    }
    $v->{residuals}{element} = { value => $emax / $up, tolerance => $ptol / $up, solver_tolerance => $tol_loop / $up,
                                 unit => $net->{u_pres}, at => $eat, pass => $emax <= $ptol ? 1 : 0 };
    $add->(code => 'ELEMENT_EQUATION', category => 'numerical', item => $eat, value => $emax / $up,
           limit => $ptol / $up, unit => $net->{u_pres},
           message => sprintf('element %s: the pressure across it differs from its own equation by %.6g %s, against '
                            . 'the verification limit of %g', $eat, $emax / $up, $net->{u_pres}, $ptol / $up))
        if $emax > $ptol && !$v->{indeterminate};
}

#==============================================================================
# PHYSICAL
#==============================================================================

# curve_order -- undef if a curve's pressures run the way they must with
# flow (falling for a supply or a pump, $dir -1; rising for a loss, +1),
# else the flow at which they first go the wrong way.
sub curve_order {
    my ($c, $dir) = @_;
    for my $i (1 .. $#{ $c->{q} }) {
        my $d = $c->{p}[$i] - $c->{p}[ $i - 1 ];
        return $c->{q}[$i] if $dir * $d < -1e-9;
    }
    return undef;
}

# extrapolated -- 'ABOVE' or 'BELOW' when a flow lies outside a curve's
# points, else undef.
sub extrapolated {
    my ($c, $q) = @_;
    return 'ABOVE' if $q > $c->{qhi} * (1 + 1e-9) + 1e-9;
    return 'BELOW' if $q < $c->{qlo} * (1 - 1e-9) - 1e-9;
    return undef;
}

sub physical {
    my ($net, $add) = @_;
    my ($uf, $up) = @{$net}{qw(f_flow f_pres)};
    my ($fu, $pu) = ($net->{u_flow}, $net->{u_pres});
    my @el = @{ $net->{elems} }[1 .. $#{ $net->{elems} }];
    my $P = sub { my %r = @_; $add->(category => 'physical', %r) };
    # A device's duty is a design requirement, checked here with its device.
    my $add_design = sub { my %r = @_; $add->(category => 'design', %r) };

    for my $e (@el) {
        my $k = $e->{kind};
        my $q = $e->{q} // 0;
        # An element cut off with its supply (HardyCross::isolate_unsupplied)
        # is out of the network, with no flow and no pressure to judge; the
        # loss of supply itself is a design finding (SUPPLY_ISOLATED).
        next if $e->{isolated};

        #------------------------------------------------------------ supplies
        if ($k =~ /^SUPPLY_/) {
            if ($q < -$QT) {
                $P->(code => 'SUPPLY_REVERSE', item => $e->{id}, value => $q / $uf, unit => $fu,
                     message => sprintf('water supply %s takes water IN, %.1f %s: a supply does not accept '
                                      . 'flow from the network%s', $e->{id}, -$q / $uf, $fu,
                                        $e->{nrv} ? ', and its check valve is open' : ''));
            }
            # A supply check valve, worked again from the final heads rather
            # than taken from the solver's own decision.  Shut, the network at
            # its connection must stand at or above the supply's no-flow head
            # less its opening pressure -- otherwise water would lift the
            # clapper, and the state reported is not the one the pressures
            # give.  (Open, it is the reverse-flow check above.)
            if ($e->{nrv} && $e->{check_closed}) {
                my $h0 = HardyCross::supply_head0($e);
                my $h  = $net->{nodes}[ $e->{n2} ]{h};
                my $push = $h0 - $h - $e->{nrv}{crack};
                $P->(code => 'SUPPLY_CHECK_INCONSISTENT', item => $e->{id}, value => $push / $up, limit => 0, unit => $pu,
                     message => sprintf('water supply %s is shut on its check valve, but its pressure exceeds the '
                                      . 'network at its connection by %.3f %s more than the valve needs to open: '
                                      . 'the valve would be open', $e->{id}, $push / $up, $pu))
                    if $push > $VERIFY_P;
                # Shut, it takes no part in the solve: what its pressure
                # would be (a derating can take it below zero) is not judged.
                next;
            }
            if ($e->{nrv} && (my $lc = $e->{nrv}{curve})) {
                # A manufacturer loss curve is not verified outside its
                # published flow range.  In particular a linear extension
                # of the last segment is a numerical extrapolation, not
                # evidence of the valve's pressure loss at that duty.
                $P->(code => 'NRV_CURVE_RANGE', item => $e->{id},
                     value => $q / $uf, limit => $lc->{qhi} / $uf, unit => $fu,
                     message => sprintf('supply check valve %s: %.1f %s exceeds the last documented '
                                    . 'flow-loss point %.1f %s', $e->{id}, $q / $uf, $fu,
                                      $lc->{qhi} / $uf, $fu))
                    if $q > $lc->{qhi} + $QT;
            }
            if ($k eq 'SUPPLY_CURVE') {
                if (defined(my $at = curve_order($e->{curve}, -1))) {
                    $P->(code => 'SUPPLY_CURVE_RISING', item => $e->{id}, value => $at / $uf, unit => $fu,
                         message => sprintf('water supply %s: its pressure RISES with flow at %.1f %s; a '
                                          . 'supply curve must not rise', $e->{id}, $at / $uf, $fu));
                }
                if (grep { $_ < 0 } @{ $e->{curve}{p} }) {
                    $P->(code => 'SUPPLY_CURVE_NEGATIVE', item => $e->{id},
                         message => "water supply $e->{id}: a curve point has a negative pressure");
                }
                if (my $x = extrapolated($e->{curve}, $q)) {
                    $P->(code => 'CURVE_EXTRAPOLATED', severity => 'warning', item => $e->{id},
                         value => $q / $uf, limit => ($x eq 'ABOVE' ? $e->{curve}{qhi} : $e->{curve}{qlo}) / $uf,
                         unit => $fu,
                         message => sprintf('water supply %s operates at %.1f %s, %s its curve points (%.1f to '
                                          . '%.1f): its pressure there is EXTRAPOLATED', $e->{id}, $q / $uf,
                                          $fu, $x eq 'ABOVE' ? 'beyond' : 'below',
                                          $e->{curve}{qlo} / $uf, $e->{curve}{qhi} / $uf));
                }
                extrapolation_limit($e, $e->{curve}, $q, 'water supply', $add_design, $uf, $fu);
                my $pa = HardyCross::curve_eval($e->{curve}, $q);
                $P->(code => 'SUPPLY_EXHAUSTED', item => $e->{id}, value => $pa / $up, unit => $pu,
                     message => sprintf('water supply %s: at %.1f %s its curve gives %.1f %s, below zero',
                                        $e->{id}, $q / $uf, $fu, $pa / $up, $pu))
                    if $pa < 0;
            } elsif (($e->{pstat} // 0) < 0) {
                $P->(code => 'SUPPLY_NEGATIVE', item => $e->{id},
                     message => "water supply $e->{id} has a negative static pressure");
            }
            next;
        }

        #--------------------------------------------------------------- pumps
        if ($k eq 'PUMP') {
            my $c = $e->{curve};
            if ($e->{isolating}) {
                $P->(code => 'PUMP_ISOLATING', item => $e->{id}, value => $q / $uf, unit => $fu,
                     message => sprintf('pump %s runs backwards (%.1f %s), and closing its check valve '
                                      . 'would isolate part of the network: the model has no valid '
                                      . 'operating state', $e->{id}, $q / $uf, $fu));
            } elsif (!$e->{closed} && $q < -$QT) {
                $P->(code => 'PUMP_REVERSE', item => $e->{id}, value => $q / $uf, unit => $fu,
                     message => sprintf('pump %s runs backwards, %.1f %s: its check valve does not pass '
                                      . 'reverse flow', $e->{id}, $q / $uf, $fu));
            }
            if ($e->{flip_limit}) {
                $P->(code => 'PUMP_STATE_UNRESOLVED', item => $e->{id}, value => $e->{nflips}, unit => 'switches',
                     message => "pump $e->{id}: its check valve opened and closed on alternate solves until "
                              . 'the limit was reached; its state is not resolved');
            }
            if ($e->{closed}) {
                my $lift = $net->{nodes}[ $e->{n2} ]{h} - $net->{nodes}[ $e->{n1} ]{h};
                my $shut = HardyCross::curve_eval($c, 0);
                $P->(code => 'PUMP_STATE_UNRESOLVED', item => $e->{id}, value => $lift / $up, limit => $shut / $up,
                     unit => $pu,
                     message => sprintf('pump %s is shut on its check valve, but the lift across it, %.1f %s, '
                                      . 'is below its shut-off pressure %.1f: it would deliver', $e->{id},
                                      $lift / $up, $pu, $shut / $up))
                    if $lift < $shut - 1e-6;
                next;
            }
            if (defined(my $at = curve_order($c, -1))) {
                # A pump curve may droop: rise a little from shut-off before
                # it falls.  Hardy Cross needs the curve to fall where the
                # pump runs, so a droop is a warning unless the pump runs on
                # it.
                my $on = $q <= $at + 1e-9;
                $P->(code => 'PUMP_CURVE_RISING', severity => $on ? 'error' : 'warning', item => $e->{id},
                     value => $at / $uf, unit => $fu,
                     message => sprintf('pump %s: its curve rises with flow up to %.1f %s%s', $e->{id}, $at / $uf,
                                        $fu, $on ? ', and the pump operates on that rising part - an unstable '
                                                 . 'operating point' : ''));
            }
            if (my $x = extrapolated($c, $q)) {
                $P->(code => 'CURVE_EXTRAPOLATED', severity => 'warning', item => $e->{id}, value => $q / $uf,
                     limit => ($x eq 'ABOVE' ? $c->{qhi} : $c->{qlo}) / $uf, unit => $fu,
                     message => sprintf('pump %s operates at %.1f %s, beyond its curve points (to %.1f): its '
                                      . 'pressure there is EXTRAPOLATED', $e->{id}, $q / $uf, $fu, $c->{qhi} / $uf));
            }
            extrapolation_limit($e, $c, $q, 'pump', $add_design, $uf, $fu);
            my $rise = HardyCross::curve_eval($c, $q);
            $P->(code => 'PUMP_BEYOND_RUNOUT', item => $e->{id}, value => $rise / $up, unit => $pu,
                 message => sprintf('pump %s at %.1f %s: its curve gives %.1f %s, a pressure LOSS - the pump is '
                                  . 'beyond its run-out', $e->{id}, $q / $uf, $fu, $rise / $up, $pu))
                if $rise < 0;
            next;
        }
        next if $e->{closed};

        #-------------------------------------------------------------- outlets
        if ($k eq 'DISCHARGE') {
            if ($q < -$QT) {
                $P->(code => 'OUTLET_REVERSE', item => $e->{id}, value => $q / $uf, unit => $fu,
                     message => sprintf('%s %s discharges BACKWARDS, %.1f %s: water would enter the network '
                                      . 'through it', lc($e->{otype} // 'outlet'), $e->{id}, $q / $uf, $fu));
            }
            next;
        }

        #------------------------------------------------------ orifice plates
        if ($k eq 'ORIFICE_REQUIRED') {
            $P->(code => 'ORIFICE_NOT_SIZED', item => $e->{id},
                 message => "orifice plate $e->{id} was never sized: the solve did not reach a converged answer");
            next;
        }
        if ($k eq 'ORIFICE') {
            my ($b, $d) = ($e->{bore} // 0, $e->{pipedia} // 0);
            my $invalid = $b <= 0 || ($d > 0 && $b >= $d);
            $P->(code => 'ORIFICE_BORE_INVALID', item => $e->{id}, value => $b, limit => $d, unit => 'mm',
                 message => sprintf('orifice plate %s: a bore of %.2f mm in a %.2f mm pipe is not a plate',
                                    $e->{id}, $b, $d))
                if $invalid;
            # A bore the rounding had to force -- down below the pipe bore,
            # or up from nothing -- is not the plate the duty asks for: the
            # duty lies within one ORIF_STEP of the end of what a plate can do,
            # and the plate made gives a drop far from it.
            if (!$e->{size_clamp} && (my $br = $e->{bore_rounding})) {
                $P->(code => 'ORIFICE_UNACHIEVABLE', item => $e->{id}, value => ($e->{dp_target} // 0) / $up,
                     unit => $pu,
                     message => sprintf('orifice plate %s: a drop of %.3f %s needs a bore of %.3f mm, which rounds '
                                      . 'to %s; the nearest plate that can be made is %.2f mm, and it does not give '
                                      . 'the duty', $e->{id}, ($e->{dp_target} // 0) / $up, $pu, $e->{bore_exact},
                                        $br eq 'DOWN_BELOW_PIPE_BORE' ? 'the full pipe bore' : 'nothing', $b));
            }
            if (my $cl = $e->{size_clamp}) {
                $P->(code => 'ORIFICE_UNACHIEVABLE', item => $e->{id},
                     value => ($e->{dp_target} // 0) / $up, unit => $pu,
                     message => $cl eq 'NO_FLOW'
                        ? "orifice plate $e->{id}: there is no flow through it to size it on"
                        : sprintf('orifice plate %s: a drop of %.2f %s at %.1f %s cannot be produced by any '
                                . 'bore in this pipe (%s)', $e->{id}, ($e->{dp_target} // 0) / $up, $pu,
                                  ($e->{q_sized} // 0) / $uf, $fu,
                                  $cl eq 'BORE_MAX' ? 'even a plate of nearly the full bore drops more'
                                                    : 'even the smallest bore drops less'));
            }
            next if $invalid;
            if ($d > 0) {
                my $beta = $b / $d;
                $P->(code => 'ORIFICE_BETA_RANGE', severity => 'warning', item => $e->{id}, value => $beta,
                     limit => $beta < $BETA_MIN ? $BETA_MIN : $BETA_MAX, unit => 'beta',
                     message => sprintf('orifice plate %s: diameter ratio %.3f is outside %.2f to %.2f, the range '
                                      . 'its loss model is established for (ISO 5167-2)', $e->{id}, $beta,
                                        $BETA_MIN, $BETA_MAX))
                    if $beta < $BETA_MIN || $beta > $BETA_MAX;
            }
            if (defined $e->{dp_target} && $e->{dp_target} > 0) {
                # The plate is sized on one solve and the network solved again
                # with it, so its final drop differs from the target for two
                # reasons, each worked out and kept:
                #   rounding  the bore made to ORIF_STEP, at the flow it was
                #             sized on: dp(q_sized, bore) - target
                #   flow      the flow moving once the plate is in:
                #             dp(q_final, bore) - dp(q_sized, bore)
                # They add up to the whole deviation.  The duty is met when
                # the final drop is within ORIF_DP_TOL per cent of the target
                # (10 % unless set).  10 % is what half a 0.5 mm step does to
                # the drop of a 10 mm bore -- the drop goes as the bore to the
                # power -4, so 4 x 0.25 / 10 -- so every plate of 10 mm or more
                # on the default step meets it on rounding alone; a tighter
                # tolerance needs a finer ORIF_STEP.  As released the
                # deviation was printed and never judged.
                my $dp = HardyCross::orifice_dp(abs $q, $b, $d, $e->{cd});
                my $dps = HardyCross::orifice_dp($e->{q_sized} // abs $q, $b, $d, $e->{cd});
                my $t = $e->{dp_target};
                $e->{dp_final}         = $dp;
                $e->{dev_pct}          = 100 * ($dp - $t) / $t;
                $e->{dev_rounding_pct} = 100 * ($dps - $t) / $t;
                $e->{dev_flow_pct}     = 100 * ($dp - $dps) / $t;
                my $tol = $net->{opts}{orif_dp_tol} // $ORIF_DP_TOL;
                $e->{dev_tol_pct} = $tol;
                $P->(code => 'ORIFICE_DEVIATION', severity => 'info', item => $e->{id},
                     value => $dp / $up, limit => $t / $up, unit => $pu,
                     message => sprintf('orifice plate %s: final drop %.2f %s against a target of %.2f (%+.1f %%: '
                                      . '%+.1f %% from rounding the bore to %.2f mm from %.3f mm, %+.1f %% from the '
                                      . 'flow moving from %.1f to %.1f %s)', $e->{id}, $dp / $up, $pu, $t / $up,
                                        $e->{dev_pct}, $e->{dev_rounding_pct}, $b, $e->{bore_exact} // $b,
                                        $e->{dev_flow_pct}, ($e->{q_sized} // abs $q) / $uf, abs($q) / $uf, $fu));
                $add_design->(code => 'ORIFICE_DUTY', item => $e->{id}, value => $e->{dev_pct}, limit => $tol,
                              unit => '%',
                              message => sprintf('orifice plate %s: its final drop, %.2f %s, is %+.1f %% from its target '
                                               . 'of %.2f, outside the %g %% tolerance (ORIF_DP_TOL); %s', $e->{id},
                                                 $dp / $up, $pu, $e->{dev_pct}, $t / $up, $tol,
                                                 abs($e->{dev_rounding_pct}) >= abs($e->{dev_flow_pct})
                                                 ? 'mostly from rounding the bore: a finer ORIF_STEP is needed'
                                                 : 'mostly from the flow moving once the plate is in'))
                    if abs($e->{dev_pct}) > $tol + 1e-9 && !$e->{size_clamp} && !$e->{bore_rounding};
            }
            next;
        }

        #------------------------------------------------- pressure ratio valve
        if ($k eq 'RATIO') {
            my $pin = $e->{pin} // gauge($net, $e->{n1});
            $P->(code => 'PRA_REVERSE', item => $e->{id}, value => $q / $uf, unit => $fu,
                 message => sprintf('pressure ratio valve %s passes water backwards, %.1f %s, which it does not '
                                  . 'do', $e->{id}, $q / $uf, $fu))
                if $q < -$QT;
            $P->(code => 'PRA_MIN_INLET', item => $e->{id}, value => $pin / $up, limit => $e->{mininlet} / $up,
                 unit => $pu,
                 message => sprintf('pressure ratio valve %s: inlet %.1f %s is below its minimum inlet pressure '
                                  . '%.1f; it does not hold its ratio there', $e->{id}, $pin / $up, $pu,
                                    $e->{mininlet} / $up))
                if defined $e->{mininlet} && $pin < $e->{mininlet};
            $P->(code => 'PRA_NO_INLET', item => $e->{id}, value => $pin / $up, unit => $pu,
                 message => sprintf('pressure ratio valve %s passes %.1f %s with an inlet pressure of %.1f %s',
                                    $e->{id}, $q / $uf, $fu, $pin / $up, $pu))
                if $pin <= 0 && $q > $QT;
            next;
        }

        #--------------------------------------------- backflow preventers, PRV
        if ($k eq 'BFP') {
            $P->(code => 'BFP_REVERSE', item => $e->{id}, value => $q / $uf, unit => $fu,
                 message => sprintf('backflow preventer %s passes water backwards, %.1f %s', $e->{id}, $q / $uf, $fu))
                if $q < -$QT;
            loss_curve_checks($e, $q, $P, 'loss device', $uf, $fu, $add_design);
            next;
        }
        if ($k eq 'FIXED_DROP') {
            $P->(code => 'FIXED_DROP_NO_FLOW', severity => 'warning', item => $e->{id},
                 message => "fixed loss $e->{id} carries no flow; a fixed loss at no flow is not defined, "
                          . 'and the pressures either side of it should be checked')
                if abs($q) <= $QT;
            $P->(code => 'FIXED_DROP_REVERSE', severity => 'warning', item => $e->{id}, value => $q / $uf, unit => $fu,
                 message => sprintf('fixed loss %s carries flow backwards, %.1f %s; check that the valve it '
                                  . 'stands for passes reverse flow', $e->{id}, $q / $uf, $fu))
                if $q < -$QT;
            next;
        }

        #------------------------------------------------------ dry pipe valves
        if ($k eq 'DPV') {
            dpv_checks($net, $e, $P, $add_design);
            next;
        }
    }

    #--------------------------------------------------- pressures at nodes
    for my $i (1 .. $#{ $net->{nodes} }) {
        next if $i == $net->{iref};
        my $p = gauge($net, $i);
        next unless HardyCross::Validate::finite($p);
        if ($p < $VAPOUR_GAUGE) {
            $P->(code => 'BELOW_VAPOUR', item => $net->{nodes}[$i]{id}, value => $p / $up,
                 limit => $VAPOUR_GAUGE / $up, unit => $pu,
                 message => sprintf('node %s: %.1f %s gauge is below the vapour pressure of water; no such '
                                  . 'pressure can exist', $net->{nodes}[$i]{id}, $p / $up, $pu));
        } elsif ($p < -1e-6) {
            $P->(code => 'NEGATIVE_PRESSURE', severity => 'warning', item => $net->{nodes}[$i]{id},
                 value => $p / $up, unit => $pu,
                 message => sprintf('node %s: %.1f %s, below atmospheric', $net->{nodes}[$i]{id}, $p / $up, $pu));
        }
    }

    #---------------------------------------- every demand reaches a supply
    connectivity($net, $P);
}

# loss_curve_checks -- a loss curve (backflow preventer, dry pipe valve) must
# not fall with flow, and must not give a negative loss.
# extrapolation_limit -- a curve used far beyond its points.  Within them a
# curve is the data it was made from; a little beyond, it is EXTRAPOLATED and
# said to be (a warning); at more than EXTRAP_MAX times its highest flow the
# answer rests on performance nobody published or measured, and the design
# cannot be shown to work on it.  1.5 is the run-out to which a fire pump is
# rated (150 % of its rated flow), the furthest a published curve normally
# goes; it is a PHCP rule, not a clause of a Standard.
our $EXTRAP_MAX = 1.5;
sub extrapolation_limit {
    my ($e, $c, $q, $what, $D, $uf, $fu) = @_;
    return unless $c && $D && $c->{qhi} > 0;
    my $aq = abs $q;
    return unless $aq > $EXTRAP_MAX * $c->{qhi} * (1 + 1e-9);
    $D->(code => 'CURVE_EXTRAPOLATION_LIMIT', item => $e->{id}, value => $aq / $uf,
         limit => $EXTRAP_MAX * $c->{qhi} / $uf, unit => $fu,
         message => sprintf('%s %s operates at %.1f %s, more than %g times the highest flow of its curve (%.1f): a '
                          . 'result that far beyond the published or tested performance is not supported by the data',
                            $what, $e->{id}, $aq / $uf, $fu, $EXTRAP_MAX, $c->{qhi} / $uf));
}

sub loss_curve_checks {
    my ($e, $q, $P, $what, $uf, $fu, $D) = @_;
    my $c = $e->{curve} or return;
    if (defined(my $at = curve_order($c, +1))) {
        $P->(code => 'LOSS_CURVE_FALLING', item => $e->{id}, value => $at / $uf, unit => $fu,
             message => sprintf('%s %s: its loss FALLS with flow at %.1f %s', $what, $e->{id}, $at / $uf, $fu));
    }
    $P->(code => 'LOSS_CURVE_NEGATIVE', item => $e->{id}, message => "$what $e->{id}: a curve point has a negative loss")
        if grep { $_ < 0 } @{ $c->{p} };
    if (my $x = extrapolated($c, abs $q)) {
        $P->(code => 'CURVE_EXTRAPOLATED', severity => 'warning', item => $e->{id}, value => abs($q) / $uf,
             limit => ($x eq 'ABOVE' ? $c->{qhi} : $c->{qlo}) / $uf, unit => $fu,
             message => sprintf('%s %s passes %.1f %s, %s its curve points (%.1f to %.1f): its loss there is '
                              . 'EXTRAPOLATED', $what, $e->{id}, abs($q) / $uf, $fu, $x eq 'ABOVE' ? 'beyond' : 'below',
                                $c->{qlo} / $uf, $c->{qhi} / $uf));
    }
    extrapolation_limit($e, $c, $q, $what, $D, $uf, $fu) unless ($e->{loss_source} // '') eq 'USER_FIXED';
}

#------------------------------------------------------------------------------
# dpv_checks -- a dry pipe valve, as the steady-state solve takes it: tripped
# and fully open.  Its configuration is checked as well as its hydraulics,
# since a trip setting that cannot be right is a model error even though it
# does not change a steady-state number.
#------------------------------------------------------------------------------
sub dpv_checks {
    my ($net, $e, $P, $D) = @_;
    my ($uf, $up) = @{$net}{qw(f_flow f_pres)};
    my ($fu, $pu) = ($net->{u_flow}, $net->{u_pres});
    my $q = $e->{q} // 0;
    my $id = $e->{id};

    $P->(code => 'DPV_REVERSE', item => $id, value => $q / $uf, unit => $fu,
         message => sprintf('dry pipe valve %s passes water backwards, %.1f %s: its clapper is a check valve',
                            $id, $q / $uf, $fu))
        if $q < -$QT;
    $P->(code => 'DPV_NO_FLOW', severity => 'warning', item => $id,
         message => "dry pipe valve $id carries no flow: the system it serves is not flowing in this calculation")
        if abs($q) <= $QT;

    # Connection: a valve in a pipe, with the pipe found.
    $P->(code => 'DPV_CONNECTION', item => $id, message => "dry pipe valve $id is not in a pipe of the model")
        unless defined $e->{host_id} && grep { $_->{kind} eq 'PIPE' && $_->{id} eq $e->{host_id} }
                                             @{ $net->{elems} }[1 .. $#{ $net->{elems} }];
    # Size.
    $P->(code => 'DPV_SIZE', item => $id, value => $e->{size}, unit => 'mm',
         message => "dry pipe valve $id: a nominal size of " . ($e->{size} // 'none') . ' mm is not a valve size')
        unless ($e->{size} // 0) >= 25 && $e->{size} <= 300;
    if ($e->{host} && $e->{host}{dia} && ($e->{size} // 0) > 0) {
        $P->(code => 'DPV_SIZE_PIPE', severity => 'warning', item => $id, value => $e->{size},
             limit => $e->{host}{dia}, unit => 'mm',
             message => sprintf('dry pipe valve %s: DN%d in a pipe of %.1f mm bore; check the valve suits its pipe',
                                $id, $e->{size}, $e->{host}{dia}))
            if $e->{size} < 0.6 * $e->{host}{dia} || $e->{size} > 1.6 * $e->{host}{dia};
    }

    # Trip method: exactly one, and physically meaningful.
    my $m = $e->{trip_mode} // '';
    if ($m eq 'RATIO') {
        my $r = $e->{trip_ratio};
        if (!defined $r || $r <= 1) {
            $P->(code => 'DPV_RATIO', item => $id, value => $r, unit => 'ratio',
                 message => "dry pipe valve $id: a differential trip ratio must be more than 1:1");
        } elsif ($r < $DPV_RATIO_LO || $r > $DPV_RATIO_HI) {
            $P->(code => 'DPV_RATIO_RANGE', severity => 'warning', item => $id, value => $r, unit => 'ratio',
                 message => sprintf('dry pipe valve %s: a differential trip ratio of %.2f:1 is outside %g:1 to %g:1; '
                                  . 'check it against the valve data', $id, $r, $DPV_RATIO_LO, $DPV_RATIO_HI));
        }
        $P->(code => 'DPV_TRIP_METHOD', item => $id,
             message => "dry pipe valve $id: give a trip ratio OR a trip pressure, not both")
            if defined $e->{trip_pressure};
    } elsif ($m eq 'TRIP') {
        my $t = $e->{trip_pressure};
        $P->(code => 'DPV_TRIP_PRESSURE', item => $id, value => defined $t ? $t / $up : undef, unit => $pu,
             message => "dry pipe valve $id: an air-side trip pressure must be more than zero")
            unless defined $t && $t > 0;
        # Above 700 kPa of air no dry system is run: a figure that high is a
        # unit mistaken (bar for kPa, kPa for psi), not a setting.
        $P->(code => 'DPV_TRIP_PRESSURE', item => $id, value => $t / $up, limit => 700 / $up, unit => $pu,
             message => sprintf('dry pipe valve %s: an air-side trip pressure of %.1f %s is higher than any dry '
                              . 'system is run at; check the pressure unit', $id, $t / $up, $pu))
            if defined $t && $t > 700;
        $P->(code => 'DPV_TRIP_METHOD', item => $id,
             message => "dry pipe valve $id: give a trip ratio OR a trip pressure, not both")
            if defined $e->{trip_ratio};
    } else {
        $P->(code => 'DPV_TRIP_METHOD', item => $id,
             message => "dry pipe valve $id: the trip method must be RATIO or TRIP");
    }
    $P->(code => 'DPV_ACCELERATOR', item => $id,
         message => "dry pipe valve $id: the accelerator must be ON or OFF")
        unless ($e->{accelerator} // '') =~ /^(ON|OFF)\z/;

    # Loss data.
    my $basis = $e->{loss} // 'NONE';
    my $src = $e->{loss_source} // '';
    if ($basis eq 'NONE') {
        my $d = $e->{db};
        $P->(code => 'DPV_NO_LOSS_DATA', item => $id,
             message => $d
                 ? "dry pipe valve $id: DATA_REQUIRED - the database record for the $d->{maker} $d->{model} DN$d->{dn} has "
                   . 'no usable pressure loss (neither a flow coefficient nor an equivalent length of a stated pipe)'
                   . (length($d->{note} // '') && $d->{note} ne 'DASH' ? ": $d->{note}" : '')
                   . ".  Give the manufacturer's flow/loss points or an equivalent length.  No loss is assumed."
                 : "dry pipe valve $id: DATA_REQUIRED - it has no pressure loss data: give the manufacturer's flow/loss "
                   . 'points or an equivalent length (EQL).  No loss is assumed.');
    } elsif ($src eq 'USER_FIXED') {
        # One loss at every flow.  A valve's loss rises with its flow, so a
        # constant is right only near the flow it was read at; and at no flow
        # it is a pressure difference across a valve passing nothing, which
        # no open valve holds.
        $P->(code => 'DPV_SIMPLIFIED_LOSS', severity => 'warning', item => $id,
             value => ($e->{fixed_loss} // 0) / $up, unit => $pu,
             message => sprintf('dry pipe valve %s: a constant loss of %.2f %s at every flow is a SIMPLIFICATION, not '
                              . 'the valve\'s characteristic; it holds only near the flow it was taken at.  Give the '
                              . 'manufacturer\'s flow/loss points, or the valve from the database', $id,
                                ($e->{fixed_loss} // 0) / $up, $pu));
        $P->(code => 'DPV_FIXED_NO_FLOW', item => $id, value => ($e->{fixed_loss} // 0) / $up, unit => $pu,
             message => sprintf('dry pipe valve %s carries no flow but is given a constant loss of %.2f %s: a pressure '
                              . 'difference across an open valve passing nothing is not physical', $id,
                                ($e->{fixed_loss} // 0) / $up, $pu))
            if abs($q) <= $QT && ($e->{fixed_loss} // 0) > 0;
        $P->(code => 'LOSS_CURVE_NEGATIVE', item => $id, message => "dry pipe valve $id: a negative constant loss")
            if ($e->{fixed_loss} // 0) < 0;
    } elsif ($basis eq 'EQL') {
        $P->(code => 'DPV_EQL', item => $id, value => $e->{eql}, unit => 'm',
             message => "dry pipe valve $id: an equivalent length must be more than zero")
            unless ($e->{eql} // 0) > 0;
        $P->(code => 'DPV_EQL_HOST', item => $id,
             message => "dry pipe valve $id: the pipe it is in was not found, so its equivalent length has no bore")
            unless $e->{host};
    } elsif ($basis eq 'CURVE') {
        loss_curve_checks($e, $q, $P, 'dry pipe valve', $uf, $fu, $D);
        # At no flow a tripped, open valve has no loss.  Below its first point
        # the curve is extended on its end slope, and that can go negative --
        # a valve ADDING pressure at low flow -- or stay well above zero.
        my $p0 = HardyCross::curve_eval($e->{curve}, 0);
        if ($p0 < -1e-9) {
            $P->(code => 'DPV_LOSS_AT_ZERO', item => $id, value => $p0 / $up, unit => $pu,
                 message => sprintf('dry pipe valve %s: its loss curve, extended below its first point, gives %.2f %s at '
                                  . 'no flow - a passive valve adding pressure.  Give a point at low flow', $id,
                                    $p0 / $up, $pu));
        } elsif ($p0 > 1e-6) {
            $P->(code => 'DPV_LOSS_AT_ZERO', severity => 'warning', item => $id, value => $p0 / $up, unit => $pu,
                 message => sprintf('dry pipe valve %s: its loss curve gives %.2f %s at no flow; a tripped, open valve '
                                  . 'has no loss when nothing flows.  Check the first point', $id, $p0 / $up, $pu));
        }
    } elsif ($basis eq 'DB' && (my $d = $e->{db})) {
        # A valve from the database: checked against what its data sheet
        # says of it.
        my $pin = gauge($net, $e->{n1});
        $P->(code => 'DPV_PRESSURE_RATING', item => $id, value => $pin / $up, limit => $d->{pmax_kpa} / $up, unit => $pu,
             message => sprintf('dry pipe valve %s (%s %s): %.1f %s at its inlet, above its rated working pressure of '
                              . '%.1f (%s)', $id, $d->{maker}, $d->{model}, $pin / $up, $pu, $d->{pmax_kpa} / $up, $d->{source}))
            if defined $d->{pmax_kpa} && $pin > $d->{pmax_kpa} + 1e-6;
        if (($e->{trip_mode} // '') eq 'RATIO' && defined $e->{trip_ratio}) {
            if (uc($d->{trip} // '') eq 'LOW') {
                $P->(code => 'DPV_RATIO_DB', severity => 'warning', item => $id, value => $e->{trip_ratio}, unit => 'ratio',
                     message => "dry pipe valve $id: the $d->{maker} $d->{model} is a low-pressure valve, set by its air "
                              . "pressure table, not a differential ratio ($d->{source})");
            } elsif (defined $d->{trip_ratio} && abs($e->{trip_ratio} - $d->{trip_ratio}) > 0.25) {
                $P->(code => 'DPV_RATIO_DB', severity => 'warning', item => $id, value => $e->{trip_ratio},
                     limit => $d->{trip_ratio}, unit => 'ratio',
                     message => sprintf('dry pipe valve %s: a trip ratio of %.2f:1 is given; the %s %s data sheet gives '
                                      . 'about %g:1 (%s)', $id, $e->{trip_ratio}, $d->{maker}, $d->{model},
                                        $d->{trip_ratio}, $d->{source}));
            }
        }
        $P->(code => 'DPV_LEGACY', severity => 'warning', item => $id,
             message => "dry pipe valve $id: the $d->{maker} $d->{model} is a legacy valve, no longer sold ($d->{source})")
            if uc($d->{status} // '') eq 'LEGACY';
        $P->(code => 'DPV_DATA_NOTE', severity => 'warning', item => $id,
             message => "dry pipe valve $id ($d->{maker} $d->{model} DN$d->{dn}): $d->{note}")
            if length($d->{note} // '') && $d->{note} ne 'DASH';
    }
    # The pressures either side: a dry pipe valve does not add pressure.
    my $dp = $net->{nodes}[ $e->{n1} ]{h} - $net->{nodes}[ $e->{n2} ]{h};
    $P->(code => 'DPV_GAIN', item => $id, value => $dp / $up, unit => $pu,
         message => sprintf('dry pipe valve %s: the pressure rises across it by %.2f %s', $id, -$dp / $up, $pu))
        if $q > $QT && $dp < -1e-6;
}

#------------------------------------------------------------------------------
# connectivity -- every operating demand reachable from a usable supply.
#
# Walked over the pipework only -- the solver's reference node is not a
# route, or every outlet would be "connected" to every supply through it --
# and over each element only in the direction it can pass water: a pipe,
# plate or fixed loss either way; a pump, backflow preventer, ratio valve or
# dry pipe valve from its inlet to its outlet only.  A pump shut on its check
# valve is no route at all, and nor is a supply shut on its own.
#
# A supply is usable when it is open and its pressure is not negative.  It
# used to need a pressure ABOVE zero, which left out a gravity tank: a supply
# at 0 kPa gauge (open to air) whose head is its elevation, the reference
# manual's own "WATER TANK 12 0".  Such a model was REJECTED as unreachable
# (found 11 November 2026, tools/test_check_valves.pl part 1).  A supply that
# truly gives nothing -- 0 kPa at the outlets' own level -- still delivers
# nothing in the solve, and its outlets fail the design.  A negative pressure
# is refused separately (SUPPLY_NEGATIVE, SUPPLY_EXHAUSTED).
#
# Nodes cut off from every supply by closed supply check valves are reported
# as SUPPLY_ISOLATED, by the design checks, not here: they are not a
# modelling fault but a supply that cannot reach them.
#
# An outlet that is not reachable can only be "fed" in a solve by water
# running backwards through another outlet, which is how one used to be
# reported as flowing.
#------------------------------------------------------------------------------
my %ONE_WAY = map { $_ => 1 } qw(PUMP BFP RATIO DPV);

sub connectivity {
    my ($net, $P) = @_;
    my @el = grep { !$_->{closed} } @{ $net->{elems} }[1 .. $#{ $net->{elems} }];
    my (@adj, @start);
    for my $e (@el) {
        my $k = $e->{kind};
        if ($k =~ /^SUPPLY_/) {
            my $p = $k eq 'SUPPLY_STATIC' ? $e->{pstat} : HardyCross::curve_eval($e->{curve}, 0);
            push @start, $e->{n2} if ($p // 0) >= 0;
            next;
        }
        next if $k eq 'DISCHARGE';
        push @{ $adj[ $e->{n1} ] }, $e->{n2};
        push @{ $adj[ $e->{n2} ] }, $e->{n1} unless $ONE_WAY{$k};
    }
    my %seen = map { $_ => 1 } @start;
    my @q = @start;
    while (@q) {
        my $v = shift @q;
        for my $w (@{ $adj[$v] || [] }) { push @q, $w unless $seen{$w}++ }
    }
    my @demand = ((map { [ $_->{id}, $_->{n1}, lc($_->{otype} // 'outlet') ] }
                   grep { $_->{kind} eq 'DISCHARGE' } @el),
                  (map { [ $_->{id}, $_->{n1}, 'fixed flow' ] }
                   grep { ($_->{qreq} // 0) > 0 } @{ $net->{fixed} || [] }));
    my %dead = map { $_ => 1 } @{ ($net->{supply_isolated} || {})->{index} || [] };
    for my $d (@demand) {
        next if $seen{ $d->[1] } || $dead{ $d->[1] };
        $P->(code => 'DEMAND_UNCONNECTED', item => $d->[0],
             message => sprintf('%s %s at node %s cannot be reached from any water supply through the pipework '
                              . 'in the direction water can flow', $d->[2], $d->[0], $net->{nodes}[ $d->[1] ]{id}));
    }
}

#==============================================================================
# DESIGN
#==============================================================================
sub design {
    my ($net, $add, %o) = @_;
    my ($uf, $up) = @{$net}{qw(f_flow f_pres)};
    my ($fu, $pu) = ($net->{u_flow}, $net->{u_pres});
    my $o = $net->{opts};
    my $D = sub { my %r = @_; $add->(category => 'design', %r) };
    my @el = grep { !$_->{closed} } @{ $net->{elems} }[1 .. $#{ $net->{elems} }];
    my %what = (SPRINKLER => 'sprinkler', HYDRANT => 'hydrant', HOSEREEL => 'hose reel');

    # Loss of supply.  Outlets and fixed demands that no open supply can
    # reach, because the check valves of every supply that could have fed
    # them are shut (HardyCross::isolate_unsupplied).  The network there
    # stands empty: no flow, no pressure.  That is a valid hydraulic state
    # and a design that fails, so it is a design finding -- NONCOMPLIANT --
    # and not a numerical one: the solve did what it should.  It is never an
    # ACCEPTED result, and no water is assumed to reach these outlets.
    if (my $iso = $net->{supply_isolated}) {
        my @out = @{ $iso->{outlets} || [] };
        $D->(code => 'SUPPLY_ISOLATED', item => join(' ', @out),
             message => sprintf('LOSS OF SUPPLY: the check valve%s of %s %s shut and no other supply can reach '
                              . 'node%s %s, so %s receive%s no water', @{ $iso->{supplies} } > 1 ? 's' : '',
                                join(', ', @{ $iso->{supplies} }), @{ $iso->{supplies} } > 1 ? 'are' : 'is',
                                @{ $iso->{nodes} } > 1 ? 's' : '', join(', ', @{ $iso->{nodes} }),
                                @out ? join(', ', @out) : 'no outlet there', @out == 1 ? 's' : ''))
            if @{ $iso->{nodes} || [] };
    }

    # Every outlet: its flow (signed: a backward flow is never a pass) and the
    # pressure it discharges on, each against its requirement.
    for my $e (grep { $_->{kind} eq 'DISCHARGE' } @el) {
        my $w = $what{ $e->{otype} // '' } // 'outlet';
        my $p = HardyCross::outlet_pressure($net, $e);
        my @why;
        push @why, sprintf('flow %.2f %s against %.2f required', $e->{q} / $uf, $fu, $e->{qreq} / $uf)
            if $e->{q} < $e->{qreq} - 1e-6;
        push @why, sprintf('pressure %.2f %s against %.2f required', $p / $up, $pu, $e->{preq} / $up)
            if $p < $e->{preq} - 1e-6;
        $D->(code => 'OUTLET_REQUIREMENT', item => $e->{id}, value => ($p - $e->{preq}) / $up, limit => 0,
             unit => $pu, outlet_type => $e->{otype},
             message => "$w $e->{id} does not meet its requirement: " . join('; ', @why))
            if @why;
    }
    for my $f (grep { defined $_->{preq} } @{ $net->{fixed} || [] }) {
        my $p = gauge($net, $f->{n1});
        $D->(code => 'FIXED_FLOW_PRESSURE', item => $f->{id}, value => ($p - $f->{preq}) / $up, limit => 0,
             unit => $pu,
             message => sprintf('fixed flow %s: %.2f %s at its node against the %.2f it needs', $f->{id},
                                $p / $up, $pu, $f->{preq} / $up))
            if $p < $f->{preq} - 1e-6;
    }

    # The velocity limit.  Set in the model (OPTION VEL_LIMIT), it is a
    # design requirement and a pipe over it fails the design; left at the
    # program's default of 6 m/s it is advice, and a warning.
    my $vl = $o->{vel_limit} // 6;
    my @fast = grep { abs(HardyCross::pipe_velocity($_->{q}, $_->{dia})) > $vl } grep { $_->{kind} eq 'PIPE' } @el;
    for my $e (@fast) {
        my $vel = abs HardyCross::pipe_velocity($e->{q}, $e->{dia});
        $D->(code => 'VELOCITY_LIMIT', severity => $o->{vel_limit_set} ? 'error' : 'warning', item => $e->{id},
             value => $vel, limit => $vl, unit => 'm/s',
             message => sprintf('pipe %s: %.2f m/s over the %s velocity limit of %g m/s', $e->{id}, $vel,
                                $o->{vel_limit_set} ? 'design' : 'default', $vl));
    }

    # Pump duties (PUMPDUTY): the curve against the rated duty.
    if (grep { $_->{kind} eq 'PUMP' } @el) {
        require HardyCross::PumpCheck;
        for my $p (grep { $_->{duty} && !$_->{ok} } @{ HardyCross::PumpCheck::check($net) }) {
            $D->(code => 'PUMP_DUTY', item => $p->{id}, value => $p->{at_duty}{p} / $up, limit => $p->{duty}[1] / $up,
                 unit => $pu,
                 message => sprintf('pump %s: %s', $p->{id},
                     !$p->{at_duty}{ok} ? sprintf('its curve gives %.1f %s at its duty flow against a duty of %.1f',
                                                  $p->{at_duty}{p} / $up, $pu, $p->{duty}[1] / $up)
                                        : sprintf('shut-off %.1f %s is above 140 %% of its duty pressure',
                                                  $p->{shutoff} / $up, $pu)));
        }
    }

    # The supply against the demand, with the margin the model asks for
    # (OPTION SUPPLY_MARGIN, a pressure; 0 unless given).
    my $need = $o->{supply_margin} // 0;
    my $da = $o{assessment} // {};
    if (my $dm = $o{demand}) {
        if (($dm->{status} // '') eq 'UNRESOLVED') {
            # The search itself failed -- not a supply found too weak.
            $D->(code => 'SUPPLY_DEMAND_UNRESOLVED', item => undef,
                 message => "the supply's adequacy could not be demonstrated: $dm->{reason}");
            %$da = (status => 'UNRESOLVED', basis => 'DEMAND POINT, one supply', message => $dm->{reason});
        } elsif ($dm->{reason}) {
            # Not worked out: a single demand point is not defined (several
            # supplies) or could not be found.  Several supplies are judged on
            # the supply schedule below; otherwise this is a finding.
            # "no supply pressure up to ... satisfies every outlet" is a
            # failure: no pressure at all meets the demand.
            my $na = $dm->{reason} =~ /^(\d+ supplies|the model has no supply|the model has no outlet with a required pressure)/;
            $D->(code => 'DEMAND_NOT_FOUND', item => undef, message => "the demand point was not found: $dm->{reason}")
                unless $na;
            %$da = (status => 'INADEQUATE', basis => 'DEMAND POINT, one supply', message => $dm->{reason}) unless $na;
        } elsif ($dm->{margin} < $need - 1e-6) {
            $D->(code => 'SUPPLY_ADEQUACY', item => $dm->{supply}{id}, value => $dm->{margin} / $up,
                 limit => $need / $up, unit => $pu,
                 message => sprintf('supply %s: %.1f %s available at the demand flow against %.1f needed, a margin '
                                  . 'of %.1f %s where %.1f is required', $dm->{supply}{id}, $dm->{p_avail} / $up, $pu,
                                    $dm->{p_demand} / $up, $dm->{margin} / $up, $pu, $need / $up));
            %$da = (status => 'INADEQUATE', basis => 'DEMAND POINT, one supply',
                    message => sprintf('margin %.1f %s against %.1f required', $dm->{margin} / $up, $pu, $need / $up));
        } else {
            %$da = (status => 'DEMONSTRATED', basis => 'DEMAND POINT, one supply',
                    message => sprintf('margin %.1f %s against %.1f required', $dm->{margin} / $up, $pu, $need / $up));
        }
    }
    if (my $s = $o{supplies}) {
        # The joint demand -- every supply at once, from one solve -- is what
        # the supplies' adequacy is judged on.  It must have been FOUND, in a
        # valid solve, and its margin be at least the one asked for.  A
        # search that failed is not a supply found inadequate, and is not
        # passed over either: as released a joint demand that could not be
        # found was ignored, and one whose solve was REJECTED was used.
        my $j = $s->{joint};
        my $st = !$j ? 'NOT_ASSESSED' : $j->{status} // ($j->{reason} ? 'UNRESOLVED' : 'FOUND');
        my $basis = sprintf('JOINT DEMAND on the %s basis (an assumption)', $j && $j->{basis} ? $j->{basis} : '-');
        if ($st eq 'UNRESOLVED') {
            $D->(code => 'SUPPLY_DEMAND_UNRESOLVED', item => 'ALL',
                 message => "the supplies' joint adequacy could not be demonstrated: $j->{reason}");
            %$da = (status => 'UNRESOLVED', basis => $basis, message => $j->{reason});
        } elsif ($st eq 'INADEQUATE') {
            $D->(code => 'SUPPLY_ADEQUACY', item => 'ALL',
                 message => "the supplies together cannot meet the demand: $j->{reason}");
            %$da = (status => 'INADEQUATE', basis => $basis, message => $j->{reason});
        } elsif ($st eq 'NOT_LIMITING') {
            %$da = (status => 'DEMONSTRATED', basis => $basis, message => $j->{reason});
        } elsif ($st eq 'FOUND' && $j->{margin} < $need - 1e-6) {
            $D->(code => 'SUPPLY_ADEQUACY', item => 'ALL', value => $j->{margin} / $up, limit => $need / $up,
                 unit => $pu,
                 message => sprintf('the supplies together, on the %s basis, have %.1f %s %s at the joint demand '
                                  . 'where %.1f is required', $j->{basis_name}, abs($j->{margin}) / $up, $pu,
                                    $j->{margin} >= 0 ? 'to spare' : 'too little', $need / $up));
            %$da = (status => 'INADEQUATE', basis => $basis,
                    message => sprintf('margin %.1f %s against %.1f required', $j->{margin} / $up, $pu, $need / $up));
        } elsif ($st eq 'FOUND') {
            %$da = (status => 'DEMONSTRATED', basis => $basis,
                    message => sprintf('margin %.1f %s against %.1f required', $j->{margin} / $up, $pu, $need / $up));
        }
        for my $sc (@{ $s->{scenarios} || [] }) {
            next unless $sc->{required};
            $D->(code => 'SCENARIO', item => $sc->{name},
                 message => "required supply scenario $sc->{name} ($sc->{description}): $sc->{acceptance}")
                unless $sc->{acceptance} eq 'ACCEPTED';
        }
    }
}

#------------------------------------------------------------------------------
# dry_time_checks -- what the trip time estimate (HardyCross::DryTime) finds
# about a dry pipe valve's setting.  The estimates themselves decide nothing;
# a set air pressure at or below the trip pressure is a valve that cannot be
# set, which is a physical failure of the model.
#------------------------------------------------------------------------------
sub dry_time_checks {
    my ($net, $add, $dry) = @_;
    my $up = $net->{f_pres};
    for my $d (@$dry) {
        if ($d->{error}) {
            $add->(category => 'physical', code => 'DPV_NOT_DRY', item => $d->{id},
                   message => "dry pipe valve $d->{id}: $d->{error}");
            next;
        }
        my $t = $d->{trip} or next;
        $add->(category => 'physical', code => 'DPV_AIR_BELOW_TRIP', item => $d->{id},
               value => ($t->{air_gauge} // 0) / $up, limit => ($t->{trip_gauge} // 0) / $up, unit => $net->{u_pres},
               message => "dry pipe valve $d->{id}: $t->{reason}")
            if ($t->{status} // '') eq 'ERROR';
        $add->(category => 'physical', code => 'DPV_TRIP_NOT_CHOKED', severity => 'warning', item => $d->{id},
               message => sprintf('dry pipe valve %s: the trip pressure, %.1f %s, is below the 1.893 atmospheres at '
                                . 'which flow through the orifice stops being choked; the trip time formula assumes '
                                . 'choked flow, and its estimate is less reliable', $d->{id}, $t->{trip_gauge} / $up,
                                  $net->{u_pres}))
            if ($t->{status} // '') eq 'ESTIMATE' && !$t->{choked};
    }
}

#------------------------------------------------------------------------------
# assess -- THE validated result of a solved network: the one the report,
# the PDF, the JSON and the editor all print, so they cannot disagree.
#
# Worked out once and kept on the network ($net->{assessment}); solve_model
# clears it, so a network solved again is assessed again.  Holds
#   ok          solve_model's result
#   demand      the single-supply demand point (HardyCross::Demand), or the
#               reason there is none
#   supplies    the multiple-supply schedule (HardyCross::Supplies), or undef
#               with one supply
#   validation  validate()'s result, with the demand and the supplies taken
#               into the design checks
#
# %o: demand => 0 leaves out the demand point and the multiple-supply
# demands, which re-solve the network many times (the JSON's opt-out).
#------------------------------------------------------------------------------
sub assess {
    my ($net, $ok, %o) = @_;
    my $want_demand = $o{demand} // 1;
    my $a = $net->{assessment};
    return $a if $a && $a->{ok} == ($ok ? 1 : 0) && ($a->{with_demand} || !$want_demand);
    require HardyCross::Demand;
    require HardyCross::Supplies;
    my ($dm, $sup);
    if ($ok && $want_demand) {
        $dm  = HardyCross::Demand::demand_point($net);
        $sup = HardyCross::Supplies::analyse($net, $ok);
    } elsif (HardyCross::Demand::supplies($net) > 1) {
        # The operating schedule needs no re-solve, so it is given even
        # without the demands, and for an unconverged solve -- marked so.
        $sup = HardyCross::Supplies::analyse($net, 0);
    }
    # The estimated trip and transit times of each dry pipe valve
    # (HardyCross::DryTime), on a converged solve: the transit at the demand
    # point's flows where there is one, else the operating point's.
    my $dry;
    if ($ok && grep { $_->{kind} eq 'DPV' } @{ $net->{elems} }[1 .. $#{ $net->{elems} }]) {
        require HardyCross::DryTime;
        my $at_demand = $dm && !$dm->{reason} && $dm->{net};
        $dry = HardyCross::DryTime::analyse($net, $at_demand ? ($dm->{net}, 'demand point') : ($net, 'operating point'));
    }
    my $v = validate($net, $ok, ($dm ? (demand => $dm) : ()), ($sup ? (supplies => $sup) : ()), ($dry ? (dry => $dry) : ()));
    return $net->{assessment} = { ok => $ok ? 1 : 0, with_demand => $want_demand && $ok ? 1 : 0,
                                  demand => $dm, supplies => $sup, dry => $dry, validation => $v };
}

#------------------------------------------------------------------------------
# summary_lines -- the validation as the lines a report or a caller prints:
# the acceptance, the three results, the residuals, then each error.
#------------------------------------------------------------------------------
my %SAY = (
    ACCEPTED      => 'ACCEPTED - numerically valid, physically valid and compliant with the design',
    NONCOMPLIANT  => 'NONCOMPLIANT - numerically and physically valid, but the design is not met or not demonstrated',
    REJECTED      => 'REJECTED - the results are not a valid solution of the model',
    INDETERMINATE => 'INDETERMINATE - no settled, converged solution; the results must not be used',
);
sub acceptance_text { $SAY{ shift() } // 'UNKNOWN' }

1;
