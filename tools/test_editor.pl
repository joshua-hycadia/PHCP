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
# this is where they are checked: each line's status, the ERRORS, WARNINGS
# and NODES lists, what is proposed after each command, the pick lists, the
# colours, the status bar, a solve and the figures for the cursor's line, the
# PIPES, NODES and OUTLETS tables and their sorting, the document (settings
# in the PROJECT tab, the network in the editor), VALIDATE's what, why and
# where, and how files are opened and reports written.  The window itself is driven by
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
# The 50 and 32 mm pipes are deliberately too small, so the solve has
# velocity warnings to list.
my $M = join "\n",
    'TITLE     EDITOR TEST',                  #  1
    'UNITS     LENGTH M',                     #  2
    'NODE      A 0',                          #  3
    'NODE      B 0',                          #  4
    'NODE      C 4.5',                        #  5
    'WATER     S1 0 700',                     #  6
    'USE       ASAM',                         #  7
    'PIPE      P1 S1 A 12 100 1T 2E 1GV',     #  8
    'PIPE      P2 A B 6 50 1E',               #  9
    'PIPE      P3 B C 3 50',                  # 10
    'SPRINKLER H1 4.5 -50 80',                # 11
    'PIPE      P4 C H1 2 32',                 # 12
    'FIXEDFLOW F1 B 100 150',                 # 13
    '';

#==============================================================================
print "1. CHECKING THE BUFFER - statuses, problems, undefined and unused nodes\n";
#==============================================================================
{
    my $r = HardyCross::Editor::check_buffer($M);
    is('a good model: no problems, no undefined or unused nodes',
       !@{ $r->{problems} } && !@{ $r->{undefined} } && !@{ $r->{unused} });
    is('every line ok', !grep { $_ && $_->{status} ne 'ok' } @{ $r->{lines} });

    my $bad = $M . "PIPE P5 C X 5 50\nPIPE P6 X Y 5 50\nSPRINKLER H2 0\nPIPX P9\n"
                 . "METHOD HW\nMETHOD DW\nNODE A 1\nPIPE P1 A B 1 50\nNODE D 0\n";
    $r = HardyCross::Editor::check_buffer($bad);
    my %u = map { $_->{node} => $_->{line} } @{ $r->{undefined} };
    is('undefined nodes X and Y listed with the first line using each',
       ($u{X} // 0) == 14 && ($u{Y} // 0) == 15 && keys %u == 2,
       join ' ', map { "$_:$u{$_}" } sort keys %u);
    my %p = map { $_->{line} => $_->{message} } @{ $r->{problems} };
    is('an incomplete line is a problem (line 16, needs MINFLOW)', ($p{16} // '') eq 'SPRINKLER NEEDS MINFLOW');
    is('an unknown command is a problem (line 17)', ($p{17} // '') eq 'UNKNOWN COMMAND PIPX');
    is('a second METHOD is a problem naming the first (line 19)',
       ($p{19} // '') eq 'METHOD IS ALREADY SET ON LINE 18');
    is('a second NODE A is a problem naming the first (line 20)',
       ($p{20} // '') eq 'NODE A IS ALREADY DEFINED ON LINE 3');
    is('a pipe name used twice is a problem (line 21)',
       ($p{21} // '') eq 'THE NAME P1 IS ALREADY USED ON LINE 8');
    is('undefined nodes are not problems on their lines', !exists $p{14} && !exists $p{15});
    is('the line statuses agree: 16 incomplete, 17 and 19 error',
       $r->{lines}[16]{status} eq 'incomplete' && $r->{lines}[17]{status} eq 'error'
       && $r->{lines}[19]{status} eq 'error');
    my %un = map { $_->{node} => $_->{line} } @{ $r->{unused} };
    is('a node nothing connects to is listed as unused (D, line 22)', ($un{D} // 0) == 22 && keys %un == 1);
    $r = HardyCross::Editor::check_buffer($bad, 16);
    is('the line being edited is not listed while incomplete', !grep { $_->{line} == 16 } @{ $r->{problems} });
    $r = HardyCross::Editor::check_buffer("WATER S 0 600\nPIPE P S B 1 47\nUSE ASAM\nPIPE Q B C 1 47\n");
    is('USE applies from its line on: 47 mm fine as a bore, an error under ASAM',
       $r->{lines}[2]{status} eq 'ok' && $r->{lines}[4]{status} eq 'error', $r->{lines}[4]{message});
    is('every message is in capitals', !grep { $_->{message} =~ /[a-z]/ }
       @{ HardyCross::Editor::check_buffer($bad)->{problems} });
}

#==============================================================================
print "2. PROPOSALS - after each kind of line\n";
#==============================================================================
{
    my $prop = sub { HardyCross::Editor::proposal($M, shift) // '(NONE)' };
    is('after a pipe: next free name, starts at its end, keeps length and size',
       $prop->(10) eq 'PIPE P5 C C2 3 50', $prop->(10));
    is('after P1 the next free name is P5, as P2 to P4 are taken', $prop->(8) eq 'PIPE P5 A A2 12 100', $prop->(8));
    is('after a node: next name, same elevation', $prop->(5) eq 'NODE C2 4.5', $prop->(5));
    is('after a sprinkler: name stepped, the rest kept', $prop->(11) eq 'SPRINKLER H2 4.5 -50 80', $prop->(11));
    is('after a water supply', $prop->(6) eq 'WATER S2 0 700', $prop->(6));
    is('after a fixed flow', $prop->(13) eq 'FIXEDFLOW F2 B2 100 150', $prop->(13));
    is('after a setting: none', $prop->(2) eq '(NONE)');
    is('after a USE line: none', $prop->(7) eq '(NONE)');
    is('after a line with an error: none',
       (HardyCross::Editor::proposal("PIPE P1 A\n", 1) // '(NONE)') eq '(NONE)');
}

#==============================================================================
print "3. PICK LISTS AND THE STATUS BAR\n";
#==============================================================================
{
    my %c = map { $_->[0] => 1 } @{ HardyCross::Editor::choices($M . "\nUSE \n", 15, 10) };
    is('USE type field: the database pipe types and BORE',
       $c{ASAM} && $c{ASAH} && $c{S20} && $c{S40} && $c{CPVC} && $c{PE11} && $c{BORE});
    my %f = map { $_->[0] => $_->[1] } @{ HardyCross::Editor::choices($M . "PIPE P5 C A 3 50 \n", 14, 27) };
    is('fitting field under USE ASAM, DN50: the codes with descriptions',
       $f{E} && $f{T} && $f{GV} && $f{CV} && $f{E} =~ /ELBOW/);
    is('   and the short forms G and C', ($f{G} // '') =~ /SHORT FOR GV/ && ($f{C} // '') =~ /SHORT FOR CV/);
    is('a WATER line: no pick list', !@{ HardyCross::Editor::choices($M, 6, 14) });

    my $st = HardyCross::Editor::status_at($M, 8, 19);
    is('status bar on line 8 at the length: the PIPE template, LENGTH current',
       $st->{template}{command} eq 'PIPE'
       && $st->{template}{fields}[ $st->{template}{current} ] eq 'LENGTH');
    is('   the template text', $st->{template}{text} eq 'PIPE <NAME> <START> <END> <LENGTH> <SIZE> [FITTINGS ...]',
       $st->{template}{text});
    $st = HardyCross::Editor::status_at('PIPE P1 A', 1, 9);
    is('a half-typed line: incomplete, needs END', $st->{status} eq 'incomplete' && $st->{message} eq 'PIPE NEEDS END');
}

#==============================================================================
print "4. SYNTAX COLOURING\n";
#==============================================================================
{
    my @s = HardyCross::Editor::colour_spans('  PIPE P1 A B 1 50 2E  // MAIN');
    my %k = map {; "$_->[0]-$_->[1]" => $_->[2] } @s;
    is('command word', ($k{'2-6'} // '') eq 'command');
    is('the new pipe\'s name, its two nodes', ($k{'7-9'} // '') eq 'name' && ($k{'10-11'} // '') eq 'ref'
       && ($k{'12-13'} // '') eq 'ref');
    is('length and size are numbers, the fitting a keyword',
       ($k{'14-15'} // '') eq 'number' && ($k{'16-18'} // '') eq 'number' && ($k{'19-21'} // '') eq 'keyword');
    is('comment span to the end of the line', ($k{'23-30'} // '') eq 'comment');
    my %b = map {; "$_->[0]-$_->[1]" => $_->[2] } HardyCross::Editor::colour_spans('BFP P1 0 10 500 40');
    is('after BFP the pipe is a reference, the curve numbers', $b{'4-6'} eq 'ref' && $b{'9-11'} eq 'number');
    is('USE: the pipe type a keyword',
       (grep { $_->[2] eq 'keyword' } HardyCross::Editor::colour_spans('USE ASAM')) == 1);
    is('an alias is a command word (P)', grep { $_->[2] eq 'command' } HardyCross::Editor::colour_spans('P P1 A B 1 50'));
    is('an unknown word: nothing coloured', !HardyCross::Editor::colour_spans('PIPX P1 A'));
    is('a comment-only line', (HardyCross::Editor::colour_spans('// NOTE'))[0][2] eq 'comment');
}

#==============================================================================
print "5. SOLVE AND RESULTS ON THE CURSOR\n";
#==============================================================================
my $net;
{
    my $r = HardyCross::Editor::solve_text($M, 'TEST.PHC');
    is('the model solves and converges', $r->{ok} && $r->{converged}, $r->{error});
    is('the report is the full report', ($r->{report} // '') =~ /PIPE SCHEDULE/i
       && $r->{report} =~ /OUTLET COMPLIANCE/i);
    $net = $r->{net};
    my @l = split /\n/, $M;
    my $res = sub { HardyCross::Editor::results_at($net, $l[ $_[0] - 1 ]) // '(NONE)' };
    my ($p1) = grep { ($_->{id} // '') eq 'P1' } @{ $net->{elems} };
    my $q = sprintf '%.1f', abs $p1->{q};
    is("pipe P1: flow $q L/MIN, velocity, end pressures",
       $res->(8) =~ /^P1  Q \Q$q\E L\/MIN  V [\d.]+ M\/S  S1 700\.0 KPA -> A [\d.]+ KPA$/, $res->(8));
    # Velocity checked by hand: Q / A with the ASAM DN100 bore of 105.1 mm.
    my ($v) = $res->(8) =~ /V ([\d.]+)/;
    my $vh = abs($p1->{q}) / 60000 / (3.14159265358979 * 0.1051 ** 2 / 4);
    is(sprintf('   velocity %.2f M/S agrees with Q/A by hand', $vh), abs($v - $vh) < 0.006);
    is('sprinkler H1: discharge and pressure, with the required',
       $res->(11) =~ /^H1  DISCHARGE [\d.]+ L\/MIN AT [\d.]+ KPA \(REQUIRED 50\.0\)$/, $res->(11));
    is('node C: pressure and elevation', $res->(5) =~ /^C  PRESSURE [\d.]+ KPA, ELEVATION 4\.500 M$/, $res->(5));
    is('water supply S1', $res->(6) =~ /^S1  SUPPLIES [\d.]+ L\/MIN AT 700\.0 KPA$/, $res->(6));
    is('fixed flow F1: flow, pressure, required',
       $res->(13) =~ /^F1  FIXED 100\.0 L\/MIN AT [\d.]+ KPA \(REQUIRED 150\.0\)$/, $res->(13));
    is('a setting line: no results', $res->(2) eq '(NONE)');
    is('a line added since the solve: no results',
       !defined HardyCross::Editor::results_at($net, 'PIPE P99 A B 1 50'));

    $r = HardyCross::Editor::solve_text($M . "PIPE P9 A Z 3 50\n", 'TEST.PHC');
    is('an error stops the solve and gives its line (14)', !$r->{ok} && ($r->{line} // 0) == 14, $r->{error});
    is('   the error is in capitals', ($r->{error} // 'x') !~ /[a-z]/, $r->{error});
    my $lps = "UNITS FLOW LPS\nUNITS PRESSURE BAR\nWATER S 0 7\nPIPE P1 S B 10 100\nSPRINKLER B 0 0 1.2\n";
    $r = HardyCross::Editor::solve_text($lps);
    is('results are in the model\'s own units (L/S and BAR)',
       (HardyCross::Editor::results_at($r->{net}, 'PIPE P1 S B 10 100') // '') =~ /L\/S .* BAR -> B [\d.]+ BAR$/);
}

#==============================================================================
print "6. THE LISTS BESIDE THE EDITOR\n";
#==============================================================================
{
    my $d = HardyCross::Editor::diagnostics($M, $net);
    is('a good model: no errors, no node notes', !@{ $d->{errors} } && !@{ $d->{nodes} });
    my %w = map { $_->{line} => $_->{message} } grep { defined $_->{line} } @{ $d->{warnings} };
    is('velocity warnings for P2, P3 and P4, on their lines',
       ($w{9} // '') =~ /^P2 - VELOCITY [\d.]+ M\/S IS OVER THE LIMIT OF 6 M\/S$/ && $w{10} && $w{12}
       && !$w{8}, join ' / ', map { "$_: $w{$_}" } sort keys %w);
    $d = HardyCross::Editor::diagnostics($M . "NODE D 0\nPIPE P5 C X 1 50\n");
    my @n = map { "$_->{line} $_->{message}" } @{ $d->{nodes} };
    is('NODES: used but not defined, and defined but unconnected',
       "@n" eq '15 X - USED, BUT NOT DEFINED 14 D - DEFINED, BUT NOTHING CONNECTS TO IT', "@n");
    is('no solve, no warnings', !@{ $d->{warnings} });

    my $f = "WATER S 0 300\nPIPE P1 S H 30 50\nSPRINKLER H 0 2000 80\n";
    my $s = HardyCross::Editor::solve_text($f);
    $d = HardyCross::Editor::diagnostics($f, $s->{net});
    is('an outlet short of its requirement is a warning on its line',
       grep { ($_->{line} // 0) == 3 && $_->{message} =~ /^H - BELOW ITS REQUIREMENT/ } @{ $d->{warnings} });
}

#==============================================================================
print "7. THE RESULTS TABLES\n";
#==============================================================================
{
    my $t = HardyCross::Editor::result_tables($net);
    my @cols = @{ $t->{pipes}{columns} };
    is('21 pipe columns, NAME first and fixed', @cols == 21 && $cols[0]{key} eq 'NAME' && $cols[0]{fixed});
    my @shown = map { $_->{key} } grep { $_->{show} } @cols;
    is('shown by default: NAME to PF, PS and VEL',
       "@shown" eq 'NAME SNODE ENODE NOM ID MAT C L F T K Q PF PS VEL', "@shown");
    is('every heading and description in capitals', !grep { "$_->{head}$_->{desc}" =~ /[a-z]/ } @cols);
    my %col = map { $cols[$_]{key} => $_ } 0 .. $#cols;
    my %row = map { $_->{cells}[0] => $_ } @{ $t->{pipes}{rows} };
    my $c = sub { my ($p, $k) = @_; $row{$p}{cells}[ $col{$k} ] };
    is('P1: S1 to A, DN100, 105.1 mm, ASAM, C 120',
       $c->('P1', 'SNODE') eq 'S1' && $c->('P1', 'ENODE') eq 'A' && $c->('P1', 'NOM') eq '100'
       && $c->('P1', 'ID') eq '105.1' && $c->('P1', 'MAT') eq 'ASAM' && $c->('P1', 'C') eq '120');
    is('P1: L + F = T', abs($c->('P1', 'L') + $c->('P1', 'F') - $c->('P1', 'T')) < 0.006 && $c->('P1', 'F') > 0);
    is('P3 climbs 4.5 m: PE = 9.807 x 4.5 = 44.13 KPA', $c->('P3', 'PE') eq '44.13', $c->('P3', 'PE'));
    is('PF/M is PF over the total length',
       abs($c->('P2', 'PFX') - $c->('P2', 'PF') / $c->('P2', 'T')) < 1e-3);
    is('no device in a pipe: PS is -', $c->('P1', 'PS') eq '-');
    is('Hazen-Williams: no Darcy factor, formula HW', $c->('P1', 'FD') eq '-' && $c->('P1', 'FORMULA') eq 'HW');
    is('every pipe flowing is active', !grep { !$_->{active} } @{ $t->{pipes}{rows} });

    my %n = map { $_->{cells}[0] => $_->{cells} } @{ $t->{nodes}{rows} };
    is('NODES: types WATER, FIXEDFLOW, SPRINKLER and NODE',
       $n{S1}[1] eq 'WATER' && $n{B}[1] eq 'FIXEDFLOW' && $n{H1}[1] eq 'SPRINKLER' && $n{C}[1] eq 'NODE');
    is('   B: 100 L/MIN, 150 required, margin = pressure - 150',
       $n{B}[4] eq '100.0' && $n{B}[5] eq '150.0' && abs($n{B}[6] - ($n{B}[3] - 150)) < 0.06);
    my %o = map { $_->{cells}[0] => $_->{cells} } @{ $t->{outlets}{rows} };
    is('OUTLETS: H1, K 80, PASS', $o{H1} && $o{H1}[3] eq '80.000' && $o{H1}[9] eq 'PASS');
    is('   the minimum flow of a sprinkler set by pressure is K x sqrt(50) = 565.7',
       $o{H1}[4] eq '565.7', $o{H1}[4]);
    is('   the fixed flow is listed, K FIXED', $o{F1} && $o{F1}[3] eq 'FIXED' && $o{F1}[9] eq 'PASS');

    my $rows = $t->{pipes}{rows};
    my @q = map { $_->{keys}[ $col{Q} ] } @{ HardyCross::Editor::sort_rows($rows, $col{Q}, 0) };
    is('sorting on Q: ascending as numbers', !grep { $q[$_] > $q[ $_ + 1 ] } 0 .. $#q - 1);
    my @names = map { $_->{cells}[0] } @{ HardyCross::Editor::sort_rows($rows, $col{VEL}, 1) };
    is('sorting on VEL descending: P4, the smallest pipe, first', $names[0] eq 'P4', "@names");
    @names = map { $_->{cells}[0] } @{ HardyCross::Editor::sort_rows($rows, $col{ENODE}, 0) };
    is('sorting on ENODE: as text', "@names" eq 'P1 P2 P3 P4', "@names");
    my $tie = [ map { { keys => [ 1, $_ ] } } 1 .. 5 ];
    is('ties keep their order', join('', map { $_->{keys}[1] } @{ HardyCross::Editor::sort_rows($tie, 0, 0) }) eq '12345');

    my $mm = HardyCross::Editor::solve_text("UNITS LENGTH MM\n" . join "\n", grep { !/UNITS/ } split /\n/, $M);
    my $tm = HardyCross::Editor::result_tables($mm->{net});
    my ($lc) = grep { $_->{key} eq 'L' } @{ $tm->{pipes}{columns} };
    my ($r1) = grep { $_->{cells}[0] eq 'P1' } @{ $tm->{pipes}{rows} };
    is('lengths in the file\'s LENGTH unit: MM', $lc->{unit} eq 'MM' && $r1->{cells}[ $col{L} ] eq '12.00',
       "$lc->{unit} $r1->{cells}[ $col{L} ]");
}

#==============================================================================
print "8. THE DOCUMENT - settings in the PROJECT tab, the network in the editor\n";
#==============================================================================
my $EX7 = slurp("$EX/07_pipe_database_demo.phc");
{
    my $d = HardyCross::Editor::split_file($EX7);
    my $s = $d->{settings};
    is('the title and project details go to the settings',
       $s->{title} eq 'LEVEL 2 SPRINKLER RANGE - DEMONSTRATION' && $s->{project}{JOB} eq 'HYC-DEMO-017'
       && $s->{project}{AUTHORITY_PHONE} eq '02 9265 2999');
    is('   and the units and method', $s->{units}{LENGTH} eq 'M' && $s->{units}{FLOW} eq 'LPM' && $s->{method} eq 'HW');
    is('the network holds no setting line',
       $d->{network} !~ /^(TITLE|PROJECT|UNITS|METHOD|OPTION)\b/m && $d->{network} =~ /^WATER     SUP 0 650$/m
       && $d->{network} =~ /^PIPE      X1 R1 H3 9\.0 65 2E\n\z/m, substr($d->{network}, 0, 40));
    my ($full, $h) = HardyCross::Editor::join_file($s, $d->{network});
    my @fl = split /\n/, $full;
    is('join_file: the settings at the head, then a blank line, then the network',
       $fl[0] eq 'TITLE     LEVEL 2 SPRINKLER RANGE - DEMONSTRATION' && $fl[ $h - 1 ] eq ''
       && $fl[$h] eq 'WATER     SUP 0 650', "H $h: $fl[$h]");
    is('   every unit written, defaults included', (grep { /^UNITS / } @fl) == 6);
    my $r1 = HardyCross::Editor::solve_text($EX7);
    my $r2 = HardyCross::Editor::solve_text($full);
    my ($q1) = map { $_->{q} } grep { ($_->{id} // '') eq 'M1' } @{ $r1->{net}{elems} };
    my ($q2) = map { $_->{q} } grep { ($_->{id} // '') eq 'M1' } @{ $r2->{net}{elems} };
    is('the joined file solves exactly as the original', abs($q1 - $q2) < 1e-9);
    my $again = HardyCross::Editor::split_file($full);
    is('split, join and split again: the same settings and network',
       $again->{network} eq $d->{network} && (HardyCross::Editor::join_file($again->{settings}, $again->{network}))[0] eq $full);
    $d = HardyCross::Editor::split_file("UNITS FLOW LPS\nUNITS FLOW LPM\nUNITS SIZE XX\nNODE A 0\n");
    is('a repeated or bad setting stays in the network, to be seen and fixed',
       $d->{settings}{units}{FLOW} eq 'LPS' && $d->{network} eq "UNITS FLOW LPM\nUNITS SIZE XX\nNODE A 0\n", $d->{network});
    my $c = HardyCross::Editor::doc_check($d);
    is('   where it is an error: settings are set in the PROJECT tab',
       $c->{lines}[1]{message} eq 'UNITS IS SET IN THE PROJECT TAB, NOT IN THE NETWORK'
       && $c->{lines}[3]{status} eq 'ok');
    my $new = HardyCross::Editor::new_settings();
    is('new settings: the office default units, HW',
       $new->{units}{LENGTH} eq 'MM' && $new->{units}{KFACTOR} eq 'LPM/KPA' && $new->{method} eq 'HW');
}
{
    my $d = HardyCross::Editor::split_file($EX7);
    my $net = $d->{network};
    $d->{network} = $net . "PIPE Z1 H3 ZZ 3 32\nPIPE M2 R1 R2 3 50\n";
    my $c = HardyCross::Editor::doc_check($d);
    my %p = map { $_->{line} => $_->{message} } @{ $c->{problems} };
    is('doc_check numbers by network line, messages included',
       ($p{17} // '') eq 'THE NAME M2 IS ALREADY USED ON LINE 10', join ' / ', map { "$_: $p{$_}" } sort keys %p);
    is('   undefined nodes by network line', $c->{undefined}[0]{node} eq 'ZZ' && $c->{undefined}[0]{line} == 16);
    $d->{settings}{options}{VEL_LIMIT} = 'FAST';
    $c = HardyCross::Editor::doc_check($d);
    is('a bad option is a settings problem, named by its PROJECT tab field',
       $c->{settings_problems}[0]{field} eq 'VEL_LIMIT' && $c->{settings_problems}[0]{message} =~ /NOT A NUMBER/,
       $c->{settings_problems}[0]{message});
    my $dg = HardyCross::Editor::doc_diagnostics($d);
    is('   listed in ERRORS with its field and no line',
       !defined $dg->{errors}[0]{line} && $dg->{errors}[0]{field} eq 'VEL_LIMIT'
       && $dg->{errors}[0]{message} =~ /^PROJECT TAB, VEL_LIMIT: /);
    $d->{settings}{options}{VEL_LIMIT} = '';
    $d->{network} = $net;
    my $st = HardyCross::Editor::doc_status($d, 9, 22);
    is('doc_status: the PIPE template on network line 9', $st->{template}{command} eq 'PIPE');
    $d->{network} = $net . "PIPE Q1 R1 R2 3 50 \n";
    my %f = map { $_->[0] => 1 } @{ HardyCross::Editor::doc_choices($d, 16, 27) };
    is('doc_choices: the fittings, with the settings\' SIZE unit in force', $f{E} && $f{GV});
    $d->{network} = $net . "PIPE Q2 R1 NOWHERE 3 50\n";
    my $r = HardyCross::Editor::doc_solve($d);
    is('doc_solve: an error\'s line is the network line', !$r->{ok} && ($r->{line} // 0) == 16
       && $r->{error} =~ /^LINE 16: /, $r->{error});
    $d->{network} = $net;
    $r = HardyCross::Editor::doc_solve($d);
    is('doc_solve: the network with its settings solves', $r->{ok} && $r->{converged});
}

#==============================================================================
print "9. VALIDATE - what is wrong, why, and where\n";
#==============================================================================
{
    my $d = HardyCross::Editor::split_file($EX7);
    my $v = HardyCross::Editor::validate($d);
    is('a good model validates with nothing to report', $v->{ok} && !@{ $v->{items} });
    my $net = $d->{network};
    $d->{network} = $net . join "\n", 'PIPE Z1 H3 ZZ 3 32', 'SPRINKLER S9 0', 'PIPX', 'NODE LONE 0',
        'UNITS FLOW LPS', 'PIPE Q1 R1 R2 3 47', 'PIPE Q2 R1 R2 3 50 ZZ', 'PIPE M2 R1 R2 3 50', 'PIPE Q3 R1 R2 3X 50', '';
    $v = HardyCross::Editor::validate($d);
    my %it = map { $_->{line} => $_ } @{ $v->{items} };
    is('nine problems found, in line order, and not valid',
       !$v->{ok} && @{ $v->{items} } == 9 && join(' ', map { $_->{line} } @{ $v->{items} }) eq '16 17 18 19 20 21 22 23 24',
       join(' ', map { $_->{line} } @{ $v->{items} }));
    my $at = sub { my $i = $it{ $_[0] }; my @l = split /\n/, $d->{network}; substr($l[ $_[0] - 1 ], $i->{start}, $i->{end} - $i->{start}) };
    is('an undefined node: the node itself, with why',
       $it{16}{what} eq 'NODE ZZ IS USED, BUT NOT DEFINED' && $at->(16) eq 'ZZ' && $it{16}{why} =~ /DEFINED BY NODE/);
    is('a short line: just past its end, naming the field it needs, and the template',
       $it{17}{what} eq 'SPRINKLER NEEDS MINFLOW' && $it{17}{field} eq 'MINFLOW' && $it{17}{start} == 14
       && $it{17}{why} =~ /SPRINKLER <NAME> <ELEVATION> <MINFLOW> <K>/, "$it{17}{start} $it{17}{why}");
    is('an unknown command: the command word, and the commands listed',
       $at->(18) eq 'PIPX' && $it{18}{field} eq 'COMMAND' && $it{18}{why} =~ /USE PIPE PC/);
    is('a node nothing connects to', $it{19}{what} eq 'NOTHING CONNECTS TO NODE LONE' && $at->(19) eq 'LONE');
    is('a setting in the network: the command word, and where it belongs',
       $at->(20) eq 'UNITS' && $it{20}{why} =~ /PROJECT TAB/);
    is('a size not in the database: the SIZE field, and why a bore is not guessed',
       $at->(21) eq '47' && $it{21}{field} eq 'SIZE' && $it{21}{why} =~ /NEVER GUESSED/);
    is('a bad fitting: the fitting code', $at->(22) eq 'ZZ' && $it{22}{why} =~ /FITTING CODES/);
    is('a name used twice: the name, and why names are unique',
       $at->(23) eq 'M2' && $it{23}{what} eq 'THE NAME M2 IS ALREADY USED ON LINE 10' && $it{23}{why} =~ /ONE SET OF NAMES/);
    is('a bad length: the length field, and how a length is written, in the file\'s unit',
       $at->(24) eq '3X' && $it{24}{field} eq 'LENGTH' && $it{24}{why} =~ /LENGTH UNIT \(M\)/);
    is('every what and why in capitals', !grep { "$_->{what}$_->{why}" =~ /[a-z]/ } @{ $v->{items} });

    # Structure: lines all good, but part of the network is cut off.
    my $island = HardyCross::Editor::split_file("WATER S 0 500\nNODE A 0\nNODE B 0\nNODE C 0\n"
        . "PIPE P1 S A 1 50\nPIPE P2 B C 1 50\nSPRINKLER H 0 0 80\nPIPE P3 A H 1 50\n");
    $v = HardyCross::Editor::validate($island);
    is('a part of the network cut off from the rest: found before any calculation',
       !$v->{ok} && $v->{items}[0]{what} =~ /^NODE [BC] IS NOT CONNECTED/ && $v->{items}[0]{line} =~ /^[34]$/,
       $v->{items}[0]{what});
    $d = HardyCross::Editor::split_file($EX7);
    $d->{settings}{options}{TOL_FLOW} = 'TIGHT';
    $v = HardyCross::Editor::validate($d);
    is('a bad option: in the PROJECT tab, its field named',
       !$v->{ok} && $v->{items}[0]{tab} eq 'PROJECT' && $v->{items}[0]{field} eq 'TOL_FLOW' && !defined $v->{items}[0]{line});
}

#==============================================================================
print "10. FILES - open .phc only, write the report\n";
#==============================================================================
{
    my $r = HardyCross::Editor::load_file("$EX/01_single_branch.phc");
    is('a .phc opens as it is, with its path', $r->{path} =~ /01_single_branch\.phc$/
       && $r->{text} eq slurp("$EX/01_single_branch.phc"));
    open my $fh, '>', "$TMP/crlf.phc" or die; binmode $fh; print $fh "TITLE A\r\nNODE B 0\r\n"; close $fh;
    is('Windows line endings are read as plain lines',
       HardyCross::Editor::load_file("$TMP/crlf.phc")->{text} eq "TITLE A\nNODE B 0\n");
    my $ok = eval { HardyCross::Editor::load_file("$TMP/old.hcx"); 1 };
    is('any other file is refused, with the reason',
       !$ok && HardyCross::is_model_error($@) && $@->{msg} =~ /THE EDITOR WORKS IN \.PHC FILES/);

    my $s = HardyCross::Editor::solve_text($M, 'TEST.PHC');
    HardyCross::Editor::write_report_file($s->{net}, $s->{converged}, 'TEST.PHC', "$TMP/r.txt");
    HardyCross::Editor::write_report_file($s->{net}, $s->{converged}, 'TEST.PHC', "$TMP/r.pdf");
    is('WRITE REPORT .txt is the ASCII report', -s "$TMP/r.txt" && slurp("$TMP/r.txt") =~ /PIPE SCHEDULE/i
       && slurp("$TMP/r.txt") !~ /[^\x00-\x7f]/);
    is('WRITE REPORT .pdf is a PDF', -s "$TMP/r.pdf" && slurp("$TMP/r.pdf") =~ /^%PDF-/);
}

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
