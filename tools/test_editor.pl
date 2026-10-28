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
# PIPES, NODES and OUTLETS tables and their sorting, the units, and how files
# are opened and reports written.  The window itself is driven by
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
print "4. COLOURING\n";
#==============================================================================
{
    my @s = HardyCross::Editor::colour_spans('  PIPE P1 A B 1 50  // MAIN');
    is('command word span', grep { $_->[2] eq 'command' && $_->[0] == 2 && $_->[1] == 6 } @s);
    is('comment span to the end of the line', grep { $_->[2] eq 'comment' && $_->[0] == 20 && $_->[1] == 27 } @s);
    is('an alias is a command word (P)', grep { $_->[2] eq 'command' } HardyCross::Editor::colour_spans('P P1 A B 1 50'));
    is('an unknown word is not coloured as a command',
       !grep { $_->[2] eq 'command' } HardyCross::Editor::colour_spans('PIPX P1'));
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
print "8. UNITS\n";
#==============================================================================
{
    my $u = HardyCross::Editor::units_of($M);
    is('units_of: the file\'s LENGTH M, defaults for the rest',
       $u->{LENGTH} eq 'M' && $u->{ELEVATION} eq 'M' && $u->{SIZE} eq 'MM' && $u->{PRESSURE} eq 'KPA'
       && $u->{FLOW} eq 'LPM' && $u->{KFACTOR} eq 'LPM/KPA');
    my $t = HardyCross::Editor::set_units($M, { %$u, LENGTH => 'MM', PRESSURE => 'BAR' });
    my @l = split /\n/, $t;
    is('set_units rewrites an existing UNITS line where it stands',
       (grep { $l[$_] eq 'UNITS     LENGTH MM' } 0 .. $#l) == 1 && $l[2] eq 'UNITS     LENGTH MM', $l[2]);
    is('   and adds a line for a changed quantity', (grep { $_ eq 'UNITS     PRESSURE BAR' } @l) == 1);
    is('   but none for a default left as it is', !grep { /UNITS\s+(FLOW|SIZE)/ } @l);
    is('   the rest of the text untouched', (join "\n", grep { !/^UNITS/ } @l) eq
       (join "\n", grep { !/^UNITS/ } split /\n/, $M));
    my $c = "// HEADER\nPIPE P1 A B 1 50\n";
    is('a new UNITS line goes after the leading comments',
       (split /\n/, HardyCross::Editor::set_units($c, { FLOW => 'LPS' }))[1] eq 'UNITS     FLOW LPS');
}

#==============================================================================
print "9. FILES - open .phc only, write the report\n";
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
