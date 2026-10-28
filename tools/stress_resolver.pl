#!/usr/bin/perl
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
# Stress the pipe database resolver: every pipe type x every tabulated DN x every
# fitting code, then random and hostile fitting strings.
#
# The property that matters most: a
# fitting the data cannot support must come back as DATA_REQUIRED with a
# message.  It must NEVER come back as a quiet zero, a negative, a NaN or an
# undefined total without an error attached.
use strict; use warnings;
use FindBin; use lib "$FindBin::Bin/..";
use HardyCross::PipeData;
HardyCross::PipeData::load();
my $R = \&HardyCross::PipeData::resolve;

my @codes = qw(E EF EL E45 T GV GV75 GV50 GV25 CV CVM CVB BV AV GLV CPL TR
               E15 EM1 EM2 EM3 E45M1 E45M2 E60M1 E60M2 E30M1 E30M2 E15M1);
my (%tally, @bad);
my $cases = 0;

sub classify {
    my ($r, $what) = @_;
    $cases++;
    my $t = $r->{total};
    if (!defined $t) {
        # undefined total is only legitimate WITH an error explaining it
        return push @bad, "$what: undefined total with no error" unless @{ $r->{errors} };
        $tally{DATA_REQUIRED}++;
        return;
    }
    return push @bad, "$what: non-finite total $t" if $t != $t || abs($t) == 9**9**9;
    return push @bad, "$what: negative total $t" if $t < 0;
    for my $rec (@{ $r->{records} }) {
        # A zero or absurd COUNT is as silent as a zero length -- the first
        # version of this check missed "0E" because it only looked at length.
        return push @bad, "$what: accepted a count of $rec->{count}"
            if $rec->{count} < 1 || $rec->{count} > 99;
        next if ($rec->{method} // '') eq 'NOT_COUNTED';
        # a counted fitting with zero length is exactly the silent zero Clause
        # 6.10 forbids
        return push @bad, "$what: counted fitting $rec->{code} resolved to ZERO"
            if defined $rec->{each} && $rec->{each} == 0;
    }
    $tally{ $t == 0 ? 'NOT_COUNTED' : 'RESOLVED' }++;
}

print "EXHAUSTIVE SWEEP\n";
for my $type (HardyCross::PipeData::pipe_types()) {
    for my $dn (15 .. 700) {
        next unless defined HardyCross::PipeData::bore($type, $dn);
        for my $code (@codes) {
            classify($R->(type => $type, dn => $dn, spec => $code), "$type DN$dn $code");
            classify($R->(type => $type, dn => $dn, spec => $code, standard_only => 1),
                     "$type DN$dn $code (standard-only)");
        }
    }
}
printf "  %d cases: %d resolved, %d not counted, %d DATA_REQUIRED\n",
    $cases, map { $tally{$_} // 0 } qw(RESOLVED NOT_COUNTED DATA_REQUIRED);

print "SIZES THAT DO NOT EXIST\n";
my $before = @bad;
for my $dn (0, 1, 17, 99, 101, 149, 151, 199, 201, 999, -50) {
    my $r = $R->(type => 'ASAM', dn => $dn, spec => '2E');
    push @bad, "ASAM DN$dn resolved when it is not tabulated" if defined $r->{total};
}
printf "  %s\n", @bad == $before ? 'every untabulated DN refused' : 'FAILURES';

print "RANDOM AND HOSTILE STRINGS\n";
srand 20260921;
my @hostile = ('', ',', ',,,', '0E', '00E', '1000000E', '-2E', '2.5E', 'E E E',
               '2e,1t', '2E;1T', '2E 1T', 'E' x 500, '1E' x 200, '2EX', 'X', '2',
               "2E\x{2013}1T", "2E\t1T", '999999999999999999999E', '1E+1T',
               '+++', '2E++1T', ' 2E , 1T ');
my @alpha = (@codes, 'X', 'Q', 'Z', ',', '+', 0, 1, 2, 9, '.', '-', 'E1');
for (1 .. 20000) {
    my $s = join '', map { $alpha[ rand @alpha ] } 1 .. 1 + int rand 12;
    push @hostile, $s;
}
my ($ok, $rej) = (0, 0);
for my $s (@hostile) {
    my $r = eval { $R->(type => 'ASAM', dn => 50, spec => $s) };
    if (!$r) { push @bad, "string '" . substr($s, 0, 40) . "' crashed: $@"; next }
    classify($r, "string '" . substr($s, 0, 40) . "'");
    defined $r->{total} ? $ok++ : $rej++;
}
printf "  %d strings: %d accepted, %d rejected with a reason, no crashes\n",
    scalar @hostile, $ok, $rej;

print "\n", (@bad ? scalar(@bad) . " PROBLEMS\n" . join("\n", map { "  $_" } @bad[0 .. ($#bad < 19 ? $#bad : 19)]) . "\n"
                  : "0 problems\n");
exit(@bad ? 1 : 0);
