#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
# DbEdit.pm -- editing the pipe and fitting database, without Tk.
#
# The editor's DATABASE tab shows data/pipes.dat as four tables -- pipe types,
# pipe sizes, fittings and K' factors -- and lets a user change, add and
# delete rows.  Every decision about that is made here, so it can be tested
# headless (tools/test_dbedit.pl); the window only draws.
#
# What it guarantees:
#   - The file is edited in place, line by line.  Comments, blank lines and
#     the order of the records are kept; an unchanged database saves to the
#     same bytes.
#   - The window shows text in capitals and 7-bit ASCII, as the rest of the
#     program does ("90 DEG STANDARD ELBOW" for "90° standard elbow").  A
#     field the user did not change keeps its original text, degree sign and
#     case included: an edit replaces only what was edited.
#   - Nothing is saved that the program could not use.  Every row is checked
#     -- the right number of fields, numbers where numbers belong (or DASH,
#     "none published"), a pipe size only for a pipe type that exists, no two
#     rows for the same thing -- and the whole file is then read by
#     HardyCross::PipeData::load, the reader the solver uses, before it
#     replaces the old one.
#   - Saving dates the DATASET line, which the report prints, and the report
#     prints the new file's SHA-256: every calculation after an edit says
#     which data it used.
#
# Where it saves (save_path): back to the file it was opened from -- the team
# folder's, or the source folder's -- except the copy packed inside an .exe,
# which cannot be written; that goes to data/pipes.dat beside the program
# (HardyCross::PipeData::user_path), which then wins over the packed one.
#
# A shared database on a network drive can be edited by two people at once.
# The file's SHA-256 is noted when it is opened; if the file on disk no longer
# has it when saving, someone else has saved in between, and the save is
# refused rather than overwrite their change.

package HardyCross::DbEdit;

use strict;
use warnings;
use File::Basename qw(dirname);
use File::Path qw(make_path);
use Digest::SHA;
use HardyCross;
use File::Spec;
use HardyCross::PipeData;
use HardyCross::Settings;
use HardyCross::Phc;

#------------------------------------------------------------------------------
# The four tables: their record kind, title, and columns.  A column is
# [ heading, type ]: text, code (capitals and digits, no spaces), int (a
# positive whole number), num (a positive number), or num0 (a number that may
# be DASH, "none published").  The order is the order of the fields in the
# file.
#------------------------------------------------------------------------------
our @TABLES = (
    [ 'PIPETYPE', 'PIPE TYPES',
      [ [ 'CODE', 'code' ], [ 'NAME', 'text' ], [ 'STANDARD', 'text' ], [ 'SIZE RANGE', 'text' ],
        [ 'C FACTOR', 'num' ] ] ],
    [ 'PIPE', 'PIPE SIZES',
      [ [ 'PIPE TYPE', 'code' ], [ 'DN', 'int' ], [ 'OD MM', 'num0' ], [ 'BORE MM', 'num0' ],
        [ 'K', 'num0' ] ] ],
    [ 'FIT', 'FITTINGS',
      [ [ 'SOURCE', 'code' ], [ 'CODE', 'code' ], [ 'FITTING', 'text' ], [ 'DN', 'int' ],
        [ 'EQV LENGTH M', 'num0' ] ] ],
    [ 'KPRIME', "K' FACTORS",
      [ [ 'CODE', 'code' ], [ 'COMPONENT', 'text' ], [ "K'", 'num' ], [ 'OFFICE USE', 'text' ] ] ],
);
my %TABLE = map { $_->[0] => { kind => $_->[0], title => $_->[1], cols => $_->[2] } } @TABLES;
sub table { $TABLE{ shift() } }

# The window's form of a field: capitals, 7-bit ASCII.
sub shown { HardyCross::Phc::ascii(shift) }

#------------------------------------------------------------------------------
# open_db -- the database file as a list of lines.  Each line is
#   { text }                         a comment or blank, kept as it is
#   { text, kind, fields => [..] }   a record
# Returns { path, lines, modified => 0 }.
#------------------------------------------------------------------------------
sub open_db {
    my $path = shift // HardyCross::PipeData::default_path();
    open my $fh, '<:raw', $path or HardyCross::fail('CANNOT OPEN THE DATABASE %s: %s', $path, uc $!);
    my $bytes = do { local $/; <$fh> };
    close $fh;
    my $sha = Digest::SHA::sha256_hex($bytes);
    my $text = $bytes;
    utf8::decode($text);
    my $crlf = $text =~ /\r\n/;
    $text =~ s/\r\n/\n/g;
    my @lines;
    for my $l (split /\n/, $text, -1) {
        if ($l =~ /^\s*(#|$)/) { push @lines, { text => $l }; next }
        my ($kind, @f) = split /\|/, $l, -1;
        push @lines, { text => $l, kind => $kind, fields => \@f };
    }
    pop @lines if @lines && $lines[-1]{text} eq '' && $text =~ /\n\z/;
    return { path => $path, lines => \@lines, modified => 0, crlf => $crlf, trailing_nl => $text =~ /\n\z/,
             sha256 => $sha };
}

# rows -- a table's records: [ { line => index, fields => [...] } ].
sub rows {
    my ($db, $kind) = @_;
    my $l = $db->{lines};
    return [ map { { line => $_, fields => $l->[$_]{fields} } }
             grep { ($l->[$_]{kind} // '') eq $kind } 0 .. $#$l ];
}

#------------------------------------------------------------------------------
# merge -- the fields to store for a row edited in the window: a field whose
# shown form is unchanged keeps its original text (degree sign, case), any
# other takes the new text, trimmed.
#------------------------------------------------------------------------------
sub merge {
    my ($old, $new) = @_;
    return [ map {
        my $n = $new->[$_] // '';
        $n =~ s/^\s+|\s+$//g;
        defined $old->[$_] && shown($old->[$_]) eq $n ? $old->[$_] : $n
    } 0 .. $#$new ];
}

#------------------------------------------------------------------------------
# check_row -- what is wrong with a row of table $kind, or undef.  With $db
# and the row's own line ($line, undef for a new row), checks the row against
# the rest: a pipe size needs its pipe type, and no two rows describe the same
# thing.
#------------------------------------------------------------------------------
sub check_row {
    my ($db, $kind, $f, $line) = @_;
    my $t = $TABLE{$kind} or return "UNKNOWN TABLE $kind";
    my @c = @{ $t->{cols} };
    return sprintf('%s TAKES %d FIELDS, NOT %d', $t->{title}, scalar @c, scalar @$f) if @$f != @c;
    for my $i (0 .. $#c) {
        my ($head, $type) = @{ $c[$i] };
        my $v = $f->[$i] // '';
        return "$head: THE CHARACTER | SEPARATES FIELDS AND CANNOT BE USED" if $v =~ /\|/;
        return "$head IS NEEDED" if $v eq '' && $head ne 'OFFICE USE';
        if ($type eq 'code') {
            return "$head '$v' MUST BE CAPITALS AND DIGITS, WITHOUT SPACES" unless $v =~ /^[A-Z0-9_]+\z/;
        } elsif ($type eq 'int') {
            return "$head '$v' MUST BE A WHOLE NUMBER ABOVE ZERO" unless $v =~ /^\d+\z/ && $v > 0;
        } elsif ($type eq 'num' || $type eq 'num0') {
            next if $type eq 'num0' && $v eq 'DASH';
            return "$head '$v' MUST BE A NUMBER ABOVE ZERO" . ($type eq 'num0' ? ', OR DASH IF NONE IS PUBLISHED' : '')
                unless $v =~ /^(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?\z/ && $v > 0;
        }
    }
    if ($kind eq 'PIPE' && $f->[2] ne 'DASH' && $f->[3] ne 'DASH' && $f->[3] >= $f->[2]) {
        return "BORE MM $f->[3] MUST BE LESS THAN OD MM $f->[2]";
    }
    return undef unless $db;
    # Against the rest of the file.
    my %key = (PIPETYPE => [0], PIPE => [0, 1], FIT => [0, 1, 3], KPRIME => [0]);
    my $k = join '|', @{$f}[ @{ $key{$kind} } ];
    for my $r (@{ rows($db, $kind) }) {
        next if defined $line && $r->{line} == $line;
        return sprintf('THERE IS ALREADY A ROW FOR %s', join(' ', @{$f}[ @{ $key{$kind} } ]))
            if join('|', @{ $r->{fields} }[ @{ $key{$kind} } ]) eq $k;
    }
    if ($kind eq 'PIPE' && !grep { $_->{fields}[0] eq $f->[0] } @{ rows($db, 'PIPETYPE') }) {
        return "PIPE TYPE $f->[0] IS NOT IN PIPE TYPES: ADD IT THERE FIRST";
    }
    return undef;
}

#------------------------------------------------------------------------------
# set_row / add_row / delete_row -- edits.  Each checks first and returns the
# problem, or undef when the edit was made.
#------------------------------------------------------------------------------
sub set_row {
    my ($db, $line, $new) = @_;
    my $l = $db->{lines}[$line] or return 'NO SUCH ROW';
    my $f = merge($l->{fields}, $new);
    my $err = check_row($db, $l->{kind}, $f, $line);
    return $err if $err;
    return undef if join("\x00", @$f) eq join("\x00", @{ $l->{fields} });
    $l->{fields} = $f;
    $l->{text} = join '|', $l->{kind}, @$f;
    $db->{modified} = 1;
    return undef;
}

# add_row -- a new record, placed after the last of its kind (or at the end).
# Returns (problem, line); line is where it went.
sub add_row {
    my ($db, $kind, $new) = @_;
    my $f = merge([], $new);
    my $err = check_row($db, $kind, $f);
    return ($err) if $err;
    my $r = rows($db, $kind);
    my $at = @$r ? $r->[-1]{line} + 1 : scalar @{ $db->{lines} };
    splice @{ $db->{lines} }, $at, 0, { text => join('|', $kind, @$f), kind => $kind, fields => $f };
    $db->{modified} = 1;
    return (undef, $at);
}

sub delete_row {
    my ($db, $line) = @_;
    my $l = $db->{lines}[$line] or return 'NO SUCH ROW';
    return 'NOT A ROW OF A TABLE' unless $TABLE{ $l->{kind} // '' };
    if ($l->{kind} eq 'PIPETYPE') {
        my $code = $l->{fields}[0];
        my $n = grep { $_->{fields}[0] eq $code } @{ rows($db, 'PIPE') };
        return "PIPE TYPE $code STILL HAS $n PIPE SIZES: DELETE THOSE FIRST" if $n;
    }
    splice @{ $db->{lines} }, $line, 1;
    $db->{modified} = 1;
    return undef;
}

#------------------------------------------------------------------------------
# check_all -- every row checked: [ { kind, line, message } ].  The window
# runs this before saving; nothing is saved while it finds anything.
#------------------------------------------------------------------------------
sub check_all {
    my $db = shift;
    my @p;
    for my $t (@TABLES) {
        for my $r (@{ rows($db, $t->[0]) }) {
            my $err = check_row($db, $t->[0], $r->{fields}, $r->{line});
            push @p, { kind => $t->[0], line => $r->{line}, message => $err } if $err;
        }
    }
    return \@p;
}

#------------------------------------------------------------------------------
# use_folder -- point this machine at a folder for the database (a team's
# shared folder).  If the folder has no pipes.dat yet and $copy is true, the
# database in use is copied there first, so a team can start its shared
# database from this one.  Returns undef, or the problem.
#
# use_builtin -- go back to the program's own database.
#
# Either way the database is loaded again from its new place, and the pick
# lists that remember the old one are cleared.
#------------------------------------------------------------------------------
sub use_folder {
    my ($dir, $copy) = @_;
    return "THE FOLDER $dir DOES NOT EXIST OR CANNOT BE REACHED" unless -d $dir;
    my $target = File::Spec->catfile($dir, 'pipes.dat');
    unless (-e $target) {
        return "THE FOLDER $dir HAS NO PIPES.DAT" unless $copy;
        my $from = HardyCross::PipeData::path() || HardyCross::PipeData::default_path();
        open my $in, '<:raw', $from or return "CANNOT READ $from";
        my $b = do { local $/; <$in> };
        close $in;
        open my $out, '>:raw', $target or return "CANNOT WRITE $target: " . uc $!;
        print $out $b;
        close $out;
    }
    my $ok = eval { HardyCross::PipeData::load($target); 1 };
    unless ($ok) {
        my $e = $@;
        HardyCross::PipeData::load();
        return 'THE DATABASE IN THAT FOLDER CANNOT BE USED: ' . uc(ref $e ? $e->{msg} : "$e");
    }
    HardyCross::Settings::set(DATABASE_DIR => $dir);
    HardyCross::Phc::reset_db_cache();
    return undef;
}

sub use_builtin {
    HardyCross::Settings::set(DATABASE_DIR => undef);
    HardyCross::PipeData::load(HardyCross::PipeData::default_path());
    HardyCross::Phc::reset_db_cache();
    return undef;
}

# today -- the date as the DATASET line writes it: 28 October 2026.
sub today {
    my @t = localtime(shift // time);
    my @m = qw(January February March April May June July August September October November December);
    return sprintf '%d %s %d', $t[3], $m[ $t[4] ], $t[5] + 1900;
}

#------------------------------------------------------------------------------
# text -- the file's text.  When the database has been changed the DATASET
# line takes today's date, so a report printed after the change says so.
#------------------------------------------------------------------------------
sub text {
    my ($db, $date) = @_;
    if ($db->{modified}) {
        for my $l (@{ $db->{lines} }) {
            next unless ($l->{kind} // '') eq 'DATASET';
            $l->{fields}[1] = $date // today();
            $l->{text} = join '|', 'DATASET', @{ $l->{fields} };
        }
    }
    my $nl = $db->{crlf} ? "\r\n" : "\n";
    my $t = join $nl, map { $_->{text} } @{ $db->{lines} };
    $t .= $nl if $db->{trailing_nl};
    utf8::encode($t);
    return $t;
}

#------------------------------------------------------------------------------
# save -- check everything, write the file, and make it the database in use.
#
# The new text is written to a temporary file beside the target and read by
# HardyCross::PipeData::load first; only when that succeeds does it replace
# the target.  Then the database is loaded from its new place, and the pick
# lists and line checks that remember it are cleared.
#
# Returns { ok, path, sha256, problems => [...] }.
#------------------------------------------------------------------------------
# save_path -- where an edited database is written.
sub save_path {
    my $db = shift;
    return HardyCross::PipeData::user_path()
        if $ENV{PAR_TEMP} && index(File::Spec->rel2abs($db->{path}), $ENV{PAR_TEMP}) == 0;
    return $db->{path};
}

# changed_on_disk -- true when the file has been saved by someone else since
# it was opened here.
sub changed_on_disk {
    my $db = shift;
    open my $fh, '<:raw', $db->{path} or return 0;
    my $bytes = do { local $/; <$fh> };
    close $fh;
    return Digest::SHA::sha256_hex($bytes) ne $db->{sha256};
}

sub save {
    my ($db, $path, $date) = @_;
    $path //= save_path($db);
    my $p = check_all($db);
    return { ok => 0, problems => $p } if @$p;
    if ($path eq $db->{path} && changed_on_disk($db)) {
        return { ok => 0, problems => [ { message => 'THE DATABASE WAS SAVED BY SOMEONE ELSE AFTER YOU OPENED IT. '
            . 'NOTHING WAS SAVED: RELOAD IT, AND MAKE YOUR CHANGE AGAIN.' } ] };
    }
    my $bytes = text($db, $date);
    make_path(dirname($path)) unless -d dirname($path);
    my $tmp = "$path.new";
    open my $fh, '>:raw', $tmp or HardyCross::fail('CANNOT WRITE %s: %s', $tmp, uc $!);
    print $fh $bytes;
    close $fh;
    my $ok = eval { HardyCross::PipeData::load($tmp); 1 };
    unless ($ok) {
        my $e = $@;
        unlink $tmp;
        HardyCross::PipeData::load($db->{path}) if -r $db->{path};
        return { ok => 0, problems => [ { message => uc(ref $e ? $e->{msg} : "$e") } ] };
    }
    rename $tmp, $path or HardyCross::fail('CANNOT REPLACE %s: %s', $path, uc $!);
    HardyCross::PipeData::load($path);
    HardyCross::Phc::reset_db_cache();
    $db->{path} = $path;
    $db->{modified} = 0;
    $db->{sha256} = HardyCross::PipeData::sha256();
    return { ok => 1, path => $path, sha256 => HardyCross::PipeData::sha256() };
}

1;
