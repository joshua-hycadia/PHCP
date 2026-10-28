#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# HardyCross/Areas.pm -- design areas: each solved, the governing one reported.
#
# A model may hold more outlets than ever flow at once: the whole floor, of
# which the design area is one part.  Each AREA line names outlets that flow
# together:
#
#     AREA A1 S101 S102 S103 S104
#     AREA A2 S201 S202 S203 S204
#
# An outlet named in no AREA (a hydrant, a hose reel) flows in every area.
#
# HOW THE GOVERNING AREA IS FOUND
#   Each area is solved on its own: the model re-read with OPTION DESIGN_AREA
#   naming it, so only its outlets (and those in no area) flow.  The area
#   that governs is
#     1. one whose solve did not converge, first of all -- nothing about it
#        can be relied on, so it is what the report must show;
#     2. else, when every area has a demand point at the supply (one supply),
#        the area with the least margin there: available minus demand;
#     3. else the area whose governing outlet has the least pressure to spare
#        at the operating point.
#   The report is then of that area, and lists every area in Section 1.
#
#   The model has no drawing, so areas are not found by position: the designer
#   names them, and PHCP reports which of those governs.
#
# OPTION DESIGN_AREA <name> solves that one area only, and nothing is picked.
#==============================================================================
package HardyCross::Areas;

use strict;
use warnings;
use HardyCross;
use HardyCross::Demand;

#------------------------------------------------------------------------------
# governing -- ($net, $ok) of the governing area, from a model read and solved
# with every outlet open.  A model with no AREA, or one with OPTION
# DESIGN_AREA, is returned as it is.  The network returned carries
# area_results: one summary for each area, in the file's order:
#   { name, line, outlets (count), ok, governing (outlet id), margin (outlet,
#     kPa), demand { q, p, avail, margin } or undef, governs (1 for the one) }
#------------------------------------------------------------------------------
sub governing {
    my ($net, $ok) = @_;
    return ($net, $ok) unless $net->{areas} && !defined $net->{design_area};
    require HardyCross::Phc;
    my $text = $net->{source_text};
    $text .= "\n" unless $text =~ /\n\z/;
    my @res;
    for my $a (@{ $net->{areas} }) {
        my $n = HardyCross::Phc::read_string($text . "OPTION DESIGN_AREA $a->{name}\n");
        my $c = HardyCross::solve_model($n);
        $n->{converged} = $c;
        my ($go, $m) = HardyCross::Demand::governing_outlet($n);
        my $d = $c ? HardyCross::Demand::demand_point($n) : undef;
        push @res, { name => $a->{name}, line => $a->{line}, outlets => scalar @{ $a->{outlets} },
                     ok => $c, governing => $go ? $go->{id} : undef, margin => $m,
                     demand => $d && defined $d->{margin}
                         ? { q => $d->{q_demand}, p => $d->{p_demand}, avail => $d->{p_avail},
                             margin => $d->{margin} } : undef,
                     net => $n };
    }
    # Which governs: see the head of this file.
    my ($g) = grep { !$_->{ok} } @res;
    unless ($g) {
        my $all_demand = !grep { !$_->{demand} } @res;
        my $key = $all_demand ? sub { $_[0]{demand}{margin} } : sub { $_[0]{margin} };
        for my $r (grep { defined $key->($_) } @res) {
            $g = $r if !$g || $key->($r) < $key->($g);
        }
        $g //= $res[0];
        $g->{basis} = $all_demand ? 'SUPPLY' : 'OUTLET';
    }
    $g->{governs} = 1;
    my $out = $g->{net};
    # The summaries keep no network: each holds the whole model.
    $out->{area_results} = [ map { my %r = %$_; delete $r{net}; \%r } @res ];
    $out->{area_basis}   = $g->{basis} // 'NOT CONVERGED';
    return ($out, $g->{ok});
}

1;
