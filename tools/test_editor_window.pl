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
# that the window carries them out: the layout (toolbar, NETWORK and PROJECT
# tabs, the editor with its line numbers, the three lists, the results tabs
# below), the white, flat look, the syntax colours, the command strip,
# proposals and undo, the pick list, VALIDATE before CALCULATE and the
# VALIDATION tab, the tables with sorting, the column chooser and the HIDE
# boxes, the PROJECT tab, and the files.  Keys are sent as real X key events where Tk
# delivers them reliably under a virtual display (Return, Tab, letters); the
# file dialogs are bypassed by passing the file name, as a user's choice would.
#
# --shot file.png saves a screenshot of the window after the calculation.
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
# Settings of our own, so the tests never read or write a user's real ones;
# and no database folder from the environment.
my $SETTINGS_DIR = tempdir(CLEANUP => 1);
$ENV{PHCP_SETTINGS} = "$SETTINGS_DIR/settings.ini";
delete $ENV{PHCP_DATABASE_DIR};
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
my @casc = grep { $menubar->type($_) eq 'cascade' } 0 .. $menubar->index('end');
my @menus = map { $menubar->entrycget($_, -label) } @casc;
is('menus in capitals: FILE EDIT MODEL', "@menus" eq 'FILE EDIT MODEL', "@menus");
my $mm = $menubar->entrycget($casc[2], -menu);
my @mi = map { $mm->entrycget($_, -label) } grep { $mm->type($_) eq 'command' } 0 .. $mm->index('end');
is('MODEL: VALIDATE, then CALCULATE', "@mi" eq 'VALIDATE CALCULATE', "@mi");
is('white paper and black ink in the editor',
   lc $main::ed->cget(-background) eq '#ffffff' && lc $main::ed->cget(-foreground) eq '#111111');
is('the window itself is white, not blue', lc $main::mw->cget(-background) eq '#ffffff');
{
    my @sizes = sort { $a <=> $b } map { $_->width } grep { $_->isa('Tk::Photo') } $main::mw->imageNames;
    is('the PHCP icon is set, at 16, 32 and 48 pixels', "@sizes" =~ /\b16 32 48\b/, "photos: @sizes");
}
is('flat: no bevel on the buttons or the editor',
   !grep({ $main::btn{$_}->cget(-relief) ne 'flat' || $main::btn{$_}->cget(-borderwidth) != 0 } keys %main::btn)
   && $main::ed->cget(-borderwidth) == 0);
my @strip = main::strip_commands();
is('the command strip lists the 19 network commands, no settings',
   @strip == 19 && $strip[0] eq 'USE' && $strip[-1] eq 'PRA' && !grep({ /^(TITLE|PROJECT|UNITS|METHOD|OPTION)$/ } @strip),
   "@strip");
is('NETWORK, PROJECT, GRAPH, QUICK TOOLS and DATABASE tabs above; VALIDATION, PIPES, NODES, OUTLETS, REPORT below',
   join(' ', @{ $main::toptabs->{names} }) eq 'NETWORK PROJECT GRAPH QUICK TOOLS DATABASE'
   && join(' ', @{ $main::restabs->{names} }) eq 'VALIDATION PIPES NODES OUTLETS REPORT');
is('the ERRORS, WARNINGS and NODES lists sit to the right of the editor',
   $main::list{ERRORS}->rootx > $main::ed->rootx + $main::ed->width - 5
   && $main::list{NODES}->rooty > $main::list{ERRORS}->rooty);
is('the results sit below the editor', $main::table{PIPES}{page}->rooty > $main::ed->rooty + $main::ed->height);
is('a line-number gutter left of the editor', $main::gutter->rootx < $main::ed->rootx && (main::gutter_numbers())[0] eq '1');
{
    my @pw = grep { $_->isa('Tk::Panedwindow') } $main::mw->Descendants;
    is('three dividers (results, side lists, graph), each wide enough to grab (6 px), with the resize pointer',
       @pw == 3 && !grep({ $_->cget(-sashwidth) < 6 } @pw)
       && (grep { $_->cget(-sashcursor) eq 'sb_v_double_arrow' } @pw) == 1);
}
is('sizes scale with the screen: px() multiplies by the scale, at least 1',
   $main::SCALE >= 1 && main::px(10) == int(10 * $main::SCALE + 0.5) && ref main::px([2, 4]) eq 'ARRAY');
is('FITTING_BASIS is a drop-down that shows DEFAULT when blank',
   $main::form{FITTING_BASIS}->isa('Tk::Menubutton') && $main::form{FITTING_BASIS}->cget(-text) =~ /^DEFAULT/);
is('CALCULATE is off and the model NOT VALIDATED', !main::calculate_enabled() && main::state_text() eq 'NOT VALIDATED');

#==============================================================================
print "2. OPEN: the network in the editor, the rest in the PROJECT tab\n";
#==============================================================================
my $EX7 = 'examples/07_pipe_database_demo.phc';
main::open_path($EX7);
flush();
my $doc = HardyCross::Editor::split_file(slurp($EX7));
is('the editor holds the network only', main::buffer() eq $doc->{network} && main::buffer() !~ /^(TITLE|PROJECT|UNITS)/m);
is('the PROJECT tab holds the title, details and units',
   $main::settings->{title} eq 'LEVEL 2 SPRINKLER RANGE - DEMONSTRATION' && $main::form{JOB}->get eq 'HYC-DEMO-017'
   && $main::settings->{units}{LENGTH} eq 'M' && $main::form{LENGTH}->cget(-text) =~ /^M\s/);
is('opening is not a change: no *', $main::mw->title eq 'PHCP EDITOR - 07_PIPE_DATABASE_DEMO.PHC', $main::mw->title);
is('the status bar shows the first line\'s template', main::status_text() =~ /^WATER NAME ELEVATION STATIC/, main::status_text());
my @lines = split /\n/, main::buffer();
is('a number for every line', (main::gutter_numbers())[-1] == @lines + 1);
my ($pl) = grep { $lines[ $_ - 1 ] =~ /^PIPE\s+M1/ } 1 .. @lines;
my ($ul) = grep { $lines[ $_ - 1 ] =~ /^USE\s+ASAM/ } 1 .. @lines;
is('syntax: the command word', grep { $_ eq 'command' } tags_on("$pl.1"));
is('syntax: the pipe\'s name, its nodes, its length, its fittings',
   (grep { $_ eq 'name' } tags_on("$pl.10")) && (grep { $_ eq 'ref' } tags_on("$pl.13"))
   && (grep { $_ eq 'number' } tags_on("$pl.21")) && (grep { $_ eq 'keyword' } tags_on("$pl.30")));
is('syntax: a pipe type', grep { $_ eq 'keyword' } tags_on("$ul.11"));
$main::ed->insert('1.0', "// A NOTE\n");
flush();
is('syntax: a comment', grep { $_ eq 'comment' } tags_on('1.3'));
main::set_buffer($doc->{network});
is('nothing is marked in a good model', !$main::ed->tagRanges('error') && !grep { $main::list{$_}->size } qw(ERRORS WARNINGS NODES));
is('before a calculation the tables say how to get results',
   main::header_text('PIPES', 0) =~ /VALIDATE \(F4\), THEN CALCULATE \(F5\)/);

#==============================================================================
print "3. LIVE CHECKS - the lists and the marks as you type\n";
#==============================================================================
my $n = @lines + 1;
$main::ed->insert('end', "PIPE Z1 H3 ZZ 3 32\nSPRINKLER S9 0\nPIPX\nNODE LONE 0\n");
$main::ed->markSet('insert', '1.0');
flush();
is('a line in error has a pale red band', grep { $_ eq 'error' } tags_on(($n + 2) . '.1'));
is('   and its number is red', grep { /^\d+\.\d+$/ && (split /\./)[0] == $n + 2 } $main::gutter->tagRanges('bad'));
my @er = $main::list{ERRORS}->get(0, 'end');
is('ERRORS names both lines, by editor line',
   (grep { /^\s*${\($n+1)}\s+SPRINKLER NEEDS MINFLOW$/ } @er) && (grep { /^\s*${\($n+2)}\s+UNKNOWN COMMAND PIPX$/ } @er),
   "@er");
is('   with a count in its heading', $main::list_head{ERRORS}->cget(-text) eq 'ERRORS  2');
my @no = $main::list{NODES}->get(0, 'end');
is('NODES lists ZZ and LONE',
   (grep { /^\s*$n\s+ZZ - USED, BUT NOT DEFINED$/ } @no) && (grep { /LONE - DEFINED, BUT NOTHING CONNECTS TO IT$/ } @no), "@no");
$main::list{ERRORS}->selectionClear(0, 'end');
$main::list{ERRORS}->selectionSet($#er);
main::go_to_list('ERRORS');
is('clicking an error moves the cursor to its line', (main::cursor())[0] == $n + 2);
$main::ed->delete("$n.0", 'end');
flush();
is('removing the bad lines clears the lists and the marks',
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
is('   and the status bar shows its fields', main::status_text() =~ /^SPRINKLER NAME ELEVATION MINFLOW K/, main::status_text());
$main::ed->markSet('insert', "$pl.4");
main::start_command('NODE');
($cl) = main::cursor();
is('on a line in use, the command goes on a new line below it',
   $cl == $pl + 1 && $main::ed->get("$cl.0", "$cl.0 lineend") eq 'NODE      ');
main::set_buffer($doc->{network});

#==============================================================================
print "5. PROPOSALS - Enter offers, Tab and Enter accept, typing discards\n";
#==============================================================================
my ($b3) = grep { $lines[ $_ - 1 ] =~ /^PIPE\s+B3/ } 1 .. @lines;
$main::ed->markSet('insert', "$b3.0 lineend");
key('Return');
is('Enter after a pipe offers the next one, greyed', $main::prop{active}
   && $main::ed->get('pstart', 'pend') eq 'PIPE B4 H3 H4 3.2 32' && (grep { $_ eq 'proposal' } tags_on('pstart')));
is('   an offered line is not part of the model yet', main::buffer() !~ /B4/);
key('Tab');
is('Tab accepts it as typed text', !$main::prop{active} && main::buffer() =~ /^PIPE B4 H3 H4 3\.2 32$/m);
key('Return');
key('Return');
is('Enter accepts and offers the one after', main::buffer() =~ /^PIPE B5 H4 H5 3\.2 32$/m && $main::prop{active});
key('x');
is('typing anything else discards it and types the key', !$main::prop{active}
   && main::buffer() !~ /B6/ && $main::ed->get('insert linestart', 'insert lineend') eq 'x');
main::undo();
is('undo: the discarded proposal does not come back', main::buffer() !~ /x$/m && main::buffer() !~ /B6/);
for (1 .. 3) { last if main::buffer() !~ /^PIPE B5/m; main::undo() }
is('further undo removes the accepted line', main::buffer() !~ /^PIPE B5/m);
main::redo();
is('redo puts it back', main::buffer() =~ /^PIPE B5/m);
main::set_buffer($doc->{network});

#==============================================================================
print "6. PICK LIST, Ctrl+Space\n";
#==============================================================================
$main::ed->insert('end', "USE ");
$main::ed->markSet('insert', 'end - 1 chars');
my $top = main::pick_list();
$main::mw->update;
my @items = $top ? ($top->children)[0]->get(0, 'end') : ();
is('in a USE line: the pipe types with descriptions', (grep { /^ASAM\s+\S/ } @items) && (grep { /^BORE / } @items));
$top->destroy if $top && Tk::Exists($top);
main::insert_choice('S40');
is('picking inserts the code', main::buffer() =~ /^USE S40$/m);
$main::ed->insert('end', "\nPIPE Q1 R1 R2 3 50 G");
$main::ed->markSet('insert', 'end - 1 chars');
$top = main::pick_list();
$main::mw->update;
@items = $top ? ($top->children)[0]->get(0, 'end') : ();
is('in a fitting field: the fitting codes for that pipe and size', (grep { /^GV\s/ } @items) && (grep { /^E\s/ } @items));
$top->destroy if $top && Tk::Exists($top);
main::insert_choice('GV');
is('a partly typed code is completed, not doubled', main::buffer() =~ /^PIPE Q1 R1 R2 3 50 GV$/m);
main::set_buffer($doc->{network});

#==============================================================================
print "7. VALIDATE BEFORE CALCULATE\n";
#==============================================================================
key('F5');
is('F5 before VALIDATE is refused, and says why',
   !$main::solved && main::status_text() =~ /VALIDATE THE INPUTS FIRST/, main::status_text());
$main::ed->insert('end', "PIPE Z1 H3 ZZ 3 32\nSPRINKLER S9 0\nPIPE Q1 R1 R2 3 47\n");
main::after_change();
key('F4');
my @vr = main::validation_rows();
is('F4 lists the problems in the VALIDATION tab: where, field, what, why',
   @vr == 3 && $vr[0][0] eq "LINE $n" && $vr[0][1] eq 'NODE' && $vr[0][2] eq 'NODE ZZ IS USED, BUT NOT DEFINED'
   && $vr[0][3] =~ /DEFINED BY NODE/ && $main::restabs->{current} eq 'VALIDATION', join ' | ', @{ $vr[0] || [] });
is('   CALCULATE stays off; the toolbar says 3 PROBLEMS',
   !main::calculate_enabled() && main::state_text() eq '3 PROBLEMS - SEE VALIDATION', main::state_text());
is('   each fault is marked on its field in the editor',
   (grep { $_ eq 'fault' } tags_on("$n.12")) && !(grep { $_ eq 'fault' } tags_on("$n.2"))
   && (grep { $_ eq 'fault' } tags_on(($n + 2) . '.17')));
is('   a short line has its last word marked', grep { $_ eq 'fault' } tags_on(($n + 1) . '.13'));
main::go_to_fault(2);
is('a click on a problem selects its field in the editor',
   $main::ed->get('sel.first', 'sel.last') eq '47' && (main::cursor())[0] == $n + 2);
main::set_buffer($doc->{network});
is('a change clears the marks and the verdict', !$main::ed->tagRanges('fault') && main::state_text() eq 'NOT VALIDATED');
my $v = main::validate();
is('a good model validates; CALCULATE comes on',
   $v->{ok} && main::calculate_enabled() && main::state_text() eq 'VALID - READY TO CALCULATE'
   && (main::validation_rows())[0][2] =~ /NO PROBLEMS FOUND/,
   join ' / ', $v->{ok} ? 'ok' : map({ $_->{what} } @{ $v->{items} }), main::state_text());
$main::ed->insert('end', ' ');
main::after_change();
is('any edit turns CALCULATE off again', !main::calculate_enabled() && main::state_text() eq 'NOT VALIDATED');
$main::ed->delete('end - 2 chars', 'end - 1 chars');
main::after_change();
main::validate();
$main::settings->{options}{VEL_LIMIT} = '8';
main::settings_changed();
is('so does a change in the PROJECT tab', !main::calculate_enabled());
$main::settings->{options}{VEL_LIMIT} = '';
main::settings_changed();
main::validate();
key('F5');
is('validated, F5 calculates: the REPORT and the tables fill',
   main::report_text() =~ /PIPE SCHEDULE/i && main::table_rows('PIPES') == 6 && main::state_text() eq 'CALCULATED');
is('   the PIPES tab comes forward, the status bar says converged',
   $main::restabs->{current} eq 'PIPES' && main::status_text() =~ /CALCULATED - CONVERGED/, main::status_text());
main::go_to_line($pl);
$main::ed->markSet('insert', "$pl.0 lineend");
main::update_status();
is('on pipe M1 the status bar shows its flow, velocity and pressures',
   main::status_text() =~ /M1  Q 3576\.8 L\/MIN  V 6\.87 M\/S  SUP 650\.0 KPA -> R1 461\.0 KPA/, main::status_text());
is('   with the PIPE template, the current field highlighted',
   main::status_text() =~ /^PIPE NAME START END LENGTH SIZE/ && $main::statusbar->tagRanges('current'));
my @w = $main::list{WARNINGS}->get(0, 'end');
is('WARNINGS lists M1 over the velocity limit, on its line', grep({ /^\s*$pl\s+M1 - VELOCITY 6\.87 M\/S/ } @w), "@w");

#==============================================================================
print "8. THE RESULTS TABLES\n";
#==============================================================================
my @heads = main::table_heads('PIPES');
is('PIPES: the default columns', "@heads" eq 'NAME SNODE ENODE NOM I.D. MAT C L F T FIT K Q PF PS VEL', "@heads");
my @rows = main::table_rows('PIPES');
is('PIPES: M1 first, as in the file',
   "@{ $rows[0] }" eq 'M1 SUP R1 100 105.1 ASAM 120 12.00 19.40 31.40 0.00 3576.8 144.86 - 6.87', "@{ $rows[0] }");
my %ci = map { $heads[$_] => $_ } 0 .. $#heads;
my ($vfull) = grep { $main::table{PIPES}{data}{columns}[$_]{key} eq 'VEL' } 0 .. $#{ $main::table{PIPES}{data}{columns} };
main::sort_table('PIPES', $vfull);
my @vv = map { $_->[ $ci{VEL} ] } main::table_rows('PIPES');
is('a click on VEL sorts ascending', !(grep { $vv[$_] > $vv[ $_ + 1 ] } 0 .. $#vv - 1), "@vv");
main::sort_table('PIPES', $vfull);
@vv = map { $_->[ $ci{VEL} ] } main::table_rows('PIPES');
is('   a second click reverses', !(grep { $vv[$_] < $vv[ $_ + 1 ] } 0 .. $#vv - 1), "@vv");
is('   and its heading shows the direction', main::header_text('PIPES', $ci{VEL}) =~ /^\s*VEL \x{25BC}\n\s*M\/S$/);
{
    # A real click in the heading row, at the middle of the Q column.
    my $h = $main::table{PIPES}{hlist};
    my $x = 0;
    $x += $h->columnWidth($_) for 0 .. $ci{Q} - 1;
    $x += int($h->columnWidth($ci{Q}) / 2);
    main::select_tab($main::restabs, 'PIPES');
    $h->focusForce;
    $main::mw->update;
    $h->eventGenerate('<ButtonPress-1>',   -x => $x, -y => 5, -button => 1, -when => 'now');
    $h->eventGenerate('<ButtonRelease-1>', -x => $x, -y => 5, -button => 1, -when => 'now');
    $main::mw->update;
    my @q = map { $_->[ $ci{Q} ] } main::table_rows('PIPES');
    is('a mouse click on the Q heading sorts on Q', !(grep { $q[$_] > $q[ $_ + 1 ] } 0 .. $#q - 1)
       && main::header_text('PIPES', $ci{Q}) =~ /Q \x{25B2}/, "@q");
}
is('the headings are one flat band: text in the header row, not buttons',
   !defined eval { $main::table{PIPES}{hlist}->header('cget', 0, '-widget') });
my $menu = main::column_menu();
my @labels = map { $menu->entrycget($_, -label) } 0 .. $menu->index('end');
is('the column chooser lists all 21 columns, NAME fixed',
   @labels == 21 && $labels[0] eq 'PIPE NAME' && $menu->entrycget(0, -state) eq 'disabled');
$menu->unpost; $menu->destroy;
$main::pipe_show{RE} = 1; $main::pipe_show{MAT} = 0;
main::make_table('PIPES');
@heads = main::table_heads('PIPES');
is('turning RE on and MAT off changes the columns', (grep { $_ eq 'RE' } @heads) && !(grep { $_ eq 'MAT' } @heads));
$main::pipe_show{RE} = 0; $main::pipe_show{MAT} = 1;
main::make_table('PIPES');
my ($sup) = grep { $_->[0] eq 'SUP' } main::table_rows('NODES');
is('NODES: SUP is the WATER supply at 650.0', $sup && $sup->[1] eq 'WATER' && $sup->[3] eq '650.0');
my @or = main::table_rows('OUTLETS');
is('OUTLETS: the three sprinklers, each PASS or FAIL', @or == 3 && !grep { $_->[-1] !~ /^(PASS|FAIL)$/ } @or);

main::set_buffer($doc->{network} . "NODE DEAD 4.5\nPIPE D1 R2 DEAD 2 25\n");
main::validate();
main::calculate();
my $all = main::table_rows('PIPES');
$main::hide_pipes = 1; main::fill_table('PIPES');
my @shown = map { $_->[0] } main::table_rows('PIPES');
is('the HIDE boxes count what they would hide: one pipe, one node',
   main::hide_count_text('pipes') eq '(1)' && main::hide_count_text('nodes') eq '(1)',
   main::hide_count_text('pipes') . ' ' . main::hide_count_text('nodes'));
is('HIDE NON-FLOWING PIPES leaves out the dead end', $all == 7 && @shown == 6 && !grep { $_ eq 'D1' } @shown);
$main::hide_pipes = 0; main::fill_table('PIPES');
my $alln = main::table_rows('NODES');
$main::hide_nodes = 1; main::fill_table('NODES');
my @sn = map { $_->[0] } main::table_rows('NODES');
is('HIDE INACTIVE NODES leaves out the dead node', !grep({ $_ eq 'DEAD' } @sn) && @sn == $alln - 1);
$main::hide_nodes = 0; main::fill_table('NODES');

main::set_buffer($doc->{network});
main::validate();
main::calculate();
is('with everything flowing the boxes say NONE, and are greyed',
   main::hide_count_text('pipes') eq '(NONE)' && main::hide_count_text('nodes') eq '(NONE)'
   && lc $main::checks{pipes}{label}->cget(-foreground) eq lc $main::C{faint});
{
    # The wheel goes to the pane under the pointer, not the one with the focus.
    main::select_tab($main::restabs, 'NODES');
    main::set_buffer(join "\n", map({ "NODE N$_ 0" } 1 .. 60), "WATER S 0 500", "SPRINKLER H 0 0 80",
                     map({ "PIPE P$_ N$_ N" . ($_ + 1) . " 1 50" } 1 .. 59), "PIPE PS S N1 1 100", "PIPE PH N60 H 1 50", '');
    main::validate();
    main::calculate();
    main::select_tab($main::restabs, 'NODES');
    $main::mw->update;
    my $h = $main::table{NODES}{hlist};
    my ($ey0) = $main::ed->yview;
    my ($hy0) = $h->yview;
    $main::ed->focusForce;
    $main::mw->update;
    $main::ed->eventGenerate('<MouseWheel>', -delta => -120, -when => 'now',
        -rootx => $h->rootx + 40, -rooty => $h->rooty + 60, -x => 40, -y => 60);
    $main::mw->update;
    my ($ey1) = $main::ed->yview;
    my ($hy1) = $h->yview;
    is('the wheel over the NODES table scrolls the table, not the editor with the focus',
       $hy1 > $hy0 && $ey1 == $ey0, "table $hy0 -> $hy1, editor $ey0 -> $ey1");
    $h->selectionSet(2);
    $h->anchorSet(2);
    my $cb = $h->cget(-browsecmd);
    $cb->Call(2) if $cb;
    is('a clicked row has its blue band and no dotted anchor box',
       !defined(($h->info('anchor'))[0]) || ($h->info('anchor'))[0] eq '');
    is('the results show the ordinary pointer', $h->cget(-cursor) =~ /^(left_ptr|arrow)$/);
    main::set_buffer($doc->{network});
    main::validate();
    main::calculate();
}
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
is('after an edit the figures are marked as from the earlier calculation',
   main::status_text() =~ /CALCULATED BEFORE THE LATEST EDITS/, main::status_text());

#==============================================================================
print "9. THE PROJECT TAB\n";
#==============================================================================
main::set_buffer($doc->{network});
main::select_tab($main::toptabs, 'PROJECT');
$main::mw->update;
is('the PROJECT tab shows the units as flat drop-downs',
   $main::form{FLOW}->ismapped && $main::form{FLOW}->cget(-relief) eq 'flat');
my $fm = $main::form{FLOW}->cget(-menu);
my ($lps) = grep { $fm->entrycget($_, -label) =~ /^LPS/ } 0 .. $fm->index('end');
my ($lpm) = grep { $fm->entrycget($_, -label) =~ /^LPM/ } 0 .. $fm->index('end');
is('   the default is marked in the menu', $fm->entrycget($lpm, -label) eq 'LPM   (DEFAULT)');
$fm->invoke($lps);
is('choosing LPS sets the unit, marks the file changed',
   $main::settings->{units}{FLOW} eq 'LPS' && $main::form{FLOW}->cget(-text) =~ /^LPS/ && $main::mw->title =~ /\*$/);
main::validate();
main::calculate();
main::go_to_line($pl);
main::update_status();
is('the results follow: M1 in L/S', main::status_text() =~ /M1  Q 59\.6\d* L\/S/, main::status_text());
$fm->invoke($lpm);
is('choosing LPM again: the file as it was, no *', $main::mw->title !~ /\*$/, $main::mw->title);
$main::form{JOB}->delete(0, 'end');
$main::form{JOB}->insert(0, 'job 42');
main::settings_changed();
is('text typed in a field is kept in capitals', $main::settings->{project}{JOB} eq 'JOB 42');
$main::settings->{options}{TOL_FLOW} = 'TIGHT';
main::settings_changed();
my ($oe) = grep { ($main::list_lines{ERRORS}[$_]{field} // '') eq 'TOL_FLOW' } 0 .. $#{ $main::list_lines{ERRORS} };
is('a bad option is listed in ERRORS', defined $oe && $main::list{ERRORS}->get($oe) =~ /PROJECT TAB, TOL_FLOW/);
main::select_tab($main::toptabs, 'NETWORK');
$main::list{ERRORS}->selectionClear(0, 'end');
$main::list{ERRORS}->selectionSet($oe // 0);
main::go_to_list('ERRORS');
is('   a click on it opens the PROJECT tab at the field', $main::toptabs->{current} eq 'PROJECT');
$v = main::validate();
is('   VALIDATE names the PROJECT tab and the field',
   !$v->{ok} && (main::validation_rows())[0][0] eq 'PROJECT TAB' && (main::validation_rows())[0][1] eq 'TOL_FLOW');
$main::settings->{options}{TOL_FLOW} = '';
main::settings_changed();

#==============================================================================
print "10. FILES\n";
#==============================================================================
main::open_path('examples/01_single_branch.phc');
$main::path = undef;
$main::ed->insert('end', "// EDITED\n");
main::after_change();
is('an edit marks the title with *', $main::mw->title =~ /\*$/);
main::file_save_as("$TMP/saved.phc");
my $saved = slurp("$TMP/saved.phc");
is('SAVE AS writes the settings at the head, then the network',
   $saved =~ /\AUNITS     LENGTH M\n/ && $saved =~ /\nMETHOD    HW\n/ && $saved =~ /\n\n\/\/ 01 - SINGLE BRANCH/
   && $saved =~ /\/\/ EDITED\n\z/, substr($saved, 0, 120));
is('   and the title loses the *', $main::mw->title eq 'PHCP EDITOR - SAVED.PHC', $main::mw->title);
my $sv = HardyCross::Editor::solve_text($saved);
is('   the saved file solves on its own', $sv->{ok} && $sv->{converged});
main::open_path("$TMP/saved.phc");
is('reopening it gives the same network and settings',
   main::buffer() =~ /\A\/\/ 01 - SINGLE BRANCH/ && $main::settings->{options}{TOL_FLOW} eq '0.001');
my $before = main::buffer();
main::open_path('examples/02_full_network.hcx');
is('a .hcx is refused, the buffer kept, the reason shown',
   main::buffer() eq $before && main::status_text() =~ /THE EDITOR WORKS IN \.PHC FILES/, main::status_text());
main::open_path('examples/02_full_network.phc');
main::file_report("$TMP/report.pdf");
is('WRITE REPORT validates, calculates and writes a PDF', -s "$TMP/report.pdf" && slurp("$TMP/report.pdf") =~ /^%PDF-/);
main::file_report("$TMP/report.txt");
is('WRITE REPORT .txt writes the text report', slurp("$TMP/report.txt") =~ /OUTLET COMPLIANCE/i);
main::set_buffer(main::buffer() . "PIPX\n");
is('WRITE REPORT on a model with problems stops at VALIDATION', !main::file_report("$TMP/no.txt") && !-e "$TMP/no.txt"
   && $main::restabs->{current} eq 'VALIDATION');

#==============================================================================
print "11. THE DATABASE TAB\n";
#==============================================================================
{
    my $real = slurp('data/pipes.dat');
    main::select_tab($main::toptabs, 'DATABASE');
    $main::mw->update;
    is('a DATABASE tab: the built-in database, its path and fingerprint',
       $main::dbv{origin}->cget(-text) eq 'BUILT-IN' && $main::dbv{path}->cget(-text) =~ m{data/pipes\.dat$}
       && $main::dbv{sha}->cget(-text) =~ /^FINGERPRINT [0-9A-F]{12}$/);
    is('four tables: pipe types, pipe sizes, fittings, K\' factors',
       join('|', @{ $main::dbv{tabs}{names} }) eq "PIPE TYPES|PIPE SIZES|FITTINGS|K' FACTORS");
    main::select_tab($main::dbv{tabs}, 'FITTINGS');
    is('the fittings table lists every fitting', @{ $main::dbv{shown_rows} } == 219);
    is('read-only at first: the row buttons off, the fields read-only, SAVE off',
       !$main::dbv{editing} && $main::dbv{btn}{UPDATE}->cget(-state) eq 'disabled'
       && $main::dbv{entries}[0]->cget(-state) eq 'readonly' && $main::dbv{btn}{SAVE}->cget(-state) eq 'disabled');
    $main::dbv{filter} = 'long radius 50 0.9';
    main::db_fill();
    is('the filter narrows the table: LONG RADIUS 50 0.9 is one row', @{ $main::dbv{shown_rows} } == 1,
       scalar @{ $main::dbv{shown_rows} });
    # Use a team folder of our own before any edit, so the real file is safe.
    my $team = tempdir(CLEANUP => 1);
    main::db_choose_folder($team, 'yes');
    is('CHOOSE FOLDER: an empty folder takes a copy and becomes the TEAM FOLDER',
       -e "$team/pipes.dat" && $main::dbv{origin}->cget(-text) eq 'TEAM FOLDER'
       && HardyCross::Settings::get('DATABASE_DIR') eq $team);
    main::select_tab($main::dbv{tabs}, 'FITTINGS');
    main::db_fill();
    my $row = $main::dbv{shown_rows}[0];
    $main::dbv{hlist}->selectionSet($row);
    $main::dbv{hlist}->cget(-browsecmd)->Call($row);
    is('a click on a row fills the fields', $main::dbv{vals}[1] eq 'EL' && $main::dbv{vals}[3] eq '50');
    main::db_update();
    is('read-only: UPDATE does nothing', !$main::dbv{db}{modified});
    $main::dbv{editing} = 1;
    main::db_editing_changed();
    is('ticking EDIT turns the row buttons and fields on',
       $main::dbv{btn}{UPDATE}->cget(-state) eq 'normal' && $main::dbv{entries}[0]->cget(-state) eq 'normal');
    $main::dbv{vals}[4] = 'ABC';
    main::db_update();
    is('a length that is not a number: refused, and the reason shown in red',
       $main::dbv{msg}->cget(-text) =~ /MUST BE A NUMBER/ && lc $main::dbv{msg}->cget(-foreground) eq lc $main::C{error});
    $main::dbv{vals}[4] = '1.7';
    main::db_update();
    is('a good change: made, and SAVE CHANGES comes on',
       $main::dbv{db}{modified} && $main::dbv{btn}{SAVE}->cget(-state) eq 'normal');
    main::open_path('examples/07_pipe_database_demo.phc');
    main::validate();
    my $before = $main::dbv{sha}->cget(-text);
    main::db_save();
    is('SAVE: written to the team folder, a new fingerprint, nothing pending',
       slurp("$team/pipes.dat") =~ /^FIT\|AS\|EL\|.*\|50\|1\.7$/m && $main::dbv{sha}->cget(-text) ne $before
       && !$main::dbv{db}{modified}, $main::dbv{msg}->cget(-text));
    is('   and the model must be validated again: CALCULATE is off', !main::calculate_enabled());
    main::validate();
    main::calculate();
    (my $flat = main::report_text()) =~ s/\s+/ /g;
    is('the report then names the team folder\'s file in full', $flat =~ /\Q$team\E.?pipes\.dat \(team folder\)/, substr($flat, index($flat, 'database:'), 200));
    main::db_use_builtin();
    is('USE BUILT-IN: back to the program\'s own database', $main::dbv{origin}->cget(-text) eq 'BUILT-IN'
       && !defined HardyCross::Settings::get('DATABASE_DIR'));
    is('the real database was never written', slurp('data/pipes.dat') eq $real);
}

print "12. THE GRAPH TAB\n";
{
    my $G = \%main::gv;
    my $model = main::full_text();
    main::select_tab($main::toptabs, 'GRAPH');
    $main::mw->update;
    is('a GRAPH tab, after PROJECT',
       "@{ $main::toptabs->{names} }" =~ /^NETWORK PROJECT GRAPH / && $main::toptabs->{current} eq 'GRAPH');
    main::graph_refresh();
    is('empty: the problems listed, PRINT TO PDF off, nothing drawn but a note',
       $G->{problems}->get(0) =~ /A, THE WATER SUPPLY, NEEDS AT LEAST TWO POINTS/
       && $G->{btn}{PDF}->cget(-state) eq 'disabled'
       && grep { $G->{canvas}->type($_) eq 'text' } $G->{canvas}->find('all'));
    main::graph_open('examples/10_supply_graph.phg');
    $main::mw->update;
    is('OPEN GRAPH fills every field from the file',
       $G->{fields}{JOB}->get eq 'HC-DEMO-010' && $G->{fields}{A3Q}->get eq '3600' && $G->{fields}{D4P}->get eq '290'
       && $G->{fields}{DUTY2D}->get eq 'HYDRANTS - TWO AT 10 L/S', $G->{fields}{A3Q}->get);
    is('   no problems, PRINT TO PDF on, the file named without *',
       $G->{check}{ok} && $G->{btn}{PDF}->cget(-state) eq 'normal' && $G->{file}->cget(-text) eq '10_SUPPLY_GRAPH.PHG',
       $G->{file}->cget(-text));
    my @curves = map { $G->{canvas}->gettags($_) } $G->{canvas}->find('withtag', 'curve');
    is('the preview draws A B C D E', join(' ', sort { $a cmp $b } grep { /^curve[A-E]$/ } keys %{ { map { $_ => 1 } @curves } })
       eq 'curveA curveB curveC curveD curveE');
    my @key = map { $G->{canvas}->itemcget($_, -text) } $G->{canvas}->find('withtag', 'key');
    is('   its key gives each duty against E: 2 has 797 kPa, margin 197',
       grep({ /^2  2400 L\/MIN AT 600 KPA - E HAS 797 KPA, MARGIN 197 KPA/ } @key), "@key");

    # A mistake: shaded, listed, and a click on it goes to it.
    $G->{fields}{A2Q}->delete(0, 'end');
    $G->{fields}{A2Q}->insert(0, '18OO');
    main::graph_refresh();
    is('a bad flow: listed with its row, its fields shaded, PRINT off',
       $G->{problems}->get(0) eq "A ROW 2: FLOW '18OO' IS NOT A NUMBER"
       && lc $G->{fields}{A2Q}->cget(-background) eq lc $main::C{fault_bg}
       && $G->{btn}{PDF}->cget(-state) eq 'disabled', $G->{problems}->get(0));
    is('   the file name gains a *', $G->{file}->cget(-text) eq '10_SUPPLY_GRAPH.PHG *');
    $G->{problems}->selectionSet(0);
    main::graph_go_to_problem();
    $main::mw->update;
    is('   a click on it puts the cursor in the field', $main::mw->focusCurrent eq $G->{fields}{A2Q});
    $G->{fields}{A2Q}->delete(0, 'end');
    $G->{fields}{A2Q}->insert(0, '1800');
    $G->{fields}{DUTY1D}->insert('end', ' level 3');
    main::graph_refresh();
    is('corrected: no problems; text typed is kept in capitals',
       $G->{check}{ok} && $main::graph->{duty}[0][1] eq 'SPRINKLERS - HIGHEST HAZARD AREA LEVEL 3');

    main::graph_pdf("$TMP/graph.pdf");
    is('PRINT TO PDF writes the sheet', -s "$TMP/graph.pdf" && slurp("$TMP/graph.pdf") =~ /^%PDF-.*% PHCP-SHEET PLOT/s);
    main::graph_save("$TMP/g.phg");
    is('SAVE GRAPH writes the .phg, and the * goes',
       slurp("$TMP/g.phg") =~ /^DUTY\s+1500 700 1 SPRINKLERS - HIGHEST HAZARD AREA LEVEL 3$/m
       && $G->{file}->cget(-text) eq 'G.PHG');
    is('the model is untouched by all of it', main::full_text() eq $model);
    main::select_tab($main::toptabs, 'NETWORK');
}

print "13. THE QUICK TOOLS TAB\n";
{
    my ($Q, $W) = (\%main::qt, \%main::qtw);
    my $model = main::full_text();
    main::select_tab($main::toptabs, 'QUICK TOOLS');
    $main::mw->update;
    my $text = sub { $W->{ $_[0] }{result}->get('1.0', 'end - 1 chars') };
    is('a QUICK TOOLS tab: velocity, K-factor, K converter, pressure loss, each asking for its figures',
       $main::toptabs->{current} eq 'QUICK TOOLS' && $text->('VEL') =~ /CHOOSE A SIZE AND GIVE A FLOW/
       && $text->('K') =~ /ANY TWO OF K, Q AND P/ && $text->('KCONV') =~ /GIVE A K/ && $W->{VEL}{problems}->cget(-text) eq '');
    my @sizes = map { $W->{VEL}{size_menu}->entrycget($_, -label) } 0 .. $W->{VEL}{size_menu}->index('end');
    is('SIZE lists the type\'s sizes with their bores', $sizes[0] =~ /^DN20\s+21\.6 MM$/ && grep({ /^DN50\s+53\.0 MM$/ } @sizes), "@sizes[0..2]");
    $W->{VEL}{size_menu}->invoke(4);           # DN50
    $W->{VEL}{field}{FLOW}->insert(0, '500');
    main::tools_update('VEL');
    is('VELOCITY: DN50 at 500 L/min is 3.78 m/s, 53.0 mm bore',
       $text->('VEL') =~ /VELOCITY\s+3\.78 M\/S/ && $text->('VEL') =~ /BORE\s+53\.0 MM/, $text->('VEL'));
    # As the PIPE TYPE drop-down does: the type set, the size cleared.
    ($Q->{VEL}{type}, $Q->{VEL}{size}) = ('BORE', '');
    main::tools_sizes('VEL');
    $main::mw->update;
    is('   BORE: the size becomes a field for the bore in mm',
       $W->{VEL}{size_entry}->ismapped && !$W->{VEL}{size_mb}->ismapped);
    $W->{VEL}{size_entry}->insert(0, '100');
    $W->{VEL}{field}{FLOW}->delete(0, 'end');
    $W->{VEL}{field}{FLOW}->insert(0, '1500');
    main::tools_update('VEL');
    is('   100 mm at 1500 L/min: 3.18 m/s', $text->('VEL') =~ /VELOCITY\s+3\.18 M\/S/);

    $W->{K}{field}{Q}->insert(0, '80');
    $W->{K}{field}{P}->insert(0, '100');
    main::tools_update('K');
    is('K-FACTOR: 80 L/min at 100 kPa gives K = 8', $text->('K') =~ /^K =\s+8\.000 L\/MIN\/KPA\^0\.5/m, $text->('K'));
    $W->{K}{field}{K}->insert(0, '8');
    main::tools_update('K');
    is('   three given: refused, the K field outlined red',
       $W->{K}{problems}->cget(-text) =~ /ONLY TWO/ && lc $W->{K}{field}{K}->cget(-highlightbackground) eq lc $main::C{error});
    $W->{K}{field}{Q}->delete(0, 'end');
    main::tools_update('K');
    is('   cleared Q: solved for it, 80 L/min', $text->('K') =~ /^FLOW Q =\s+80\.00 L\/MIN/m
       && $W->{K}{problems}->cget(-text) eq '');

    $W->{KCONV}{field}{VALUE}->insert(0, '5.6');
    main::tools_update('KCONV');
    is('K CONVERTER: K5.6 US is 80.731 L/min/bar^0.5 and 8.073 per root kPa',
       $text->('KCONV') =~ /METRIC, BAR\s+80\.731/ && $text->('KCONV') =~ /METRIC, KPA\s+8\.073/, $text->('KCONV'));

    $Q->{LOSS}{size} = 65;
    $W->{LOSS}{field}{FLOW}->insert(0, '1000');
    $W->{LOSS}{field}{LENGTH}->insert(0, '25');
    main::tools_update('LOSS');
    is('PRESSURE LOSS: DN65 at 1000 L/min, both formulas, per metre and over 25 m',
       $text->('LOSS') =~ /LOSS, KPA\/M\s+3\.4617\s+2\.79\d\d/ && $text->('LOSS') =~ /LOSS OVER 25 M\s+86\.54\s+69\.9\d/,
       $text->('LOSS'));
    $W->{LOSS}{field}{C}->insert(0, 'C1OO');
    main::tools_update('LOSS');
    is('   a bad C: named, outlined red, no answer',
       $W->{LOSS}{problems}->cget(-text) =~ /C FACTOR 'C1OO' IS NOT A NUMBER/
       && lc $W->{LOSS}{field}{C}->cget(-highlightbackground) eq lc $main::C{error}
       && $text->('LOSS') =~ /NO ANSWER/);
    is('the model is untouched by all of it', main::full_text() eq $model);
    main::select_tab($main::toptabs, 'NETWORK');
}

$main::mw->destroy;
print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
