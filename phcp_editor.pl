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
#   this file                  colours and fonts, and the dark palette; widget
#                              helpers (flat buttons, tabs, check boxes,
#                              drop-downs); build_window;
#                              the NETWORK tab -- colouring, line numbers, the
#                              lists, the status bar, the command strip,
#                              proposals, the pick list; VALIDATE and
#                              CALCULATE (F4, F5); files; start
#   Window/Project.pm          PROJECT tab: title, details, units, method, options
#   Window/Graph.pm            GRAPH tab: a Q^1.85 water supply graph
#   Window/Tools.pm            QUICK TOOLS tab: the calculators
#   Window/Orifice.pm          ORIFICE PLATE tab: size a plate, or the loss across one
#   Window/Database.pm         DATABASE tab: the pipe and fitting database
#   Window/Results.pm          the results: VALIDATION, PIPES, NODES, OUTLETS
#==============================================================================
use strict;
use Time::HiRes ();
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
use HardyCross::Settings;
# The window, one file to a tab (all in package main).
use HardyCross::Window::Project;
use HardyCross::Window::Tools;
use HardyCross::Window::Orifice;
use HardyCross::Window::Graph;
use HardyCross::Window::Database;
use HardyCross::Window::Results;
use File::Spec;

#------------------------------------------------------------------------------
# Colours.
#
# The same flat palette as the spreadsheet and the isometric drawing: white
# paper, a grey band for the toolbar and the headings, one blue, and a soft
# shadow under a bar.  Blue marks a command word, the current field, the
# active tab and CALCULATE; red marks what is wrong.  Every colour is named
# once here.  Dark mode is the same roles, darker.  %C is the palette on
# screen.  EDITOR_THEME remembers the choice.  The spreadsheet uses
# SHEET_THEME and the isometric drawing uses ISO_THEME, so the three windows
# do not follow each other.
#------------------------------------------------------------------------------
our %THEME_LIGHT = (
    paper      => '#FFFFFF',     # editor, tables, form fields
    panel      => '#F4F6F9',     # toolbar, status bar, headings, line numbers
    line       => '#E2E6EE',     # hairlines and field outlines
    hover      => '#E8F0FA',     # a button or a row under the pointer
    ink        => '#1C1F24',     # text
    muted      => '#5C6570',     # labels, inactive tabs, comments
    faint      => '#8A929E',     # line numbers, disabled text
    accent     => '#1967D2',     # the highlight blue
    accent_dk  => '#1558B0',     # the highlight blue, pressed
    accent_bg  => '#E8F0FE',     # a pale blue behind a highlight
    select     => '#D3E3FD',     # selection
    curline    => '#EEF2F7',     # the cursor's line
    number     => '#185ABC',     # numbers in the editor
    error      => '#C5221F',     # what is wrong
    error_bg   => '#FCE8E6',     # behind a line in error
    fault_bg   => '#F6D4D2',     # behind the field validation found at fault
    warn       => '#8A5A00',     # a warning
    proposal   => '#9AA0A6',     # the greyed proposed line
    sash       => '#E4E7EB',     # the dividers between panes, wide enough to grab
    scroll     => '#C5CDD8',     # the scrollbar thumb
    scroll_on  => '#A8B2C0',     # the scrollbar thumb under the pointer
    shadow     => '#D5DBE3',     # the soft edge under a bar
);
our %THEME_DARK = (
    paper      => '#1F232B',
    panel      => '#282D37',
    line       => '#3A4150',
    hover      => '#323846',
    ink        => '#E8EAED',
    muted      => '#A8B0BD',
    faint      => '#7C8594',
    accent     => '#3D7AEC',
    accent_dk  => '#2F64C4',
    accent_bg  => '#1A2C4C',
    select     => '#2C4468',
    curline    => '#252A33',
    number     => '#A8C7FF',
    error      => '#FF8A80',
    error_bg   => '#3E2628',
    fault_bg   => '#4A3032',
    warn       => '#E7B15A',
    proposal   => '#8E97A6',
    sash       => '#2A303A',
    scroll     => '#555E6E',
    scroll_on  => '#6A7486',
    shadow     => '#14171C',
);
our $theme = 'light';
our %C = %THEME_LIGHT;
# Closures that redraw a canvas from %C (the check boxes).  apply_theme
# calls them after the palette has changed, so the tick is drawn again.
our @theme_draws;
our $view_menu;           # the VIEW menu, so its label can follow the palette

# The ordinary pointer.  X11's "arrow" points up and to the right, so it is
# left_ptr there; Windows calls the same pointer "arrow".
our $POINTER = $^O eq 'MSWin32' ? 'arrow' : 'left_ptr';

# Fonts are chosen when the window is built, the same way the spreadsheet
# chooses them: Inter for the chrome and JetBrains Mono for the model, when
# the machine has them.  Otherwise Segoe UI and Consolas on Windows, DejaVu
# on a plain Linux install.
our ($MONO, $MONO_B, $MONO_I, $UI, $UI_B, $UI_S, $UI_S_N);
sub pick_fonts {
    my %have = map { lc $_ => 1 } $main::mw->fontFamilies;
    my ($mono) = grep { $have{ lc $_ } } 'JetBrains Mono', 'Cascadia Mono', 'Consolas',
        'Roboto Mono', 'Source Code Pro', 'DejaVu Sans Mono', 'Liberation Mono', 'Menlo', 'Courier New';
    my ($ui) = grep { $have{ lc $_ } } 'Inter', 'Segoe UI', 'Roboto', 'Source Sans 3',
        'Noto Sans', 'Cantarell', 'Liberation Sans', 'DejaVu Sans', 'Helvetica Neue', 'Arial';
    $mono //= 'Courier';
    $ui   //= 'Helvetica';
    ($MONO, $MONO_B, $MONO_I) = ([ $mono, 10 ], [ $mono, 10, 'bold' ], [ $mono, 10, 'italic' ]);
    ($UI, $UI_B, $UI_S, $UI_S_N) = ([ $ui, 10 ], [ $ui, 10, 'bold' ], [ $ui, 9, 'bold' ], [ $ui, 9 ]);
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
our ($toptabs, $restabs);        # the NETWORK / PROJECT / GRAPH / QUICK TOOLS / ORIFICE PLATE / DATABASE tabs; the results tabs
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
# A filled button has no second edge: the outline is the same blue as the
# face.  The others sit on the grey bar as a white chip with a hairline,
# the same chips as the spreadsheet's toolbar.
sub flat_button {
    my ($parent, $text, $cmd, %o) = @_;
    my $p = $o{primary};
    return $parent->Button(-text => $text, -command => $cmd, -font => $UI_B,
        -relief => 'flat', -borderwidth => 0, -highlightthickness => 1,
        -highlightbackground => $p ? $C{accent} : $C{line}, -highlightcolor => $C{accent},
        -background => $p ? $C{accent} : $C{paper}, -foreground => $p ? '#FFFFFF' : $C{ink},
        -activebackground => $p ? $C{accent_dk} : $C{hover},
        -activeforeground => $p ? '#FFFFFF' : $C{ink},
        -disabledforeground => $C{faint}, -padx => px(16), -pady => px(6), -cursor => 'hand2');
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
                          -padx => px(14), -pady => px(8), -cursor => 'hand2')->pack(-side => 'top');
        my $u = $f->Frame(-height => px(3), -background => $C{paper})->pack(-side => 'top', -fill => 'x');
        $t->{label}{$n} = [ $l, $u ];
        $l->bind('<ButtonRelease-1>' => sub { select_tab($t, $n) });
        $l->bind('<Enter>' => sub { $l->configure(-foreground => $C{ink}) });
        $l->bind('<Leave>' => sub {
            $l->configure(-foreground => ($t->{current} // '') eq $n ? $C{ink} : $C{muted});
        });
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
    push @theme_draws, $draw;
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
        -background => $C{scroll}, -activebackground => $C{scroll_on}, -highlightthickness => 0);
}

#==============================================================================
# set_icon -- the PHCP icon on the window and the taskbar, in place of Tk's.
#
# A blue tile with a two-loop pipe network and a red sprinkler at the far
# node.  The blue is the editor's accent and the sprinkler is the error
# red.  Each size in the icon is drawn for that size, so both loops are
# still there at 16.  The same picture is data/phcp.ico, which
# build_windows.bat gives the .exe files.
#
# Two routes, because Perl/Tk is Tk 8.4:
#   Windows  wm iconbitmap with the .ico file.  Tk 8.4 has no wm iconphoto,
#            and wm iconimage on Windows changes neither the title bar nor
#            the taskbar, so a picture alone leaves Tk's own icon showing.
#            iconbitmap hands Windows the icon itself, every size in the
#            file, for both.  -default gives it to the dialogs as well.
#   others   the PNG data below, at 16, 32 and 48 pixels, so the window needs
#            no file to find; Tk picks the size the system asks for.
# Without the .ico (Windows) or Tk::PNG (elsewhere) the window simply keeps
# the Tk icon.
#==============================================================================
my %ICON_PNG = (
    16 => join('', qw(
        iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAnklEQVR42mNkqN/PIvFCuIWR
        gSGdgYFBgIE48OE/A8PMFxJva2CayxlIAwKMDAzlEi+EGZigNpMFGBkY0lmQnf1shi5RGqUy
        LsNdwsRAIWDCZQOSLRh8ggZQ7IIRZgCjZPql/6SmA+S0wEKqjceUFSCW3X3AIJVxmYGFgYHh
        Ayw14oprPC78wPKfgWEmsZlJKuMyw7O7D+BsiF4KszMAfKA10dIzwHIAAAAASUVORK5CYII=
    )),
    32 => join('', qw(
        iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAACI0lEQVR42u2XzWsTURTFf28y
        9oOosS3BRArqRgQTCKUFs2nptla6Uimhi3ZjsIYu/APEfYMWIQQjiBWX0oKhW6EoVhBJtSRL
        HYQk5ZlgF7EhHx0XJalNGknsJHGRszycmXPevRfeu4IS7r9R7ckBL+DRwSWgBwOhQ1ZABHiZ
        sKWCPBgvAAgA650tm1osvgYxTEugfyyYTNdlwJEU+yfvf98684MQCVvaXSp7i80BxLA9OeBV
        0PHQLuh4VF3gEhX8vcmzLExYURVhiE9hT2dpTeIPbx/2F7iUo6bdSHMAVREsTFirmwA9Sq0P
        jEatfyq0GWo9onPeL1VcPOhsWPNfVqAToBOgE6AToBOgaQHGr5yq4hZnBjF3K41fRv9i/nz+
        PJlYlHgoRO6HpG90jOnZOS5au7j16CuFPb3+APXcapWaTCzK1s0bFH9lANh595ZMLIrb/5Cp
        EQuvPvxsbgviT0Nl8xLk6gpZTWNyyPL3GSiV5zjIS1mTP91rOgigQ7ZStLQmjx3izOhYFXei
        rx+z08mmtlvellShE0Fw9U+hP7xd9YJtBIszg0zPzpGJRZGrK2Xzy8En5JUuXqyn9h+lOhFh
        v/35LvDYyP6buxWW5y/gvmQmq2nkpOSk00le6cL37DvhTzslqa9pq5mqCKZGLFwbsmDpNbGp
        7bK8nuKbzB1azdq+nCoAMuBIJmxpN+ADNo4aTCPWc2AD8CVsabcMOJIAvwHmU8oCxrBsIgAA
        AABJRU5ErkJggg==
    )),
    48 => join('', qw(
        iVBORw0KGgoAAAANSUhEUgAAADAAAAAwCAYAAABXAvmHAAACsUlEQVR42u2aQUhUURSG/3Pf
        oBMajGQOMxBoCE2E4UCLkbTGTYSg7czdNIgO1MJ2LrRWuWgXRNC4mVQUc1ctCjdONWKLwFDE
        WQQJwujDwBclKPjuaZEzoM6MNjXOu/D+5T3vvvd/vHPOXdxDyCJ3ZDEomENMHCCQDyUUg5PE
        9EkSjejRhvjBOO03Pl8rWIuBEIQVxYhLMsN61L9yCMDT+6UZJN4AcMHaMsCyfW24MZEBcEfm
        awW0eQXMZyAkTL8e9a8IABCsxRQyDwCuPc8gd2QxKMAzUFAS1CoEcwiKSjCHBBMFVAVgooCD
        wHn7fGdTFYa6vKgoFydmbGtHYmAyham5zbzPEdh3pKuTNg8AFeUCQ13e46XRcV5WCh33uwKK
        S3kARyGbbj/5ho/JX1ljLb5KvLxf91/2FO0P5DKSL1bIHrsGbAAbwAawAWwAG8AGsAFsABvA
        BlAWwOd1qgHQ3+HOuj49WJ8z9k8ALb7Kv47lWu/vcKOvrQZsmlgfG8VyTzeWe7qxPjYKjSX6
        2mryQpAnssD5zKaeNxT9D7BpYjkcgjGb2LfuutqMi7ERmCRw49FXJFPb1kwhfWL8kHkAMGYT
        0CfG4RCEzqYq69aA8eH9kbFL55yFAWztSLXb6MBkqugQrmvXj4wtrW4XVsTF7vPTg/XQWBZc
        xFrllbtdBFSXAuD7z12UaYTAhdOo7riFsjPVgBA4VXce3lAYtQ8egjQNT99u4NXnH4e7FyhJ
        nt6FGAh3Sn2Q3bt5Fg6x79oau5Lx7N0GHr/Wc/RfvLDMJZ/P60RnU1Wm2yytbmNqbjNr2qQl
        Qa0EAJ7ehRnL3s7nPP0QXxu+3CoAQJIZBmAoZN/Y8/ynjepR/wpYtisCYYBle3peInMOrA03
        JiRMPxhxK6eNhOlPz0kAB6ZV0lJp3OY3sKYL96Ys/JwAAAAASUVORK5CYII=
    )),
);
sub set_icon {
    if ($^O eq 'MSWin32' and my $ico = icon_file()) {
        return if eval { $mw->iconbitmap('-default', $ico); 1 }
               or eval { $mw->iconbitmap($ico); 1 };
    }
    return unless eval { require Tk::PNG; 1 };
    my @img = map { $mw->Photo(-format => 'png', -data => $ICON_PNG{$_}) }
              sort { $b <=> $a } keys %ICON_PNG;
    eval { $mw->iconphoto('-default', @img); 1 } or eval { $mw->iconimage($img[-1]) };
}

# icon_file -- data/phcp.ico, wherever this copy of the editor keeps it:
# beside the script when run from the source folder, or inside a packaged
# .exe, which unpacks it to PAR_TEMP/inc/lib/data (build_windows.bat adds it
# there).  Undef if neither exists.
sub icon_file {
    my @try = (File::Spec->catfile($FindBin::Bin, 'data', 'phcp.ico'));
    push @try, File::Spec->catfile($ENV{PAR_TEMP}, 'inc', 'lib', 'data', 'phcp.ico') if $ENV{PAR_TEMP};
    my ($ico) = grep { -f } @try;
    return $ico;
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
    $toptabs = make_tabs($top, [ 'NETWORK', 'PROJECT', 'GRAPH', 'QUICK TOOLS', 'ORIFICE PLATE', 'DATABASE' ],
                         sub {
                             tools_refresh() if $_[0] eq 'QUICK TOOLS';
                             orifice_refresh() if $_[0] eq 'ORIFICE PLATE';
                         });
    build_network($toptabs->{page}{NETWORK});
    build_project($toptabs->{page}{PROJECT});
    build_graph($toptabs->{page}{GRAPH});
    build_tools($toptabs->{page}{'QUICK TOOLS'});
    build_orifice($toptabs->{page}{'ORIFICE PLATE'});
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
    # A palette remembered from last time.  The widgets are built in the
    # light colours and then repainted, so the shared tabs take the dark
    # colours too.
    my $saved = eval { lc(HardyCross::Settings::get('EDITOR_THEME') // '') } // '';
    apply_theme('dark') if $saved eq 'dark';
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
    # cascade() here returns the entry, not the menu, so the menu is made on
    # its own and the label of DARK MODE can be changed when the palette is.
    $view_menu = $bar->Menu(-tearoff => 0, -font => $UI, -relief => 'flat', -borderwidth => 0,
        -background => $C{paper}, -foreground => $C{ink},
        -activebackground => $C{select}, -activeforeground => $C{ink});
    $bar->cascade(-label => 'VIEW', -menu => $view_menu);
    $view_menu->command(-label => 'DARK MODE', -command => sub { toggle_theme() });
    my $model = $bar->cascade(-label => 'MODEL', -tearoff => 0);
    $model->command(-label => 'VALIDATE',  -accelerator => 'F4', -command => sub { validate() });
    $model->command(-label => 'CALCULATE', -accelerator => 'F5', -command => sub { calculate() });
}

# build_toolbar -- the file buttons, VALIDATE and CALCULATE, WRITE REPORT,
# DARK MODE, and on the right the model's state: not validated, problems,
# valid, calculated.
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
    $btn{THEME} = flat_button($in, 'DARK MODE', sub { toggle_theme() })->pack(-side => 'right', -padx => px([0, 8]));
    # A soft edge, not a hard rule: the bar sits a step above the page,
    # as it does on the spreadsheet.
    $mw->Frame(-background => $C{shadow}, -height => 1)->pack(-side => 'top', -fill => 'x');
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
    $sb->Frame(-background => $C{shadow}, -height => 1)->pack(-side => 'top', -fill => 'x');
    $statusbar = $sb->Text(-height => 1, -wrap => 'none', -font => $MONO, -background => $C{panel},
        -foreground => $C{ink}, -borderwidth => 0, -highlightthickness => 0, -padx => px(14), -pady => px(6),
        -state => 'disabled', -cursor => $POINTER, -takefocus => 0)->pack(-fill => 'x');

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
    # found at fault, a deeper red with the text underlined.  The same tags
    # are set again when the palette changes.
    style_editor_tags();
    $ed->tagLower('curline');
    $ed->tagRaise('error');
    $ed->tagRaise('fault');
    $ed->tagRaise('proposal');
    $ed->tagRaise('sel');

    # The three lists.
    for my $name (qw(ERRORS WARNINGS NODES)) {
        my $f = $right->Frame(-background => $C{paper})->pack(-fill => 'both', -expand => 1);
        $list_head{$name} = $f->Label(-text => $name, -font => $UI_S, -anchor => 'w', -background => $C{panel},
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

# replace_lines -- the network text changed line by line where it differs,
# keeping the cursor, the view and the undo history of the rest.
sub replace_lines {
    my $new = shift;
    discard_proposal();
    my @old = split /\n/, buffer(), -1;
    my @nl  = split /\n/, $new, -1;
    return set_buffer($new) unless @old == @nl;
    for my $i (0 .. $#nl) {
        next if $old[$i] eq $nl[$i];
        my $n = $i + 1;
        $ed->delete("$n.0", "$n.end");
        $ed->insert("$n.0", $nl[$i]);
    }
}

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
    # The commands sit on the same grey band as the toolbar, edge to edge,
    # with a soft edge under them.  A command is blue; the pointer washes
    # it pale blue.
    my $band = $parent->Frame(-background => $C{panel})->pack(-side => 'top', -fill => 'x');
    $strip = $band->Frame(-background => $C{panel})->pack(-fill => 'x', -padx => px(8), -pady => px(6));
    my @groups = @HardyCross::Phc::COMMAND_GROUPS[1 .. $#HardyCross::Phc::COMMAND_GROUPS];
    my $first = 1;
    for my $group (@groups) {
        $strip->Frame(-background => $C{line}, -width => 1, -height => px(16))->pack(-side => 'left', -padx => px(8))
            unless $first;
        $first = 0;
        for my $cmd (@$group) {
            my $l = $strip->Label(-text => $cmd, -font => $MONO_B, -background => $C{panel},
                                  -foreground => $C{accent}, -padx => px(6), -pady => px(3), -cursor => 'hand2')
                          ->pack(-side => 'left');
            $l->bind('<Enter>' => sub { $l->configure(-background => $C{accent_bg}) });
            $l->bind('<Leave>' => sub { $l->configure(-background => $C{panel}) });
            $l->bind('<ButtonRelease-1>' => sub { start_command($cmd) });
        }
    }
    $parent->Frame(-background => $C{shadow}, -height => 1)->pack(-side => 'top', -fill => 'x');
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
    # A calculation can take a while (auto sizing, design areas): the status
    # bar says what is being worked on, with a turning mark and the seconds
    # gone, so the window is plainly working and not stuck.
    my $t0 = time;
    my ($turn, $shown) = (0, 0);
    my $progress = sub {
        my $what = shift;
        my $now = Time::HiRes::time();
        return if $now - $shown < 0.15;
        $shown = $now;
        message(sprintf('%s COMPUTING - %s - %d S', ('|', '/', '-', '\\')[ $turn++ % 4 ], $what, time - $t0));
        $mw->update;
    };
    $mw->Busy(-recurse => 1);
    $progress->('CALCULATING');
    my $r = eval { HardyCross::Editor::doc_solve(doc(), $path, progress => $progress) };
    my $err = $@;
    $mw->Unbusy;
    die $err unless $r;
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
    # Auto sizing: each sized pipe's size goes in as a comment after its line,
    # //AS - 25.  A comment changes nothing in the model, so the text is still
    # the one that passed VALIDATE.
    if (defined $r->{network} && $r->{network} ne buffer()) {
        replace_lines($r->{network});
        $full = full_text();
        $valid_text = $full;
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
# Dark mode.  The shared tabs read %C when they build a widget, and an HList
# keeps the colours in its cell styles, so both have to be painted again.
# White text on a blue button is not the paper colour: a foreground of white
# is left white, and a background of white becomes the dark paper.
#==============================================================================

# style_editor_tags -- the syntax colours, the gutter and the status bar,
# from the palette now in %C.  Called when the editor is built and again
# when the palette changes.
sub style_editor_tags {
    return unless $ed && $gutter && $statusbar;
    $statusbar->tagConfigure('current', -foreground => $C{accent}, -font => $MONO_B, -underline => 1);
    $statusbar->tagConfigure('muted', -foreground => $C{muted});
    $statusbar->tagConfigure('bad', -foreground => $C{error}, -font => $MONO_B);
    $statusbar->tagConfigure('good', -foreground => $C{accent}, -font => $MONO_B);
    $gutter->tagConfigure('num', -justify => 'right');
    $gutter->tagConfigure('cur', -foreground => $C{ink}, -font => $MONO_B);
    $gutter->tagConfigure('bad', -foreground => $C{error}, -font => $MONO_B);
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
}

# toggle_theme -- the VIEW menu and the toolbar.  The choice is written to
# this machine's settings, the same small file as the database folder, so
# the next time the editor opens it is as it was left.  EDITOR_THEME is
# this window's key.  The spreadsheet reads SHEET_THEME and not this one.
sub toggle_theme {
    apply_theme($theme eq 'dark' ? 'light' : 'dark');
    eval { HardyCross::Settings::set('EDITOR_THEME', uc $theme) };
}

# apply_theme -- put the named palette on screen.  'light' or 'dark'.
sub apply_theme {
    my $name = shift;
    $name = $name && $name eq 'dark' ? 'dark' : 'light';
    return if $name eq $theme && $mw;
    my $from = $theme eq 'dark' ? \%THEME_DARK : \%THEME_LIGHT;
    my $to   = $name eq 'dark' ? \%THEME_DARK : \%THEME_LIGHT;
    my %map;
    for my $k (keys %$from) {
        my $a = uc $from->{$k};
        $map{$a} = $to->{$k} if $a ne uc($to->{$k});
    }
    %C = %$to;
    $theme = $name;
    return unless $mw;
    paint_theme(\%map, $mw);
    my $bar = eval { $mw->cget('-menu') };
    paint_theme(\%map, $bar) if $bar;
    style_editor_tags();
    for my $name (qw(ERRORS WARNINGS NODES)) {
        next unless $list{$name} && eval { Tk::Exists($list{$name}) };
        $list{$name}->configure(-background => $C{paper},
            -foreground => $name eq 'ERRORS' ? $C{error} : $name eq 'WARNINGS' ? $C{warn} : $C{ink},
            -selectbackground => $C{select}, -selectforeground => $C{ink});
    }
    for my $draw (@theme_draws) { eval { $draw->() } }
    eval { graph_draw() } if $main::gv{canvas};
    eval { fill_results() } if $restabs;
    restyle_validation();
    eval { db_header() } if $dbv{path};
    eval { db_fill() } if $dbv{tabs};
    eval { db_form() } if $dbv{formrow};
    eval { db_state() } if $dbv{btn};
    recolour() if $ed;
    $btn{THEME}->configure(-text => $theme eq 'dark' ? 'LIGHT MODE' : 'DARK MODE') if $btn{THEME};
    $view_menu->entryconfigure(0, -label => $theme eq 'dark' ? 'LIGHT MODE' : 'DARK MODE',
        -background => $C{paper}, -foreground => $C{ink},
        -activebackground => $C{select}, -activeforeground => $C{ink}) if $view_menu;
    $mw->optionAdd('*Background', $C{paper});
    $mw->optionAdd('*Foreground', $C{ink});
    $mw->optionAdd('*Menu.background', $C{paper});
    $mw->optionAdd('*Menu.foreground', $C{ink});
    $mw->optionAdd('*Menu.activeBackground', $C{select});
    $mw->optionAdd('*Menu.activeForeground', $C{ink});
    update_actions();
}

# paint_theme -- one widget, its children, and the menus hanging off it.
# A colour that belongs to the palette being left is swapped for the same
# role in the palette being entered.  Anything else (white text on a blue
# button, a system colour) is left.
sub paint_theme {
    my ($map, $w, $seen) = @_;
    $seen //= {};
    return unless $w && eval { Tk::Exists($w) };
    my $path = eval { $w->PathName };
    return unless defined $path;
    return if $seen->{$path}++;
    my @opt = qw(-background -foreground -activebackground -activeforeground
        -highlightbackground -highlightcolor -insertbackground
        -selectbackground -selectforeground -disabledforeground
        -troughcolor -readonlybackground);
    my %fg = map { $_ => 1 } qw(-foreground -activeforeground -selectforeground
        -disabledforeground -insertbackground -highlightcolor);
    for my $opt (@opt) {
        my $v = eval { $w->cget($opt) };
        next unless defined $v && length $v;
        my $hex = uc $v;
        # White as a foreground is the text on a blue button, and the tick
        # in a check box.  White as a background is the paper.
        next if $hex eq '#FFFFFF' && $fg{$opt};
        my $n = $map->{$hex} or next;
        eval { $w->configure($opt => $n) };
    }
    if ($w->isa('Tk::Menu')) {
        eval { $w->configure(-background => $C{paper}, -foreground => $C{ink},
            -activebackground => $C{select}, -activeforeground => $C{ink}) };
        my $end = eval { $w->index('end') };
        if (defined $end && $end ne 'none') {
            for my $i (0 .. $end) {
                next if ($w->type($i) // '') eq 'separator';
                eval { $w->entryconfigure($i, -background => $C{paper}, -foreground => $C{ink},
                    -activebackground => $C{select}, -activeforeground => $C{ink}) };
                my $sub = eval { $w->entrycget($i, '-menu') };
                paint_theme($map, $sub, $seen) if $sub;
            }
        }
    }
    if ($w->isa('Tk::Menubutton')) {
        my $sub = eval { $w->cget('-menu') };
        paint_theme($map, $sub, $seen) if $sub;
    }
    if ($w->isa('Tk::Canvas')) {
        for my $id (eval { $w->find('all') } || ()) {
            for my $opt (qw(-fill -outline)) {
                my $v = eval { $w->itemcget($id, $opt) };
                next unless defined $v && length $v && $v ne 'black';
                next if uc $v eq '#FFFFFF';
                my $n = $map->{ uc $v } or next;
                eval { $w->itemconfigure($id, $opt => $n) };
            }
        }
    }
    if ($w->isa('Tk::Text')) {
        for my $tag (eval { $w->tagNames } || ()) {
            next if $tag eq 'sel';
            for my $opt (qw(-foreground -background)) {
                my $v = eval { $w->tagCget($tag, $opt) };
                next unless defined $v && length $v;
                next if uc $v eq '#FFFFFF';
                my $n = $map->{ uc $v } or next;
                eval { $w->tagConfigure($tag, $opt => $n) };
            }
        }
    }
    paint_theme($map, $_, $seen) for eval { $w->children };
}

# restyle_validation -- the VALIDATION table keeps its cell styles from when
# it was built.  New styles, then the rows again, so a fault reads in the
# palette now on screen.  The result tables are rebuilt by fill_results.
sub restyle_validation {
    return unless $vtable && $vtable->{hlist} && eval { Tk::Exists($vtable->{hlist}) };
    my $h = $vtable->{hlist};
    $h->configure(-background => $C{paper}, -foreground => $C{ink},
        -selectbackground => $C{select}, -selectforeground => $C{ink});
    $vtable->{styles} = styles($h, wrap => 620);
    for my $i (0 .. 3) {
        eval { $h->header('configure', $i, -style => $vtable->{styles}{headw},
                          -headerbackground => $C{panel}) };
    }
    fill_validation();
}

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
