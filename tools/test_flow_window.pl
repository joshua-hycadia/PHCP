#!/usr/bin/perl
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# test_flow_window.pl -- the drawn window, under a display.
#
#   perl tools/test_flow_window.pl [--shot file.png]
#
# Needs Tk and an X display.  With no display it re-runs itself under
# xvfb-run; with neither it says SKIPPED and exits 0.  What the drawing
# means is checked in tools/test_flow.pl.  This checks that the window
# shows it: the page, a block placed with the pointer, VALIDATE before
# CALCULATE, and the pressures drawn on the blocks.
#==============================================================================
use strict;
use warnings;
no warnings 'once';
use FindBin;
use lib "$FindBin::Bin/..";
use File::Temp qw(tempdir);

my ($SHOT) = map { $ARGV[$_ + 1] } grep { $ARGV[$_] eq '--shot' } 0 .. $#ARGV;

unless ($ENV{DISPLAY}) {
    if (!$ENV{PHCP_UNDER_XVFB} && system('which xvfb-run >/dev/null 2>&1') == 0) {
        $ENV{PHCP_UNDER_XVFB} = 1;
        exec 'xvfb-run', '-a', '-s', '-screen 0 1400x900x24', $^X, $0, @ARGV;
    }
    print "SKIPPED: no X display and no xvfb-run - the flow window was not run\n";
    exit 0;
}
unless (eval { require Tk; 1 }) {
    print "SKIPPED: Tk is not installed - the flow window was not run\n";
    exit 0;
}

chdir "$FindBin::Bin/..";
$main::PHCP_FLOW_LOAD_ONLY = 1;
require "./phcp_flow.pl";

my ($pass, $fail) = (0, 0);
sub is {
    my ($name, $ok, $why) = @_;
    printf "  %-72s %s\n", $name, $ok ? 'ok' : '*** FAIL';
    print "      $why\n" if !$ok && defined $why;
    $ok ? $pass++ : $fail++;
}
my $TMP = tempdir(CLEANUP => 1);

main::build_window();
$main::mw->update;

is('white page', $main::canvas->cget('-bg') eq '#FFFFFF');
is('flat: the toolbar buttons have no bevel',
   !grep { $_->cget('-relief') ne 'flat' } values %main::toolbtn, $main::btn{CALCULATE});
my @bevel;
sub bevelled {
    my $w = shift;
    for my $c ($w->children) {
        my $class = eval { $c->class } || '';
        if ($class =~ /^(Button|Menubutton|Scrollbar|Entry)\z/) {
            my $rel = eval { $c->cget('-relief') } // '';
            push @bevel, "$class $rel" if $rel ne 'flat';
        }
        bevelled($c);
    }
}
bevelled($main::mw);
is('flat: fields, menus and scrollbars have no bevel', !@bevel, join('; ', @bevel));
sub walk {
    my $w = shift;
    return () unless $w;
    return $w, map { walk($_) } $w->children;
}
is('SELECT is the tool, and it is the highlight',
   $main::tool eq 'SELECT' && $main::toolbtn{SELECT}->cget('-bg') eq '#1F5FBF');
is('CALCULATE waits for VALIDATE', $main::btn{CALCULATE}->cget('-fg') eq '#A3AAB4');

my $n0 = @{ $main::doc->{nodes} };
main::set_tool('SPRINKLER');
$main::canvas->eventGenerate('<Button-1>', -x => 420, -y => 240);
$main::canvas->eventGenerate('<ButtonRelease-1>', -x => 420, -y => 240);
$main::mw->update;
is('a click with SPRINKLER chosen places a head', @{ $main::doc->{nodes} } == $n0 + 1
   && (grep { $_->{kind} eq 'SPRINKLER' } @{ $main::doc->{nodes} }));
is('the head is drawn', $main::canvas->find('withtag', 'node') > 0);

is('anything but a .phc is refused', !main::open_path("$TMP/notes.txt", 1));
is('example 01 opens', main::open_path('examples/01_single_branch.phc', 1));
$main::mw->update;
my %drawn;
for my $item ($main::canvas->find('withtag', 'node')) {
    for my $tag ($main::canvas->gettags($item)) { $drawn{$1} = 1 if $tag =~ /^node:(.+)/ }
}
is('both blocks are on the page', keys %drawn == 2, join ' ', sort keys %drawn);
is('the pipe is drawn', $main::canvas->find('withtag', 'pipe') >= 1);

my $early = main::do_calculate();
is('CALCULATE before VALIDATE does not solve', !$early->{ok} && $early->{error} eq 'VALIDATE FIRST');
my $v = main::do_validate();
is('VALIDATE accepts the example', $v->{ok}, $v->{error});
is('CALCULATE is now the highlight', $main::btn{CALCULATE}->cget('-bg') eq '#1F5FBF');
my $c = main::do_calculate();
is('CALCULATE converges', $c->{ok}, $c->{error});
my @results = map { $main::canvas->itemcget($_, '-text') } $main::canvas->find('withtag', 'result');
is('pressures are drawn in the file\'s unit', (grep { /KPA/ } @results) >= 1, join(' | ', @results));
is('the pipe flow is drawn', (grep { /LPM/ } @results) >= 1);

# A second example, with a pump and devices, so the page is not only a branch.
is('example 02 opens', main::open_path('examples/02_full_network.phc', 1));
$main::mw->update;
is('a pump is drawn as a pump', $main::canvas->find('withtag', 'pump') >= 1);
my ($title_e) = grep { eval { $_->class eq 'Entry' && $_->get =~ /COMBINED SPRINKLER/ } } walk($main::card);
is('the title fits in its field', $title_e && $title_e->fontMeasure($title_e->cget('-font'), $title_e->get) <= $title_e->width - 8,
   $title_e ? $title_e->width . ' px for ' . length($title_e->get) . ' letters' : 'no title field');
$main::mw->update;
my @sr = @{ $main::card_cv->cget('-scrollregion') };
is('the card scrolls as far as its last line',
   $sr[3] >= $main::card->reqheight - 2, "@sr against " . $main::card->reqheight);
is('a device is named on its pipe', $main::canvas->find('withtag', 'device') >= 1);

# Dark is the same drawing.  The page, the card and a field change together,
# and the pressures stay on the blocks.  Put the light page back afterwards.
main::do_validate();
main::do_calculate();
$main::mw->update;
main::toggle_dark();
$main::mw->update;
is('DARK turns the page dark', lc($main::canvas->cget('-bg')) eq '#1c1f26');
is('DARK turns the card dark', lc($main::card->cget('-bg')) eq '#14171c');
my ($dark_e) = grep { eval { $_->class eq 'Entry' } } walk($main::card);
is('DARK turns a field dark', $dark_e && lc($dark_e->cget('-bg')) eq '#1c1f26');
my @dark_results = map { $main::canvas->itemcget($_, '-text') } $main::canvas->find('withtag', 'result');
is('DARK keeps the pressures and flows', (grep { /KPA|LPM/ } @dark_results) >= 2, join(' | ', @dark_results));
is('the button offers the way back', $main::btn{DARK}->cget('-text') eq 'LIGHT');
main::toggle_dark();
$main::mw->update;
is('LIGHT restores the white page', lc($main::canvas->cget('-bg')) eq '#ffffff');
is('LIGHT restores the button', $main::btn{DARK}->cget('-text') eq 'DARK');

my $out = "$TMP/drawn.phc";
is('SAVE writes the drawing', main::file_save($out));
is('the saved file is .phc the reader accepts',
   eval { require HardyCross::Phc; HardyCross::Phc::read_string(do { local $/; open my $f, '<', $out; <$f> }, '.'); 1 },
   $@ && (ref $@ ? $@->{msg} : $@));

if ($SHOT) {
    main::open_path('examples/02_full_network.phc', 1);
    main::set_tool('SELECT');
    main::do_validate();
    main::do_calculate();
    $main::mw->update;
    system('import', '-window', $main::mw->id, $SHOT) == 0
        ? print "      screenshot saved to $SHOT\n"
        : print "      screenshot not taken\n";
}

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
