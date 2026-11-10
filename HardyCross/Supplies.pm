#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# HardyCross/Supplies.pm -- several water supplies, each on its own terms.
#
# A network fed from more than one place has no single "demand": how much
# each supply must give depends on what the others do.  So the question is
# asked four ways, each a full Hardy Cross solve (or a bisection of them) of
# the whole network, and each labelled with what it assumes:
#
#   OPERATING     every supply on its own curve or static pressure, as
#                 modelled: each one's flow and pressure, its share of the
#                 net demand, and whether any runs backwards.
#   CONDITIONAL   for each supply in turn, the least pressure (and the flow
#                 that goes with it) at its connection for the governing
#                 outlet to receive exactly its minimum, WITH EVERY OTHER
#                 SUPPLY AS MODELLED.  It is conditional on the others: the
#                 conditional minima of two supplies are NOT a condition they
#                 can both be at at once, and are never added.
#   JOINT         one solve in which every supply is reduced together, on a
#                 stated basis, until the governing outlet receives exactly
#                 its minimum and every other outlet at least its own:
#                   DERATE  every supply's pressure lowered by the same
#                           amount, D, at every flow (the default)
#                   SCALE   every supply's pressure multiplied by the same
#                           factor, F
#                 Each supply keeps its own curve shape and its own
#                 connection; their pressures are never assumed equal.  Every
#                 supply's flow and pressure at the joint demand come from
#                 that one solve.  D (or the pressure F gives up) is the
#                 margin the supplies have together, on that basis.  Another
#                 basis gives another split: the basis is an assumption, and
#                 the report says so.
#   SCENARIOS     the network solved and validated with supplies out of
#                 service or reduced: every supply alone and every supply
#                 out in turn (OPTION SUPPLY_SCENARIOS, ON by default), and
#                 each SCENARIO line.  A SCENARIO line is a requirement: one
#                 that is not ACCEPTED fails the design.  The automatic ones
#                 are for information.
#
# With one supply the conditional and the joint demand are the same thing --
# the demand point of HardyCross::Demand -- and this module is not used.
#
# All values are in the engine's internal units (L/min, kPa); the report and
# the JSON convert.  A supply's pressure is its gauge pressure at its own
# elevation, as the supply is modelled.
#==============================================================================
package HardyCross::Supplies;

use strict;
use warnings;
use HardyCross;
use HardyCross::Demand;
use HardyCross::Validate;

my $QT = $HardyCross::Q_TINY;

# The pressure to which every bisection here is taken, kPa: the same as the
# demand point's.
our $P_TOL = 0.01;

sub supplies { return HardyCross::Demand::supplies(shift) }

# reread -- the model read again from its text, unsolved.
sub reread {
    my $text = shift;
    require HardyCross::Phc;
    return eval { HardyCross::Phc::read_string($text) };
}

# by_id -- a supply of a network by its id.
sub by_id {
    my ($net, $id) = @_;
    my ($s) = grep { $_->{id} eq $id } supplies($net);
    return $s;
}

# shifted -- a supply curve with every pressure changed by $fn, refitted.
sub shifted {
    my ($c, $fn) = @_;
    return HardyCross::fit_curve({ q => [ @{ $c->{q} } ], p => [ map { $fn->($_) } @{ $c->{p} } ] }, 0);
}

# avail -- one supply's pressure at a flow, as modelled.
sub avail { return HardyCross::Demand::avail_of(@_) }

#------------------------------------------------------------------------------
# solve_variant -- (ok, network, margin, governing): the model re-read, changed
# by $mutate (given the fresh network), solved, and its least outlet margin.
# margin is undef when the solve does not converge and settle: a trial with no
# answer is never treated as one that passes.
#------------------------------------------------------------------------------
sub solve_variant {
    my ($text, $mutate) = @_;
    my $net = reread($text) or return;
    $mutate->($net) if $mutate;
    my $ok = eval { HardyCross::solve_model($net) };
    return (0, $net) unless $ok;
    my ($go, $m) = HardyCross::Demand::governing_outlet($net);
    return (1, $net, $m, $go);
}

# trial_of -- a variant solved and classified (HardyCross::Demand::trial):
# PASS, SHORT, INVALID, NOT_CONVERGED or NO_OUTLET.
sub trial_of {
    my ($ok, $net) = solve_variant(@_);
    return HardyCross::Demand::trial($ok, $net);
}

# state_of -- what a supply is doing, in one word, for every schedule here
# and in the report and the JSON:
#
#   OUT_OF_SERVICE  taken out by a scenario (SCENARIO ... 0)
#   ISOLATED        shut on its check valve, and nothing else supplies its part
#                   of the network: that part has lost its supply
#   CLOSED          shut on its check valve (NRV): the network stands above
#                   what it can give, and the other supplies carry the load
#   REVERSE         taking water in -- impossible, and refused by
#                   HardyCross::Validate (SUPPLY_REVERSE)
#   IDLE            open, giving no flow
#   DELIVERING      open, giving water
#
# CLOSED is a valid operating state, not a failure: a supply whose valve has
# shut is neither "too weak" nor an invalid trial (tools/test_check_valves.pl).
sub state_of {
    my $s = shift;
    return 'OUT_OF_SERVICE' if $s->{out_of_service};
    return 'ISOLATED'       if $s->{isolated};
    return 'CLOSED'         if $s->{closed};
    return $s->{q} < -$QT ? 'REVERSE' : $s->{q} <= $QT ? 'IDLE' : 'DELIVERING';
}

# valve_of -- a supply's check valve for the schedules: { cv, crack,
# crack_given, model, loss } with loss the valve's pressure loss at the
# supply's flow (kPa, 0 when shut), or undef for a supply without one.
sub valve_of {
    my $s = shift;
    my $v = $s->{nrv} or return undef;
    my ($loss) = $s->{closed} ? (0) : HardyCross::check_valve_loss($s, $s->{q});
    return { %$v, loss => $loss, switches => $s->{nflips} // 0 };
}

# reverse_text -- the supplies of a trial that take water in, in words.
sub reverse_text {
    my $t = shift;
    return '' unless $t && $t->{net};
    my @r = grep { !$_->{closed} && $_->{q} < -$QT } supplies($t->{net});
    return join ', ', map { sprintf('supply %s takes %.3g L/min in', $_->{id}, -$_->{q}) } @r;
}

#------------------------------------------------------------------------------
# operating -- each supply as the modelled network runs it.
#------------------------------------------------------------------------------
sub operating {
    my $net = shift;
    my @sup = supplies($net);
    my $qin = 0;
    $qin += $_->{q} > 0 ? $_->{q} : 0 for @sup;
    my @rows;
    for my $s (@sup) {
        my $q = $s->{q};
        my $p = HardyCross::Demand::gauge($net, $s->{n2});
        push @rows, {
            id => $s->{id}, node => $net->{nodes}[ $s->{n2} ]{id}, z => $s->{z} // 0,
            kind => $s->{kind} eq 'SUPPLY_STATIC' ? 'STATIC' : 'CURVE',
            flow => $q, pressure => $p,
            # The pressure the supply itself gives at that flow, at its own
            # elevation: its static, or its curve.
            supply_pressure => avail($s, $q > 0 ? $q : 0),
            share => $qin > 0 && $q > 0 ? 100 * $q / $qin : 0,
            status => state_of($s),
            check_valve => valve_of($s),
            extrapolated => $s->{curve} && HardyCross::Validate::extrapolated($s->{curve}, $q) ? 1 : 0,
        };
    }
    return \@rows;
}

#------------------------------------------------------------------------------
# conditional -- the least pressure supply $sid needs, the others as modelled.
#
# The supply is replaced by a static pressure p at its own node and
# elevation (HardyCross::Demand::solve_at) and p is bisected.  Two things
# bound it:
#
#   - Below the pressure p0 at which the supply gives no flow at all, the
#     others push water INTO it.  No supply does that, so p0 is the lowest
#     pressure considered.  If the outlets are all met at p0 the supply is
#     NOT REQUIRED: the others meet the demand with it giving nothing.
#   - Every trial is classified (HardyCross::Demand::trial).  Only a valid
#     SHORT trial is "below the minimum"; one that is physically invalid
#     (another supply taking water in, a pump backwards) or that does not
#     converge is not, and a minimum found against one is UNRESOLVED.
#
# Returns { id, basis CONDITIONAL, status (REQUIRED, NOT_REQUIRED,
# INADEQUATE, UNRESOLVED), pressure, flow, available, margin, governing,
# others_reverse => [ids], acceptance, findings, reason }.
#------------------------------------------------------------------------------
sub conditional {
    my ($net, $sid) = @_;
    my $text = $net->{source_text}
        or return { id => $sid, basis => 'CONDITIONAL', status => 'UNRESOLVED', reason => 'no model text' };
    my $orig = by_id($net, $sid);
    my $at = sub {
        my $p = shift;
        my $t = HardyCross::Demand::trial(HardyCross::Demand::solve_at($text, $sid, $p));
        $t->{q} = by_id($t->{net}, $sid)->{q} if $t->{net} && by_id($t->{net}, $sid);
        return $t;
    };
    my $solved = sub { my $t = shift; $t && $t->{status} ne 'NOT_CONVERGED' && defined $t->{q} };
    my $no = sub { my ($st, $why) = @_; { id => $sid, basis => 'CONDITIONAL', status => $st, reason => $why } };

    # p0: the supply's flow rises with its pressure; find where it is zero.
    # Any converged solve tells where the flow is; validity is asked below.
    my $p_now = HardyCross::Demand::gauge($net, $orig->{n2});
    my ($lo, $hi) = (0, $p_now > 1 ? $p_now : 100);
    my $t0 = $at->(0);
    my $p0 = 0;
    unless ($solved->($t0) && $t0->{q} >= -$QT) {
        my $th = $at->($hi);
        for (1 .. 30) { last if $solved->($th) && $th->{q} > 0; $hi *= 1.5; $th = $at->($hi) }
        return $no->('UNRESOLVED', 'no pressure was found at which this supply delivers water in a converged solve')
            unless $solved->($th) && $th->{q} > 0;
        for (1 .. 80) {
            my $mid = 0.5 * ($lo + $hi);
            my $t = $at->($mid);
            if ($solved->($t) && $t->{q} > 0) { $hi = $mid } else { $lo = $mid }
            last if $hi - $lo < $P_TOL;
        }
        $p0 = $hi;
    }
    my $t_p0 = $at->($p0);
    return result_of($net, $sid, 'NOT_REQUIRED', $p0, $t_p0) if $t_p0->{status} eq 'PASS';

    # Bisect between p0 and a pressure that satisfies every outlet.
    ($lo, $hi) = ($p0, $p_now > $p0 ? $p_now : $p0 + 100);
    my $th = $at->($hi);
    my @seen = ($th);
    for (1 .. 30) { last if $th->{status} eq 'PASS'; $hi *= 1.5; push @seen, $th = $at->($hi) }
    unless ($th->{status} eq 'PASS') {
        my $st = HardyCross::Demand::bracket_status(@seen);
        my ($odd) = grep { $_->{status} ne 'SHORT' } @seen;
        return $no->($st, $st eq 'INADEQUATE'
            ? sprintf('no pressure at this supply up to %.0f kPa satisfies every outlet', $hi)
            : sprintf('no pressure at this supply up to %.0f kPa gave a valid solve meeting every outlet: %s', $hi,
                      HardyCross::Demand::trial_why($odd)));
    }
    my $tb = $t_p0;
    for (1 .. 80) {
        my $mid = 0.5 * ($lo + $hi);
        my $t = $at->($mid);
        if ($t->{status} eq 'PASS') { ($hi, $th) = ($mid, $t) } else { ($lo, $tb) = ($mid, $t) }
        last if $hi - $lo < $P_TOL;
    }
    unless (HardyCross::Demand::search_status($tb) eq 'FOUND') {
        return $no->('UNRESOLVED', sprintf('below %.2f kPa at this supply the trial solves are %s (%s): its minimum '
                                         . 'could not be found', $hi, $tb->{status}, reverse_text($tb)
                                           || HardyCross::Demand::trial_why($tb)));
    }
    return result_of($net, $sid, 'REQUIRED', $hi, $th);
}

sub result_of {
    my ($net, $sid, $status, $p, $t) = @_;
    my $orig = by_id($net, $sid);
    my $q = $t->{q} > 0 ? $t->{q} : 0;
    my $a = avail($orig, $q);
    my $v = HardyCross::Validate::validate($t->{net}, 1);
    return {
        id => $sid, basis => 'CONDITIONAL', status => $status, pressure => $p, flow => $q,
        available => $a, margin => $a - $p,
        extrapolated => $orig->{curve} && HardyCross::Validate::extrapolated($orig->{curve}, $q) ? 1 : 0,
        governing => $t->{go} ? $t->{go}{id} : undef,
        others_reverse => [ map { $_->{id} } grep { $_->{id} ne $sid && $_->{q} < -$QT } supplies($t->{net}) ],
        acceptance => $v->{acceptance},
        findings => [ map { $_->{code} } grep { $_->{severity} eq 'error' && $_->{category} ne 'design' }
                      @{ $v->{findings} } ],
    };
}

#------------------------------------------------------------------------------
# joint -- the simultaneous demand of every supply, on one basis (DERATE or
# SCALE).  See the head of the module.
#
# Returns { basis, basis_name, assumption, delta (DERATE, kPa) or factor
# (SCALE), margin (kPa: the pressure every supply has to spare on that basis,
# for SCALE the least of them), governing, acceptance, supplies => [ { id,
# flow, pressure, available, margin, status } ], q_total } or { reason }.
#------------------------------------------------------------------------------
sub joint {
    my $net = shift;
    my $basis = $net->{opts}{joint_basis} // 'DERATE';
    my $text = $net->{source_text} or return { reason => 'the model text is not available to re-solve' };
    my $apply = sub {
        my $x = shift;
        return sub {
            for my $s (supplies(shift)) {
                if ($basis eq 'DERATE') {
                    if ($s->{kind} eq 'SUPPLY_STATIC') { $s->{pstat} -= $x }
                    else { $s->{curve} = shifted($s->{curve}, sub { $_[0] - $x }) }
                } else {
                    if ($s->{kind} eq 'SUPPLY_STATIC') { $s->{pstat} *= $x }
                    else { $s->{curve} = shifted($s->{curve}, sub { $_[0] * $x }) }
                }
            }
        };
    };
    # Every trial classified (HardyCross::Demand::trial): only a PASS is a
    # joint demand the supplies can meet, and only a valid SHORT trial is one
    # they cannot.  A trial in which a supply takes water in, or which does
    # not converge, is neither -- and as released it counted as passing as
    # long as the outlets were met, so a joint demand at which one supply
    # took 550 L/min IN was reported, with its margin.
    my $trial = sub { trial_of($text, $apply->(shift)) };
    my $pass = sub { my $t = shift; $t && $t->{status} eq 'PASS' };
    my $what = sub { my $x = shift; $basis eq 'DERATE' ? sprintf('a derating of %.2f kPa', $x) : sprintf('a factor of %.4f', $x) };
    my $no = sub {
        my ($st, $why) = @_;
        return { status => $st, reason => $why, basis => $basis };
    };
    # The margin falls as D rises, and rises with F.  pass: x satisfies every
    # outlet.  Find a bracket [pass, fail], then bisect.
    my ($good, $bad, $tg, $tb, @seen);
    my $t1 = $trial->($basis eq 'DERATE' ? 0 : 1);
    if ($basis eq 'DERATE') {
        my $pmax = 0;
        for my $s (supplies($net)) {
            my $p = $s->{kind} eq 'SUPPLY_STATIC' ? $s->{pstat} : HardyCross::curve_eval($s->{curve}, 0);
            $pmax = $p if $p > $pmax;
        }
        if ($pass->($t1)) {
            ($good, $tg, $bad) = (0, $t1, $pmax > 1 ? $pmax : 100);
            $tb = $trial->($bad);
            for (1 .. 30) { last unless $pass->($tb); $bad *= 1.5; $tb = $trial->($bad) }
            return $no->('NOT_LIMITING', 'the outlets are met however far the supplies are derated') if $pass->($tb);
        } else {
            ($bad, $good, $tb) = (0, -100, $t1);
            @seen = ($t1);
            $tg = $trial->($good);
            for (1 .. 30) { push @seen, $tg; last if $pass->($tg); $good *= 1.5; $tg = $trial->($good) }
            unless ($pass->($tg)) {
                my $st = HardyCross::Demand::bracket_status(@seen);
                my ($odd) = grep { $_->{status} ne 'SHORT' } @seen;
                return $no->($st, $st eq 'INADEQUATE'
                    ? sprintf('raising every supply by %.0f kPa does not satisfy every outlet', -$good)
                    : sprintf('raising every supply by up to %.0f kPa gave no valid solve meeting every outlet: %s',
                              -$good, reverse_text($odd) || HardyCross::Demand::trial_why($odd)));
            }
        }
    } else {
        if ($pass->($t1)) {
            ($good, $tg, $bad) = (1, $t1, 0);
        } else {
            ($bad, $good, $tb) = (1, 1.5, $t1);
            @seen = ($t1);
            $tg = $trial->($good);
            for (1 .. 30) { push @seen, $tg; last if $pass->($tg); $good *= 1.5; $tg = $trial->($good) }
            unless ($pass->($tg)) {
                my $st = HardyCross::Demand::bracket_status(@seen);
                my ($odd) = grep { $_->{status} ne 'SHORT' } @seen;
                return $no->($st, $st eq 'INADEQUATE'
                    ? sprintf('scaling every supply by %.0f does not satisfy every outlet', $good)
                    : sprintf('scaling every supply by up to %.0f gave no valid solve meeting every outlet: %s',
                              $good, reverse_text($odd) || HardyCross::Demand::trial_why($odd)));
            }
        }
    }
    # Bisect.  For SCALE the step is taken in pressure: the change in factor
    # that moves the strongest supply by P_TOL.
    my $pref = 0;
    for my $s (supplies($net)) {
        my $p = $s->{kind} eq 'SUPPLY_STATIC' ? $s->{pstat} : HardyCross::curve_eval($s->{curve}, 0);
        $pref = $p if $p > $pref;
    }
    my $tolx = $basis eq 'DERATE' ? $P_TOL : $P_TOL / ($pref > 1 ? $pref : 1);
    for (1 .. 100) {
        last if abs($good - $bad) < $tolx;
        my $mid = 0.5 * ($good + $bad);
        my $t = $trial->($mid);
        if ($pass->($t)) { ($good, $tg) = ($mid, $t) } else { ($bad, $tb) = ($mid, $t) }
    }
    # The boundary must be where the outlets stop being met in a valid
    # solve.  Where the trial just past it is invalid or unconverged, the
    # boundary is the edge of validity instead, and the joint demand on this
    # basis is not known.
    unless (HardyCross::Demand::search_status($tb) eq 'FOUND') {
        return $no->('UNRESOLVED', sprintf('beyond %s the joint demand trials are %s: %s.  On the %s basis the '
                                         . 'supplies reach that state before the governing outlet reaches its '
                                         . 'minimum, so no valid joint demand exists on it', $what->($good),
                                           $tb->{status}, reverse_text($tb) || HardyCross::Demand::trial_why($tb),
                                           $basis));
    }

    my $jn = $tg->{net};
    my $v  = HardyCross::Validate::validate($jn, 1);
    my (@rows, $qt, $mmin);
    for my $s (supplies($jn)) {
        my $o = by_id($net, $s->{id});
        my $q = $s->{q};
        my $p = $s->{kind} eq 'SUPPLY_STATIC' ? $s->{pstat} : HardyCross::curve_eval($s->{curve}, $q);
        my $a = avail($o, $q > 0 ? $q : 0);
        $qt += $q;
        $mmin = $a - $p if !defined $mmin || $a - $p < $mmin;
        push @rows, { id => $s->{id}, node => $jn->{nodes}[ $s->{n2} ]{id}, z => $s->{z} // 0,
                      flow => $q, pressure => $p,
                      node_pressure => HardyCross::Demand::gauge($jn, $s->{n2}),
                      available => $a, margin => $a - $p,
                      active => !$s->{closed} && $q > $QT ? 1 : 0,
                      extrapolated => $o->{curve} && HardyCross::Validate::extrapolated($o->{curve}, $q) ? 1 : 0,
                      status => state_of($s), check_valve => valve_of($s) };
    }
    my $qin = 0;
    $qin += $_->{flow} > 0 ? $_->{flow} : 0 for @rows;
    $_->{share} = $qin > 0 && $_->{flow} > 0 ? 100 * $_->{flow} / $qin : 0 for @rows;
    # The supplies' flows, signed, against the network's net demand in the
    # same solve: every outlet's discharge and every fixed demand.
    my $dem = 0;
    $dem += $_->{q} for grep { $_->{kind} eq 'DISCHARGE' && !$_->{closed} } @{ $jn->{elems} }[1 .. $#{ $jn->{elems} }];
    $dem += $jn->{nodes}[$_]{demand} // 0 for 1 .. $#{ $jn->{nodes} };
    my $btol = $HardyCross::Validate::VERIFY_Q_REL * (abs($dem) > 1 ? abs($dem) : 1);
    my @bad = grep { $_->{severity} eq 'error' && $_->{category} ne 'design' } @{ $v->{findings} };
    return {
        status => @bad ? 'UNRESOLVED' : 'FOUND',
        (@bad ? (reason => 'the joint demand solve is not valid: ' . join('; ', map { $_->{message} } @bad)) : ()),
        basis => $basis,
        basis_name => $basis eq 'DERATE' ? 'uniform pressure derating' : 'uniform pressure scaling',
        assumption => 'An ASSUMPTION that defines this joint demand, not a unique physical requirement: '
            . ($basis eq 'DERATE'
               ? 'every supply\'s pressure lowered by the same amount at every flow, each keeping its own curve and '
               . 'connection, until the governing outlet receives exactly its minimum'
               : 'every supply\'s pressure multiplied by the same factor at every flow, each keeping its own curve '
               . 'and connection, until the governing outlet receives exactly its minimum')
            . '.  Another basis gives another split between the supplies.',
        ($basis eq 'DERATE' ? (delta => $good) : (factor => $good)),
        margin => $basis eq 'DERATE' ? $good : $mmin,
        governing => $tg->{go} ? $tg->{go}{id} : undef,
        boundary => $tb ? $tb->{status} : undef,
        acceptance => $v->{acceptance},
        findings => [ map { $_->{code} } @bad ],
        supplies => \@rows,
        q_total => $qt,
        net_demand => $dem,
        balance => $qt - $dem,
        balance_pass => abs($qt - $dem) <= $btol ? 1 : 0,
        net => $jn,
    };
}

#------------------------------------------------------------------------------
# scenarios -- the supply scenarios to solve: the automatic ones (each
# supply alone, each out of service), then the model's SCENARIO lines.
# Each is { name, description, required, shares => { id => percent } }.
#------------------------------------------------------------------------------
sub scenario_list {
    my $net = shift;
    my @ids = map { $_->{id} } supplies($net);
    my @list;
    if ($net->{opts}{supply_scenarios} // 1) {
        my %seen;
        for my $id (@ids) {
            my %sh = map { $_ => ($_ eq $id ? 100 : 0) } @ids;
            push @list, { name => "ONLY-$id", description => "$id alone, every other supply out of service",
                          required => 0, shares => \%sh };
            $seen{ join ',', map { "$_=$sh{$_}" } sort keys %sh } = 1;
        }
        for my $id (@ids) {
            my %sh = map { $_ => ($_ eq $id ? 0 : 100) } @ids;
            next if $seen{ join ',', map { "$_=$sh{$_}" } sort keys %sh }++;
            push @list, { name => "WITHOUT-$id", description => "$id out of service, the others as modelled",
                          required => 0, shares => \%sh };
        }
    }
    for my $sc (@{ $net->{scenarios} || [] }) {
        my %sh = map { $_ => 100 } @ids;
        $sh{ $_->[0] } = $_->[1] for @{ $sc->{shares} };
        push @list, { name => $sc->{name}, line => $sc->{line}, required => 1, shares => \%sh,
                      description => join(', ', map { $_->[1] == 0 ? "$_->[0] out of service"
                                                                 : "$_->[0] at $_->[1] % of its pressure" }
                                               @{ $sc->{shares} }) };
    }
    return @list;
}

#------------------------------------------------------------------------------
# scenario -- one scenario solved and validated.  A supply at 0 % is taken
# out of the network (its node stays, as a junction); one at less than 100 %
# has every pressure of its curve, or its static, multiplied by the
# percentage.
#------------------------------------------------------------------------------
sub scenario {
    my ($net, $sc) = @_;
    my $text = $net->{source_text};
    my $n = reread($text);
    my %sh = %{ $sc->{shares} };
    for my $s (supplies($n)) {
        my $pc = $sh{ $s->{id} } // 100;
        if ($pc <= 0) { $s->{closed} = 1; $s->{out_of_service} = 1; next }
        next if $pc >= 100;
        if ($s->{kind} eq 'SUPPLY_STATIC') { $s->{pstat} *= $pc / 100 }
        else { $s->{curve} = shifted($s->{curve}, sub { $_[0] * $pc / 100 }) }
    }
    my $ok = eval { HardyCross::solve_model($n) };
    my $err = $@;
    unless (defined $ok) {
        my $msg = HardyCross::is_model_error($err) ? $err->{msg} : "$err";
        $msg =~ s/\s+\z//;
        return { %$sc, acceptance => 'INDETERMINATE', error => $msg, supplies => [] };
    }
    my $v = HardyCross::Validate::validate($n, $ok);
    my ($go, $m) = HardyCross::Demand::governing_outlet($n);
    return {
        %$sc,
        acceptance => $v->{acceptance},
        converged  => $ok ? 1 : 0,
        governing  => $go ? $go->{id} : undef,
        margin     => $m,
        findings   => [ map { $_->{code} } grep { $_->{severity} eq 'error' } @{ $v->{findings} } ],
        supplies   => [ map { { id => $_->{id}, percent => $sh{ $_->{id} } // 100,
                                flow => $_->{closed} ? 0 : $_->{q},
                                pressure => HardyCross::Demand::gauge($n, $_->{n2}),
                                status => state_of($_) } }
                        supplies($n) ],
    };
}

#------------------------------------------------------------------------------
# analyse -- the whole multiple-supply picture for a solved network, or undef
# with fewer than two supplies.  { operating, net_demand, supply_sum,
# balance, conditional => [..], joint => {..}, scenarios => [..] }.
#------------------------------------------------------------------------------
sub analyse {
    my ($net, $ok) = @_;
    my @sup = supplies($net);
    return undef unless @sup > 1;
    my $r = { operating => operating($net) };
    my $sum = 0;
    $sum += $_->{flow} for @{ $r->{operating} };
    my $dem = 0;
    $dem += $_->{q} for grep { $_->{kind} eq 'DISCHARGE' && !$_->{closed} } @{ $net->{elems} }[1 .. $#{ $net->{elems} }];
    $dem += $net->{nodes}[$_]{demand} // 0 for 1 .. $#{ $net->{nodes} };
    @{$r}{qw(supply_sum net_demand balance)} = ($sum, $dem, $sum - $dem);
    my ($go) = HardyCross::Demand::governing_outlet($net);
    $r->{governing} = $go ? $go->{id} : undef;
    return $r unless $ok && $net->{source_text} && $go;
    $r->{conditional} = [ map { conditional($net, $_->{id}) } @sup ];
    $r->{joint}       = joint($net);
    $r->{scenarios}   = [ map { scenario($net, $_) } scenario_list($net) ];
    return $r;
}

1;
