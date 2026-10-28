#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
# HardyCross/Demand.pm -- the flow path to the governing outlet, and the demand
# the system places on its water supply.
#
# TWO QUESTIONS A CERTIFIER ASKS OF EVERY CALCULATION
#   1. Show me the path to the most demanding head, with the pressure falling
#      along it, so I can check it with a calculator.
#   2. How much does the system need at the supply connection, and how much
#      does the supply have to spare?
#
# Neither is simple on a looped network, and the reasons are stated where the
# code handles them.

package HardyCross::Demand;

use strict;
use warnings;
use HardyCross;
use HardyCross::Parse;

my $GW = $HardyCross::GAMMA_W;

sub gauge {
    my ($net, $i) = @_;
    my $n = $net->{nodes}[$i];
    return $n->{h} - $GW * $n->{z};
}

# The pressure an outlet has to spare: actual minus required, kPa.
sub outlet_margin {
    my ($net, $e) = @_;
    return gauge($net, $e->{n1}) - $e->{preq};
}

#------------------------------------------------------------------------------
# The governing outlet.
#
# "Most remote" in the hydraulic sense: the outlet with the LEAST pressure to
# spare over its requirement, which is the one that fails first as the supply
# weakens.  It is not necessarily the one furthest away on the drawing -- a
# near head on a small pipe, or a high one, can govern.
#
# A fixed flow with a minimum pressure (FIXEDFLOW MINP=, .phc Flow MINP=) is a
# candidate too: its flow is set, but it still needs that pressure to deliver
# it, and it fails first if its margin is the least.  It is returned as the
# fixed-flow record from the parser ($net->{fixed}), which carries the same
# n1, preq and q fields as an outlet element, and kind FIXEDFLOW.  A fixed flow
# with no minimum pressure has no margin and cannot govern.
#------------------------------------------------------------------------------
sub governing_outlet {
    my $net = shift;
    my ($best, $bm);
    my @cand = ((grep { $_->{kind} eq 'DISCHARGE' } @{ $net->{elems} }[1 .. $#{ $net->{elems} }]),
                (grep { defined $_->{preq} } @{ $net->{fixed} || [] }));
    for my $e (@cand) {
        my $m = outlet_margin($net, $e);
        ($best, $bm) = ($e, $m) if !defined $bm || $m < $bm;
    }
    return ($best, $bm);
}

#------------------------------------------------------------------------------
# The flow path from a supply to an outlet.
#
# A looped network has no single path: water reaches a head by several routes
# at once.  The path shown is traced BACKWARDS from the outlet, taking at each
# node the element that brings the most water in, until a supply is reached --
# the route that carries most of the flow.
#
# The choice of path does not affect the numbers on it.  Head at a node is a
# single value however it is reached, so the pressure worked forward along ANY
# path must land on the solved pressure at every node.  The worksheet prints
# both, and the difference column is the check.
#------------------------------------------------------------------------------
sub flow_path {
    my ($net, $outlet) = @_;
    my @steps;
    my $v = $outlet->{n1};
    my %seen = ($v => 1);
    my $iref = $net->{iref};

    for (1 .. scalar @{ $net->{nodes} }) {
        my ($best, $bq);
        for my $ei (1 .. $#{ $net->{elems} }) {
            my $e = $net->{elems}[$ei];
            next if $e->{closed} || $e->{kind} eq 'DISCHARGE';
            # the element delivers INTO $v if flow runs toward it
            my $in = ($e->{n2} == $v && $e->{q} >  1e-9) ? $e->{q}
                   : ($e->{n1} == $v && $e->{q} < -1e-9) ? -$e->{q} : 0;
            next unless $in > 0;
            ($best, $bq) = ($e, $in) if !defined $bq || $in > $bq;
        }
        return (undef, "no inflow found at node $net->{nodes}[$v]{id}") unless $best;

        my $from = $best->{n2} == $v ? $best->{n1} : $best->{n2};
        unshift @steps, { elem => $best, from => $from, to => $v, q => $bq };
        last if $from == $iref;              # reached a supply
        return (undef, 'the trace revisited a node') if $seen{$from}++;
        $v = $from;
    }
    return (\@steps, undef);
}

#------------------------------------------------------------------------------
# The demand point.
#
# In a solved network the supply always exactly meets the system -- that is
# what "solved" means -- so the operating point shows no margin at all.  The
# DEMAND is a different thing: the pressure the system needs at the supply
# connection for the governing outlet to receive exactly its minimum, and the
# flow that goes with it.  Every outlet discharges less than at the operating
# point, because the supply pressure is lower.
#
# It is found by replacing the supply with a fixed pressure and bisecting on
# that pressure until the least outlet margin is zero.  Each trial is a full
# solve, including pump check valves and orifice sizing -- lowering the supply
# can close a check valve, and the demand must reflect that.
#
# Defined for ONE supply.  With several, "the pressure the system needs" has no
# single answer -- it depends how the supplies share the load -- and the report
# says so rather than inventing one.
#------------------------------------------------------------------------------
sub margin_at {
    my ($text, $sid, $p) = @_;
    my ($ok, $net) = solve_at($text, $sid, $p);
    return unless $ok;
    my (undef, $m) = governing_outlet($net);
    return unless defined $m;
    return ($m, $net);
}

#------------------------------------------------------------------------------
# solve_at -- (converged, network): the model re-read from its text and solved
# with supply $sid held at pressure $p (a static supply at the same node and
# elevation, in place of its curve).  Every other supply is left as modelled.
# (undef) when the text does not read or the supply is not in it.
#------------------------------------------------------------------------------
sub solve_at {
    my ($text, $sid, $p) = @_;
    require HardyCross::Phc;
    my $net = eval { HardyCross::Phc::read_string($text) } or return;
    my ($sup) = grep { ($_->{id} // '') eq $sid } @{ $net->{elems} }[1 .. $#{ $net->{elems} }];
    return unless $sup;
    # Same node, same elevation, a fixed pressure instead of a curve.
    my $z = $sup->{z} // 0;
    %$sup = (%$sup, kind => 'SUPPLY_STATIC', pstat => $p, z => $z);
    delete $sup->{curve};
    my $ok = eval { HardyCross::solve_model($net) };
    return ($ok, $net);
}

sub demand_point {
    my ($net) = @_;
    my @sup = grep { $_->{kind} =~ /^SUPPLY_/ } @{ $net->{elems} }[1 .. $#{ $net->{elems} }];
    return { reason => 'the model has no supply' } unless @sup;
    return { reason => scalar(@sup) . ' supplies: a single demand point is not defined when '
                     . 'supplies share the load, so each supply is reported at its operating point' }
        if @sup > 1;
    my $s = $sup[0];
    my $text = $net->{source_text}
        or return { reason => 'the model text is not available to re-solve' };
    my ($go) = governing_outlet($net);
    return { reason => 'the model has no outlet with a required pressure' } unless $go;

    my $p_now = gauge($net, $s->{n2});
    my ($lo, $hi) = (0, $p_now > 1 ? $p_now : 100);

    # Make sure the bracket holds the answer: at $hi the margin must be >= 0.
    my ($mh) = margin_at($text, $s->{id}, $hi);
    for (1 .. 30) {
        last if defined $mh && $mh >= 0;
        $hi *= 1.5;
        ($mh) = margin_at($text, $s->{id}, $hi);
    }
    return { reason => 'no supply pressure up to ' . sprintf('%.0f', $hi)
                     . ' kPa satisfies every outlet' } unless defined $mh && $mh >= 0;

    # Bisect to 0.01 kPa.  A trial that does not solve counts as a failure:
    # a supply too weak to push water to every outlet is below the demand.
    for (1 .. 60) {
        my $mid = 0.5 * ($lo + $hi);
        my ($m) = margin_at($text, $s->{id}, $mid);
        if (defined $m && $m >= 0) { $hi = $mid } else { $lo = $mid }
        last if $hi - $lo < 0.01;
    }
    my ($m, $dn) = margin_at($text, $s->{id}, $hi);
    my ($dsup) = grep { ($_->{id} // '') eq $s->{id} } @{ $dn->{elems} }[1 .. $#{ $dn->{elems} }];
    my ($dgo) = governing_outlet($dn);
    # The demand flow: what the system draws at the demand point, plus any
    # hose allowance (OPTION HOSE_ALLOWANCE), which is added at the supply --
    # it draws on the supply but not through the network modelled.
    my $q_sys  = abs $dsup->{q};
    my $q_hose = $net->{opts}{hose} // 0;
    my $q_d    = $q_sys + $q_hose;

    # What the supply has at that flow.
    my $avail = $s->{kind} eq 'SUPPLY_STATIC'
              ? $s->{pstat}
              : HardyCross::curve_eval($s->{curve}, $q_d);

    return {
        supply    => $s,
        governing => $dgo,
        q_demand  => $q_d,
        q_system  => $q_sys,
        q_hose    => $q_hose,
        p_demand  => $hi,
        p_avail   => $avail,
        margin    => $avail - $hi,
        q_oper    => abs $s->{q},
        p_oper    => $p_now,
        # the whole network at the demand point, so the cover sheet can report
        # sprinkler flows and density at the design condition, not only at the
        # operating point
        net       => $dn,
    };
}

#------------------------------------------------------------------------------
# All the supplies together.
#
# Several supplies are combined the way supply graphs combine them -- as pumps
# on one header are: their curves are ADDED IN FLOW AT EQUAL PRESSURE.  At
# each pressure the combined supply gives the sum of what each supply gives at
# that pressure; pressures are not adjusted.  A static supply gives any flow
# up to its pressure, so the combined curve never falls below the highest
# static.
#
# The required condition is taken on the same basis: every supply held at one
# common pressure, raised until the governing outlet receives exactly its
# minimum.  The flows of all the supplies in that solve, added, are the
# combined duty, at that pressure.  (How that total splits between the
# supplies in the solve follows the pipework, not their curves, so it is not
# reported supply by supply.)  Where the supplies connect at
# different points, this is a statement about them taken together: the
# modelled network runs each at its own pressure, as Section 9 lists, and in
# the common-pressure solve water may pass from one supply into another.
#------------------------------------------------------------------------------

# supplies -- the supply elements of a network.
sub supplies {
    my $net = shift;
    return grep { $_->{kind} =~ /^SUPPLY_/ } @{ $net->{elems} }[1 .. $#{ $net->{elems} }];
}

# solve_all_at -- (converged, network): the model re-read and solved with
# every supply held at gauge pressure $p.
sub solve_all_at {
    my ($text, $p) = @_;
    require HardyCross::Phc;
    my $net = eval { HardyCross::Phc::read_string($text) } or return;
    for my $s (supplies($net)) {
        my $z = $s->{z} // 0;
        %$s = (%$s, kind => 'SUPPLY_STATIC', pstat => $p, z => $z);
        delete $s->{curve};
    }
    my $ok = eval { HardyCross::solve_model($net) };
    return ($ok, $net);
}

# avail_of -- one supply's pressure at a flow: its static pressure, or its
# curve.
sub avail_of {
    my ($s, $q) = @_;
    return $s->{kind} eq 'SUPPLY_STATIC' ? $s->{pstat} : HardyCross::curve_eval($s->{curve}, $q);
}

# flow_at -- the flow one supply gives at gauge pressure $p: none at or above
# its pressure at no flow, and for a curve the flow where the curve reaches
# $p.  A static supply gives any flow at or below its pressure (undef:
# unlimited).
sub flow_at {
    my ($s, $p) = @_;
    if ($s->{kind} eq 'SUPPLY_STATIC') { return $p <= $s->{pstat} ? undef : 0 }
    return 0 if $p >= HardyCross::curve_eval($s->{curve}, 0);
    my ($lo, $hi) = (0, 1);
    $hi *= 2 while HardyCross::curve_eval($s->{curve}, $hi) > $p && $hi < 1e9;
    for (1 .. 80) {
        my $mid = 0.5 * ($lo + $hi);
        if (HardyCross::curve_eval($s->{curve}, $mid) > $p) { $lo = $mid } else { $hi = $mid }
    }
    return 0.5 * ($lo + $hi);
}

# combined_avail -- a sub giving the pressure the supplies together have at a
# total flow: the highest pressure at which the flows they give add up to it.
sub combined_avail {
    my @sup = @_;
    my ($pstat) = sort { $b <=> $a } map { $_->{pstat} } grep { $_->{kind} eq 'SUPPLY_STATIC' } @sup;
    my @curve = grep { $_->{kind} ne 'SUPPLY_STATIC' } @sup;
    my ($ptop) = sort { $b <=> $a } map { HardyCross::curve_eval($_->{curve}, 0) } @curve;
    return sub {
        my $q = shift;
        my $pc = 0;
        if (@curve) {
            my $sum = sub { my $t = 0; $t += flow_at($_, $_[0]) for @curve; $t };
            if ($sum->(0) >= $q) {
                my ($lo, $hi) = (0, $ptop);
                for (1 .. 60) {
                    my $mid = 0.5 * ($lo + $hi);
                    if ($sum->($mid) >= $q) { $lo = $mid } else { $hi = $mid }
                }
                $pc = $lo;
            }
        }
        return defined $pstat && $pstat > $pc ? $pstat : $pc;
    };
}

#------------------------------------------------------------------------------
# combined_demand -- the required condition of several supplies, on the basis
# above, or { reason }:
#
#   p_demand     the common pressure at which the governing outlet receives
#                exactly its minimum
#   q_demand     the flows of all the supplies in that solve, added: the
#                combined duty
#   avail        the combined curve, a sub of total flow
#   p_avail      the combined curve at the combined duty
#   margin       p_avail - p_demand
#   q_oper       the flows the supplies deliver in the modelled network, added
#   p_oper       the highest of their operating pressures
#   one_pressure true when their operating pressures agree to within 2 %, so
#                the modelled network runs them as on one header
#   supply       a stand-in { id => 'ALL', kind => 'COMBINED' }; combined => 1;
#                parts, the supplies; governing, the outlet in that solve
#------------------------------------------------------------------------------
sub combined_demand {
    my ($net) = @_;
    my @sup = supplies($net);
    return { reason => 'fewer than two supplies' } unless @sup > 1;
    my $text = $net->{source_text}
        or return { reason => 'the model text is not available to re-solve' };
    my ($go) = governing_outlet($net);
    return { reason => 'the model has no outlet with a required pressure' } unless $go;
    my $margin = sub {
        my ($ok, $n) = solve_all_at($text, shift);
        return unless $ok;
        my (undef, $m) = governing_outlet($n);
        return ($m, $n);
    };

    # Bisect on the common pressure, as demand_point does on one supply's.
    my ($lo, $hi) = (0, 100);
    my ($mh) = $margin->($hi);
    for (1 .. 30) {
        last if defined $mh && $mh >= 0;
        $hi *= 1.5;
        ($mh) = $margin->($hi);
    }
    return { reason => 'no common supply pressure up to ' . sprintf('%.0f', $hi)
                     . ' kPa satisfies every outlet' } unless defined $mh && $mh >= 0;
    for (1 .. 60) {
        my $mid = 0.5 * ($lo + $hi);
        my ($m) = $margin->($mid);
        if (defined $m && $m >= 0) { $hi = $mid } else { $lo = $mid }
        last if $hi - $lo < 0.01;
    }
    my (undef, $dn) = $margin->($hi);
    my ($dgo) = governing_outlet($dn);
    my $q_d = 0;
    $q_d += $_->{q} for supplies($dn);
    # Any hose allowance is added at the supplies, as for one supply.
    my $q_sys = $q_d;
    $q_d += $net->{opts}{hose} // 0;

    my ($q_o, $p_o, $p_lo) = (0, undef, undef);
    for my $s (@sup) {
        $q_o += abs $s->{q};
        my $g = gauge($net, $s->{n2});
        $p_o  = $g if !defined $p_o  || $g > $p_o;
        $p_lo = $g if !defined $p_lo || $g < $p_lo;
    }
    my $avail = combined_avail(@sup);
    return {
        supply       => { id => 'ALL', kind => 'COMBINED' },
        combined     => 1,
        parts        => [ @sup ],
        governing    => $dgo,
        avail        => $avail,
        p_demand     => $hi,
        q_demand     => $q_d,
        q_system     => $q_sys,
        q_hose       => $net->{opts}{hose} // 0,
        p_avail      => $avail->($q_d),
        margin       => $avail->($q_d) - $hi,
        q_oper       => $q_o,
        p_oper       => $p_o,
        one_pressure => $p_o - $p_lo <= 0.02 * abs $p_o,
    };
}

1;
