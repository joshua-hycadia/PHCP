#!/usr/bin/perl
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# pack_with_icon.pl -- package a program as a Windows .exe that carries an icon.
#
#   perl tools\pack_with_icon.pl <icon.ico> <console|gui> <out.exe> <pp options and script ...>
#
# WHY THIS EXISTS
#   PAR::Packer's pp once had --icon; it was removed.  An .exe made by pp is
#   its loader (parl.exe, or parlw.exe for a windowed program) with the
#   program's archive appended.  Rewriting the finished .exe's resources would
#   move or drop that appended archive, so the icon is set where pp itself
#   used to set it: on a copy of the LOADER, before the archive is added.
#
#     1. pp -p   packs the script and its modules into a .par archive
#     2. a copy of parl.exe (parlw.exe) has its icon replaced (Win32::Exe)
#     3. that copy writes the .exe:  loader -B -O<out.exe> <archive.par>
#        (-B bundles the core modules, as pp does by default)
#
# Exits 0 with the .exe written, or non-zero with the reason; the build
# script then falls back to a plain pp build, without the icon, so an icon
# never costs a working program.
#==============================================================================
use strict;
use warnings;
use Config;
use File::Copy qw(copy);
use File::Spec;

my ($icon, $mode, $out, @pp) = @ARGV;
die "usage: pack_with_icon.pl icon.ico console|gui out.exe pp-options... script\n"
    unless $icon && $mode && $out && @pp;
die "pack_with_icon: $icon not found\n" unless -f $icon;
die "pack_with_icon: Win32::Exe is not installed\n" unless eval { require Win32::Exe; 1 };

# The loader: parl.exe for a console program, parlw.exe for a windowed one,
# found beside the perl that runs this, or on the PATH.
my $name = $mode eq 'gui' ? 'parlw.exe' : 'parl.exe';
my ($loader) = grep { -f } map { File::Spec->catfile($_, $name) }
    grep { defined && length } $Config{sitebin}, $Config{bin}, $Config{scriptdir},
    split /;/, $ENV{PATH} // '';
die "pack_with_icon: $name not found\n" unless $loader;

(my $stem = $out) =~ s/\.exe\z//i;
my ($par, $tmp) = ("$stem.icon.par", "$stem.icon-loader.exe");
unlink $par, $tmp, $out;

# 1. the archive.  --gui is a property of the loader, not of the archive.
# pp is a .bat file on Windows, which only the command shell can run, so it
# is called by a command line with each argument quoted.
my @opts = grep { $_ ne '--gui' } @pp;
my $cmd = join ' ', map { /[\s;"]/ ? '"' . s/"/\\"/gr . '"' : $_ } 'pp', '-p', '-o', $par, @opts;
system($cmd) == 0 && -s $par
    or die "pack_with_icon: pp -p failed\n";

# 2. the loader, with the icon.
copy($loader, $tmp) or die "pack_with_icon: cannot copy $loader: $!\n";
my $exe = Win32::Exe->new($tmp) or die "pack_with_icon: Win32::Exe cannot read $tmp\n";
$exe->update(icon => $icon);
$exe->write($tmp);

# 3. the program: the loader with the archive.
system($tmp, '-B', "-O$out", $par) == 0 && -s $out
    or die "pack_with_icon: the loader did not write $out\n";
unlink $par, $tmp;
print "pack_with_icon: $out written with the icon $icon\n";
exit 0;
