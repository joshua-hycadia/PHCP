#!/usr/bin/perl
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# test_isometric.pl -- the isometric drawing (HardyCross::Isometric), headless.
#
#   perl tools/test_isometric.pl
#
# The drawing writes .phc.  What it must prove:
#
#   1. A grid point drawn and picked again is the same point.
#   2. A length converted to the model's unit reads back as the same metres.
#   3. Placing a supply, a sprinkler and a pipe writes a model that solves,
#      and a pipe that is not on one axis is refused.
#   4. Moving a point sets the pipe's length from the grid.  A length already
#      typed is left alone until then.  A comment, an //AS note and an AREA
#      line survive, and renaming a point renames it in the AREA line.
#   5. Every example but the 1000-node grid, written back from the drawing,
#      solves to the same pipe flows and node pressures.  A copy keeps the
#      source's original when the source is changed.  Writing twice is the
#      same text, and //ISO positions are kept.
#==============================================================================
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";
use HardyCross;
use HardyCross::Phc;
use HardyCross::Editor;
use HardyCross::Isometric;

my ($pass, $fail) = (0, 0);
sub is {
    my ($name, $ok, $why) = @_;
    printf "  %-68s %s\n", $name, $ok ? 'ok' : '*** FAIL';
    print "      $why\n" if !$ok && defined $why;
    $ok ? $pass++ : $fail++;
}
sub slurp { my $p = shift; open my $f, '<', $p or die "$p: $!\n"; local $/; <$f> }
my $EX = "$FindBin::Bin/../examples";

sub units {
    return { %HardyCross::Phc::UNIT_DEFAULT, LENGTH => 'M', ELEVATION => 'M' };
}
sub draw_of {
    my ($text, $u) = @_;
    return HardyCross::Isometric::read_network($text, $u || units());
}

# flows and gauge pressures, as test_phc.pl reads them.
sub results {
    my $text = shift;
    my $net = eval { HardyCross::Phc::read_string($text) };
    my $err = $@;
    return (undef, ref $err && $err->{msg} ? $err->{msg} : $err) unless $net;
    eval { HardyCross::solve_model($net) };
    $err = $@;
    return (undef, ref $err && $err->{msg} ? $err->{msg} : $err) if $err;
    my (%q, %p);
    my $el = $net->{elems};
    $q{ $_->{id} } = $_->{q} for grep { ($_->{kind} || '') eq 'PIPE' } @$el[ 1 .. $#$el ];
    $p{ $_->{id} } = $_->{h} - $HardyCross::GAMMA_W * $_->{z}
        for grep { $_->{id} ne 'REF' } @{ $net->{nodes} }[ 1 .. $#{ $net->{nodes} } ];
    return (\%q, \%p);
}
sub worst {
    my ($a, $b) = @_;
    my $w = 0;
    for (keys %$a) {
        return (1e30, $_) unless exists $b->{$_};
        my $d = abs($a->{$_} - $b->{$_});
        $w = $d if $d > $w;
    }
    return ($w, '');
}

#==============================================================================
print "1. THE GRID\n";
#==============================================================================
{
    my $v = { ox => 12.5, oy => -7, scale => 17 };
    my $bad = 0;
    for my $ix (-4 .. 4) {
        for my $iy (-4 .. 4) {
            for my $iz (-2, 0, 2.5, 4.5) {
                my ($x, $y) = HardyCross::Isometric::project($ix, $iy, $iz, $v);
                my ($a, $b, $c) = HardyCross::Isometric::cell_at($x, $y, $v, $iz);
                $bad++ if $a != $ix || $b != $iy || abs($c - $iz) > 1e-9;
            }
        }
    }
    is('a point drawn and picked again is the same point, including a fractional height', !$bad, "$bad missed");
    my $d = draw_of("NODE A 0\nNODE B 0\nPIPE P1 A B 4 25\n");
    # Give them a known picture so the hit is not the auto layout's.
    HardyCross::Isometric::move_node($d, 'A', 0, 0, 0);
    HardyCross::Isometric::move_node($d, 'B', 4, 0, 0);
    my ($x, $y) = HardyCross::Isometric::project(4, 0, 0, $v);
    my $hit = HardyCross::Isometric::hit($d, $x, $y, $v);
    is('a click on a point hits that point', $hit && $hit->{kind} eq 'node' && $hit->{name} eq 'B',
       $hit ? "$hit->{kind} $hit->{name}" : 'nothing');
    my ($fx, $fy) = HardyCross::Isometric::project(40, 40, 0, $v);
    is('a click on empty grid hits nothing', !HardyCross::Isometric::hit($d, $fx, $fy, $v));
}

#==============================================================================
print "2. LENGTHS AND THE MODEL'S UNITS\n";
#==============================================================================
{
    my $u = { %HardyCross::Phc::UNIT_DEFAULT };
    my $d = draw_of('', $u);          # length defaults to millimetres
    my $tok = HardyCross::Isometric::metres_to_token($d, 4, 'LENGTH');
    my $back = HardyCross::Phc::length_metres($tok, 'MM');
    is('4 m is 4000 mm, and reads back as 4 m', $tok eq '4000' && abs($back - 4) < 1e-6, "$tok -> $back");
    $d->{units}{LENGTH} = 'IN';
    $tok = HardyCross::Isometric::metres_to_token($d, 0.0254, 'LENGTH');
    $back = HardyCross::Phc::length_metres($tok, 'IN');
    is('one inch written and read back', abs($back - 0.0254) < 1e-6, $tok);
}

#==============================================================================
print "3. DRAWING WRITES A MODEL\n";
#==============================================================================
{
    my $u = units();
    my $d = draw_of('', $u);
    my ($e, $w) = HardyCross::Isometric::add_node($d, 'WATER', 0, 0, 0, '0');
    my ($e2, $s) = HardyCross::Isometric::add_node($d, 'SPRINKLER', 4, 0, 0, '0');
    my ($e3, $p) = HardyCross::Isometric::add_pipe($d, $w, $s);
    is('a supply, a sprinkler and a pipe', !$e && !$e2 && !$e3 && $w eq 'W1' && $s eq 'S1' && $p eq 'P1',
       join ' ', map { defined $_ ? $_ : '' } $e, $e2, $e3, $w, $s, $p);
    my ($e4, $n) = HardyCross::Isometric::add_node($d, 'NODE', 1, 1, 0, '0');
    my ($e5) = HardyCross::Isometric::add_pipe($d, $w, $n);
    is('a pipe not on one axis is refused', $e5 && $e5 =~ /ONE GRID AXIS/, $e5);
    my ($e6) = HardyCross::Isometric::add_node($d, 'NODE', 0, 0, 0, '0');
    is('a second point on the same cell is refused', $e6 && $e6 =~ /ALREADY USED/, $e6);
    HardyCross::Isometric::delete_item($d, 'node', $n);   # the off-axis point is not part of the branch
    my $text = HardyCross::Isometric::write_network($d);
    is('the text is the commands, with the positions as //ISO comments',
       $text =~ m{^//ISO GRID 1$}m && $text =~ m{^//ISO W1 0 0 0$}m
       && $text =~ /^WATER\s+W1 0 500$/m && $text =~ /^SPRINKLER\s+S1 0 -50 80$/m
       && $text =~ /^PIPE\s+P1 W1 S1 4 25$/m && $text =~ /^USE\s+BORE 120$/m, $text);
    my $settings = HardyCross::Editor::new_settings();
    $settings->{units}{LENGTH} = 'M';
    my ($full) = HardyCross::Editor::join_file($settings, $text);
    my ($q, $err) = results($full);
    is('and it solves', $q && $q->{P1} && $q->{P1} > 0, $err || 'no flow');
}

#==============================================================================
print "4. A MOVE, AND WHAT IS KEPT\n";
#==============================================================================
{
    my $raw = join "\n",
        '// KEEP THIS',
        'NODE A 0',
        'NODE B 0',
        'SPRINKLER S 0 -50 80',
        'USE ASAM',
        'PIPE P1 A B 10 50 T  //AS - 40',
        'PIPE P2 B S 3 32',
        'AREA NEAR S',
        '';
    my $d = draw_of($raw);
    my $before = $d->{pipes}[0]{len};
    HardyCross::Isometric::set_grid($d, 2);     # the step changes; typed lengths do not
    is('changing the grid leaves a length that was typed', $d->{pipes}[0]{len} eq $before, $d->{pipes}[0]{len});
    my $err = HardyCross::Isometric::move_node($d, 'B', 6, 0, 0);
    is('moving a point sets its pipes from the grid', !$err && $d->{pipes}[0]{len} eq '12' && $d->{pipes}[1]{len} ne '3',
       "P1 $d->{pipes}[0]{len} P2 $d->{pipes}[1]{len}");
    $err = HardyCross::Isometric::set_node($d, 'S', 'NAME', 'S9');
    my $text = HardyCross::Isometric::write_network($d);
    is('a comment, an //AS note and an AREA line survive, and the new name is in the AREA',
       !$err && $text =~ m{^// KEEP THIS$}m && $text =~ m{//AS - 40} && $text =~ /^AREA\s+NEAR S9$/m
       && $text =~ /^PIPE\s+P2 B S9 /m, $text);
    # Positions come back.
    my $d2 = draw_of($text);
    is('//ISO positions are kept', $d2->{nodes}{B}{pinned} && $d2->{nodes}{B}{ix} == 6 && !$d2->{nodes}{B}{iy},
       "ix $d2->{nodes}{B}{ix}");
    my $again = HardyCross::Isometric::write_network($d2);
    is('writing the drawing twice gives the same text', $again eq $text, $again);
}

#==============================================================================
print "5. THE EXAMPLES, AND A COPY\n";
#==============================================================================
{
    my $copy = join "\n",
        'NODE A 0', 'NODE B 0', 'NODE C 0',
        'USE BORE 120',
        'PIPE P1 A B 10 50',
        'PC P1 P2 B C',
        'CHANGEPIPE P1 12 40 E',
        '';
    my $d = draw_of($copy);
    my ($p1) = grep { $_->{name} eq 'P1' } @{ $d->{pipes} };
    my ($p2) = grep { $_->{name} eq 'P2' } @{ $d->{pipes} };
    is('a change applies to the named pipe; the copy keeps the original',
       $p1 && $p2 && $p1->{len} eq '12' && $p1->{size} eq '40' && "@{ $p1->{fits} }" eq 'E'
       && $p2->{len} eq '10' && $p2->{size} eq '50' && !@{ $p2->{fits} },
       $p1 ? "P1 $p1->{len} $p1->{size} @{$p1->{fits}} / P2 $p2->{len} $p2->{size}" : 'missing');
    my $back = HardyCross::Isometric::write_network($d);
    is('the copy is written as its own pipe, and the change is not applied twice',
       $back =~ /^PIPE\s+P2 B C 10 50$/m && $back =~ /^PIPE\s+P1 A B 12 40 E$/m && $back !~ /^PC\b/m
       && $back !~ /^CHANGEPIPE\b/m, $back);

    opendir my $dir, $EX or die $!;
    my @ex = sort grep { /\.phc\z/ && !/04_grid/ } readdir $dir;
    closedir $dir;
    for my $file (@ex) {
        my $doc = HardyCross::Editor::split_file(slurp("$EX/$file"));
        my $drawing = HardyCross::Isometric::read_network($doc->{network}, $doc->{settings}{units});
        my $missing = grep { !defined $drawing->{nodes}{$_}{ix} } @{ $drawing->{node_order} };
        my (%cell, $overlap);
        for my $name (@{ $drawing->{node_order} }) {
            my $n = $drawing->{nodes}{$name};
            my $k = sprintf '%d,%d,%.4f', $n->{ix}, $n->{iy}, $n->{iz};
            $overlap = $name if $cell{$k}++;
        }
        my $once = HardyCross::Isometric::write_network($drawing);
        my $twice = HardyCross::Isometric::write_network(
            HardyCross::Isometric::read_network($once, $doc->{settings}{units}));
        my ($orig) = HardyCross::Editor::join_file($doc->{settings}, $doc->{network});
        my ($rewritten) = HardyCross::Editor::join_file($doc->{settings}, $once);
        my ($a, $pa) = results($orig);
        my ($b, $pb) = results($rewritten);
        my $ok_solve = $a && $b && ref $pa eq 'HASH' && ref $pb eq 'HASH';
        my ($flow) = $ok_solve ? worst($a, $b) : (1e30);
        my ($press) = $ok_solve ? worst($pa, $pb) : (1e30);
        my $err = $ok_solve ? '' : (ref $pa ? '' : ($pa || $pb || 'did not solve'));
        is("$file: every point placed, none on top of another, same flows and pressures",
           !$missing && !$overlap && $twice eq $once && $flow < 0.05 && $press < 0.05,
           $err || "unplaced $missing overlap " . ($overlap || '') . " flow $flow pressure $press");
    }
}

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
