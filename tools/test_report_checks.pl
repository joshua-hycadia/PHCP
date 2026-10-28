#!/usr/bin/perl
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# test_report_checks.pl -- does the report's arithmetic close ON THE PAGE?
#
# The report promises that every figure can be reproduced by hand from others
# printed beside it, and tells the reader which check to make.  This test takes
# that promise literally: it reads the printed report as TEXT -- never the
# solver's internal numbers -- and does the arithmetic a checker would do with
# a calculator.  A check that only closes to full machine precision, and
# misses once the figures are rounded for print, fails here.
#
# It exists because one did: a loss-per-metre column printed to four decimals
# was ample in kPa/m and lost two significant figures in bar/m, so PF/M x T
# missed PF by 2 % in any model written in bar.
#
#   perl tools/test_report_checks.pl [model.hcx ...]
#==============================================================================
use strict;
use warnings;
use FindBin;
use File::Temp qw(tempfile);

my @models = @ARGV ? @ARGV : glob("$FindBin::Bin/../examples/*.hcx");
@models = grep { !/grid1000/ } @models;          # large; adds nothing here
my ($checks, $fails) = (0, 0);
my @bad;

# The tolerance a checker would accept: the rounding of every printed figure
# that went into the sum, plus one unit in the last place of the result.
sub ulp { my $s = shift; return $s =~ /\.(\d+)/ ? 10 ** -length($1) : 1 }

sub close_to {
    my ($what, $got, $want, $tol) = @_;
    $checks++;
    return 1 if abs($got - $want) <= $tol;
    $fails++;
    push @bad, sprintf('%s: worked %.6g, printed %.6g, allowed %.2g', $what, $got, $want, $tol)
        if @bad < 20;
    return 0;
}

for my $m (@models) {
    my (undef, $rep) = tempfile(SUFFIX => '.txt', UNLINK => 1);
    system("\"$FindBin::Bin/../phcp.pl\" \"$m\" \"$rep\" >/dev/null 2>&1");
    next unless -s $rep;
    open my $fh, '<', $rep or next;
    my @L = <$fh>;
    close $fh;
    (my $name = $m) =~ s{.*/}{};

    my $sec = '';
    for my $li (0 .. $#L) {
        my $l = $L[$li];
        $sec = $1 if $l =~ /^ (\d+)\. [A-Z]/;

        # PIPE SCHEDULE, NFPA four-line blocks:
        #   TL = L + F,  Pf = FRI-LOSS x TL,  Pt END = Pt BEG - Pe - Pf,  Pn = Pt BEG - Pv
        if ($sec eq '6' && $l =~ /\bL=\s*([\d.]+).*\bPt\s+(-?[\d.]+)\s+Pt\s+(-?[\d.]+)\s*$/) {
            my ($len, $ptb) = ($1, $2);
            my $at = $li;          # by position: two identical lines cannot be confused
            my ($l2, $l3, $l4) = @L[ $at + 1 .. $at + 3 ];
            my ($pipe) = $l2 =~ /^\s(\S+)/;
            my ($ftg, $pe, $pv) = $l2 =~ /F=\s*(-?[\d.]+)\s+C=.*\bPe\s+(-?[\d.]+)\s+Pv\s+(-?[\d.]+)/;
            my ($tl, $frl, $pf, $pn) = $l3 =~ /TL=\s*([\d.]+)\s+([\d.]+)\s+Pf\s+(-?[\d.]+)\s+Pn\s+(-?[\d.]+)/;
            my ($pte) = $l4 =~ /\bPt\s+(-?[\d.]+)\s*$/;
            if (defined $ftg && defined $tl && defined $pte) {
                close_to("$name pipe $pipe TL = L + F", $len + $ftg, $tl,
                         ulp($len) + ulp($ftg) + ulp($tl));
                close_to("$name pipe $pipe Pf = FRI-LOSS x TL", $frl * $tl, abs $pf,
                         $frl * ulp($tl) / 2 + $tl * ulp($frl) / 2 + ulp($pf));
                close_to("$name pipe $pipe Pt END = Pt BEG - Pe - Pf", $ptb - $pe - $pf, $pte,
                         ulp($ptb) + ulp($pe) + ulp($pf) + ulp($pte));
                close_to("$name pipe $pipe Pn = Pt - Pv", $ptb - $pv, $pn,
                         ulp($ptb) + ulp($pv) + ulp($pn));
            } else {
                close_to("$name pipe block after '" . substr($l, 0, 30) . "' parsed", 0, 1, 0);
            }
        }

        # COVER SHEET (before Section 1):
        #   cushion = available - demand,  computed density = lowest flow / area
        if ($sec eq '' && $l =~ /^\s+Pressure cushion\s+(-?[\d.]+)/) {
            my $cush = $1;
            my ($av) = map { /available at the demand flow\s+(-?[\d.]+)/ ? $1 : () } @L;
            my ($dr) = map { /Demand pressure required\s+(-?[\d.]+)/ ? $1 : () } @L;
            close_to("$name cover cushion = available - demand", $av - $dr, $cush,
                     ulp($av) + ulp($dr) + ulp($cush)) if defined $av && defined $dr;
        }
        if ($sec eq '' && $l =~ /^\s+Computed density .*?mm\/min\s+(\S+)\s+(\S+)/) {
            my @dens = ($1, $2);
            my ($aps) = map { /Area per sprinkler\s+:\s+([\d.]+)/ ? $1 : () } @L;
            my ($lowline) = grep { /^\s+Lowest sprinkler flow/ } @L;
            my @low = $lowline =~ /([\d.]+) \(/g;
            for my $k (0, 1) {
                next unless defined $low[$k] && $dens[$k] =~ /^[\d.]+$/ && $aps;
                close_to("$name cover computed density column " . ($k + 1), $low[$k] / $aps, $dens[$k],
                         ulp($low[$k]) / $aps + $low[$k] * ulp($aps) / $aps ** 2 + ulp($dens[$k]));
            }
        }

        # FLOW PATH:  P TO = P FROM - PF - PE,  PF = PF/M x T,  P TO = P SOLVED
        if ($sec eq '8' && $l =~ /^\s+\d+\s+\S+/) {
            my @f = split ' ', $l;
            next unless @f == 15;
            my ($t, $pfm, $pf, $pe, $pfr, $pto, $psol) = @f[6, 7, 9, 10, 11, 12, 13];
            close_to("$name path step $f[0] P TO = P FROM - PF - PE", $pfr - $pf - $pe, $pto,
                     ulp($pfr) + ulp($pf) + ulp($pe) + ulp($pto));
            close_to("$name path step $f[0] P TO = P SOLVED", $pto, $psol, ulp($pto) + ulp($psol))
                if $psol =~ /^-?[\d.]+$/;
            close_to("$name path step $f[0] PF = PF/M x T", $pfm * $t, $pf,
                     abs($pfm) * ulp($t) / 2 + $t * ulp($pfm) / 2 + ulp($pf))
                if $t =~ /^[\d.]+$/ && $pfm =~ /^[\d.]+$/;
        }

        # OUTLET COMPLIANCE:  ACT Q = K x sqrt(ACT P)
        if ($sec eq '7' && $l =~ /^ \S+\s+\S+\s+[\d.]+\s+[\d.]+\s+[\d.]+\s+[\d.]+\s+-?[\d.]+\s+(PASS|\*\*\*)/) {
            my @f = split ' ', $l;
            my ($k, $aq, $ap) = @f[2, 4, 6];
            close_to("$name outlet $f[0] Q = K sqrt(P)", $k * sqrt($ap), $aq,
                     $k * ulp($ap) / (2 * sqrt($ap)) + sqrt($ap) * ulp($k) / 2 + ulp($aq));
        }

        # NODE SCHEDULE:  PRESSURE + ELEV HEAD = TOTAL HEAD
        if ($sec eq '5' && $l =~ /^ \S+\s+-?[\d.]+\s+-?[\d.]+\s+-?[\d.]+\s+-?[\d.]+\s+/) {
            my @f = split ' ', $l;
            my ($eh, $p, $th) = @f[2, 3, 4];
            close_to("$name node $f[0] PRESSURE + ELEV HEAD = TOTAL HEAD", $p + $eh, $th,
                     ulp($p) + ulp($eh) + ulp($th));
        }
    }
}

printf "report hand-checks: %d checked across %d models, %d failed\n",
    $checks, scalar @models, $fails;
print "  $_\n" for @bad;
exit($fails ? 1 : 0);
