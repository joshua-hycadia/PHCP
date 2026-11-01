#!/usr/bin/perl
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# test_sizing.pl -- auto pipe sizing (HardyCross::Sizing), headless.
#
#   perl tools/test_sizing.pl
#
#   1. READING.  SIZE 0 under a pipe type reads, at the smallest size with
#      every fitting in the database; under USE BORE it is refused; the two
#      settings are checked.
#   2. THE ANSWER PASSES.  Checked here, independently of the search: the
#      sized model re-read and its demand point found - the margin under the
#      supply is at least what was asked, as a percentage or a pressure, and
#      no sized pipe exceeds the velocity limit.
#   3. NO SMALLER WILL DO.  Each sized pipe one size smaller fails that same
#      check (SMALLEST).  VOLUME holds no more water than SMALLEST.
#   4. WHAT IS SIZED TOGETHER.  A PIPE line sizes its copies (PC) with it, and
#      the size is written after the PC line too; a CHANGEPIPE line sizes its
#      one pipe.
#   5. THE COMMENTS.  //AS - <size> after each sized line, SIZE 0 kept, a
#      comment of the user's own kept after it, an old //AS replaced; the
#      annotated model sizes the same again.
#   6. WHEN NOTHING WILL DO.  A supply too weak: the largest sizes, a warning,
#      and the report says NOT MET.
#   7. WITH DESIGN AREAS, IN INCHES, IN THE REPORT AND THE JSON.
#==============================================================================
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";
use HardyCross;
use HardyCross::Phc;
use HardyCross::Demand;
use HardyCross::Sizing;
use HardyCross::Areas;
use HardyCross::Report;
use HardyCross::Json;

my ($pass, $fail) = (0, 0);
sub is {
    my ($name, $ok, $why) = @_;
    printf "  %-68s %s\n", $name, $ok ? 'ok' : '*** FAIL';
    print "      $why\n" if !$ok && defined $why;
    $ok ? $pass++ : $fail++;
}
sub refused {
    my ($name, $text, $re) = @_;
    my $net = eval { HardyCross::Phc::read_string($text) };
    my $e = $@ && HardyCross::is_model_error($@) ? $@->{msg} : "$@";
    is($name, !$net && $e =~ $re, $net ? 'it was accepted' : "got: $e");
}
# sized -- the model read, solved and sized, as phcp.pl does it.
sub sized {
    my $n = HardyCross::Phc::read_string(shift);
    my $ok = HardyCross::solve_model($n);
    ($n, $ok) = HardyCross::Sizing::size($n, $ok);
    return ($n, $ok);
}
# check -- the independent check of a model text with sizes in it: the
# demand point's margin against what is asked, and the sized pipes' speeds.
sub check {
    my ($text, $pipes, %o) = @_;
    my $n = HardyCross::Phc::read_string($text);
    HardyCross::solve_model($n) or return { ok => 0, why => 'no solve' };
    my $d = HardyCross::Demand::demand_point($n);
    return { ok => 0, why => $d->{reason} } unless defined $d->{margin};
    my $need = $o{pct} ? $o{pct} / 100 * $d->{p_avail} : $o{fixed} // 0;
    my %e = map { ($_->{id} // '') => $_ } @{ $n->{elems} }[1 .. $#{ $n->{elems} }];
    my ($vmax) = sort { $b <=> $a } map { abs HardyCross::pipe_velocity($e{$_}{q}, $e{$_}{dia}) } @$pipes;
    return { ok => $d->{margin} >= $need - 0.01 && $vmax <= ($o{vlim} // 6) + 1e-6,
             margin => $d->{margin}, need => $need, vmax => $vmax };
}
# with -- a model text with each unit at the size given (DN or index).
sub with {
    my ($text, $units, $tok) = @_;
    my @l = split /\n/, $text, -1;
    for my $i (0 .. $#$units) {
        $l[ $units->[$i]{line} - 1 ] = HardyCross::Sizing::set_field($l[ $units->[$i]{line} - 1 ],
            $units->[$i]{kind} eq 'CHANGEPIPE' ? 3 : 5, $tok->[$i]);
    }
    return join "\n", @l;
}

# A floor: a town main, a riser and two branch lines of four K80 heads.
my $FLOOR = join "\n",
    'UNITS LENGTH M', 'UNITS KFACTOR LPM/BAR',
    'WATER TOWN 0 450 1000 380 2000 250',
    'NODE R0 0', 'NODE R1 4', 'NODE J1 4', 'NODE J2 4',
    'SPRINKLER A1 4 -100 80', 'NC A1 A2 A3 A4 B1 B2 B3 B4',
    'USE ASAM',
    'PIPE M1 TOWN R0 30 100', 'PIPE RS R0 R1 4 100 E', 'PIPE H1 R1 J1 10 80 T',
    'PIPE H2 J1 J2 40 0',
    'PIPE LA1 J1 A1 3 0 T', 'PIPE LA2 A1 A2 3 0', 'PIPE LA3 A2 A3 3 0', 'PIPE LA4 A3 A4 3 0',
    'PIPE LB1 J2 B1 3 0 T', 'PIPE LB2 B1 B2 3 0', 'PIPE LB3 B2 B3 3 0', 'PIPE LB4 B3 B4 3 0', '';
my @AUTO = qw(H2 LA1 LA2 LA3 LA4 LB1 LB2 LB3 LB4);

print "1. READING\n";
{
    my $n = HardyCross::Phc::read_string($FLOOR);
    my %u = map { $_->{pipes}[0] => $_ } @{ $n->{auto_sizing} || [] };
    my %dn = map { $_->{id} => $_ } grep { $_->{kind} eq 'PIPE' } @{ $n->{elems} }[1 .. $#{ $n->{elems} }];
    is('nine pipes of size 0 are to be sized', keys %u == 9 && !grep { !$u{$_} } @AUTO);
    is('   each read at the smallest size its type has: ASAM DN20',
       $u{LA2}{choices}[0][0] == 20 && abs($dn{LA2}{dia} - HardyCross::PipeData::bore('ASAM', 20)) < 1e-9);
    is('   a pipe with a tee starts where the tee has a value too',
       !grep { !defined HardyCross::PipeData::resolve(type => 'ASAM', dn => $_->[0], spec => 'T')->{total} } @{ $u{LA1}{choices} });
    is('   the sizes go up to the largest ASAM has, DN150', $u{LA2}{choices}[-1][0] == 150);
    refused('SIZE 0 under USE BORE is refused, saying a pipe type is needed',
            "WATER W 0 500\nSPRINKLER S 0 -50 8\nUSE BORE\nPIPE P1 W S 3 0\n", qr/^line 4: .*SIZE 0 .*NEEDS A PIPE TYPE/);
    refused('SIZING_GOAL other than SMALLEST or VOLUME', $FLOOR . "OPTION SIZING_GOAL CHEAPEST\n", qr/SIZING_GOAL IS SMALLEST .* OR VOLUME/);
    refused('SIZING_MARGIN that is neither 10% nor a pressure', $FLOOR . "OPTION SIZING_MARGIN TEN\n", qr/SIZING_MARGIN 'TEN' IS A PERCENTAGE/);
    refused('   nor 100% or more', $FLOOR . "OPTION SIZING_MARGIN 100%\n", qr/IS A PERCENTAGE/);
    refused('   nor below zero', $FLOOR . "OPTION SIZING_MARGIN -5\n", qr/IS A PERCENTAGE/);
    refused('SIZING_TRIALS of 0', $FLOOR . "OPTION SIZING_TRIALS 0\n", qr/SIZING_TRIALS '0' IS A WHOLE NUMBER OF TRIALS, 1 TO 50/);
    refused('   or 51, or 2.5', $FLOOR . "OPTION SIZING_TRIALS 2.5\n", qr/IS A WHOLE NUMBER OF TRIALS/);
    my $c = HardyCross::Phc::check_line('PIPE P9 A B 3 0 T', { use => 'ASAM' });
    is('the editor\'s line check takes SIZE 0 under a pipe type', $c->{status} eq 'ok', $c->{message});
}

print "2. THE ANSWER PASSES - checked at the demand point\n";
my %res;
for my $case ([ 'SIZING_MARGIN 10%', pct => 10 ], [ 'SIZING_MARGIN 50', fixed => 50 ], [ '', fixed => 0 ]) {
    my ($opt, %o) = @$case;
    my ($n, $ok) = sized($FLOOR . (length $opt ? "OPTION $opt\n" : ''));
    my $s = $n->{sizing};
    my $chk = check($n->{source_text}, \@AUTO, %o);
    $res{$opt} = [ $n, $s ];
    is(sprintf('%s: passes, margin %.1f kPa against %.1f asked, fastest sized pipe %.2f m/s',
               length $opt ? $opt : 'no margin', $chk->{margin} // 0, $chk->{need} // 0, $chk->{vmax} // 0),
       $ok && $s->{passes} && $chk->{ok}, $chk->{why});
}

print "3. NO SMALLER WILL DO\n";
{
    my ($n, $s) = @{ $res{'SIZING_MARGIN 10%'} };
    my @u = @{ $s->{units} };
    my $text = $s->{text} . "OPTION SIZING_MARGIN 10%\n";
    my @dn = map { $_->{dn} } @u;
    my @bad;
    for my $i (0 .. $#u) {
        my @ch = map { $_->[0] } @{ HardyCross::Phc::read_string($FLOOR)->{auto_sizing}[$i]{choices} };
        my ($k) = grep { $ch[$_] == $dn[$i] } 0 .. $#ch;
        next unless $k;
        my @t = @dn; $t[$i] = $ch[ $k - 1 ];
        push @bad, "$u[$i]{pipes}[0] at DN$t[$i]" if check(with($FLOOR, \@u, \@t), \@AUTO, pct => 10)->{ok};
    }
    is('SMALLEST: each sized pipe one size smaller fails the check', !@bad, "still passes: @bad");
    my ($nv) = sized($FLOOR . "OPTION SIZING_MARGIN 10%\nOPTION SIZING_GOAL VOLUME\n");
    my $vol = sub { my $sz = shift; my $v = 0; my %len = (H2 => 40); $v += ($len{ $_->{pipes}[0] } // 3)
                    * (HardyCross::PipeData::bore('ASAM', $_->{dn}) / 1000) ** 2 for @{ $sz->{units} }; $v * 0.7853981634 };
    is(sprintf('VOLUME: %.1f L of water in the sized pipes, SMALLEST %.1f L - no more',
               1000 * $vol->($nv->{sizing}), 1000 * $vol->($s)),
       $nv->{sizing}{passes} && $vol->($nv->{sizing}) <= $vol->($s) + 1e-12
       && check($nv->{source_text}, \@AUTO, pct => 10)->{ok});
}

print "3a. TRIALS\n";
{
    my ($n, $s) = @{ $res{'SIZING_MARGIN 10%'} };
    my @t = @{ $s->{trials} };
    is('5 trials unless set: from the smallest, from the largest, then varied',
       $s->{ntrials} == 5 && @t == 5 && $t[0]{from} eq 'the smallest sizes' && $t[1]{from} eq 'the largest sizes'
       && $t[2]{from} =~ /varied/);
    my ($chosen) = grep { $_->{best} } @t;
    is('   exactly one is chosen, and no trial that passes costs less',
       (grep { $_->{best} } @t) == 1 && !grep { $_->{passes} && $_->{objective} < $chosen->{objective} - 1e-12 } @t);
    is('   the sizes chosen are that trial\'s',
       join(' ', map { $_->{dn} } @{ $s->{units} }) eq join(' ', @{ $chosen->{sizes} }));
    my ($again) = sized($FLOOR . "OPTION SIZING_MARGIN 10%\n");
    is('the same model gives the same sizes every time',
       join(' ', map { $_->{dn} } @{ $again->{sizing}{units} }) eq join(' ', map { $_->{dn} } @{ $s->{units} }));
    my @said;
    my $n1 = HardyCross::Phc::read_string($FLOOR . "OPTION SIZING_TRIALS 1\n");
    my ($o1) = HardyCross::Sizing::size($n1, HardyCross::solve_model($n1), progress => sub { push @said, shift });
    is('SIZING_TRIALS 1: one trial', @{ $o1->{sizing}{trials} } == 1 && $o1->{sizing}{passes});
    is('   and the search says where it is as it goes', @said > 10 && $said[-1] =~ /^AUTO SIZING 9 PIPES - TRIAL 1 OF 1 - \d+ SOLVES$/, $said[-1]);
}

print "4. WHAT IS SIZED TOGETHER\n";
{
    my $m = join "\n", 'UNITS LENGTH M', 'WATER W 0 400', 'NODE J 0', 'USE ASAM', 'PIPE M W J 20 80',
        'SPRINKLER S1 0 -50 8', 'NC S1 S2 S3', 'PIPE P1 J S1 6 0 T', 'PC P1 P2 J S2  P3 J S3',
        'CHANGEPIPE P3 15 0 T E', '';
    my ($n) = sized($m);
    my %u = map { $_->{line} => $_ } @{ $n->{sizing}{units} };
    is('the PIPE line sizes P1 and its unchanged copy P2 together',
       $u{8} && "@{ $u{8}{pipes} }" eq 'P1 P2' && "@{ $u{8}{lines} }" eq '8 9');
    is('   the CHANGEPIPE line sizes P3 on its own', $u{10} && "@{ $u{10}{pipes} }" eq 'P3');
    my %d = map { $_->{id} => $_->{dia} } grep { $_->{kind} eq 'PIPE' } @{ $n->{elems} }[1 .. $#{ $n->{elems} }];
    is('   P1 and P2 come out the same size', $d{P1} == $d{P2});
    my @a = split /\n/, HardyCross::Sizing::annotate($m, $n->{sizing});
    is('the size is written after the PIPE, PC and CHANGEPIPE lines',
       $a[7] =~ m{//AS - \d+$} && $a[8] =~ m{//AS - \d+$} && $a[9] =~ m{//AS - \d+$} && $a[4] !~ /AS/);
}

print "5. THE COMMENTS\n";
{
    my $m = join "\n", 'WATER W 0 500', 'USE ASAM', 'PIPE P1 W A 20 0', 'NODE A 0',
        'PIPE P2 A S 6 0 T   // TO THE HEAD', 'SPRINKLER S 0 -50 8', '';
    my ($n) = sized($m);
    my $a = HardyCross::Sizing::annotate($m, $n->{sizing});
    my @a = split /\n/, $a;
    is('//AS - <size> after the sized line, SIZE 0 kept', $a[2] =~ m{^PIPE P1 W A 20 0  //AS - (\d+)$} && $1 == $n->{sizing}{units}[0]{dn});
    is('   the line\'s own comment kept after it', $a[4] =~ m{^PIPE P2 A S 6 0 T  //AS - \d+ // TO THE HEAD$}, $a[4]);
    is('   lines not sized untouched', $a[0] eq 'WATER W 0 500' && $a[3] eq 'NODE A 0');
    my ($n2) = sized($a);
    my $a2 = HardyCross::Sizing::annotate($a, $n2->{sizing});
    is('the annotated model sizes the same, and its comments are replaced, not added to', $a2 eq $a, $a2);
    (my $stale = $a) =~ s{//AS - \d+}{//AS - 999}g;
    is('   a stale //AS is put right', HardyCross::Sizing::annotate($stale, $n->{sizing}) eq $a);
    is('clear takes them off again', HardyCross::Sizing::clear($a) eq ($m =~ s/T   \/\/ TO/T \/\/ TO/r));
}

print "6. WHEN NOTHING WILL DO\n";
{
    (my $weak = $FLOOR) =~ s/WATER TOWN 0 450 1000 380 2000 250/WATER TOWN 0 150 1000 60/;
    my ($n, $ok) = sized($weak);
    my $s = $n->{sizing};
    is('a supply too weak: not met, every sized pipe at its largest, DN150',
       !$s->{passes} && !grep { $_->{dn} != 150 } @{ $s->{units} });
    is('   a warning says so', grep { /^auto sizing: even the largest sizes/ } @{ $n->{warnings} });
    my $rep = HardyCross::Report::write_report($n, $ok, 'weak.phc');
    (my $flat = $rep) =~ s/\s+/ /g;
    is('   and the report: NOT MET', $flat =~ /NOT MET: even the largest sizes in the database/);
}

print "7. WITH DESIGN AREAS, IN INCHES, IN THE REPORT AND THE JSON\n";
{
    my $m = $FLOOR . "AREA NEAR A1 A2 A3 A4\nAREA FAR B1 B2 B3 B4\nOPTION SIZING_MARGIN 10%\n";
    my ($n, $ok) = sized($m);
    my @bad;
    for my $a (qw(NEAR FAR)) {
        my $c = check($n->{source_text} . "OPTION DESIGN_AREA $a\n", \@AUTO, pct => 10);
        push @bad, $a unless $c->{ok};
    }
    is('with AREA lines, the sizes pass in every area', $n->{sizing}{passes} && !@bad, "fails in @bad");
    my @said;
    my ($g, $gok) = HardyCross::Areas::governing($n, $ok, progress => sub { push @said, shift });
    is('   and the design areas are then reported from the sized model',
       $gok && $g->{area_results} && @{ $g->{area_results} } == 2);
    is('   each area said as it is solved', "@said" eq 'DESIGN AREA NEAR - 1 OF 2 DESIGN AREA FAR - 2 OF 2', "@said");
    (my $in = $FLOOR) =~ s/^UNITS LENGTH M$/UNITS LENGTH M\nUNITS SIZE IN/m;
    $in =~ s/^(PIPE M1 TOWN R0 30) 100$/$1 4/m;
    $in =~ s/^(PIPE RS R0 R1 4) 100 E$/$1 4 E/m;
    $in =~ s/^(PIPE H1 R1 J1 10) 80 T$/$1 3 T/m;
    my ($ni) = sized($in);
    my %inch = reverse HardyCross::Phc::inch_sizes();
    is('with UNITS SIZE IN, each size is written as its inch size',
       !grep { $_->{token} ne $inch{ $_->{dn} } } @{ $ni->{sizing}{units} });
    my ($r) = @{ $res{'SIZING_MARGIN 10%'} };
    my $rep = HardyCross::Report::write_report($r, 1, 'floor.phc');
    is('the report lists each sized pipe, its size and velocity, and the margin met',
       $rep =~ /^ AUTO PIPE SIZING$/m && $rep =~ /^ \d+\s+PIPE\s+ASAM\s+LA1\s+DN\d+\s+[\d.]+$/m
       && ($rep =~ s/\s+/ /gr) =~ /Met: at the demand point the supply has [\d.]+ kPa to spare, against [\d.]+ kPa asked for/);
    my $j = HardyCross::Json::results($r, 1, 'floor.phc');
    is('the JSON lists them as sized', ref $j->{sized} eq 'ARRAY' && @{ $j->{sized} } == 9 && $j->{sized}[0]{dn});
    my ($plain) = HardyCross::Phc::read_string(slurp("$FindBin::Bin/../examples/01_single_branch.phc"));
    is('a model with no size 0 is not touched', !$plain->{auto_sizing} && (HardyCross::Sizing::size($plain, 1))[0] == $plain);
}

sub slurp { my $p = shift; open my $f, '<', $p or die "$p: $!\n"; local $/; <$f> }

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
