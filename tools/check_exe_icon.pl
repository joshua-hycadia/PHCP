#!/usr/bin/perl
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# check_exe_icon.pl -- does a built .exe carry the PHCP icon?
#
#   perl tools/check_exe_icon.pl <program.exe> [icon.ico]     (icon: data/phcp.ico)
#
# WHY THIS EXISTS
#   The v1.0.0 build log said the icon had been set, yet both programs showed
#   the packager's stock icon in Explorer: the tool that wrote the icon had
#   written a resource table that still pointed at the old pictures.  So the
#   finished .exe itself is read here, the way Explorer reads it, and its
#   icon compared byte for byte with the .ico file.
#
#   Explorer shows a program's FIRST icon group: named groups sort before
#   numbered ones, names alphabetically, numbers in order.  That group lists
#   its pictures by number; each picture is an RT_ICON resource holding the
#   same bytes as the matching image in a .ico file.  So the check is:
#     - the first group lists as many pictures as the .ico holds, of the same
#       sizes, in the same order
#     - each picture's bytes are the .ico image's bytes
#
#   Pure Perl, so it runs anywhere, on any .exe, without Windows.  Exits 0 if
#   the icon matches, 1 with the reason if not.  pack_with_icon.pl runs it on
#   every .exe it writes, and CI runs it on the built programs.
#==============================================================================
use strict;
use warnings;

my ($exe, $ico) = @ARGV;
$ico //= 'data/phcp.ico';
die "usage: check_exe_icon.pl program.exe [icon.ico]\n" unless $exe;

my @want = ico_images(slurp($ico));
my ($group, @got) = exe_icon(slurp($exe));

my @bad;
push @bad, sprintf('%d pictures in the first icon group (%s), %d in %s',
                   scalar @got, $group, scalar @want, $ico) if @got != @want;
for my $i (0 .. ($#got < $#want ? $#got : $#want)) {
    my ($g, $w) = ($got[$i], $want[$i]);
    push @bad, sprintf('picture %d is %s, %d bytes; %s has %s, %d bytes', $i + 1,
                       size($g), length $g->{data}, $ico, size($w), length $w->{data})
        if $g->{data} ne $w->{data};
}
if (@bad) {
    print "check_exe_icon: $exe does NOT carry $ico\n";
    print "  $_\n" for @bad;
    exit 1;
}
printf "check_exe_icon: %s carries %s - icon group %s, %d pictures (%s), bytes identical\n",
    $exe, $ico, $group, scalar @got, join(' ', map { size($_) } @got);
exit 0;

# size -- "32x32" for a picture; a width or height of 0 in the tables means 256.
sub size { my $p = shift; return ($p->{w} || 256) . 'x' . ($p->{h} || 256) }

sub slurp {
    my $f = shift;
    open my $fh, '<:raw', $f or die "check_exe_icon: cannot read $f: $!\n";
    local $/;
    return scalar <$fh>;
}

# ico_images -- the pictures in a .ico file, in file order.
#   header: reserved 0, type 1, count; then 16 bytes per picture:
#   width, height, colours, reserved, planes, bits, bytes, offset.
sub ico_images {
    my $bin = shift;
    my ($zero, $type, $n) = unpack 'vvv', $bin;
    die "check_exe_icon: $ico is not an icon file\n" unless $zero == 0 && $type == 1 && $n;
    return map {
        my ($w, $h, undef, undef, undef, undef, $len, $off) = unpack 'CCCCvvVV', substr($bin, 6 + 16 * $_, 16);
        { w => $w, h => $h, data => substr($bin, $off, $len) };
    } 0 .. $n - 1;
}

# exe_icon -- the name of a program's first icon group, then its pictures.
sub exe_icon {
    my $bin = shift;
    die "check_exe_icon: $exe is not a Windows program\n" unless substr($bin, 0, 2) eq 'MZ';
    my $pe = unpack 'V', substr($bin, 0x3C, 4);
    die "check_exe_icon: $exe has no PE header\n" unless substr($bin, $pe, 4) eq "PE\0\0";
    my ($nsec, $optsz) = (unpack('v', substr($bin, $pe + 6, 2)), unpack('v', substr($bin, $pe + 20, 2)));
    # The data directories follow the optional header's fixed part, which is
    # 96 bytes for a 32-bit program and 112 for a 64-bit one; the resource
    # table is the third directory.
    my $magic = unpack 'v', substr($bin, $pe + 24, 2);
    my $dirs = $pe + 24 + ($magic == 0x20b ? 112 : 96);
    my ($rva) = unpack 'V', substr($bin, $dirs + 2 * 8, 4);
    die "check_exe_icon: $exe has no resources\n" unless $rva;

    # Section table: to turn an address in memory (RVA) into a file offset.
    my @sec = map {
        my ($vsize, $va, $rsize, $ptr) = unpack 'VVVV', substr($bin, $pe + 24 + $optsz + 40 * $_ + 8, 16);
        [ $va, ($vsize > $rsize ? $vsize : $rsize), $ptr ];
    } 0 .. $nsec - 1;
    my $at = sub {
        my $r = shift;
        for (@sec) { return $_->[2] + $r - $_->[0] if $r >= $_->[0] && $r < $_->[0] + $_->[1] }
        die "check_exe_icon: address $r is in no section\n";
    };
    my $root = $at->($rva);

    # One level of the resource tree: [key, sort key, offset] per entry,
    # sorted as Windows looks them up.  Offsets are from the tree's root; the
    # high bit marks a name (instead of a number) or a sub-directory.
    my $level = sub {
        my $d = shift;
        my ($named, $ids) = unpack 'vv', substr($bin, $root + $d + 12, 4);
        my @e;
        for my $i (0 .. $named + $ids - 1) {
            my ($id, $off) = unpack 'VV', substr($bin, $root + $d + 16 + 8 * $i, 8);
            if ($id & 0x80000000) {
                my $p = $root + ($id & 0x7fffffff);
                my $len = unpack 'v', substr($bin, $p, 2);
                my $name = join '', map { chr } unpack 'v*', substr($bin, $p + 2, 2 * $len);
                push @e, [ $name, "0$name", $off ];
            } else {
                push @e, [ "#$id", sprintf('1%010d', $id), $off ];
            }
        }
        return sort { $a->[1] cmp $b->[1] } @e;
    };
    # The bytes of the first language of a named resource.
    my $data = sub {
        my $off = shift;
        ($off) = map { $_->[2] } $level->($off & 0x7fffffff) if $off & 0x80000000;
        my ($drva, $len) = unpack 'VV', substr($bin, $root + $off, 8);
        return substr($bin, $at->($drva), $len);
    };
    my %type = map { $_->[0] => $_->[2] } $level->(0);
    die "check_exe_icon: $exe has no icon group\n" unless $type{'#14'} && $type{'#3'};
    my ($first) = $level->($type{'#14'} & 0x7fffffff);
    my %pic = map { $_->[0] => $_->[2] } $level->($type{'#3'} & 0x7fffffff);

    # The group: reserved, type, count; then 14 bytes per picture:
    # width, height, colours, reserved, planes, bits, bytes, picture number.
    my $g = $data->($first->[2]);
    my $n = unpack 'v', substr($g, 4, 2);
    my @p = map {
        my ($w, $h, undef, undef, undef, undef, undef, $id) = unpack 'CCCCvvVv', substr($g, 6 + 14 * $_, 14);
        die "check_exe_icon: picture #$id of the icon group is missing\n" unless $pic{"#$id"};
        { w => $w, h => $h, data => $data->($pic{"#$id"}) };
    } 0 .. $n - 1;
    return ($first->[0], @p);
}
