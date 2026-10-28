#!/usr/bin/perl
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# phcp_editor.pl -- the PHCP text editor.
#
#   perl phcp_editor.pl [model.phc | model.hcx]
#
# Two panes: EDITOR on the left, where the model is typed as .phc command
# lines, and REPORT on the right, filled by F5.  Below them a status bar and
# two lists: PROBLEMS, and UNDEFINED NODES.
#
# THIS FILE IS ONLY THE WINDOW.  Every decision -- is this line good, what is
# the next line likely to be, what goes in the pick list, what did the solve
# give for this pipe -- is made by HardyCross::Editor, which has no Tk in it
# and is tested headless by tools/test_editor.pl.  What is here is drawing,
# keys and files.  tools/test_editor_window.pl drives this window under a
# virtual display; it loads this file without starting the event loop (see
# the last lines) and calls the handlers below directly.
#
# Layout of this file:
#   colours and fonts          the light blue and black scheme, named once
#   build_window               the widgets
#   recolour / update_status   colouring, problems, the status bar
#   proposals                  the greyed next line, accepted by Enter or Tab
#   pick_list                  Ctrl+Space
#   solve / results            F5, and figures for the cursor's line
#   files                      NEW OPEN SAVE SAVE AS WRITE REPORT
#==============================================================================
use strict;
use warnings;
use FindBin;
use lib $FindBin::Bin;
use Tk;
use Tk::Panedwindow;
# TextUndo, not Text: Perl/Tk's Text accepts -undo but never records an edit,
# so Ctrl+Z did nothing.  TextUndo keeps its own record of every insert and
# delete, and undoes them one at a time.
use Tk::TextUndo;
use HardyCross;
use HardyCross::Editor;

#------------------------------------------------------------------------------
# Colours and fonts.
#
# Light blue paper and black ink, the scheme of a Perl textbook: a pale blue
# page with black type, and a black band for the status line.  Command words
# are dark blue and bold, comments grey, errors red -- each dark enough to
# read on the pale blue.
#------------------------------------------------------------------------------
our %C = (
    paper    => '#D6EAF8',     # editor and report background: pale blue
    chrome   => '#AED6F1',     # frames, headings and lists: a deeper blue
    ink      => '#000000',     # text
    band     => '#000000',     # status bar background
    band_ink => '#D6EAF8',     # status bar text
    command  => '#002B7F',     # command words
    comment  => '#4D5656',     # comments
    error    => '#B00020',     # a line in error
    proposal => '#5D7FA3',     # the greyed proposed line
    current  => '#FFFFFF',     # the current field in the status bar
    select   => '#85C1E9',     # selection
);
our $MONO   = ['Courier', 11];
our $MONO_B = ['Courier', 11, 'bold'];
our $UI_B   = ['Helvetica', 10, 'bold'];

# The window's state.  One editor window per process, so plain package
# variables, each named for what it holds.
our ($mw, $ed, $report, $statusbar, $problems, $undefined);
our $path;               # the file being edited, or undef for a new buffer
our $suggest;            # the name SAVE AS offers for a converted .hcx
our $solved;             # { net, converged, text } from the last good solve
our $saved_text = '';    # the text as last opened or saved: "modified" is
                         # simply the buffer differing from it
our $recolour_job;       # the pending delayed re-check, so typing stays smooth
our @problem_lines;      # the line each PROBLEMS entry goes to
our @undefined_lines;    # the line each UNDEFINED NODES entry goes to
our %prop = (active => 0);   # the proposal on show, if any
our $notice;             # [ text, bad, where ]: a message that stays in the
                         # status bar until the text or the cursor changes

#==============================================================================
# build_window -- create every widget.  Returns the main window.
#==============================================================================
sub build_window {
    $mw = MainWindow->new(-background => $C{chrome});
    $mw->geometry('1400x860');
    $mw->optionAdd('*Font', $UI_B);
    build_menus();

    # The two panes, side by side, the divider movable.
    my $pw = $mw->Panedwindow(-orient => 'horizontal', -background => $C{chrome},
                              -sashwidth => 6, -showhandle => 0);
    my $left  = $mw->Frame(-background => $C{chrome});
    my $right = $mw->Frame(-background => $C{chrome});
    heading($left, 'EDITOR');
    heading($right, 'REPORT');
    $ed = $left->Scrolled('TextUndo', -scrollbars => 'se', -wrap => 'none',
        -font => $MONO, -background => $C{paper}, -foreground => $C{ink},
        -insertbackground => $C{ink}, -selectbackground => $C{select},
        -insertwidth => 2, -borderwidth => 0, -highlightthickness => 0)
        ->pack(-fill => 'both', -expand => 1);
    $report = $right->Scrolled('Text', -scrollbars => 'se', -wrap => 'none',
        -font => $MONO, -background => $C{paper}, -foreground => $C{ink},
        -selectbackground => $C{select}, -borderwidth => 0, -highlightthickness => 0,
        -state => 'disabled')->pack(-fill => 'both', -expand => 1);
    # The editor starts a little under half the width; the report takes the
    # rest, being 132 columns wide.
    $pw->add($left, -width => 620);
    $pw->add($right);

    # The status bar: the command's field template with the current field
    # highlighted, then the message or the solved figures.  A one-line Text,
    # not a Label, so one field can be drawn differently from the rest.
    $statusbar = $mw->Text(-height => 1, -wrap => 'none', -font => $MONO,
        -background => $C{band}, -foreground => $C{band_ink}, -borderwidth => 0,
        -highlightthickness => 0, -state => 'disabled', -cursor => 'left_ptr');
    $statusbar->tagConfigure('current', -foreground => $C{band}, -background => $C{current},
                             -font => $MONO_B);
    $statusbar->tagConfigure('bad', -foreground => '#FF8A80');

    # The lists under the panes.
    my $lists = $mw->Frame(-background => $C{chrome});
    my $pf = $lists->Frame(-background => $C{chrome});
    my $uf = $lists->Frame(-background => $C{chrome});
    heading($pf, 'PROBLEMS');
    heading($uf, 'UNDEFINED NODES');
    $problems  = list_box($pf);
    $undefined = list_box($uf);
    $pf->pack(-side => 'left', -fill => 'both', -expand => 1);
    $uf->pack(-side => 'left', -fill => 'both', -padx => [6, 0]);
    $problems->bind('<ButtonRelease-1>' => sub { go_to_list($problems, \@problem_lines) });
    $undefined->bind('<ButtonRelease-1>' => sub { go_to_list($undefined, \@undefined_lines) });

    # Packed bottom-up so the panes take whatever height is left.
    $lists->pack(-side => 'bottom', -fill => 'x', -padx => 6, -pady => [0, 6]);
    $statusbar->pack(-side => 'bottom', -fill => 'x', -padx => 6, -pady => 4);
    $pw->pack(-side => 'top', -fill => 'both', -expand => 1, -padx => 6, -pady => [6, 0]);

    # Colouring.  The error tag is raised above the others so a line in error
    # is red all the way along, command word included.
    $ed->tagConfigure('command', -foreground => $C{command}, -font => $MONO_B);
    $ed->tagConfigure('comment', -foreground => $C{comment});
    $ed->tagConfigure('error', -foreground => $C{error});
    $ed->tagConfigure('proposal', -foreground => $C{proposal});
    $ed->tagRaise('error');
    $ed->tagRaise('proposal');

    bind_keys();
    set_title();
    update_status();
    $ed->focus;
    return $mw;
}

# heading -- a capitalised label over a pane or list.
sub heading {
    my ($parent, $text) = @_;
    $parent->Label(-text => $text, -font => $UI_B, -anchor => 'w',
                   -background => $C{chrome}, -foreground => $C{ink})
           ->pack(-side => 'top', -fill => 'x');
}

# list_box -- a short scrolled list in the scheme's colours.
sub list_box {
    my $parent = shift;
    return $parent->Scrolled('Listbox', -scrollbars => 'oe', -height => 5,
        -font => $MONO, -background => $C{paper}, -foreground => $C{ink},
        -selectbackground => $C{select}, -borderwidth => 0, -highlightthickness => 0,
        -activestyle => 'none')->pack(-fill => 'both', -expand => 1);
}

#------------------------------------------------------------------------------
# Menus.  Labels in capitals, as the rest of PHCP.
#------------------------------------------------------------------------------
sub build_menus {
    my $bar = $mw->Menu(-type => 'menubar');
    $mw->configure(-menu => $bar);
    my $file = $bar->cascade(-label => 'FILE', -tearoff => 0);
    $file->command(-label => 'NEW',          -accelerator => 'Ctrl+N', -command => \&file_new);
    $file->command(-label => 'OPEN...',      -accelerator => 'Ctrl+O', -command => \&file_open);
    $file->command(-label => 'SAVE',         -accelerator => 'Ctrl+S', -command => \&file_save);
    $file->command(-label => 'SAVE AS...',                             -command => \&file_save_as);
    $file->separator;
    $file->command(-label => 'WRITE REPORT...', -accelerator => 'Ctrl+R', -command => \&file_report);
    $file->separator;
    $file->command(-label => 'QUIT',         -accelerator => 'Ctrl+Q', -command => \&file_quit);
    my $edit = $bar->cascade(-label => 'EDIT', -tearoff => 0);
    $edit->command(-label => 'UNDO',      -accelerator => 'Ctrl+Z', -command => \&undo);
    $edit->command(-label => 'REDO',      -accelerator => 'Ctrl+Y', -command => \&redo);
    $edit->separator;
    $edit->command(-label => 'PICK LIST', -accelerator => 'Ctrl+Space', -command => \&pick_list);
    my $model = $bar->cascade(-label => 'MODEL', -tearoff => 0);
    $model->command(-label => 'SOLVE', -accelerator => 'F5', -command => \&solve);
}

#------------------------------------------------------------------------------
# bind_keys -- the editor's own keys.
#
# Our bindings go on a tag placed FIRST in the text widget's bindtags, so they
# run before the Text class bindings and can stop them (Tk->break) -- Enter
# must not insert its newline before the proposal is dealt with, for one.
#------------------------------------------------------------------------------
sub bind_keys {
    my $t = text_widget();
    $t->bindtags([ 'PhcEditor', $t->bindtags ]);
    $mw->bind('PhcEditor', '<Return>'       => sub { on_return(); Tk->break });
    $mw->bind('PhcEditor', '<Tab>'          => sub { on_tab() and Tk->break });
    $mw->bind('PhcEditor', '<KeyPress>'     => \&on_key);
    $mw->bind('PhcEditor', '<ButtonPress>'  => sub { discard_proposal() });
    $mw->bind('PhcEditor', '<KeyRelease>'   => sub { after_change() });
    $mw->bind('PhcEditor', '<ButtonRelease>' => sub { update_status() });
    $mw->bind('PhcEditor', '<Control-space>' => sub { pick_list(); Tk->break });
    $mw->bind('PhcEditor', '<Control-z>'    => sub { undo(); Tk->break });
    $mw->bind('PhcEditor', '<Control-y>'    => sub { redo(); Tk->break });
    # Wrapped, not passed as \&name: Tk calls a bound sub with the widget as
    # its first argument, and file_open would take that for a file name.
    $mw->bind('<F5>'        => sub { solve() });
    $mw->bind('<Control-n>' => sub { file_new() });
    $mw->bind('<Control-o>' => sub { file_open() });
    $mw->bind('<Control-s>' => sub { file_save() });
    $mw->bind('<Control-r>' => sub { file_report() });
    $mw->bind('<Control-q>' => sub { file_quit() });
    $mw->protocol('WM_DELETE_WINDOW' => \&file_quit);
}

# text_widget -- the Text inside the Scrolled frame, where keys arrive.
sub text_widget { $ed->Subwidget('scrolled') }

#==============================================================================
# Buffer helpers.
#==============================================================================

# buffer -- the model text, without a proposal that is only on offer.
sub buffer {
    my $t = $ed->get('1.0', 'end - 1 chars');
    return $t unless $prop{active};
    my $s = $ed->index('pstart');
    my $e = $ed->index('pend');
    my $before = $ed->get('1.0', $s);
    my $after  = $ed->get($e, 'end - 1 chars');
    return $before . $after;
}

# set_buffer -- replace the whole text, as when a file is opened.
sub set_buffer {
    my $text = shift;
    discard_proposal();
    $ed->delete('1.0', 'end');
    $ed->insert('1.0', $text);
    text_widget()->ResetUndo;    # undo does not reach back past an open
    $saved_text = $text;
    $ed->markSet('insert', '1.0');
    $solved = undef;
    clear_report();
    recolour();
}

# cursor -- (line, column) of the insertion point.
sub cursor { split /\./, $ed->index('insert') }

# go_to_line -- put the cursor at the start of line $n and show it.
sub go_to_line {
    my $n = shift or return;
    $ed->markSet('insert', "$n.0");
    $ed->see("$n.0");
    $ed->tagRemove('sel', '1.0', 'end');
    $ed->tagAdd('sel', "$n.0", "$n.0 lineend");
    $ed->focus;
    update_status();
}

sub go_to_list {
    my ($lb, $lines) = @_;
    my ($i) = $lb->curselection;
    go_to_line($lines->[$i]) if defined $i;
}

#==============================================================================
# Colouring, the problems lists, the status bar.
#==============================================================================

# after_change -- after a key: the status bar at once, the full re-check
# shortly after typing pauses.
sub after_change {
    update_status();
    $recolour_job->cancel if $recolour_job;
    $recolour_job = $mw->after(250, sub { $recolour_job = undef; recolour() });
    set_title();
}

# recolour -- re-check every line; colour it and refill the two lists.
sub recolour {
    my $text = buffer();
    my ($line) = cursor();
    my $res = HardyCross::Editor::check_buffer($text, $line);
    my @l = split /\n/, $text, -1;
    $ed->tagRemove($_, '1.0', 'end') for qw(command comment error);
    for my $i (1 .. @l) {
        for my $s (HardyCross::Editor::colour_spans($l[ $i - 1 ])) {
            my ($a, $b, $tag) = @$s;
            $ed->tagAdd($tag, "$i.$a", "$i.$b");
        }
        my $st = $res->{lines}[$i]{status};
        # An incomplete line is still being typed while the cursor is on it;
        # anywhere else it is as wrong as an error and shows red.
        $ed->tagAdd('error', "$i.0", "$i.0 lineend")
            if $st eq 'error' || ($st eq 'incomplete' && $i != $line);
    }
    $problems->delete(0, 'end');
    @problem_lines = ();
    for my $p (@{ $res->{problems} }) {
        $problems->insert('end', sprintf('LINE %-5d %s', $p->{line}, $p->{message}));
        push @problem_lines, $p->{line};
    }
    $undefined->delete(0, 'end');
    @undefined_lines = ();
    for my $u (@{ $res->{undefined} }) {
        $undefined->insert('end', sprintf('%-12s FIRST USED ON LINE %d', $u->{node}, $u->{line}));
        push @undefined_lines, $u->{line};
    }
    return $res;
}

# update_status -- the status bar for the cursor's line.
#
# The field template, with the field the cursor is in highlighted; then the
# line's message if it has one, or else the solved figures for the element on
# the line (after a solve).  Figures from a solve of an earlier version of the
# buffer are marked as such.
sub update_status {
    my $text = buffer();
    my ($n, $col) = cursor();
    # A message (solved, saved, converted ...) stays until something changes;
    # otherwise the key release that follows F5 would wipe "solved" at once.
    if ($notice) {
        return if $notice->[2] eq where($text);
        $notice = undef;
    }
    my $st = HardyCross::Editor::status_at($text, $n, $col);
    $statusbar->configure(-state => 'normal');
    $statusbar->delete('1.0', 'end');
    $statusbar->insert('end', ' ');
    if (my $t = $st->{template}) {
        if ($t->{command}) {
            $statusbar->insert('end', uc($t->{command}) . ' ');
            my @f = @{ $t->{fields} };
            for my $i (0 .. $#f) {
                $statusbar->insert('end', $f[$i], ($i == $t->{current} ? 'current' : ()));
                $statusbar->insert('end', ' ');
            }
        }
    }
    my $extra;
    if ($st->{status} ne 'ok' && length $st->{message}) {
        $extra = [ uc $st->{message}, 'bad' ];
    } elsif ($solved) {
        my @l = split /\n/, $text, -1;
        my $r = HardyCross::Editor::results_at($solved->{net}, $l[ $n - 1 ]);
        $r .= '   (SOLVED BEFORE THE LATEST EDITS)' if defined $r && $text ne $solved->{text};
        $extra = [ $r ] if defined $r;
    }
    $statusbar->insert('end', '|  ' . $extra->[0], ($extra->[1] ? $extra->[1] : ())) if $extra;
    $statusbar->configure(-state => 'disabled');
    return $st;
}

# status_text -- what the status bar shows, as plain text (for the tests).
sub status_text { my $s = $statusbar->get('1.0', 'end - 1 chars'); $s =~ s/\s+$//; $s }

# where -- the buffer and cursor, as one string: a message stays while this
# is unchanged.
sub where { my $text = shift // buffer(); return join "\x00", $ed->index('insert'), $text }

# message -- a message in the status bar, kept until the text or cursor moves.
sub message {
    my ($text, $bad) = @_;
    $notice = [ $text, $bad, where() ];
    $statusbar->configure(-state => 'normal');
    $statusbar->delete('1.0', 'end');
    $statusbar->insert('end', ' ' . uc($text), ($bad ? 'bad' : ()));
    $statusbar->configure(-state => 'disabled');
}

#==============================================================================
# Proposals.
#
# After Enter the likely next line is shown greyed at the cursor.  Enter or Tab
# accepts it (Enter also starts the next line, and offers the one after, so
# holding Enter lays down a run of pipes); any other key discards it and then
# does what it normally does.  The proposal sits between the marks pstart and
# pend, tagged 'proposal'; buffer() leaves it out until it is accepted.
#
# The grey text is put in and taken out with the plain Tk::Text insert and
# delete, which TextUndo does not record: a proposal that was only offered
# must not come back as real text on Ctrl+Z.  When it is accepted it is taken
# out the same way and typed back in with the recorded insert, so undo removes
# an accepted line like any other.
#==============================================================================

sub on_return {
    accept_proposal() if $prop{active};
    $ed->insert('insert', "\n");
    $ed->see('insert');
    offer_proposal();
    after_change();
}

# on_tab -- accept a proposal; otherwise let Tab insert itself.  Returns true
# when it handled the key.
sub on_tab {
    return 0 unless $prop{active};
    accept_proposal();
    after_change();
    return 1;
}

# on_key -- any other key discards the proposal first.  Modifier keys alone
# (Shift, Control) do not: they arrive before the key they modify.
sub on_key {
    my $w = shift;
    my $ev = $w->XEvent;
    my $sym = $ev ? $ev->K : '';
    return if $sym =~ /^(Shift|Control|Alt|Meta|Super|Caps_Lock|Return|Tab)/;
    discard_proposal();
}

sub offer_proposal {
    my ($n) = cursor();
    my $p = HardyCross::Editor::proposal(buffer(), $n - 1) // return;
    # Only on an empty line: never push grey text into the middle of a line.
    return if $ed->get('insert linestart', 'insert lineend') =~ /\S/;
    my $t = text_widget();
    $ed->markSet('pstart', 'insert');
    $ed->markGravity('pstart', 'left');
    $t->Tk::Text::insert('insert', $p, 'proposal');
    $ed->markSet('pend', 'insert');
    $ed->markGravity('pend', 'right');
    $ed->markSet('insert', 'pstart');
    $prop{active} = 1;
}

sub accept_proposal {
    return unless $prop{active};
    my $t = text_widget();
    my $p = $ed->get('pstart', 'pend');
    my $at = $ed->index('pstart');
    $t->Tk::Text::delete('pstart', 'pend');
    $prop{active} = 0;
    $ed->insert($at, $p);
    $ed->markSet('insert', "$at + " . length($p) . ' chars');
}

sub discard_proposal {
    return unless $prop{active};
    text_widget()->Tk::Text::delete('pstart', 'pend');
    $prop{active} = 0;
}

#==============================================================================
# Pick list, Ctrl+Space.
#
# In a Use type field or a Pipe's fittings, a list of the codes from the pipe
# and fitting database with their descriptions.  Arrows move, Enter or a
# double-click inserts the code over any part already typed, Escape closes.
#==============================================================================
sub pick_list {
    discard_proposal();
    my ($n, $col) = cursor();
    my $ch = HardyCross::Editor::choices(buffer(), $n, $col);
    unless (@$ch) {
        message('no pick list here: Ctrl+Space works in a Use type or a pipe fitting field');
        return;
    }
    my $top = $mw->Toplevel(-background => $C{chrome});
    $top->title('PICK LIST');
    $top->transient($mw);
    my $lb = $top->Scrolled('Listbox', -scrollbars => 'oe', -height => 12, -width => 60,
        -font => $MONO, -background => $C{paper}, -foreground => $C{ink},
        -selectbackground => $C{select}, -activestyle => 'none')
        ->pack(-fill => 'both', -expand => 1, -padx => 4, -pady => 4);
    $lb->insert('end', sprintf('%-6s %s', @$_)) for @$ch;
    $lb->selectionSet(0);
    $lb->activate(0);
    my $choose = sub {
        my ($i) = $lb->curselection;
        $top->destroy;
        insert_choice($ch->[$i][0]) if defined $i;
    };
    $lb->bind('<Return>' => $choose);
    $lb->bind('<Double-ButtonRelease-1>' => $choose);
    $lb->bind('<Escape>' => sub { $top->destroy });
    # Open beside the cursor.
    my @bb = $ed->bbox('insert');
    if (@bb) {
        my ($x, $y) = ($ed->rootx + $bb[0], $ed->rooty + $bb[1] + $bb[3] + 2);
        $top->geometry("+$x+$y");
    }
    $lb->focus;
    return $top;
}

# insert_choice -- put a picked code at the cursor, replacing the part of the
# word already typed before it ("G" + GV gives "GV", not "GGV").
sub insert_choice {
    my $code = shift;
    my $start = $ed->index('insert');
    my $before = $ed->get('insert linestart', 'insert');
    if ($before =~ /(\S+)\z/ && index(uc $code, uc $1) == 0) {
        $start = $ed->index('insert - ' . length($1) . ' chars');
    }
    $ed->delete($start, 'insert');
    $ed->insert('insert', $code);
    $ed->focus;
    after_change();
}

#==============================================================================
# Solve, F5.
#==============================================================================
sub solve {
    discard_proposal();
    my $text = buffer();
    my $r = HardyCross::Editor::solve_text($text, $path // $suggest);
    if (!$r->{ok}) {
        $solved = undef;
        fill_report("THE MODEL WAS NOT SOLVED\n\n$r->{error}\n");
        go_to_line($r->{line}) if $r->{line};
        message($r->{error}, 1);
        return $r;
    }
    $solved = { net => $r->{net}, converged => $r->{converged}, text => $text };
    fill_report($r->{report});
    message($r->{converged} ? 'solved - converged' : 'solved - DID NOT CONVERGE: the results must not be used',
            !$r->{converged});
    return $r;
}

sub fill_report {
    my $text = shift;
    $report->configure(-state => 'normal');
    $report->delete('1.0', 'end');
    $report->insert('1.0', $text);
    $report->configure(-state => 'disabled');
}
sub clear_report { fill_report('') }
sub report_text  { $report->get('1.0', 'end - 1 chars') }

#==============================================================================
# Files.
#==============================================================================

# set_title -- the file name, and * when there are unsaved changes.
sub set_title {
    my $name = $path // ($suggest ? "$suggest (not saved)" : 'untitled.phc');
    $name =~ s{.*[/\\]}{};
    $mw->title('PHCP EDITOR - ' . $name . ($ed && modified() ? ' *' : ''));
}

# modified -- whether the buffer differs from what was last opened or saved.
sub modified { buffer() ne $saved_text }

# ok_to_discard -- true if there are no unsaved changes, or the user agrees
# to lose them.
sub ok_to_discard {
    return 1 unless modified();
    my $a = $mw->messageBox(-title => 'UNSAVED CHANGES', -icon => 'warning', -type => 'YesNo',
        -message => 'The model has unsaved changes.  Discard them?');
    return lc($a) eq 'yes';
}

sub file_new {
    return unless ok_to_discard();
    ($path, $suggest) = (undef, undef);
    set_buffer('');
    set_title();
}

sub file_open {
    my $f = shift;
    return unless ok_to_discard();
    $f //= $mw->getOpenFile(-filetypes => [ [ 'PHCP model', [ '.phc', '.hcx' ] ], [ 'All files', '*' ] ]);
    return unless defined $f && length $f;
    open_path($f);
}

# open_path -- load a file into the editor.  A .hcx is converted into a new,
# unsaved .phc buffer, and the status bar says so.
sub open_path {
    my $f = shift;
    my $r = eval { HardyCross::Editor::load_file($f) };
    unless ($r) {
        my $e = $@;
        message(HardyCross::is_model_error($e) ? $e->{msg} : "$e", 1);
        return;
    }
    ($path, $suggest) = ($r->{path}, $r->{suggest});
    set_buffer($r->{text});
    if ($r->{converted}) {
        $saved_text = '';           # it has not been saved as .phc yet
        message($r->{note});
    }
    set_title();
    return $r;
}

sub file_save {
    return file_save_as() unless defined $path;
    write_buffer($path);
}

sub file_save_as {
    my $f = shift // $mw->getSaveFile(-defaultextension => '.phc',
        -initialfile => ($suggest // $path // 'untitled.phc') =~ s{.*[/\\]}{}r,
        -filetypes => [ [ 'PHCP model', '.phc' ] ]);
    return unless defined $f && length $f;
    write_buffer($f) and ($path, $suggest) = ($f, undef);
    set_title();
}

# write_buffer -- save the text, ending with a newline.
sub write_buffer {
    my $f = shift;
    my $text = buffer();
    $text .= "\n" unless $text =~ /\n\z/;
    my $fh;
    unless (open $fh, '>', $f) { message("cannot write $f: $!", 1); return 0 }
    print $fh $text;
    close $fh;
    $saved_text = buffer();
    message("saved $f");
    set_title();
    return 1;
}

# file_report -- solve if the last solve is not of this text, then write the
# report as .pdf or .txt by the extension chosen.
sub file_report {
    my $out = shift;
    my $text = buffer();
    unless ($solved && $solved->{text} eq $text) {
        my $r = solve();
        return unless $r->{ok};
    }
    $out //= $mw->getSaveFile(-defaultextension => '.pdf',
        -initialfile => (($path // $suggest // 'untitled.phc') =~ s{.*[/\\]}{}r) =~ s/\.phc\z//r . '_report.pdf',
        -filetypes => [ [ 'PDF report', '.pdf' ], [ 'Text report', '.txt' ] ]);
    return unless defined $out && length $out;
    my $ok = eval { HardyCross::Editor::write_report_file($solved->{net}, $solved->{converged},
                                                         $path // $suggest // 'untitled.phc', $out) };
    message($ok ? "report written to $out" : 'report not written: ' . ($@ && (ref $@ ? $@->{msg} : $@)), !$ok);
    return $ok;
}

sub file_quit {
    return unless ok_to_discard();
    $mw->destroy;
}

# undo / redo -- one recorded edit at a time.  TextUndo complains on an empty
# record; that is not an error worth showing, so it is caught.
sub undo { discard_proposal(); eval { text_widget()->undo }; after_change() }
sub redo { discard_proposal(); eval { text_widget()->redo }; after_change() }

#==============================================================================
# Start.  Run as a program, build the window and enter the event loop.  A test
# that only wants the subs sets $main::PHCP_EDITOR_LOAD_ONLY before loading
# this file, and then builds and drives the window itself.
#
# An explicit flag, not "unless caller": a packaged phcp_editor.exe runs this
# script from inside the packager's loader, where caller is set too, and the
# packaged editor then opened no window at all and exited.
#==============================================================================
sub main {
    my $file = shift;
    build_window();
    open_path($file) if defined $file;
    MainLoop;
}
main(@ARGV) unless $main::PHCP_EDITOR_LOAD_ONLY;

1;
