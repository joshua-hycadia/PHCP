#!/usr/bin/perl
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# test_editor.pl -- the text editor's logic, HardyCross::Editor, without Tk.
#
#   perl tools/test_editor.pl
#
# Every decision the editor window makes is made by HardyCross::Editor, so
# this is where they are checked: what each line's status is and what the
# problems list says, which nodes are undefined, what is proposed after each
# command, what the pick lists hold, where the colours go, what a solve gives
# and what the status bar shows for the element on the cursor's line, and how
# files are opened and reports written.  The window itself is driven by
# tools/test_editor_window.pl.
#==============================================================================
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";
use File::Temp qw(tempdir);
use HardyCross;
use HardyCross::Editor;

my ($pass, $fail) = (0, 0);
sub is {
    my ($name, $ok, $why) = @_;
    printf "  %-66s %s\n", $name, $ok ? 'ok' : '*** FAIL';
    print "      $why\n" if !$ok && defined $why;
    $ok ? $pass++ : $fail++;
}
sub slurp { my $p = shift; open my $f, '<', $p or die "$p: $!\n"; local $/; <$f> }
my $EX  = "$FindBin::Bin/../examples";
my $TMP = tempdir(CLEANUP => 1);

# A small model, its lines numbered in the comments for the checks below.
my $M = join "\n",
    'Title  EDITOR TEST',                     #  1
    'Units  FLOW=LPM PRESSURE=KPA',           #  2
    'Node   A 0',                             #  3
    'Node   B 0',                             #  4
    'Node   C 4.5',                           #  5
    'Supply S1 A STATIC 700',                 #  6
    'Use    ASAM',                            #  7
    'Pipe   P1 A B 12 100 T 2E GV',           #  8
    'Pipe   P2 B C 6 50 E',                   #  9
    'Head   H1 C K=80 P=50',                  # 10
    'Flow   F1 B Q=100 MINP=150',             # 11
    '';

#==============================================================================
print "1. CHECKING THE BUFFER - statuses, problems, undefined nodes\n";
#==============================================================================
{
    my $r = HardyCross::Editor::check_buffer($M);
    is('a good model: no problems, no undefined nodes',
       !@{ $r->{problems} } && !@{ $r->{undefined} });
    is('every line ok', !grep { $_ && $_->{status} ne 'ok' } @{ $r->{lines} });

    my $bad = $M . "Pipe P3 C D 5 50\nPipe P4 D E 5 50\nHead H2 E K=80\nPipx P9\nMethod HW\nMethod DW\nNode A 1\n";
    $r = HardyCross::Editor::check_buffer($bad);
    my %u = map { $_->{node} => $_->{line} } @{ $r->{undefined} };
    is('undefined nodes D and E listed with the first line using each',
       ($u{D} // 0) == 12 && ($u{E} // 0) == 13 && keys %u == 2,
       join ' ', map { "$_:$u{$_}" } sort keys %u);
    my %p = map { $_->{line} => $_->{message} } @{ $r->{problems} };
    is('an incomplete line is a problem (line 14, any two of K Q P)', ($p{14} // '') =~ /any two/);
    is('an unknown command is a problem (line 15)', ($p{15} // '') =~ /unknown command Pipx/);
    is('a second Method is a problem naming the first (line 17)',
       ($p{17} // '') =~ /Method is already set on line 16/);
    is('a second Node line is a problem naming the first (line 18)',
       ($p{18} // '') =~ /node A already has a Node line, on line 3/);
    is('undefined nodes are not problems on their lines', !exists $p{12} && !exists $p{13});
    is('the line statuses agree: 14 incomplete, 15 and 17 error',
       $r->{lines}[14]{status} eq 'incomplete' && $r->{lines}[15]{status} eq 'error'
       && $r->{lines}[17]{status} eq 'error');

    $r = HardyCross::Editor::check_buffer($bad, 14);
    is('the line being edited is not listed while incomplete',
       !grep { $_->{line} == 14 } @{ $r->{problems} });
    $r = HardyCross::Editor::check_buffer("Units FLOW=LPS\nNode A 0\nNode B 0\nSupply S A STATIC 6 \n"
                                        . "Pipe P A B 1 47\nUse ASAM\nPipe Q A B 1 47\n");
    is('Use applies from its line on: DN47 fine as a bore, an error under ASAM',
       $r->{lines}[5]{status} eq 'ok' && $r->{lines}[7]{status} eq 'error'
       && $r->{lines}[7]{message} =~ /DATA_REQUIRED/);
}

#==============================================================================
print "2. PROPOSALS - after each kind of line\n";
#==============================================================================
{
    my $prop = sub { HardyCross::Editor::proposal($M, shift) // '(none)' };
    is('after a pipe: next free id, starts at its end, keeps length and size',
       $prop->(9) eq 'Pipe P3 C C2 6 50', $prop->(9));
    is('after P1, P2 is taken, so P3', $prop->(8) eq 'Pipe P3 B B2 12 100', $prop->(8));
    is('after a node: next free id, same elevation', $prop->(5) eq 'Node D 4.5' || $prop->(5) eq 'Node C2 4.5',
       $prop->(5));
    is('after a head: id and node stepped, options kept', $prop->(10) eq 'Head H2 C2 K=80 P=50',
       $prop->(10));
    is('after a supply', $prop->(6) eq 'Supply S2 A2 STATIC 700', $prop->(6));
    is('after a flow', $prop->(11) eq 'Flow F2 B2 Q=100 MINP=150', $prop->(11));
    is('after a setting: none', $prop->(2) eq '(none)');
    is('after a Use line: none', $prop->(7) eq '(none)');
    is('after a line with an error: none',
       (HardyCross::Editor::proposal("Pipe P1 A\n", 1) // '(none)') eq '(none)');
    my $dev = "Node A 0\nNode B 0\nPRV R1 A B DP=50\nBFP BF1 A B 0 0 100 10\nOrifice O1 A B DP=20 DN=50\n"
            . "Pump PU1 A B 0 300 100 200\nHydrant HY1 B Q=600 P=200\nHoseReel HR1 B K=7.5 P=220\n";
    is('after a PRV', (HardyCross::Editor::proposal($dev, 3) // '') eq 'PRV R2 A2 B2 DP=50');
    is('after a BFP', (HardyCross::Editor::proposal($dev, 4) // '') eq 'BFP BF2 A2 B2 0 0 100 10');
    is('after an orifice', (HardyCross::Editor::proposal($dev, 5) // '') eq 'Orifice O2 A2 B2 DP=20 DN=50');
    is('after a pump', (HardyCross::Editor::proposal($dev, 6) // '') eq 'Pump PU2 A2 B2 0 300 100 200');
    is('after a hydrant', (HardyCross::Editor::proposal($dev, 7) // '') eq 'Hydrant HY2 B2 Q=600 P=200');
    is('after a hose reel', (HardyCross::Editor::proposal($dev, 8) // '') eq 'HoseReel HR2 B2 K=7.5 P=220');
}

#==============================================================================
print "3. PICK LISTS AND THE STATUS BAR\n";
#==============================================================================
{
    my $t = $M . "Use \nPipe P5 C A 3 50 \n";
    my %c = map { $_->[0] => $_->[1] } @{ HardyCross::Editor::choices($t, 12, 4) };
    is('Use type field: the database pipe types and BORE',
       $c{ASAM} && $c{ASAH} && $c{S20} && $c{S40} && $c{CPVC} && $c{PE11} && $c{BORE});
    %c = map { $_->[0] => $_->[1] } @{ HardyCross::Editor::choices($M . "Pipe P5 C A 3 50 \n", 12, 17) };
    is('fitting field under Use ASAM, DN50: AS codes with descriptions',
       $c{E} && $c{T} && $c{GV} && $c{CV} && $c{E} =~ /elbow/i);
    my @none = @{ HardyCross::Editor::choices($M, 6, 10) };
    is('a Supply line: no pick list', !@none);

    my $st = HardyCross::Editor::status_at($M, 8, 15);
    is('status bar on line 8 col 15: Pipe template, cursor in length',
       $st->{template}{command} eq 'Pipe'
       && $st->{template}{fields}[ $st->{template}{current} ] eq 'length');
    $st = HardyCross::Editor::status_at("Pipe P1 A", 1, 9);
    is('status of a half-typed line: incomplete, needs n2',
       $st->{status} eq 'incomplete' && $st->{message} =~ /needs n2/);
}

#==============================================================================
print "4. COLOURING\n";
#==============================================================================
{
    my @s = HardyCross::Editor::colour_spans('  Pipe P1 A B 1 50  // main');
    is('command word span', grep { $_->[2] eq 'command' && $_->[0] == 2 && $_->[1] == 6 } @s);
    is('comment span to the end of the line', grep { $_->[2] eq 'comment' && $_->[0] == 20 && $_->[1] == 27 } @s);
    is('an unknown word is not coloured as a command',
       !grep { $_->[2] eq 'command' } HardyCross::Editor::colour_spans('Pipx P1'));
    is('a comment-only line', (HardyCross::Editor::colour_spans('// note'))[0][2] eq 'comment');
}

#==============================================================================
print "5. SOLVE AND RESULTS ON THE CURSOR\n";
#==============================================================================
{
    my $r = HardyCross::Editor::solve_text($M, 'test.phc');
    is('the model solves and converges', $r->{ok} && $r->{converged}, $r->{error});
    is('the report is the full report', ($r->{report} // '') =~ /PIPE SCHEDULE/
       && $r->{report} =~ /OUTLET COMPLIANCE/);
    my $net = $r->{net};
    my @l = split /\n/, $M;
    my $res = sub { HardyCross::Editor::results_at($net, $l[ $_[0] - 1 ]) // '(none)' };
    my ($p1) = grep { ($_->{id} // '') eq 'P1' } @{ $net->{elems} };
    my $q = sprintf '%.1f', abs $p1->{q};
    is("pipe P1: flow $q L/min, velocity, end pressures",
       $res->(8) =~ /^P1  Q \Q$q\E L\/min  V [\d.]+ m\/s  A [\d.]+ kPa -> B [\d.]+ kPa$/, $res->(8));
    # Velocity checked by hand: Q / A with the ASAM DN100 bore of 105.1 mm.
    my ($v) = $res->(8) =~ /V ([\d.]+)/;
    my $vh = abs($p1->{q}) / 60000 / (3.14159265358979 * 0.1051 ** 2 / 4);
    is(sprintf('   velocity %.2f m/s agrees with Q/A by hand', $vh), abs($v - $vh) < 0.006);
    is('head H1: discharge and pressure, with the required',
       $res->(10) =~ /^H1  q [\d.]+ L\/min at [\d.]+ kPa \(required 50\.0\)$/, $res->(10));
    is('node C: pressure and elevation', $res->(5) =~ /^C  pressure [\d.]+ kPa, elevation 4\.500 m$/,
       $res->(5));
    is('supply S1', $res->(6) =~ /^S1  supplies [\d.]+ L\/min at 700\.0 kPa$/, $res->(6));
    is('fixed flow F1: fixed flow, pressure, required', $res->(11) =~ /^F1  fixed 100\.0 L\/min at [\d.]+ kPa \(required 150\.0\)$/,
       $res->(11));
    is('a setting line: no results', $res->(2) eq '(none)');
    is('a line added since the solve: no results',
       !defined HardyCross::Editor::results_at($net, 'Pipe P99 A B 1 50'));

    $r = HardyCross::Editor::solve_text($M . "Pipe P9 A Z 3 50\n", 'test.phc');
    is('an error stops the solve and gives its line (12)', !$r->{ok} && ($r->{line} // 0) == 12,
       $r->{error});
    my $lps = "Units FLOW=LPS PRESSURE=BAR\nNode A 0\nNode B 0\nSupply S A STATIC 7\n"
            . "Pipe P1 A B 10 100\nHead H B K=1.2 P=0.5\n";
    $r = HardyCross::Editor::solve_text($lps);
    is('results are in the model\'s own units (L/s and bar)',
       (HardyCross::Editor::results_at($r->{net}, 'Pipe P1 A B 10 100') // '') =~ /L\/s .* bar -> B [\d.]+ bar$/);
}

#==============================================================================
print "6. FILES - open .phc, convert .hcx, write the report\n";
#==============================================================================
{
    my $r = HardyCross::Editor::load_file("$EX/01_single_branch.phc");
    is('a .phc opens as it is, with its path', !$r->{converted} && $r->{path} =~ /01_single_branch\.phc$/
       && $r->{text} eq slurp("$EX/01_single_branch.phc"));
    $r = HardyCross::Editor::load_file("$EX/07_pipe_database_demo.hcx");
    is('a .hcx is converted into a new buffer with no path', $r->{converted} && !defined $r->{path});
    is('   the note says so', $r->{note} =~ /converted from 07_pipe_database_demo\.hcx .* not yet saved/);
    is('   SAVE AS is offered the .phc name', $r->{suggest} =~ /07_pipe_database_demo\.phc$/);
    is('   the converted text is what --convert writes',
       $r->{text} eq slurp("$EX/07_pipe_database_demo.phc"));

    my $s = HardyCross::Editor::solve_text($M, 'test.phc');
    HardyCross::Editor::write_report_file($s->{net}, $s->{converged}, 'test.phc', "$TMP/r.txt");
    HardyCross::Editor::write_report_file($s->{net}, $s->{converged}, 'test.phc', "$TMP/r.pdf");
    is('WRITE REPORT .txt is the ASCII report', -s "$TMP/r.txt" && slurp("$TMP/r.txt") =~ /PIPE SCHEDULE/);
    is('WRITE REPORT .pdf is a PDF', -s "$TMP/r.pdf" && slurp("$TMP/r.pdf") =~ /^%PDF-/);
}

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
