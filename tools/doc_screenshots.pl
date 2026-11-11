#!/usr/bin/perl
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# doc_screenshots.pl -- the pictures in docs/USER_GUIDE.md, taken from the
# programs themselves.
#
#   perl tools/doc_screenshots.pl [outdir]        (default docs/images)
#
# Each window (the text editor, the spreadsheet and the isometric drawing) is
# opened on examples/02_full_network.phc, validated and calculated, and each
# tab the guide describes is saved as a PNG with ImageMagick's import.  The
# GRAPH tab is given examples/10_supply_graph.phg, so it has a graph to draw.  So the
# guide shows the programs as they are, not as they were when it was written.
#
# Needs Perl/Tk, ImageMagick and an X display.  With no display it re-runs
# itself under xvfb-run, the same arrangement as the window tests; CI's
# "screenshots" job runs it and keeps the pictures as an artifact.
#
# The three programs each define their own main:: subs, so each runs in a
# process of its own (--one <program> <outdir>).
#==============================================================================
use strict;
use warnings;
no warnings 'once';      # the programs' package variables are read from here
use FindBin;
use lib "$FindBin::Bin/..";
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);

my $ROOT = File::Spec->rel2abs("$FindBin::Bin/..");
my $MODEL = "$ROOT/examples/02_full_network.phc";

#------------------------------------------------------------- a display
unless ($ENV{DISPLAY}) {
    if (!$ENV{PHCP_UNDER_XVFB} && system('which xvfb-run >/dev/null 2>&1') == 0) {
        $ENV{PHCP_UNDER_XVFB} = 1;
        exec 'xvfb-run', '-a', '-s', '-screen 0 1600x1000x24', $^X, $0, @ARGV;
    }
    die "doc_screenshots: no X display and no xvfb-run\n";
}
die "doc_screenshots: Tk is not installed\n" unless eval { require Tk; 1 };
die "doc_screenshots: ImageMagick's import is not installed\n"
    unless system('which import >/dev/null 2>&1') == 0;

#------------------------------------------------------------- the parent
unless (@ARGV && $ARGV[0] eq '--one') {
    my $out = File::Spec->rel2abs($ARGV[0] // "$ROOT/docs/images");
    make_path($out);
    my $bad = 0;
    for my $prog (qw(editor sheet isometric)) {
        print "== $prog\n";
        system($^X, $0, '--one', $prog, $out) == 0 or $bad++;
    }
    exit($bad ? 1 : 0);
}

#------------------------------------------------------------- one program
my (undef, $PROG, $OUT) = @ARGV;
chdir $ROOT;
# Settings of this run's own, so a user's real ones are never read: every
# picture is the program's defaults (light mode, the shipped database).
my $SETTINGS_DIR = tempdir(CLEANUP => 1);
$ENV{PHCP_SETTINGS} = "$SETTINGS_DIR/settings.ini";
delete $ENV{PHCP_DATABASE_DIR};

if ($PROG eq 'editor') {
    $main::PHCP_EDITOR_LOAD_ONLY = 1;
    require "./phcp_editor.pl";
} elsif ($PROG eq 'sheet') {
    $main::PHCP_SHEET_LOAD_ONLY = 1;
    require "./phcp_sheet.pl";
} elsif ($PROG eq 'isometric') {
    $main::PHCP_EDITOR_LOAD_ONLY = 1;
    $main::PHCP_ISO_LOAD_ONLY = 1;
    require "./phcp_isometric.pl";
} else {
    die "doc_screenshots: unknown program $PROG\n";
}

main::build_window();
my $mw = $main::mw;
$mw->update;
main::open_path($MODEL) or die "doc_screenshots: $MODEL did not open\n";
$mw->update;
main::validate();
main::calculate();
$mw->update;

# shot -- show the given tabs, then save the window as <program>_<name>.png.
sub shot {
    my ($name, @tabs) = @_;
    while (my ($bar, $tab) = splice @tabs, 0, 2) {
        main::select_tab($bar, $tab);
    }
    $mw->raise;
    $mw->update;
    $mw->idletasks;
    my $file = "$OUT/${PROG}_$name.png";
    if (system('import', '-window', $mw->id, $file) == 0) {
        print "  $file\n";
    } else {
        die "doc_screenshots: import failed for $file\n";
    }
}

my ($top, $res) = ($main::toptabs, $main::restabs);
if ($PROG eq 'editor') {
    shot('network',    $top => 'NETWORK', $res => 'PIPES');
    shot('outlets',    $top => 'NETWORK', $res => 'OUTLETS');
    shot('validation', $top => 'NETWORK', $res => 'VALIDATION');
    shot('report',     $top => 'NETWORK', $res => 'REPORT');
    shot('project',    $top => 'PROJECT');
    main::graph_open("$ROOT/examples/10_supply_graph.phg") or die "doc_screenshots: the graph did not open
";
    shot('graph',      $top => 'GRAPH');
    shot('quick_tools', $top => 'QUICK TOOLS');
    shot('orifice',    $top => 'ORIFICE PLATE');
    shot('database',   $top => 'DATABASE');
    main::toggle_theme();
    shot('dark',       $top => 'NETWORK', $res => 'PIPES');
} elsif ($PROG eq 'sheet') {
    shot('system',     $top => 'SYSTEM', $res => 'PIPES');
    shot('nodes',      $top => 'NODES', $res => 'NODES');
    shot('supplies',   $top => 'SUPPLIES', $res => 'OUTLETS');
    shot('devices',    $top => 'PRESSURE DEVICES', $res => 'VALIDATION');
} else {
    main::select_tab($top, 'ISOMETRIC');
    main::iso_fit(1);          # the FIT button: the whole network in the canvas
    shot('drawing',    $top => 'ISOMETRIC');
}
$mw->destroy;
exit 0;
