#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# HardyCross/PumpCheck.pm -- each pump's curve checked against its rated duty.
#
# A pump (PUMP) or a booster in a pipe (BP) is given its rated duty with
# PUMPDUTY <pump> <flow> <pressure>.  Its curve, as entered, is then read at
# three flows and compared:
#
#   AT DUTY     the curve at the duty flow gives at least the duty pressure:
#               the pump does what it is rated to do.
#   SHUT-OFF    the curve at no flow is not more than 140 % of the duty
#               pressure.  Source: the Pump Industry Australia AS 2941-2013
#               fire pump checklist, "Shut-off Pressure < 140% of duty head".
#   150 % FLOW  the curve at 150 % of the duty flow gives at least 65 % of the
#               duty pressure.  Source: NFPA 20, 6.2 ("not less than 150
#               percent of rated capacity at not less than 65 percent of total
#               rated head").  Whether AS 2941 states the same was not
#               confirmed, so this is reported FOR INFORMATION and is never a
#               failure.
#
# A curve is read as the solver reads it -- through every point entered,
# straight in Q^1.85 between them, straight in Q beyond the last -- so a
# reading beyond the last point entered is EXTRAPOLATED, and said so.
#
# Without a duty a pump is listed with its shut-off pressure only: the duty is
# not guessed (the operating point is not the rated duty).
#==============================================================================
package HardyCross::PumpCheck;

use strict;
use warnings;
use HardyCross;

our $SHUTOFF_MAX = 1.40;     # shut-off / duty pressure, at most
our $OVERLOAD_Q  = 1.50;     # the overload flow, as a multiple of duty flow
our $OVERLOAD_P  = 0.65;     # its pressure / duty pressure, at least

#------------------------------------------------------------------------------
# check -- every pump in a network:
#   [ { id, kind (PUMP|BP), shutoff, duty => [q, p] or undef,
#       at_duty => { p, ok }, shutoff_ok, over => { q, p, ok, extrapolated },
#       ok } ]
# In the network's internal units (L/min, kPa).  ok is AT DUTY and SHUT-OFF;
# the 150 % reading is for information and does not set it.
#------------------------------------------------------------------------------
sub check {
    my $net = shift;
    my $duty = $net->{opts}{pump_duty} || {};
    my @out;
    for my $e (grep { $_->{kind} eq 'PUMP' } @{ $net->{elems} }[1 .. $#{ $net->{elems} }]) {
        my $c = $e->{curve};
        my $p = { id => $e->{id}, kind => $e->{id} =~ /\.BP\z/ ? 'BP' : 'PUMP',
                  shutoff => HardyCross::curve_eval($c, 0) };
        if (my $d = $duty->{ $e->{id} }) {
            my ($q, $pd) = @$d;
            $p->{duty} = [ $q, $pd ];
            my $at = HardyCross::curve_eval($c, $q);
            $p->{at_duty} = { p => $at, ok => $at >= $pd - 1e-9 };
            $p->{shutoff_ok} = $p->{shutoff} <= $SHUTOFF_MAX * $pd + 1e-9;
            my $qo = $OVERLOAD_Q * $q;
            my $po = HardyCross::curve_eval($c, $qo);
            $p->{over} = { q => $qo, p => $po, ok => $po >= $OVERLOAD_P * $pd - 1e-9,
                           extrapolated => $qo > $c->{qhi} + 1e-9 };
            $p->{ok} = $p->{at_duty}{ok} && $p->{shutoff_ok};
        }
        push @out, $p;
    }
    return \@out;
}

#------------------------------------------------------------------------------
# warnings -- one line for each pump that fails a check, for the report's
# warnings, the editor's WARNINGS list and the JSON.
#------------------------------------------------------------------------------
sub warnings {
    my $net = shift;
    my ($uf, $up) = @{$net}{qw(f_flow f_pres)};
    my @w;
    for my $p (grep { $_->{duty} && !$_->{ok} } @{ check($net) }) {
        my ($q, $pd) = @{ $p->{duty} };
        push @w, sprintf('pump %s does not deliver its duty: %.1f at %.1f, its curve gives %.1f', $p->{id},
                         $q / $uf, $pd / $up, $p->{at_duty}{p} / $up) unless $p->{at_duty}{ok};
        push @w, sprintf('pump %s shut-off %.1f is above 140%% of its duty pressure %.1f (%.1f) - AS 2941 '
                         . '(Pump Industry Australia checklist)', $p->{id}, $p->{shutoff} / $up, $pd / $up,
                         $SHUTOFF_MAX * $pd / $up) unless $p->{shutoff_ok};
    }
    return @w;
}

1;
