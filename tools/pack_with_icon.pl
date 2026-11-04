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
#   its loader (parl.exe) with the program's archive appended; a windowed
#   program (pp --gui) is the same loader with its subsystem set to windows.  Rewriting the finished .exe's resources would
#   move or drop that appended archive, so the icon is set where pp itself
#   used to set it: on a copy of the LOADER, before the archive is added.
#
#     1. pp -p   packs the script and its modules into a .par archive
#     2. a copy of parl.exe has its icon replaced, and for a windowed
#        program its subsystem set to windows.  The icon is written by
#        Windows itself (BeginUpdateResource, UpdateResource,
#        EndUpdateResource, called through Win32::API): the loader's own
#        icon group and pictures are deleted, and the .ico file's pictures
#        and a group listing them added.  The subsystem is one number in the
#        PE header, set directly.  parl.exe is itself a packed program: its
#        own core modules (XSLoader and the rest) are appended after the end
#        of its PE image, and Windows rewrites the image alone.  So those
#        appended bytes are taken from the original before the change and
#        put back after it.
#     3. that copy writes the .exe:  loader -B -O<out.exe> <archive.par>
#        (-B bundles the core modules, as pp does by default)
#     4. the finished .exe is read back by tools/check_exe_icon.pl, which
#        compares its icon with the .ico file byte for byte.
#
# Up to v1.0.0 step 2 used Win32::Exe.  Its resource writer (0.17) builds the
# new pictures in memory but writes a resource table that still points at the
# loader's four stock pictures, so the programs showed the packager's icon
# while this script said the icon had been set.  Step 4 is there so that
# cannot happen silently again.
#
# Exits 0 with the .exe written and checked, or non-zero with the reason; the
# build script then falls back to a plain pp build, without the icon, so an
# icon never costs a working program.
#==============================================================================
use strict;
use warnings;
use Config;
use File::Copy qw(copy);
use File::Spec;
use FindBin;

my ($icon, $mode, $out, @pp) = @ARGV;
die "usage: pack_with_icon.pl icon.ico console|gui out.exe pp-options... script\n"
    unless $icon && $mode && $out && @pp;
die "pack_with_icon: $icon not found\n" unless -f $icon;
die "pack_with_icon: Win32::API is not installed\n" unless eval { require Win32::API; 1 };

# The loader, parl.exe, found beside the perl that runs this, or on the PATH.
my $name = 'parl.exe';
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

# 2. the loader, with the icon and the subsystem, and its appended modules
# put back.
my $orig = slurp($loader);
my $overlay = substr($orig, pe_end($orig));
copy($loader, $tmp) or die "pack_with_icon: cannot copy $loader: $!\n";
set_icon($tmp, $icon, $orig);
my $new = slurp($tmp);
$new = substr($new, 0, pe_end($new)) . $overlay;
# The subsystem: 2 runs in a window with no console, 3 opens a console.  It
# is a 16-bit field 68 bytes into the optional header, in both the 32-bit
# and 64-bit layouts.
my $pe = unpack 'V', substr($new, 0x3C, 4);
substr($new, $pe + 24 + 68, 2) = pack 'v', ($mode eq 'gui' ? 2 : 3);
open my $wf, '>:raw', $tmp or die "pack_with_icon: cannot write $tmp: $!\n";
print $wf $new;
close $wf;
printf "pack_with_icon: loader image %d bytes, its appended modules %d bytes kept\n",
    pe_end($new), length $overlay;

# 3. the program: the loader with the archive.  Its own output is shown if it
# fails; and an untouched copy of the loader is tried, so the log says
# whether the packing or the icon was at fault.
my $run = sub {
    # By its full path: a command shell set not to run programs from the
    # current folder (NoDefaultCurrentDirectoryInExePath) would not find it.
    my $l = File::Spec->rel2abs(shift);
    unlink $out;
    my $said = qx{"$l" -B "-O$out" "$par" 2>&1};
    return ($? == 0 && -s $out, $said);
};
my ($ok, $said) = $run->($tmp);
unless ($ok) {
    print "pack_with_icon: the loader with the icon did not write $out:\n$said\n";
    my $plain = "$stem.plain-loader.exe";
    copy($loader, $plain);
    my ($pok, $psaid) = $run->($plain);
    unlink $plain, $out;
    die $pok ? "pack_with_icon: an untouched loader writes it - so setting the icon spoils the loader\n"
             : "pack_with_icon: an untouched loader does not write it either:\n$psaid\n";
}
unlink $par, $tmp;

# 4. read the icon back out of the finished program.
system($^X, File::Spec->catfile($FindBin::Bin, 'check_exe_icon.pl'), $out, $icon) == 0
    or die "pack_with_icon: $out was written, but without the icon $icon\n";
print "pack_with_icon: $out written with the icon $icon\n";
exit 0;

sub slurp {
    my $f = shift;
    open my $fh, '<:raw', $f or die "pack_with_icon: cannot read $f: $!\n";
    local $/;
    return scalar <$fh>;
}

# utf16 -- a string as Windows' wide functions take it: UTF-16, ending in 0.
sub utf16 { return pack 'v*', unpack('U*', shift), 0 }

# set_icon -- replace a program's icon with the pictures in an .ico file.
#   $exe   the program, changed in place
#   $ico   the .ico file
#   $orig  the program's bytes, to find the icon resources it has now
# Windows' own resource update functions do the writing.  They take the type
# and name of a resource as either a number below 65536 or the address of a
# UTF-16 string, so both are passed as integers here.
sub set_icon {
    my ($exe, $ico, $orig) = @_;
    my ($RT_ICON, $RT_GROUP_ICON, $ENGLISH) = (3, 14, 1033);
    my $begin = Win32::API->new('kernel32', 'BeginUpdateResourceW', 'PN', 'N')
        or die "pack_with_icon: BeginUpdateResourceW: $^E\n";
    my $update = Win32::API->new('kernel32', 'UpdateResourceW', 'NNNNPN', 'N')
        or die "pack_with_icon: UpdateResourceW: $^E\n";
    # The same function to remove a resource: its data pointer must be NULL,
    # which a 'P' argument never is, so here it is a plain number, 0.
    my $remove = Win32::API->new('kernel32', 'UpdateResourceW', 'NNNNNN', 'N')
        or die "pack_with_icon: UpdateResourceW: $^E\n";
    my $end = Win32::API->new('kernel32', 'EndUpdateResourceW', 'NN', 'N')
        or die "pack_with_icon: EndUpdateResourceW: $^E\n";

    # The .ico: reserved 0, type 1, count; then 16 bytes per picture --
    # width, height, colours, reserved, planes, bits, bytes, offset.
    my $b = slurp($ico);
    my ($zero, $type, $n) = unpack 'vvv', $b;
    die "pack_with_icon: $ico is not an icon file\n" unless $zero == 0 && $type == 1 && $n;
    my @pic = map { [ unpack 'CCCCvvVV', substr($b, 6 + 16 * $_, 16) ] } 0 .. $n - 1;

    # A resource name: a number as itself, a name as the address of its
    # UTF-16 text.  The texts are kept in @names until the update is done,
    # so the addresses stay good.
    my @names;
    my $id = sub {
        my $v = shift;
        return $v if $v =~ /^\d+\z/;
        push @names, utf16($v);
        return unpack 'Q', pack 'P', $names[-1];
    };

    my $h = $begin->Call(utf16(File::Spec->rel2abs($exe)), 0)
        or die "pack_with_icon: BeginUpdateResource($exe) failed: $^E\n";
    # Out with the loader's icon group(s) and pictures, in each language they
    # were written in (a resource is removed by updating it with no data) ...
    for my $r (grep { $_->[0] eq $RT_ICON || $_->[0] eq $RT_GROUP_ICON } resources($orig)) {
        $remove->Call($h, $r->[0], $id->($r->[1]), $r->[2], 0, 0)
            or die "pack_with_icon: cannot remove the old icon resource $r->[0]/$r->[1]: $^E\n";
    }
    # ... in with each picture as RT_ICON 1, 2, 3 ..., and RT_GROUP_ICON 1,
    # which lists them: 14 bytes per picture, the .ico entry with its file
    # offset replaced by the picture's number.  US English, as the loader's
    # other resources are.
    my $group = pack 'vvv', 0, 1, $n;
    for my $i (0 .. $n - 1) {
        my ($w, $ht, $col, $res, $planes, $bits, $len, $off) = @{ $pic[$i] };
        $update->Call($h, $RT_ICON, $i + 1, $ENGLISH, substr($b, $off, $len), $len)
            or die "pack_with_icon: cannot add picture " . ($i + 1) . ": $^E\n";
        $group .= pack 'CCCCvvVv', $w, $ht, $col, $res, $planes, $bits, $len, $i + 1;
    }
    $update->Call($h, $RT_GROUP_ICON, 1, $ENGLISH, $group, length $group)
        or die "pack_with_icon: cannot add the icon group: $^E\n";
    $end->Call($h, 0) or die "pack_with_icon: EndUpdateResource($exe) failed: $^E\n";
    printf "pack_with_icon: %d pictures from %s set on the loader\n", $n, $ico;
}

# resources -- [type, name, language] for every resource in a program, with
# a numbered type or name given as its number and a named one as its name.
sub resources {
    my $b = shift;
    my $pe = unpack 'V', substr($b, 0x3C, 4);
    my ($nsec, $optsz) = (unpack('v', substr($b, $pe + 6, 2)), unpack('v', substr($b, $pe + 20, 2)));
    # The resource table is the third data directory, after the optional
    # header's fixed part: 96 bytes for a 32-bit program, 112 for 64-bit.
    my $magic = unpack 'v', substr($b, $pe + 24, 2);
    my ($rva) = unpack 'V', substr($b, $pe + 24 + ($magic == 0x20b ? 112 : 96) + 16, 4);
    return () unless $rva;
    my $root;
    for my $i (0 .. $nsec - 1) {
        my ($vsize, $va, $rsize, $ptr) = unpack 'VVVV', substr($b, $pe + 24 + $optsz + 40 * $i + 8, 16);
        $root = $ptr + $rva - $va if $rva >= $va && $rva < $va + ($vsize > $rsize ? $vsize : $rsize);
    }
    die "pack_with_icon: the resource table is in no section\n" unless defined $root;
    # One level of the tree: [number or name, offset of what it holds].  The
    # high bit of an id marks a name; of an offset, a further level.
    my $level = sub {
        my $d = shift;
        my ($named, $ids) = unpack 'vv', substr($b, $root + $d + 12, 4);
        return map {
            my ($key, $off) = unpack 'VV', substr($b, $root + $d + 16 + 8 * $_, 8);
            if ($key & 0x80000000) {
                my $p = $root + ($key & 0x7fffffff);
                my $len = unpack 'v', substr($b, $p, 2);
                $key = join '', map { chr } unpack 'v*', substr($b, $p + 2, 2 * $len);
            }
            [ $key, $off & 0x7fffffff ];
        } 0 .. $named + $ids - 1;
    };
    my @all;
    for my $t ($level->(0)) {
        for my $n ($level->($t->[1])) {
            push @all, [ $t->[0], $n->[0], $_->[0] ] for $level->($n->[1]);
        }
    }
    return @all;
}

# pe_end -- where a Windows program's PE image ends in its file: the end of
# its furthest section.  Anything after it is appended data (an overlay).
sub pe_end {
    my $b = shift;
    die "pack_with_icon: not a Windows program\n" unless substr($b, 0, 2) eq 'MZ';
    my $pe = unpack 'V', substr($b, 0x3C, 4);
    die "pack_with_icon: no PE header\n" unless substr($b, $pe, 4) eq "PE\0\0";
    my ($nsec, $optsz) = (unpack('v', substr($b, $pe + 6, 2)), unpack('v', substr($b, $pe + 20, 2)));
    my $tab = $pe + 24 + $optsz;
    my $end = 0;
    for my $i (0 .. $nsec - 1) {
        my ($size, $ptr) = unpack 'VV', substr($b, $tab + 40 * $i + 16, 8);
        $end = $ptr + $size if $ptr + $size > $end;
    }
    return $end;
}
