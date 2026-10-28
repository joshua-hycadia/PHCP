#!/usr/bin/perl
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# test_editor_window.pl -- the editor WINDOW, driven under a display.
#
#   perl tools/test_editor_window.pl [--shot file.png]
#
# Needs Tk and an X display.  With no display it re-runs itself under
# xvfb-run, a virtual display, if that is installed; with neither it says
# SKIPPED and exits 0, so the suite can run on a machine without either --
# the README says plainly whether the window has been run.
#
# tools/test_editor.pl checks every decision the editor makes.  This checks
# that the window carries them out: the colours land on the right characters,
# the problems lists fill, Enter offers a proposal and Tab takes it, the pick
# list opens with the database codes, F5 fills the REPORT pane, the status bar
# shows the solved figures for the cursor's line, undo works, and the files
# open, save and write reports.  Keys are sent as real X key events where Tk
# delivers them reliably under a virtual display (Return, Tab, letters); the
# file dialogs are bypassed by passing the file name, as a user's choice would.
#
# --shot file.png saves a screenshot of the window after the solve.
#==============================================================================
use strict;
use warnings;
no warnings 'once';      # the editor's package variables are read from here
use FindBin;
use lib "$FindBin::Bin/..";
use File::Temp qw(tempdir);

my ($SHOT) = map { $ARGV[$_ + 1] } grep { $ARGV[$_] eq '--shot' } 0 .. $#ARGV;

#------------------------------------------------------------- a display
unless ($ENV{DISPLAY}) {
    if (!$ENV{PHCP_UNDER_XVFB} && system('which xvfb-run >/dev/null 2>&1') == 0) {
        $ENV{PHCP_UNDER_XVFB} = 1;
        exec 'xvfb-run', '-a', '-s', '-screen 0 1600x1000x24', $^X, $0, @ARGV;
    }
    print "SKIPPED: no X display and no xvfb-run - the editor window was not run\n";
    exit 0;
}
unless (eval { require Tk; 1 }) {
    print "SKIPPED: Tk is not installed - the editor window was not run\n";
    exit 0;
}

# Load the editor without starting its event loop: the flag tells it not to
# run main().
chdir "$FindBin::Bin/..";
$main::PHCP_EDITOR_LOAD_ONLY = 1;
require "./phcp_editor.pl";

my ($pass, $fail) = (0, 0);
sub is {
    my ($name, $ok, $why) = @_;
    printf "  %-66s %s\n", $name, $ok ? 'ok' : '*** FAIL';
    print "      $why\n" if !$ok && defined $why;
    $ok ? $pass++ : $fail++;
}
sub slurp { my $p = shift; open my $f, '<', $p or die "$p: $!\n"; local $/; <$f> }
my $TMP = tempdir(CLEANUP => 1);

# key -- send one real key press and release to the editor, then let Tk run.
sub key {
    my $sym = shift;
    my $t = main::text_widget();
    $t->focusForce;
    $main::mw->update;
    $t->eventGenerate('<KeyPress>',   -keysym => $sym, -when => 'now');
    $t->eventGenerate('<KeyRelease>', -keysym => $sym, -when => 'now');
    $main::mw->update;
}
# type -- send each character of a string as a key.
sub type {
    my %sym = (' ' => 'space', '=' => 'equal', '.' => 'period', '/' => 'slash');
    key($sym{$_} // $_) for split //, shift;
}
# tags_on -- the tags on a character of the editor.
sub tags_on { my $i = shift; return map { "$_" } $main::ed->tagNames($i) }
sub flush { $main::mw->update; $main::recolour_job && $main::recolour_job->cancel; main::recolour(); $main::mw->update }

#==============================================================================
print "1. THE WINDOW\n";
#==============================================================================
main::build_window();
$main::mw->update;
is('the window opens, titled', $main::mw->title eq 'PHCP EDITOR - untitled.phc', $main::mw->title);
my $menubar = $main::mw->cget(-menu);
my @menus = map { $menubar->entrycget($_, -label) }
            grep { $menubar->type($_) eq 'cascade' } 0 .. $menubar->index('end');
is('menus in capitals: FILE EDIT MODEL', "@menus" eq 'FILE EDIT MODEL', "@menus");
is('light blue paper, black ink in the editor',
   lc $main::ed->cget(-background) eq lc $main::C{paper} && $main::ed->cget(-foreground) eq '#000000');
is('the report pane in the same scheme', lc $main::report->cget(-background) eq lc $main::C{paper});
is('a black status band', $main::statusbar->cget(-background) eq '#000000');

#==============================================================================
print "2. OPEN AND COLOUR\n";
#==============================================================================
main::open_path('examples/07_pipe_database_demo.phc');
flush();
is('a .phc opens into the editor unchanged',
   main::buffer() eq slurp('examples/07_pipe_database_demo.phc'));
is('the title names the file', $main::mw->title eq 'PHCP EDITOR - 07_pipe_database_demo.phc');
my @lines = split /\n/, main::buffer();
my ($tl) = grep { $lines[ $_ - 1 ] =~ /^Title/ } 1 .. @lines;
my ($pl) = grep { $lines[ $_ - 1 ] =~ /^Pipe\s+M1/ } 1 .. @lines;
is('command words carry the command colour', (grep { $_ eq 'command' } tags_on("$tl.0"))
   && (grep { $_ eq 'command' } tags_on("$pl.2")));
is('the arguments do not', !grep { $_ eq 'command' } tags_on("$pl.12"));
is('comments carry the comment colour', grep { $_ eq 'comment' } tags_on('1.0'));
is('no line is red in a good model', !$main::ed->tagRanges('error'));
is('no problems listed', $main::problems->size == 0 && $main::undefined->size == 0);

#==============================================================================
print "3. ERRORS, PROBLEMS, UNDEFINED NODES\n";
#==============================================================================
my $n = @lines + 1;
$main::ed->insert('end', "Pipe Z1 H3 ZZ 3 32\nHead S9 ZZ K=80\nPipx\n");
$main::ed->markSet('insert', '1.0');
flush();
is('an unknown command line is red', grep { $_ eq 'error' } tags_on(($n + 2) . '.1'));
is('an incomplete line, cursor elsewhere, is red', grep { $_ eq 'error' } tags_on(($n + 1) . '.1'));
my @pr = $main::problems->get(0, 'end');
is('the problems list names both lines', (grep { /^LINE $n\s+.*any two/ || /^LINE ${\($n+1)}\s+.*any two/ } @pr)
   && (grep { /unknown command Pipx/ } @pr), "@pr");
my @un = $main::undefined->get(0, 'end');
is('UNDEFINED NODES lists ZZ and the line first using it', "@un" =~ /^ZZ\s+FIRST USED ON LINE $n$/, "@un");
$main::problems->selectionClear(0, 'end');
$main::problems->selectionSet($#pr);
main::go_to_list($main::problems, \@main::problem_lines);
is('clicking a problem moves the cursor to its line',
   ($main::ed->index('insert') =~ /^(\d+)/)[0] == $main::problem_lines[-1]);
$main::ed->delete("$n.0", 'end');
flush();
is('removing the bad lines clears the lists and the red',
   $main::problems->size == 0 && $main::undefined->size == 0 && !$main::ed->tagRanges('error'));

#==============================================================================
print "4. PROPOSALS - Enter offers, Tab and Enter accept, typing discards\n";
#==============================================================================
my ($b3) = grep { $lines[ $_ - 1 ] =~ /^Pipe\s+B3/ } 1 .. @lines;
$main::ed->markSet('insert', "$b3.0 lineend");
key('Return');
is('Enter after a pipe offers the next one, greyed', $main::prop{active}
   && $main::ed->get('pstart', 'pend') =~ /^Pipe B4 H3 H4 3\.2 32$/
   && (grep { $_ eq 'proposal' } tags_on('pstart')), $main::ed->get('insert linestart', 'insert lineend'));
is('   an offered line is not part of the model yet', main::buffer() !~ /B4/);
key('Tab');
is('Tab accepts it as typed text', !$main::prop{active} && main::buffer() =~ /^Pipe B4 H3 H4 3\.2 32$/m
   && !(grep { $_ eq 'proposal' } tags_on(($b3 + 1) . '.2')));
key('Return');
is('Enter again offers the next', $main::prop{active} && $main::ed->get('pstart', 'pend') =~ /^Pipe B5 H4 H5/);
key('Return');
is('Enter accepts and offers the one after (holding Enter repeats)',
   main::buffer() =~ /^Pipe B5 H4 H5 3\.2 32$/m && $main::prop{active}
   && $main::ed->get('pstart', 'pend') =~ /^Pipe B6 H5 H6/);
key('x');
is('typing anything else discards it and types the key', !$main::prop{active}
   && main::buffer() !~ /B6/ && $main::ed->get('insert linestart', 'insert lineend') eq 'x');
main::undo();
# TextUndo merges adjacent typing into one step, so this undo takes the
# newline and the x together; what matters is that the discarded proposal
# does not come back as text.
is('undo removes the typed key, and the discarded proposal does not come back',
   main::buffer() !~ /x$/ && main::buffer() !~ /B6/, main::buffer());
for (1 .. 3) { last if main::buffer() !~ /^Pipe B5/m; main::undo() }
is('further undo removes the accepted line', main::buffer() !~ /^Pipe B5/m, main::buffer());
main::redo();
is('redo puts it back', main::buffer() =~ /^Pipe B5/m);
# Tidy the buffer back to the file for what follows.
main::set_buffer(slurp('examples/07_pipe_database_demo.phc'));

#==============================================================================
print "5. PICK LIST, Ctrl+Space\n";
#==============================================================================
$main::ed->insert('end', "Use ");
$main::ed->markSet('insert', 'end - 1 chars');
my $top = main::pick_list();
$main::mw->update;
my $lb = $top && ($top->children)[0];
my @items = $lb ? $lb->get(0, 'end') : ();
is('Ctrl+Space in a Use line lists the pipe types with descriptions',
   (grep { /^ASAM\s+AS 1074 Medium/ } @items) && (grep { /^BORE / } @items), "@items[0..2]");
$top->destroy if $top;
main::insert_choice('S40');
is('picking inserts the code at the cursor', main::buffer() =~ /^Use S40$/m);
$main::ed->insert('end', "\nPipe Q1 R1 R2 3 50 G");
$main::ed->markSet('insert', 'end - 1 chars');
$top = main::pick_list();
$main::mw->update;
@items = $top ? ($top->children)[0]->get(0, 'end') : ();
is('in a fitting field it lists the fitting codes for that pipe and size',
   (grep { /^GV\s/ } @items) && (grep { /^EF\s/ } @items) == 0, scalar(@items) . ' items');
$top->destroy if $top;
main::insert_choice('GV');
is('a partly typed code is completed, not doubled', main::buffer() =~ /^Pipe Q1 R1 R2 3 50 GV$/m);
main::set_buffer(slurp('examples/07_pipe_database_demo.phc'));

#==============================================================================
print "6. SOLVE, F5, AND RESULTS ON THE CURSOR\n";
#==============================================================================
key('F5');
is('F5 fills the REPORT pane with the full report',
   main::report_text() =~ /PIPE SCHEDULE/ && main::report_text() =~ /FLOW PATH TO THE GOVERNING OUTLET/);
is('the status bar says it converged', main::status_text() =~ /SOLVED - CONVERGED/, main::status_text());
main::go_to_line($pl);
$main::ed->markSet('insert', "$pl.0 lineend");
main::update_status();
is('on pipe M1 the status bar shows its solved flow, velocity and pressures',
   main::status_text() =~ /M1  Q 3576\.8 L\/min  V 6\.87 m\/s  SUP 650\.0 kPa -> R1 461\.0 kPa/,
   main::status_text());
is('   with the Pipe template, the current field highlighted',
   main::status_text() =~ /^\s*PIPE id n1 n2 length size/ && $main::statusbar->tagRanges('current'),
   main::status_text());
if ($SHOT) {
    $main::mw->raise;
    $main::mw->update;
    system('import', '-window', $main::mw->id, $SHOT) == 0
        ? print "      screenshot saved to $SHOT\n"
        : print "      screenshot not taken\n";
}
$main::ed->insert("$pl.0 lineend", ' ');
main::update_status();
is('after an edit the figures are marked as from the earlier solve',
   main::status_text() =~ /SOLVED BEFORE THE LATEST EDITS/);
main::set_buffer(slurp('examples/07_pipe_database_demo.phc') . "Pipe Z9 H3 NOWHERE 3 32\n");
my $r = main::solve();
my ($cur) = $main::ed->index('insert') =~ /^(\d+)/;
is('a model with an error is not solved; the cursor goes to the error line',
   !$r->{ok} && $cur == @lines + 1 && main::report_text() =~ /NOT SOLVED/, "line $cur");

#==============================================================================
print "7. FILES\n";
#==============================================================================
main::set_buffer(slurp('examples/01_single_branch.phc'));
($main::path, $main::suggest) = (undef, undef);
$main::ed->insert('end', "// edited\n");
main::after_change();
is('an edit marks the title with *', $main::mw->title =~ /\*$/);
main::file_save_as("$TMP/saved.phc");
is('SAVE AS writes the buffer', slurp("$TMP/saved.phc") eq main::buffer());
is('   and the title loses the *', $main::mw->title eq 'PHCP EDITOR - saved.phc');
main::open_path('examples/02_full_network.hcx');
is('opening a .hcx converts it into a new unsaved .phc buffer',
   main::buffer() eq slurp('examples/02_full_network.phc') && !defined $main::path);
is('   the title says not saved, and the status bar says converted',
   $main::mw->title =~ /02_full_network\.phc \(not saved\) \*$/ && main::status_text() =~ /CONVERTED FROM/);
main::file_report("$TMP/report.pdf");
is('WRITE REPORT .pdf solves and writes a PDF', -s "$TMP/report.pdf" && slurp("$TMP/report.pdf") =~ /^%PDF-/);
main::file_report("$TMP/report.txt");
is('WRITE REPORT .txt writes the text report', slurp("$TMP/report.txt") =~ /OUTLET COMPLIANCE/);
main::file_save_as("$TMP/02.phc");
is('saving the converted buffer gives a .phc that solves to the same report',
   slurp("$TMP/02.phc") eq slurp('examples/02_full_network.phc'));

$main::mw->destroy;
print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
