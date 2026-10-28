#!/usr/bin/perl
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# test_dbedit.pl -- editing the pipe and fitting database, and choosing where
# it is kept, without Tk (HardyCross::DbEdit, HardyCross::Settings).
#
#   perl tools/test_dbedit.pl
#
# Works on copies in a temporary folder, with its own settings file
# (PHCP_SETTINGS), so the real database and a user's real settings are never
# read or written.
#==============================================================================
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";
use File::Temp qw(tempdir);
use File::Copy qw(copy);
use File::Spec;

my $TMP = tempdir(CLEANUP => 1);
$ENV{PHCP_SETTINGS} = "$TMP/settings.ini";
delete $ENV{PHCP_DATABASE_DIR};
require HardyCross::DbEdit;
require HardyCross::PipeData;
require HardyCross::Settings;
require HardyCross::Editor;

my ($pass, $fail) = (0, 0);
sub is {
    my ($name, $ok, $why) = @_;
    printf "  %-66s %s\n", $name, $ok ? 'ok' : '*** FAIL';
    print "      $why\n" if !$ok && defined $why;
    $ok ? $pass++ : $fail++;
}
sub slurp { my $p = shift; open my $f, '<:raw', $p or die "$p: $!\n"; local $/; <$f> }
my $REAL = "$FindBin::Bin/../data/pipes.dat";
my $ORIG = slurp($REAL);

#==============================================================================
print "1. READING - four tables, the file kept as it is\n";
#==============================================================================
copy($REAL, "$TMP/a.dat") or die;
my $db = HardyCross::DbEdit::open_db("$TMP/a.dat");
no warnings 'once';
my %n = map { $_->[0] => scalar @{ HardyCross::DbEdit::rows($db, $_->[0]) } } @HardyCross::DbEdit::TABLES;
is('the four tables: 8 pipe types, 101 sizes, 219 fittings, 19 K\' factors',
   $n{PIPETYPE} == 8 && $n{PIPE} == 101 && $n{FIT} == 219 && $n{KPRIME} == 19, join ' ', map { "$_ $n{$_}" } sort keys %n);
is('an unchanged database writes back to the same bytes', HardyCross::DbEdit::text($db) eq $ORIG);
is('the window shows capitals and ASCII: 90 DEG STANDARD ELBOW',
   HardyCross::DbEdit::shown('90° standard elbow') eq '90 DEG STANDARD ELBOW');

#==============================================================================
print "2. EDITING - change, add, delete; what was not edited keeps its text\n";
#==============================================================================
{
    my ($e) = grep { $_->{fields}[1] eq 'E' && $_->{fields}[3] eq '50' && $_->{fields}[0] eq 'AS' }
              @{ HardyCross::DbEdit::rows($db, 'FIT') };
    my @shown = map { HardyCross::DbEdit::shown($_) } @{ $e->{fields} };
    $shown[4] = '1.6';
    my $err = HardyCross::DbEdit::set_row($db, $e->{line}, \@shown);
    is('a length changed from the window', !$err && $db->{lines}[ $e->{line} ]{fields}[4] eq '1.6', $err);
    is('   the fitting name, not edited, keeps its degree sign and case',
       $db->{lines}[ $e->{line} ]{text} eq "FIT|AS|E|90\x{B0} standard elbow|50|1.6", $db->{lines}[ $e->{line} ]{text});
    is('   and the file is marked changed', $db->{modified});
    $err = HardyCross::DbEdit::set_row($db, $e->{line}, [ @shown[0 .. 3], 'LOTS' ]);
    is('a length that is not a number is refused, saying why', ($err // '') =~ /EQV LENGTH M 'LOTS' MUST BE A NUMBER/, $err);
    $err = HardyCross::DbEdit::set_row($db, $e->{line}, [ @shown[0 .. 3], 'DASH' ]);
    is('DASH, none published, is accepted for a length', !$err, $err);
    my ($e2, $at) = HardyCross::DbEdit::add_row($db, 'PIPE', [ 'ASAM', '200', '219.1', '206.5', '5e-08' ]);
    is('a new pipe size is added after the last of its kind',
       !$e2 && $db->{lines}[$at]{text} eq 'PIPE|ASAM|200|219.1|206.5|5e-08'
       && ($db->{lines}[ $at - 1 ]{kind} // '') eq 'PIPE' && ($db->{lines}[ $at + 1 ]{kind} // '') ne 'PIPE', $e2);
    ($e2) = HardyCross::DbEdit::add_row($db, 'PIPE', [ 'ASAM', '200', '219.1', '206.5', '5e-08' ]);
    is('the same size again is refused', ($e2 // '') =~ /ALREADY A ROW FOR ASAM 200/, $e2);
    ($e2) = HardyCross::DbEdit::add_row($db, 'PIPE', [ 'NOPE', '50', '60', '50', '1e-5' ]);
    is('a size for a pipe type that does not exist is refused', ($e2 // '') =~ /PIPE TYPE NOPE IS NOT IN PIPE TYPES/, $e2);
    ($e2) = HardyCross::DbEdit::add_row($db, 'PIPE', [ 'ASAM', '225', '200', '210', '1e-8' ]);
    is('a bore larger than its OD is refused', ($e2 // '') =~ /BORE MM 210 MUST BE LESS THAN OD MM 200/, $e2);
    ($e2) = HardyCross::DbEdit::add_row($db, 'KPRIME', [ 'x y', 'A', '5', '' ]);
    is('a code with lower case or spaces is refused', ($e2 // '') =~ /CAPITALS AND DIGITS/, $e2);
    ($e2) = HardyCross::DbEdit::add_row($db, 'KPRIME', [ 'ZZ', 'A|B', '5', '' ]);
    is('a | in a field is refused', ($e2 // '') =~ /SEPARATES FIELDS/, $e2);
    my ($pt) = grep { $_->{fields}[0] eq 'ASAM' } @{ HardyCross::DbEdit::rows($db, 'PIPETYPE') };
    my $d = HardyCross::DbEdit::delete_row($db, $pt->{line});
    is('a pipe type with sizes cannot be deleted', ($d // '') =~ /STILL HAS 12 PIPE SIZES/, $d);
    my ($kp) = grep { $_->{fields}[0] eq 'TR' } @{ HardyCross::DbEdit::rows($db, 'KPRIME') };
    is('a K\' factor row can be deleted', !HardyCross::DbEdit::delete_row($db, $kp->{line})
       && !grep { $_->{fields}[0] eq 'TR' } @{ HardyCross::DbEdit::rows($db, 'KPRIME') });
    my ($ah) = grep { $_->{fields}[0] eq 'ASAH' && $_->{fields}[1] eq '150' } @{ HardyCross::DbEdit::rows($db, 'PIPE') };
    is('a pipe size can be deleted', !HardyCross::DbEdit::delete_row($db, $ah->{line}));
    is('every row still passes', !@{ HardyCross::DbEdit::check_all($db) });
}

#==============================================================================
print "3. SAVING - checked, dated, loaded, fingerprinted\n";
#==============================================================================
{
    my $r = HardyCross::DbEdit::save($db, "$TMP/a.dat", '1 November 2026');
    is('the edited database saves', $r->{ok}, join ' / ', map { $_->{message} } @{ $r->{problems} || [] });
    my $t = slurp("$TMP/a.dat");
    is('   the DATASET line takes the date of the change', $t =~ /^DATASET\|Hycadia pipe and fitting database\|1 November 2026\r?$/m);
    is('   it is the database in use now, with the new fingerprint',
       HardyCross::PipeData::path() eq "$TMP/a.dat" && HardyCross::PipeData::sha256() eq $r->{sha256}
       && HardyCross::PipeData::bore('ASAM', 200) == 206.5);
    is('   the deleted row is gone from the loaded data too (a reload starts clean)',
       !defined HardyCross::PipeData::bore('ASAH', 150) && defined HardyCross::PipeData::bore('ASAH', 125));
    is('   comments and blank lines are all still there',
       (() = $t =~ /^#/mg) == (() = $ORIG =~ /^#/mg) && (() = $t =~ /^$/mg) == (() = $ORIG =~ /^$/mg));
    is('   and nothing was left behind (no .new file)', !-e "$TMP/a.dat.new");

    my $d2 = HardyCross::DbEdit::open_db("$TMP/a.dat");
    my $other = HardyCross::DbEdit::open_db("$TMP/a.dat");
    my ($e) = @{ HardyCross::DbEdit::rows($other, 'KPRIME') };
    HardyCross::DbEdit::set_row($other, $e->{line}, [ map { HardyCross::DbEdit::shown($_) } @{ $e->{fields} }[0 .. 1], '41', '' ]);
    HardyCross::DbEdit::save($other, "$TMP/a.dat");
    my ($f) = @{ HardyCross::DbEdit::rows($d2, 'KPRIME') };
    HardyCross::DbEdit::set_row($d2, $f->{line}, [ map { HardyCross::DbEdit::shown($_) } @{ $f->{fields} }[0 .. 1], '42', '' ]);
    $r = HardyCross::DbEdit::save($d2, "$TMP/a.dat");
    is('two people at once: the second save is refused, not lost over the first',
       !$r->{ok} && $r->{problems}[0]{message} =~ /SAVED BY SOMEONE ELSE/ && slurp("$TMP/a.dat") =~ /\|41\|/);
}

#==============================================================================
print "4. WHERE THE DATABASE IS - a team folder, else the built-in one\n";
#==============================================================================
{
    HardyCross::DbEdit::use_builtin();
    is('with no folder set, the built-in database is used',
       !defined HardyCross::Settings::database_dir() && HardyCross::PipeData::origin() eq 'BUILT-IN');
    my $team = "$TMP/team";
    mkdir $team;
    my $err = HardyCross::DbEdit::use_folder($team, 0);
    is('an empty folder is refused unless the database is to be copied there', ($err // '') =~ /HAS NO PIPES.DAT/, $err);
    $err = HardyCross::DbEdit::use_folder($team, 1);
    is('choosing it with copy: this database is copied there and used',
       !$err && -e "$team/pipes.dat" && slurp("$team/pipes.dat") eq $ORIG
       && HardyCross::PipeData::origin() eq 'TEAM FOLDER', $err);
    is('   the choice is kept in the settings file',
       HardyCross::Settings::get('DATABASE_DIR') eq $team && slurp($ENV{PHCP_SETTINGS}) =~ /^DATABASE_DIR=\Q$team\E\r?$/m);   # CR LF on Windows
    is('   and the next load, anywhere in the program, uses it',
       HardyCross::PipeData::default_path() eq File::Spec->catfile($team, 'pipes.dat'));
    my $ed = HardyCross::DbEdit::open_db();
    is('   editing it saves back to the team folder', HardyCross::DbEdit::save_path($ed) eq File::Spec->catfile($team, 'pipes.dat'));
    my $r = HardyCross::Editor::solve_text(slurp("$FindBin::Bin/../examples/07_pipe_database_demo.phc"));
    (my $flat = $r->{report} // '') =~ s/\s+/ /g;
    is('   a report names the team folder\'s file in full, and says it is the team\'s',
       $flat =~ /\Q$team\E.?pipes\.dat \(team folder\), SHA-256 [0-9a-f]{64}/, substr($flat, index($flat, 'database:'), 200));
    unlink "$team/pipes.dat";
    my $ok = eval { HardyCross::PipeData::load(); 1 };
    is('if the team folder cannot be read, loading stops and says where - no quiet fallback',
       !$ok && $@ =~ /cannot open the pipe and fitting database .*team.*the database folder set in the PHCP settings/s, $@);
    $err = HardyCross::DbEdit::use_folder("$TMP/nowhere", 1);
    is('a folder that does not exist is refused', ($err // '') =~ /DOES NOT EXIST/, $err);
    local $ENV{PHCP_DATABASE_DIR} = "$TMP/env";
    is('PHCP_DATABASE_DIR, if set, wins over the settings file', HardyCross::Settings::database_dir() eq "$TMP/env");
    delete $ENV{PHCP_DATABASE_DIR};
    HardyCross::DbEdit::use_builtin();
    is('USE BUILT-IN clears the setting and goes back', !defined HardyCross::Settings::database_dir()
       && HardyCross::PipeData::origin() eq 'BUILT-IN');
}
print "5. ROUGHNESS - a column of PIPE TYPES\n";
{
    my @c = map { $_->[0] } @{ HardyCross::DbEdit::table('PIPETYPE')->{cols} };
    is('PIPE TYPES has ROUGHNESS MM after C FACTOR', "@c[4, 5]" eq 'C FACTOR ROUGHNESS MM');
    my $d = HardyCross::DbEdit::open_db($REAL);
    my ($pe) = grep { $_->{fields}[0] eq 'PE11' } @{ HardyCross::DbEdit::rows($d, 'PIPETYPE') };
    is('   PE11 reads 0.007 mm', $pe && $pe->{fields}[5] eq '0.007');
    my @shown = map { HardyCross::DbEdit::shown($_) } @{ $pe->{fields} };
    $shown[5] = '0';
    my $e0 = HardyCross::DbEdit::set_row($d, $pe->{line}, \@shown);
    is('   a roughness of 0 is refused', ($e0 // '') =~ qr/ROUGHNESS MM '0' MUST BE A NUMBER ABOVE ZERO, OR DASH/);
    $shown[5] = '0.015';
    is('   0.015 is accepted', !defined HardyCross::DbEdit::set_row($d, $pe->{line}, \@shown) && $d->{modified});
    # A database from before the column: its pipe types read with DASH.
    (my $old = slurp($REAL)) =~ s/^(PIPETYPE\|[^\n]*)\|[^|\n]*$/$1/mg;
    open my $o, '>', "$TMP/old.dat" or die;
    print $o $old;
    close $o;
    my $od = HardyCross::DbEdit::open_db("$TMP/old.dat");
    my $p = HardyCross::DbEdit::check_all($od);
    is('   an older database without it opens: roughness DASH, nothing to put right, nothing changed',
       !@$p && !$od->{modified} && (grep { $_->{fields}[0] eq 'ASAM' } @{ HardyCross::DbEdit::rows($od, 'PIPETYPE') })[0]{fields}[5] eq 'DASH',
       join '; ', map { $_->{message} } @$p);
}
is('the real database was never touched', slurp($REAL) eq $ORIG);

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
