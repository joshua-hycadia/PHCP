#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
# HardyCross/Window/Results.pm -- part of the editor window, phcp_editor.pl:
# the results: VALIDATION, PIPES, NODES and OUTLETS.
#
# The window is split one file to a tab so each can be read on its own.  It
# is still one program: this file is in package main, shares the window's
# globals (declared with our in phcp_editor.pl and named again below) and its
# widget helpers, and is loaded by phcp_editor.pl with use.  Nothing here
# decides anything; the decisions are in the HardyCross modules it calls.

package main;

use strict;
use warnings;

our ($hide_nodes, $hide_pipes, $restabs, %checks, %table, $MONO, $POINTER, $report, %C, %pipe_show, $MONO_B, $UI, $UI_B, $mw, $solved, $validation, $vtable);   # the window's globals, from phcp_editor.pl
#==============================================================================
# The results: VALIDATION, then PIPES, NODES and OUTLETS as sortable tables,
# and the REPORT.
#
# A click on a column heading sorts on it; a second click reverses.  On the
# PIPES table a right click on the headings opens the column chooser.  HIDE
# NON-FLOWING PIPES and HIDE INACTIVE NODES leave out what the tables mark as
# inactive.  The rows themselves come from HardyCross::Editor::result_tables.
#==============================================================================
sub build_results {
    my $parent = shift;
    $restabs = make_tabs($parent, [ 'VALIDATION', 'PIPES', 'NODES', 'OUTLETS', 'REPORT' ]);
    my $opts = $restabs->{bar};
    $checks{nodes} = check_box($opts, 'HIDE INACTIVE NODES', \$hide_nodes, sub { fill_table('NODES') });
    $checks{nodes}{frame}->pack(-side => 'right', -padx => px([6, 14]));
    $checks{pipes} = check_box($opts, 'HIDE NON-FLOWING PIPES', \$hide_pipes, sub { fill_table('PIPES') });
    $checks{pipes}{frame}->pack(-side => 'right', -padx => px(6));

    build_validation($restabs->{page}{VALIDATION});
    for my $name (qw(PIPES NODES OUTLETS)) {
        $table{$name} = { hlist => undef, data => undef, sort => undef, desc => 0, page => $restabs->{page}{$name} };
        make_table($name);
    }
    my $rp = $restabs->{page}{REPORT};
    my $rsb = flat_scrollbar($rp, 'vertical')->pack(-side => 'right', -fill => 'y');
    $report = $rp->Text(-wrap => 'none', -font => $MONO, -background => $C{paper}, -foreground => $C{ink},
        -selectbackground => $C{select}, -selectforeground => $C{ink}, -borderwidth => 0,
        -highlightthickness => 0, -padx => px(12), -pady => px(8), -state => 'disabled', -cursor => $POINTER,
        -yscrollcommand => sub { $rsb->set(@_) })->pack(-fill => 'both', -expand => 1);
    wheel_target($report);
    $rsb->configure(-command => sub { $report->yview(@_) });
    %pipe_show = map { $_->{key} => $_->{show} } HardyCross::Editor::pipe_columns({ q => '', p => '', l => '' });
}

# hlist -- a flat, scrolled HList for a table.
sub hlist {
    my ($page, $ncol) = @_;
    my $box = $page->Frame(-background => $C{paper})->pack(-fill => 'both', -expand => 1);
    my $vsb = flat_scrollbar($box, 'vertical')->pack(-side => 'right', -fill => 'y');
    my $hsb = flat_scrollbar($box, 'horizontal')->pack(-side => 'bottom', -fill => 'x');
    my $h = $box->HList(-header => 1, -columns => $ncol, -background => $C{paper},
        -foreground => $C{ink}, -font => $MONO, -selectbackground => $C{select},
        -selectforeground => $C{ink}, -borderwidth => 0, -highlightthickness => 0,
        -selectmode => 'browse', -drawbranch => 0, -indent => 0, -selectborderwidth => 0,
        -cursor => $POINTER, -takefocus => 0,
        -yscrollcommand => sub { $vsb->set(@_) }, -xscrollcommand => sub { $hsb->set(@_) })
        ->pack(-fill => 'both', -expand => 1);
    $vsb->configure(-command => sub { $h->yview(@_) });
    $hsb->configure(-command => sub { $h->xview(@_) });
    # A clicked row is shown by its pale blue band alone: HList also draws a
    # dotted box round the "anchor" row, which looked like a stray outline.
    $h->configure(-browsecmd => sub { $h->anchorClear });
    wheel_target($h);
    return ($h, $box);
}

#------------------------------------------------------------------------------
# Column headings.  Each heading is a text item in the HList's own header
# row, drawn on the grey panel with no border, so the row reads as one flat
# band the full width of the table with no seams between columns.  (Buttons
# placed in the header could not stretch to their columns and left gaps.)  A
# click is placed by its x position: header_column turns it into a column.
#------------------------------------------------------------------------------
sub heading {
    my ($h, $i, $text, $style) = @_;
    $h->header('create', $i, -itemtype => 'text', -text => $text, -style => $style,
               -headerbackground => $C{panel}, -borderwidth => 0, -relief => 'flat');
}

sub header_column {
    my ($h, $x) = @_;
    my @w = map { $h->columnWidth($_) } 0 .. $h->cget(-columns) - 1;
    my $total = 0;
    $total += $_ for @w;
    my $pos = $x + ($h->xview)[0] * $total;
    my $acc = 0;
    for my $i (0 .. $#w) { $acc += $w[$i]; return $i if $pos < $acc }
    return undef;
}

# on_heading -- call $cb with the column clicked, when a click (button $b) is
# in the header row.
sub on_heading {
    my ($h, $b, $cb) = @_;
    $h->bind("<ButtonRelease-$b>" => sub {
        my $e = $h->XEvent or return;
        return unless $e->y <= $h->header('height');
        my $c = header_column($h, $e->x);
        $cb->($c) if defined $c;
    });
}

# styles -- the cell styles of a table: right and left aligned, on white and
# on the faint stripe of alternate rows, and FAIL in red.
sub styles {
    my ($h, %o) = @_;
    my %s;
    for my $stripe (0, 1) {
        my $bg = $C{paper};      # no stripes: HList cannot run a band past its last column
        for my $al (qw(e w)) {
            $s{"$al$stripe"} = $h->ItemStyle('text', -anchor => $al, -font => $MONO, -background => $bg,
                -foreground => $C{ink}, -selectforeground => $C{ink}, -padx => px(8), -pady => px(3));
        }
        $s{"bad$stripe"} = $h->ItemStyle('text', -anchor => 'w', -font => $MONO_B, -background => $bg,
            -foreground => $C{error}, -padx => px(8), -pady => px(3));
        $s{"wrap$stripe"} = $h->ItemStyle('text', -anchor => 'nw', -font => $UI, -background => $bg,
            -foreground => $C{ink}, -padx => px(8), -pady => px(4), -wraplength => px($o{wrap} // 600), -justify => 'left');
        $s{"what$stripe"} = $h->ItemStyle('text', -anchor => 'nw', -font => $UI_B, -background => $bg,
            -foreground => $C{error}, -padx => px(8), -pady => px(4), -wraplength => px(380), -justify => 'left');
        $s{"where$stripe"} = $h->ItemStyle('text', -anchor => 'nw', -font => $UI, -background => $bg,
            -foreground => $C{ink}, -padx => px(8), -pady => px(4));
    }
    $s{good} = $h->ItemStyle('text', -anchor => 'w', -font => $UI_B, -background => $C{paper},
        -foreground => $C{accent}, -padx => px(8), -pady => px(8), -wraplength => px(380));
    $s{muted} = $h->ItemStyle('text', -anchor => 'w', -font => $UI, -background => $C{paper},
        -foreground => $C{muted}, -padx => px(8), -pady => px(8), -wraplength => px(380));
    $s{headm} = $h->ItemStyle('text', -anchor => 'w', -justify => 'left', -font => $MONO_B,
        -background => $C{panel}, -foreground => $C{ink}, -padx => px(8), -pady => px(6));
    $s{headw} = $h->ItemStyle('text', -anchor => 'w', -justify => 'left', -font => $UI_B,
        -background => $C{panel}, -foreground => $C{ink}, -padx => px(8), -pady => px(6));
    return \%s;
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
    $t->{box}->destroy if $t->{box};
    my @cols = columns($name);
    # Before a calculation, or after one that failed, there are no columns:
    # one heading says how to get some.
    @cols = ([ 0, { head => 'NO RESULTS - VALIDATE (F4), THEN CALCULATE (F5)', unit => '', align => 'w' } ])
        unless @cols;
    my ($h, $box) = hlist($t->{page}, scalar @cols);
    $t->{styles} = styles($h);
    # Headings and cells are in the monospace face, each column padded to
    # one width in characters: numbers then line up exactly on the right
    # under a right-aligned heading, names on the left.  (HList itself
    # clips a right-anchored heading, and a centred one sits unevenly over
    # right-aligned numbers.)  Widths come from every row, shown or hidden,
    # so a column does not jump when the HIDE boxes change.
    my $rows = $t->{data} ? $t->{data}{rows} : [];
    $t->{width} = {};
    for my $i (0 .. $#cols) {
        my ($full, $c) = @{ $cols[$i] };
        my $w = 2 + length $c->{head};                   # room for the sort mark
        $w = length $c->{unit} if length($c->{unit} // '') > $w;
        for (@$rows) { my $l = length $_->{cells}[$full]; $w = $l if $l > $w }
        $t->{width}{$full} = $w;
        my $mark = defined $t->{sort} && $t->{sort} == $full ? ($t->{desc} ? " \x{25BC}" : " \x{25B2}") : '';
        if ($t->{data}) {
            heading($h, $i, join("\n", map { pad($_, $w, $c->{align}) } $c->{head} . $mark, $c->{unit} || ''),
                    $t->{styles}{headm});
        } else {
            heading($h, $i, $c->{head}, $t->{styles}{headw});
        }
    }
    if ($t->{data}) {
        on_heading($h, 1, sub { sort_table($name, $cols[ $_[0] ][0]) });
        on_heading($h, 3, sub { column_menu() }) if $name eq 'PIPES';
    }
    @{$t}{qw(hlist box)} = ($h, $box);
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
        my $z = $n % 2;
        for my $i (0 .. $#cols) {
            my ($full, $c) = @{ $cols[$i] };
            my $cell = $r->{cells}[$full];
            my $style = $cell eq 'FAIL' ? "bad$z" : "w$z";
            $h->itemCreate($n, $i, -text => pad($cell, $t->{width}{$full}, $c->{align}),
                           -style => $t->{styles}{$style});
        }
        $n++;
    }
}

# pad -- text padded to $w characters: on the left for a right-aligned ('e')
# column, on the right otherwise.
sub pad { my ($t, $w, $al) = @_; return $al eq 'e' ? sprintf('%*s', $w, $t) : sprintf('%-*s', $w, $t) }

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
    my $m = $mw->Menu(-tearoff => 0, -background => $C{paper}, -foreground => $C{ink}, -font => $UI,
                      -relief => 'flat', -borderwidth => 1, -activeborderwidth => 0,
                      -activebackground => $C{select}, -activeforeground => $C{ink}, -selectcolor => $C{accent});
    for my $c (HardyCross::Editor::pipe_columns({ q => '', p => '', l => '' })) {
        $m->checkbutton(-label => $c->{desc}, -variable => \$pipe_show{ $c->{key} },
            -state => $c->{fixed} ? 'disabled' : 'normal', -command => sub { make_table('PIPES') });
    }
    $m->Popup(-popover => 'cursor', -popanchor => 'nw');
    return $m;
}

# fill_results -- the three tables from the last calculation (empty without one).
sub fill_results {
    my $tables = $solved ? HardyCross::Editor::result_tables($solved->{net}) : {};
    for my $name (qw(PIPES NODES OUTLETS)) {
        $table{$name}{data} = $tables->{ lc $name };
        make_table($name);
    }
    hide_counts();
}

#------------------------------------------------------------------------------
# hide_counts -- how many rows each HIDE box would hide, beside it: (2), or
# (NONE) with the box greyed when every pipe flows or every node is active,
# so ticking a box that has nothing to hide is not mistaken for a fault.
#------------------------------------------------------------------------------
sub hide_counts {
    for my $k ([ 'pipes', 'PIPES' ], [ 'nodes', 'NODES' ]) {
        my ($key, $name) = @$k;
        my $c = $checks{$key} or next;
        my $d = $table{$name}{data};
        my $n = $d ? grep { !$_->{active} } @{ $d->{rows} } : undef;
        $c->{count}->configure(-text => !defined $n ? '' : $n ? "($n)" : '(NONE)');
        $c->{label}->configure(-foreground => defined $n && !$n ? $C{faint} : $C{ink});
    }
}

# hide_count_text -- the count shown beside a HIDE box (for the tests).
sub hide_count_text { return $checks{ shift() }{count}->cget(-text) }

# table_rows -- what a table shows, row by row (for the tests).
sub table_rows {
    my $name = shift;
    my $h = $table{$name}{hlist};
    my @cols = columns($name);
    my $trim = sub { my $t = shift; $t =~ s/^\s+|\s+$//g; $t };
    return map { my $r = $_; [ map { $trim->($h->itemCget($r, $_, '-text')) } 0 .. $#cols ] } $h->info('children');
}
# header_text -- the text of a table's heading $i (for the tests).
sub header_text { my ($name, $i) = @_; return $table{$name}{hlist}->header('cget', $i, '-text') }
# table_heads -- the headings of a table as shown (for the tests).
sub table_heads { return map { $_->[1]{head} } columns(shift) }

#==============================================================================
# The VALIDATION tab: what VALIDATE found.  One row per problem - WHERE (the
# line, or the PROJECT tab), FIELD, WHAT IS WRONG and WHY.  A click on a row
# goes to it: the field at fault is selected in the editor, or the PROJECT
# tab field is focused.
#==============================================================================
sub build_validation {
    my $page = shift;
    my ($h, $box) = hlist($page, 4);
    my @heads = ('WHERE', 'FIELD', 'WHAT IS WRONG', 'WHY');
    my $st = styles($h, wrap => 620);
    heading($h, $_, $heads[$_], $st->{headw}) for 0 .. 3;
    $h->columnWidth(0, -char => 14);
    $h->columnWidth(1, -char => 16);
    $h->columnWidth(2, px(400));
    $h->configure(-browsecmd => sub { $h->anchorClear; go_to_fault(shift) });
    $vtable = { hlist => $h, styles => $st };
    fill_validation();
}

# fill_validation -- the VALIDATION table from the last VALIDATE.
sub fill_validation {
    return unless $vtable;
    my ($h, $s) = @{$vtable}{qw(hlist styles)};
    $h->delete('all');
    unless ($validation) {
        $h->add('none');
        $h->itemCreate('none', 2, -text => 'NOT VALIDATED YET. PRESS VALIDATE (F4) TO CHECK THE INPUTS.',
                       -style => $s->{muted});
        return;
    }
    unless (@{ $validation->{items} }) {
        $h->add('none');
        $h->itemCreate('none', 2, -text => 'NO PROBLEMS FOUND. CALCULATE (F5) IS NOW AVAILABLE.', -style => $s->{good});
        return;
    }
    my $n = 0;
    for my $it (@{ $validation->{items} }) {
        my $z = $n % 2;
        $h->add($n);
        my $where = $it->{tab} ? 'PROJECT TAB' : defined $it->{line} ? "LINE $it->{line}" : 'NETWORK';
        $h->itemCreate($n, 0, -text => $where, -style => $s->{"where$z"});
        $h->itemCreate($n, 1, -text => $it->{field} // '', -style => $s->{"where$z"});
        $h->itemCreate($n, 2, -text => $it->{what}, -style => $s->{"what$z"});
        $h->itemCreate($n, 3, -text => $it->{why}, -style => $s->{"wrap$z"});
        $n++;
    }
}

# go_to_fault -- a VALIDATION row clicked: to the field at fault.
sub go_to_fault {
    my $row = shift;
    return unless $validation && defined $row && $row =~ /^\d+\z/;
    my $it = $validation->{items}[$row] or return;
    return show_field($it->{field}) if $it->{tab};
    go_to_line($it->{line}, $it->{start}, $it->{end}) if defined $it->{line};
}

# validation_rows -- the VALIDATION table as text, row by row (for the tests).
sub validation_rows {
    my $h = $vtable->{hlist};
    return map { my $r = $_; [ map { $h->itemExists($r, $_) ? $h->itemCget($r, $_, '-text') : '' } 0 .. 3 ] }
           $h->info('children');
}

1;
