#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# HardyCross/DryTime.pm -- ESTIMATED trip, transit and delivery times of a dry
# pipe valve's system.  Apart from the solver: nothing here changes a flow or
# a pressure, and nothing here decides whether a calculation is accepted.
#
# TRIP TIME -- the published formula
#
#     t = 0.0352 x V / (An x sqrt(T0)) x ln(pa0 / pa)
#
#   t    seconds, from the first sprinkler opening to the valve tripping
#   V    the dry system volume, ft3 (every pipe downstream of the valve)
#   An   the flow area of the open sprinkler(s), ft2: the nominal orifice
#        area, pi d^2 / 4, times the number open
#   T0   the air temperature, degrees Rankine
#   pa0  the initial (set) air pressure, psia (DPVAIR)
#   pa   the trip pressure, psia: the TRIP setting, or the static water
#        pressure at the valve divided by the differential RATIO
#
# The equation is from FM Global researchers, as published in the SFPE
# Handbook of Fire Protection Engineering; its form and the definitions above
# are as given in the ASPE Pipeline article "Physics, Hydraulics, and Code
# Requirements Behind Water Delivery Time in Dry Pipe Fire Protection
# Systems" (19 August 2026), whose worked example tools/test_drytime.pl
# reproduces.  It is the isothermal blow-down of the dry volume through a
# choked orifice of discharge coefficient 1: with air at gamma 1.4 and
# R 1716 ft lbf/(slug R), 1 / (sqrt(gamma R) (2/(gamma+1))^((gamma+1)/
# (2(gamma-1)))) = 0.0353, which test_drytime.pl checks as well.  Flow
# through the orifice is choked only while the absolute pressure is above
# 1.893 atmospheres (about 13.1 psig); a trip pressure below that is flagged.
#
# The accelerator is NOT modelled (planned): a time with ACCELERATOR ON is the
# time without it, and said so.
#
# TRANSIT TIME -- a rudimentary estimate, ignoring the air
#
# The time for water to travel from the valve to the most remote outlet of
# the dry system, as if the pipes held no air to compress or expel:
#
#   PATH   sum of L / v along the flow path from the valve to the remote
#          outlet, at the solved velocities -- the water front's travel time
#   FILL   the dry volume divided by the flow through the valve -- the time
#          to fill every pipe, the "theoretical minimum transit time" of the
#          ASPE article
#
# The transit estimate is the larger of the two.  Both are lower bounds: the
# air the water has to push out makes the real transit longer.  The flows
# are the demand point's where there is one (one supply), else the operating
# point's: the report says which.
#
# DELIVERY = TRIP + TRANSIT, an ESTIMATE.  It is not a water delivery time
# calculation by a listed method (NFPA 13 requires one, or a test), and the
# report never presents it as one.
#==============================================================================
package HardyCross::DryTime;

use strict;
use warnings;
use HardyCross;

our $C_TRIP   = 0.0352;          # the published constant (US units)
our $P_ATM    = 101.325;         # kPa, standard atmosphere
our $CHOKE    = 1.893;           # critical pressure ratio of air, gamma 1.4
my $FT3 = 0.028316846592;        # m3 in a ft3
my $FT2 = 0.09290304;            # m2 in a ft2
my $PSI = 6.894757;              # kPa in a psi
my $PI  = 3.14159265358979;

#------------------------------------------------------------------------------
# trip_time -- the formula itself, in its own units: seconds from V ft3, An
# ft2, T0 degrees R and the two absolute pressures in psia.
#------------------------------------------------------------------------------
sub trip_time {
    my ($v_ft3, $an_ft2, $t_r, $pa0, $pa) = @_;
    return $C_TRIP * $v_ft3 / ($an_ft2 * sqrt $t_r) * log($pa0 / $pa);
}

#------------------------------------------------------------------------------
# dry_part -- the pipework downstream of a dry pipe valve: { pipes => [elems],
# outlets => [elems], volume (m3), nodes => {index => 1} } or { error }.
# Walked from the valve's outlet over pipes and devices, not back through
# the valve, stopping at outlets.  A dry part that reaches a water supply or
# the valve's own inlet is not dry: it is refused.
#------------------------------------------------------------------------------
sub dry_part {
    my ($net, $dpv) = @_;
    my @el = grep { !$_->{closed} } @{ $net->{elems} }[1 .. $#{ $net->{elems} }];
    my (%adj, %supply_node);
    for my $e (@el) {
        next if $e == $dpv;
        if ($e->{kind} =~ /^SUPPLY_/) { $supply_node{ $e->{n2} } = $e->{id}; next }
        next if $e->{kind} eq 'DISCHARGE';
        push @{ $adj{ $e->{n1} } }, [ $e->{n2}, $e ];
        push @{ $adj{ $e->{n2} } }, [ $e->{n1}, $e ];
    }
    my %seen = ($dpv->{n2} => 1);
    my @q = ($dpv->{n2});
    my %pipe;
    while (@q) {
        my $v = shift @q;
        return { error => sprintf('the pipework downstream of the valve reaches water supply %s: it is not a dry '
                                . 'system', $supply_node{$v}) } if $supply_node{$v};
        return { error => 'the pipework downstream of the valve leads back to its inlet: it is not a dry system' }
            if $v == $dpv->{n1};
        for my $l (@{ $adj{$v} || [] }) {
            my ($w, $e) = @$l;
            $pipe{ $e->{id} } = $e if $e->{kind} eq 'PIPE';
            push @q, $w unless $seen{$w}++;
        }
    }
    my $vol = 0;
    $vol += $PI / 4 * ($_->{dia} / 1000) ** 2 * $_->{len} for values %pipe;
    my @outlets = grep { $_->{kind} eq 'DISCHARGE' && $seen{ $_->{n1} } } @el;
    return { pipes => [ values %pipe ], outlets => \@outlets, volume => $vol, nodes => \%seen };
}

#------------------------------------------------------------------------------
# path_time -- (seconds, [pipe ids], metres) along the flow path from the
# valve's outlet to an outlet: traced back from the outlet taking, at each
# node, the element that brings the most water in, as the report's flow
# path is.  undef if the trace does not reach the valve.
#------------------------------------------------------------------------------
sub path_time {
    my ($net, $dpv, $outlet) = @_;
    my @el = grep { !$_->{closed} && $_->{kind} ne 'DISCHARGE' } @{ $net->{elems} }[1 .. $#{ $net->{elems} }];
    my ($t, $len, @ids) = (0, 0);
    my $v = $outlet->{n1};
    my %seen = ($v => 1);
    for (1 .. scalar @{ $net->{nodes} }) {
        return ($t, [ reverse @ids ], $len) if $v == $dpv->{n2};
        my ($best, $bq);
        for my $e (@el) {
            next if $e->{kind} =~ /^SUPPLY_/;
            my $in = ($e->{n2} == $v && $e->{q} > 1e-9) ? $e->{q} : ($e->{n1} == $v && $e->{q} < -1e-9) ? -$e->{q} : 0;
            ($best, $bq) = ($e, $in) if $in > 0 && (!defined $bq || $in > $bq);
        }
        return unless $best;
        if ($best->{kind} eq 'PIPE') {
            my $vel = abs HardyCross::pipe_velocity($bq, $best->{dia});
            return unless $vel > 0;
            $t   += $best->{len} / $vel;
            $len += $best->{len};
            push @ids, $best->{id};
        }
        my $from = $best->{n2} == $v ? $best->{n1} : $best->{n2};
        return if $seen{$from}++;
        $v = $from;
    }
    return;
}

#------------------------------------------------------------------------------
# static_at -- the static water pressure at a node, kPa gauge, with no water
# flowing: the highest of the supplies' no-flow pressures, each corrected for
# its elevation above the node.  Pumps are not included.
#------------------------------------------------------------------------------
sub static_at {
    my ($net, $i) = @_;
    my $z = $net->{nodes}[$i]{z} // 0;
    my $best;
    for my $s (grep { $_->{kind} =~ /^SUPPLY_/ && !$_->{closed} } @{ $net->{elems} }[1 .. $#{ $net->{elems} }]) {
        my $p0 = $s->{kind} eq 'SUPPLY_STATIC' ? $s->{pstat} : HardyCross::curve_eval($s->{curve}, 0);
        my $p = $p0 + $HardyCross::GAMMA_W * (($s->{z} // 0) - $z);
        $best = $p if !defined $best || $p > $best;
    }
    return $best;
}

#------------------------------------------------------------------------------
# analyse -- the estimates for every dry pipe valve of a solved network:
# [ { id, trip => {...}, transit => {...}, delivery } ].  $flows is the
# network whose flows the transit uses (the demand point's, or $net itself),
# $basis says which.  All values SI: s, m3, m2, kPa, K.
#------------------------------------------------------------------------------
sub analyse {
    my ($net, $flows, $basis) = @_;
    $flows //= $net;
    $basis //= 'operating point';
    my @out;
    for my $e (grep { $_->{kind} eq 'DPV' } @{ $net->{elems} }[1 .. $#{ $net->{elems} }]) {
        my $tr = $e->{transient} || {};
        my $r = { id => $e->{id} };
        push @out, $r;
        my $dry = dry_part($net, $e);
        if ($dry->{error}) { $r->{error} = $dry->{error}; next }
        $r->{volume} = $dry->{volume};
        $r->{pipes}  = scalar @{ $dry->{pipes} };

        #---------------------------------------------------------- trip
        my $t = $r->{trip} = {};
        my @need;
        push @need, 'the set air pressure (DPVAIR)' unless defined $tr->{air_initial};
        push @need, 'the open sprinkler orifice (DPVTRIP)' unless $tr->{orifice_mm};
        if (@need) {
            $t->{status} = 'NOT_CALCULATED';
            $t->{reason} = 'needs ' . join(' and ', @need);
        } else {
            my $static = $tr->{static_water} // static_at($net, $e->{n1});
            $t->{static} = $static;
            $t->{static_given} = defined $tr->{static_water} ? 1 : 0;
            my $ptrip = ($e->{trip_mode} // '') eq 'TRIP' ? $e->{trip_pressure}
                      : defined $e->{trip_ratio} && $e->{trip_ratio} > 0 && defined $static ? $static / $e->{trip_ratio}
                      : undef;
            my $n = $tr->{open_count} // 1;
            my $an = $n * $PI / 4 * ($tr->{orifice_mm} / 1000) ** 2;
            my $tk = ($tr->{air_temp_c} // 20) + 273.15;
            @{$t}{qw(trip_gauge air_gauge open_count orifice_mm area air_temp_c)} =
                ($ptrip, $tr->{air_initial}, $n, $tr->{orifice_mm}, $an, $tk - 273.15);
            if (!defined $ptrip) {
                @{$t}{qw(status reason)} = ('NOT_CALCULATED', 'no trip pressure: no supply to take the static water pressure from');
            } elsif ($tr->{air_initial} <= $ptrip) {
                @{$t}{qw(status reason)} = ('ERROR', sprintf('the set air pressure, %.1f kPa, is not above the trip '
                    . 'pressure, %.1f kPa: the valve would not stay set', $tr->{air_initial}, $ptrip));
            } else {
                my ($pa0, $pa) = (($tr->{air_initial} + $P_ATM) / $PSI, ($ptrip + $P_ATM) / $PSI);
                $t->{seconds} = trip_time($dry->{volume} / $FT3, $an / $FT2, $tk * 1.8, $pa0, $pa);
                $t->{status}  = 'ESTIMATE';
                $t->{choked}  = ($ptrip + $P_ATM) / $P_ATM >= $CHOKE ? 1 : 0;
                $t->{accelerator_ignored} = ($e->{accelerator} // '') eq 'ON' ? 1 : 0;
            }
        }

        #------------------------------------------------------- transit
        my $x = $r->{transit} = { basis => $basis };
        my ($fdpv) = grep { $_->{id} eq $e->{id} } @{ $flows->{elems} }[1 .. $#{ $flows->{elems} }];
        my $fdry = $fdpv ? dry_part($flows, $fdpv) : { error => 'the valve is not in the network of that solve' };
        if ($fdry->{error} || !@{ $fdry->{outlets} }) {
            @{$x}{qw(status reason)} = ('NOT_CALCULATED', $fdry->{error} // 'no outlet downstream of the valve');
        } else {
            require HardyCross::Demand;
            # The most remote outlet: the one with least pressure to spare.
            my ($remote) = sort { HardyCross::Demand::outlet_margin($flows, $a) <=> HardyCross::Demand::outlet_margin($flows, $b) }
                           @{ $fdry->{outlets} };
            my ($tp, $ids, $len) = path_time($flows, $fdpv, $remote);
            my $qv = $fdpv->{q};
            $x->{remote} = $remote->{id};
            $x->{flow}   = $qv;
            if (defined $tp) { @{$x}{qw(path_seconds path_pipes path_length)} = ($tp, $ids, $len) }
            $x->{fill_seconds} = $qv > 1e-9 ? $fdry->{volume} / ($qv / 60000) : undef;
            my @c = grep { defined } $x->{path_seconds}, $x->{fill_seconds};
            if (@c) {
                ($x->{seconds}) = sort { $b <=> $a } @c;
                $x->{status} = 'ESTIMATE';
            } else {
                @{$x}{qw(status reason)} = ('NOT_CALCULATED', 'no flow through the valve');
            }
        }
        $r->{delivery} = $t->{seconds} + $x->{seconds}
            if defined $t->{seconds} && defined $x->{seconds};
    }
    return \@out;
}

1;
