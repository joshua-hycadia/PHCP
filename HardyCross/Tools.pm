#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# HardyCross/Tools.pm -- the editor's QUICK TOOLS: three small calculators.
#
#   velocity   a pipe type and size, and a flow: the bore and the velocity
#   kfactor    any two of K, Q and P: the third, from Q = K x sqrt(P)
#   kconvert   a K-factor in one unit, in the others: US (gpm per root psi)
#              and metric (L/min per root bar, and per root kPa)
#   loss       a pipe type and size, and a flow: the friction loss by
#              Hazen-Williams and by Darcy-Weisbach, side by side
#
# Each takes the fields as typed (text) and returns either the answer or the
# problems with the fields, each naming its field, so the tab only draws.
# Nothing here is part of a model; nothing here changes one.
#
# THE SAME NUMBERS AS A CALCULATION
#   Bores come from the pipe and fitting database (HardyCross::PipeData), as a
#   model's pipes do.  The losses are the solver's own: a one-pipe element is
#   handed to HardyCross::elem_hf with the program's default options -- the
#   Hazen-Williams constant 6.05e7 and exponents 1.85 and 4.87, water at
#   20 C (kinematic viscosity 1.004e-6 m2/s) -- so a pipe here loses exactly
#   what the same pipe loses in a model.  The C factor defaults to the pipe
#   type's, from the database; the roughness to 0.045 mm, the program's
#   default (the database holds no roughness).  Either can be changed.
#   Darcy-Weisbach's friction factor is the solver's: an explicit solution of
#   the Colebrook equation when turbulent (Re 4000 and above), 64/Re when
#   laminar (below 2000), and a straight blend of the two between.
#
#   Units: flow L/min, pressure kPa, length m, bore and roughness mm,
#   velocity m/s.  A K-factor is in L/min per root kPa or per root bar, as
#   chosen: a K80 head is K 8 in L/min/kPa^0.5 and K 80 in L/min/bar^0.5.
#==============================================================================
package HardyCross::Tools;

use strict;
use warnings;
use HardyCross;
use HardyCross::Parse;
use HardyCross::PipeData;

# The pipe "type" that takes a bore typed in, rather than a size looked up.
our $BORE = 'BORE';
our $EPS_DEFAULT = 0.045;     # mm, as HardyCross::Parse gives a pipe with none

sub blank  { !defined $_[0] || $_[0] !~ /\S/ }
sub is_num { defined $_[0] && $_[0] =~ /^\s*[-+]?(\d+\.?\d*|\.\d+)([eE][-+]?\d+)?\s*\z/ }

# pipe_types -- the choices for PIPE TYPE: every type in the database, then
# BORE for a bore typed in.
sub pipe_types {
    HardyCross::Parse::ensure_db();
    return (HardyCross::PipeData::pipe_types(), $BORE);
}

# sizes -- the nominal sizes the database holds for a pipe type, smallest
# first, leaving out any whose bore is not given.
sub sizes {
    my $type = shift;
    HardyCross::Parse::ensure_db();
    return () if $type eq $BORE;
    my @dn;
    for my $dn (1 .. 1200) {
        push @dn, $dn if defined HardyCross::PipeData::bore($type, $dn);
    }
    return @dn;
}

# type_c -- the pipe type's Hazen-Williams C, from the database (120 for BORE).
sub type_c {
    my $type = shift;
    HardyCross::Parse::ensure_db();
    my $t = $type ne $BORE && HardyCross::PipeData::pipe_type($type);
    return $t ? $t->{c} : 120;
}

#------------------------------------------------------------------------------
# number -- a field as a number: (value) or (undef, problem).  $rule:
# 'pos' above zero, 'nonneg' zero or above.
#------------------------------------------------------------------------------
sub number {
    my ($label, $v, $rule) = @_;
    return (undef, "$label IS NEEDED") if blank($v);
    return (undef, "$label '" . ($v =~ s/^\s+|\s+$//gr) . "' IS NOT A NUMBER") unless is_num($v);
    return (undef, "$label MUST BE ABOVE ZERO") if ($rule // 'pos') eq 'pos' && $v <= 0;
    return (undef, "$label CANNOT BE NEGATIVE") if $v < 0;
    return ($v + 0);
}

# bore_of -- (bore mm) or (undef, [field, problem]) for a type and a size; for
# BORE the size field is the bore itself.
sub bore_of {
    my ($type, $size) = @_;
    HardyCross::Parse::ensure_db();
    return (undef, [ 'TYPE', 'CHOOSE A PIPE TYPE' ]) if blank($type);
    if ($type eq $BORE) {
        my ($d, $e) = number('BORE', $size);
        return defined $d ? ($d) : (undef, [ 'SIZE', $e ]);
    }
    return (undef, [ 'TYPE', "UNKNOWN PIPE TYPE $type" ]) unless HardyCross::PipeData::pipe_type($type);
    return (undef, [ 'SIZE', 'CHOOSE A SIZE' ]) if blank($size);
    my $d = is_num($size) && HardyCross::PipeData::bore($type, $size + 0);
    return (undef, [ 'SIZE', "$type IS NOT MADE IN DN$size - CHOOSE A SIZE FROM THE LIST" ]) unless $d;
    return ($d);
}

#------------------------------------------------------------------------------
# velocity -- { type, size, flow } as typed.  Returns
#   { ok => 1, bore (mm), area (m2), velocity (m/s) }
#   { ok => 0, errors => [ [field, problem] ] }
#------------------------------------------------------------------------------
sub velocity {
    my %f = @_;
    my @err;
    my ($d, $de) = bore_of($f{type}, $f{size});
    push @err, $de if $de;
    my ($q, $qe) = number('FLOW', $f{flow}, 'nonneg');
    push @err, [ 'FLOW', $qe ] if $qe;
    return { ok => 0, errors => \@err } if @err;
    return { ok => 1, bore => $d, area => 3.14159265358979 * ($d / 1000) ** 2 / 4,
             velocity => HardyCross::pipe_velocity($q, $d) };
}

#------------------------------------------------------------------------------
# kfactor -- { k, q, p, unit } as typed: exactly two of K, Q (L/min) and
# P (kPa) given, the third found from Q = K x sqrt(P).  unit is 'KPA' (K in
# L/min per root kPa, the default) or 'BAR' (per root bar).  Returns
#   { ok => 1, solved => 'K'|'Q'|'P', k, q, p, k_kpa, k_bar }
#   { ok => 0, errors => [ [field, problem] ] }
#------------------------------------------------------------------------------
sub kfactor {
    my %f = @_;
    my $unit = uc($f{unit} // 'KPA');
    my @given = grep { !blank($f{ lc $_ }) } qw(K Q P);
    return { ok => 0, errors => [ [ 'K', 'GIVE ANY TWO OF K, Q AND P - THE THIRD IS FOUND' ] ] } if @given < 2;
    return { ok => 0, errors => [ [ 'K', 'GIVE ONLY TWO OF K, Q AND P - CLEAR THE ONE TO BE FOUND' ] ] } if @given > 2;
    my (%v, @err);
    my %label = (K => 'K', Q => 'FLOW Q', P => 'PRESSURE P');
    for my $x (@given) {
        my ($n, $e) = number($label{$x}, $f{ lc $x }, $x eq 'K' ? 'pos' : 'nonneg');
        if ($e) { push @err, [ $x, $e ] } else { $v{$x} = $n }
    }
    return { ok => 0, errors => \@err } if @err;
    # K in L/min per root kPa for the sums; a K per root bar is ten times it.
    my $kf = $unit eq 'BAR' ? 10 : 1;
    my ($k, $q, $p) = (defined $v{K} ? $v{K} / $kf : undef, $v{Q}, $v{P});
    my ($solved) = grep { !defined $v{$_} } qw(K Q P);
    if ($solved eq 'K') {
        return { ok => 0, errors => [ [ 'P', 'PRESSURE P MUST BE ABOVE ZERO TO FIND K' ] ] } unless $p > 0;
        $k = $q / sqrt $p;
    }
    elsif ($solved eq 'Q') { $q = $k * sqrt $p }
    else                   { $p = ($q / $k) ** 2 }
    return { ok => 1, solved => $solved, k => $k * $kf, q => $q, p => $p, k_kpa => $k, k_bar => $k * 10,
             unit => $unit };
}

#------------------------------------------------------------------------------
# kconvert -- { value, from } as typed: a K-factor in one unit, given in all
# three.  from is 'US' (US gpm per root psi), 'BAR' (L/min per root bar) or
# 'KPA' (L/min per root kPa).  K = Q / sqrt(P), so a K converts by the flow
# factor over the root of the pressure factor:
#   1 US gallon = 3.785411784 L (exact);  1 psi = 6.894757293 kPa
#   K(L/min/bar^0.5) = K(gpm/psi^0.5) x 3.785411784 x sqrt(100 / 6.894757293)
#                    = K(US) x 14.4163...;   K per root kPa is a tenth of that.
# So a K5.6 head (US) is K80.7 metric (bar), the K80 it is sold as.  Returns
#   { ok => 1, us, bar, kpa, from }  or  { ok => 0, errors => [ [field, problem] ] }
#------------------------------------------------------------------------------
our $GAL = 3.785411784;          # L per US gallon
our $PSI = 6.894757293168;       # kPa per psi
our $US_TO_BAR = $GAL * sqrt(100 / $PSI);

sub kconvert {
    my %f = @_;
    my $from = uc($f{from} // 'US');
    my ($k, $e) = number('K', $f{value});
    return { ok => 0, errors => [ [ 'VALUE', $e ] ] } if $e;
    my $bar = $from eq 'US' ? $k * $US_TO_BAR : $from eq 'KPA' ? $k * 10 : $k;
    return { ok => 1, from => $from, us => $bar / $US_TO_BAR, bar => $bar, kpa => $bar / 10 };
}

#------------------------------------------------------------------------------
# loss -- { type, size, flow, length, c, eps } as typed.  Length blank is one
# metre; C blank is the pipe type's; roughness blank is 0.045 mm.  Returns
#   { ok => 1, bore, velocity, length, c, eps,
#     hw => { per_m, total },
#     dw => { per_m, total, re, f, regime },
#     diff (DW - HW, kPa), diff_pct (of HW) }
#   { ok => 0, errors => [ [field, problem] ] }
# Both losses are HardyCross::elem_hf on one pipe, with the program's default
# options and the method set; so they are what a model would give.
#------------------------------------------------------------------------------
sub loss {
    my %f = @_;
    my @err;
    my ($d, $de) = bore_of($f{type}, $f{size});
    push @err, $de if $de;
    my ($q, $qe) = number('FLOW', $f{flow}, 'nonneg');
    push @err, [ 'FLOW', $qe ] if $qe;
    my $len = 1;
    unless (blank($f{length})) {
        my ($l, $le) = number('LENGTH', $f{length});
        if ($le) { push @err, [ 'LENGTH', $le ] } else { $len = $l }
    }
    my $c = $f{type} && !$de ? type_c($f{type}) : 120;
    unless (blank($f{c})) {
        my ($v, $ce) = number('C FACTOR', $f{c});
        if ($ce) { push @err, [ 'C', $ce ] } else { $c = $v }
    }
    my $eps = $EPS_DEFAULT;
    unless (blank($f{eps})) {
        my ($v, $ee) = number('ROUGHNESS', $f{eps}, 'nonneg');
        if ($ee) { push @err, [ 'EPS', $ee ] } else { $eps = $v }
    }
    return { ok => 0, errors => \@err } if @err;

    my $pipe = { kind => 'PIPE', len => $len, eqv => 0, dia => $d, c => $c, eps => $eps };
    my $hf = sub {
        my $method = shift;
        my $o = HardyCross::Parse::new_net()->{opts};
        $o->{method} = $method;
        my ($h) = HardyCross::elem_hf($pipe, $q, $o);
        return $h;
    };
    my ($hw, $dw) = ($hf->('HW'), $hf->('DW'));
    my $v  = HardyCross::pipe_velocity($q, $d);
    my $nu = HardyCross::Parse::new_net()->{opts}{nu};
    my $re = $v * ($d / 1000) / $nu;
    my $fr = HardyCross::dw_friction($re, $eps, $d);
    return {
        ok => 1, bore => $d, velocity => $v, length => $len, c => $c, eps => $eps, nu => $nu,
        hw => { per_m => $hw / $len, total => $hw },
        dw => { per_m => $dw / $len, total => $dw, re => $re, f => $fr,
                regime => $re < 2000 ? 'LAMINAR' : $re < 4000 ? 'TRANSITIONAL' : 'TURBULENT' },
        diff => $dw - $hw, diff_pct => $hw > 0 ? 100 * ($dw - $hw) / $hw : 0,
    };
}

1;
