#!/usr/bin/perl
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# test_fast_window.pl -- the fast-entry window, driven under a display.
#
#   perl tools/test_fast_window.pl [--shot file.png]
#
# Needs Tk and an X display.  With no display it re-runs itself under
# xvfb-run; with neither it says SKIPPED and exits 0.  The decisions are
# checked in tools/test_fast.pl.  This checks that the window carries them
# out: the row, a run added from the row, ditto, undo, validate before
# calculate, and a .phc file round trip.  File dialogs are bypassed by
# passing the file name.
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
    print "SKIPPED: no X display and no xvfb-run - the fast-entry window was not run\n";
    exit 0;
}
unless (eval { require Tk; 1 }) {
    print "SKIPPED: Tk is not installed - the fast-entry window was not run\n";
    exit 0;
}

chdir "$FindBin::Bin/..";
$main::PHCP_FAST_LOAD_ONLY = 1;
require "./phcp_fast.pl";

my ($pass, $fail) = (0, 0);
sub is {
    my ($name, $ok, $why) = @_;
    printf "  %-66s %s\n", $name, $ok ? 'ok' : '*** FAIL';
    print "      $why\n" if !$ok && defined $why;
    $ok ? $pass++ : $fail++;
}
sub slurp { my $p = shift; open my $f, '<', $p or die "$p: $!\n"; local $/; <$f> }
my $TMP = tempdir(CLEANUP => 1);

sub key {
    my ($w, $sym) = @_;
    $w->focusForce;
    $main::mw->update;
    $w->eventGenerate('<KeyPress>',   -keysym => $sym, -when => 'now');
    $w->eventGenerate('<KeyRelease>', -keysym => $sym, -when => 'now');
    $main::mw->update;
}

#==============================================================================
print "1. THE WINDOW\n";
#==============================================================================
main::build_window();
$main::mw->update;
is('the window opens, titled in capitals', $main::mw->title eq 'PHCP FAST ENTRY - UNTITLED.PHC', $main::mw->title);
is('the window is white', lc $main::mw->cget(-background) eq '#ffffff');
is('flat buttons', !grep { $main::btn{$_}->cget(-relief) ne 'flat' } keys %main::btn);
my $menubar = $main::mw->cget(-menu);
my @menus = map { $menubar->entrycget($_, -label) } grep { $menubar->type($_) eq 'cascade' } 0 .. $menubar->index('end');
is('menus FILE EDIT MODEL', "@menus" eq 'FILE EDIT MODEL', "@menus");
is('CALCULATE starts unavailable', $main::btn{CALCULATE}->cget(-state) eq 'disabled');
is('PIPE is the command on show', $main::mode_key eq 'PIPE' && $main::ent{NAME});
is('the hint tells how a run is written', $main::hint_l->cget(-text) =~ /P1-P12/ && $main::hint_l->cget(-text) =~ /P1X12/);
{
    my @sizes = sort { $a <=> $b } map { $_->width } grep { $_->isa('Tk::Photo') } $main::mw->imageNames;
    is('the PHCP icon is set, at 16, 32 and 48', "@sizes" =~ /\b16 32 48\b/, "photos: @sizes");
}
is('a new file is not modified', !main::modified());

#==============================================================================
print "2. A ROW, FROM THE FIELDS AND FROM KEYS\n";
#==============================================================================
main::set_mode('NODE');
$main::mw->update;
is('NODE is selected', $main::mode_key eq 'NODE'
    && lc $main::mode_btn{NODE}->cget(-background) eq lc $main::C{accent_bg},
    $main::mode_btn{NODE}->cget(-background));
main::set_fields(NAME => 'N1', ELEVATION => '0');
my $r = main::commit_row();
is('enter adds the node', $r->{ok} && $main::list->size == 1 && $main::list->get(0) =~ /NODE\s+N1 0/, $r->{message});
is('the file is now modified', main::modified());

# The next node is offered.  Accept it with the Return key, after typing only
# a name over the proposal, the way a run of similar nodes is entered.
main::set_fields(NAME => 'N2');
key($main::ent{NAME}, 'Return');
is('the return key adds the offered node', $main::list->size == 2 && $main::list->get(1) =~ /NODE\s+N2/);

main::set_mode('SPRINKLER');
main::set_fields(NAME => 'H1-H3', ELEVATION => '3.2', MINFLOW => '-50', K => '8');
$r = main::commit_row();
is('a name H1-H3 adds three heads', $r->{ok} && $main::list->size == 5, $r->{message} || $main::list->size);
is('the third head kept the elevation, minimum and K', $main::list->get(4) =~ /SPRINKLER\s+H3 3\.2 -50 8/, $main::list->get(4));

# Ditto: the size of a pipe, copied from the line above with the apostrophe.
main::set_mode('PIPE');
$main::use_type = 'ASAM';
$main::use_c = '120';
main::set_fields(NAME => 'P1', START => 'N1', END => 'H1', LENGTH => '4', SIZE => '25', FITTINGS => 'T');
$r = main::commit_row();
is('a pipe with a type and a fitting is added', $r->{ok} && $main::list->get($main::list->size - 1) =~ /FITTINGS| T\s*$| 25 T/,
    $r->{message} || $main::list->get($main::list->size - 1));
is('the type was written once, in front of the pipe', (grep { /USE\s+ASAM 120/ } map { $main::list->get($_) } 0 .. $main::list->size - 1) == 1);

# The offer keeps the fitting.  Overtype the name and the end, leave the rest,
# and ditto is not required for the fitting - it is already there.
is('the next pipe is offered with the fitting kept', ($main::value{FITTINGS} // '') eq 'T' && ($main::value{START} // '') eq 'H1',
    "start=$main::value{START} fit=$main::value{FITTINGS}");

# Apostrophe on a field that still shows the offer copies the previous line.
$main::value{SIZE} = '';
$main::ghost{SIZE} = '';
key($main::ent{SIZE}, 'apostrophe');
is('apostrophe copies the size from the pipe above', ($main::value{SIZE} // '') eq '25', $main::value{SIZE});

main::do_undo();
is('undo removes the last add', $main::list->size == 5, $main::list->size);
main::do_redo();
is('redo puts it back', $main::list->size >= 6);

#==============================================================================
print "3. VALIDATE, THEN CALCULATE\n";
#==============================================================================
# The heads and the one pipe do not make example 01.  Build that network.
$main::saved_text = main::full_text();
main::file_new();
is('new clears the network', $main::list->size == 0 && !main::modified());
$main::unit_var{LENGTH} = 'M';
main::sync_settings();
main::set_mode('WATER');
main::set_fields(NAME => 'N1', ELEVATION => '0', STATIC => '900');
main::commit_row();
main::set_mode('SPRINKLER');
main::set_fields(NAME => 'N2', ELEVATION => '0', MINFLOW => '-50', K => '80');
main::commit_row();
main::set_mode('PIPE');
$main::use_type = 'BORE';
$main::use_c = '120';
main::set_fields(NAME => 'P1', START => 'N1', END => 'N2', LENGTH => '100', SIZE => '100');
$r = main::commit_row();
is('the worked branch is entered', $r->{ok}, $r->{message});
my $calc = main::do_calculate();
is('calculate is refused before validate', !$calc->{ok} && $calc->{not_validated});
my $v = main::do_validate();
is('the branch validates', $v->{ok}, join('; ', map { $_->{what} } @{ $v->{items} }));
is('calculate is now available', $main::btn{CALCULATE}->cget(-state) eq 'normal');
$calc = main::do_calculate();
is('the branch converges', $calc->{ok} && $calc->{converged}, $calc->{error});
is('the pipe table shows P1', $main::pipe_list->get(1) =~ /P1/);
is('the report is the calculation report', main::report_text() =~ /PIPE/ && main::report_text() =~ /P1/);

# A click on a network line loads it back into the row.
$main::list->selectionSet(0);
$main::list->eventGenerate('<<ListboxSelect>>');
$main::mw->update;
is('clicking the first line loads it for editing', $main::edit_line == 1, "edit=$main::edit_line mode=$main::mode_key");

#==============================================================================
print "4. THE FILE IS ORDINARY .PHC\n";
#==============================================================================
main::escape_row();
$main::saved_text = main::full_text();
$main::title_var = 'FAST ENTRY';
$main::detail{JOB} = 'FE-1';
main::sync_settings();
my $out = "$TMP/branch.phc";
is('save writes a .phc file', main::file_save_as($out) && -s $out);
my $text = slurp($out);
is('the saved file holds the title, the job and the pipe',
    $text =~ /TITLE\s+FAST ENTRY/ && $text =~ /PROJECT\s+JOB FE-1/ && $text =~ /PIPE\s+P1 N1 N2 100 100/);
main::file_new();
main::open_path($out);
is('opening it shows the same lines', (grep { /PIPE\s+P1/ } main::list_text()) == 1);
is('and the job is still in the details', ($main::detail{JOB} // '') eq 'FE-1', $main::detail{JOB});
my $rep = "$TMP/branch.txt";
is('write report produces the text report', main::file_report($rep) && slurp($rep) =~ /P1/);

if ($SHOT) {
    $main::mw->update;
    my $id = $main::mw->id;
    system('import', '-window', $id, $SHOT) == 0 or system('xwd', '-id', $id, '-out', "$SHOT.xwd");
    print "shot: $SHOT\n" if -s $SHOT;
}

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
