#!/usr/bin/perl
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# test_sheet_window.pl -- the spreadsheet window, built and driven headlessly.
#
#   xvfb-run -a perl tools/test_sheet_window.pl
#
# The same idea as test_editor_window.pl: no mouse, the widgets are asked
# directly.  What is checked is that the four network tabs are grids, that
# typing a pipe fills the nodes tab, that a node type of PRV adds that
# device's row, and that VALIDATE and CALCULATE are the editor's, so the
# answer is the engine's.
#==============================================================================
use strict;
use warnings;
no warnings 'once';      # the sheet's package variables are read from here
use FindBin;
use lib "$FindBin::Bin/..";
use File::Temp qw(tempdir);

my $pass = 0;
my $fail = 0;
sub is {
    my ($name, $ok, $why) = @_;
    printf "  %-64s %s\n", $name, $ok ? 'ok' : '*** FAIL';
    print "      $why\n" if !$ok && defined $why;
    $ok ? $pass++ : $fail++;
}

# Same arrangement as the editor's window test: with no display, re-run under
# xvfb-run; with neither a display nor xvfb-run, say so and exit 0.
unless ($ENV{DISPLAY}) {
    if (!$ENV{PHCP_UNDER_XVFB} && system('which xvfb-run >/dev/null 2>&1') == 0) {
        $ENV{PHCP_UNDER_XVFB} = 1;
        exec 'xvfb-run', '-a', '-s', '-screen 0 1600x1000x24', $^X, $0, @ARGV;
    }
    print "SKIPPED: no X display and no xvfb-run - the spreadsheet window was not run\n";
    exit 0;
}
unless (eval { require Tk; 1 }) {
    print "SKIPPED: Tk is not installed - the spreadsheet window was not run\n";
    exit 0;
}

# A settings file of this run's own, so the DATABASE tab never reads or
# writes a real one.
my $settings_dir = tempdir(CLEANUP => 1);
$ENV{PHCP_SETTINGS} = "$settings_dir/settings.ini";
delete $ENV{PHCP_DATABASE_DIR};

$main::PHCP_SHEET_LOAD_ONLY = 1;
require "$FindBin::Bin/../phcp_sheet.pl";

my $mw = build_window();
$mw->update;
is('the window is a spreadsheet, not the text editor', $mw->title =~ /^PHCP SHEET/);

my @tabs = @{ $main::toptabs->{names} };
is('the network is four grids, then the editor\'s other tabs',
   join(' ', @tabs) eq 'SYSTEM NODES SUPPLIES PRESSURE DEVICES PROJECT GRAPH QUICK TOOLS DATABASE',
   "@tabs");
is('the results tabs are the editor\'s',
   join(' ', @{ $main::restabs->{names} }) eq 'VALIDATION PIPES NODES OUTLETS REPORT');
is('each pressure device has its own table',
   join(' ', @{ $main::devtabs->{names} }) eq 'PUMP BP BFP PRV OPP OFD PRA');
is('a new sheet starts not validated, and calculate is off',
   state_text() eq 'NOT VALIDATED' && !calculate_enabled());
is('the system grid has a row to type in, and a pipe column',
   grid_cell('SYSTEM', 0, 'pipe') && grid_cell('SYSTEM', 0, 'fittings'));

# Type a pipe the way a keystroke does: the entry holds the text, and the
# KeyRelease binding is what writes it into the model.
sub type_cell {
    my ($id, $r, $key, $text) = @_;
    my $w = grid_cell($id, $r, $key) or return;
    $w->focusForce;
    $w->delete(0, 'end');
    $w->insert(0, $text);
    $w->eventGenerate('<KeyRelease>', -keysym => 'a', -when => 'now');
    $mw->update;
}

type_cell('SYSTEM', 0, 'pipe', 'P1');
type_cell('SYSTEM', 0, 'from', 'A');
type_cell('SYSTEM', 0, 'to', 'B');
type_cell('SYSTEM', 0, 'length', '10');
type_cell('SYSTEM', 0, 'type', 'ASAM');
type_cell('SYSTEM', 0, 'diam', '100');
type_cell('SYSTEM', 0, 'fittings', '2E T GV');
$mw->update;

my @nodes = HardyCross::Sheet::node_rows($main::sheet);
is('typing the pipe\'s ends fills the nodes tab, in that order', join(' ', @nodes) eq 'A B', "@nodes");
is('the node number is shown and is not an entry', grid_text('NODES', 0, 'node') eq 'A'
   && !grid_cell('NODES', 0, 'node')->isa('Tk::Entry'));
is('a new node\'s type is blank', grid_text('NODES', 0, 'type') eq '');

# Choosing PRV is the menu's command: commit_value is what that command calls.
commit_value('NODES', 1, 'type', 'PRV');
$mw->update;
my @prv = HardyCross::Sheet::device_rows($main::sheet, 'PRV');
is('PRV on a node adds one row to the PRV table', @prv == 1 && $prv[0]{node} eq 'B');
is('that row is on the pressure-devices grid, on the pipe that arrives there',
   grid_text('DEV:PRV', 0, 'node') eq 'B' && grid_text('DEV:PRV', 0, 'pipe') eq 'P1');
# The device page has to be showing, or Tk does not deliver the key to it.
select_tab($main::toptabs, 'PRESSURE DEVICES');
select_tab($main::devtabs, 'PRV');
$mw->update;
type_cell('DEV:PRV', 0, 'q1', '0');
type_cell('DEV:PRV', 0, 'l1', '40');
commit_value('NODES', 1, 'type', '');
$mw->update;
is('clearing the type takes the row off the table', !HardyCross::Sheet::device_rows($main::sheet, 'PRV'));
commit_value('NODES', 1, 'type', 'PRV');
$mw->update;
is('choosing it again brings the loss back', grid_text('DEV:PRV', 0, 'l1') eq '40',
   'cell=[' . grid_text('DEV:PRV', 0, 'l1') . ']');

select_tab($main::toptabs, 'NODES');
$mw->update;
type_cell('NODES', 0, 'elev', '0');
type_cell('NODES', 1, 'elev', '3');
commit_value('NODES', 0, 'type', 'SUPPLY');
select_tab($main::toptabs, 'SUPPLIES');
$mw->update;
type_cell('SUPPLIES', 0, 'static', '800');
type_cell('SUPPLIES', 0, 'static', '850');
is('SUPPLY adds the supplies row, and the elevation stays on the node',
   grid_text('SUPPLIES', 0, 'node') eq 'A' && grid_text('SUPPLIES', 0, 'static') eq '850'
   && grid_text('NODES', 0, 'elev') eq '0');

# The last edit replaced 800 with 850.  Undo returns to 800; redo to 850.
edit_undo();
$mw->update;
is('undo puts the last cell back', grid_text('SUPPLIES', 0, 'static') eq '800',
   'static=[' . grid_text('SUPPLIES', 0, 'static') . ']');
edit_redo();
$mw->update;
is('redo puts the typed value back', grid_text('SUPPLIES', 0, 'static') eq '850',
   'static=[' . grid_text('SUPPLIES', 0, 'static') . ']');

my $v = validate();
is('the typed model validates', $v->{ok}, join('; ', map { $_->{what} } @{ $v->{items} }));
is('calculate turns on once it is valid', calculate_enabled() && state_text() eq 'VALID - READY TO CALCULATE');
my $r = calculate();
is('calculate runs the engine and converges', $r->{ok} && $r->{converged});
is('the pipe table has the pipe', (grep { $_->[0] =~ /P1/ } table_rows('PIPES')) ? 1 : 0);

# A file the editor already opens, through the sheet.
open_path("$FindBin::Bin/../examples/01_single_branch.phc");
$mw->update;
is('opening a .phc file fills the system grid from it', grid_text('SYSTEM', 0, 'pipe') eq 'P1'
   && grid_text('SYSTEM', 0, 'from') eq 'N1' && grid_text('SYSTEM', 0, 'diam') eq '100.0');
is('the supply and the sprinkler land on the nodes tab',
   grid_text('NODES', 0, 'type') eq 'SUPPLY' && grid_text('NODES', 1, 'type') eq 'SPRINKLER');
is('the sprinkler\'s minimum pressure is in MIN P', grid_text('NODES', 1, 'min_p') eq '50');
$v = validate();
is('the opened file validates', $v->{ok}, join('; ', map { $_->{what} } @{ $v->{items} }));
$r = calculate();
is('and calculates', $r->{ok} && $r->{converged});

# A fault goes to the cell.  A bad diameter may not be the first problem the
# reader lists (a pipe it cannot read also leaves a node unconnected), so the
# click is the row that names the size.
select_tab($main::toptabs, 'SYSTEM');
$mw->update;
type_cell('SYSTEM', 0, 'diam', 'not-a-size');
$v = validate();
is('a bad diameter is a problem', !$v->{ok});
my ($fi) = grep { ($v->{items}[$_]{what} // '') =~ /NOT A NUMBER/ } 0 .. $#{ $v->{items} };
go_to_fault($fi // 0);
$mw->update;
my $focused = $mw->focusCurrent;
is('clicking it selects the system tab and the diameter cell',
   $main::toptabs->{current} eq 'SYSTEM' && $focused && $focused eq grid_cell('SYSTEM', 0, 'diam'),
   'tab=' . ($main::toptabs->{current} // '') . ' focus=' . ($focused ? $focused->PathName : 'none')
   . ' whats=' . join(' | ', map { $_->{what} } @{ $v->{items} }));

$mw->destroy;
print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
