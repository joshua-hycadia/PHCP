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
# Layout of this file:
#   colours and fonts          white and matte; blue and black for highlights
#   widget helpers             flat buttons, tabs, check boxes, drop-downs
#   build_window               the widgets
#   recolour / update_status   syntax colours, line numbers, lists, status bar
#   command strip              the commands, a click starts a line
#   PROJECT tab                title, project details, units, method, options
#   GRAPH tab                  a Q^1.85 water supply graph from figures typed in
#   QUICK TOOLS tab            velocity, K-factor and pressure loss calculators
#   tables                     the results: sort, column chooser, hide boxes
#   proposals                  the greyed next line, accepted by Enter or Tab
#   pick_list                  Ctrl+Space
#   validate / calculate       F4 / F5
#   files                      NEW OPEN SAVE SAVE AS WRITE REPORT
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
        iVBORw0KGgoAAAANSUhEUgAAADAAAAAwCAYAAABXAvmHAAAGdUlEQVR42u2aW2ycRxWAvzPz
        779eZ+04di5ucTaOTRqwEhIIRSUPRWlUKuUiKioQUksSBalKGniAQnktF3EpKpQ+UCkPBXFR
        JUBEEEFLozRB0DzVKSmkKaSubSJVJG28vuxudvf/Zw4P693YTZy1nTgX5CPtw/7/aOZ8c86c
        mXPmF2qiAqIAy3cc7jY2uQv121HtAk1X3l9PEQXJIfIWYg56V/rZmZ9v7nuvrjLpwSeOBJmV
        weNGZK/YsFV9GfUxqHJDRAQxAWJC1JWHvOoz/+mPH+cvm+KqzlKd2WUPvdjYEDT+3jY0b3bF
        YVDnUAwiwo0UVUXwiLW2oQVXHD1cjAufOvvLTxYqFvjMr+2GRV3mndLYn21y4SZXzEYiEsAN
        VvxyJKqxbViUcKWRI0uSTff1Zt/yltd/o2HP574RNC7e6YtDZRET3nzKV/xJRKy6YjlILX5/
        vpCVkee2HZbO3YdXqLP/REwjGsvNqfxkSyCBor4g1q0x3pmHTaIxjcZ68ys/vrI1VpNoTHtn
        Hg4E3a4+UlSEKdQ3ItcFTQHvpxHxVER9pIJuD1DpVh8JU6gvAvliTDme+1AaWCHdYKk7kmDU
        R6DSHSDSOFWcNyLki45d93Zw5x0L8aqYOTBFtd83387z9B8GSSYsWm/vUQWRxoAr8IpAKfLc
        vbaVrXcumXMLnOgf5ckDAzQkQKfpdME0lgz5CzHOK84r1ghep/ZVYwQjFQVkfKKcn9rCxlDr
        d7QQM1P7BtNpZIxgTaVrawQLYGVGvl1P7IQxrjnARV8FCwycvcCxU1mSCVNbPlV32/jBRXQu
        S+G9YoxwbqTMS38/T8JKzS1EoFT2rO9upieTvqqj1swAvIIVjp3K8uATJ2hrCmvuYY1wfqzM
        rx5bR+eyFLFXQiO8cSbHjidfo6khwI9rGgTCu8Mlvrf7A/Rk0rV+5xygKsmEYXFzyKJ0YhKA
        SOXdREkEQltTgvREACuoV1KhufrQO8vNnNhpbWFXJXZ6iTtUF7HzWgMQqbT112BrMdziMg8w
        DzAPMA8wDzAPcEOkevSYnGgx4xPpDQEwIgznI6LIg/doHKPeETslm4sQpl9euK4AMv7L5iL2
        blnOZ+++DYwhmQoRY1mzspmvfrqTQtnh/fQgZnWYE6mcKAN70Q2smfz/cm1ByOYivvX5VezZ
        mgFgtLeXYn8/4e23s+jjd/Htnav56KqFPPKTU4TTIJgVQCnyvDtcxk84jVojDI1GlCI/qW0U
        K++MlIli5fxYxCNbOtizNUPhv2fp+8qXGX35ZXzsEGtIr/0QXT/8EfdvXMUbZ3J8/7cDtDYl
        pkxJZwxQXV/ru5r57u7VpJKTM7ILJc/6ruYaEMDKZSm+s+sOkoGlFDke2nQb3jn6Hn2U7KFD
        hO3t2EqFgbHjvZz+4j7WHTjAnq0r+MVLbzN6wVXyB70WAONK9WTS9GTSdaMMwPIlKb72QNek
        d6PHjzP6t78StrejcVx7Hi5ZQuHkPxg6epSl27ayobuJP/YO0bIgwE1BMC0APyEpmZikyGUq
        a+8NjxPbeucIw4BiXx/eucrMT0p+KrWM/L9PowrtLWHdSl1dAFVIheaSqkEwm6rEeLqZ7OhA
        jLkkzFSuIpRUZjkicH4sqltIC+opnwiEk4M52poTeA/GzDaECrHzfLi7ifRHNpBet46xV14h
        sXQpOAfGEA0Pk8x00nbPPeRLjlf7c6SSppaKXrbfFTuPaL3YXYo9sau4wWzT2MAIQ7mIxx7o
        5Js7VjPyr9O8uW8vhZMna5ZILs/Q/eOnabvrY+z/0yBf/+npulGoLkA1wghy1buYAIWS45l9
        Pdy/sR2iEueef5FCXx/Jjg6W3Xcvpnkhx14f4sEfvFaxuFx50mTFzqM6+3md+QboPUTO86Vt
        Gb6wpZOlzRe9eLioPHdokCd+N0AUK2EgdSoXgqzYcSSPmbpCPRcQqjCSj3lfa5L1KxewtCUk
        m4s4MZCn/1yR5lSANVxZeRHwWggQ7RMTrtG4rMjcn42q89TalGDkQswLr2ZxXjEGUqGlNZ3A
        a52akeLFJkS11BcoctCYxFqVkofrd8PkvBJYYeGCYMJ+o1dcsBdnX1VMwnhXPmiM9ft9VMgh
        gVzvG+2JVTvndZqjqyKB+KiQM9bvNwPPbh7E+6dsQ4sBolsgCYtsQ4vB+6cGnt08eMtfdP8f
        fGpQaXUrf+xRQ70lP7f5H0BeSZcukCjgAAAAAElFTkSuQmCC
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
# The PROJECT tab: the title and project details, the units, the method and
# the options.  Each field is tied to $settings; a change marks the file
# modified and turns CALCULATE off until VALIDATE is run again.  Text is
# kept in capitals as it is typed.
#==============================================================================
sub build_project {
    my $page = shift;
    # The form scrolls: on a short window, or with the results pane dragged
    # up, the CALCULATION options run below the bottom edge.  A canvas holds
    # the form, with the same thin scrollbar as the rest of the window.
    my $sb = flat_scrollbar($page, 'vertical')->pack(-side => 'right', -fill => 'y');
    my $cv = $page->Canvas(-background => $C{paper}, -highlightthickness => 0, -borderwidth => 0,
                           -yscrollcommand => sub { $sb->set(@_) })->pack(-fill => 'both', -expand => 1);
    $sb->configure(-command => sub { $cv->yview(@_) });
    my $wrap = $cv->Frame(-background => $C{paper});
    $cv->createWindow(px(18), px(12), -window => $wrap, -anchor => 'nw');
    $wrap->bind('<Configure>' => sub {
        $cv->configure(-scrollregion => [ 0, 0, $wrap->reqwidth + px(36), $wrap->reqheight + px(24) ]);
    });
    wheel_target($cv);
    $project_canvas = $cv;
    my $column = sub {
        my ($title) = @_;
        my $c = $wrap->Frame(-background => $C{paper})->pack(-side => 'left', -fill => 'y', -anchor => 'n', -padx => px([0, 26]));
        $c->Label(-text => $title, -font => $UI_B, -background => $C{paper}, -foreground => $C{ink}, -anchor => 'w')
          ->pack(-fill => 'x');
        rule($c, 'x', -pady => px([4, 8]));
        my $g = $c->Frame(-background => $C{paper})->pack(-fill => 'x');
        return $g;
    };
    my $row = 0;
    my $label = sub {
        my ($g, $text) = @_;
        $g->Label(-text => $text, -font => $UI, -background => $C{paper}, -foreground => $C{muted}, -anchor => 'w')
          ->grid(-row => $row, -column => 0, -sticky => 'w', -pady => px(3), -padx => px([0, 14]));
    };
    my $entry = sub {
        my ($g, $field, $var, $width) = @_;
        my $e = flat_entry($g, $var, $width);
        $e->grid(-row => $row, -column => 1, -sticky => 'w', -pady => px(3), -ipady => px(3));
        $e->bind('<KeyRelease>' => sub { settings_changed() });
        $form{$field} = $e;
        $row++;
    };

    my @f = @HardyCross::Editor::PROJECT_FIELDS;
    my $split = 9;           # PROJECT ... DATE in the first column
    my $g = $column->('PROJECT DETAILS');
    $row = 0;
    $label->($g, 'TITLE');
    $entry->($g, 'TITLE', \$settings->{title}, 34);
    for my $k (@f[0 .. $split]) {
        $settings->{project}{$k} //= '';
        $label->($g, HardyCross::Editor::project_label($k));
        $entry->($g, $k, \$settings->{project}{$k}, 34);
    }
    $g = $column->('DESIGN BASIS');
    $row = 0;
    for my $k (@f[ $split + 1 .. $#f ]) {
        $settings->{project}{$k} //= '';
        $label->($g, HardyCross::Editor::project_label($k));
        $entry->($g, $k, \$settings->{project}{$k}, 22);
    }

    $g = $column->('UNITS');
    $row = 0;
    for my $q (@HardyCross::Phc::UNIT_QUANTITIES) {
        $label->($g, $HardyCross::Editor::UNIT_LABEL{$q});
        my $dd = drop_down($g, \$settings->{units}{$q}, $HardyCross::Phc::UNIT_CHOICES{$q}, sub { settings_changed() },
                            $HardyCross::Phc::UNIT_DEFAULT{$q});
        $dd->grid(-row => $row, -column => 1, -sticky => 'w', -pady => px(3));
        $form{$q} = $dd;
        $row++;
    }

    # CALCULATION: each option with a plain label, its .phc name small and
    # grey beside it, and a line under it saying what it does and what a
    # blank means (HardyCross::Editor::@OPTION_FORM).
    $g = $column->('CALCULATION');
    $row = 0;
    my $help = sub {
        my ($text) = @_;
        $g->Label(-text => $text, -font => $UI_S_N, -background => $C{paper}, -foreground => $C{muted},
                  -justify => 'left', -anchor => 'w', -wraplength => px(300))
          ->grid(-row => $row++, -column => 0, -columnspan => 2, -sticky => 'w', -pady => px([0, 6]));
    };
    my $name = sub {
        my ($text, $key) = @_;
        my $f = $g->Frame(-background => $C{paper});
        $f->Label(-text => $text, -font => $UI, -background => $C{paper}, -foreground => $C{ink})->pack(-side => 'left');
        $f->Label(-text => $key, -font => $UI_S_N, -background => $C{paper}, -foreground => $C{faint})
          ->pack(-side => 'left', -padx => px([6, 0]));
        $f->grid(-row => $row, -column => 0, -sticky => 'w', -pady => px([3, 0]), -padx => px([0, 14]));
    };
    $name->('FRICTION FORMULA', 'METHOD');
    my $dd = drop_down($g, \$settings->{method}, [qw(HW DW)], sub { settings_changed() });
    $dd->grid(-row => $row++, -column => 1, -sticky => 'w', -pady => px([3, 0]));
    $form{METHOD} = $dd;
    $help->('HW HAZEN-WILLIAMS, THE SPRINKLER STANDARD\'S METHOD. DW DARCY-WEISBACH, WITH ROUGHNESS IN PLACE OF C.');
    for my $o (@HardyCross::Editor::OPTION_FORM) {
        unless (ref $o) {           # a subheading
            $g->Label(-text => $o, -font => $UI_B, -background => $C{paper}, -foreground => $C{ink}, -anchor => 'w')
              ->grid(-row => $row++, -column => 0, -columnspan => 2, -sticky => 'w', -pady => px([12, 4]));
            next;
        }
        my ($key, $text, $about, $choices) = @$o;
        $settings->{options}{$key} //= '';
        $name->($text, $key);
        if ($choices) {
            my $d = drop_down($g, \$settings->{options}{$key}, $choices, sub { settings_changed() });
            $d->grid(-row => $row, -column => 1, -sticky => 'w', -pady => px([3, 0]));
            $form{$key} = $d;
        } else {
            my $e = flat_entry($g, \$settings->{options}{$key}, 12);
            $e->grid(-row => $row, -column => 1, -sticky => 'w', -pady => px([3, 0]), -ipady => px(3));
            $e->bind('<KeyRelease>' => sub { settings_changed() });
            $form{$key} = $e;
        }
        $row++;
        $help->($about);
    }
}

# settings_changed -- after any change in the PROJECT tab.
sub settings_changed {
    for my $v (\$settings->{title}, \(@{ $settings->{project} }{ keys %{ $settings->{project} } }),
               \(@{ $settings->{options} }{ keys %{ $settings->{options} } })) {
        $$v = uc $$v if defined $$v && $$v =~ /[a-z]/;
    }
    set_title();
    update_actions();
    recolour();         # the units in force change what a line means
    update_status();
}

#==============================================================================
# The QUICK TOOLS tab: three small calculators, side by side.
#
#   VELOCITY        a pipe type and size, and a flow: the bore and velocity
#   K-FACTOR        any two of K, Q and P: the third
#   K CONVERTER     a K-factor from US units to metric, or back
#   PRESSURE LOSS   a pipe type and size, and a flow: the friction loss by
#                   Hazen-Williams and Darcy-Weisbach, side by side
#
# Each answers as it is typed.  Independent of the model, like the GRAPH tab.
# Every number is HardyCross::Tools's -- the database's bores and the
# solver's own loss formulas -- so a pipe here behaves exactly as in a model;
# this is drawing.
#==============================================================================
our %qt = (VEL => { type => 'ASAM', size => '', flow => '' },
           K   => { k => '', q => '', p => '', unit => 'KPA' },
           KCONV => { value => '', from => 'US' },
           LOSS => { type => 'ASAM', size => '', flow => '', length => '', c => '', eps => '' });
our %qtw;                        # the widgets, by tool and field; and each tool's result text

sub build_tools {
    my $page = shift;
    my $bar = $page->Frame(-background => $C{paper})->pack(-side => 'top', -fill => 'x', -padx => px(14), -pady => px([10, 8]));
    $bar->Label(-text => 'FLOW L/MIN, PRESSURE KPA, LENGTH M, BORE MM.  INDEPENDENT OF THE MODEL.',
                -font => $UI_S_N, -background => $C{paper}, -foreground => $C{muted})->pack(-side => 'left');
    $qtw{db} = $bar->Label(-text => '', -font => $UI_S_N, -background => $C{paper}, -foreground => $C{muted})
                     ->pack(-side => 'right');
    rule($page, 'x', -side => 'top');
    # The calculators scroll, as the PROJECT tab does, so none is cut short
    # on a short window or with the results pane dragged up.
    my $sb = flat_scrollbar($page, 'vertical')->pack(-side => 'right', -fill => 'y');
    my $cv = $page->Canvas(-background => $C{paper}, -highlightthickness => 0, -borderwidth => 0,
                           -yscrollcommand => sub { $sb->set(@_) })->pack(-fill => 'both', -expand => 1);
    $sb->configure(-command => sub { $cv->yview(@_) });
    my $row = $cv->Frame(-background => $C{paper});
    $cv->createWindow(px(14), px(10), -window => $row, -anchor => 'nw');
    $row->bind('<Configure>' => sub {
        $cv->configure(-scrollregion => [ 0, 0, $row->reqwidth + px(28), $row->reqheight + px(20) ]);
    });
    wheel_target($cv);
    my %col = map { $_ => $row->Frame(-background => $C{paper})->pack(-side => 'left', -fill => 'y', -anchor => 'n',
                                                                      -padx => px([0, 30])) } 1 .. 3;

    # card -- one calculator: a heading, a line on what it does, the fields,
    # its problems in red, and its answer.  Cards stack down their column.
    my $card = sub {
        my ($tool, $title, $about, $column, $lines) = @_;
        my $c = $col{$column}->Frame(-background => $C{paper})->pack(-side => 'top', -fill => 'x', -anchor => 'n',
                                                                     -pady => px([0, 18]));
        $c->Label(-text => $title, -font => $UI_B, -background => $C{paper}, -foreground => $C{ink}, -anchor => 'w')
          ->pack(-fill => 'x');
        rule($c, 'x', -pady => px([4, 4]));
        $c->Label(-text => $about, -font => $UI_S_N, -background => $C{paper}, -foreground => $C{muted},
                  -anchor => 'w', -justify => 'left', -wraplength => px(360))->pack(-fill => 'x', -pady => px([0, 8]));
        my $g = $c->Frame(-background => $C{paper})->pack(-fill => 'x', -anchor => 'w');
        $qtw{$tool}{problems} = $c->Label(-text => '', -font => $UI, -background => $C{paper},
            -foreground => $C{error}, -anchor => 'w', -justify => 'left', -wraplength => px(360))
            ->pack(-fill => 'x', -pady => px([8, 4]));
        $qtw{$tool}{result} = $c->Text(-font => $MONO, -height => $lines // 10, -width => 48, -wrap => 'none',
            -relief => 'flat', -borderwidth => 0, -highlightthickness => 0, -background => $C{panel},
            -foreground => $C{ink}, -padx => px(10), -pady => px(8), -cursor => $POINTER, -takefocus => 0)
            ->pack(-fill => 'x');
        $qtw{$tool}{result}->tagConfigure('head', -font => $MONO_B);
        $qtw{$tool}{result}->tagConfigure('big', -font => $MONO_B, -foreground => $C{accent});
        $qtw{$tool}{result}->tagConfigure('muted', -foreground => $C{muted});
        $qtw{$tool}{result}->tagConfigure('warn', -foreground => $C{error}, -font => $MONO_B);
        return $g;
    };
    my $r = 0;
    my $label = sub {
        my ($g, $text) = @_;
        $g->Label(-text => $text, -font => $UI, -background => $C{paper}, -foreground => $C{muted}, -anchor => 'w')
          ->grid(-row => $r, -column => 0, -sticky => 'w', -pady => px(3), -padx => px([0, 12]));
    };
    my $entry = sub {
        my ($g, $tool, $field, $width, $note) = @_;
        my $e = flat_entry($g, \$qt{$tool}{ lc $field }, $width // 10);
        $e->grid(-row => $r, -column => 1, -sticky => 'w', -pady => px(3), -ipady => px(2));
        $e->bind('<KeyRelease>' => sub { tools_update($tool) });
        $g->Label(-text => $note, -font => $UI_S_N, -background => $C{paper}, -foreground => $C{faint}, -anchor => 'w')
          ->grid(-row => $r, -column => 2, -sticky => 'w', -padx => px([8, 0])) if $note;
        $qtw{$tool}{field}{$field} = $e;
        $r++;
        return $e;
    };
    # pipe -- PIPE TYPE and SIZE: the type a drop-down of the database's
    # types and BORE; the size a drop-down of that type's sizes, or for BORE
    # a field for the bore in mm.
    my $pipe = sub {
        my ($g, $tool) = @_;
        $label->($g, 'PIPE TYPE');
        my $t = drop_down($g, \$qt{$tool}{type}, [ HardyCross::Tools::pipe_types() ], sub {
            $qt{$tool}{size} = '';
            tools_sizes($tool);
            tools_update($tool);
        });
        $t->grid(-row => $r++, -column => 1, -sticky => 'w', -pady => px(3));
        $qtw{$tool}{field}{TYPE} = $t;
        $label->($g, 'SIZE');
        my $f = $g->Frame(-background => $C{paper});
        $f->grid(-row => $r++, -column => 1, -columnspan => 2, -sticky => 'w', -pady => px(3));
        my $mb = $f->Menubutton(-text => '', -font => $MONO, -relief => 'flat', -borderwidth => 0,
            -highlightthickness => 1, -highlightbackground => $C{line}, -background => $C{paper},
            -activebackground => $C{hover}, -foreground => $C{ink}, -anchor => 'w', -width => 11,
            -padx => px(6), -pady => px(3), -indicatoron => 0, -cursor => 'hand2');
        my $m = $mb->Menu(-tearoff => 0, -font => $MONO, -relief => 'flat', -borderwidth => 1,
            -activeborderwidth => 0, -background => $C{paper}, -foreground => $C{ink},
            -activebackground => $C{select}, -activeforeground => $C{ink});
        $mb->configure(-menu => $m);
        my $be = flat_entry($f, \$qt{$tool}{size}, 10);
        $be->bind('<KeyRelease>' => sub { tools_update($tool) });
        my $bn = $f->Label(-text => 'BORE, MM', -font => $UI_S_N, -background => $C{paper}, -foreground => $C{faint});
        @{ $qtw{$tool} }{qw(size_mb size_menu size_entry size_note)} = ($mb, $m, $be, $bn);
        $qtw{$tool}{field}{SIZE} = $mb;
        tools_sizes($tool);
    };

    # VELOCITY.
    my $g = $card->('VEL', 'VELOCITY', 'THE VELOCITY IN A PIPE AT A FLOW.  THE BORE IS THE DATABASE\'S FOR THE TYPE AND SIZE.', 1, 8);
    $r = 0;
    $pipe->($g, 'VEL');
    $label->($g, 'FLOW');
    $entry->($g, 'VEL', 'FLOW', 10, 'L/MIN');

    # K-FACTOR.
    $g = $card->('K', 'K-FACTOR', 'Q = K x SQRT(P).  GIVE ANY TWO OF K, Q AND P; THE THIRD IS FOUND.  CLEAR A FIELD TO SOLVE FOR IT.', 2, 7);
    $r = 0;
    $label->($g, 'K');
    $entry->($g, 'K', 'K', 10);
    $label->($g, 'K UNITS');
    my $ku = drop_down($g, \$qt{K}{unit}, [qw(KPA BAR)], sub { tools_update('K') });
    $ku->grid(-row => $r++, -column => 1, -sticky => 'w', -pady => px(3));
    $g->Label(-text => 'KPA: L/MIN PER ROOT KPA (K80 = 8).  BAR: PER ROOT BAR (K80 = 80).', -font => $UI_S_N,
              -background => $C{paper}, -foreground => $C{faint}, -anchor => 'w', -wraplength => px(340), -justify => 'left')
      ->grid(-row => $r++, -column => 0, -columnspan => 3, -sticky => 'w', -pady => px([0, 4]));
    $label->($g, 'FLOW Q');
    $entry->($g, 'K', 'Q', 10, 'L/MIN');
    $label->($g, 'PRESSURE P');
    $entry->($g, 'K', 'P', 10, 'KPA');

    # K CONVERTER.
    $g = $card->('KCONV', 'K-FACTOR CONVERTER', 'A K-FACTOR FROM US UNITS (GPM PER ROOT PSI) TO METRIC, OR BACK.  '
        . 'K5.6 (US) IS K80 (METRIC, L/MIN PER ROOT BAR).', 2, 4);
    $r = 0;
    $label->($g, 'K');
    $entry->($g, 'KCONV', 'VALUE', 10);
    $label->($g, 'GIVEN IN');
    my $kf = drop_down($g, \$qt{KCONV}{from}, [qw(US BAR KPA)], sub { tools_update('KCONV') });
    $kf->grid(-row => $r++, -column => 1, -sticky => 'w', -pady => px(3));
    $g->Label(-text => 'US: GPM/PSI^0.5.  BAR: L/MIN/BAR^0.5.  KPA: L/MIN/KPA^0.5.', -font => $UI_S_N,
              -background => $C{paper}, -foreground => $C{faint}, -anchor => 'w')
      ->grid(-row => $r++, -column => 0, -columnspan => 3, -sticky => 'w');

    # PRESSURE LOSS.
    $g = $card->('LOSS', 'PRESSURE LOSS', 'THE FRICTION LOSS IN A PIPE AT A FLOW, BY HAZEN-WILLIAMS AND BY DARCY-WEISBACH, '
        . 'WITH THE SOLVER\'S OWN FORMULAS.  BLANK: 1 M OF PIPE, AND THE TYPE\'S C AND ROUGHNESS FROM THE DATABASE.', 3, 11);
    $r = 0;
    $pipe->($g, 'LOSS');
    $label->($g, 'FLOW');
    $entry->($g, 'LOSS', 'FLOW', 10, 'L/MIN');
    $label->($g, 'LENGTH');
    $entry->($g, 'LOSS', 'LENGTH', 10, 'M - BLANK: 1');
    $label->($g, 'C FACTOR (HW)');
    $entry->($g, 'LOSS', 'C', 10);
    $label->($g, 'ROUGHNESS (DW)');
    $entry->($g, 'LOSS', 'EPS', 10, 'MM - BLANK: THE TYPE\'S');

    tools_refresh();
}

# tools_refresh -- on opening the tab: the database may have changed in the
# DATABASE tab since, so the sizes and the answers are taken from it afresh.
sub tools_refresh {
    return unless $qtw{db};
    HardyCross::Parse::ensure_db();
    $qtw{db}->configure(-text => 'PIPE DATA: ' . uc(HardyCross::PipeData::dataset()));
    for my $tool (qw(VEL LOSS)) {
        $qt{$tool}{size} = '' if $qt{$tool}{type} ne $HardyCross::Tools::BORE
            && !grep { $_ eq $qt{$tool}{size} } HardyCross::Tools::sizes($qt{$tool}{type});
        tools_sizes($tool);
    }
    tools_update($_) for qw(VEL K KCONV LOSS);
}

# tools_sizes -- the SIZE choice for a tool's pipe type: a drop-down of the
# type's sizes, or for BORE a field for the bore.
sub tools_sizes {
    my $tool = shift;
    my $w = $qtw{$tool};
    my $type = $qt{$tool}{type};
    $w->{size_menu}->delete(0, 'end');
    if ($type eq $HardyCross::Tools::BORE) {
        $w->{size_mb}->packForget;
        $w->{size_entry}->pack(-side => 'left', -ipady => px(2));
        $w->{size_note}->pack(-side => 'left', -padx => px([8, 0]));
        $qtw{$tool}{field}{SIZE} = $w->{size_entry};
    } else {
        $w->{size_entry}->packForget;
        $w->{size_note}->packForget;
        $w->{size_mb}->pack(-side => 'left');
        for my $dn (HardyCross::Tools::sizes($type)) {
            $w->{size_menu}->command(-label => sprintf('DN%-5s %6.1f MM', $dn, HardyCross::PipeData::bore($type, $dn)),
                -command => sub { $qt{$tool}{size} = $dn; tools_update($tool) });
        }
        $qtw{$tool}{field}{SIZE} = $w->{size_mb};
    }
    tools_show_size($tool);
}
sub tools_show_size {
    my $tool = shift;
    return if $qt{$tool}{type} eq $HardyCross::Tools::BORE;
    my $s = $qt{$tool}{size};
    $qtw{$tool}{size_mb}->configure(-text => sprintf('%-9s %s', length $s ? "DN$s" : 'CHOOSE', "\x{25BE}"));
}

#------------------------------------------------------------------------------
# tools_update -- a calculator worked out again: its problems, each field at
# fault shaded, and its answer.
#------------------------------------------------------------------------------
sub tools_update {
    my $tool = shift;
    my $w = $qtw{$tool} or return;
    tools_show_size($tool) if $w->{size_mb};
    my $f = $qt{$tool};
    my $res = $tool eq 'VEL'   ? HardyCross::Tools::velocity(%$f)
            : $tool eq 'K'     ? HardyCross::Tools::kfactor(%$f)
            : $tool eq 'KCONV' ? HardyCross::Tools::kconvert(%$f)
            :                    HardyCross::Tools::loss(%$f);
    $qtw{$tool}{last} = $res;
    for my $e (values %{ $w->{field} }) { $e->configure(-highlightbackground => $C{line}) }
    my $t = $w->{result};
    $t->configure(-state => 'normal');
    $t->delete('1.0', 'end');
    # Before anything is typed there is nothing to complain about: show what
    # is needed, quietly, rather than a list of problems.
    my $empty = !grep { defined && /\S/ } map { $f->{$_} } grep { !/^(type|unit|from)\z/ } keys %$f;
    if (!$res->{ok}) {
        if ($empty) {
            $w->{problems}->configure(-text => '');
            $t->insert('end', $tool eq 'K' ? 'GIVE ANY TWO OF K, Q AND P.' : $tool eq 'KCONV' ? 'GIVE A K.'
                            : 'CHOOSE A SIZE AND GIVE A FLOW.', 'muted');
        } else {
            $w->{problems}->configure(-text => join "\n", map { $_->[1] } @{ $res->{errors} });
            for my $e (@{ $res->{errors} }) {
                my $fw = $w->{field}{ $e->[0] } or next;
                $fw->configure(-highlightbackground => $C{error});
            }
            $t->insert('end', 'NO ANSWER UNTIL THE FIELDS ARE PUT RIGHT.', 'muted');
        }
        $t->configure(-state => 'disabled');
        return $res;
    }
    $w->{problems}->configure(-text => '');
    my $line = sub { my ($l, $v, $tag) = @_; $t->insert('end', sprintf('%-18s', $l), 'muted'); $t->insert('end', "$v\n", $tag // '') };
    if ($tool eq 'VEL') {
        $line->('VELOCITY', sprintf('%.2f M/S', $res->{velocity}), 'big');
        $t->insert('end', "\n");
        $line->('BORE', sprintf('%.1f MM', $res->{bore}));
        $line->('AREA', sprintf('%.6f M2', $res->{area}));
        $line->('FLOW', sprintf('%.1f L/MIN  (%.3f L/S)', $f->{flow}, $f->{flow} / 60));
        $t->insert('end', "\n");
        my $lim = $settings->{options}{VEL_LIMIT};
        $lim = 6 unless defined $lim && $lim =~ /^\s*[\d.]+\s*$/ && $lim > 0;
        $line->('AGAINST THE LIMIT', sprintf('%.1f M/S: %s', $lim, $res->{velocity} > $lim ? 'ABOVE IT' : 'WITHIN IT'),
               $res->{velocity} > $lim ? 'head' : '');
        $t->insert('end', '(THE PROJECT TAB\'S VELOCITY LIMIT)', 'muted');
    } elsif ($tool eq 'KCONV') {
        my %u = (US => 'GPM/PSI^0.5', BAR => 'L/MIN/BAR^0.5', KPA => 'L/MIN/KPA^0.5');
        for my $x (qw(US BAR KPA)) {
            $line->($x eq 'US' ? 'US' : "METRIC, $x", sprintf('%.3f %s', $res->{ lc $x }, $u{$x}),
                    $x eq $res->{from} ? '' : 'big');
        }
    } elsif ($tool eq 'K') {
        my %name = (K => 'K', Q => 'FLOW Q', P => 'PRESSURE P');
        my %val = (K => sprintf('%.3f L/MIN/%s^0.5', $res->{k}, $res->{unit} eq 'BAR' ? 'BAR' : 'KPA'),
                   Q => sprintf('%.2f L/MIN', $res->{q}), P => sprintf('%.2f KPA  (%.3f BAR)', $res->{p}, $res->{p} / 100));
        $line->("$name{ $res->{solved} } =", $val{ $res->{solved} }, 'big');
        $t->insert('end', "\n");
        $line->($name{$_}, $val{$_}) for grep { $_ ne $res->{solved} } qw(K Q P);
        $t->insert('end', "\n");
        $line->('K PER ROOT KPA', sprintf('%.3f', $res->{k_kpa}));
        $line->('K PER ROOT BAR', sprintf('%.3f', $res->{k_bar}));
    } else {
        $t->insert('end', sprintf("%-18s%13s %13s\n", '', 'HAZEN-WILLIAMS', 'DARCY-WEISBACH'), 'head');
        $t->insert('end', sprintf("%-18s", 'LOSS, KPA/M'), 'muted');
        $t->insert('end', sprintf("%13.4f %14.4f\n", $res->{hw}{per_m}, $res->{dw}{per_m}), 'big');
        if ($res->{length} != 1) {
            $t->insert('end', sprintf("%-18s", sprintf('LOSS OVER %g M', $res->{length})), 'muted');
            $t->insert('end', sprintf("%13.2f %14.2f\n", $res->{hw}{total}, $res->{dw}{total}), 'big');
            $t->insert('end', sprintf("%-18s%13s %14s\n", '', 'KPA', 'KPA'), 'muted');
        }
        $line->('DW AGAINST HW', sprintf('%+.1f %%', $res->{diff_pct}));
        $line->('BORE, VELOCITY', sprintf('%.1f MM, %.2f M/S', $res->{bore}, $res->{velocity}));
        $line->('C, ROUGHNESS', sprintf('%g (HW), %g MM (DW)', $res->{c}, $res->{eps}));
        # An assumed roughness is said so, in red: none given, none published.
        $line->('', 'ROUGHNESS ASSUMED: THE PROGRAM DEFAULT', 'warn') if $res->{eps_src} eq 'DEFAULT';
        $line->('REYNOLDS NUMBER', sprintf('%.0f, %s', $res->{dw}{re}, $res->{dw}{regime}));
        $line->('FRICTION FACTOR', sprintf('%.5f (DARCY)', $res->{dw}{f}));
    }
    $t->configure(-state => 'disabled');
    return $res;
}

#==============================================================================
# The GRAPH tab: a Q^1.85 water supply graph from figures typed in.
#
# Independent of the model: nothing here is read from the network or from a
# calculation, and nothing here changes them.  The supply as measured (A),
# the loss from the supply to the datum (B) and a pump (D) are typed as
# points; the tab draws them with the supply available at the datum (C =
# A - B) and with the pump (E = C + D), and up to ten duty points, each with
# the pressure available to it and its margin.  PRINT TO PDF writes the sheet;
# SAVE GRAPH keeps the figures in a .phg file.  Every decision -- what is
# wrong, where the curves go -- is HardyCross::Graph's; this is drawing.
#
# Left, the figures; right, the graph as it will print, redrawn as they are
# typed, and under it what is wrong with them, if anything.  A field at fault
# is shaded; a click on a problem goes to its field.
#==============================================================================
our $graph = HardyCross::Graph::new_graph();
our %gv = (fields => {}, saved => '');   # canvas, problems list, fields by name, path, saved text

sub build_graph {
    my $page = shift;
    my $bar = $page->Frame(-background => $C{paper})->pack(-side => 'top', -fill => 'x', -padx => px(14), -pady => px([10, 8]));
    $gv{btn}{NEW}   = flat_button($bar, 'NEW GRAPH',     sub { graph_new() })->pack(-side => 'left', -padx => px([0, 4]));
    $gv{btn}{OPEN}  = flat_button($bar, 'OPEN GRAPH...', sub { graph_open() })->pack(-side => 'left', -padx => px(4));
    $gv{btn}{SAVE}  = flat_button($bar, 'SAVE GRAPH...', sub { graph_save() })->pack(-side => 'left', -padx => px(4));
    $bar->Frame(-background => $C{line}, -width => 1, -height => px(22))->pack(-side => 'left', -padx => px(10));
    $gv{btn}{PDF}   = flat_button($bar, 'PRINT TO PDF...', sub { graph_pdf() }, primary => 1)
                        ->pack(-side => 'left', -padx => px(4));
    $gv{file} = $bar->Label(-text => '', -font => $UI, -background => $C{paper}, -foreground => $C{muted})
                    ->pack(-side => 'left', -padx => px(12));
    $bar->Label(-text => 'L/MIN AND KPA.  INDEPENDENT OF THE MODEL - NOTHING HERE COMES FROM THE NETWORK.',
                -font => $UI_S_N, -background => $C{paper}, -foreground => $C{muted})->pack(-side => 'right');
    rule($page, 'x', -side => 'top');

    my $hp = divider($page, 'horizontal');
    my $left  = $page->Frame(-background => $C{paper});
    my $right = $page->Frame(-background => $C{paper});

    # The figures, in a scrolling form.
    my $sb = flat_scrollbar($left, 'vertical')->pack(-side => 'right', -fill => 'y');
    my $cv = $left->Canvas(-background => $C{paper}, -highlightthickness => 0, -borderwidth => 0,
                           -yscrollcommand => sub { $sb->set(@_) })->pack(-fill => 'both', -expand => 1);
    $sb->configure(-command => sub { $cv->yview(@_) });
    my $wrap = $cv->Frame(-background => $C{paper});
    $cv->createWindow(px(14), px(10), -window => $wrap, -anchor => 'nw');
    $wrap->bind('<Configure>' => sub {
        $cv->configure(-scrollregion => [ 0, 0, $wrap->reqwidth + px(28), $wrap->reqheight + px(20) ]);
    });
    wheel_target($cv);
    $gv{form} = $cv;
    $gv{wrap} = $wrap;

    my $heading = sub {
        my ($parent, $text, $note) = @_;
        my $h = $parent->Frame(-background => $C{paper})->pack(-fill => 'x', -pady => px([10, 0]));
        $h->Label(-text => $text, -font => $UI_B, -background => $C{paper}, -foreground => $C{ink})->pack(-side => 'left');
        $h->Label(-text => $note, -font => $UI_S_N, -background => $C{paper}, -foreground => $C{muted})
          ->pack(-side => 'left', -padx => px([8, 0])) if $note;
        rule($parent, 'x', -pady => px([3, 6]));
    };
    my $field = sub {
        my ($g, $name, $var, $width, $row, $col) = @_;
        my $e = flat_entry($g, $var, $width);
        $e->grid(-row => $row, -column => $col, -sticky => 'w', -pady => px(2), -padx => px([0, 6]), -ipady => px(2));
        $e->bind('<KeyRelease>' => sub { graph_changed() });
        $gv{fields}{$name} = $e;
        return $e;
    };
    my $label = sub {
        my ($g, $text, $row, $col, %o) = @_;
        $g->Label(-text => $text, -font => $o{head} ? $UI_S : $UI, -background => $C{paper},
                  -foreground => $C{muted}, -anchor => 'w')
          ->grid(-row => $row, -column => $col, -sticky => 'w', -padx => px([0, 10]), -columnspan => $o{span} // 1);
    };

    # The sheet: project details and the axes.
    $heading->($wrap, 'SHEET');
    my $g = $wrap->Frame(-background => $C{paper})->pack(-fill => 'x');
    my $r = 0;
    for my $k (@HardyCross::Graph::PROJECT) {
        $label->($g, $HardyCross::Graph::PROJECT_LABEL{$k}, $r, 0);
        $field->($g, $k, \$graph->{project}{$k}, 30, $r++, 1);
    }
    $r = 0;
    for my $k (@HardyCross::Graph::AXIS) {
        $label->($g, $HardyCross::Graph::AXIS_LABEL{$k}, $r, 2);
        $field->($g, $k, \$graph->{axis}{$k}, 8, $r++, 3);
    }
    $label->($g, 'AXES LEFT BLANK ARE WORKED OUT FROM THE FIGURES', $r, 2, span => 2);

    # The curves: three tables side by side.
    $heading->($wrap, 'CURVES', 'FLOWS RISING FROM ROW TO ROW, NO GAPS');
    my $cf = $wrap->Frame(-background => $C{paper})->pack(-fill => 'x');
    my %note = (A => 'AT LEAST TWO POINTS', B => 'ONE POINT: A LOSS LINE THROUGH 0', D => 'FROM CHURN, 0 L/MIN; OR NONE');
    for my $c (@HardyCross::Graph::CURVES) {
        my $t = $cf->Frame(-background => $C{paper})->pack(-side => 'left', -anchor => 'n', -padx => px([0, 22]));
        $t->Label(-text => "$c  $HardyCross::Graph::CURVE_NAME{$c}", -font => $UI_B, -background => $C{paper},
                  -foreground => $C{ink}, -anchor => 'w')->pack(-fill => 'x');
        $t->Label(-text => $note{$c}, -font => $UI_S_N, -background => $C{paper}, -foreground => $C{muted},
                  -anchor => 'w')->pack(-fill => 'x', -pady => px([0, 4]));
        my $tg = $t->Frame(-background => $C{paper})->pack(-anchor => 'w');
        $label->($tg, '', 0, 0, head => 1);
        $label->($tg, 'FLOW L/MIN', 0, 1, head => 1);
        $label->($tg, 'PRESSURE KPA', 0, 2, head => 1);
        for my $i (0 .. $HardyCross::Graph::ROWS - 1) {
            $tg->Label(-text => $i + 1, -font => $UI_S_N, -background => $C{paper}, -foreground => $C{faint})
               ->grid(-row => $i + 1, -column => 0, -sticky => 'e', -padx => px([0, 6]));
            my $f = $field->($tg, $c . ($i + 1) . 'Q', \$graph->{$c}[$i][0], 9, $i + 1, 1);
            my $p = $field->($tg, $c . ($i + 1) . 'P', \$graph->{$c}[$i][1], 9, $i + 1, 2);
            # A problem names the row: both its fields are shaded.
            $gv{rows}{ $c . ($i + 1) } = [ $f, $p ];
        }
    }

    # The duty points.
    $heading->($wrap, 'DUTY POINTS', 'EACH A FLOW NEEDED AT A PRESSURE; THE NUMBER IS DRAWN ON THE GRAPH');
    my $dg = $wrap->Frame(-background => $C{paper})->pack(-anchor => 'w');
    $label->($dg, 'NO', 0, 0, head => 1);
    $label->($dg, 'DESCRIPTION', 0, 1, head => 1);
    $label->($dg, 'FLOW L/MIN', 0, 2, head => 1);
    $label->($dg, 'PRESSURE KPA', 0, 3, head => 1);
    for my $i (0 .. $HardyCross::Graph::DUTY_ROWS - 1) {
        my @w = ($field->($dg, 'DUTY' . ($i + 1) . 'L', \$graph->{duty}[$i][0], 5,  $i + 1, 0),
                 $field->($dg, 'DUTY' . ($i + 1) . 'D', \$graph->{duty}[$i][1], 34, $i + 1, 1),
                 $field->($dg, 'DUTY' . ($i + 1) . 'Q', \$graph->{duty}[$i][2], 9,  $i + 1, 2),
                 $field->($dg, 'DUTY' . ($i + 1) . 'P', \$graph->{duty}[$i][3], 9,  $i + 1, 3));
        $gv{rows}{ 'DUTY' . ($i + 1) } = \@w;
    }
    $gv{rows}{$_} = [ $gv{fields}{$_} ] for @HardyCross::Graph::AXIS;

    # The graph, and what is wrong.
    $gv{problems} = $right->Listbox(-font => $MONO, -height => 5, -relief => 'flat', -borderwidth => 0,
        -highlightthickness => 0, -background => $C{paper}, -foreground => $C{error},
        -selectbackground => $C{error_bg}, -selectforeground => $C{error}, -activestyle => 'none')
        ->pack(-side => 'bottom', -fill => 'x', -padx => px(10), -pady => px([0, 8]));
    $gv{problems}->bind('<ButtonRelease-1>' => sub { graph_go_to_problem() });
    rule($right, 'x', -side => 'bottom');
    $gv{canvas} = $right->Canvas(-background => $C{paper}, -highlightthickness => 0, -borderwidth => 0)
        ->pack(-fill => 'both', -expand => 1, -padx => px(6), -pady => px(6));
    $gv{canvas}->Tk::bind('<Configure>' => sub { graph_draw() });

    $hp->add($left, -width => px(820));
    $hp->add($right);
    $hp->pack(-fill => 'both', -expand => 1);
    $gv{saved} = graph_text();
    graph_changed();
}

# graph_text -- the figures as they would be saved, to tell whether they changed.
sub graph_text {
    my @f = (map({ $graph->{project}{$_} } @HardyCross::Graph::PROJECT), map({ $graph->{axis}{$_} } @HardyCross::Graph::AXIS),
             map({ map { @$_ } @{ $graph->{$_} } } @HardyCross::Graph::CURVES), map { @$_ } @{ $graph->{duty} });
    return join "\x00", map { $_ // '' } @f;
}
sub graph_modified { return graph_text() ne $gv{saved} }

# graph_changed -- after any change: capitals, a fresh check, the shading, the
# problems list and the drawing.  Run a moment after typing stops.
sub graph_changed {
    $mw->afterCancel($gv{job}) if $gv{job};
    $gv{job} = $mw->after(200, sub { $gv{job} = undef; graph_refresh() });
}
sub graph_refresh {
    $_ = uc for grep { defined } values %{ $graph->{project} };
    $_->[1] = uc $_->[1] for grep { defined $_->[1] } @{ $graph->{duty} };
    $_->[0] = uc $_->[0] for grep { defined $_->[0] } @{ $graph->{duty} };
    my $chk = HardyCross::Graph::check($graph);
    $gv{check} = $chk;
    for my $w (values %{ $gv{fields} }) { $w->configure(-background => $C{paper}) }
    $gv{problems}->delete(0, 'end');
    for my $e (@{ $chk->{errors} }) {
        my ($where, $msg) = @$e;
        $_->configure(-background => $C{fault_bg}) for @{ $gv{rows}{$where} || [] };
        $gv{problems}->insert('end', $msg);
    }
    $gv{problems}->insert('end', '') unless @{ $chk->{errors} };
    $gv{btn}{PDF}->configure(-state => $chk->{ok} ? 'normal' : 'disabled');
    graph_set_title();
    graph_draw();
}
sub graph_set_title {
    my $name = defined $gv{path} ? ($gv{path} =~ s{.*[/\\]}{}r) : 'UNTITLED.PHG';
    $gv{file}->configure(-text => uc($name) . (graph_modified() ? ' *' : ''));
}

# graph_go_to_problem -- a click on a problem: focus the field at fault.
sub graph_go_to_problem {
    my ($i) = $gv{problems}->curselection;
    return unless defined $i;
    my $e = $gv{check}{errors}[$i] or return;
    my $w = ($gv{rows}{ $e->[0] } || [])->[0] or return;
    $w->focus;
    $w->selectionRange(0, 'end');
    # Scroll the form to it if it is out of sight.
    $gv{form}->update;
    my $y = $w->rooty - $gv{form}->rooty;
    if ($y < 0 || $y > $gv{form}->height - px(30)) {
        my $at = ($w->rooty - $gv{wrap}->rooty) / ($gv{wrap}->reqheight || 1);
        $gv{form}->yviewMoveto($at > 0.05 ? $at - 0.05 : 0);
    }
}

#------------------------------------------------------------------------------
# graph_draw -- the graph on the canvas, as it will print: the same curves,
# styles and letters as HardyCross::Graph::write_pdf, scaled to the pane.
#------------------------------------------------------------------------------
sub graph_draw {
    my $c = $gv{canvas} or return;
    $c->delete('all');
    my ($W, $H) = ($c->width, $c->height);
    return if $W < 50 || $H < 50;
    my $chk = $gv{check} or return;
    unless ($chk->{ok}) {
        $c->createText($W / 2, $H / 2, -text => 'THE GRAPH IS DRAWN WHEN THE FIGURES ARE COMPLETE - SEE BELOW',
                       -font => $UI, -fill => $C{muted});
        return;
    }
    my $sr = HardyCross::Graph::series($chk);
    # The key goes under the plot: a line for each curve and each duty point.
    my @names = grep { $sr->{lines}{$_} } qw(A B C D E);
    my $keyh = (@names + @{ $sr->{duty} }) * px(15) + px(12);
    my ($pl, $pr, $pt, $pb) = (px(56), $W - px(16), px(26), $H - px(44) - $keyh);
    return if $pb - $pt < px(60);
    my ($pw, $ph) = ($pr - $pl, $pb - $pt);
    my ($qmax, $pmax) = @{$sr}{qw(qmax pmax)};
    my $X = sub { $pl + ($_[0] > 0 ? ($_[0] / $qmax) ** 1.85 : 0) * $pw };
    my $Y = sub { $pb - $_[0] / $pmax * $ph };
    for my $p (@{ $sr->{yticks} }) {
        next if $p > $pmax + 1e-9;
        $c->createLine($pl, $Y->($p), $pr, $Y->($p), -fill => $C{line});
        $c->createText($pl - px(5), $Y->($p), -text => sprintf('%g', $p), -anchor => 'e', -font => $UI_S_N, -fill => $C{muted});
    }
    my $last = -1e9;
    for my $q (@{ $sr->{xticks} }) {
        next if $q > $qmax + 1e-9;
        my $x = $X->($q);
        $c->createLine($x, $pt, $x, $pb, -fill => $C{line});
        my $t = sprintf '%g', $q;
        next if $x - px(4) * length($t) < $last + px(6);
        $c->createText($x, $pb + px(4), -text => $t, -anchor => 'n', -font => $UI_S_N, -fill => $C{muted});
        $last = $x + px(4) * length $t;
    }
    $c->createText($pl - px(5), $pt - px(8), -text => 'PRESSURE, KPA', -anchor => 'w', -font => $UI_S, -fill => $C{ink});
    $c->createText(($pl + $pr) / 2, $pb + px(26), -text => 'FLOW, L/MIN, ON A FLOW^1.85 SCALE', -font => $UI_S, -fill => $C{ink});
    $c->createRectangle($pl, $pt, $pr, $pb, -outline => $C{ink});

    # Line styles as on the sheet: A thin, B dotted, C dashed, D dash-dot; the
    # curve designed against heavy and blue, so it reads first on the screen.
    my %dash = (A => '', B => '.', C => '-', D => '-.', E => '-');
    my %along = (A => 0.30, B => 0.62, C => 0.46, D => 0.78, E => 0.90);
    for my $n (@names) {
        my $design = $n eq $sr->{design};
        # Only the part inside the plot: the curve is cut into runs of points
        # between 0 and the top of the pressure axis.
        my @runs = ([]);
        for my $pt (@{ $sr->{lines}{$n} }) {
            if ($pt->[1] >= 0 && $pt->[1] <= $pmax) { push @{ $runs[-1] }, $X->($pt->[0]), $Y->($pt->[1]) }
            elsif (@{ $runs[-1] }) { push @runs, [] }
        }
        for my $xy (grep { @$_ >= 4 } @runs) {
            $c->createLine(@$xy, -fill => $design ? $C{accent} : $C{ink}, -width => $design ? px(3) : 1,
                           ($design || $dash{$n} eq '' ? () : (-dash => $dash{$n})), -tags => [ 'curve', "curve$n" ]);
        }
    }
    for my $n (@names) {
        my ($at) = grep { $X->($_->[0]) >= $pl + $along{$n} * $pw } @{ $sr->{lines}{$n} };
        next unless $at && $at->[1] >= 0 && $at->[1] <= $pmax;
        my ($x, $y) = ($X->($at->[0]), $Y->($at->[1]) - px(8));
        $c->createRectangle($x - px(6), $y - px(7), $x + px(6), $y + px(7), -fill => $C{paper}, -outline => '');
        $c->createText($x, $y, -text => $n, -font => $UI_B, -fill => $n eq $sr->{design} ? $C{accent} : $C{ink});
    }
    my $r = px(3);
    for my $cn (sort keys %{ $sr->{points} }) {
        for my $p (@{ $sr->{points}{$cn} }) {
            my ($x, $y) = ($X->($p->[0]), $Y->($p->[1]));
            next if $p->[1] > $pmax;
            $c->createOval($x - $r, $y - $r, $x + $r, $y + $r, -outline => $C{ink}, -fill => $C{paper});
        }
    }
    for my $d (@{ $sr->{duty} }) {
        next if $d->{q} > $qmax || $d->{p} > $pmax;
        my ($x, $y) = ($X->($d->{q}), $Y->($d->{p}));
        my $bad = $d->{margin} < 0;
        $c->createRectangle($x - $r, $y - $r, $x + $r, $y + $r, -fill => $bad ? $C{error} : $C{ink}, -outline => '');
        $c->createText($x + px(6), $y - px(6), -text => $d->{label}, -anchor => 'w', -font => $UI_S,
                       -fill => $bad ? $C{error} : $C{ink}, -tags => [ 'duty' ]);
    }
    # The key, under the plot: each curve with its line, then each duty
    # point against the curve designed against.
    my $ky = $pb + px(48);
    for my $n (@names) {
        my $design = $n eq $sr->{design};
        $c->createLine($pl, $ky, $pl + px(26), $ky, -fill => $design ? $C{accent} : $C{ink},
                       -width => $design ? px(3) : 1, ($design || $dash{$n} eq '' ? () : (-dash => $dash{$n})));
        $c->createText($pl + px(34), $ky, -anchor => 'w', -font => $design ? $UI_S : $UI_S_N, -tags => [ 'key' ],
                       -fill => $design ? $C{accent} : $C{ink},
                       -text => "$n  $HardyCross::Graph::CURVE_NAME{$n}" . ($design ? ' - DESIGNED AGAINST' : ''));
        $ky += px(15);
    }
    for my $d (@{ $sr->{duty} }) {
        $c->createRectangle($pl + px(10), $ky - px(3), $pl + px(16), $ky + px(3),
                            -fill => $d->{margin} < 0 ? $C{error} : $C{ink}, -outline => '');
        $c->createText($pl + px(34), $ky, -anchor => 'w', -font => $UI_S_N, -tags => [ 'key' ],
                       -fill => $d->{margin} < 0 ? $C{error} : $C{ink},
                       -text => sprintf('%s  %.0f L/MIN AT %.0f KPA - %s HAS %.0f KPA, %s %.0f KPA%s', $d->{label},
                                        $d->{q}, $d->{p}, $sr->{design}, $d->{avail},
                                        $d->{margin} < 0 ? 'SHORT BY' : 'MARGIN', abs $d->{margin},
                                        length $d->{desc} ? "  ($d->{desc})" : ''));
        $ky += px(15);
    }
}

#------------------------------------------------------------------------------
# Files: NEW GRAPH, OPEN GRAPH, SAVE GRAPH, PRINT TO PDF.
#------------------------------------------------------------------------------
sub graph_ok_to_discard {
    return 1 unless graph_modified();
    my $a = $mw->messageBox(-title => 'UNSAVED GRAPH', -icon => 'warning', -type => 'YesNo',
        -message => 'THE GRAPH HAS UNSAVED CHANGES.  DISCARD THEM?');
    return lc($a) eq 'yes';
}
# graph_load -- put a graph's figures in the tab.  The fields are tied to the
# graph held here, so the values are copied in, not the graph replaced.
sub graph_load {
    my $g = shift;
    $graph->{project}{$_} = $g->{project}{$_} for @HardyCross::Graph::PROJECT;
    $graph->{axis}{$_}    = $g->{axis}{$_}    for @HardyCross::Graph::AXIS;
    # Element by element: a list assigned to a row would make new scalars and
    # leave the fields tied to the old ones.
    for my $c (@HardyCross::Graph::CURVES) {
        for my $i (0 .. $HardyCross::Graph::ROWS - 1) { $graph->{$c}[$i][$_] = $g->{$c}[$i][$_] for 0, 1 }
    }
    for my $i (0 .. $HardyCross::Graph::DUTY_ROWS - 1) { $graph->{duty}[$i][$_] = $g->{duty}[$i][$_] for 0 .. 3 }
    graph_refresh();
}
sub graph_new {
    return unless graph_ok_to_discard();
    graph_load(HardyCross::Graph::new_graph());
    $gv{path} = undef;
    $gv{saved} = graph_text();
    graph_refresh();
    message('NEW GRAPH');
}
sub graph_open {
    my $file = shift;
    return unless graph_ok_to_discard();
    $file //= $mw->getOpenFile(-filetypes => [ [ 'PHCP GRAPH', '.phg' ] ]);
    return unless defined $file && length $file;
    my $g = eval { HardyCross::Graph::read_file($file) };
    unless ($g) { message("GRAPH NOT OPENED: $@", 1); return }
    graph_load($g);
    $gv{path} = $file;
    $gv{saved} = graph_text();
    graph_refresh();
    message("GRAPH OPENED: $file");
    return 1;
}
sub graph_save {
    my $file = shift;
    $file //= $mw->getSaveFile(-defaultextension => '.phg', -filetypes => [ [ 'PHCP GRAPH', '.phg' ] ],
        -initialfile => defined $gv{path} ? ($gv{path} =~ s{.*[/\\]}{}r) : 'GRAPH.PHG');
    return unless defined $file && length $file;
    my $ok = eval { HardyCross::Graph::write_file($graph, $file) };
    unless ($ok) { message("GRAPH NOT SAVED: $@", 1); return }
    $gv{path} = $file;
    $gv{saved} = graph_text();
    graph_set_title();
    message("GRAPH SAVED: $file");
    return 1;
}
sub graph_pdf {
    my $file = shift;
    graph_refresh();
    unless ($gv{check}{ok}) { message('THE GRAPH HAS PROBLEMS - SEE THE LIST UNDER IT', 1); return }
    my $base = defined $gv{path} ? ($gv{path} =~ s{.*[/\\]}{}r =~ s/\.phg\z//ir) : 'GRAPH';
    $file //= $mw->getSaveFile(-defaultextension => '.pdf', -initialfile => "${base}_GRAPH.PDF",
        -filetypes => [ [ 'PDF', '.pdf' ] ]);
    return unless defined $file && length $file;
    my $ok = eval { HardyCross::Graph::write_pdf($graph, $file,
                        model => defined $gv{path} ? ($gv{path} =~ s{.*[/\\]}{}r) : '') };
    message($ok ? "GRAPH WRITTEN TO $file" : 'GRAPH NOT WRITTEN: ' . ($@ // ''), !$ok);
    return $ok;
}

#==============================================================================
# The DATABASE tab: the pipe and fitting database, viewed and edited.
#
# Read-only until EDIT THE DATABASE is ticked, because a change reaches every
# calculation made after it (decided 28 October 2026).  Four tables -- pipe
# types, pipe sizes, fittings, K' factors -- each with a filter; a click on a
# row puts it in the fields below, where it can be changed, added as a new
# row, or deleted.  SAVE CHANGES checks every row and the whole file, writes
# it, and makes it the database in use; the report then prints its new
# SHA-256.  Every decision is HardyCross::DbEdit's; this is drawing.
#
# Above the tables: where the database is -- the program's own (BUILT-IN), a
# copy beside the program, or a TEAM FOLDER chosen with CHOOSE FOLDER..., such
# as a folder on a network drive that every machine in a team points at.
#==============================================================================
sub build_database {
    my $page = shift;
    my $top = $page->Frame(-background => $C{paper})->pack(-side => 'top', -fill => 'x', -padx => px(14), -pady => px([10, 6]));
    my $l1 = $top->Frame(-background => $C{paper})->pack(-fill => 'x');
    $dbv{origin} = $l1->Label(-text => '', -font => $UI_B, -padx => px(10), -pady => px(3))->pack(-side => 'left');
    $dbv{path} = $l1->Label(-text => '', -font => $MONO, -background => $C{paper}, -foreground => $C{ink})
                    ->pack(-side => 'left', -padx => px(10));
    $dbv{sha} = $l1->Label(-text => '', -font => $UI_S_N, -background => $C{paper}, -foreground => $C{muted})
                   ->pack(-side => 'left', -padx => px(6));
    $dbv{btn}{BUILTIN} = flat_button($l1, 'USE BUILT-IN', sub { db_use_builtin() })->pack(-side => 'right', -padx => px([6, 0]));
    $dbv{btn}{FOLDER}  = flat_button($l1, 'CHOOSE FOLDER...', sub { db_choose_folder() })->pack(-side => 'right', -padx => px(6));
    $dbv{btn}{RELOAD}  = flat_button($l1, 'RELOAD', sub { db_reload() })->pack(-side => 'right', -padx => px(6));

    my $l2 = $top->Frame(-background => $C{paper})->pack(-fill => 'x', -pady => px([10, 0]));
    $dbv{edit_box} = check_box($l2, 'EDIT THE DATABASE', \$dbv{editing}, sub { db_editing_changed() });
    $dbv{edit_box}{frame}->pack(-side => 'left');
    $dbv{btn}{SAVE} = flat_button($l2, 'SAVE CHANGES', sub { db_save() }, primary => 1)->pack(-side => 'left', -padx => px([16, 4]));
    $dbv{btn}{DISCARD} = flat_button($l2, 'DISCARD CHANGES', sub { db_reload(1) })->pack(-side => 'left', -padx => px(4));
    $dbv{note} = $l2->Label(-text => '', -font => $UI_S_N, -background => $C{paper}, -foreground => $C{muted},
                            -justify => 'left', -anchor => 'w')->pack(-side => 'left', -padx => px(14), -fill => 'x');
    my $ff = $l2->Frame(-background => $C{paper})->pack(-side => 'right');
    $ff->Label(-text => 'FILTER', -font => $UI, -background => $C{paper}, -foreground => $C{muted})->pack(-side => 'left');
    $dbv{filter} = '';
    my $fe = flat_entry($ff, \$dbv{filter}, 18)->pack(-side => 'left', -padx => px([8, 0]), -ipady => px(3));
    $fe->bind('<KeyRelease>' => sub { db_fill() });
    rule($page, 'x', -side => 'top');

    # The edit fields, under the tables.
    my $form = $page->Frame(-background => $C{panel})->pack(-side => 'bottom', -fill => 'x');
    rule($form, 'x', -side => 'top');
    $dbv{formrow} = $form->Frame(-background => $C{panel})->pack(-fill => 'x', -padx => px(14), -pady => px([8, 4]));
    my $fb = $form->Frame(-background => $C{panel})->pack(-fill => 'x', -padx => px(14), -pady => px([0, 8]));
    $dbv{btn}{UPDATE} = flat_button($fb, 'UPDATE ROW', sub { db_update() })->pack(-side => 'left', -padx => px([0, 4]));
    $dbv{btn}{ADD}    = flat_button($fb, 'ADD AS NEW ROW', sub { db_add() })->pack(-side => 'left', -padx => px(4));
    $dbv{btn}{DELETE} = flat_button($fb, 'DELETE ROW', sub { db_delete() })->pack(-side => 'left', -padx => px(4));
    $dbv{msg} = $fb->Label(-text => '', -font => $UI_B, -background => $C{panel}, -foreground => $C{muted},
                           -anchor => 'w', -justify => 'left')->pack(-side => 'left', -padx => px(14), -fill => 'x');

    my @kinds = map { $_->[0] } @HardyCross::DbEdit::TABLES;
    my %title = map { $_->[0] => $_->[1] } @HardyCross::DbEdit::TABLES;
    $dbv{tabs} = make_tabs($page, [ map { $title{$_} } @kinds ], sub {
        my $t = shift;
        ($dbv{kind}) = grep { $title{$_} eq $t } @kinds;
        db_fill();
        db_form();
    });
    db_reload(1);
}

# db_open -- read the database in use into the tab; a file that cannot be
# read (a team folder off the network) is said so, and the tab shows nothing.
sub db_open {
    my $db = eval { HardyCross::Parse::ensure_db(); HardyCross::DbEdit::open_db(HardyCross::PipeData::path()) };
    $dbv{error} = $db ? undef : uc(ref $@ ? $@->{msg} : "$@");
    $dbv{error} =~ s/\s+\z// if $dbv{error};
    $dbv{db} = $db;
}

# db_reload -- read the database again from its file, losing unsaved edits
# (after asking, unless $quiet).
sub db_reload {
    my $quiet = shift;
    return if !$quiet && !db_ok_to_leave();
    db_open();
    $dbv{sel} = undef;
    db_header();
    db_fill();
    db_form();
    db_state();
    db_message($dbv{error} // '', $dbv{error} ? 1 : 0);
}

# db_header -- where the database is, its path and fingerprint.
sub db_header {
    my $o = HardyCross::PipeData::origin(HardyCross::PipeData::path() || HardyCross::PipeData::default_path());
    my $team = $o eq 'TEAM FOLDER';
    $dbv{origin}->configure(-text => $o, -foreground => $team ? $C{accent} : $C{muted},
                            -background => $team ? $C{accent_bg} : $C{hover});
    $dbv{path}->configure(-text => HardyCross::PipeData::path() || HardyCross::PipeData::default_path());
    my $sha = HardyCross::PipeData::sha256();
    $dbv{sha}->configure(-text => $sha ? 'FINGERPRINT ' . uc(substr $sha, 0, 12) : '');
}

# db_state -- buttons and fields on or off for read-only or editing.
sub db_state {
    my $ed = $dbv{editing} && $dbv{db};
    my $mod = $dbv{db} && $dbv{db}{modified};
    $dbv{btn}{$_}->configure(-state => $ed ? 'normal' : 'disabled') for qw(UPDATE ADD DELETE);
    $dbv{btn}{SAVE}->configure($mod && $ed
        ? (-state => 'normal', -background => $C{accent}, -highlightbackground => $C{accent})
        : (-state => 'disabled', -background => $C{panel}, -highlightbackground => $C{line}));
    $dbv{btn}{DISCARD}->configure(-state => $mod ? 'normal' : 'disabled');
    $_->configure(-state => $ed ? 'normal' : 'readonly') for @{ $dbv{entries} || [] };
    $dbv{note}->configure(-text => !$dbv{db} ? ''
        : $ed ? 'EDITING. CHANGES TAKE EFFECT WHEN SAVED, AND EVERY REPORT AFTER THEM PRINTS THE NEW FINGERPRINT.'
              : 'READ-ONLY. TICK EDIT THE DATABASE TO CHANGE IT.');
}

sub db_editing_changed { db_state() }

# db_cols -- the current table's columns.
sub db_cols { return @{ HardyCross::DbEdit::table($dbv{kind})->{cols} } }

# db_fill -- the current table, filtered: every row with a word beginning
# with each word of the filter.
sub db_fill {
    my $kind = $dbv{kind} or return;
    return unless $dbv{tabs};          # make_tabs selects its first tab before it returns
    my $page = $dbv{tabs}{page}{ HardyCross::DbEdit::table($kind)->{title} };
    $dbv{box}{$kind}->destroy if $dbv{box}{$kind};
    my @cols = db_cols();
    my ($h, $box) = hlist($page, scalar @cols);
    my $st = styles($h);
    $dbv{box}{$kind} = $box;
    $dbv{hlist} = $h;
    my @rows = $dbv{db} ? @{ HardyCross::DbEdit::rows($dbv{db}, $kind) } : ();
    my @w = map { length $_->[0] } @cols;
    my @shown = map { [ map { HardyCross::DbEdit::shown($_) } @{ $_->{fields} } ] } @rows;
    for my $r (@shown) { for my $i (0 .. $#w) { my $l = length($r->[$i] // ''); $w[$i] = $l if $l > $w[$i] } }
    my $num = sub { $cols[ $_[0] ][1] =~ /^(int|num)/ };
    heading($h, $_, pad($cols[$_][0], $w[$_], $num->($_) ? 'e' : 'w'), $st->{headm}) for 0 .. $#cols;
    my @words = grep { length } split ' ', uc($dbv{filter} // '');
    $dbv{shown_rows} = [];
    for my $k (0 .. $#rows) {
        # Each word of the filter must begin some word of the row: "50"
        # finds DN 50, not DN 150.
        my @tok = map { split ' ' } @{ $shown[$k] };
        next if grep { my $w = $_; !grep { index($_, $w) == 0 } @tok } @words;
        my $id = $rows[$k]{line};
        $h->add($id);
        $h->itemCreate($id, $_, -text => pad($shown[$k][$_] // '', $w[$_], $num->($_) ? 'e' : 'w'),
                       -style => $st->{w0}) for 0 .. $#cols;
        push @{ $dbv{shown_rows} }, $id;
    }
    $h->configure(-browsecmd => sub { $h->anchorClear; $dbv{sel} = shift; db_form() });
    if (defined $dbv{sel} && $h->info('exists', $dbv{sel})) { $h->selectionSet($dbv{sel}); $h->see($dbv{sel}) }
}

# db_form -- the edit fields for the current table, holding the selected row.
sub db_form {
    my $kind = $dbv{kind} or return;
    return unless $dbv{tabs};
    $_->destroy for $dbv{formrow}->children;
    my @cols = db_cols();
    my $l = defined $dbv{sel} && $dbv{db} ? $dbv{db}{lines}[ $dbv{sel} ] : undef;
    $l = undef unless $l && ($l->{kind} // '') eq $kind;
    $dbv{vals} = [ map { $l ? HardyCross::DbEdit::shown($l->{fields}[$_]) : '' } 0 .. $#cols ];
    $dbv{entries} = [];
    for my $i (0 .. $#cols) {
        my $f = $dbv{formrow}->Frame(-background => $C{panel})->pack(-side => 'left', -padx => px([0, 10]));
        $f->Label(-text => $cols[$i][0], -font => $UI_S_N, -background => $C{panel}, -foreground => $C{muted},
                  -anchor => 'w')->pack(-fill => 'x');
        my $w = $cols[$i][1] eq 'text' ? 30 : $cols[$i][1] eq 'code' ? 9 : 11;
        my $e = flat_entry($f, \$dbv{vals}[$i], $w)->pack(-ipady => px(3));
        $e->configure(-readonlybackground => $C{panel});
        push @{ $dbv{entries} }, $e;
    }
    db_state();
}

# db_message -- a line beside the row buttons: red for a problem.
sub db_message {
    my ($t, $bad) = @_;
    $dbv{msg}->configure(-text => $t, -foreground => $bad ? $C{error} : $C{accent});
}

sub db_update {
    return unless $dbv{editing} && $dbv{db};
    return db_message('SELECT A ROW TO CHANGE FIRST', 1) unless defined $dbv{sel};
    my $err = HardyCross::DbEdit::set_row($dbv{db}, $dbv{sel}, [ @{ $dbv{vals} } ]);
    return db_message($err, 1) if $err;
    db_fill();
    db_state();
    db_message('ROW CHANGED. SAVE CHANGES TO USE IT.');
}

sub db_add {
    return unless $dbv{editing} && $dbv{db};
    my ($err, $at) = HardyCross::DbEdit::add_row($dbv{db}, $dbv{kind}, [ @{ $dbv{vals} } ]);
    return db_message($err, 1) if $err;
    $dbv{sel} = $at;
    db_fill();
    db_state();
    db_message('ROW ADDED. SAVE CHANGES TO USE IT.');
}

sub db_delete {
    return unless $dbv{editing} && $dbv{db};
    return db_message('SELECT A ROW TO DELETE FIRST', 1) unless defined $dbv{sel};
    my $err = HardyCross::DbEdit::delete_row($dbv{db}, $dbv{sel});
    return db_message($err, 1) if $err;
    $dbv{sel} = undef;
    db_fill();
    db_form();
    db_message('ROW DELETED. SAVE CHANGES TO MAKE IT FINAL.');
}

#------------------------------------------------------------------------------
# db_save -- check, write, and use the edited database.  A model validated
# against the old data must be validated again: CALCULATE goes off.
#------------------------------------------------------------------------------
sub db_save {
    return unless $dbv{editing} && $dbv{db} && $dbv{db}{modified};
    my $r = HardyCross::DbEdit::save($dbv{db});
    unless ($r->{ok}) {
        my $p = $r->{problems}[0];
        my $where = defined $p->{line} ? ' (' . HardyCross::DbEdit::table($p->{kind})->{title} . ')' : '';
        $dbv{sel} = $p->{line} if defined $p->{line};
        db_fill();
        return db_message("NOT SAVED: $p->{message}$where", 1);
    }
    db_after_change();
    db_message("SAVED TO $r->{path}. VALIDATE THE MODEL AGAIN BEFORE CALCULATING.");
}

# db_after_change -- the database in use has changed: what was checked or
# calculated against the old one is out of date.
sub db_after_change {
    HardyCross::Editor::clear_cache();
    ($valid_text, $validation, $solved) = (undef, undef, undef);
    fill_results();
    fill_validation();
    db_header();
    db_fill();
    db_state();
    recolour();
    update_actions();
}

#------------------------------------------------------------------------------
# db_choose_folder / db_use_builtin -- where the database is kept, for this
# machine.  A folder with no database yet is offered a copy of the one in use,
# which is how a team starts its shared database.
#------------------------------------------------------------------------------
sub db_choose_folder {
    my $dir = shift;
    return unless db_ok_to_leave();
    $dir //= $mw->chooseDirectory(-title => 'FOLDER FOR THE PIPE AND FITTING DATABASE', -mustexist => 1);
    return unless defined $dir && length $dir;
    my $copy = 0;
    unless (-e File::Spec->catfile($dir, 'pipes.dat')) {
        my $a = shift // $mw->messageBox(-title => 'NO DATABASE IN THAT FOLDER', -icon => 'question',
            -type => 'YesNo', -message => "$dir HAS NO PIPES.DAT.\n\nCOPY THE DATABASE IN USE THERE, TO START "
            . "A SHARED DATABASE FOR THE TEAM?");
        return unless lc($a) eq 'yes';
        $copy = 1;
    }
    my $err = HardyCross::DbEdit::use_folder($dir, $copy);
    return db_message($err, 1) if $err;
    db_open();
    db_after_change();
    db_message("USING THE DATABASE IN $dir ON THIS MACHINE.");
}

sub db_use_builtin {
    return unless db_ok_to_leave();
    HardyCross::DbEdit::use_builtin();
    db_open();
    db_after_change();
    db_message('USING THE BUILT-IN DATABASE ON THIS MACHINE.');
}

# db_ok_to_leave -- true unless there are unsaved database edits the user
# wants to keep.
sub db_ok_to_leave {
    return 1 unless $dbv{db} && $dbv{db}{modified};
    my $a = $mw->messageBox(-title => 'UNSAVED DATABASE CHANGES', -icon => 'warning', -type => 'YesNo',
        -message => 'THE DATABASE HAS CHANGES THAT ARE NOT SAVED.  DISCARD THEM?');
    return lc($a) eq 'yes';
}

#------------------------------------------------------------------------------
# load_settings -- put a document's settings into the PROJECT tab.  The
# values are copied into the hash the fields are tied to, never by replacing
# it, so every field stays tied.
#------------------------------------------------------------------------------
sub load_settings {
    my $new = shift;
    $settings->{title} = $new->{title} // '';
    $settings->{project}{$_} = '' for keys %{ $settings->{project} };
    $settings->{project}{$_} = $new->{project}{$_} for keys %{ $new->{project} };
    $settings->{extra} = [ @{ $new->{extra} || [] } ];
    $settings->{units}{$_} = $new->{units}{$_} for @HardyCross::Phc::UNIT_QUANTITIES;
    $settings->{method} = $new->{method} // 'HW';
    $settings->{options}{$_} = $new->{options}{$_} // '' for @HardyCross::Phc::OPTIONS;
    $_->() for @dd_refresh;
}

# show_field -- the PROJECT tab, with one field focused and marked.
sub show_field {
    my $field = shift;
    select_tab($toptabs, 'PROJECT');
    my $w = $form{$field} or return;
    $w->focus;
    $w->configure(-highlightbackground => $C{error});
    $mw->after(2500, sub { $w->configure(-highlightbackground => $C{line}) if Tk::Exists($w) });
}

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
