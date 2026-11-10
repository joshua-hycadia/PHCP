#!/usr/bin/perl
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# test_results.pl -- the results saved back into the .phc (HardyCross::Results).
#
#   perl tools/test_results.pl
#
#   1. THE BLOCK.  phcp.pl --save writes one results block at the end of the
#      model; saving again replaces it; the model above it is byte for byte
#      what it was.
#   2. IT CHANGES NOTHING.  The model with its block solves to exactly the
#      same flows and pressures as without; the editor does not show it.
#   3. IT IS THE SOLVE.  Every pipe flow, node pressure and the acceptance in
#      the block are the solve's, read back with read_block; the fingerprint
#      matches the model, and stops matching when the model is edited.
#==============================================================================
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";
use HardyCross;
use HardyCross::Phc;
use HardyCross::Results;
use HardyCross::Validate;
use HardyCross::Editor;

my $EX = "$FindBin::Bin/../examples";
my $TMP = "$FindBin::Bin/../.test_results_tmp";
mkdir $TMP;
my ($pass, $fail) = (0, 0);
sub is {
    my ($name, $ok, $why) = @_;
    printf "  %-68s %s\n", $name, $ok ? 'ok' : '*** FAIL';
    print "      $why\n" if !$ok && defined $why;
    $ok ? $pass++ : $fail++;
}
sub slurp { my $p = shift; open my $f, '<', $p or die "$p: $!\n"; local $/; my $t = <$f>; $t =~ s/\r\n/\n/g; $t }
sub save { my $m = shift; system("\"$^X\" \"$FindBin::Bin/../phcp.pl\" --save \"$m\" > \"$TMP/out.txt\"") >> 8 }
sub plain { my $p = shift; my $o = `"$^X" "$FindBin::Bin/../phcp.pl" "$p"`; $o =~ s/^# .*\n//mg; $o }

print "1. THE BLOCK\n";
for my $ex (qw(01_single_branch 06_orifice 09_parallel_pumps)) {
    my $orig = slurp("$EX/$ex.phc");
    my $m = "$TMP/$ex.phc";
    open my $f, '>', $m or die; binmode $f; print $f $orig; close $f;
    my $code = save($m);
    my $once = slurp($m);
    my $n = () = $once =~ /^\Q$HardyCross::Results::BEGIN\E/mg;
    is("$ex: --save writes one block at the end (exit $code)", $n == 1 && $once =~ /^\Q$HardyCross::Results::END\E\n\z/m);
    is('   the model above it is exactly as it was', HardyCross::Results::strip($once) eq $orig);
    save($m);
    my $twice = slurp($m);
    $n = () = $twice =~ /^\Q$HardyCross::Results::BEGIN\E/mg;
    is('   saving again replaces it: still one, the model unchanged', $n == 1 && HardyCross::Results::strip($twice) eq $orig);

    print "2. IT CHANGES NOTHING ($ex)\n" if $ex eq '01_single_branch';
    is('   solved with its block: the same flows and pressures', plain($m) eq plain("$EX/$ex.phc"));
    is('   the editor opens it without the block', HardyCross::Editor::load_file($m)->{text} eq $orig);

    my $net = HardyCross::Phc::read_string($twice);
    my $ok = HardyCross::solve_model($net);
    my $rows = HardyCross::Results::read_block($twice);
    my %pipe = map { $_->[1] => { @$_[2 .. $#$_] } } grep { $_->[0] eq 'PIPE' } @$rows;
    my %node = map { $_->[1] => { @$_[2 .. $#$_] } } grep { $_->[0] eq 'NODE' } @$rows;
    my ($res) = map { +{ @$_[1 .. $#$_] } } grep { $_->[0] eq 'RESULT' } @$rows;
    my ($model) = map { +{ @$_[1 .. $#$_] } } grep { $_->[0] eq 'MODEL' } @$rows;
    my $bad = 0;
    for my $e (grep { $_->{kind} eq 'PIPE' } @{ $net->{elems} }[1 .. $#{ $net->{elems} }]) {
        $bad++ unless $pipe{ $e->{id} } && abs($pipe{ $e->{id} }{FLOW} - $e->{q} / $net->{f_flow}) < 1e-4;
    }
    for my $i (1 .. $#{ $net->{nodes} }) {
        my $nd = $net->{nodes}[$i];
        next if $nd->{id} eq 'REF';
        my $p = ($nd->{h} - $HardyCross::GAMMA_W * $nd->{z}) / $net->{f_pres};
        $bad++ unless $node{ $nd->{id} } && abs($node{ $nd->{id} }{PRESSURE} - $p) < 1e-4;
    }
    is('   every pipe flow and node pressure in it is the solve\'s', !$bad && keys %pipe, "$bad differ");
    is("   its acceptance is the solve's ($res->{ACCEPTANCE})",
       $res->{ACCEPTANCE} eq HardyCross::Validate::validate($net, $ok)->{acceptance});
    is('   its fingerprint is the model\'s', $model->{SHA256} eq HardyCross::Results::fingerprint($twice));
    is('   and an edited model no longer matches it',
       $model->{SHA256} ne HardyCross::Results::fingerprint(HardyCross::Results::strip($twice) . "// EDITED\n"));
}
{
    my $code = system("$^X \"$FindBin::Bin/../phcp.pl\" --save - < \"$EX/01_single_branch.phc\" 2>/dev/null") >> 8;
    is('--save with the model on standard input is refused', $code != 0);
}

unlink glob("$TMP/*");
rmdir $TMP;
printf "\n%d passed, %d failed\n", $pass, $fail;
exit($fail ? 1 : 0);
