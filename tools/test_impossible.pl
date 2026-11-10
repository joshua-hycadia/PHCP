#!/usr/bin/perl
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# test_impossible.pl -- models that must NOT be accepted, run through the
# program a user runs.
#
#   perl tools/test_impossible.pl              through phcp.pl
#   perl tools/test_impossible.pl phcp.exe     through the built program
#
# Every model in tools/impossible/ states, on a line "// EXPECT: <exit>
# <acceptance>", what phcp --json --strict must do with it: the exit status
# and the acceptance in the JSON.  Each holds a condition that cannot be a
# valid, compliant design -- most of them were accepted before 11 November
# 2026.  valid_control.phc is the one that must be ACCEPTED, so that a
# program refusing everything cannot pass.
#==============================================================================
use strict;
use warnings;
use FindBin;
use JSON::PP;

my $exe = shift;
my @cmd = $exe ? ($exe) : ($^X, "$FindBin::Bin/../phcp.pl");
my ($pass, $fail) = (0, 0);
sub is {
    my ($name, $ok, $why) = @_;
    printf "  %-60s %s\n", $name, $ok ? 'ok' : '*** FAIL';
    print "      $why\n" if !$ok && defined $why;
    $ok ? $pass++ : $fail++;
}

my $dir = "$FindBin::Bin/impossible";
opendir my $dh, $dir or die "$dir: $!\n";
my @models = sort grep { /\.phc\z/ } readdir $dh;
closedir $dh;
die "no models in $dir\n" unless @models;
for my $m (@models) {
    my $path = "$dir/$m";
    my $text = do { open my $f, '<', $path or die "$path: $!\n"; local $/; <$f> };
    my ($want_x, $want_a) = $text =~ m{^// EXPECT: (\d+) (\w+)}m or die "$m: no EXPECT line\n";
    my $q = join ' ', map { /\s/ ? qq{"$_"} : $_ } @cmd;
    my $out = `$q --json --strict "$path" 2>&1`;
    my $x = $? >> 8;
    my ($json) = $out =~ /(\{.*\})/s;
    my $j = eval { decode_json($json // '{}') } || {};
    my $acc = $j->{acceptance} // 'none';
    is(sprintf('%-26s exit %d, %s', $m, $want_x, $want_a), $x == $want_x && $acc eq $want_a,
       "exit $x, $acc");
    is(sprintf('%-26s %s', $m, $want_a eq 'ACCEPTED' ? 'approved' : 'not approved'),
       ($want_a eq 'ACCEPTED') == !!($j->{approved} // 0)) unless $want_a eq 'ERROR';
}
printf "\n%d passed, %d failed\n", $pass, $fail;
exit($fail ? 1 : 0);
