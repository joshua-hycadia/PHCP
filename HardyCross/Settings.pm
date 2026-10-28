#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
# Settings.pm -- the few settings that belong to a machine, not to a model.
#
# One so far: DATABASE_DIR, a folder holding the pipe and fitting database
# (pipes.dat).  A team points every machine at one folder on a network drive
# and they all calculate with the same data; the report prints the path and
# the SHA-256 of the file read, so each calculation still says exactly which
# data it used.  Unset, the program uses its own database.
#
# The settings live in a small KEY=VALUE text file:
#   Windows    %APPDATA%\PHCP\settings.ini
#   elsewhere  ~/.config/phcp/settings.ini
# PHCP_SETTINGS names another file (the tests use this, so they never read or
# write a user's real settings).  The environment variable PHCP_DATABASE_DIR,
# if set, wins over the file -- for a script, or an office that sets it by
# policy.

package HardyCross::Settings;

use strict;
use warnings;
use File::Spec;
use File::Basename qw(dirname);
use File::Path qw(make_path);

# file -- where the settings are kept.
sub file {
    return $ENV{PHCP_SETTINGS} if $ENV{PHCP_SETTINGS};
    if ($^O eq 'MSWin32') {
        my $base = $ENV{APPDATA} // $ENV{USERPROFILE} // '.';
        return File::Spec->catfile($base, 'PHCP', 'settings.ini');
    }
    return File::Spec->catfile($ENV{HOME} // '.', '.config', 'phcp', 'settings.ini');
}

# all -- every setting in the file, as a hash.  A missing file is no settings.
sub all {
    my %s;
    open my $fh, '<', file() or return \%s;
    while (my $l = <$fh>) {
        $l =~ s/\r?\n\z//;
        next if $l =~ /^\s*(#|;|$)/;
        $s{ uc $1 } = $2 if $l =~ /^\s*([A-Za-z_]+)\s*=\s*(.*?)\s*\z/;
    }
    close $fh;
    return \%s;
}

sub get { return all()->{ uc shift } }

#------------------------------------------------------------------------------
# set -- write one setting; an empty or undefined value removes it.  The
# other lines of the file, comments included, are kept.
#------------------------------------------------------------------------------
sub set {
    my ($key, $value) = @_;
    $key = uc $key;
    my $f = file();
    my @lines;
    if (open my $fh, '<', $f) { @lines = <$fh>; close $fh }
    s/\r?\n\z// for @lines;
    @lines = grep { !/^\s*\Q$key\E\s*=/i } @lines;
    unshift @lines, '# PHCP settings - see HardyCross/Settings.pm' unless @lines;
    push @lines, "$key=$value" if defined $value && length $value;
    make_path(dirname($f)) unless -d dirname($f);
    open my $out, '>', $f or die "cannot write the settings file $f: $!\n";
    print $out map { "$_\n" } @lines;
    close $out;
    return 1;
}

# database_dir -- the folder chosen for the database, or undef for the
# program's own.
sub database_dir {
    my $d = $ENV{PHCP_DATABASE_DIR} // get('DATABASE_DIR');
    return defined $d && length $d ? $d : undef;
}

1;
