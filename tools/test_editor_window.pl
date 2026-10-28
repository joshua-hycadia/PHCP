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
# that the window carries them out: the layout (editor, command strip and
# status bar above, ERRORS / WARNINGS / NODES to the right, the results
# tables below), the colours on the right characters, the three lists, the
# command strip, Enter offering a proposal and Tab taking it, the pick list,
# F5 filling the tables and the REPORT tab, sorting, the column chooser and
# the HIDE boxes, the units dialog, undo, and the files.  Keys are sent as real X key events where Tk
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
is('the window opens, titled in capitals', $main::mw->title eq 'PHCP EDITOR - UNTITLED.PHC', $main::mw->title);
my $menubar = $main::mw->cget(-menu);
my @menus = map { $menubar->entrycget($_, -label) }
            grep { $menubar->type($_) eq 'cascade' } 0 .. $menubar->index('end');
is('menus in capitals: FILE EDIT MODEL', "@menus" eq 'FILE EDIT MODEL', "@menus");
my ($fi) = grep { $menubar->type($_) eq 'cascade' } 0 .. $menubar->index('end');
my $filemenu = $menubar->entrycget($fi, -menu);
my @items = map { $filemenu->entrycget($_, -label) }
            grep { $filemenu->type($_) eq 'command' } 0 .. $filemenu->index('end');
is('every FILE item in capitals, PROPERTIES among them',
   !grep({ /[a-z]/ } @items) && grep({ /^PROPERTIES/ } @items), "@items");
is('light blue paper, black ink in the editor',
   lc $main::ed->cget(-background) eq lc $main::C{paper} && $main::ed->cget(-foreground) eq '#000000');
is('the report tab in the same scheme', lc $main::report->cget(-background) eq lc $main::C{paper});
is('a black status band', $main::statusbar->cget(-background) eq '#000000');
my @strip = main::strip_commands();
is('the command strip lists every command, in its groups',
   "@strip" eq join(' ', @HardyCross::Phc::COMMANDS) && @strip == 24, "@strip");
is('the ERRORS, WARNINGS and NODES lists sit to the right of the editor',
   $main::list{ERRORS}->rootx > $main::ed->rootx + $main::ed->width - 5
   && $main::list{NODES}->rooty > $main::list{ERRORS}->rooty);
is('the results tables sit below the editor',
   $main::table{PIPES}{hlist}->rooty > $main::ed->rooty + $main::ed->height
   && join(' ', $main::book->pages) eq 'PIPES NODES OUTLETS REPORT', join(' ', $main::book->pages));

#==============================================================================
print "2. OPEN AND COLOUR\n";
#==============================================================================
my $EX7 = 'examples/07_pipe_database_demo.phc';
main::open_path($EX7);
flush();
is('a .phc opens into the editor unchanged', main::buffer() eq slurp($EX7));
is('the status bar shows the first line\'s template at once', main::status_text() =~ /^\s*TITLE TEXT/, main::status_text());
is('before a solve the tables say how to get results',
   $main::table{PIPES}{hlist}->header('cget', 0, '-widget')->cget(-text) =~ /F5 SOLVES/);
is('the title names the file', $main::mw->title eq 'PHCP EDITOR - 07_PIPE_DATABASE_DEMO.PHC', $main::mw->title);
my @lines = split /\n/, main::buffer();
my ($tl) = grep { $lines[ $_ - 1 ] =~ /^TITLE/ } 1 .. @lines;
my ($pl) = grep { $lines[ $_ - 1 ] =~ /^PIPE\s+M1/ } 1 .. @lines;
is('command words carry the command colour', (grep { $_ eq 'command' } tags_on("$tl.0"))
   && (grep { $_ eq 'command' } tags_on("$pl.2")));
is('the fields do not', !grep { $_ eq 'command' } tags_on("$pl.12"));
$main::ed->insert('1.0', "// A NOTE\n");
flush();
is('comments carry the comment colour', grep { $_ eq 'comment' } tags_on('1.3'));
main::set_buffer(slurp($EX7));
is('no line is red in a good model', !$main::ed->tagRanges('error'));
is('nothing in the three lists', !grep { $main::list{$_}->size } qw(ERRORS WARNINGS NODES));

#==============================================================================
print "3. ERRORS AND NODES\n";
#==============================================================================
my $n = @lines + 1;
$main::ed->insert('end', "PIPE Z1 H3 ZZ 3 32\nSPRINKLER S9 0\nPIPX\nNODE LONE 0\n");
$main::ed->markSet('insert', '1.0');
flush();
is('an unknown command line is red', grep { $_ eq 'error' } tags_on(($n + 2) . '.1'));
is('an incomplete line, cursor elsewhere, is red', grep { $_ eq 'error' } tags_on(($n + 1) . '.1'));
my @er = $main::list{ERRORS}->get(0, 'end');
is('ERRORS names both lines',
   (grep { /^LINE ${\($n+1)}\s+SPRINKLER NEEDS MINFLOW$/ } @er) && (grep { /^LINE ${\($n+2)}\s+UNKNOWN COMMAND PIPX$/ } @er),
   "@er");
my @no = $main::list{NODES}->get(0, 'end');
is('NODES lists ZZ, used but not defined, and LONE, unconnected',
   (grep { /^LINE $n\s+ZZ - USED, BUT NOT DEFINED$/ } @no)
   && (grep { /^LINE ${\($n+3)}\s+LONE - DEFINED, BUT NOTHING CONNECTS TO IT$/ } @no), "@no");
$main::list{ERRORS}->selectionClear(0, 'end');
$main::list{ERRORS}->selectionSet($#er);
main::go_to_list('ERRORS');
is('clicking an error moves the cursor to its line',
   ($main::ed->index('insert') =~ /^(\d+)/)[0] == $main::list_lines{ERRORS}[-1]);
$main::ed->delete("$n.0", 'end');
flush();
is('removing the bad lines clears the lists and the red',
   !$main::list{ERRORS}->size && !$main::list{NODES}->size && !$main::ed->tagRanges('error'));

#==============================================================================
print "4. THE COMMAND STRIP\n";
#==============================================================================
$main::ed->markSet('insert', 'end - 1 chars');
main::start_command('SPRINKLER');
my ($cl) = main::cursor();
is('a click on SPRINKLER starts a SPRINKLER line',
   $main::ed->get("$cl.0", "$cl.0 lineend") eq 'SPRINKLER ', $main::ed->get("$cl.0", "$cl.0 lineend"));
main::update_status();
is('   and the status bar shows its fields, NAME current',
   main::status_text() =~ /^\s*SPRINKLER NAME ELEVATION MINFLOW K/, main::status_text());
$main::ed->markSet('insert', "$pl.4");
main::start_command('NODE');
($cl) = main::cursor();
is('on a line in use, the command goes on a new line below it',
   $cl == $pl + 1 && $main::ed->get("$cl.0", "$cl.0 lineend") eq 'NODE      '
   && $main::ed->get("$pl.0", "$pl.0 lineend") eq $lines[ $pl - 1 ]);
main::set_buffer(slurp($EX7));

#==============================================================================
print "5. PROPOSALS - Enter offers, Tab and Enter accept, typing discards\n";
#==============================================================================
my ($b3) = grep { $lines[ $_ - 1 ] =~ /^PIPE\s+B3/ } 1 .. @lines;
$main::ed->markSet('insert', "$b3.0 lineend");
key('Return');
is('Enter after a pipe offers the next one, greyed', $main::prop{active}
   && $main::ed->get('pstart', 'pend') eq 'PIPE B4 H3 H4 3.2 32'
   && (grep { $_ eq 'proposal' } tags_on('pstart')), $main::ed->get('insert linestart', 'insert lineend'));
is('   an offered line is not part of the model yet', main::buffer() !~ /B4/);
key('Tab');
is('Tab accepts it as typed text', !$main::prop{active} && main::buffer() =~ /^PIPE B4 H3 H4 3\.2 32$/m
   && !(grep { $_ eq 'proposal' } tags_on(($b3 + 1) . '.2')));
key('Return');
is('Enter again offers the next', $main::prop{active} && $main::ed->get('pstart', 'pend') =~ /^PIPE B5 H4 H5/);
key('Return');
is('Enter accepts and offers the one after (holding Enter repeats)',
   main::buffer() =~ /^PIPE B5 H4 H5 3\.2 32$/m && $main::prop{active}
   && $main::ed->get('pstart', 'pend') =~ /^PIPE B6 H5 H6/);
key('x');
is('typing anything else discards it and types the key', !$main::prop{active}
   && main::buffer() !~ /B6/ && $main::ed->get('insert linestart', 'insert lineend') eq 'x');
main::undo();
# TextUndo merges adjacent typing into one step, so this undo may take the
# newline and the x together; what matters is that the discarded proposal
# does not come back as text.
is('undo removes the typed key, and the discarded proposal does not come back',
   main::buffer() !~ /x$/m && main::buffer() !~ /B6/, main::buffer());
for (1 .. 3) { last if main::buffer() !~ /^PIPE B5/m; main::undo() }
is('further undo removes the accepted line', main::buffer() !~ /^PIPE B5/m);
main::redo();
is('redo puts it back', main::buffer() =~ /^PIPE B5/m);
main::set_buffer(slurp($EX7));

#==============================================================================
print "6. PICK LIST, Ctrl+Space\n";
#==============================================================================
$main::ed->insert('end', "USE ");
$main::ed->markSet('insert', 'end - 1 chars');
my $top = main::pick_list();
$main::mw->update;
my $lb = $top && ($top->children)[0];
@items = $lb ? $lb->get(0, 'end') : ();
is('Ctrl+Space in a USE line lists the pipe types with descriptions',
   (grep { /^ASAM\s+\S/ } @items) && (grep { /^BORE / } @items) && !grep({ /[a-z]/ } @items), "@items[0..2]");
$top->destroy if $top;
main::insert_choice('S40');
is('picking inserts the code at the cursor', main::buffer() =~ /^USE S40$/m);
$main::ed->insert('end', "\nPIPE Q1 R1 R2 3 50 G");
$main::ed->markSet('insert', 'end - 1 chars');
$top = main::pick_list();
$main::mw->update;
@items = $top ? ($top->children)[0]->get(0, 'end') : ();
is('in a fitting field it lists the fitting codes for that pipe and size',
   (grep { /^GV\s/ } @items) && (grep { /^E\s/ } @items), scalar(@items) . ' items');
$top->destroy if $top;
main::insert_choice('GV');
is('a partly typed code is completed, not doubled', main::buffer() =~ /^PIPE Q1 R1 R2 3 50 GV$/m);
main::set_buffer(slurp($EX7));

#==============================================================================
print "7. SOLVE, F5, AND RESULTS ON THE CURSOR\n";
#==============================================================================
key('F5');
is('F5 fills the REPORT tab with the full report',
   main::report_text() =~ /PIPE SCHEDULE/i && main::report_text() =~ /GOVERNING OUTLET/i);
is('the status bar says it converged', main::status_text() =~ /SOLVED - CONVERGED/, main::status_text());
main::go_to_line($pl);
$main::ed->markSet('insert', "$pl.0 lineend");
main::update_status();
is('on pipe M1 the status bar shows its solved flow, velocity and pressures',
   main::status_text() =~ /M1  Q 3576\.8 L\/MIN  V 6\.87 M\/S  SUP 650\.0 KPA -> R1 461\.0 KPA/,
   main::status_text());
is('   with the PIPE template, the current field highlighted',
   main::status_text() =~ /^\s*PIPE NAME START END LENGTH SIZE/ && $main::statusbar->tagRanges('current'),
   main::status_text());
my @w = $main::list{WARNINGS}->get(0, 'end');
is('WARNINGS lists M1, over the velocity limit, on its line',
   grep({ /^LINE $pl\s+M1 - VELOCITY 6\.87 M\/S IS OVER THE LIMIT/ } @w), "@w");

#==============================================================================
print "8. THE RESULTS TABLES\n";
#==============================================================================
my @heads = main::table_heads('PIPES');
is('PIPES: the default columns',
   "@heads" eq 'NAME SNODE ENODE NOM I.D. MAT C L F T FIT K Q PF PS VEL', "@heads");
my @rows = main::table_rows('PIPES');
is('PIPES: a row per pipe, M1 first as in the file',
   @rows == 6 && "@{ $rows[0] }" eq 'M1 SUP R1 100 105.1 ASAM 120 12.00 19.40 31.40 0.00 3576.8 144.86 - 6.87',
   "@{ $rows[0] }");
my %ci = map { $heads[$_] => $_ } 0 .. $#heads;
my ($vfull) = grep { $main::table{PIPES}{data}{columns}[$_]{key} eq 'VEL' } 0 .. $#{ $main::table{PIPES}{data}{columns} };
main::sort_table('PIPES', $vfull);
my @v = map { $_->[ $ci{VEL} ] } main::table_rows('PIPES');
is('a click on VEL sorts ascending', !(grep { $v[$_] > $v[ $_ + 1 ] } 0 .. $#v - 1), "@v");
main::sort_table('PIPES', $vfull);
@v = map { $_->[ $ci{VEL} ] } main::table_rows('PIPES');
is('   a second click reverses', !(grep { $v[$_] < $v[ $_ + 1 ] } 0 .. $#v - 1), "@v");
my ($head) = grep { $_->cget(-text) =~ /^VEL/ } map { $main::table{PIPES}{hlist}->header('cget', $_, '-widget') }
             0 .. $#heads;
is('   and its heading shows the direction', $head && $head->cget(-text) =~ /^VEL v/);
my $menu = main::column_menu();
my @labels = map { $menu->entrycget($_, -label) } 0 .. $menu->index('end');
is('the column chooser lists all 21 columns, NAME fixed',
   @labels == 21 && $labels[0] eq 'PIPE NAME' && $menu->entrycget(0, -state) eq 'disabled', "@labels");
$menu->unpost; $menu->destroy;
$main::pipe_show{RE} = 1; $main::pipe_show{MAT} = 0;
main::make_table('PIPES');
@heads = main::table_heads('PIPES');
is('turning RE on and MAT off changes the columns shown',
   (grep { $_ eq 'RE' } @heads) && !(grep { $_ eq 'MAT' } @heads), "@heads");
$main::pipe_show{RE} = 0; $main::pipe_show{MAT} = 1;
main::make_table('PIPES');
my @nr = main::table_rows('NODES');
my ($sup) = grep { $_->[0] eq 'SUP' } @nr;
is('NODES: SUP is the WATER supply at 650.0', $sup && $sup->[1] eq 'WATER' && $sup->[3] eq '650.0');
my @or = main::table_rows('OUTLETS');
is('OUTLETS: the three sprinklers, each with a result',
   @or == 3 && !grep { $_->[-1] !~ /^(PASS|FAIL)$/ } @or);

# HIDE: a pipe carrying no flow, a dead end off R2.
main::set_buffer(slurp($EX7) . "NODE DEAD 4.5\nPIPE D1 R2 DEAD 2 25\n");
main::solve();
my $all = main::table_rows('PIPES');
$main::hide_pipes = 1; main::fill_table('PIPES');
my @shown = map { $_->[0] } main::table_rows('PIPES');
is('HIDE NON-FLOWING PIPES leaves out the dead end', $all == 7 && @shown == 6 && !grep { $_ eq 'D1' } @shown,
   "$all / @shown");
$main::hide_pipes = 0; main::fill_table('PIPES');
my $alln = main::table_rows('NODES');
$main::hide_nodes = 1; main::fill_table('NODES');
my @sn = map { $_->[0] } main::table_rows('NODES');
is('HIDE INACTIVE NODES leaves out the dead node', !grep({ $_ eq 'DEAD' } @sn) && @sn == $alln - 1, "@sn");
$main::hide_nodes = 0; main::fill_table('NODES');
main::set_buffer(slurp($EX7));
main::solve();

if ($SHOT) {
    main::go_to_line($pl);
    $main::mw->raise;
    $main::mw->update;
    system('import', '-window', $main::mw->id, $SHOT) == 0
        ? print "      screenshot saved to $SHOT\n"
        : print "      screenshot not taken\n";
}
$main::ed->insert("$pl.0 lineend", ' ');
$main::ed->markSet('insert', "$pl.0 lineend");
main::update_status();
is('after an edit the figures are marked as from the earlier solve',
   main::status_text() =~ /SOLVED BEFORE THE LATEST EDITS/, main::status_text());
main::set_buffer(slurp($EX7) . "PIPE Z9 H3 NOWHERE 3 32\n");
my $r = main::solve();
my ($cur) = $main::ed->index('insert') =~ /^(\d+)/;
is('a model with an error is not solved; the cursor goes to the error line',
   !$r->{ok} && $cur == @lines + 1 && main::report_text() =~ /NOT SOLVED/, "line $cur");
is('   and the tables are emptied', !main::table_rows('PIPES'));

#==============================================================================
print "9. PROPERTIES - UNITS\n";
#==============================================================================
main::set_buffer(slurp($EX7));
my ($dlg, $pick) = main::properties();
$main::mw->update;
is('the dialog opens with the file\'s units', $pick->{LENGTH} eq 'M' && $pick->{FLOW} eq 'LPM');
$dlg->destroy;
main::apply_units({ %$pick, FLOW => 'LPS' });
is('choosing LPS rewrites the UNITS FLOW line', main::buffer() =~ /^UNITS     FLOW LPS$/m
   && main::buffer() !~ /FLOW LPM/);
main::solve();
is('and the results follow: M1 in L/S', main::status_text() =~ /SOLVED/ && do {
       main::go_to_line($pl); main::update_status(); main::status_text() =~ /M1  Q 59\.6\d* L\/S/ },
   main::status_text());
main::undo();
is('undo puts the units back', main::buffer() =~ /FLOW LPM/);

#==============================================================================
print "10. FILES\n";
#==============================================================================
main::set_buffer(slurp('examples/01_single_branch.phc'));
$main::path = undef;
$main::ed->insert('end', "// EDITED\n");
main::after_change();
is('an edit marks the title with *', $main::mw->title =~ /\*$/);
main::file_save_as("$TMP/saved.phc");
is('SAVE AS writes the buffer', slurp("$TMP/saved.phc") eq main::buffer());
is('   and the title loses the *', $main::mw->title eq 'PHCP EDITOR - SAVED.PHC', $main::mw->title);
my $before = main::buffer();
main::open_path('examples/02_full_network.hcx');
is('a .hcx is refused, the buffer kept, the reason shown',
   main::buffer() eq $before && main::status_text() =~ /THE EDITOR WORKS IN \.PHC FILES/, main::status_text());
main::open_path('examples/02_full_network.phc');
main::file_report("$TMP/report.pdf");
is('WRITE REPORT .pdf solves and writes a PDF', -s "$TMP/report.pdf" && slurp("$TMP/report.pdf") =~ /^%PDF-/);
main::file_report("$TMP/report.txt");
is('WRITE REPORT .txt writes the text report', slurp("$TMP/report.txt") =~ /OUTLET COMPLIANCE/i);

$main::mw->destroy;
print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
