#!/usr/bin/perl
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# test_fast.pl -- the fast-entry decisions, HardyCross::FastEntry, without Tk.
#
#   perl tools/test_fast.pl
#
# The window (phcp_fast.pl) draws the row and sends keys.  What a row becomes,
# which values are offered next, and what is refused are decided here and
# checked here.  The lines are ordinary .phc: a model built only through this
# module solves to the same pipe flow as examples/01_single_branch.phc.
#==============================================================================
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";
use HardyCross::FastEntry;
use HardyCross::Editor;
use HardyCross::Phc;

my ($pass, $fail) = (0, 0);
sub is {
    my ($name, $ok, $why) = @_;
    printf "  %-66s %s\n", $name, $ok ? 'ok' : '*** FAIL';
    print "      $why\n" if !$ok && defined $why;
    $ok ? $pass++ : $fail++;
}
sub ids {
    my $r = HardyCross::FastEntry::expand_token(shift);
    return $r->{ok} ? join(' ', @{ $r->{ids} }) : "ERR $r->{message}";
}
sub tokens {
    my $line = shift;
    my @t = split ' ', $line;
    return join ' ', @t;
}

my $S = HardyCross::Editor::new_settings();
$S->{units}{LENGTH} = 'M';

#==============================================================================
print "1. A RUN OF NAMES\n";
#==============================================================================
is('P1-P4 is four names', ids('P1-P4') eq 'P1 P2 P3 P4', ids('P1-P4'));
is('P1..P4 is the same run', ids('P1..P4') eq 'P1 P2 P3 P4');
is('spaces around the mark are ignored', ids('P1 - P4') eq 'P1 P2 P3 P4');
is('P1x4 and P1*4 and P1X4 are a count', ids('P1x4') eq 'P1 P2 P3 P4'
    && ids('P1*4') eq 'P1 P2 P3 P4' && ids('P1X4') eq 'P1 P2 P3 P4');
is('a count keeps a leading zero', ids('P01x3') eq 'P01 P02 P03', ids('P01x3'));
is('4101-4103 steps the digits', ids('4101-4103') eq '4101 4102 4103');
is('one name is itself', ids('N12') eq 'N12');
is('a fitting code is not a run', ids('2E') eq '2E');
is('an empty token is no names', ids('  ') eq '');
is('a run goes upward', ids('P5-P1') =~ /^ERR /, ids('P5-P1'));
is('a run keeps one prefix', ids('P1-N4') =~ /^ERR /, ids('P1-N4'));
is('a run of none is refused', ids('P1x0') =~ /^ERR /);
is('a run stops at 500', ids('P1x501') =~ /^ERR / && ids('P1-P501') =~ /^ERR /);

#==============================================================================
print "2. THE MODES COVER THE NETWORK COMMANDS\n";
#==============================================================================
{
    my @cmds = grep {
        my $c = HardyCross::Phc::command_spec($_);
        $c && $c->{kind} ne 'setting';
    } @HardyCross::Phc::COMMANDS;
    my %have = map { $_->{key} => 1 } HardyCross::FastEntry::modes();
    my @miss = grep { !$have{$_} } @cmds;
    is('every network command has a mode', !@miss, "@miss");
    is('LINE is the escape hatch, and it is not a .phc command', $have{LINE}
        && !HardyCross::Phc::command_spec('LINE'));
    my %hot;
    my $clash = 0;
    for my $m (HardyCross::FastEntry::modes()) {
        next unless $m->{hotkey};
        $clash++ if $hot{ $m->{hotkey} }++;
        is("alt+$m->{hotkey} is $m->{key}", HardyCross::FastEntry::hotkey($m->{hotkey}) eq $m->{key});
    }
    is('no two commands share a letter', $clash == 0, $clash);
    # The fields of each command match the language: fixed, then optional, then
    # one remainder.  A drift here would write a line the reader moves.
    for my $m (HardyCross::FastEntry::modes()) {
        next if $m->{raw};
        my $c = HardyCross::Phc::command_spec($m->{key});
        my $n = @{ $c->{fixed} } + @{ $c->{opt} || [] } + ($c->{rest} ? 1 : 0);
        is("$m->{key} has its $n fields", @{ $m->{fields} } == $n,
            join(' ', map { $_->{key} } @{ $m->{fields} }));
    }
}

#==============================================================================
print "3. ONE ROW, AND THE NEXT ONE\n";
#==============================================================================
{
    # Fittings need a pipe type, so the type is already in force.  Under
    # USE BORE they are refused, which is the reader's own rule.
    my $net = "USE       ASAM 120\n";
    my $r = HardyCross::FastEntry::plan(
        settings => $S, network => $net, mode => 'PIPE',
        values => { NAME => 'P1', START => 'N1', END => 'N2', LENGTH => '3.2', SIZE => '100', FITTINGS => 'T' });
    is('a pipe row is added', $r->{ok}, $r->{message});
    is('the line is padded like the files', $r->{lines}[0] eq 'PIPE      P1 N1 N2 3.2 100 T', $r->{lines}[0]);
    $net = $r->{network};

    my $g = HardyCross::FastEntry::next_ghosts($net, 'PIPE',
        HardyCross::FastEntry::sticky_from_network($net, 'PIPE'));
    is('the next pipe starts where this one ended', $g->{NAME} eq 'P2' && $g->{START} eq 'N2' && $g->{END} eq 'N3',
        join(' ', @$g{qw(NAME START END)}));
    is('length and size are kept', $g->{LENGTH} eq '3.2' && $g->{SIZE} eq '100');
    is('fittings are kept, though a proposal drops them', $g->{FITTINGS} eq 'T', $g->{FITTINGS});

    # The proposal on its own really does drop the fittings: the sticky is
    # what puts them back, and clearing them has to stay cleared.
    my $bare = HardyCross::FastEntry::next_ghosts($net, 'PIPE', {});
    is('without a sticky the proposal has no fittings', ($bare->{FITTINGS} // '') eq '');
    my $cleared = HardyCross::FastEntry::next_ghosts($net, 'PIPE', { FITTINGS => '', LENGTH => '3.2', SIZE => '100' });
    is('a cleared sticky is offered empty', ($cleared->{FITTINGS} // 'X') eq '');

    my $r2 = HardyCross::FastEntry::plan(settings => $S, network => $net, mode => 'PIPE', values => $g);
    is('accepting the offer adds the next pipe', $r2->{ok} && tokens($r2->{lines}[0]) eq 'PIPE P2 N2 N3 3.2 100 T',
        $r2->{message} || tokens($r2->{lines}[0]));
    $net = $r2->{network};

    is('ditto is the previous pipe\'s size',
        HardyCross::FastEntry::ditto($net, 'PIPE', 'SIZE') eq '100');
    is('ditto skips the line being edited',
        HardyCross::FastEntry::ditto($net, 'PIPE', 'NAME', 3) eq 'P1');
}

#==============================================================================
print "4. A RUN BECOMES ORDINARY LINES\n";
#==============================================================================
{
    my $r = HardyCross::FastEntry::plan(
        settings => $S, network => "USE       ASAM\n", mode => 'PIPE',
        values => { NAME => 'P1x3', START => 'N1', END => 'N2', LENGTH => '3', SIZE => '25', FITTINGS => 'T' });
    is('three pipes from one name', $r->{ok} && @{ $r->{lines} } == 3, $r->{message});
    my @got = map { tokens($_) } @{ $r->{lines} };
    is('each pipe starts where the last ended',
        join(' | ', @got) eq 'PIPE P1 N1 N2 3 25 T | PIPE P2 N2 N3 3 25 T | PIPE P3 N3 N4 3 25 T',
        join(' | ', @got));

    my $n = HardyCross::FastEntry::plan(
        settings => $S, network => '', mode => 'NODE',
        values => { NAME => 'N1-N4', ELEVATION => '4.5' });
    is('four nodes at one elevation', $n->{ok} && @{ $n->{lines} } == 4
        && tokens($n->{lines}[0]) eq 'NODE N1 4.5' && tokens($n->{lines}[3]) eq 'NODE N4 4.5',
        $n->{message});

    my $h = HardyCross::FastEntry::plan(
        settings => $S, network => '', mode => 'SPRINKLER',
        values => { NAME => 'H1-H3', ELEVATION => '3.2', MINFLOW => '-50', K => '8' });
    is('three heads, the same elevation, minimum and K', $h->{ok}
        && tokens($h->{lines}[2]) eq 'SPRINKLER H3 3.2 -50 8', $h->{message} || tokens($h->{lines}[2]));

    my $f = HardyCross::FastEntry::plan(
        settings => $S, network => '', mode => 'FIXEDFLOW',
        values => { NAME => 'F1x3', NODE => 'N10', FLOW => '100', MINPRESSURE => '150' });
    is('a fixed-flow run steps the node', $f->{ok}
        && tokens($f->{lines}[0]) eq 'FIXEDFLOW F1 N10 100 150'
        && tokens($f->{lines}[2]) eq 'FIXEDFLOW F3 N12 100 150',
        $f->{message} || join(' / ', map { tokens($_) } @{ $f->{lines} || [] }));

    my $z = HardyCross::FastEntry::plan(
        settings => $S, network => '', mode => 'FIXEDFLOW',
        values => { NAME => 'F1-F2', NODE => 'A1-A2', FLOW => '100' });
    is('a node run of the same length is zipped', $z->{ok}
        && tokens($z->{lines}[0]) eq 'FIXEDFLOW F1 A1 100'
        && tokens($z->{lines}[1]) eq 'FIXEDFLOW F2 A2 100', $z->{message});

    my $bad = HardyCross::FastEntry::plan(
        settings => $S, network => '', mode => 'FIXEDFLOW',
        values => { NAME => 'F1-F3', NODE => 'A1-A2', FLOW => '100' });
    is('a node run of a different length is refused', !$bad->{ok} && $bad->{field} eq 'NODE', $bad->{message});

    my $area = HardyCross::FastEntry::plan(
        settings => $S, network => "SPRINKLER H1 3 -50 8\nSPRINKLER H2 3 -50 8\nSPRINKLER H3 3 -50 8\n",
        mode => 'AREA', values => { NAME => 'A1', OUTLETS => 'H1-H3' });
    is('an outlet range stays on one AREA line', $area->{ok} && tokens($area->{lines}[0]) eq 'AREA A1 H1 H2 H3',
        $area->{message} || tokens($area->{lines}[0] // ''));

    my $nc = HardyCross::FastEntry::plan(
        settings => $S, network => "NODE      N1 0\n",
        mode => 'NC', values => { SOURCE => 'N1', NAMES => 'N2-N4' });
    is('a copy range stays on one NC line', $nc->{ok} && tokens($nc->{lines}[0]) eq 'NC N1 N2 N3 N4',
        $nc->{message} || tokens($nc->{lines}[0] // ''));

    my $pump = HardyCross::FastEntry::plan(
        settings => $S, network => "NODE N1 0\nNODE N2 0\n",
        mode => 'PUMP', values => { NAME => 'PM1x2', IN => 'N1', OUT => 'N2', CHURN => '800', POINTS => '100 700' });
    is('a pump name is not a run', !$pump->{ok}, $pump->{message});
}

#==============================================================================
print "5. WHAT IS REFUSED, AND WHAT IS ONLY WARNED\n";
#==============================================================================
{
    my $r = HardyCross::FastEntry::plan(
        settings => $S, network => '', mode => 'PIPE',
        values => { NAME => 'P1', START => 'N1', LENGTH => '3', SIZE => '25' });
    is('a missing end is not added', !$r->{ok} && $r->{field} eq 'END', $r->{message});

    my $hole = HardyCross::FastEntry::plan(
        settings => $S, network => '', mode => 'PIPE',
        values => { NAME => 'P1', START => 'N1', END => '', LENGTH => '3', SIZE => '25' });
    is('an empty field cannot be skipped', !$hole->{ok} && $hole->{field} eq 'END');

    my $fit = HardyCross::FastEntry::plan(
        settings => $S, network => "USE       ASAM\nNODE N1 0\nNODE N2 0\n",
        mode => 'PIPE',
        values => { NAME => 'P1', START => 'N1', END => 'N2', LENGTH => '3', SIZE => '100', FITTINGS => 'NOPE' });
    is('a fitting the database lacks is refused', !$fit->{ok} && ($fit->{message} =~ /FITTING/ || $fit->{field} eq 'FITTINGS'),
        $fit->{message});

    my $dup = HardyCross::FastEntry::plan(
        settings => $S, network => "PIPE      P1 N1 N2 3 100\n",
        mode => 'PIPE',
        values => { NAME => 'P1', START => 'N1', END => 'N3', LENGTH => '3', SIZE => '100' });
    is('a name already used is refused', !$dup->{ok} && $dup->{message} =~ /ALREADY/, $dup->{message});

    my $edit = HardyCross::FastEntry::plan(
        settings => $S, network => "PIPE      P1 N1 N2 3 100\n",
        mode => 'PIPE', edit => 1,
        values => { NAME => 'P9', START => 'N1', END => 'N2', LENGTH => '6', SIZE => '80' });
    is('editing replaces that line', $edit->{ok} && tokens($edit->{network}) eq 'PIPE P9 N1 N2 6 80',
        $edit->{message} || tokens($edit->{network} // ''));

    my $run = HardyCross::FastEntry::plan(
        settings => $S, network => "PIPE      P1 N1 N2 3 100\n",
        mode => 'PIPE', edit => 1,
        values => { NAME => 'P1x2', START => 'N1', END => 'N2', LENGTH => '3', SIZE => '100' });
    is('a run is not written over one line', !$run->{ok});

    my $gone = HardyCross::FastEntry::plan(
        settings => $S, network => '', mode => 'NODE', edit => 3,
        values => { NAME => 'N1', ELEVATION => '0' });
    is('editing a line that is not there is refused', !$gone->{ok});

    my $set = HardyCross::FastEntry::plan(
        settings => $S, network => '', mode => 'LINE', values => { TEXT => 'UNITS LENGTH M' });
    is('a setting typed as a line is refused', !$set->{ok} && $set->{message} =~ /BAR/, $set->{message});

    my $note = HardyCross::FastEntry::plan(
        settings => $S, network => '', mode => 'LINE', values => { TEXT => '// RISER' });
    is('a comment is added as typed', $note->{ok} && $note->{lines}[0] eq '// RISER');

    my $warn = HardyCross::FastEntry::plan(
        settings => $S, network => '', mode => 'PIPE',
        values => { NAME => 'P1', START => 'N1', END => 'N2', LENGTH => '3', SIZE => '100' });
    is('a pipe to a node not defined yet is added, and says so',
        $warn->{ok} && join(' ', @{ $warn->{warnings} }) =~ /N1/ && join(' ', @{ $warn->{warnings} }) =~ /N2/,
        join('; ', @{ $warn->{warnings} || [] }) || $warn->{message});

    my $del = HardyCross::FastEntry::delete_line("NODE      N1 0\nNODE      N2 0\n", 1);
    is('a line can be removed', tokens($del) eq 'NODE N2 0', tokens($del // ''));
}

#==============================================================================
print "6. THE PIPE TYPE IN FORCE\n";
#==============================================================================
{
    my $have = HardyCross::FastEntry::use_in_force($S, '');
    is('before any USE the type is BORE', $have->{type} eq 'BORE' && !defined $have->{c});
    is('BORE with C 120 needs no line', !defined HardyCross::FastEntry::use_line($S, '', { type => 'BORE', c => '120' }));

    my $r = HardyCross::FastEntry::plan(
        settings => $S, network => "NODE N1 0\nNODE N2 0\n", mode => 'PIPE',
        use => { type => 'ASAM', c => '120' },
        values => { NAME => 'P1', START => 'N1', END => 'N2', LENGTH => '3', SIZE => '100', FITTINGS => 'T' });
    is('a changed type is written in front of the row', $r->{ok} && @{ $r->{lines} } == 2
        && tokens($r->{lines}[0]) eq 'USE ASAM 120' && tokens($r->{lines}[1]) =~ /^PIPE /,
        $r->{message} || join(' / ', map { tokens($_) } @{ $r->{lines} || [] }));

    my $again = HardyCross::FastEntry::plan(
        settings => $S, network => $r->{network}, mode => 'PIPE',
        use => { type => 'ASAM', c => '120' },
        values => { NAME => 'P2', START => 'N2', END => 'N3', LENGTH => '3', SIZE => '100' });
    is('the same type is not written twice', $again->{ok} && @{ $again->{lines} } == 1, $again->{message});
    is('the type in force is now ASAM 120',
        do { my $u = HardyCross::FastEntry::use_in_force($S, $r->{network}); $u->{type} eq 'ASAM' && $u->{c} eq '120' });
}

#==============================================================================
print "7. PICK LISTS\n";
#==============================================================================
{
    my $types = HardyCross::FastEntry::choices_for(
        settings => $S, network => '', mode => 'USE', field => 'PIPETYPE', values => { PIPETYPE => '' });
    my %code = map { $_->[0] => 1 } @$types;
    is('a pipe type offers the database, and BORE', $code{ASAM} && $code{S20} && $code{BORE}, join(' ', sort keys %code));
    my $one = HardyCross::FastEntry::complete('S2', $types);
    is('S2 completes to S20', ($one->{unique} // '') eq 'S20', $one->{unique});
    my $many = HardyCross::FastEntry::complete('S', $types);
    is('S matches more than one type', !$many->{unique} && @{ $many->{matches} } >= 2);

    my $fits = HardyCross::FastEntry::choices_for(
        settings => $S, network => "USE       ASAM\n", mode => 'PIPE', field => 'FITTINGS',
        values => { NAME => 'P1', START => 'N1', END => 'N2', LENGTH => '3', SIZE => '100', FITTINGS => '' });
    my %fit = map { $_->[0] => 1 } @$fits;
    is('fittings are offered for the pipe type', $fit{T} || $fit{E}, join(' ', sort keys %fit));
    my $tee = HardyCross::FastEntry::complete('T', $fits);
    is('T completes to one fitting', ($tee->{unique} // '') eq 'T');
}

#==============================================================================
print "8. A MODEL BUILT FROM ROWS SOLVES AS THE EXAMPLE DOES\n";
#==============================================================================
{
    my $s = HardyCross::Editor::new_settings();
    $s->{units}{LENGTH} = 'M';
    $s->{options}{TOL_FLOW} = '0.001';
    $s->{options}{TOL_LOOP} = '0.0005';
    my $net = '';
    for my $row (
        [ 'WATER',     { NAME => 'N1', ELEVATION => '0', STATIC => '900' } ],
        [ 'SPRINKLER', { NAME => 'N2', ELEVATION => '0', MINFLOW => '-50', K => '80' } ],
        [ 'PIPE',      { NAME => 'P1', START => 'N1', END => 'N2', LENGTH => '100', SIZE => '100' } ],
    ) {
        my $r = HardyCross::FastEntry::plan(
            settings => $s, network => $net, mode => $row->[0], values => $row->[1],
            use => { type => 'BORE', c => '120' });
        $net = $r->{network} if $r->{ok};
        is("$row->[0] row added for the worked example", $r->{ok}, $r->{message});
    }
    my $built = HardyCross::Editor::doc_solve({ settings => $s, network => $net });
    my $file = HardyCross::Editor::split_file(slurp("$FindBin::Bin/../examples/01_single_branch.phc"));
    my $orig = HardyCross::Editor::doc_solve($file);
    is('the built model converges', $built->{ok} && $built->{converged}, $built->{error});
    my ($bq) = $built->{ok} ? (map { $_->{q} } grep { $_->{id} && $_->{id} eq 'P1' } @{ $built->{net}{elems} }) : ();
    my ($oq) = $orig->{ok}  ? (map { $_->{q} } grep { $_->{id} && $_->{id} eq 'P1' } @{ $orig->{net}{elems} }) : ();
    is('its pipe flow matches example 01', defined $bq && defined $oq && abs($bq - $oq) < 1e-6, "built $bq example $oq");

    # A line read back is the row that wrote it.
    my $back = HardyCross::FastEntry::fields_of_line('PIPE      P1 N1 N2 100 100');
    is('a pipe line reads back into its fields', $back->{ok} && $back->{command} eq 'PIPE'
        && $back->{values}{END} eq 'N2' && $back->{values}{SIZE} eq '100');
    my $round = HardyCross::FastEntry::line_of('PIPE', $back->{values});
    is('and writes back to the same tokens', tokens($round) eq 'PIPE P1 N1 N2 100 100');
}

sub slurp { my $p = shift; open my $f, '<', $p or die "$p: $!\n"; local $/; <$f> }

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
