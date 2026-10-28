#!/usr/bin/perl
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# phcp_editor.pl -- the PHCP editor.
#
#   perl phcp_editor.pl [model.phc]
#
#   +------------------------------------------------------------------+
#   | NEW OPEN SAVE | VALIDATE  CALCULATE | WRITE REPORT    [ status ] |
#   +------------------------------------------------------------------+
#   | NETWORK | PROJECT                                                 |
#   |  USE PIPE PC ... | NODE NC WATER ... | PUMP BP BFP ...  (strip)   |
#   |  +----+---------------------------------------+ +--------------+ |
#   |  |  1 | WATER     SUP 0 650                   | | ERRORS       | |
#   |  |  2 | NODE      R1 4.5                      | | WARNINGS     | |
#   |  +----+---------------------------------------+ | NODES        | |
#   |  status bar: the field template | the line's results            | |
#   +------------------------------------------------------------------+
#   | VALIDATION | PIPES | NODES | OUTLETS | REPORT      [ ] HIDE ...   |
#   +------------------------------------------------------------------+
#
# The editor holds the NETWORK only.  The title, project details, units,
# method and options are set in the PROJECT tab; the .phc file keeps them as
# lines at its head (HardyCross::Editor::split_file and join_file), so a
# saved file is complete and phcp.pl reads it unchanged.
#
# VALIDATE comes before CALCULATE.  VALIDATE lists every problem - what is
# wrong, why, and where - in the VALIDATION tab and marks each in the editor;
# a click on one goes to it.  CALCULATE is available only while the model is
# exactly as it was when it last passed validation.
#
# THIS FILE IS ONLY THE WINDOW.  Every decision -- is this line good, what is
# the next line likely to be, what goes in a pick list or a table, what is
# wrong and why -- is made by HardyCross::Editor, which has no Tk in it and is
# tested headless by tools/test_editor.pl.  What is here is drawing, keys and
# files.  tools/test_editor_window.pl drives this window under a virtual
# display; it loads this file without starting the event loop (see the last
# lines) and calls the handlers below directly.
#
# Layout: this file holds the frame of the window and the NETWORK tab; each
# other tab is a file of its own in HardyCross/Window/, in package main, so it
# shares this file's globals and helpers.
#   this file                  colours and fonts; widget helpers (flat buttons,
#                              tabs, check boxes, drop-downs); build_window;
#                              the NETWORK tab -- colouring, line numbers, the
#                              lists, the status bar, the command strip,
#                              proposals, the pick list; VALIDATE and
#                              CALCULATE (F4, F5); files; start
#   Window/Project.pm          PROJECT tab: title, details, units, method, options
#   Window/Graph.pm            GRAPH tab: a Q^1.85 water supply graph
#   Window/Tools.pm            QUICK TOOLS tab: the calculators
#   Window/Database.pm         DATABASE tab: the pipe and fitting database
#   Window/Results.pm          the results: VALIDATION, PIPES, NODES, OUTLETS
#==============================================================================
use strict;
use warnings;
use FindBin;
use lib $FindBin::Bin;
use Tk;
use Tk::Panedwindow;
use Tk::HList;
use Tk::ItemStyle;
# TextUndo, not Text: Perl/Tk's Text accepts -undo but never records an edit,
# so Ctrl+Z did nothing.  TextUndo keeps its own record of every insert and
# delete, and undoes them one at a time.
use Tk::TextUndo;
use HardyCross;
use HardyCross::Phc;
use HardyCross::Editor;
use HardyCross::DbEdit;
use HardyCross::Graph;
use HardyCross::Tools;
# The window, one file to a tab (all in package main).
use HardyCross::Window::Project;
use HardyCross::Window::Tools;
use HardyCross::Window::Graph;
use HardyCross::Window::Database;
use HardyCross::Window::Results;
use File::Spec;

#------------------------------------------------------------------------------
# Colours.
#
# A white, matte window: white paper, a very light grey for panels, one-pixel
# grey rules in place of bevels.  Blue and black are the highlight colours -
# command words, the current field, the active tab, the CALCULATE button, the
# selection - and red marks what is wrong.  Every colour is named once here.
#------------------------------------------------------------------------------
our %C = (
    paper      => '#FFFFFF',     # editor, tables, form fields
    panel      => '#F6F7F9',     # toolbar, status bar, table headings
    line       => '#DDE1E6',     # one-pixel rules and field outlines
    hover      => '#EEF1F5',     # a button or heading under the pointer
    ink        => '#111111',     # text
    muted      => '#6B7280',     # labels, inactive tabs, comments
    faint      => '#A3AAB4',     # line numbers, disabled text
    accent     => '#1F5FBF',     # the highlight blue
    accent_dk  => '#184C99',     # the highlight blue, pressed
    accent_bg  => '#E8F0FC',     # a pale blue behind a highlight
    select     => '#D3E3FA',     # selection
    curline    => '#F5F8FD',     # the cursor's line
    number     => '#0B4F9C',     # numbers in the editor
    error      => '#C62828',     # what is wrong
    error_bg   => '#FDEEEE',     # behind a line in error
    fault_bg   => '#F9D4D4',     # behind the field validation found at fault
    warn       => '#8A5A00',     # a warning
    proposal   => '#9AA5B4',     # the greyed proposed line
    sash       => '#E4E7EB',     # the dividers between panes, wide enough to grab
);

# The ordinary pointer.  X11's "arrow" points up and to the right, so it is
# left_ptr there; Windows calls the same pointer "arrow".
our $POINTER = $^O eq 'MSWin32' ? 'arrow' : 'left_ptr';

# Fonts are chosen when the window is built, from what the machine has:
# Consolas and Segoe UI on Windows, DejaVu on Linux.
our ($MONO, $MONO_B, $MONO_I, $UI, $UI_B, $UI_S, $UI_S_N);
sub pick_fonts {
    my %have = map { lc $_ => 1 } $main::mw->fontFamilies;
    my ($mono) = grep { $have{ lc $_ } } 'Consolas', 'DejaVu Sans Mono', 'Liberation Mono', 'Menlo', 'Courier New';
    my ($ui)   = grep { $have{ lc $_ } } 'Segoe UI', 'DejaVu Sans', 'Liberation Sans', 'Helvetica Neue', 'Arial';
    $mono //= 'Courier';
    $ui   //= 'Helvetica';
    ($MONO, $MONO_B, $MONO_I) = ([ $mono, 10 ], [ $mono, 10, 'bold' ], [ $mono, 10, 'italic' ]);
    ($UI, $UI_B, $UI_S, $UI_S_N) = ([ $ui, 9 ], [ $ui, 9, 'bold' ], [ $ui, 8, 'bold' ], [ $ui, 8 ]);
}

#------------------------------------------------------------------------------
# Crisp on a high-resolution screen.
#
# Windows draws a program that has not declared itself DPI-aware at 96 dpi and
# then stretches the bitmap -- at 150 % scaling everything comes out soft.
# Perl/Tk does not declare it, so dpi_aware does, before the first window is
# made.  Tk then measures the real resolution: fonts, given in points, come
# out at the right size and sharp.  Sizes given in pixels -- padding, the
# divider and scrollbar widths, the window itself -- are passed through px(),
# which multiplies them by the screen's scale (1.5 at 150 %), so the layout
# keeps its proportions.
#------------------------------------------------------------------------------
our $SCALE = 1;
sub px {
    my $v = shift;
    return [ map { px($_) } @$v ] if ref $v;
    return int($v * $SCALE + 0.5);
}

sub dpi_aware {
    return unless $^O eq 'MSWin32';
    eval {
        require Win32::API;
        # Per-monitor where Windows offers it (8.1 and later), else system-wide.
        my $per = Win32::API->new('shcore', 'SetProcessDpiAwareness', 'I', 'I');
        if ($per) { $per->Call(1) } else { Win32::API->new('user32', 'SetProcessDPIAware', '', 'I')->Call() }
        1;
    };
}

# The window's state.  One editor window per process, so plain package
# variables, each named for what it holds.
our ($mw, $ed, $gutter, $report, $statusbar, $strip, $pill, $vtable);
our (%list, %list_lines, %list_head);   # ERRORS, WARNINGS, NODES: listbox, entries, heading
our (%table);                    # PIPES, NODES, OUTLETS: { hlist, data, sort, desc }
our ($toptabs, $restabs);        # the NETWORK / PROJECT / GRAPH / QUICK TOOLS / DATABASE tabs; the results tabs
our (%btn, %form, %checks);      # toolbar buttons; PROJECT tab fields; HIDE boxes
our $project_canvas;             # the PROJECT tab's scrolling canvas
our %dbv;                        # the DATABASE tab: { db, editing, kind, sel, ... }
our %pipe_show;                  # the pipe columns shown, by key
our ($hide_pipes, $hide_nodes) = (0, 0);
our $path;                       # the file being edited, or undef for a new buffer
our $settings = HardyCross::Editor::new_settings();   # what the PROJECT tab holds
our $solved;                     # { net, converged, text } from the last calculation
our $validation;                 # { ok, items, text } from the last VALIDATE
our $valid_text;                 # the whole text as it was when it last passed VALIDATE
our $saved_text = '';            # the whole text as last opened or saved
our $recolour_job;               # the pending delayed re-check, so typing stays smooth
our %prop = (active => 0);       # the proposal on show, if any
our $notice;                     # [ text, bad, where ]: a message that stays in the
                                 # status bar until the text or the cursor changes
our $gutter_lines = 0;           # how many numbers the gutter holds

#==============================================================================
# Widget helpers.  Tk draws bevels by default; each helper sets a flat relief,
# no border, and a one-pixel outline in the rule colour where one is wanted.
#==============================================================================

# rule -- a one-pixel line, horizontal ('x') or vertical ('y').
sub rule {
    my ($parent, $fill, %pack) = @_;
    my $f = $parent->Frame(-background => $C{line}, ($fill eq 'x' ? (-height => 1) : (-width => 1)));
    $f->pack(-fill => $fill, %pack);
    return $f;
}

# flat_button -- a flat button.  The primary one (CALCULATE) is solid blue.
sub flat_button {
    my ($parent, $text, $cmd, %o) = @_;
    my $p = $o{primary};
    return $parent->Button(-text => $text, -command => $cmd, -font => $UI_B,
        -relief => 'flat', -borderwidth => 0, -highlightthickness => 1,
        -highlightbackground => $p ? $C{accent} : $C{line}, -highlightcolor => $C{accent},
        -background => $p ? $C{accent} : $C{paper}, -foreground => $p ? '#FFFFFF' : $C{ink},
        -activebackground => $p ? $C{accent_dk} : $C{hover},
        -activeforeground => $p ? '#FFFFFF' : $C{ink},
        -disabledforeground => $C{faint}, -padx => px(14), -pady => px(5), -cursor => 'hand2');
}

#------------------------------------------------------------------------------
# make_tabs -- a row of flat tabs over a set of pages.  The active tab is in
# ink with a blue bar under it; the others are grey.  Returns
# { bar, page => { name => frame }, current, ... }; the bar has room on its
# right for the caller to pack more into.
#------------------------------------------------------------------------------
sub make_tabs {
    my ($parent, $names, $on_select) = @_;
    my $t = { names => $names, page => {}, label => {}, on_select => $on_select };
    $t->{bar} = $parent->Frame(-background => $C{paper})->pack(-side => 'top', -fill => 'x');
    rule($parent, 'x', -side => 'top');
    my $body = $parent->Frame(-background => $C{paper})->pack(-side => 'top', -fill => 'both', -expand => 1);
    for my $n (@$names) {
        my $f = $t->{bar}->Frame(-background => $C{paper})->pack(-side => 'left');
        my $l = $f->Label(-text => $n, -font => $UI_B, -background => $C{paper}, -foreground => $C{muted},
                          -padx => px(14), -pady => px(7), -cursor => 'hand2')->pack(-side => 'top');
        my $u = $f->Frame(-height => px(2), -background => $C{paper})->pack(-side => 'top', -fill => 'x');
        $t->{label}{$n} = [ $l, $u ];
        $l->bind('<ButtonRelease-1>' => sub { select_tab($t, $n) });
        $t->{page}{$n} = $body->Frame(-background => $C{paper});
    }
    select_tab($t, $names->[0]);
    return $t;
}

sub select_tab {
    my ($t, $n) = @_;
    $t->{page}{ $t->{current} }->packForget if $t->{current};
    $t->{current} = $n;
    $t->{page}{$n}->pack(-fill => 'both', -expand => 1);
    for my $m (@{ $t->{names} }) {
        my ($l, $u) = @{ $t->{label}{$m} };
        $l->configure(-foreground => $m eq $n ? $C{ink} : $C{muted});
        $u->configure(-background => $m eq $n ? $C{accent} : $C{paper});
    }
    $t->{on_select}->($n) if $t->{on_select};
}

#------------------------------------------------------------------------------
# check_box -- a flat check box drawn on a canvas: an outlined square, filled
# blue with a white tick when on.  (Tk's own indicator is bevelled.)
#------------------------------------------------------------------------------
sub check_box {
    my ($parent, $text, $var, $cmd) = @_;
    my $f = $parent->Frame(-background => $C{paper}, -cursor => 'hand2');
    my $b = px(14);
    my $c = $f->Canvas(-width => $b, -height => $b, -background => $C{paper},
                       -highlightthickness => 0, -borderwidth => 0)->pack(-side => 'left', -padx => px([0, 6]));
    my $l = $f->Label(-text => $text, -font => $UI, -background => $C{paper}, -foreground => $C{ink})
              ->pack(-side => 'left');
    my $n = $f->Label(-text => '', -font => $UI, -background => $C{paper}, -foreground => $C{muted})
              ->pack(-side => 'left', -padx => px([4, 0]));
    my $draw = sub {
        $c->delete('all');
        if ($$var) {
            $c->createRectangle(1, 1, $b - 1, $b - 1, -fill => $C{accent}, -outline => $C{accent});
            $c->createLine(map({ px($_) } 4, 7, 6, 10, 11, 4), -fill => '#FFFFFF', -width => px(2));
        } else {
            $c->createRectangle(1, 1, $b - 1, $b - 1, -fill => $C{paper}, -outline => $C{faint});
        }
    };
    $_->bind('<ButtonRelease-1>' => sub { $$var = $$var ? 0 : 1; $draw->(); $cmd->() }) for $f, $c, $l, $n;
    $draw->();
    return { frame => $f, draw => $draw, label => $l, count => $n };
}

#------------------------------------------------------------------------------
# drop_down -- a flat choice: the value, a small arrow, and a plain menu.  The
# default, if given, is marked in the menu.
#------------------------------------------------------------------------------
our @dd_refresh;                  # drop-downs to redraw when settings are loaded
sub drop_down {
    my ($parent, $var, $choices, $cmd, $default) = @_;
    my $show = sub { sprintf '%-9s %s', length($$var // '') ? $$var : 'DEFAULT', "\x{25BE}" };
    my $mb = $parent->Menubutton(-text => $show->(), -font => $MONO, -relief => 'flat',
        -borderwidth => 0, -highlightthickness => 1, -highlightbackground => $C{line},
        -background => $C{paper}, -activebackground => $C{hover}, -foreground => $C{ink},
        -anchor => 'w', -width => 11, -padx => px(6), -pady => px(3), -indicatoron => 0, -cursor => 'hand2');
    my $m = $mb->Menu(-tearoff => 0, -font => $MONO, -relief => 'flat', -borderwidth => 1,
        -activeborderwidth => 0, -background => $C{paper}, -foreground => $C{ink},
        -activebackground => $C{select}, -activeforeground => $C{ink});
    for my $v (@$choices) {
        $m->command(-label => ($v eq '' ? 'DEFAULT' : $v) . (defined $default && $v eq $default ? '   (DEFAULT)' : ''), -command => sub { $$var = $v; $mb->configure(-text => $show->()); $cmd->() });
    }
    $mb->configure(-menu => $m);
    push @dd_refresh, sub { $mb->configure(-text => $show->()) };
    return $mb;
}

# flat_entry -- a one-line text field with a one-pixel outline, blue when focused.
sub flat_entry {
    my ($parent, $var, $width) = @_;
    return $parent->Entry(-textvariable => $var, -font => $MONO, -width => $width // 30,
        -relief => 'flat', -borderwidth => 0, -highlightthickness => 1,
        -highlightbackground => $C{line}, -highlightcolor => $C{accent},
        -background => $C{paper}, -foreground => $C{ink}, -insertbackground => $C{ink},
        -selectbackground => $C{select}, -selectforeground => $C{ink});
}

#------------------------------------------------------------------------------
# divider -- a pane divider the user can drag: a 6-pixel light grey band (a
# one-pixel line could not be grabbed), the resize pointer over it, and the
# panes redrawn live while it moves.
#------------------------------------------------------------------------------
sub divider {
    my ($parent, $orient) = @_;
    return $parent->Panedwindow(-orient => $orient, -background => $C{sash}, -sashwidth => px(6),
        -sashpad => 0, -borderwidth => 0, -showhandle => 0, -handlesize => 0,
        -sashrelief => 'flat', -opaqueresize => 1,
        -sashcursor => $orient eq 'vertical' ? 'sb_v_double_arrow' : 'sb_h_double_arrow');
}

# flat_scrollbar -- a thin grey scrollbar with no bevels.
sub flat_scrollbar {
    my ($parent, $orient) = @_;
    return $parent->Scrollbar(-orient => $orient, -relief => 'flat', -borderwidth => 0,
        -elementborderwidth => 0, -width => px(11), -troughcolor => $C{panel},
        -background => '#CDD2D9', -activebackground => '#B4BBC5', -highlightthickness => 0);
}

#==============================================================================
# set_icon -- the PHCP icon on the window and the taskbar, in place of Tk's.
#
# A blue tile with a two-loop pipe network and a red sprinkler at the far
# node.  The same picture is data/phcp.ico, which build_windows.bat gives the
# .exe files.  Held here as PNG data at 16, 32 and 48 pixels so the window
# needs no file to find; Tk picks the size the system asks for.  Without
# Tk::PNG the window simply keeps the Tk icon.
#==============================================================================
my %ICON_PNG = (
    16 => join('', qw(
        iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAACSklEQVR42oWTz0vUQRjGP+/M
        7LqrK65mdYjM6JbayXMl1alzIIJ2rJtBlBRKiKeoi/9AEELgqVN20kPdwouSESK5rXWKNGVX
        d/c7M2+HNX+k0QNzGXif+bzvO48AdAzOjpl0dtjEpBWigAjHSjWqUYzbiEltsjjVNyEdQ7Oj
        LtMykVRKbFeSf9fuKps2OGcR10Sobo5J5+25sleTbWuy2tXZbFSVGIGDPgrGgCAsFUusb9Wi
        S1nREHacMbZxu1zjanerTD24xP80+GyRmfkfJp8SgphGB6oiIj4oUZWNUsJSoYS1gmq9oxCU
        rs4crbkUPugunACq7g9sRDEifCyUuPlknlzGEbV+V6p43oz3cqWnjah6EEjc34jOCLmMO2SA
        gLPHD/eIgQJRde9IfXvEJKDeI6rIgU0dMRDAiOy9jMJOojS0tyHO4F2aWuIRcYAeNfBRKVU8
        IqCqVDyMD1zg7NsXrBQKPLzRz/L3POs/S6RSZt/AIERVujtzzIz3Yq0QfcBlGjj/fpqVRyPU
        gnBxbZm7t57z+OUy7WmL221bnK1jn2hOc7mn7RBV8dVXqh5MPs/mapGTmYAYg6LqoiLZtGGx
        sMXA0wWU/Z8oMZJgGenr5+LqZ359WePUvftML1RJEQArcm5orizWZn0SdKcWzaGBCiQ+0nGm
        hTvXT5N3ntefEt59+BZzTQ0Sg9+RjqHZUdvQMqG+jOFwCBQwApWqp1xVxBqcBnK5DNjGepj2
        4pzKDGvwrRCOxFkErAiKKhiN4jZiUpksTl2b+A1H6g/aAEZ1wAAAAABJRU5ErkJggg==
    )),
    32 => join('', qw(
        iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAEJ0lEQVR42u2XTWxUVRTHf+e+
        j5nOTFvitFpFWwRZYfhQNCQu0EZkAZKwc8HHThJjWJTEGAgxakx0QyRRExo31IQFLEiM7Iig
        KxJtBERDtFQoIhWkie3MdN7Mu/e4mKHtTDvA2BJceJK7ee9+/M/5n3vO/wogoIDoEztObzGe
        /ybOrgPNgAoLYqIgOYx3xtn4k6sDL35Z2VsQ3lED0HP5m8/ET+wCUBuBKgtqIoiXAEDj6NCV
        JevfoOI9dG8/ecjPdL1uCzctqoKI4X6YqkNEvVSnF+dG+0e+eHmXdO/8epPxW77SOCqD+rdB
        3UdTkFj8RODiyc2+IH0CqqiZebhUGZrvWW42kwJqBFSQPh9lnbORAN7MWcWSwzpFKpCbo7u6
        xoiQDOdk03M2AmWdj0hqZsKJCMWS5b3ty1nRk8G5SjTqD5gKjs4NUASu34rY8/nFRvkAIim/
        frkAsVPWLm9nzbK2eREwOhbdlSK/UQjzUYx1SmyVQmSrgMEpJHxDS6IS2qjsmCw5jEzf3HTS
        w/eE3GR8V5B+Yx4FzwjjhZgt7w4yNlEmGRrGJmK29T7G+9uXAzBw8hofHhsm2xYQ2wqC4/uf
        ZWlXy2zumgEwk6qxiTK3xisAbo2Xyc/wrFCy/PV3CWAKgHX3nrb+vUwKfKkZnpn2zJPp77cd
        buby+vdWwOpGbVWp+desGR6w/Q9gwQHIgwRg5HZSKjiHaqWX3KkcLBgAY4Ri2YE6wtAHY/A9
        Qzm2lGNtCKJpAI0az2Rk6WoPOf7BCyxuhdwvv9LdmWBg7/O0BIbYzh0JM1+OpdoDQg8G9q1l
        5c2z/LBhAz++uplzmzbRmxnl077VFKPynPrijoXIqZJOehzf/0xFG4hgrbIo7eOqVWdb72I2
        rukglfToXgTfvfYWxeFLBNksucFBzu/ZxyvHjrJyaRs/XcmTSnhTa+8IIBEYjAiJQFjalWoI
        MtsakG0NAMgNXaI8ep0gm0WtJXy4g/zQEFrI8fgjGc4OTSBJr4ZHv1E2X74xyUOZAKs6O3Qy
        zZ0CzimBJyxZ1kNy2VNMDH5P2NlJ8Y/rPLx1K5LKcOnqOGFoZpVr6dl5al76W6ryqFSKObL/
        Odan/uR8314Kw8O0rlrJio8/4sgF2H3wHO2ZcFanlJ6dp7V51Vd7K4xAOVZaQsPB3avZuKod
        Lz9OKd3G0W9v8Hb/BTzPTNWJGtXRs+NUHlOrC/9tESpbJYpinn6yjUc701y5Ns7F3/OkWwKM
        qeuWFXlV8BHOGC/xkouLrl4ZN2NOwfeEIBXy80iO879NEPqG9kyIc1rvnzVewjgtnjGKHlAQ
        EMd8uKjqAqdKKuHTng5IhgbrtH5TBXEKougBM3K494Qr5fu9VEcAOFTdfMuyU8W6OR4llb2d
        l+oIXCnfP3K498R/4nH6QJ/n/wBWFOScCQMOKQAAAABJRU5ErkJggg==
    )),
    48 => join('', qw(
        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
    )),
);
sub set_icon {
    return unless eval { require Tk::PNG; 1 };
    my @img = map { $mw->Photo(-format => 'png', -data => $ICON_PNG{$_}) }
              sort { $b <=> $a } keys %ICON_PNG;
    eval { $mw->iconphoto('-default', @img); 1 } or eval { $mw->iconimage($img[-1]) };
}


#==============================================================================
# build_window -- create every widget.  Returns the main window.
#==============================================================================
sub build_window {
    dpi_aware();
    $mw = MainWindow->new(-background => $C{paper});
    set_icon();
    # The screen's scale against the 96 dpi the sizes here were drawn for;
    # never below 1, so a low-resolution screen is not cramped further.
    my $dpi = $mw->winfo('pixels', '1i');
    $SCALE = $dpi > 96 ? $dpi / 96 : 1;
    pick_fonts();
    $mw->geometry(px(1500) . 'x' . px(950));
    $mw->optionAdd('*Font', $UI);
    $mw->optionAdd('*Background', $C{paper});
    $mw->optionAdd('*Menu.Relief', 'flat');
    $mw->optionAdd('*Menu.activeBorderWidth', 0);
    $mw->optionAdd('*Menu.activeBackground', $C{select});
    $mw->optionAdd('*Menu.activeForeground', $C{ink});
    $mw->optionAdd('*Menu.font', $UI);
    $mw->optionAdd('*Menu.borderWidth', 1);
    build_menus();
    build_toolbar();

    # The divider between the work above and the results below can be moved.
    my $vp = divider($mw, 'vertical');
    my $top = $mw->Frame(-background => $C{paper});
    my $bottom = $mw->Frame(-background => $C{paper});
    $toptabs = make_tabs($top, [ 'NETWORK', 'PROJECT', 'GRAPH', 'QUICK TOOLS', 'DATABASE' ],
                         sub { tools_refresh() if $_[0] eq 'QUICK TOOLS' });
    build_network($toptabs->{page}{NETWORK});
    build_project($toptabs->{page}{PROJECT});
    build_graph($toptabs->{page}{GRAPH});
    build_tools($toptabs->{page}{'QUICK TOOLS'});
    build_database($toptabs->{page}{DATABASE});
    build_results($bottom);
    $vp->add($top, -height => px(560));
    $vp->add($bottom);
    $vp->pack(-fill => 'both', -expand => 1);

    bind_keys();
    $saved_text = full_text();       # an empty new file is not a change
    set_title();
    update_actions();
    update_status();
    $ed->focus;
    return $mw;
}

sub build_menus {
    my $bar = $mw->Menu(-type => 'menubar', -relief => 'flat', -borderwidth => 0, -font => $UI,
                        -background => $C{paper}, -foreground => $C{ink});
    $mw->configure(-menu => $bar);
    my $file = $bar->cascade(-label => 'FILE', -tearoff => 0);
    $file->command(-label => 'NEW',             -accelerator => 'CTRL+N', -command => sub { file_new() });
    $file->command(-label => 'OPEN...',         -accelerator => 'CTRL+O', -command => sub { file_open() });
    $file->command(-label => 'SAVE',            -accelerator => 'CTRL+S', -command => sub { file_save() });
    $file->command(-label => 'SAVE AS...',                                -command => sub { file_save_as() });
    $file->separator;
    $file->command(-label => 'PROJECT AND UNITS',                         -command => sub { select_tab($toptabs, 'PROJECT') });
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
    $model->command(-label => 'VALIDATE',  -accelerator => 'F4', -command => sub { validate() });
    $model->command(-label => 'CALCULATE', -accelerator => 'F5', -command => sub { calculate() });
}

# build_toolbar -- the file buttons, VALIDATE and CALCULATE, WRITE REPORT, and
# on the right the model's state: not validated, problems, valid, calculated.
sub build_toolbar {
    my $tb = $mw->Frame(-background => $C{panel})->pack(-side => 'top', -fill => 'x');
    my $in = $tb->Frame(-background => $C{panel})->pack(-fill => 'x', -padx => px(14), -pady => px(8));
    my $sep = sub { $in->Frame(-background => $C{line}, -width => 1, -height => px(22))->pack(-side => 'left', -padx => px(10)) };
    $btn{NEW}  = flat_button($in, 'NEW',  sub { file_new() })->pack(-side => 'left', -padx => px([0, 4]));
    $btn{OPEN} = flat_button($in, 'OPEN', sub { file_open() })->pack(-side => 'left', -padx => px(4));
    $btn{SAVE} = flat_button($in, 'SAVE', sub { file_save() })->pack(-side => 'left', -padx => px(4));
    $sep->();
    $btn{VALIDATE}  = flat_button($in, 'VALIDATE  F4', sub { validate() })->pack(-side => 'left', -padx => px(4));
    $btn{CALCULATE} = flat_button($in, 'CALCULATE  F5', sub { calculate() }, primary => 1)
                          ->pack(-side => 'left', -padx => px(4));
    $sep->();
    $btn{REPORT} = flat_button($in, 'WRITE REPORT', sub { file_report() })->pack(-side => 'left', -padx => px(4));
    $pill = $in->Label(-text => '', -font => $UI_B, -padx => px(12), -pady => px(4))->pack(-side => 'right');
    rule($mw, 'x', -side => 'top');
}

#------------------------------------------------------------------------------
# build_network -- the NETWORK tab: the command strip across the top, the
# editor with its line numbers and status bar, the three lists on the right.
#------------------------------------------------------------------------------
sub build_network {
    my $page = shift;
    build_strip($page);
    my $hp = divider($page, 'horizontal');
    my $left  = $page->Frame(-background => $C{paper});
    my $right = $page->Frame(-background => $C{paper});

    # The status bar, under the editor.
    my $sb = $left->Frame(-background => $C{panel})->pack(-side => 'bottom', -fill => 'x');
    rule($sb, 'x', -side => 'top');
    $statusbar = $sb->Text(-height => 1, -wrap => 'none', -font => $MONO, -background => $C{panel},
        -foreground => $C{ink}, -borderwidth => 0, -highlightthickness => 0, -padx => px(14), -pady => px(6),
        -state => 'disabled', -cursor => $POINTER, -takefocus => 0)->pack(-fill => 'x');
    $statusbar->tagConfigure('current', -foreground => $C{accent}, -font => $MONO_B, -underline => 1);
    $statusbar->tagConfigure('muted', -foreground => $C{muted});
    $statusbar->tagConfigure('bad', -foreground => $C{error}, -font => $MONO_B);
    $statusbar->tagConfigure('good', -foreground => $C{accent}, -font => $MONO_B);

    # The editor: line numbers, text, scrollbars.  The gutter is a second
    # Text in the same font, scrolled with the editor, so its numbers stay
    # level with the lines however the editor is scrolled.
    my $ef = $left->Frame(-background => $C{paper})->pack(-fill => 'both', -expand => 1);
    my $vsb = flat_scrollbar($ef, 'vertical')->pack(-side => 'right', -fill => 'y');
    my $hsb = flat_scrollbar($ef, 'horizontal')->pack(-side => 'bottom', -fill => 'x');
    $gutter = $ef->Text(-width => 5, -wrap => 'none', -font => $MONO, -background => $C{panel},
        -foreground => $C{faint}, -borderwidth => 0, -highlightthickness => 0, -padx => px(6), -pady => px(6),
        -state => 'disabled', -cursor => $POINTER, -takefocus => 0, -spacing1 => 1, -spacing3 => 1)
        ->pack(-side => 'left', -fill => 'y');
    $gutter->tagConfigure('num', -justify => 'right');
    $gutter->tagConfigure('cur', -foreground => $C{ink}, -font => $MONO_B);
    $gutter->tagConfigure('bad', -foreground => $C{error}, -font => $MONO_B);
    $gutter->bind('<ButtonRelease-1>' => sub {
        my ($n) = $gutter->index('current') =~ /^(\d+)/;
        go_to_line($n) if $n;
    });
    rule($ef, 'y', -side => 'left');
    $ed = $ef->TextUndo(-wrap => 'none', -font => $MONO, -background => $C{paper}, -foreground => $C{ink},
        -insertbackground => $C{ink}, -insertwidth => px(2), -selectbackground => $C{select},
        -selectforeground => $C{ink}, -borderwidth => 0, -highlightthickness => 0, -padx => px(10), -pady => px(6),
        -spacing1 => 1, -spacing3 => 1, -exportselection => 1,
        -yscrollcommand => sub { $vsb->set(@_); $gutter->yviewMoveto($_[0]) },
        -xscrollcommand => sub { $hsb->set(@_) })->pack(-side => 'left', -fill => 'both', -expand => 1);
    $vsb->configure(-command => sub { $ed->yview(@_) });
    $hsb->configure(-command => sub { $ed->xview(@_) });
    wheel_target($ed);
    wheel_target($gutter, $ed);       # the wheel over the numbers scrolls the editor

    # Syntax colours.  Blue for command words and keywords, black bold for a
    # name being defined, dark blue for numbers, grey italic for comments.
    # Behind a line in error, a pale red; behind the exact field validation
    # found at fault, a deeper red with the text underlined.
    $ed->tagConfigure('curline', -background => $C{curline});
    $ed->tagConfigure('command', -foreground => $C{accent}, -font => $MONO_B);
    $ed->tagConfigure('keyword', -foreground => $C{accent});
    $ed->tagConfigure('name',    -foreground => $C{ink}, -font => $MONO_B);
    $ed->tagConfigure('ref',     -foreground => $C{ink});
    $ed->tagConfigure('number',  -foreground => $C{number});
    $ed->tagConfigure('comment', -foreground => $C{muted}, -font => $MONO_I);
    $ed->tagConfigure('error',   -background => $C{error_bg});
    $ed->tagConfigure('fault',   -background => $C{fault_bg}, -foreground => $C{error}, -underline => 1);
    $ed->tagConfigure('proposal', -foreground => $C{proposal}, -font => $MONO_I);
    $ed->tagLower('curline');
    $ed->tagRaise('error');
    $ed->tagRaise('fault');
    $ed->tagRaise('proposal');
    $ed->tagRaise('sel');

    # The three lists.
    for my $name (qw(ERRORS WARNINGS NODES)) {
        my $f = $right->Frame(-background => $C{paper})->pack(-fill => 'both', -expand => 1);
        $list_head{$name} = $f->Label(-text => $name, -font => $UI_S, -anchor => 'w', -background => $C{paper},
            -foreground => $C{muted}, -padx => px(14), -pady => px(8))->pack(-side => 'top', -fill => 'x');
        $list{$name} = $f->Listbox(-height => 5, -font => $MONO, -background => $C{paper},
            -foreground => $name eq 'ERRORS' ? $C{error} : $name eq 'WARNINGS' ? $C{warn} : $C{ink},
            -selectbackground => $C{select}, -selectforeground => $C{ink}, -relief => 'flat',
            -borderwidth => 0, -highlightthickness => 0, -activestyle => 'none', -cursor => $POINTER)
            ->pack(-fill => 'both', -expand => 1, -padx => px([14, 4]), -pady => px([0, 6]));
        wheel_target($list{$name});
        rule($f, 'x', -side => 'bottom') unless $name eq 'NODES';
        $list_lines{$name} = [];
        my $n = $name;
        $list{$name}->bind('<ButtonRelease-1>' => sub { go_to_list($n) });
    }
    $hp->add($left, -width => px(1000));
    $hp->add($right);
    $hp->pack(-fill => 'both', -expand => 1);
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
    $mw->bind('PhcEditor', '<Return>'          => sub { on_return(); Tk->break });
    $mw->bind('PhcEditor', '<Tab>'             => sub { on_tab() and Tk->break });
    $mw->bind('PhcEditor', '<KeyPress>'        => \&on_key);
    $mw->bind('PhcEditor', '<ButtonPress>'     => sub { discard_proposal() });
    $mw->bind('PhcEditor', '<ButtonPress-3>'   => sub { Tk->break });   # no bevelled pop-up menu
    $mw->bind('PhcEditor', '<KeyRelease>'      => sub { after_change() });
    $mw->bind('PhcEditor', '<ButtonRelease>'   => sub { update_status() });
    $mw->bind('PhcEditor', '<Control-space>'   => sub { pick_list(); Tk->break });
    $mw->bind('PhcEditor', '<Control-z>'       => sub { undo(); Tk->break });
    $mw->bind('PhcEditor', '<Control-y>'       => sub { redo(); Tk->break });
    $mw->bind('<F4>'        => sub { validate() });
    $mw->bind('<F5>'        => sub { calculate() });
    $mw->bind('<Control-n>' => sub { file_new() });
    $mw->bind('<Control-o>' => sub { file_open() });
    $mw->bind('<Control-s>' => sub { file_save() });
    $mw->bind('<Control-r>' => sub { file_report() });
    $mw->bind('<Control-q>' => sub { file_quit() });
    $mw->protocol('WM_DELETE_WINDOW' => sub { file_quit() });
    bind_wheel();
}

#------------------------------------------------------------------------------
# The mouse wheel scrolls what is under the pointer.
#
# Windows sends wheel events to the widget with the keyboard focus, so with
# the cursor in the editor the wheel over the results table scrolled the
# editor and the table could not be scrolled at all.  Every scrollable pane
# is registered here (wheel_target puts a 'PhcWheel' tag first in its
# bindtags); a wheel event, wherever it is delivered, is passed to the
# registered pane under the pointer, and goes no further.  The same binding
# on the main window catches the wheel when the focus is in a field of the
# PROJECT tab.  On Linux the wheel arrives as buttons 4 and 5.
#------------------------------------------------------------------------------
our %WHEEL;                      # widget path => the widget the wheel scrolls
sub wheel_target {
    my ($w, $target) = @_;
    $WHEEL{ $w->PathName } = $target // $w;
    $w->bindtags([ 'PhcWheel', grep { $_ ne 'PhcWheel' } $w->bindtags ]);
}

sub route_wheel {
    my ($units, $X, $Y) = @_;           # lines to scroll; the pointer on the screen
    my $w = $mw->containing($X, $Y);
    $w = $w->parent while $w && !$WHEEL{ $w->PathName } && $w ne $mw;
    my $t = $w && $WHEEL{ $w->PathName } or return;
    $t->yview('scroll', $units, 'units');     # the form every scrollable widget takes
    Tk->break;
}

sub bind_wheel {
    for my $tag ('PhcWheel', $mw) {
        # Windows: 120 per notch of the wheel, three lines a notch.
        $mw->bind($tag, '<MouseWheel>' => [ sub { my (undef, $d, $X, $Y) = @_;
            route_wheel($d > 0 ? -3 * (int($d / 120) || 1) : 3 * (int(-$d / 120) || 1), $X, $Y) },
            Ev('D'), Ev('X'), Ev('Y') ]);
        $mw->bind($tag, '<Button-4>' => [ sub { route_wheel(-3, $_[1], $_[2]) }, Ev('X'), Ev('Y') ]);
        $mw->bind($tag, '<Button-5>' => [ sub { route_wheel(3,  $_[1], $_[2]) }, Ev('X'), Ev('Y') ]);
    }
}

# text_widget -- the Text where keys arrive (the editor itself).
sub text_widget { $ed }

#==============================================================================
# Buffer helpers.
#==============================================================================

# buffer -- the network text, without a proposal that is only on offer.
sub buffer {
    my $t = $ed->get('1.0', 'end - 1 chars');
    return $t unless $prop{active};
    return $ed->get('1.0', 'pstart') . $ed->get('pend', 'end - 1 chars');
}

# doc -- the document: the PROJECT tab's settings and the editor's network.
sub doc { return { settings => $settings, network => buffer() } }

# full_text -- the whole .phc file the document makes.
sub full_text { return (HardyCross::Editor::join_file($settings, buffer()))[0] }

# set_buffer -- replace the network text, as when a file is opened.
sub set_buffer {
    my $text = shift;
    discard_proposal();
    $ed->delete('1.0', 'end');
    $ed->insert('1.0', $text);
    text_widget()->ResetUndo;    # undo does not reach back past an open
    $saved_text = full_text();
    $ed->markSet('insert', '1.0');
    ($solved, $validation, $valid_text) = (undef, undef, undef);
    fill_results();
    fill_validation();
    recolour();
    update_actions();
    update_status();
}

# cursor -- (line, column) of the insertion point.
sub cursor { split /\./, $ed->index('insert') }

# go_to_line -- put the cursor at line $n, show it; select columns $a to $b
# if given, otherwise the whole line.
sub go_to_line {
    my ($n, $a, $b) = @_;
    return unless $n;
    select_tab($toptabs, 'NETWORK');
    $ed->tagRemove('sel', '1.0', 'end');
    if (defined $a) {
        $ed->markSet('insert', "$n.$a");
        $ed->tagAdd('sel', "$n.$a", "$n.$b");
    } else {
        $ed->markSet('insert', "$n.0");
        $ed->tagAdd('sel', "$n.0", "$n.0 lineend");
    }
    $ed->see('insert');
    $ed->focus;
    update_status();
}

# go_to_list -- a click in ERRORS, WARNINGS or NODES: to the line, or for a
# setting to its field in the PROJECT tab.
sub go_to_list {
    my $name = shift;
    my ($i) = $list{$name}->curselection;
    return unless defined $i;
    my $e = $list_lines{$name}[$i] or return;
    return show_field($e->{field}) if $e->{field};
    go_to_line($e->{line});
}

#==============================================================================
# Colouring, line numbers, the three lists, the status bar.
#==============================================================================

# after_change -- after a key: the status bar at once, the full re-check
# shortly after typing pauses.
sub after_change {
    update_status();
    $recolour_job->cancel if $recolour_job;
    $recolour_job = $mw->after(250, sub { $recolour_job = undef; recolour() });
    set_title();
    update_actions();
}

# recolour -- re-check every line; colour it, number it, and refill the lists.
sub recolour {
    my $text = buffer();
    my ($line) = cursor();
    my $res = HardyCross::Editor::doc_check(doc(), $line);
    my @l = split /\n/, $text, -1;
    $ed->tagRemove($_, '1.0', 'end') for qw(command keyword name ref number comment error);
    my @bad;
    for my $i (1 .. @l) {
        for my $s (HardyCross::Editor::colour_spans($l[ $i - 1 ])) {
            my ($a, $b, $tag) = @$s;
            $ed->tagAdd($tag, "$i.$a", "$i.$b");
        }
        my $st = ($res->{lines}[$i] || {})->{status} // 'ok';
        # An incomplete line is still being typed while the cursor is on it;
        # anywhere else it is as wrong as an error.
        if ($st eq 'error' || ($st eq 'incomplete' && $i != $line)) {
            $ed->tagAdd('error', "$i.0", "$i.0 lineend + 1 chars");
            push @bad, $i;
        }
    }
    # Validation marks belong to the text they were found in.
    $ed->tagRemove('fault', '1.0', 'end') unless $validation && $validation->{text} eq full_text();
    refresh_gutter(\@bad);

    # Warnings belong to the last calculation; they are shown until the next.
    my $d = HardyCross::Editor::doc_diagnostics(doc(), $solved ? $solved->{net} : undef, $line);
    for my $name (qw(ERRORS WARNINGS NODES)) {
        my $lb = $list{$name};
        my @e = @{ $d->{ lc $name } };
        $lb->delete(0, 'end');
        $list_lines{$name} = [];
        for my $p (@e) {
            $lb->insert('end', defined $p->{line} ? sprintf('%5d  %s', $p->{line}, $p->{message})
                                                  : "       $p->{message}");
            push @{ $list_lines{$name} }, $p;
        }
        $list_head{$name}->configure(-text => @e ? "$name  " . scalar(@e) : $name,
            -foreground => !@e ? $C{muted} : $name eq 'ERRORS' ? $C{error} : $name eq 'WARNINGS' ? $C{warn} : $C{ink});
    }
    return $res;
}

# refresh_gutter -- the line numbers: one per line, the cursor's in black,
# lines in error in red.
sub refresh_gutter {
    my $bad = shift || [];
    my ($n) = $ed->index('end - 1 chars') =~ /^(\d+)/;
    my ($cur) = cursor();
    $gutter->configure(-state => 'normal');
    if ($n != $gutter_lines) {
        $gutter->delete('1.0', 'end');
        $gutter->insert('1.0', join("\n", 1 .. $n), 'num');
        $gutter_lines = $n;
    }
    $gutter->tagRemove($_, '1.0', 'end') for qw(cur bad);
    $gutter->tagAdd('bad', "$_.0", "$_.0 lineend") for @$bad;
    $gutter->tagAdd('cur', "$cur.0", "$cur.0 lineend");
    $gutter->configure(-state => 'disabled');
    $gutter->yviewMoveto(($ed->yview)[0]);
}

# gutter_numbers -- the numbers the gutter shows (for the tests).
sub gutter_numbers { return split /\n/, $gutter->get('1.0', 'end - 1 chars') }

# update_status -- the status bar for the cursor's line: the command's field
# template with the field the cursor is in highlighted, then the line's
# message if it has one, or after a calculation the element's results.
sub update_status {
    my $text = buffer();
    my ($n, $col) = cursor();
    $ed->tagRemove('curline', '1.0', 'end');
    $ed->tagAdd('curline', "$n.0", "$n.0 lineend + 1 chars");
    refresh_gutter([ map { /^(\d+)/ ? $1 : () } $gutter->tagRanges('bad') ]) if $gutter;
    # A message (calculated, saved ...) stays until something changes;
    # otherwise the key release that follows F5 would wipe it at once.
    if ($notice) {
        return if $notice->[2] eq where($text);
        $notice = undef;
    }
    my $st = HardyCross::Editor::doc_status(doc(), $n, $col);
    $statusbar->configure(-state => 'normal');
    $statusbar->delete('1.0', 'end');
    if (my $t = $st->{template}) {
        if ($t->{command}) {
            $statusbar->insert('end', "$t->{command} ", 'muted');
            my @f = @{ $t->{fields} };
            for my $i (0 .. $#f) {
                $statusbar->insert('end', $f[$i], ($i == $t->{current} ? 'current' : 'muted'));
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
        $r .= '   (CALCULATED BEFORE THE LATEST EDITS)' if defined $r && full_text() ne $solved->{text};
        $extra = [ $r ] if defined $r;
    }
    if ($extra) {
        $statusbar->insert('end', '   |   ', 'muted');
        $statusbar->insert('end', $extra->[0], ($extra->[1] ? $extra->[1] : ()));
    }
    $statusbar->configure(-state => 'disabled');
    return $st;
}

# status_text -- what the status bar shows, as plain text (for the tests).
sub status_text { my $s = $statusbar->get('1.0', 'end - 1 chars'); $s =~ s/\s+$//; $s }

# where -- the document and cursor as one string: a message stays while this
# is unchanged.
sub where { my $text = shift // buffer(); return join "\x00", $ed->index('insert'), $text, full_text() }

# message -- a message in the status bar, kept until the text or cursor moves.
sub message {
    my ($text, $bad) = @_;
    $notice = [ $text, $bad, where() ];
    $statusbar->configure(-state => 'normal');
    $statusbar->delete('1.0', 'end');
    $statusbar->insert('end', uc($text), ($bad ? 'bad' : 'good'));
    $statusbar->configure(-state => 'disabled');
}

#------------------------------------------------------------------------------
# update_actions -- CALCULATE on or off, and the state shown on the right of
# the toolbar.  CALCULATE is on only while the whole file is exactly as it
# was when it last passed VALIDATE; any edit, to the network or in the
# PROJECT tab, turns it off until VALIDATE is run again.
#------------------------------------------------------------------------------
sub update_actions {
    return unless $btn{CALCULATE};
    my $full = full_text();
    my $valid = defined $valid_text && $valid_text eq $full;
    $btn{CALCULATE}->configure($valid
        ? (-state => 'normal', -background => $C{accent}, -highlightbackground => $C{accent})
        : (-state => 'disabled', -background => $C{panel}, -highlightbackground => $C{line}));
    my ($text, $fg, $bg);
    if ($solved && $solved->{text} eq $full) {
        ($text, $fg, $bg) = $solved->{converged} ? ('CALCULATED', $C{accent}, $C{accent_bg})
                                                 : ('DID NOT CONVERGE', $C{error}, $C{error_bg});
    } elsif ($valid) {
        ($text, $fg, $bg) = ('VALID - READY TO CALCULATE', $C{accent}, $C{accent_bg});
    } elsif ($validation && $validation->{text} eq $full) {
        my $n = @{ $validation->{items} };
        ($text, $fg, $bg) = ("$n PROBLEM" . ($n == 1 ? '' : 'S') . ' - SEE VALIDATION', $C{error}, $C{error_bg});
    } else {
        ($text, $fg, $bg) = ('NOT VALIDATED', $C{muted}, $C{hover});
    }
    $pill->configure(-text => $text, -foreground => $fg, -background => $bg);
}

# calculate_enabled / state_text -- for the tests.
sub calculate_enabled { return $btn{CALCULATE}->cget(-state) eq 'normal' }
sub state_text { return $pill->cget(-text) }

#==============================================================================
# The command strip: the network commands, in their groups.  A click starts a
# line with that command, on the current line if it is empty or a new one
# below it.  The settings commands are not here: they are the PROJECT tab.
#==============================================================================
sub build_strip {
    my $parent = shift;
    $strip = $parent->Frame(-background => $C{paper})->pack(-side => 'top', -fill => 'x', -padx => px(8), -pady => px(6));
    my @groups = @HardyCross::Phc::COMMAND_GROUPS[1 .. $#HardyCross::Phc::COMMAND_GROUPS];
    my $first = 1;
    for my $group (@groups) {
        $strip->Frame(-background => $C{line}, -width => 1, -height => px(16))->pack(-side => 'left', -padx => px(8))
            unless $first;
        $first = 0;
        for my $cmd (@$group) {
            my $l = $strip->Label(-text => $cmd, -font => $MONO_B, -background => $C{paper},
                                  -foreground => $C{accent}, -padx => px(6), -pady => px(3), -cursor => 'hand2')
                          ->pack(-side => 'left');
            $l->bind('<Enter>' => sub { $l->configure(-background => $C{accent_bg}) });
            $l->bind('<Leave>' => sub { $l->configure(-background => $C{paper}) });
            $l->bind('<ButtonRelease-1>' => sub { start_command($cmd) });
        }
    }
    rule($parent, 'x', -side => 'top');
}

# start_command -- begin a line with a command, ready for its first field.
sub start_command {
    my $cmd = shift;
    discard_proposal();
    select_tab($toptabs, 'NETWORK');
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
    return map { $_->cget(-text) } grep { $_->isa('Tk::Label') } $strip->children;
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
# In a USE type or a pipe's fittings: a list of the choices with their
# descriptions.  Arrows move, Enter or a double-click inserts over any part
# already typed, Escape closes.
#==============================================================================
sub pick_list {
    discard_proposal();
    my ($n, $col) = cursor();
    my $ch = HardyCross::Editor::doc_choices(doc(), $n, $col);
    unless (@$ch) {
        message('NO PICK LIST HERE: CTRL+SPACE WORKS IN A USE TYPE OR A PIPE FITTING');
        return;
    }
    my $top = $mw->Toplevel(-background => $C{line});
    $top->overrideredirect(1);
    $top->transient($mw);
    my $lb = $top->Listbox(-height => 14, -width => 64, -font => $MONO, -background => $C{paper},
        -foreground => $C{ink}, -selectbackground => $C{select}, -selectforeground => $C{ink},
        -activestyle => 'none', -relief => 'flat', -borderwidth => 0, -highlightthickness => 0)
        ->pack(-fill => 'both', -expand => 1, -padx => px(1), -pady => px(1));
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
    $lb->bind('<Escape>' => sub { $top->destroy; $ed->focus });
    $lb->bind('<FocusOut>' => sub { $top->destroy if Tk::Exists($top) });
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
# VALIDATE (F4) and CALCULATE (F5).
#==============================================================================

#------------------------------------------------------------------------------
# validate -- check everything, list what is wrong, mark it in the editor.
# When nothing is wrong the text is remembered, and CALCULATE is available
# until the text changes.
#------------------------------------------------------------------------------
sub validate {
    discard_proposal();
    my $full = full_text();
    my $v = HardyCross::Editor::validate(doc());
    $validation = { %$v, text => $full };
    $valid_text = $v->{ok} ? $full : undef;
    $ed->tagRemove('fault', '1.0', 'end');
    for my $it (@{ $v->{items} }) {
        next unless defined $it->{line};
        # A line that stops short is at fault just past its end, where
        # nothing can be seen; its last word is marked instead.
        my ($a, $b) = ($it->{start}, $it->{end});
        my $len = length $ed->get("$it->{line}.0", "$it->{line}.0 lineend");
        if ($a >= $len) {
            my $code = $ed->get("$it->{line}.0", "$it->{line}.0 lineend");
            ($a, $b) = $code =~ /(\S+)\s*\z/ ? ($-[1], $+[1]) : (0, $len);
        }
        $ed->tagAdd('fault', "$it->{line}.$a", "$it->{line}.$b");
    }
    fill_validation();
    select_tab($restabs, 'VALIDATION');
    recolour();
    update_actions();
    my $n = @{ $v->{items} };
    message($v->{ok} ? 'VALID - NO PROBLEMS FOUND. CALCULATE (F5) IS NOW AVAILABLE'
                     : "$n PROBLEM" . ($n == 1 ? '' : 'S') . ' FOUND - SEE VALIDATION BELOW; CLICK ONE TO GO TO IT',
            !$v->{ok});
    return $v;
}

#------------------------------------------------------------------------------
# calculate -- solve the model.  Refused unless the text is exactly what last
# passed VALIDATE.
#------------------------------------------------------------------------------
sub calculate {
    discard_proposal();
    my $full = full_text();
    unless (defined $valid_text && $valid_text eq $full) {
        message('VALIDATE THE INPUTS FIRST (F4): CALCULATE RUNS ONLY ON A MODEL THAT HAS PASSED VALIDATION', 1);
        return { ok => 0, not_validated => 1 };
    }
    my $r = HardyCross::Editor::doc_solve(doc(), $path);
    if (!$r->{ok}) {
        $solved = undef;
        fill_results();
        fill_report("THE MODEL WAS NOT CALCULATED\n\n$r->{error}\n");
        go_to_line($r->{line}) if $r->{line};
        recolour();
        update_actions();
        message($r->{error}, 1);
        return $r;
    }
    $solved = { net => $r->{net}, converged => $r->{converged}, text => $full };
    fill_results();
    fill_report($r->{report});
    select_tab($restabs, 'PIPES');
    recolour();          # the WARNINGS list is the calculation's
    update_actions();
    message($r->{converged} ? 'CALCULATED - CONVERGED'
                            : 'CALCULATED - DID NOT CONVERGE: THE RESULTS MUST NOT BE USED', !$r->{converged});
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
# Files.
#==============================================================================

# set_title -- the file name, and * when there are unsaved changes.
sub set_title {
    my $name = $path // 'UNTITLED.PHC';
    $name =~ s{.*[/\\]}{};
    $mw->title('PHCP EDITOR - ' . uc($name) . ($ed && modified() ? ' *' : ''));
}

# modified -- whether the file differs from what was last opened or saved.
sub modified { full_text() ne $saved_text }

# ok_to_discard -- true if nothing is unsaved, or the user agrees to lose it.
sub ok_to_discard {
    return 0 unless db_ok_to_leave();
    return 0 unless graph_ok_to_discard();
    return 1 unless modified();
    my $a = $mw->messageBox(-title => 'UNSAVED CHANGES', -icon => 'warning', -type => 'YesNo',
        -message => 'THE MODEL HAS UNSAVED CHANGES.  DISCARD THEM?');
    return lc($a) eq 'yes';
}

sub file_new {
    return unless ok_to_discard();
    $path = undef;
    load_settings(HardyCross::Editor::new_settings());
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

# open_path -- load a .phc file: its settings into the PROJECT tab, its
# network into the editor.
sub open_path {
    my $f = shift;
    my $r = eval { HardyCross::Editor::load_file($f) };
    unless ($r) {
        my $e = $@;
        message(HardyCross::is_model_error($e) ? $e->{msg} : "$e", 1);
        return;
    }
    my $d = HardyCross::Editor::split_file($r->{text});
    $path = $r->{path};
    load_settings($d->{settings});
    set_buffer($d->{network});
    select_tab($toptabs, 'NETWORK');
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

# write_buffer -- save the whole file, settings and network, ending with a
# newline.
sub write_buffer {
    my $f = shift;
    my $text = full_text();
    $text .= "\n" unless $text =~ /\n\z/;
    my $fh;
    unless (open $fh, '>', $f) { message("CANNOT WRITE $f: $!", 1); return 0 }
    print $fh $text;
    close $fh;
    $saved_text = full_text();
    message("SAVED $f");
    set_title();
    return 1;
}

# file_report -- validate and calculate if the last calculation is not of
# this text, then write the report as .pdf or .txt by the extension chosen.
sub file_report {
    my $out = shift;
    unless ($solved && $solved->{text} eq full_text()) {
        return unless validate()->{ok};
        return unless calculate()->{ok};
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
