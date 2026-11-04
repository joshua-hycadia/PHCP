#!/usr/bin/perl
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# test_flow.pl -- the drawn network, HardyCross::Flow, without Tk.
#
#   perl tools/test_flow.pl
#
# A drawing is .phc.  These checks are that a file comes back as the same
# network (the same solved flows and pressures), that a position survives a
# save, and that the edits the window offers build a model the reader
# accepts.  The window itself is tools/test_flow_window.pl.
#==============================================================================
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";
use File::Temp qw(tempdir);
use HardyCross;
use HardyCross::Phc;
use HardyCross::Flow;

my ($pass, $fail) = (0, 0);
sub is {
    my ($name, $ok, $why) = @_;
    printf "  %-72s %s\n", $name, $ok ? 'ok' : '*** FAIL';
    print "      $why\n" if !$ok && defined $why;
    $ok ? $pass++ : $fail++;
}
sub slurp { my $p = shift; open my $f, '<', $p or die "$p: $!\n"; local $/; <$f> }

my $EX  = "$FindBin::Bin/../examples";
my $TMP = tempdir(CLEANUP => 1);

# solved -- flows and pressures in internal units, for a comparison.
sub solved {
    my $text = shift;
    my $net = HardyCross::Phc::read_string($text, '.');
    my $ok = HardyCross::solve_model($net);
    my (%q, %p);
    for my $i (1 .. $#{ $net->{elems} }) {
        $q{ $net->{elems}[$i]{id} } = $net->{elems}[$i]{q};
    }
    for my $i (1 .. $#{ $net->{nodes} }) {
        my $n = $net->{nodes}[$i];
        next if $n->{id} eq 'REF';
        $p{ $n->{id} } = $n->{h} - $HardyCross::GAMMA_W * $n->{z};
    }
    return { ok => $ok ? 1 : 0, q => \%q, p => \%p };
}

sub close_to {
    my ($a, $b, $tol) = @_;
    my %k = map { $_ => 1 } keys %$a, keys %$b;
    for my $k (sort keys %k) {
        return "$k missing on one side" unless exists $a->{$k} && exists $b->{$k};
        my $d = abs($a->{$k} - $b->{$k});
        return "$k differs by $d" if $d > $tol;
    }
    return '';
}

#==============================================================================
print "1. THE EXAMPLES, DRAWN AND WRITTEN BACK, SOLVE THE SAME\n";
#==============================================================================
for my $path (sort glob "$EX/*.phc") {
    my ($name) = $path =~ m{([^/]+)\z};
    my $text = slurp($path);
    my $doc = eval { HardyCross::Flow::read_text($text) };
    is("$name reads", $doc, $@ && (ref $@ ? $@->{msg} : $@));
    next unless $doc;
    my $back = HardyCross::Flow::write_text($doc);
    my $again = eval { HardyCross::Flow::read_text($back) };
    is("$name writes a file that reads", $again, $@ && (ref $@ ? $@->{msg} : $@));
    if ($name eq '04_grid1000.phc') {
        # The grid is a thousand blocks.  Reading it back is the check;
        # solving it is the stress test, not this one.
        my $net = eval { HardyCross::Phc::read_string($back, '.') };
        my $err = $@;
        $err = $err->{msg} if ref $err;
        is('   the 1000-node grid is a model again', $net && @{ $doc->{nodes} } >= 1000, $err);
        next;
    }
    my $left = eval { solved($text) };
    my $right = eval { solved($back) };
    is("$name solves", $left && $right, $@);
    next unless $left && $right;
    is("   $name converged, both ways", $left->{ok} && $right->{ok});
    is("   $name flows", !close_to($left->{q}, $right->{q}, 0.05), close_to($left->{q}, $right->{q}, 0.05));
    is("   $name pressures", !close_to($left->{p}, $right->{p}, 0.05), close_to($left->{p}, $right->{p}, 0.05));
}

#==============================================================================
print "2. WHAT THE DRAWING KEEPS\n";
#==============================================================================
{
    my $doc = HardyCross::Flow::read_text(slurp("$EX/01_single_branch.phc"));
    my ($water) = grep { $_->{kind} eq 'WATER' } @{ $doc->{nodes} };
    my ($head) = grep { $_->{kind} eq 'SPRINKLER' } @{ $doc->{nodes} };
    is('a supply is laid out to the left of the head', $water->{x} < $head->{x},
       "$water->{x} $head->{x}");
    is('the opening note is kept', (HardyCross::Flow::write_text($doc) =~ /^\/\/ 01 - SINGLE BRANCH/));

    $water->{x} = 40;
    $water->{y} = 50;
    $head->{x} = 400;
    $head->{y} = 180;
    my $doc2 = HardyCross::Flow::read_text(HardyCross::Flow::write_text($doc));
    my ($w2) = grep { $_->{name} eq 'N1' } @{ $doc2->{nodes} };
    my ($h2) = grep { $_->{name} eq 'N2' } @{ $doc2->{nodes} };
    is('a position comment survives a save', $w2->{x} == 40 && $w2->{y} == 50 && $h2->{x} == 400 && $h2->{y} == 180,
       "$w2->{x},$w2->{y} $h2->{x},$h2->{y}");
    my $moved = HardyCross::Flow::model_text($doc);
    HardyCross::Flow::move_node($doc, $head->{id}, 420, 200);
    is('moving a block does not change the model', HardyCross::Flow::model_text($doc) eq $moved);

    my $full = HardyCross::Flow::read_text(slurp("$EX/02_full_network.phc"));
    my ($bfp) = grep { $_->{name} eq 'BFP1' } @{ $full->{edges} };
    my ($op) = grep { $_->{name} eq 'OP1' } @{ $full->{edges} };
    my ($ofd) = grep { $_->{name} eq 'OP2' } @{ $full->{edges} };
    my ($pmp) = grep { $_->{kind} eq 'PUMP' } @{ $full->{edges} };
    is('a backflow preventer stays on its pipe', $bfp && $bfp->{device}{kind} eq 'BFP'
       && $bfp->{device}{pairs}[0] == 0 && $bfp->{device}{pairs}[1] == 0);
    is('an orifice drop and a bore are kept',
       $op && $op->{device}{kind} eq 'OPP' && $op->{device}{drop} == 80
       && $ofd && $ofd->{device}{kind} eq 'OFD' && $ofd->{device}{bore} == 22);
    is('equivalent length stays on the pipe', (grep { $_->{name} eq 'M1' && $_->{eqv} == 8 } @{ $full->{edges} }) == 1);
    is('a pump joins its two blocks', $pmp && $pmp->{name} eq 'PMP1' && @{ $pmp->{pairs} } == 4);

    my $areas = HardyCross::Flow::read_text(slurp("$EX/11_design_areas.phc"));
    is('K in L/min per bar is kept', $areas->{units}{KFACTOR} eq 'LPM/BAR');
    my ($far) = grep { $_->{name} eq 'FAR' } @{ $areas->{areas} };
    is('a design area lists its heads', $far && join(' ', @{ $far->{outlets} }) eq 'B1 B2 B3 B4');

    my $sized = HardyCross::Flow::read_text(slurp("$EX/12_auto_sizing.phc"));
    my @copies = grep { $_->{kind} eq 'SPRINKLER' && $_->{name} =~ /^[AB]/ } @{ $sized->{nodes} };
    is('a copied head becomes a head of its own', @copies == 8);
    is('a size of 0 is still a size of 0', (grep { $_->{name} eq 'H2' && $_->{size} == 0 } @{ $sized->{edges} }) == 1);
}

#==============================================================================
print "3. COPIES AND A CHANGE, AGAINST THE READER\n";
#==============================================================================
{
    my $src = <<'PHC';
TITLE     COPIES
UNITS     LENGTH M
UNITS     ELEVATION M
METHOD    HW
NODE      A 0
NODE      B 0
NODE      C 0
WATER     S 0 500
SPRINKLER H 0 -50 80
USE       BORE 120
PIPE      P1 S A 10 100
PIPE      P2 A B 10 80
PC        P2 P3 B C
CHANGEPIPE P2 12 50
PIPE      P4 C H 5 25
PHC
    my $doc = eval { HardyCross::Flow::read_text($src) };
    is('a copy reads', $doc, $@ && (ref $@ ? $@->{msg} : $@));
    my ($p2) = grep { $_->{name} eq 'P2' } @{ $doc->{edges} };
    my ($p3) = grep { $_->{name} eq 'P3' } @{ $doc->{edges} };
    is('the change is on the pipe that was changed', $p2 && $p2->{len} == 12 && $p2->{size} == 50);
    is('the copy keeps the pipe it was taken from', $p3 && $p3->{len} == 10 && $p3->{size} == 80);
    my $left = eval { solved($src) };
    my $right = $doc && eval { solved(HardyCross::Flow::write_text($doc)) };
    is('the copy solves as the original', $left && $right && $left->{ok} && $right->{ok}
       && !close_to($left->{q}, $right->{q}, 0.05) && !close_to($left->{p}, $right->{p}, 0.05),
       ($@ && (ref $@ ? $@->{msg} : $@)) || ($left && $right && close_to($left->{q}, $right->{q}, 0.05)));
}

#==============================================================================
print "4. EDITING A DRAWING\n";
#==============================================================================
{
    my $doc = HardyCross::Flow::blank();
    my $v = HardyCross::Flow::validate($doc);
    is('an empty page is not a model', !$v->{ok} && $v->{error} =~ /NO MODEL/);

    my $w = HardyCross::Flow::add_node($doc, 'WATER', 40, 40);
    my $n = HardyCross::Flow::add_node($doc, 'NODE', 300, 40);
    my $s = HardyCross::Flow::add_node($doc, 'SPRINKLER', 560, 40);
    my $p1 = HardyCross::Flow::add_edge($doc, 'PIPE', $w->{id}, $n->{id});
    my $p2 = HardyCross::Flow::add_edge($doc, 'PIPE', $n->{id}, $s->{id});
    is('two pipes, three blocks', @{ $doc->{nodes} } == 3 && @{ $doc->{edges} } == 2);
    is('a pipe cannot start and end on one block',
       !HardyCross::Flow::add_edge($doc, 'PIPE', $w->{id}, $w->{id})
       && HardyCross::Flow::error =~ /TWO DIFFERENT/);
    is('a second block cannot take the first name',
       !HardyCross::Flow::apply($doc, $n->{id}, { name => $w->{name} })
       && HardyCross::Flow::error =~ /ALREADY USED/);
    is('a tilde is not a name',
       !HardyCross::Flow::apply($doc, $n->{id}, { name => 'N1~' })
       && HardyCross::Flow::error =~ /RESERVED/);

    my $calc = HardyCross::Flow::calculate($doc);
    is('the branch calculates', $calc->{ok}, $calc->{error});
    is('the head has a pressure and the pipe a flow',
       defined $s->{pressure} && $s->{pressure} > 0 && defined $p1->{flow} && $p1->{flow} > 0,
       "P=$s->{pressure} Q=$p1->{flow}");

    # The same text, solved on its own, agrees.  calculate already solved;
    # this is the reader and the solver on the written file.
    # Discharges are elements too, under the head's name.  Compare the pipes
    # and the blocks, which are what the page drew.
    sub has {
        my ($want, $got, $tol) = @_;
        for my $k (sort keys %$want) {
            return "$k missing" unless exists $got->{$k};
            my $d = abs($want->{$k} - $got->{$k});
            return "$k differs by $d" if $d > $tol;
        }
        return '';
    }
    my $own = solved(HardyCross::Flow::write_text($doc));
    my %q = ($p1->{name} => $p1->{flow}, $p2->{name} => $p2->{flow});
    my %p = ($w->{name} => $w->{pressure}, $n->{name} => $n->{pressure}, $s->{name} => $s->{pressure});
    is('the figures are the solver\'s', $own->{ok} && !has(\%q, $own->{q}, 0.05) && !has(\%p, $own->{p}, 0.05),
       has(\%q, $own->{q}, 0.05) || has(\%p, $own->{p}, 0.05));

    my $ff = HardyCross::Flow::add_fixedflow($doc, $n->{id});
    is('a fixed flow is on the junction', $ff && $ff->{node} eq $n->{id});
    HardyCross::Flow::remove($doc, $n->{id});
    is('deleting the junction takes its pipes and its fixed flow',
       @{ $doc->{nodes} } == 2 && @{ $doc->{edges} } == 0 && @{ $doc->{flows} } == 0);

    my $bad = eval { HardyCross::Flow::read_text("NODE A 0\nNODE A 1\n") };
    my $err = $@;
    $err = $err->{msg} if ref $err;
    is('a node defined twice is refused, with the line', !$bad && $err =~ /line 2: NODE A IS ALREADY DEFINED/, $err);
}

#==============================================================================
print "5. A FILE\n";
#==============================================================================
{
    my $doc = HardyCross::Flow::read_text(slurp("$EX/01_single_branch.phc"));
    my $out = "$TMP/branch.phc";
    is('writes', HardyCross::Flow::write_file($doc, $out));
    my $doc2 = HardyCross::Flow::read_file($out);
    is('reads back the same pipes', join(' ', sort map { $_->{name} } @{ $doc2->{edges} })
       eq join(' ', sort map { $_->{name} } @{ $doc->{edges} }));
}

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
