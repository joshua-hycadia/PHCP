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
#               water in; curves the right way up; plates that fit their pipe
#               and meet their duty; every operating demand reachable from a
#               supply; no pressure below vapour pressure
#   design      the answer meets the design: every outlet's flow and pressure,
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
    design($net, $add, %o);

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
               message => 'the device states (orifice plates, pump check valves, ratio valves, velocity '
                        . 'pressures) had not settled when the solve stopped');
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
    my $ctol = 1e-6 * ($qscale > 1 ? $qscale : 1);
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
    $v->{residuals}{loop} = { value => $lmax / $up, tolerance => $tol_loop / $up, unit => $net->{u_pres},
                              at => defined $lat ? "loop $lat" : undef, pass => $lmax <= $tol_loop ? 1 : 0 };
    $add->(code => 'LOOP_CLOSURE', category => 'numerical', item => "loop $lat", value => $lmax / $up,
           limit => $tol_loop / $up, unit => $net->{u_pres},
           message => sprintf('loop %d does not close: %.6g %s against a tolerance of %g',
                              $lat, $lmax / $up, $net->{u_pres}, $tol_loop / $up))
        if $lmax > $tol_loop && !$v->{indeterminate};

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
    $v->{residuals}{element} = { value => $emax / $up, tolerance => $tol_loop / $up, unit => $net->{u_pres},
                                 at => $eat, pass => $emax <= $tol_loop ? 1 : 0 };
    $add->(code => 'ELEMENT_EQUATION', category => 'numerical', item => $eat, value => $emax / $up,
           limit => $tol_loop / $up, unit => $net->{u_pres},
           message => sprintf('element %s: the pressure across it differs from its own equation by %.6g %s',
                              $eat, $emax / $up, $net->{u_pres}))
        if $emax > $tol_loop && !$v->{indeterminate};
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

    for my $e (@el) {
        my $k = $e->{kind};
        my $q = $e->{q} // 0;

        #------------------------------------------------------------ supplies
        if ($k =~ /^SUPPLY_/) {
            if ($q < -$QT) {
                $P->(code => 'SUPPLY_REVERSE', item => $e->{id}, value => $q / $uf, unit => $fu,
                     message => sprintf('water supply %s takes water IN, %.1f %s: a supply does not accept '
                                      . 'flow from the network', $e->{id}, -$q / $uf, $fu));
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
            if (defined $e->{dp_target}) {
                # The plate is sized on one solve and the network solved again
                # with it, so its final drop differs from the target by the
                # rounding of the bore and the flow moving.  Stated, so it can
                # be checked; not a failure.
                my $dp = HardyCross::orifice_dp(abs $q, $b, $d, $e->{cd});
                $e->{dp_final} = $dp;
                $P->(code => 'ORIFICE_DEVIATION', severity => 'info', item => $e->{id},
                     value => $dp / $up, limit => $e->{dp_target} / $up, unit => $pu,
                     message => sprintf('orifice plate %s: final drop %.2f %s against a target of %.2f (%+.1f %%), '
                                      . 'bore %.2f mm rounded from %.3f mm', $e->{id}, $dp / $up, $pu,
                                        $e->{dp_target} / $up,
                                        $e->{dp_target} > 0 ? 100 * ($dp - $e->{dp_target}) / $e->{dp_target} : 0,
                                        $b, $e->{bore_exact} // $b));
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
            loss_curve_checks($e, $q, $P, 'loss device', $uf, $fu);
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
            dpv_checks($net, $e, $P);
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
sub loss_curve_checks {
    my ($e, $q, $P, $what, $uf, $fu) = @_;
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
}

#------------------------------------------------------------------------------
# dpv_checks -- a dry pipe valve, as the steady-state solve takes it: tripped
# and fully open.  Its configuration is checked as well as its hydraulics,
# since a trip setting that cannot be right is a model error even though it
# does not change a steady-state number.
#------------------------------------------------------------------------------
sub dpv_checks {
    my ($net, $e, $P) = @_;
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
    if ($basis eq 'NONE') {
        $P->(code => 'DPV_NO_LOSS_DATA', item => $id,
             message => "dry pipe valve $id has no pressure loss data: give the manufacturer's flow/loss points "
                      . 'or an equivalent length (EQL).  No loss is assumed.');
    } elsif ($basis eq 'EQL') {
        $P->(code => 'DPV_EQL', item => $id, value => $e->{eql}, unit => 'm',
             message => "dry pipe valve $id: an equivalent length must be more than zero")
            unless ($e->{eql} // 0) > 0;
        $P->(code => 'DPV_EQL_HOST', item => $id,
             message => "dry pipe valve $id: the pipe it is in was not found, so its equivalent length has no bore")
            unless $e->{host};
    } elsif ($basis eq 'CURVE') {
        loss_curve_checks($e, $q, $P, 'dry pipe valve', $uf, $fu);
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
# valve is no route at all.  A supply is usable when it can give pressure.
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
            push @start, $e->{n2} if ($p // 0) > 0;
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
    for my $d (@demand) {
        next if $seen{ $d->[1] };
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
    if (my $dm = $o{demand}) {
        if ($dm->{reason}) {
            # Not worked out: a single demand point is not defined (several
            # supplies) or could not be found.  Several supplies are judged on
            # the supply schedule below; otherwise this is a finding.
            # "no supply pressure up to ... satisfies every outlet" is a
            # failure: no pressure at all meets the demand.
            $D->(code => 'DEMAND_NOT_FOUND', item => undef, message => "the demand point was not found: $dm->{reason}")
                unless $dm->{reason} =~ /^(\d+ supplies|the model has no supply|the model has no outlet with a required pressure)/;
        } elsif ($dm->{margin} < $need - 1e-6) {
            $D->(code => 'SUPPLY_ADEQUACY', item => $dm->{supply}{id}, value => $dm->{margin} / $up,
                 limit => $need / $up, unit => $pu,
                 message => sprintf('supply %s: %.1f %s available at the demand flow against %.1f needed, a margin '
                                  . 'of %.1f %s where %.1f is required', $dm->{supply}{id}, $dm->{p_avail} / $up, $pu,
                                    $dm->{p_demand} / $up, $dm->{margin} / $up, $pu, $need / $up));
        }
    }
    if (my $s = $o{supplies}) {
        my $j = $s->{joint};
        if ($j && !$j->{reason} && $j->{margin} < $need - 1e-6) {
            $D->(code => 'SUPPLY_ADEQUACY', item => 'ALL', value => $j->{margin} / $up, limit => $need / $up,
                 unit => $pu,
                 message => sprintf('the supplies together, on the %s basis, have %.1f %s %s at the joint demand '
                                  . 'where %.1f is required', $j->{basis_name}, abs($j->{margin}) / $up, $pu,
                                    $j->{margin} >= 0 ? 'to spare' : 'too little', $need / $up));
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
    my $v = validate($net, $ok, ($dm ? (demand => $dm) : ()), ($sup ? (supplies => $sup) : ()));
    return $net->{assessment} = { ok => $ok ? 1 : 0, with_demand => $want_demand && $ok ? 1 : 0,
                                  demand => $dm, supplies => $sup, validation => $v };
}

#------------------------------------------------------------------------------
# summary_lines -- the validation as the lines a report or a caller prints:
# the acceptance, the three results, the residuals, then each error.
#------------------------------------------------------------------------------
my %SAY = (
    ACCEPTED      => 'ACCEPTED - numerically valid, physically valid and compliant with the design',
    NONCOMPLIANT  => 'NONCOMPLIANT - numerically and physically valid, but the design is not met',
    REJECTED      => 'REJECTED - the results are not a valid solution of the model',
    INDETERMINATE => 'INDETERMINATE - no settled, converged solution; the results must not be used',
);
sub acceptance_text { $SAY{ shift() } // 'UNKNOWN' }

1;
