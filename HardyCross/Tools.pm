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
#   fittings   a pipe type and size, and fittings: their equivalent length
#              from the database, fitting by fitting
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
#   what the same pipe loses in a model.  The C factor and the roughness
#   default to the pipe type's, from the database (a type with no roughness
#   published, and BORE, take 0.045 mm, the program's default).  Either can
#   be changed.
#   Darcy-Weisbach's friction factor is the solver's: an explicit solution of
#   the Colebrook equation when turbulent (Re 4000 and above), 64/Re when
#   laminar (below 2000), and a straight blend of the two between.
#
#   UNITS.  Each calculator takes units => { FLOW, PRESSURE, LENGTH, SIZE,
#   KFACTOR } -- the PROJECT tab's, with the same choices and the same factors
#   as a model (HardyCross::Phc).  Fields are read in those units and turned
#   into L/min, kPa, m and mm for the sums; the answers come back in L/min,
#   kPa, m and mm, with show(), below, to give them in the units chosen.
#   Without units, everything is L/min, kPa, m and mm.  Velocity is m/s.  A
#   K80 head is K 8 in L/min/kPa^0.5, K 80 in L/min/bar^0.5, K 5.6 in
#   gpm/psi^0.5.
#==============================================================================
package HardyCross::Tools;

use strict;
use warnings;
use HardyCross;
use HardyCross::Parse;
use HardyCross::PipeData;
require HardyCross::Phc;    # the unit choices and factors; it uses this module's neighbours

# The pipe "type" that takes a bore typed in, rather than a size looked up.
our $BORE = 'BORE';
our $EPS_DEFAULT = 0.045;     # mm, as HardyCross::Parse gives a pipe with none

sub blank  { !defined $_[0] || $_[0] !~ /\S/ }

#------------------------------------------------------------------------------
# Units.
#------------------------------------------------------------------------------
our %INTERNAL = (FLOW => 'LPM', PRESSURE => 'KPA', LENGTH => 'M', SIZE => 'MM', KFACTOR => 'LPM/KPA');
my %KALIAS = (US => 'GPM/PSI', BAR => 'LPM/BAR', KPA => 'LPM/KPA');

# units_of -- a units hash completed: anything not given is the internal unit.
sub units_of {
    my $u = shift || {};
    return { map { $_ => (uc($u->{$_} // '') || $INTERNAL{$_}) } keys %INTERNAL };
}

# factor -- what one of $unit is in the internal unit of $q: L/min, kPa, m, mm.
sub factor {
    my ($q, $unit) = @_;
    return HardyCross::Phc::unit_factor($q, $unit) if $q eq 'FLOW' || $q eq 'PRESSURE';
    return HardyCross::Phc::length_metres(1, $unit) if $q eq 'LENGTH';
    return HardyCross::Phc::size_mm(1, $unit) if $q eq 'SIZE';
    die "no unit factor for $q\n";
}

# kfactor_factor -- what a K of 1 in a KFACTOR unit (e.g. GPM/PSI) is in
# L/min per root kPa: the flow factor over the root of the pressure factor.
sub kfactor_factor {
    my $unit = uc shift;
    $unit = $KALIAS{$unit} // $unit;
    my ($kq, $kp) = split m{/}, $unit;
    return factor('FLOW', $kq) / sqrt(factor('PRESSURE', $kp));
}

# show -- an internal value (L/min, kPa, m, mm) in the unit chosen for $q.
sub show {
    my ($q, $v, $units) = @_;
    return $v / factor($q, units_of($units)->{$q});
}

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

# type_eps -- the pipe type's roughness in mm, from the database; 0.045, the
# program's default, for BORE or a type with none published.
sub type_eps {
    my $type = shift // '';
    HardyCross::Parse::ensure_db();
    my $t = $type ne $BORE && HardyCross::PipeData::pipe_type($type);
    return $t && defined $t->{eps} ? $t->{eps} + 0 : $EPS_DEFAULT;
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
    my ($type, $size, $u) = @_;
    HardyCross::Parse::ensure_db();
    return (undef, [ 'TYPE', 'CHOOSE A PIPE TYPE' ]) if blank($type);
    if ($type eq $BORE) {
        my ($d, $e) = number('BORE', $size);
        return defined $d ? ($d * factor('SIZE', units_of($u)->{SIZE})) : (undef, [ 'SIZE', $e ]);
    }
    return (undef, [ 'TYPE', "UNKNOWN PIPE TYPE $type" ]) unless HardyCross::PipeData::pipe_type($type);
    return (undef, [ 'SIZE', 'CHOOSE A SIZE' ]) if blank($size);
    my $d = is_num($size) && HardyCross::PipeData::bore($type, $size + 0);
    return (undef, [ 'SIZE', "$type IS NOT MADE IN DN$size - CHOOSE A SIZE FROM THE LIST" ]) unless $d;
    return ($d);
}

#------------------------------------------------------------------------------
# velocity -- { type, size, flow, units } as typed.  Returns
#   { ok => 1, bore (mm), area (m2), velocity (m/s) }
#   { ok => 0, errors => [ [field, problem] ] }
#------------------------------------------------------------------------------
sub velocity {
    my %f = @_;
    my $u = units_of($f{units});
    my @err;
    my ($d, $de) = bore_of($f{type}, $f{size}, $u);
    push @err, $de if $de;
    my ($q, $qe) = number('FLOW', $f{flow}, 'nonneg');
    push @err, [ 'FLOW', $qe ] if $qe;
    return { ok => 0, errors => \@err } if @err;
    $q *= factor('FLOW', $u->{FLOW});
    return { ok => 1, bore => $d, area => 3.14159265358979 * ($d / 1000) ** 2 / 4, q => $q,
             velocity => HardyCross::pipe_velocity($q, $d) };
}

#------------------------------------------------------------------------------
# kfactor -- { k, q, p, unit, units } as typed: exactly two of K, Q and P
# given, the third found from Q = K x sqrt(P).  Q and P are in units' FLOW and
# PRESSURE; K in unit, a KFACTOR unit (LPM/KPA, the default; LPM/BAR, LPS/KPA,
# LPS/BAR, GPM/PSI; or KPA, BAR, US for the commonest).  Returns
#   { ok => 1, solved => 'K'|'Q'|'P', k (in unit), q (L/min), p (kPa),
#     k_kpa, k_bar, k_us, unit }
#   { ok => 0, errors => [ [field, problem] ] }
#------------------------------------------------------------------------------
sub kfactor {
    my %f = @_;
    my $unit = uc($f{unit} // 'KPA');
    $unit = $KALIAS{$unit} // $unit;
    my $u = units_of($f{units});
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
    # The sums in L/min, kPa and L/min per root kPa.
    my $kf = 1 / kfactor_factor($unit);
    my ($k, $q, $p) = (defined $v{K} ? $v{K} / $kf : undef,
                       defined $v{Q} ? $v{Q} * factor('FLOW', $u->{FLOW}) : undef,
                       defined $v{P} ? $v{P} * factor('PRESSURE', $u->{PRESSURE}) : undef);
    my ($solved) = grep { !defined $v{$_} } qw(K Q P);
    if ($solved eq 'K') {
        return { ok => 0, errors => [ [ 'P', 'PRESSURE P MUST BE ABOVE ZERO TO FIND K' ] ] } unless $p > 0;
        $k = $q / sqrt $p;
    }
    elsif ($solved eq 'Q') { $q = $k * sqrt $p }
    else                   { $p = ($q / $k) ** 2 }
    return { ok => 1, solved => $solved, k => $k * $kf, q => $q, p => $p, k_kpa => $k, k_bar => $k * 10,
             k_us => $k / kfactor_factor('GPM/PSI'), unit => $unit };
}

#------------------------------------------------------------------------------
# kconvert -- { value, from } as typed: a K-factor in one unit, given in all
# three.  from is 'US' (US gpm per root psi), 'BAR' (L/min per root bar) or
# 'KPA' (L/min per root kPa).  K = Q / sqrt(P), so a K converts by the flow
# factor over the root of the pressure factor:
#   1 US gallon = 3.785411784 L (exact);  1 psi = 6.894757 kPa (the model's
#   unit table)
#   K(L/min/bar^0.5) = K(gpm/psi^0.5) x 3.785411784 x sqrt(100 / 6.894757)
#                    = K(US) x 14.4163...;   K per root kPa is a tenth of that.
# So a K5.6 head (US) is K80.7 metric (bar), the K80 it is sold as.  from may
# also be any KFACTOR unit (LPS/KPA, LPS/BAR ...).  Returns
#   { ok => 1, us, bar, kpa, all => { unit => K, for every KFACTOR unit }, from }
#   { ok => 0, errors => [ [field, problem] ] }
#------------------------------------------------------------------------------

sub kconvert {
    my %f = @_;
    my $from = uc($f{from} // 'US');
    my ($k, $e) = number('K', $f{value});
    return { ok => 0, errors => [ [ 'VALUE', $e ] ] } if $e;
    # By the model's own unit factors, so a K converts here exactly as a
    # model reads it in that unit.
    my $bar = $k * kfactor_factor($from) * 10;
    no warnings 'once';
    my %all = map { $_ => $bar / 10 / kfactor_factor($_) } @{ $HardyCross::Phc::UNIT_CHOICES{KFACTOR} };
    return { ok => 1, from => $from, us => $all{'GPM/PSI'}, bar => $bar, kpa => $bar / 10, all => \%all };
}

#------------------------------------------------------------------------------
# loss -- { type, size, flow, length, c, eps, units } as typed.  Length blank
# is one metre; C and roughness blank are the pipe type's.  Returns, in
# L/min, kPa, m and mm (show() gives them in the units chosen)
#   { ok => 1, bore, velocity, length, c, eps, eps_src (GIVEN, DATABASE, or
#     DEFAULT: 0.045 mm assumed, none given or published),
#     hw => { per_m, total },
#     dw => { per_m, total, re, f, regime },
#     diff (DW - HW, kPa), diff_pct (of HW) }
#   { ok => 0, errors => [ [field, problem] ] }
# Both losses are HardyCross::elem_hf on one pipe, with the program's default
# options and the method set; so they are what a model would give.
#------------------------------------------------------------------------------
sub loss {
    my %f = @_;
    my $u = units_of($f{units});
    my @err;
    my ($d, $de) = bore_of($f{type}, $f{size}, $u);
    push @err, $de if $de;
    my ($q, $qe) = number('FLOW', $f{flow}, 'nonneg');
    push @err, [ 'FLOW', $qe ] if $qe;
    $q *= factor('FLOW', $u->{FLOW}) unless $qe;
    my $eps_published = sub { my $t = HardyCross::PipeData::pipe_type(shift); $t && defined $t->{eps} };
    my $len = 1;
    unless (blank($f{length})) {
        my ($l, $le) = number('LENGTH', $f{length});
        if ($le) { push @err, [ 'LENGTH', $le ] } else { $len = $l * factor('LENGTH', $u->{LENGTH}) }
    }
    my $c = $f{type} && !$de ? type_c($f{type}) : 120;
    unless (blank($f{c})) {
        my ($v, $ce) = number('C FACTOR', $f{c});
        if ($ce) { push @err, [ 'C', $ce ] } else { $c = $v }
    }
    # The roughness: as typed; else the type's, from the database; else the
    # program default, 0.045 mm -- and then said to be assumed.
    my $eps = $f{type} && !$de ? type_eps($f{type}) : $EPS_DEFAULT;
    my $eps_src = $f{type} && !$de && $f{type} ne $BORE && $eps_published->($f{type}) ? 'DATABASE' : 'DEFAULT';
    unless (blank($f{eps})) {
        my ($v, $ee) = number('ROUGHNESS', $f{eps}, 'nonneg');
        if ($ee) { push @err, [ 'EPS', $ee ] } else { ($eps, $eps_src) = ($v * factor('SIZE', $u->{SIZE}), 'GIVEN') }
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
        ok => 1, bore => $d, velocity => $v, length => $len, c => $c, eps => $eps, eps_src => $eps_src, nu => $nu,
        hw => { per_m => $hw / $len, total => $hw },
        dw => { per_m => $dw / $len, total => $dw, re => $re, f => $fr,
                regime => $re < 2000 ? 'LAMINAR' : $re < 4000 ? 'TRANSITIONAL' : 'TURBULENT' },
        diff => $dw - $hw, diff_pct => $hw > 0 ? 100 * ($dw - $hw) / $hw : 0,
    };
}

#------------------------------------------------------------------------------
# fittings -- { type, size, spec, c } as typed: fittings on a pipe, in the
# .phc fitting form (2E 1T GV, or 2E,1T,1GV), and their equivalent length,
# by HardyCross::PipeData::resolve -- the same look-up, source and
# corrections as a model's pipe.  C blank is the pipe type's.  Returns
#   { ok => 1, total (m), source, rows => [ { count, code, label, each, total,
#     note } ] }
#   { ok => 0, errors => [ [field, problem] ] }
# A fitting the database has no value for is an error, as in a model: never
# zero, never interpolated.
#------------------------------------------------------------------------------
sub fittings {
    my %f = @_;
    my @err;
    return { ok => 0, errors => [ [ 'TYPE', 'FITTINGS NEED A PIPE TYPE FROM THE DATABASE, NOT BORE' ] ] }
        if ($f{type} // '') eq $BORE;
    my ($d, $de) = bore_of($f{type}, $f{size});
    push @err, $de if $de;
    my $c;
    unless (blank($f{c})) {
        my ($v, $ce) = number('C FACTOR', $f{c});
        if ($ce) { push @err, [ 'C', $ce ] } else { $c = $v }
    }
    push @err, [ 'SPEC', 'GIVE THE FITTINGS: 2E 1T GV, OR 2E,1T,1GV' ] if blank($f{spec});
    return { ok => 0, errors => \@err } if @err;
    (my $spec = uc $f{spec}) =~ s/^\s+|\s+$//g;
    $spec =~ s/[\s,]+/+/g;
    # The editor's short forms for the three commonest valves.
    $spec = join '+', map { s/^(\d*)([GCB])\z/$1 . { G => 'GV', C => 'CV', B => 'BV' }->{$2}/er } split /\+/, $spec;
    my $r = HardyCross::PipeData::resolve(type => $f{type}, dn => $f{size} + 0, c => $c, spec => $spec);
    return { ok => 0, errors => [ map { [ 'SPEC', uc ] } @{ $r->{errors} } ] } if @{ $r->{errors} };
    my @rows = map { { count => $_->{count}, code => $_->{code}, label => HardyCross::Phc::ascii($_->{label} // $_->{code}),
                       each => $_->{each}, total => $_->{total}, note => $_->{note} } } @{ $r->{records} };
    my $src = @{ $r->{records} } ? $r->{records}[0]{doc} : '';
    return { ok => 1, total => $r->{total}, rows => \@rows, source => $src, spec => $spec };
}

1;
