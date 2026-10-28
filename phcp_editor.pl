#!/usr/bin/perl
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# phcp_editor.pl -- the PHCP text editor.
#
#   perl phcp_editor.pl [model.phc]
#
#   +--------------------------------------+------------------+
#   | EDITOR - the model as .phc commands  | ERRORS           |
#   |                                      | WARNINGS         |
#   | command strip:  TITLE PROJECT ...    | NODES            |
#   | status bar: the field template       |                  |
#   +--------------------------------------+------------------+
#   | PIPES | NODES | OUTLETS | REPORT  - results, in sortable columns  |
#   | [ ] HIDE NON-FLOWING PIPES   [ ] HIDE INACTIVE NODES               |
#   +--------------------------------------------------------------------+
#
# THIS FILE IS ONLY THE WINDOW.  Every decision -- is this line good, what is
# the next line likely to be, what goes in a pick list or a table, what does
# a warning say -- is made by HardyCross::Editor, which has no Tk in it and is
# tested headless by tools/test_editor.pl.  What is here is drawing, keys and
# files.  tools/test_editor_window.pl drives this window under a virtual
# display; it loads this file without starting the event loop (see the last
# lines) and calls the handlers below directly.
#
# Layout of this file:
#   colours and fonts          the light blue and black scheme, named once
#   build_window               the widgets
#   recolour / update_status   colouring, the three lists, the status bar
#   command strip              the commands, a click starts a line
#   tables                     the results: sort, column chooser, hide boxes
#   proposals                  the greyed next line, accepted by Enter or Tab
#   pick_list                  Ctrl+Space
#   solve                      F5
#   properties                 FILE > PROPERTIES: the file's units
#   files                      NEW OPEN SAVE SAVE AS WRITE REPORT
#==============================================================================
use strict;
use warnings;
use FindBin;
use lib $FindBin::Bin;
use Tk;
use Tk::Panedwindow;
use Tk::NoteBook;
use Tk::HList;
use Tk::ItemStyle;
use Tk::BrowseEntry;
# TextUndo, not Text: Perl/Tk's Text accepts -undo but never records an edit,
# so Ctrl+Z did nothing.  TextUndo keeps its own record of every insert and
# delete, and undoes them one at a time.
use Tk::TextUndo;
use HardyCross;
use HardyCross::Phc;
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
    paper    => '#D6EAF8',     # editor, lists and tables: pale blue
    chrome   => '#AED6F1',     # frames and headings: a deeper blue
    ink      => '#000000',     # text
    band     => '#000000',     # status bar background
    band_ink => '#D6EAF8',     # status bar text
    command  => '#002B7F',     # command words
    comment  => '#4D5656',     # comments
    error    => '#B00020',     # a line in error
    warn     => '#7E5109',     # a warning
    proposal => '#5D7FA3',     # the greyed proposed line
    current  => '#FFFFFF',     # the current field in the status bar
    select   => '#85C1E9',     # selection
);
our $MONO   = ['Courier', 11];
our $MONO_B = ['Courier', 11, 'bold'];
our $UI_B   = ['Helvetica', 10, 'bold'];

# The window's state.  One editor window per process, so plain package
# variables, each named for what it holds.
our ($mw, $ed, $report, $statusbar, $book, $strip);
our (%list, %list_lines);        # ERRORS, WARNINGS, NODES: listbox, and its lines
our (%table);                    # PIPES, NODES, OUTLETS: { hlist, data, sort, desc }
our %pipe_show;                  # the pipe columns shown, by key
our ($hide_pipes, $hide_nodes) = (0, 0);
our $path;                       # the file being edited, or undef for a new buffer
our $solved;                     # { net, converged, text } from the last good solve
our $saved_text = '';            # the text as last opened or saved: "modified" is
                                 # simply the buffer differing from it
our $recolour_job;               # the pending delayed re-check, so typing stays smooth
our %prop = (active => 0);       # the proposal on show, if any
our $notice;                     # [ text, bad, where ]: a message that stays in the
                                 # status bar until the text or the cursor changes

#==============================================================================
# build_window -- create every widget.  Returns the main window.
#==============================================================================
sub build_window {
    $mw = MainWindow->new(-background => $C{chrome});
    $mw->geometry('1500x950');
    $mw->optionAdd('*Font', $UI_B);
    build_menus();

    # Top and bottom, the divider movable: the editor area above, the
    # results below.
    my $vp = $mw->Panedwindow(-orient => 'vertical', -background => $C{chrome}, -sashwidth => 6);
    my $top = $mw->Frame(-background => $C{chrome});
    my $bottom = $mw->Frame(-background => $C{chrome});

    # Above: the editor and its strip and status bar, with the three lists
    # to the right.
    my $hp = $top->Panedwindow(-orient => 'horizontal', -background => $C{chrome}, -sashwidth => 6);
    my $left  = $top->Frame(-background => $C{chrome});
    my $right = $top->Frame(-background => $C{chrome});
    heading($left, 'EDITOR');
    $statusbar = $left->Text(-height => 1, -wrap => 'none', -font => $MONO,
        -background => $C{band}, -foreground => $C{band_ink}, -borderwidth => 0,
        -highlightthickness => 0, -state => 'disabled', -cursor => 'left_ptr')
        ->pack(-side => 'bottom', -fill => 'x', -pady => [4, 0]);
    $statusbar->tagConfigure('current', -foreground => $C{band}, -background => $C{current},
                             -font => $MONO_B);
    $statusbar->tagConfigure('bad', -foreground => '#FF8A80');
    build_strip($left);
    $ed = $left->Scrolled('TextUndo', -scrollbars => 'se', -wrap => 'none',
        -font => $MONO, -background => $C{paper}, -foreground => $C{ink},
        -insertbackground => $C{ink}, -selectbackground => $C{select},
        -insertwidth => 2, -borderwidth => 0, -highlightthickness => 0)
        ->pack(-fill => 'both', -expand => 1);
    for my $name (qw(ERRORS WARNINGS NODES)) {
        my $f = $right->Frame(-background => $C{chrome})->pack(-fill => 'both', -expand => 1);
        heading($f, $name);
        $list{$name} = $f->Scrolled('Listbox', -scrollbars => 'osoe', -height => 6,
            -font => $MONO, -background => $C{paper},
            -foreground => $name eq 'ERRORS' ? $C{error} : $name eq 'WARNINGS' ? $C{warn} : $C{ink},
            -selectbackground => $C{select}, -borderwidth => 0, -highlightthickness => 0,
            -activestyle => 'none')->pack(-fill => 'both', -expand => 1);
        $list_lines{$name} = [];
        my $n = $name;
        $list{$name}->bind('<ButtonRelease-1>' => sub { go_to_list($n) });
    }
    $hp->add($left, -width => 1060);
    $hp->add($right);
    $hp->pack(-fill => 'both', -expand => 1);

    # Below: the results, one tab each, with the HIDE boxes under them.
    build_results($bottom);
    $vp->add($top, -height => 560);
    $vp->add($bottom);
    $vp->pack(-fill => 'both', -expand => 1, -padx => 6, -pady => 6);

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

# heading -- a capitalised label over a pane, list or table.
sub heading {
    my ($parent, $text) = @_;
    $parent->Label(-text => $text, -font => $UI_B, -anchor => 'w',
                   -background => $C{chrome}, -foreground => $C{ink})
           ->pack(-side => 'top', -fill => 'x');
}

#------------------------------------------------------------------------------
# Menus.  Labels in capitals, as the rest of PHCP.
#------------------------------------------------------------------------------
sub build_menus {
    my $bar = $mw->Menu(-type => 'menubar');
    $mw->configure(-menu => $bar);
    my $file = $bar->cascade(-label => 'FILE', -tearoff => 0);
    $file->command(-label => 'NEW',             -accelerator => 'CTRL+N', -command => sub { file_new() });
    $file->command(-label => 'OPEN...',         -accelerator => 'CTRL+O', -command => sub { file_open() });
    $file->command(-label => 'SAVE',            -accelerator => 'CTRL+S', -command => sub { file_save() });
    $file->command(-label => 'SAVE AS...',                                -command => sub { file_save_as() });
    $file->separator;
    $file->command(-label => 'PROPERTIES - UNITS...',                     -command => sub { properties() });
    $file->separator;
    $file->command(-label => 'WRITE REPORT...', -accelerator => 'CTRL+R', -command => sub { file_report() });
    $file->separator;
    $file->command(-label => 'QUIT',            -accelerator => 'CTRL+Q', -command => sub { file_quit() });
    my $edit = $bar->cascade(-label => 'EDIT', -tearoff => 0);
    $edit->command(-label => 'UNDO',      -accelerator => 'CTRL+Z',     -command => sub { undo() });
    $edit->command(-label => 'REDO',      -accelerator => 'CTRL+Y',     -command => sub { redo() });
    $edit->separator;
    $edit->command(-label => 'PICK LIST', -accelerator => 'CTRL+SPACE', -command => sub { pick_list() });
    my $model = $bar->cascade(-label => 'MODEL', -tearoff => 0);
    $model->command(-label => 'SOLVE', -accelerator => 'F5', -command => sub { solve() });
}

#------------------------------------------------------------------------------
# bind_keys -- the editor's own keys.
#
# Our bindings go on a tag placed FIRST in the text widget's bindtags, so they
# run before the Text class bindings and can stop them (Tk->break) -- Enter
# must not insert its newline before the proposal is dealt with, for one.
# Tk calls a bound sub with the widget as its first argument, so file_open and
# the like are wrapped: they would take the widget for a file name.
#------------------------------------------------------------------------------
sub bind_keys {
    my $t = text_widget();
    $t->bindtags([ 'PhcEditor', $t->bindtags ]);
    $mw->bind('PhcEditor', '<Return>'        => sub { on_return(); Tk->break });
    $mw->bind('PhcEditor', '<Tab>'           => sub { on_tab() and Tk->break });
    $mw->bind('PhcEditor', '<KeyPress>'      => \&on_key);
    $mw->bind('PhcEditor', '<ButtonPress>'   => sub { discard_proposal() });
    $mw->bind('PhcEditor', '<KeyRelease>'    => sub { after_change() });
    $mw->bind('PhcEditor', '<ButtonRelease>' => sub { update_status() });
    $mw->bind('PhcEditor', '<Control-space>' => sub { pick_list(); Tk->break });
    $mw->bind('PhcEditor', '<Control-z>'     => sub { undo(); Tk->break });
    $mw->bind('PhcEditor', '<Control-y>'     => sub { redo(); Tk->break });
    $mw->bind('<F5>'        => sub { solve() });
    $mw->bind('<Control-n>' => sub { file_new() });
    $mw->bind('<Control-o>' => sub { file_open() });
    $mw->bind('<Control-s>' => sub { file_save() });
    $mw->bind('<Control-r>' => sub { file_report() });
    $mw->bind('<Control-q>' => sub { file_quit() });
    $mw->protocol('WM_DELETE_WINDOW' => sub { file_quit() });
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
    return $ed->get('1.0', 'pstart') . $ed->get('pend', 'end - 1 chars');
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
    fill_results();
    recolour();
    update_status();
}

# cursor -- (line, column) of the insertion point.
sub cursor { split /\./, $ed->index('insert') }

# go_to_line -- put the cursor at the start of line $n, show and select it.
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
    my $name = shift;
    my ($i) = $list{$name}->curselection;
    go_to_line($list_lines{$name}[$i]) if defined $i;
}

#==============================================================================
# Colouring, the three lists, the status bar.
#==============================================================================

# after_change -- after a key: the status bar at once, the full re-check
# shortly after typing pauses.
sub after_change {
    update_status();
    $recolour_job->cancel if $recolour_job;
    $recolour_job = $mw->after(250, sub { $recolour_job = undef; recolour() });
    set_title();
}

# recolour -- re-check every line; colour it and refill the three lists.
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
    # Warnings belong to the last solve; they are shown until the next one.
    my $d = HardyCross::Editor::diagnostics($text, $solved ? $solved->{net} : undef, $line);
    for my $name (qw(ERRORS WARNINGS NODES)) {
        my $lb = $list{$name};
        $lb->delete(0, 'end');
        $list_lines{$name} = [];
        for my $p (@{ $d->{ lc $name } }) {
            $lb->insert('end', defined $p->{line} ? sprintf('LINE %-5d %s', $p->{line}, $p->{message})
                                                  : $p->{message});
            push @{ $list_lines{$name} }, $p->{line};
        }
    }
    return $res;
}

# update_status -- the status bar for the cursor's line: the command's field
# template with the field the cursor is in highlighted, then the line's
# message if it has one, or after a solve the element's results.
sub update_status {
    my $text = buffer();
    my ($n, $col) = cursor();
    # A message (solved, saved ...) stays until something changes; otherwise
    # the key release that follows F5 would wipe "SOLVED" at once.
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
            $statusbar->insert('end', "$t->{command} ");
            my @f = @{ $t->{fields} };
            for my $i (0 .. $#f) {
                $statusbar->insert('end', $f[$i], ($i == $t->{current} ? 'current' : ()));
                $statusbar->insert('end', ' ');
            }
        }
    }
    my $extra;
    if ($st->{status} ne 'ok' && length $st->{message}) {
        $extra = [ $st->{message}, 'bad' ];
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

# where -- the buffer and cursor as one string: a message stays while this is
# unchanged.
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
# The command strip: every command, in groups, two groups to a row so the
# whole set fits beside the lists at any usual window width.  A click starts
# a line with that command, on the current line if it is empty or a new one
# below it.
#==============================================================================
sub build_strip {
    my $parent = shift;
    $strip = $parent->Frame(-background => $C{chrome})->pack(-side => 'bottom', -fill => 'x', -pady => [4, 0]);
    my @groups = @HardyCross::Phc::COMMAND_GROUPS;
    while (my @pair = splice @groups, 0, 2) {
        my $row = $strip->Frame(-background => $C{chrome})->pack(-side => 'top', -fill => 'x');
        my $first = 1;
        for my $group (@pair) {
            $row->Label(-text => '|', -background => $C{chrome}, -foreground => $C{comment})
                ->pack(-side => 'left', -padx => 4) unless $first;
            $first = 0;
            for my $cmd (@$group) {
                my $l = $row->Label(-text => $cmd, -font => $UI_B, -background => $C{chrome},
                                    -foreground => $C{command}, -cursor => 'hand2')
                            ->pack(-side => 'left', -padx => 2);
                $l->bind('<ButtonRelease-1>' => sub { start_command($cmd) });
            }
        }
    }
}

# start_command -- begin a line with a command, ready for its first field.
sub start_command {
    my $cmd = shift;
    discard_proposal();
    unless ($ed->get('insert linestart', 'insert lineend') =~ /^\s*$/) {
        $ed->markSet('insert', 'insert lineend');
        $ed->insert('insert', "\n");
    }
    $ed->delete('insert linestart', 'insert lineend');
    $ed->insert('insert', sprintf('%-9s ', $cmd));
    $ed->see('insert');
    $ed->focus;
    after_change();
}

# strip_commands -- the commands on the strip, in order (for the tests).
sub strip_commands {
    return map { $_->cget(-text) } grep { $_->cget(-text) ne '|' } map { $_->children } $strip->children;
}

#==============================================================================
# The results: PIPES, NODES and OUTLETS as sortable tables, and the REPORT.
#
# A click on a column heading sorts on it; a second click reverses.  On the
# PIPES table a right click on the headings opens the column chooser.  HIDE
# NON-FLOWING PIPES and HIDE INACTIVE NODES leave out what the tables mark as
# inactive.  The rows themselves come from HardyCross::Editor::result_tables.
#==============================================================================
sub build_results {
    my $parent = shift;
    $book = $parent->NoteBook(-background => $C{chrome}, -backpagecolor => $C{chrome},
                              -inactivebackground => $C{chrome}, -font => $UI_B);
    for my $name (qw(PIPES NODES OUTLETS)) {
        my $page = $book->add($name, -label => $name);
        $table{$name} = { hlist => undef, data => undef, sort => undef, desc => 0, page => $page };
        make_table($name);
    }
    my $rp = $book->add('REPORT', -label => 'REPORT');
    $report = $rp->Scrolled('Text', -scrollbars => 'se', -wrap => 'none', -font => $MONO,
        -background => $C{paper}, -foreground => $C{ink}, -selectbackground => $C{select},
        -borderwidth => 0, -highlightthickness => 0, -state => 'disabled')->pack(-fill => 'both', -expand => 1);
    my $opts = $parent->Frame(-background => $C{chrome})->pack(-side => 'bottom', -fill => 'x');
    $opts->Checkbutton(-text => 'HIDE NON-FLOWING PIPES', -variable => \$hide_pipes,
        -background => $C{chrome}, -activebackground => $C{chrome}, -command => sub { fill_table('PIPES') })
        ->pack(-side => 'left', -padx => 6);
    $opts->Checkbutton(-text => 'HIDE INACTIVE NODES', -variable => \$hide_nodes,
        -background => $C{chrome}, -activebackground => $C{chrome}, -command => sub { fill_table('NODES') })
        ->pack(-side => 'left', -padx => 6);
    $book->pack(-fill => 'both', -expand => 1);
    %pipe_show = map { $_->{key} => $_->{show} } HardyCross::Editor::pipe_columns({ q => '', p => '', l => '' });
}

# columns -- the columns of a table as shown: all of them, or for PIPES the
# ones the chooser has on.  Each with its index in the full row.
sub columns {
    my $name = shift;
    my $d = $table{$name}{data} or return;
    my @c = @{ $d->{columns} };
    return map { [ $_, $c[$_] ] } grep { $name ne 'PIPES' || $pipe_show{ $c[$_]{key} } } 0 .. $#c;
}

# make_table -- (re)build a table's HList for its current columns.
sub make_table {
    my $name = shift;
    my $t = $table{$name};
    $t->{hlist}->destroy if $t->{hlist};
    my @cols = columns($name);
    # Before a solve, or after one that failed, there are no columns: one
    # heading says how to get some.
    @cols = ([ 0, { head => 'NO RESULTS - F5 SOLVES THE MODEL', unit => '', align => 'w' } ]) unless @cols;
    my $h = $t->{page}->Scrolled('HList', -scrollbars => 'osoe', -header => 1,
        -columns => scalar @cols, -background => $C{paper}, -foreground => $C{ink},
        -font => $MONO, -selectbackground => $C{select}, -borderwidth => 0,
        -highlightthickness => 0, -selectmode => 'browse')->pack(-fill => 'both', -expand => 1);
    for my $i (0 .. $#cols) {
        my ($full, $c) = @{ $cols[$i] };
        my $mark = defined $t->{sort} && $t->{sort} == $full ? ($t->{desc} ? ' v' : ' ^') : '';
        my $b = $h->Button(-text => $c->{head} . $mark . ($c->{unit} ? "\n$c->{unit}" : "\n "),
            -font => $UI_B, -background => $C{chrome}, -activebackground => $C{select},
            -foreground => $C{ink}, -relief => 'raised', -borderwidth => 1, -anchor => 'center',
            -command => sub { sort_table($name, $full) });
        $b->bind('<ButtonRelease-3>' => sub { column_menu() }) if $name eq 'PIPES';
        $h->header('create', $i, -itemtype => 'window', -widget => $b);
    }
    $t->{hlist} = $h;
    $t->{styles} = {
        e => $h->ItemStyle('text', -anchor => 'e', -font => $MONO, -background => $C{paper}, -foreground => $C{ink}),
        w => $h->ItemStyle('text', -anchor => 'w', -font => $MONO, -background => $C{paper}, -foreground => $C{ink}),
        bad => $h->ItemStyle('text', -anchor => 'w', -font => $MONO_B, -background => $C{paper}, -foreground => $C{error}),
    };
    fill_table($name);
}

# fill_table -- the rows of a table, sorted and filtered as set.
sub fill_table {
    my $name = shift;
    my $t = $table{$name};
    my $h = $t->{hlist} or return;
    $h->delete('all');
    my $d = $t->{data} or return;
    my $rows = $d->{rows};
    $rows = HardyCross::Editor::sort_rows($rows, $t->{sort}, $t->{desc}) if defined $t->{sort};
    $rows = [ grep { $_->{active} } @$rows ] if ($name eq 'PIPES' && $hide_pipes) || ($name eq 'NODES' && $hide_nodes);
    my @cols = columns($name);
    my $n = 0;
    for my $r (@$rows) {
        $h->add($n);
        for my $i (0 .. $#cols) {
            my ($full, $c) = @{ $cols[$i] };
            my $cell = $r->{cells}[$full];
            my $style = $cell eq 'FAIL' ? 'bad' : $c->{align};
            $h->itemCreate($n, $i, -text => $cell, -style => $t->{styles}{$style});
        }
        $n++;
    }
}

# sort_table -- sort on a column; the same column again reverses.
sub sort_table {
    my ($name, $col) = @_;
    my $t = $table{$name};
    $t->{desc} = defined $t->{sort} && $t->{sort} == $col ? !$t->{desc} : 0;
    $t->{sort} = $col;
    make_table($name);     # rebuilt so the heading shows the sort mark
}

# column_menu -- the pipe column chooser: every column with a tick when shown.
# NAME is always shown.
sub column_menu {
    my $m = $mw->Menu(-tearoff => 0, -background => $C{paper}, -foreground => $C{ink});
    for my $c (HardyCross::Editor::pipe_columns({ q => '', p => '', l => '' })) {
        $m->checkbutton(-label => $c->{desc}, -variable => \$pipe_show{ $c->{key} },
            -state => $c->{fixed} ? 'disabled' : 'normal', -command => sub { make_table('PIPES') });
    }
    $m->Popup(-popover => 'cursor', -popanchor => 'nw');
    return $m;
}

# fill_results -- all four tabs from the last solve (empty without one).
sub fill_results {
    my $tables = $solved ? HardyCross::Editor::result_tables($solved->{net}) : {};
    for my $name (qw(PIPES NODES OUTLETS)) {
        $table{$name}{data} = $tables->{ lc $name };
        make_table($name);
    }
}

# table_rows -- what a table shows, row by row (for the tests).
sub table_rows {
    my $name = shift;
    my $h = $table{$name}{hlist};
    my @cols = columns($name);
    return map { my $r = $_; [ map { $h->itemCget($r, $_, '-text') } 0 .. $#cols ] } $h->info('children');
}
# table_heads -- the headings of a table as shown (for the tests).
sub table_heads { return map { $_->[1]{head} } columns(shift) }

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

# on_tab -- accept a proposal; otherwise let Tab insert itself.  True when it
# handled the key.
sub on_tab {
    return 0 unless $prop{active};
    accept_proposal();
    after_change();
    return 1;
}

# on_key -- any other key discards the proposal first.  Modifier keys alone do
# not: they arrive before the key they modify.
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
    $ed->markSet('pstart', 'insert');
    $ed->markGravity('pstart', 'left');
    text_widget()->Tk::Text::insert('insert', $p, 'proposal');
    $ed->markSet('pend', 'insert');
    $ed->markGravity('pend', 'right');
    $ed->markSet('insert', 'pstart');
    $prop{active} = 1;
}

sub accept_proposal {
    return unless $prop{active};
    my $p = $ed->get('pstart', 'pend');
    my $at = $ed->index('pstart');
    text_widget()->Tk::Text::delete('pstart', 'pend');
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
# In a USE type, a pipe's fittings, a UNITS quantity or unit, METHOD or an
# OPTION name: a list of the choices with their descriptions.  Arrows move,
# Enter or a double-click inserts over any part already typed, Escape closes.
#==============================================================================
sub pick_list {
    discard_proposal();
    my ($n, $col) = cursor();
    my $ch = HardyCross::Editor::choices(buffer(), $n, $col);
    unless (@$ch) {
        message('NO PICK LIST HERE: CTRL+SPACE WORKS IN A USE TYPE, A PIPE FITTING, UNITS, METHOD OR OPTION');
        return;
    }
    my $top = $mw->Toplevel(-background => $C{chrome});
    $top->title('PICK LIST');
    $top->transient($mw);
    my $lb = $top->Scrolled('Listbox', -scrollbars => 'oe', -height => 14, -width => 64,
        -font => $MONO, -background => $C{paper}, -foreground => $C{ink},
        -selectbackground => $C{select}, -activestyle => 'none')
        ->pack(-fill => 'both', -expand => 1, -padx => 4, -pady => 4);
    $lb->insert('end', sprintf('%-9s %s', @$_)) for @$ch;
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
    my @bb = $ed->bbox('insert');
    $top->geometry('+' . ($ed->rootx + $bb[0]) . '+' . ($ed->rooty + $bb[1] + $bb[3] + 2)) if @bb;
    $lb->focus;
    return $top;
}

# insert_choice -- a picked code at the cursor, replacing the part of the word
# already typed before it ("G" + GV gives "GV", not "GGV").
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
    my $r = HardyCross::Editor::solve_text($text, $path);
    if (!$r->{ok}) {
        $solved = undef;
        fill_results();
        fill_report("THE MODEL WAS NOT SOLVED\n\n$r->{error}\n");
        go_to_line($r->{line}) if $r->{line};
        recolour();
        message($r->{error}, 1);
        return $r;
    }
    $solved = { net => $r->{net}, converged => $r->{converged}, text => $text };
    fill_results();
    fill_report($r->{report});
    recolour();          # the WARNINGS list is the solve's
    message($r->{converged} ? 'SOLVED - CONVERGED' : 'SOLVED - DID NOT CONVERGE: THE RESULTS MUST NOT BE USED',
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
sub report_text { $report->get('1.0', 'end - 1 chars') }

#==============================================================================
# FILE > PROPERTIES: the file's units.
#
# One choice per quantity, set from the file's UNITS lines.  OK rewrites
# those lines (HardyCross::Editor::set_units) as one undoable edit; nothing
# else in the text changes.
#==============================================================================
sub properties {
    my $units = HardyCross::Editor::units_of(buffer());
    my $top = $mw->Toplevel(-background => $C{chrome});
    $top->title('PROPERTIES - UNITS');
    $top->transient($mw);
    my %pick = %$units;
    for my $q (@HardyCross::Phc::UNIT_QUANTITIES) {
        my $row = $top->Frame(-background => $C{chrome})->pack(-fill => 'x', -padx => 8, -pady => 2);
        $row->Label(-text => sprintf('%-10s', $q), -font => $MONO_B, -background => $C{chrome})->pack(-side => 'left');
        my $be = $row->BrowseEntry(-variable => \$pick{$q}, -state => 'readonly', -width => 10,
            -background => $C{paper}, -font => $MONO)->pack(-side => 'left');
        $be->insert('end', @{ $HardyCross::Phc::UNIT_CHOICES{$q} });
        $row->Label(-text => '  DEFAULT ' . $HardyCross::Phc::UNIT_DEFAULT{$q}, -background => $C{chrome},
                    -foreground => $C{comment})->pack(-side => 'left');
    }
    my $btn = $top->Frame(-background => $C{chrome})->pack(-fill => 'x', -pady => 6);
    $btn->Button(-text => 'OK', -command => sub { apply_units(\%pick); $top->destroy })->pack(-side => 'right', -padx => 8);
    $btn->Button(-text => 'CANCEL', -command => sub { $top->destroy })->pack(-side => 'right');
    return ($top, \%pick);
}

# apply_units -- write the units chosen into the buffer's UNITS lines.
sub apply_units {
    my $units = shift;
    my $text = buffer();
    my $new = HardyCross::Editor::set_units($text, $units);
    return if $new eq $text;
    my $at = $ed->index('insert');
    # The delete and insert are grouped, so one Ctrl+Z puts the old units
    # back rather than leaving an empty buffer.
    my $t = text_widget();
    $t->addGlobStart;
    $ed->delete('1.0', 'end');
    $ed->insert('1.0', $new);
    $t->addGlobEnd;
    $ed->markSet('insert', $at);
    after_change();
    recolour();
    message('UNITS SET');
}

#==============================================================================
# Files.
#==============================================================================

# set_title -- the file name, and * when there are unsaved changes.
sub set_title {
    my $name = $path // 'UNTITLED.PHC';
    $name =~ s{.*[/\\]}{};
    $mw->title('PHCP EDITOR - ' . uc($name) . ($ed && modified() ? ' *' : ''));
}

# modified -- whether the buffer differs from what was last opened or saved.
sub modified { buffer() ne $saved_text }

# ok_to_discard -- true if nothing is unsaved, or the user agrees to lose it.
sub ok_to_discard {
    return 1 unless modified();
    my $a = $mw->messageBox(-title => 'UNSAVED CHANGES', -icon => 'warning', -type => 'YesNo',
        -message => 'THE MODEL HAS UNSAVED CHANGES.  DISCARD THEM?');
    return lc($a) eq 'yes';
}

sub file_new {
    return unless ok_to_discard();
    $path = undef;
    set_buffer('');
    set_title();
}

sub file_open {
    my $f = shift;
    return unless ok_to_discard();
    $f //= $mw->getOpenFile(-filetypes => [ [ 'PHCP MODEL', [ '.phc' ] ], [ 'ALL FILES', '*' ] ]);
    return unless defined $f && length $f;
    open_path($f);
}

# open_path -- load a .phc file into the editor.
sub open_path {
    my $f = shift;
    my $r = eval { HardyCross::Editor::load_file($f) };
    unless ($r) {
        my $e = $@;
        message(HardyCross::is_model_error($e) ? $e->{msg} : "$e", 1);
        return;
    }
    $path = $r->{path};
    set_buffer($r->{text});
    set_title();
    return $r;
}

sub file_save {
    return file_save_as() unless defined $path;
    write_buffer($path);
}

sub file_save_as {
    my $f = shift // $mw->getSaveFile(-defaultextension => '.phc',
        -initialfile => ($path // 'UNTITLED.PHC') =~ s{.*[/\\]}{}r,
        -filetypes => [ [ 'PHCP MODEL', '.phc' ] ]);
    return unless defined $f && length $f;
    $path = $f if write_buffer($f);
    set_title();
}

# write_buffer -- save the text, ending with a newline.
sub write_buffer {
    my $f = shift;
    my $text = buffer();
    $text .= "\n" unless $text =~ /\n\z/;
    my $fh;
    unless (open $fh, '>', $f) { message("CANNOT WRITE $f: $!", 1); return 0 }
    print $fh $text;
    close $fh;
    $saved_text = buffer();
    message("SAVED $f");
    set_title();
    return 1;
}

# file_report -- solve if the last solve is not of this text, then write the
# report as .pdf or .txt by the extension chosen.
sub file_report {
    my $out = shift;
    unless ($solved && $solved->{text} eq buffer()) {
        my $r = solve();
        return unless $r->{ok};
    }
    $out //= $mw->getSaveFile(-defaultextension => '.pdf',
        -initialfile => (($path // 'UNTITLED.PHC') =~ s{.*[/\\]}{}r) =~ s/\.phc\z//ir . '_REPORT.PDF',
        -filetypes => [ [ 'PDF REPORT', '.pdf' ], [ 'TEXT REPORT', '.txt' ] ]);
    return unless defined $out && length $out;
    my $ok = eval { HardyCross::Editor::write_report_file($solved->{net}, $solved->{converged},
                                                         $path // 'UNTITLED.PHC', $out) };
    message($ok ? "REPORT WRITTEN TO $out" : 'REPORT NOT WRITTEN: ' . ($@ && (ref $@ ? $@->{msg} : $@)), !$ok);
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
our $PHCP_EDITOR_LOAD_ONLY;
main(@ARGV) unless $PHCP_EDITOR_LOAD_ONLY;

1;
