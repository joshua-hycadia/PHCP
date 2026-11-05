#!/usr/bin/perl
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# test_isometric_window.pl -- the isometric window, driven under a display.
#
#   perl tools/test_isometric_window.pl
#
# The text editor is a different program.  This checks that phcp_editor.pl
# was not given an isometric tab, and that phcp_isometric.pl draws a network,
# keeps a pipe's properties on the right, locks the axes, chooses labels and
# can go dark.  A pipe is two clicks, or a length, size, fittings and C typed
# first so the click only chooses the direction.
#==============================================================================
use strict;
use warnings;
no warnings 'once';
use FindBin;
use lib "$FindBin::Bin/..";
use File::Temp qw(tempdir);

unless ($ENV{DISPLAY}) {
    if (!$ENV{PHCP_UNDER_XVFB} && system('which xvfb-run >/dev/null 2>&1') == 0) {
        $ENV{PHCP_UNDER_XVFB} = 1;
        exec 'xvfb-run', '-a', '-s', '-screen 0 1600x1000x24', $^X, $0, @ARGV;
    }
    print "SKIPPED: no X display and no xvfb-run - the isometric window was not run\n";
    exit 0;
}
unless (eval { require Tk; 1 }) {
    print "SKIPPED: Tk is not installed - the isometric window was not run\n";
    exit 0;
}

chdir "$FindBin::Bin/..";
my $SETTINGS_DIR = tempdir(CLEANUP => 1);
$ENV{PHCP_SETTINGS} = "$SETTINGS_DIR/settings.ini";
delete $ENV{PHCP_DATABASE_DIR};
$main::PHCP_EDITOR_LOAD_ONLY = 1;
$main::PHCP_ISO_LOAD_ONLY = 1;
require "./phcp_isometric.pl";

my ($pass, $fail) = (0, 0);
sub is {
    my ($name, $ok, $why) = @_;
    printf "  %-68s %s\n", $name, $ok ? 'ok' : '*** FAIL';
    print "      $why\n" if !$ok && defined $why;
    $ok ? $pass++ : $fail++;
}
sub slurp { my $p = shift; open my $f, '<', $p or die "$p: $!\n"; local $/; <$f> }

print "1. A FORK, NOT A CHANGE TO THE TEXT EDITOR\n";
{
    my $src = slurp('phcp_editor.pl');
    is('phcp_editor.pl has no isometric tab', $src !~ /ISOMETRIC/ && $src !~ /iso_show/ && $src !~ /build_isometric/);
}

print "2. THE DRAWING WINDOW\n";
main::build_window();
$main::mw->update;
is('the window is the isometric program', $main::mw->title eq 'PHCP ISOMETRIC - UNTITLED.PHC', $main::mw->title);
is('DARK MODE sits left of the status, the same place as the other windows',
   $main::btn{THEME} && $main::pill && $main::btn{VALIDATE}
   && $main::btn{THEME}->cget('-text') eq 'DARK MODE'
   && $main::btn{THEME}->rootx + $main::btn{THEME}->width <= $main::pill->rootx + 8
   && abs($main::btn{THEME}->rooty - $main::btn{VALIDATE}->rooty) < 8
   && !$main::iso{btn}{DARK},
   ($main::btn{THEME} ? $main::btn{THEME}->cget('-text') . ' ' : '')
   . join(' ', map { $_->rootx . ',' . $_->rooty } grep { $_ } $main::btn{VALIDATE}, $main::btn{THEME}, $main::pill));
{
    my $face = lc $main::mw->fontActual($main::btn{NEW}->cget('-font'), '-family');
    my $weight = $main::mw->fontActual($main::btn{NEW}->cget('-font'), '-weight');
    is('buttons are the editor chrome face, 10 point bold',
       $main::UI_B && $main::UI_B->[1] == 10 && $main::UI_B->[2] eq 'bold'
       && $face eq lc $main::UI_B->[0] && $weight eq 'bold',
       "$face $weight spec @$main::UI_B");
    is('the toolbar is the shared grey, and the ink is the shared ink',
       lc $main::btn{NEW}->parent->cget('-background') eq '#f4f6f9'
       && lc $main::btn{NEW}->cget('-foreground') eq '#1c1f24',
       $main::btn{NEW}->parent->cget('-background') . ' ' . $main::btn{NEW}->cget('-foreground'));
}
is('there is no NETWORK tab',
   join(' ', @{ $main::toptabs->{names} }) eq 'ISOMETRIC PROJECT GRAPH QUICK TOOLS DATABASE'
   && $main::toptabs->{current} eq 'ISOMETRIC',
   join(' ', @{ $main::toptabs->{names} }));
is('the grid is drawn, and the view starts locked',
   $main::iso_cv->find('withtag', 'grid') > 0 && $main::iso{lock} && $main::iso{view}{lock});

main::iso_set_tool('WATER');
main::iso_click_cell(0, 0);
main::iso_set_tool('SPRINKLER');
main::iso_click_cell(4, 0);
main::iso_set_tool('PIPE');
main::iso_click_cell(0, 0);
main::iso_click_cell(4, 0);
my $b = main::buffer();
is('a supply, a sprinkler and a pipe are written as commands',
   $b =~ /^WATER\s+W1\b/m && $b =~ /^SPRINKLER\s+S1\b/m && $b =~ /^PIPE\s+P1\s+W1\s+S1\s/m, $b);

main::iso_set_tool('SELECT');
$main::iso{sel} = { kind => 'pipe', name => 'P1' };
main::iso_props();
$main::mw->update;
is('the properties pane sits to the right of the drawing',
   $main::iso{props}->rootx > $main::iso_cv->rootx + 40, $main::iso{props}->rootx . ' vs ' . $main::iso_cv->rootx);
is('a selected pipe offers length, fittings and C',
   exists $main::iso{field}{LENGTH} && exists $main::iso{field}{FITTINGS} && exists $main::iso{field}{C},
   join(' ', sort keys %{ $main::iso{field} }));
main::iso_set_field('FITTINGS', '2E 1T');
main::iso_set_field('C', '110');
$b = main::buffer();
is('fittings and C are written back', $b =~ /^PIPE\s+P1\s+W1\s+S1\s+\S+\s+\S+\s+2E\s+1T/m && $b =~ /^USE\s+BORE\s+110/m, $b);

main::iso_set_label('LENGTH', 1);
my @captions = map { $main::iso_cv->itemcget($_, '-text') } $main::iso_cv->find('withtag', 'label');
is('a label can be switched on: the length is drawn', scalar grep({ /\b\d/ } @captions), "@captions");
main::iso_set_label('POINTS', 0);
main::iso_set_label('PIPES', 0);
main::iso_set_label('LENGTH', 0);
main::iso_set_label('DEVICES', 0);
@captions = map { $main::iso_cv->itemcget($_, '-text') } $main::iso_cv->find('withtag', 'label');
is('labels can be switched off', !grep({ /\S/ } @captions), "@captions");

my $paper = lc $main::iso_cv->cget(-background);
main::iso_apply_theme('DARK');
$main::mw->update;
my $dark = lc $main::iso_cv->cget(-background);
my $cell = lc $main::vtable->{styles}{muted}->cget(-background);
my $head = lc $main::vtable->{hlist}->header('cget', 0, '-headerbackground');
is('dark mode repaints the drawing in the shared palette', $dark ne $paper && $dark eq '#1f232b', "$paper -> $dark");
is('dark mode repaints the results table in the shared palette', $cell eq '#1f232b' && $head eq '#282d37', "$cell $head");
is('DARK MODE is labelled the same as the other windows, and the choice is ISO_THEME',
   $main::btn{THEME}->cget('-text') eq 'LIGHT MODE'
   && (HardyCross::Settings::get('ISO_THEME') // '') eq 'DARK'
   && !defined HardyCross::Settings::get('EDITOR_THEME')
   && !defined HardyCross::Settings::get('SHEET_THEME'),
   $main::btn{THEME}->cget('-text') . ' ISO=' . (HardyCross::Settings::get('ISO_THEME') // ''));
main::iso_apply_theme('LIGHT');
$main::mw->update;
is('light mode puts the paper back', lc $main::iso_cv->cget(-background) eq '#ffffff');
is('light mode puts the results table back', lc $main::vtable->{styles}{muted}->cget(-background) eq '#ffffff');

print "3. CLICK AND CLICK, OR THE KNOWN VALUES\n";
is('length, size, fittings and C can be typed before the click',
   exists $main::iso{known}{LENGTH} && exists $main::iso{known}{SIZE}
   && exists $main::iso{known}{FITTINGS} && exists $main::iso{known}{C});
is('the known length is labelled with its unit', $main::iso{known_label}{LENGTH}->cget(-text) =~ /LENGTH MM/);
$main::iso{known}{LENGTH} = '4000';
$main::iso{known}{SIZE} = '32';
$main::iso{known}{FITTINGS} = '1E';
$main::iso{known}{C} = '100';
main::iso_set_tool('PIPE');
main::iso_click_cell(4, 0);
main::iso_click_cell(20, 0);
$b = main::buffer();
is('a known length places the end, and the typed values are the pipe',
   $b =~ m{^//ISO \S+ 8 0 0$}m && $b =~ /^PIPE\s+\S+\s+S1\s+\S+\s+4000\s+32\s+1E/m
   && $b =~ /^USE\s+BORE\s+100/m, $b);
$main::mw->update;
my $focus = $main::mw->focusCurrent;
is('drawing a pipe leaves the drawing focused',
   $focus && $main::iso_cv && $focus->PathName eq $main::iso_cv->PathName, $focus ? $focus->PathName : 'none');

main::iso_set_tool('SELECT');
main::iso_click_cell(6, 0);
$main::mw->update;
$focus = $main::mw->focusCurrent;
is('selecting a pipe focuses its length',
   $focus && $main::iso{entry}{LENGTH} && $focus->PathName eq $main::iso{entry}{LENGTH}->PathName,
   $focus ? $focus->PathName : 'none');
main::iso_set_field('LENGTH', '2000');
$b = main::buffer();
is('typing the length moves the end and keeps the typed length',
   $b =~ m{^//ISO \S+ 6 0 0$}m && $b =~ /^PIPE\s+\S+\s+S1\s+\S+\s+2000\s+32\s+1E/m, $b);
$main::mw->update;
$focus = $main::mw->focusCurrent;
is('return in the length moves on to the size',
   $focus && $main::iso{entry}{SIZE} && $focus->PathName eq $main::iso{entry}{SIZE}->PathName,
   $focus ? $focus->PathName : 'none');

$main::iso{known}{LENGTH} = '';
$main::iso{known}{SIZE} = '';
$main::iso{known}{FITTINGS} = '';
$main::iso{known}{C} = '';
main::iso_set_tool('PIPE');
main::iso_click_cell(6, 0);
main::iso_click_cell(6, 3);
$b = main::buffer();
is('a blank length follows the click', $b =~ /^PIPE\s+\S+\s+\S+\s+\S+\s+3000\s+25(?:\s|$)/m, $b);

$main::iso{known}{LENGTH} = '9000';
main::iso_click_cell(0, 0);
main::iso_click_cell(4, 0);
$b = main::buffer();
is('a click on an existing point joins it and does not move it',
   $b =~ m{^//ISO S1 4 0 0$}m && $b =~ /^PIPE\s+\S+\s+W1\s+S1\s+9000\b/m, $b);

my $opened = "$SETTINGS_DIR/opened.phc";
open my $out, '>', $opened or die $!;
print $out "NODE A 0\nNODE B 0\nPIPE P9 A B 4 25\n";
close $out;
main::open_path($opened);
$main::mw->update;
is('opening a file stays on the drawing', ($main::toptabs->{current} || '') eq 'ISOMETRIC', $main::toptabs->{current});
is('the opened network is drawn', main::buffer() =~ /^PIPE\s+P9\s+A\s+B\s/m && $main::iso{draw}{nodes}{A});

$main::mw->destroy;
print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
