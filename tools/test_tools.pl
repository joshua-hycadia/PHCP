#!/usr/bin/perl
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# test_tools.pl -- the QUICK TOOLS calculators (HardyCross::Tools), headless.
#
#   perl tools/test_tools.pl
#
# Every answer is checked against a formula written out in this file, not
# against the engine's own code:
#
#   1. VELOCITY.       v = Q / A, with the database's bore.
#   2. K-FACTOR.       Q = K sqrt(P), each of the three solved for; K per root
#                      bar is ten times K per root kPa.
#   3. K CONVERTER.    US gpm/psi^0.5 to L/min/bar^0.5 by the exact gallon and
#                      psi; a K5.6 head is the K80 it is sold as.
#   4. PRESSURE LOSS.  Hazen-Williams 6.05e7 Q^1.85 / (C^1.85 d^4.87) kPa/m;
#                      Darcy-Weisbach against the Colebrook equation solved
#                      here by iteration, 64/Re when laminar and the blend
#                      of the two in the transitional zone; length, C and
#                      roughness each followed.
#   5. REFUSED.        Each problem names its field.
#==============================================================================
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";
use HardyCross::Tools;
use HardyCross::PipeData;

my ($pass, $fail) = (0, 0);
sub is {
    my ($name, $ok, $why) = @_;
    printf "  %-68s %s\n", $name, $ok ? 'ok' : '*** FAIL';
    print "      $why\n" if !$ok && defined $why;
    $ok ? $pass++ : $fail++;
}
sub rel { my ($a, $b) = @_; abs($a - $b) / (abs($b) > 1e-12 ? abs($b) : 1) }
my $PI = 4 * atan2(1, 1);

# A refusal: not ok, and a problem on the field named, matching $re.
sub refused {
    my ($name, $r, $field, $re) = @_;
    my ($e) = grep { $_->[0] eq $field } @{ $r->{errors} || [] };
    is($name, !$r->{ok} && $e && $e->[1] =~ $re,
       $r->{ok} ? 'it was accepted' : join '; ', map { "[$_->[0]] $_->[1]" } @{ $r->{errors} });
}

#==============================================================================
print "1. VELOCITY - v = Q / A\n";
#==============================================================================
{
    my @types = grep { $_ ne 'BORE' } HardyCross::Tools::pipe_types();
    is('the pipe types are the database\'s, then BORE', @types >= 5 && (HardyCross::Tools::pipe_types())[-1] eq 'BORE',
       join ' ', HardyCross::Tools::pipe_types());
    my $bad = 0;
    for my $type (@types) {
        for my $dn (HardyCross::Tools::sizes($type)) {
            my $d = HardyCross::PipeData::bore($type, $dn);
            my $r = HardyCross::Tools::velocity(type => $type, size => $dn, flow => 1000);
            $bad++ unless $r->{ok} && $r->{bore} == $d && rel($r->{velocity}, (1000 / 60000) / ($PI * ($d / 1000) ** 2 / 4)) < 1e-12;
        }
    }
    is('every type and size: the database bore, and v = Q / A', !$bad);
    my $r = HardyCross::Tools::velocity(type => 'ASAM', size => 50, flow => 500);
    is(sprintf('DN50 medium steel at 500 L/min: 53.0 mm bore, %.3f m/s', $r->{velocity}),
       $r->{bore} == 53.0 && rel($r->{velocity}, 3.7773) < 1e-4);
    $r = HardyCross::Tools::velocity(type => 'BORE', size => '100', flow => '1500');
    is('BORE: the bore typed in, 100 mm at 1500 L/min is 3.183 m/s', $r->{ok} && rel($r->{velocity}, 3.18310) < 1e-5);
    $r = HardyCross::Tools::velocity(type => 'ASAM', size => 50, flow => 0);
    is('no flow, no velocity', $r->{ok} && $r->{velocity} == 0);
}

#==============================================================================
print "2. K-FACTOR - Q = K sqrt(P)\n";
#==============================================================================
{
    my $r = HardyCross::Tools::kfactor(k => 8, p => 100);
    is('K 8 (per root kPa) at 100 kPa: Q = 80 L/min', $r->{ok} && $r->{solved} eq 'Q' && rel($r->{q}, 80) < 1e-12);
    $r = HardyCross::Tools::kfactor(q => 80, p => 100);
    is('80 L/min at 100 kPa: K = 8 per root kPa, 80 per root bar',
       $r->{ok} && $r->{solved} eq 'K' && rel($r->{k}, 8) < 1e-12 && rel($r->{k_bar}, 80) < 1e-12);
    $r = HardyCross::Tools::kfactor(k => 8, q => 120);
    is('K 8 at 120 L/min: P = (120/8)^2 = 225 kPa', $r->{ok} && $r->{solved} eq 'P' && rel($r->{p}, 225) < 1e-12);
    $r = HardyCross::Tools::kfactor(k => 80, p => 150, unit => 'BAR');
    is(sprintf('K 80 per root bar at 150 kPa (1.5 bar): Q = 80 sqrt(1.5) = %.3f', 80 * sqrt 1.5),
       $r->{ok} && rel($r->{q}, 80 * sqrt(1.5)) < 1e-12 && rel($r->{k_kpa}, 8) < 1e-12);
    $r = HardyCross::Tools::kfactor(q => 97.98, p => 150, unit => 'BAR');
    is('K found in the unit chosen: per root bar', $r->{ok} && rel($r->{k}, 97.98 / sqrt(1.5)) < 1e-12);
    refused('one value is not enough', HardyCross::Tools::kfactor(k => 8), 'K', qr/ANY TWO/);
    refused('three values: one must be cleared', HardyCross::Tools::kfactor(k => 8, q => 80, p => 100), 'K', qr/ONLY TWO/);
    refused('K from no pressure is refused', HardyCross::Tools::kfactor(q => 80, p => 0), 'P', qr/ABOVE ZERO TO FIND K/);
    refused('a K of zero is refused', HardyCross::Tools::kfactor(k => 0, p => 100), 'K', qr/ABOVE ZERO/);
    refused('a letter O for a zero', HardyCross::Tools::kfactor(k => 8, p => '1O0'), 'P', qr/'1O0' IS NOT A NUMBER/);
}

#==============================================================================
print "3. K CONVERTER - US gpm/psi^0.5 and metric L/min/bar^0.5, L/min/kPa^0.5\n";
#==============================================================================
{
    # 1 US gal = 3.785411784 L; 1 psi = 6.894757293168 kPa = 0.06894757 bar.
    my $f = 3.785411784 / sqrt(0.06894757293168);
    my $r = HardyCross::Tools::kconvert(value => 5.6, from => 'US');
    is(sprintf('K5.6 (US) is K%.2f metric per root bar - the K80 it is sold as', 5.6 * $f),
       $r->{ok} && rel($r->{bar}, 5.6 * $f) < 1e-12 && abs($r->{bar} - 80.7) < 0.05 && rel($r->{kpa}, $r->{bar} / 10) < 1e-12);
    $r = HardyCross::Tools::kconvert(value => 80, from => 'BAR');
    is(sprintf('K80 metric is K%.3f US', 80 / $f), $r->{ok} && rel($r->{us}, 80 / $f) < 1e-12 && rel($r->{kpa}, 8) < 1e-12);
    $r = HardyCross::Tools::kconvert(value => 8, from => 'KPA');
    is('K8 per root kPa is K80 per root bar', $r->{ok} && rel($r->{bar}, 80) < 1e-12);
    $r = HardyCross::Tools::kconvert(value => 11.2, from => 'US');
    my $back = HardyCross::Tools::kconvert(value => $r->{bar}, from => 'BAR');
    is('US to metric and back gives the same K', rel($back->{us}, 11.2) < 1e-12);
    refused('a K that is not a number', HardyCross::Tools::kconvert(value => 'K80', from => 'BAR'), 'VALUE', qr/NOT A NUMBER/);
}

#==============================================================================
print "4. PRESSURE LOSS - Hazen-Williams and Darcy-Weisbach\n";
#==============================================================================
# Colebrook, solved here by fixed-point iteration: an independent check of the
# engine's explicit approximation.  Laminar below Re 2000; between 2000 and
# 4000, the transitional zone, the solver blends linearly from 64/Re to the
# turbulent value, and so does this.
sub colebrook {
    my ($re, $eps, $d) = @_;
    return 64 / $re if $re < 2000;
    my $x = 0.02 ** -0.5;
    $x = -2 * log($eps / (3.7 * $d) + 2.51 * $x / $re) / log(10) for 1 .. 100;
    my $f = 1 / $x ** 2;
    if ($re < 4000) { my $t = ($re - 2000) / 2000; $f = (1 - $t) * 64 / $re + $t * $f }
    return $f;
}
{
    my $hw = sub { my ($q, $c, $d) = @_; 6.05e7 * $q ** 1.85 / ($c ** 1.85 * $d ** 4.87) };
    my $dw = sub {
        my ($q, $eps, $d) = @_;
        my $v = ($q / 60000) / ($PI * ($d / 1000) ** 2 / 4);
        my $re = $v * ($d / 1000) / 1.004e-6;
        return colebrook($re, $eps, $d) / ($d / 1000) * 1000 * $v ** 2 / 2 / 1000;   # kPa/m: f/D rho v^2/2
    };
    my $r = HardyCross::Tools::loss(type => 'ASAM', size => 50, flow => 500);
    is(sprintf('HW, DN50 at 500 L/min, C 120: %.4f kPa/m', $hw->(500, 120, 53.0)),
       $r->{ok} && rel($r->{hw}{per_m}, $hw->(500, 120, 53.0)) < 1e-12 && $r->{c} == 120 && $r->{length} == 1);
    is(sprintf('DW, 0.045 mm: %.4f kPa/m, within 0.5 %% of Colebrook', $dw->(500, 0.045, 53.0)),
       rel($r->{dw}{per_m}, $dw->(500, 0.045, 53.0)) < 0.005, sprintf('%.5f', $r->{dw}{per_m}));
    is('   turbulent, Re = vD/nu', $r->{dw}{regime} eq 'TURBULENT' && rel($r->{dw}{re}, $r->{velocity} * 0.053 / 1.004e-6) < 1e-12);
    my $bad = 0;
    for my $type (grep { $_ ne 'BORE' } HardyCross::Tools::pipe_types()) {
        for my $dn (HardyCross::Tools::sizes($type)) {
            my $d = HardyCross::PipeData::bore($type, $dn);
            my $c = HardyCross::PipeData::pipe_type($type)->{c};
            for my $q (100, 1000, 5000) {
                my $x = HardyCross::Tools::loss(type => $type, size => $dn, flow => $q);
                $bad++ unless rel($x->{hw}{per_m}, $hw->($q, $c, $d)) < 1e-12
                           && rel($x->{dw}{per_m}, $dw->($q, 0.045, $d)) < 0.01;
            }
        }
    }
    is('every type and size at 100, 1000 and 5000 L/min: HW exact, DW within 1 %', !$bad);
    $r = HardyCross::Tools::loss(type => 'S40', size => 600, flow => 100);
    is(sprintf('transitional (S40 DN600 at 100 L/min, Re %.0f): the blend, within 1 %%', $r->{dw}{re}),
       $r->{dw}{regime} eq 'TRANSITIONAL' && rel($r->{dw}{f}, colebrook($r->{dw}{re}, 0.045, $r->{bore})) < 0.01);
    my $l = HardyCross::Tools::loss(type => 'ASAM', size => 65, flow => 1000, length => 25);
    my $one = HardyCross::Tools::loss(type => 'ASAM', size => 65, flow => 1000);
    is('over 25 m: 25 times the loss per metre, both formulas',
       rel($l->{hw}{total}, 25 * $one->{hw}{per_m}) < 1e-12 && rel($l->{dw}{total}, 25 * $one->{dw}{per_m}) < 1e-12);
    $r = HardyCross::Tools::loss(type => 'PE11', size => 110, flow => 1000);
    is('the C factor is the pipe type\'s: 150 for PE', $r->{c} == 150 && rel($r->{hw}{per_m}, $hw->(1000, 150, HardyCross::PipeData::bore('PE11', 110))) < 1e-12);
    $r = HardyCross::Tools::loss(type => 'ASAM', size => 50, flow => 500, c => 100, eps => '0.0015');
    is('C and roughness as typed', $r->{c} == 100 && $r->{eps} == 0.0015 && rel($r->{hw}{per_m}, $hw->(500, 100, 53.0)) < 1e-12
       && rel($r->{dw}{per_m}, $dw->(500, 0.0015, 53.0)) < 0.005);
    $r = HardyCross::Tools::loss(type => 'BORE', size => 2, flow => 0.05);
    my $v = (0.05 / 60000) / ($PI * 0.002 ** 2 / 4);
    is(sprintf('laminar (Re %.0f): f = 64/Re', $v * 0.002 / 1.004e-6),
       $r->{dw}{regime} eq 'LAMINAR' && rel($r->{dw}{f}, 64 / ($v * 0.002 / 1.004e-6)) < 1e-12);
    is('   and DW against HW is DW - HW, as a percentage of HW',
       rel($one->{diff_pct}, 100 * ($one->{dw}{per_m} - $one->{hw}{per_m}) / $one->{hw}{per_m}) < 1e-12);
}

#==============================================================================
print "5. REFUSED - each problem names its field\n";
#==============================================================================
{
    refused('no size chosen', HardyCross::Tools::velocity(type => 'ASAM', size => '', flow => 100), 'SIZE', qr/CHOOSE A SIZE/);
    refused('a size the type is not made in', HardyCross::Tools::velocity(type => 'ASAM', size => 300, flow => 100),
            'SIZE', qr/ASAM IS NOT MADE IN DN300/);
    refused('an unknown pipe type', HardyCross::Tools::loss(type => 'XX9', size => 50, flow => 100), 'TYPE', qr/UNKNOWN PIPE TYPE XX9/);
    refused('no flow', HardyCross::Tools::loss(type => 'ASAM', size => 50, flow => ''), 'FLOW', qr/FLOW IS NEEDED/);
    refused('a negative flow', HardyCross::Tools::velocity(type => 'ASAM', size => 50, flow => -5), 'FLOW', qr/CANNOT BE NEGATIVE/);
    refused('a bore of zero', HardyCross::Tools::velocity(type => 'BORE', size => 0, flow => 100), 'SIZE', qr/BORE MUST BE ABOVE ZERO/);
    refused('a length of zero', HardyCross::Tools::loss(type => 'ASAM', size => 50, flow => 100, length => 0), 'LENGTH', qr/ABOVE ZERO/);
    refused('a C that is not a number', HardyCross::Tools::loss(type => 'ASAM', size => 50, flow => 100, c => 'C120'), 'C', qr/NOT A NUMBER/);
    refused('a negative roughness', HardyCross::Tools::loss(type => 'ASAM', size => 50, flow => 100, eps => -1), 'EPS', qr/CANNOT BE NEGATIVE/);
}

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
