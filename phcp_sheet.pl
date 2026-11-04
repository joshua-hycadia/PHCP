#!/usr/bin/perl
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# phcp_sheet.pl -- the spreadsheet window.
#
#   perl phcp_sheet.pl [model.phc]
#
# A second way in to the same engine.  phcp_editor.pl is the text editor and
# is not changed by this program: the two do not share a window, and a file
# saved here is ordinary .phc, which phcp.pl and the editor already read.
#
#   +------------------------------------------------------------------+
#   | NEW OPEN SAVE | VALIDATE  CALCULATE | WRITE REPORT    [ status ] |
#   +------------------------------------------------------------------+
#   | SYSTEM | NODES | SUPPLIES | PRESSURE DEVICES | PROJECT | GRAPH   |
#   |        | QUICK TOOLS | ORIFICE PLATE | DATABASE                |
#   |  ROW | PIPE | FROM NODE | TO NODE | LENGTH | TYPE | DIAM | ...    |
#   |   1  |  1   | 2         | 101     | 7000   | S20  | 100  | 2E T   |
#   +------------------------------------------------------------------+
#   | VALIDATION | PIPES | NODES | OUTLETS | REPORT                     |
#   +------------------------------------------------------------------+
#
# SYSTEM is the pipes, one row each.  NODES is filled from the node numbers
# typed there, in the order they first appear.  A blank node type is a node;
# the word is not written in the cell.  SUPPLY on a node adds a row to
# SUPPLIES.  A pressure-device type adds a row to that device's table, and
# each device has only the columns it needs.
#
# PIPE TYPE, PIPE DIAM and NODE TYPE are lists.  The pipe types and the
# nominal sizes come from the database.  BORE, and a type the database does
# not know, leave the diameter as a cell to type in.  EDIT inserts, deletes
# and clears rows, copies a cell downwards, and finds and replaces.  VIEW
# switches the whole window between the light palette and a dark one.
#
# PROJECT, GRAPH, QUICK TOOLS, ORIFICE PLATE and DATABASE are the same tabs
# as the editor.
# They live in HardyCross/Window/ and decide nothing for themselves.  The
# decisions for the grids are HardyCross::Sheet, which has no Tk in it.
# VALIDATE and CALCULATE call HardyCross::Editor, the same checks and the
# same solve the text editor uses.
#
# Perl 5, as the rest of PHCP.  The defined-or operator needs Perl 5.10,
# which the engine already requires.  No signatures and no try/catch.
#
# The flat buttons, tabs and colours below belong to this window: a white
# sheet, a grey band for the toolbar and the column headings, a shadow
# under the bar, and a stripe on alternate rows.  Inter and JetBrains Mono
# are used when the machine has them.  The editor is not opened and is
# not edited.
#==============================================================================
use strict;
use warnings;
use FindBin;
use lib $FindBin::Bin;
use Time::HiRes ();
use Storable ();
use Tk;
use Tk::Panedwindow;
use Tk::HList;
use File::Spec;
use HardyCross;
use HardyCross::Phc;
use HardyCross::Editor;
use HardyCross::Sheet;
use HardyCross::DbEdit;
use HardyCross::Graph;
use HardyCross::Tools;
use HardyCross::Settings;
# The shared tabs.  Each is package main, as it is for the editor, so the
# helpers below are the ones it calls.  Nothing in those files is modified.
use HardyCross::Window::Project;
use HardyCross::Window::Tools;
use HardyCross::Window::Orifice;
use HardyCross::Window::Graph;
use HardyCross::Window::Database;
use HardyCross::Window::Results;

#------------------------------------------------------------------------------
# Colours and type.  The sheet has its own flat palette: a white surface, a
# grey header band, one blue, and a shadow line under the toolbar.  It is not
# the editor's palette, and the editor is not changed by it.  DARK MODE swaps
# in the second palette.  %C is the one on screen.
# The two hashes stay as they were defined, so a toggle can map every colour
# a widget was given back to the other palette.  scroll is the scrollbar
# thumb.  shadow is the soft edge under a bar.
# Widgets take a copy of the hex when they are built.  Changing %C does not
# by itself repaint them; apply_theme walks the window and swaps the hexes.
#------------------------------------------------------------------------------
our %THEME_LIGHT = (
    paper      => '#FFFFFF',
    panel      => '#F4F6F9',
    line       => '#E2E6EE',
    hover      => '#E8F0FA',
    ink        => '#1C1F24',
    muted      => '#5C6570',
    faint      => '#8A929E',
    accent     => '#1967D2',
    accent_dk  => '#1558B0',
    accent_bg  => '#E8F0FE',
    select     => '#D3E3FD',
    curline    => '#EEF2F7',
    number     => '#185ABC',
    error      => '#C5221F',
    error_bg   => '#FCE8E6',
    fault_bg   => '#F6D4D2',
    warn       => '#8A5A00',
    proposal   => '#9AA0A6',
    sash       => '#E4E7EB',
    scroll     => '#C5CDD8',
    scroll_on  => '#A8B2C0',
    shadow     => '#D5DBE3',
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
our $POINTER = $^O eq 'MSWin32' ? 'arrow' : 'left_ptr';
our ($MONO, $MONO_B, $MONO_I, $UI, $UI_B, $UI_S, $UI_S_N);
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
        my $per = Win32::API->new('shcore', 'SetProcessDpiAwareness', 'I', 'I');
        if ($per) { $per->Call(1) } else { Win32::API->new('user32', 'SetProcessDPIAware', '', 'I')->Call() }
        1;
    };
}

sub pick_fonts {
    # Inter for the chrome and JetBrains Mono for the grid, when the machine
    # has them.  Otherwise the same faces the editor would pick: Segoe UI and
    # Consolas on Windows, DejaVu on a plain Linux install.  The grid stays
    # monospace so a column of figures lines up.
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
# Flat widgets.  Tk's own buttons and tabs are bevelled; these are not.
#------------------------------------------------------------------------------
sub rule {
    my ($parent, $fill, %pack) = @_;
    my $f = $parent->Frame(-background => $C{line}, ($fill eq 'x' ? (-height => 1) : (-width => 1)));
    $f->pack(-fill => $fill, %pack);
    return $f;
}

sub flat_button {
    my ($parent, $text, $cmd, %o) = @_;
    my $p = $o{primary};
    # A filled button has no second edge: the outline is the same blue as the
    # face.  The others sit on the grey bar as a white chip with a hairline.
    return $parent->Button(-text => $text, -command => $cmd, -font => $UI_B,
        -relief => 'flat', -borderwidth => 0, -highlightthickness => 1,
        -highlightbackground => $p ? $C{accent} : $C{line}, -highlightcolor => $C{accent},
        -background => $p ? $C{accent} : $C{paper}, -foreground => $p ? '#FFFFFF' : $C{ink},
        -activebackground => $p ? $C{accent_dk} : $C{hover},
        -activeforeground => $p ? '#FFFFFF' : $C{ink},
        -disabledforeground => $C{faint}, -padx => px(16), -pady => px(6), -cursor => 'hand2');
}

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
    return unless $t && $t->{page}{$n};
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
    push @theme_draws, $draw;
    return { frame => $f, draw => $draw, label => $l, count => $n };
}

our @dd_refresh;
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
        $m->command(-label => ($v eq '' ? 'DEFAULT' : $v) . (defined $default && $v eq $default ? '   (DEFAULT)' : ''),
                    -command => sub { $$var = $v; $mb->configure(-text => $show->()); $cmd->() });
    }
    $mb->configure(-menu => $m);
    push @dd_refresh, sub { $mb->configure(-text => $show->()) };
    return $mb;
}

sub flat_entry {
    my ($parent, $var, $width) = @_;
    return $parent->Entry(-textvariable => $var, -font => $MONO, -width => $width // 30,
        -relief => 'flat', -borderwidth => 0, -highlightthickness => 1,
        -highlightbackground => $C{line}, -highlightcolor => $C{accent},
        -background => $C{paper}, -foreground => $C{ink}, -insertbackground => $C{ink},
        -selectbackground => $C{select}, -selectforeground => $C{ink});
}

sub divider {
    my ($parent, $orient) = @_;
    return $parent->Panedwindow(-orient => $orient, -background => $C{sash}, -sashwidth => px(6),
        -sashpad => 0, -borderwidth => 0, -showhandle => 0, -handlesize => 0,
        -sashrelief => 'flat', -opaqueresize => 1,
        -sashcursor => $orient eq 'vertical' ? 'sb_v_double_arrow' : 'sb_h_double_arrow');
}

sub flat_scrollbar {
    my ($parent, $orient) = @_;
    return $parent->Scrollbar(-orient => $orient, -relief => 'flat', -borderwidth => 0,
        -elementborderwidth => 0, -width => px(11), -troughcolor => $C{panel},
        -background => $C{scroll}, -activebackground => $C{scroll_on}, -highlightthickness => 0);
}

# The wheel scrolls whatever is under the pointer, not whichever widget has
# the keyboard focus.  The editor does the same, for the same reason: a
# focused cell would otherwise steal the wheel from the grid.
# $mw is declared here, before the subs that name it: an our later in the
# file would not be in scope for these.
our ($mw, %WHEEL);
sub wheel_target {
    my ($w, $target) = @_;
    $WHEEL{ $w->PathName } = $target // $w;
    $w->bindtags([ 'PhcWheel', grep { $_ ne 'PhcWheel' } $w->bindtags ]);
}
sub route_wheel {
    my ($units, $X, $Y) = @_;
    my $w = $mw->containing($X, $Y);
    $w = $w->parent while $w && !$WHEEL{ $w->PathName } && $w ne $mw;
    my $t = $w && $WHEEL{ $w->PathName } or return;
    $t->yview('scroll', $units, 'units');
    Tk->break;
}
sub bind_wheel {
    for my $tag ('PhcWheel', $mw) {
        $mw->bind($tag, '<MouseWheel>' => [ sub { my (undef, $d, $X, $Y) = @_;
            route_wheel($d > 0 ? -3 * (int($d / 120) || 1) : 3 * (int(-$d / 120) || 1), $X, $Y) },
            Ev('D'), Ev('X'), Ev('Y') ]);
        $mw->bind($tag, '<Button-4>' => [ sub { route_wheel(-3, $_[1], $_[2]) }, Ev('X'), Ev('Y') ]);
        $mw->bind($tag, '<Button-5>' => [ sub { route_wheel(3,  $_[1], $_[2]) }, Ev('X'), Ev('Y') ]);
    }
}

sub set_icon {
    # Windows takes the .ico for the title bar and the taskbar.  Tk 8.4 has
    # no wm iconphoto there.  Elsewhere the window keeps Tk's icon: the
    # editor embeds its own PNGs, and this program does not copy them.
    if ($^O eq 'MSWin32' and my $ico = icon_file()) {
        return if eval { $mw->iconbitmap('-default', $ico); 1 }
               or eval { $mw->iconbitmap($ico); 1 };
    }
}
sub icon_file {
    my @try = (File::Spec->catfile($FindBin::Bin, 'data', 'phcp.ico'));
    push @try, File::Spec->catfile($ENV{PAR_TEMP}, 'inc', 'lib', 'data', 'phcp.ico') if $ENV{PAR_TEMP};
    my ($ico) = grep { -f } @try;
    return $ico;
}

#------------------------------------------------------------------------------
# The window's state.  One sheet window per process.
# $settings is the PROJECT tab's hash.  The sheet holds that same hash, so a
# unit changed on the PROJECT tab is the unit the file is written with.
#------------------------------------------------------------------------------
our ($toptabs, $restabs, $devtabs, $report, $pill, $hint, $statusbar, $vtable);
our (%btn, %form, %checks, %table, %dbv, %gv, %pipe_show, %grids);
our ($hide_pipes, $hide_nodes) = (0, 0);
our $project_canvas;
our $path;
our $settings = HardyCross::Editor::new_settings();
our $sheet = HardyCross::Sheet::new_sheet($settings);
our ($solved, $validation, $valid_text);
our $saved_text = '';
our @undo_stack;
our @redo_stack;
our $restoring = 0;       # true while undo or redo is putting a snapshot back
our @fault_marks;         # entries whose outline is red after VALIDATE
our $BLANKS = 8;          # empty SYSTEM rows under the last pipe, to type into
our $system_pad = $BLANKS; # grows when Enter is pressed on the last of those rows
our $view_menu;           # the VIEW menu, so its label can follow the palette
# Find and replace.  The dialog and the menu share these.  $find_pos is the
# cell last landed on, "grid, row, column", so FIND NEXT moves on from it.
our ($find_what, $find_with) = ('', '');
our $find_case = 0;
our $find_all = 0;
our $find_pos;
our $find_box;

#==============================================================================
# The window.
#==============================================================================
sub build_window {
    dpi_aware();
    $mw = MainWindow->new(-background => $C{paper});
    set_icon();
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

    my $vp = divider($mw, 'vertical');
    my $top = $mw->Frame(-background => $C{paper});
    my $bottom = $mw->Frame(-background => $C{paper});
    $toptabs = make_tabs($top, [ 'SYSTEM', 'NODES', 'SUPPLIES', 'PRESSURE DEVICES',
                                 'PROJECT', 'GRAPH', 'QUICK TOOLS', 'ORIFICE PLATE', 'DATABASE' ],
                         sub {
                             tools_refresh() if $_[0] eq 'QUICK TOOLS';
                             orifice_refresh() if $_[0] eq 'ORIFICE PLATE';
                         });
    build_system($toptabs->{page}{SYSTEM});
    build_nodes($toptabs->{page}{NODES});
    build_supplies($toptabs->{page}{SUPPLIES});
    build_devices($toptabs->{page}{'PRESSURE DEVICES'});
    build_project($toptabs->{page}{PROJECT});
    build_graph($toptabs->{page}{GRAPH});
    build_tools($toptabs->{page}{'QUICK TOOLS'});
    build_orifice($toptabs->{page}{'ORIFICE PLATE'});
    build_database($toptabs->{page}{DATABASE});
    build_results($bottom);
    $vp->add($top, -height => px(560));
    $vp->add($bottom);
    $vp->pack(-fill => 'both', -expand => 1);

    my $foot = $mw->Frame(-background => $C{panel})->pack(-side => 'bottom', -fill => 'x');
    $foot->Frame(-background => $C{shadow}, -height => 1)->pack(-side => 'top', -fill => 'x');
    $hint = $foot->Label(-text => '', -font => $UI, -background => $C{panel}, -foreground => $C{muted},
                         -anchor => 'w', -justify => 'left', -wraplength => px(1100))
                 ->pack(-fill => 'x', -padx => px(16), -pady => px([6, 0]));
    $statusbar = $foot->Label(-text => '', -font => $UI, -background => $C{panel}, -foreground => $C{ink},
                              -anchor => 'w', -justify => 'left')->pack(-fill => 'x', -padx => px(16), -pady => px([1, 8]));

    bind_keys();
    refresh_all();
    $saved_text = full_text();
    set_title();
    update_actions();
    update_status();
    # A palette remembered from last time.  The widgets are built light and
    # then repainted, so the shared tabs take the dark colours too.
    my $saved = eval { lc(HardyCross::Settings::get('SHEET_THEME') // '') } // '';
    apply_theme('dark') if $saved eq 'dark';
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
    $edit->command(-label => 'UNDO',       -accelerator => 'CTRL+Z', -command => sub { edit_undo() });
    $edit->command(-label => 'REDO',       -accelerator => 'CTRL+Y', -command => sub { edit_redo() });
    $edit->separator;
    $edit->command(-label => 'INSERT ROW', -accelerator => 'CTRL+INS', -command => sub { edit_insert_row() });
    $edit->command(-label => 'DELETE ROW', -accelerator => 'CTRL+DEL', -command => sub { edit_delete_row() });
    $edit->command(-label => 'CLEAR ROW',                             -command => sub { edit_clear_row() });
    $edit->command(-label => 'FILL DOWN',  -accelerator => 'CTRL+D',  -command => sub { edit_fill_down() });
    $edit->separator;
    $edit->command(-label => 'FIND...',    -accelerator => 'CTRL+F',  -command => sub { open_find(0) });
    $edit->command(-label => 'REPLACE...', -accelerator => 'CTRL+H',  -command => sub { open_find(1) });
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
    # A soft edge, not a hard rule: the bar sits a step above the sheet.
    $mw->Frame(-background => $C{shadow}, -height => 1)->pack(-side => 'top', -fill => 'x');
}

sub bind_keys {
    $mw->bind('<F4>'        => sub { validate() });
    $mw->bind('<F5>'        => sub { calculate() });
    $mw->bind('<Control-n>' => sub { file_new() });
    $mw->bind('<Control-o>' => sub { file_open() });
    $mw->bind('<Control-s>' => sub { file_save() });
    $mw->bind('<Control-r>' => sub { file_report() });
    $mw->bind('<Control-q>' => sub { file_quit() });
    $mw->bind('<Control-z>' => sub { edit_undo() });
    $mw->bind('<Control-y>' => sub { edit_redo() });
    $mw->bind('<Control-d>' => sub { edit_fill_down() });
    $mw->bind('<Control-f>' => sub { open_find(0) });
    $mw->bind('<Control-h>' => sub { open_find(1) });
    $mw->bind('<Control-Insert>' => sub { edit_insert_row() });
    $mw->bind('<Control-Delete>' => sub { edit_delete_row() });
    $mw->protocol('WM_DELETE_WINDOW' => sub { file_quit() });
    bind_wheel();
}

# A one-line description above each grid, so the tab says where its rows
# come from.  The grids themselves scroll under it.
sub blurb {
    my ($page, $text) = @_;
    my $f = $page->Frame(-background => $C{paper})->pack(-side => 'top', -fill => 'x', -padx => px(16), -pady => px([10, 6]));
    $f->Label(-text => $text, -font => $UI, -background => $C{paper}, -foreground => $C{muted},
              -anchor => 'w', -justify => 'left', -wraplength => px(1100))->pack(-fill => 'x');
    return $f;
}

sub build_system {
    my $page = shift;
    blurb($page, 'Each row is a pipe.  Pipe type, and the diameter of a database type, are lists.  Drag a cell\'s bottom-right corner to copy it down.  Edit inserts, deletes, clears, and finds.');
    $grids{SYSTEM} = build_grid($page, 'SYSTEM');
}
sub build_nodes {
    my $page = shift;
    blurb($page, 'Filled from the System tab, in the order the node numbers first appear.  A blank type is a node, and the word is not written in the cell.');
    $grids{NODES} = build_grid($page, 'NODES');
}
sub build_supplies {
    my $page = shift;
    blurb($page, 'A row appears when a node\'s type is Supply.  The elevation stays on the Nodes tab.');
    $grids{SUPPLIES} = build_grid($page, 'SUPPLIES');
}
sub build_devices {
    my $page = shift;
    blurb($page, 'A row appears when a node\'s type is that device.  A device already in a file is listed too.  Each table has only the columns that device needs.');
    $devtabs = make_tabs($page, [ @HardyCross::Sheet::DEVICE_TYPES ]);
    for my $type (@HardyCross::Sheet::DEVICE_TYPES) {
        $grids{"DEV:$type"} = build_grid($devtabs->{page}{$type}, "DEV:$type");
    }
}

#------------------------------------------------------------------------------
# One grid: a header that stays put while the body scrolls down, and scrolls
# sideways with the body.  Row numbers are the first column, as on a sheet.
#
# The cells are placed in a frame, not drawn in a canvas.  A window embedded
# in a canvas does not take the keyboard in this Tk, so a click could not
# put the cursor in a cell.  A frame that is only moved (place) scrolls the
# same way and the cells focus normally.
#------------------------------------------------------------------------------
sub build_grid {
    my ($parent, $id) = @_;
    my $g = { id => $id, cell => {}, ox => 0, oy => 0 };
    my $box = $parent->Frame(-background => $C{paper})->pack(-fill => 'both', -expand => 1);
    $g->{vsb} = flat_scrollbar($box, 'vertical')->pack(-side => 'right', -fill => 'y');
    my $col = $box->Frame(-background => $C{paper})->pack(-fill => 'both', -expand => 1);
    $g->{hclip} = $col->Frame(-background => $C{panel}, -height => px(42))->pack(-side => 'top', -fill => 'x');
    $g->{hclip}->packPropagate(0);
    $g->{hframe} = $g->{hclip}->Frame(-background => $C{panel});
    $col->Frame(-background => $C{line}, -height => 1)->pack(-side => 'top', -fill => 'x');
    $g->{hframe}->place(-x => 0, -y => 0, -anchor => 'nw');
    $g->{hsb} = flat_scrollbar($col, 'horizontal')->pack(-side => 'bottom', -fill => 'x');
    $g->{clip} = $col->Frame(-background => $C{paper})->pack(-fill => 'both', -expand => 1);
    $g->{frame} = $g->{clip}->Frame(-background => $C{paper});
    $g->{frame}->place(-x => 0, -y => 0, -anchor => 'nw');
    $g->{vsb}->configure(-command => sub { grid_scroll($g, 'y', @_) });
    $g->{hsb}->configure(-command => sub { grid_scroll($g, 'x', @_) });
    $g->{clip}->bind('<Configure>' => sub { grid_place($g) });
    $g->{hframe}->bind('<Configure>' => sub {
        my $h = $g->{hframe}->reqheight;
        $g->{hclip}->configure(-height => $h) if $h && $h != ($g->{hclip}->cget('-height') || 0);
    });
    my $wheel = bless { g => $g }, 'PhcScroller';
    wheel_target($g->{clip}, $wheel);
    wheel_target($g->{hclip}, $wheel);
    return $g;
}

# grid_scroll -- the scrollbar's command.  'moveto' is a fraction of the
# grid; 'scroll' is a step, a page when the bar asks for one.
sub grid_scroll {
    my ($g, $axis, $how, $a, $b) = @_;
    my ($view, $full) = $axis eq 'x'
        ? ($g->{clip}->width,  $g->{frame}->reqwidth)
        : ($g->{clip}->height, $g->{frame}->reqheight);
    $view ||= 1;
    $full ||= 1;
    my $max = $full - $view;
    $max = 0 if $max < 0;
    my $off = $axis eq 'x' ? $g->{ox} : $g->{oy};
    if ($how eq 'moveto') {
        $off = $a * $full;
    } elsif ($how eq 'scroll') {
        my $step = (defined $b && $b eq 'pages') ? int($view * 0.9) : px(18);
        $off += $a * $step;
    }
    $off = 0 if $off < 0;
    $off = $max if $off > $max;
    if ($axis eq 'x') { $g->{ox} = $off } else { $g->{oy} = $off }
    grid_place($g);
}

# grid_wheel -- the wheel, in rows.  PhcScroller calls this.
sub grid_wheel {
    my ($g, $units) = @_;
    grid_scroll($g, 'y', 'scroll', $units, 'units');
}

# grid_place -- put the grid at the current offset and tell the scrollbars
# how much of it is showing.
sub grid_place {
    my $g = shift;
    return if $g->{placing};
    $g->{placing} = 1;
    my $vw = $g->{clip}->width  || 1;
    my $vh = $g->{clip}->height || 1;
    my $fw = $g->{frame}->reqwidth  || 1;
    my $fh = $g->{frame}->reqheight || 1;
    my $maxx = $fw - $vw; $maxx = 0 if $maxx < 0;
    my $maxy = $fh - $vh; $maxy = 0 if $maxy < 0;
    $g->{ox} = 0 if $g->{ox} < 0; $g->{ox} = $maxx if $g->{ox} > $maxx;
    $g->{oy} = 0 if $g->{oy} < 0; $g->{oy} = $maxy if $g->{oy} > $maxy;
    $g->{frame}->place(-x => -$g->{ox}, -y => -$g->{oy}, -anchor => 'nw');
    $g->{hframe}->place(-x => -$g->{ox}, -y => 0, -anchor => 'nw');
    $g->{hsb}->set($fw ? $g->{ox} / $fw : 0, $fw ? ($g->{ox} + $vw) / $fw : 1);
    $g->{vsb}->set($fh ? $g->{oy} / $fh : 0, $fh ? ($g->{oy} + $vh) / $fh : 1);
    $g->{placing} = 0;
}

# The columns and the rows each grid shows.  The column list is the model's,
# so the heading and the field written to the file are the same thing.
sub grid_spec {
    my $id = shift;
    # An array of columns, then how many rows.  The column functions return
    # a list; it is wrapped so the row count is not mistaken for a column.
    if ($id eq 'SYSTEM') {
        return ([ HardyCross::Sheet::system_columns($sheet) ], system_row_count());
    }
    if ($id eq 'NODES') {
        my @ids = HardyCross::Sheet::node_rows($sheet);
        return ([ HardyCross::Sheet::node_columns($sheet) ], scalar @ids);
    }
    if ($id eq 'SUPPLIES') {
        my @ids = HardyCross::Sheet::supply_rows($sheet);
        return ([ HardyCross::Sheet::supply_columns($sheet) ], scalar @ids);
    }
    if ($id =~ /^DEV:(.+)/) {
        my @rows = HardyCross::Sheet::device_rows($sheet, $1);
        return ([ HardyCross::Sheet::device_columns($sheet, $1) ], scalar @rows);
    }
    return ([], 0);
}

sub system_row_count {
    my $last = $#{ $sheet->{pipes} };
    $last-- while $last >= 0 && HardyCross::Sheet::pipe_is_blank($sheet->{pipes}[$last]);
    my $pad = $system_pad;
    $pad = $BLANKS if !defined $pad || $pad < $BLANKS;
    my $n = $last + 1 + $pad;
    return $n < $pad ? $pad : $n;
}

# grid_signature -- columns and row identity.  A new node, or a new pair of
# curve columns, changes it and the grid is built again.  Typing in a cell
# that is already there does not.
sub grid_signature {
    my $id = shift;
    my ($cols, $n) = grid_spec($id);
    my @id;
    if ($id eq 'NODES')    { @id = HardyCross::Sheet::node_rows($sheet) }
    elsif ($id eq 'SUPPLIES') { @id = HardyCross::Sheet::supply_rows($sheet) }
    elsif ($id =~ /^DEV:(.+)/) { @id = map { $_->{name} . '|' . ($_->{node} // '') . '|' . ($_->{pipe} // '') }
                                      HardyCross::Sheet::device_rows($sheet, $1) }
    else { @id = 0 .. $n - 1 }
    # The heading carries the unit, so a change of units on the PROJECT tab
    # builds the grid again.  On SYSTEM the diameter cell is a list or a
    # typed cell according to the type that row inherits, so that is part of
    # the signature too: changing the type rebuilds that cell's choices.
    my $units = join ',', map { $sheet->{settings}{units}{$_} // '' } qw(LENGTH SIZE ELEVATION FLOW PRESSURE KFACTOR);
    my @shape = map { $_->{key} . ':' . $_->{head} } @$cols;
    my @diam;
    if ($id eq 'SYSTEM') {
        for my $r (0 .. $n - 1) {
            my $t = HardyCross::Sheet::effective_type($sheet, $r);
            my $list = HardyCross::Sheet::diam_choices($sheet, $t) ? 'L' : 'E';
            push @diam, "$t:$list";
        }
    }
    return join "\n", $units, @shape, '---', @id, '===', @diam;
}

sub refresh_all {
    return unless $grids{SYSTEM};
    # A node type of PRV with no row yet gains one before the tables paint.
    HardyCross::Sheet::reconcile($sheet);
    refresh_grid($_) for qw(SYSTEM NODES SUPPLIES), map { "DEV:$_" } @HardyCross::Sheet::DEVICE_TYPES;
    mark_faults() if $validation && defined $validation->{text} && $validation->{text} eq eval { full_text() };
}

sub refresh_others {
    my $except = shift;
    for my $id (qw(SYSTEM NODES SUPPLIES), map { "DEV:$_" } @HardyCross::Sheet::DEVICE_TYPES) {
        next if $id eq $except;
        refresh_grid($id);
    }
}

# refresh_grid -- paint one grid.  Rebuild when the rows or the columns
# changed; otherwise write the values into the cells, leaving the cell the
# user is typing in alone.
sub refresh_grid {
    my $id = shift;
    my $g = $grids{$id} or return;
    return if $g->{building};   # a cell destroyed by a rebuild must not rebuild again
    my $sig = grid_signature($id);
    if (!$g->{sig} || $g->{sig} ne $sig) {
        $g->{building} = 1;
        $g->{sig} = $sig;
        rebuild_grid($g);
        $g->{building} = 0;
        return;
    }
    my ($cols, $n) = grid_spec($id);
    for my $r (0 .. $n - 1) {
        for my $col (@$cols) {
            my $w = $g->{cell}{$r}{ $col->{key} } or next;
            my $val = cell_get($id, $r, $col->{key});
            # A list and a read-only cell show their text.  An entry the user
            # is typing in is left alone, so a refresh does not move the cursor.
            if (!$w->isa('Tk::Entry')) {
                $w->configure(-text => $val);
            } elsif ($mw->focus && $w eq $mw->focus) {
                next;
            } elsif ($w->get ne $val) {
                $w->delete(0, 'end');
                $w->insert(0, $val);
            }
        }
    }
}

sub rebuild_grid {
    my $g = shift;
    my $id = $g->{id};
    $_->destroy for $g->{frame}->children, $g->{hframe}->children;
    $g->{cell} = {};
    $g->{rownum} = {};
    $g->{ro} = {};
    $g->{hover} = undef;
    my ($cols, $n) = grid_spec($id);
    # Bold headings are wider than the same letters in the cell face.  The
    # column is the wider of the heading and the cell's character width, plus
    # the padding, so a heading such as PIPE DIAM is not clipped.
    my $cw = $mw->fontMeasure($MONO, '0') || 8;
    my $col_px = sub {
        my $col = shift;
        my $head_w = $mw->fontMeasure($MONO_B, $col->{head}) || 0;
        my $body_w = $cw * ($col->{width} || 1);
        my $w = $head_w > $body_w ? $head_w : $body_w;
        return $w + px(22);
    };
    my $c = 0;
    my $head = sub {
        my ($text, $pxw) = @_;
        my $l = $g->{hframe}->Label(-text => $text, -font => $MONO_B, -background => $C{panel},
                                    -foreground => $C{ink}, -anchor => 'w', -padx => px(6), -pady => px(8));
        $l->grid(-row => 0, -column => $c, -sticky => 'ew');
        $g->{hframe}->gridColumnconfigure($c, -minsize => $pxw);
        $g->{frame}->gridColumnconfigure($c, -minsize => $pxw);
        $c++;
    };
    my $row_w = $mw->fontMeasure($MONO_B, 'ROW') || 0;
    my $num_w = $mw->fontMeasure($MONO, '9999') || 0;
    $head->('ROW', ($row_w > $num_w ? $row_w : $num_w) + px(22));
    $head->($_->{head}, $col_px->($_)) for @$cols;

    for my $r (0 .. $n - 1) {
        my $bg = $r % 2 ? $C{curline} : $C{paper};
        my $num = $g->{frame}->Label(-text => $r + 1, -font => $MONO, -background => $C{panel},
                                     -foreground => $C{muted}, -anchor => 'e', -width => 4, -padx => px(6), -pady => px(3));
        $num->grid(-row => $r, -column => 0, -sticky => 'nsew');
        $g->{rownum}{$r} = $num;
        bind_row_hover($num, $g, $r);
        my $cc = 1;
        for my $col (@$cols) {
            my $w = make_cell($g, $r, $col, $bg);
            $w->grid(-row => $r, -column => $cc, -sticky => 'nsew');
            $g->{cell}{$r}{ $col->{key} } = $w;
            $cc++;
        }
    }
    grid_place($g);
}

# row_base_bg -- the colour a cell has when the pointer is not on its row.
# Read-only cells and the row number sit on the grey band.  The rest stripe.
sub row_base_bg {
    my ($g, $r, $key) = @_;
    return $C{panel} if !defined $key || $g->{ro}{$r}{$key};
    return $r % 2 ? $C{curline} : $C{paper};
}

# paint_row -- shade a whole row, or put its own colours back.  A fault's
# red outline is a highlight colour, so this does not touch it.  A fill drag
# and a rebuild leave the row alone: those are already painting it.
sub paint_row {
    my ($g, $r, $on) = @_;
    return unless $g && defined $r;
    return if $g->{building} || $g->{drag};
    my $num = $g->{rownum}{$r};
    $num->configure(-background => $on ? $C{hover} : $C{panel}) if $num && eval { Tk::Exists($num) };
    my $cells = $g->{cell}{$r} or return;
    for my $key (keys %$cells) {
        my $w = $cells->{$key} or next;
        next unless eval { Tk::Exists($w) };
        my $bg = $on ? $C{hover} : row_base_bg($g, $r, $key);
        eval { $w->configure(-background => $bg) };
    }
}

# pointer_in_row -- true when the pointer's y is still inside this row.
# Moving from one cell to the next in the same row must not flash the stripe
# back on between the Leave and the Enter.
sub pointer_in_row {
    my ($g, $r) = @_;
    return 0 unless $g && defined $r;
    my $num = $g->{rownum}{$r} or return 0;
    return 0 unless eval { Tk::Exists($num) };
    my $y = eval { $g->{frame}->pointery };
    return 0 unless defined $y;
    my $y0 = eval { $num->rooty } // return 0;
    my $h = eval { $num->height } || 0;
    return $h && $y >= $y0 && $y < $y0 + $h;
}

# row_menu_open -- a list on this row is posted, so the pointer has left the
# cell for the menu and the row should stay shaded.
sub row_menu_open {
    my ($g, $r) = @_;
    for my $c (values %{ $g->{cell}{$r} || {} }) {
        my $menu = eval { $c->cget('-menu') };
        return 1 if $menu && eval { $menu->ismapped };
    }
    return 0;
}

sub clear_row_hover {
    my ($g, $r) = @_;
    return if $g->{building} || $g->{drag};
    return if pointer_in_row($g, $r) || row_menu_open($g, $r);
    paint_row($g, $r, 0);
    $g->{hover} = undef if defined $g->{hover} && $g->{hover} == $r;
}

# bind_row_hover -- shade the row under the pointer.  Leave waits until the
# pointer has actually gone, so crossing a cell border inside the row does
# not flicker.
sub bind_row_hover {
    my ($w, $g, $r) = @_;
    $w->bind('<Enter>' => sub {
        return if $g->{drag} || $g->{building};
        if (defined $g->{hover} && $g->{hover} != $r) {
            paint_row($g, $g->{hover}, 0);
        }
        $g->{hover} = $r;
        paint_row($g, $r, 1);
    });
    $w->bind('<Leave>' => sub {
        return if $g->{drag} || $g->{building};
        my $row = $r;
        $mw->afterIdle(sub { clear_row_hover($g, $row) });
    });
}

# make_cell -- one cell.  A row number's row is $r.  Read-only cells are the
# node number and, on a device, the node it was taken from: those come from
# somewhere else and are not typed over.  A list (node type, pipe type, and
# a diameter the database knows sizes for) is an entry that completes as it
# is typed: the first match is filled in, the rest of the matches stay
# listed, and Tab moves through them.  Anything else is typed.
sub make_cell {
    my ($g, $r, $col, $bg) = @_;
    my $id = $g->{id};
    my $val = cell_get($id, $r, $col->{key});
    my @choices = lookup_choices($id, $r, $col);
    if (@choices) {
        my $fg = $col->{kind} eq 'diam' ? $C{number} : $C{ink};
        my $e = $g->{frame}->Entry(-font => $MONO, -width => $col->{width}, -relief => 'flat',
            -borderwidth => 0, -highlightthickness => 1, -highlightbackground => $C{line},
            -highlightcolor => $C{accent}, -background => $bg, -foreground => $fg,
            -insertbackground => $C{ink}, -selectbackground => $C{select}, -selectforeground => $C{ink},
            -takefocus => 1);
        $e->insert(0, $val);
        $e->{phcp_choices} = \@choices;
        $e->{phcp_id} = $id;
        $e->{phcp_r} = $r;
        $e->{phcp_key} = $col->{key};
        $e->{phcp_kind} = $col->{kind};
        $e->{phcp_menu} = lookup_menu_for($e, $id, $r, $col, \@choices);
        $e->{phcp_pop}  = lookup_menu_for($e, $id, $r, $col, []);
        $e->bind('<KeyRelease>' => sub {
            return if $g->{building} || $e->{phcp_busy};
            my $ks = eval { $e->XEvent->K } // '';
            return if $ks =~ /^(?:Tab|ISO_Left_Tab|Return|KP_Enter|Up|Down|Left|Right|Escape|Prior|Next|Home|End)$/;
            lookup_type($e);
        });
        # Backspace over a suggested tail deletes the last character the user
        # typed, not only the suggestion, then completion runs again.
        $e->bind('<BackSpace>' => sub {
            return unless completion_selected($e);
            my $prefix = typed_prefix($e);
            my $np = length($prefix) ? substr($prefix, 0, -1) : '';
            $e->{phcp_busy} = 1;
            $e->delete(0, 'end');
            $e->insert(0, $np);
            $e->{phcp_busy} = 0;
            Tk->break;
        });
        $e->bind('<Escape>' => sub {
            my $orig = $e->{phcp_orig};
            $orig = '' if !defined $orig;
            $e->{phcp_busy} = 1;
            $e->delete(0, 'end');
            $e->insert(0, $orig);
            $e->icursor('end');
            $e->selectionClear if eval { $e->selectionPresent };
            $e->{phcp_busy} = 0;
            commit_value($id, $r, $col->{key}, $orig, 1);
            lookup_unpost($e);
            Tk->break;
        });
        $e->bind('<Right>' => sub {
            return unless completion_selected($e);
            $e->selectionClear;
            $e->icursor('end');
            lookup_unpost($e);
            Tk->break;
        });
        $e->bind('<Alt-Down>' => sub { lookup_post($e, $e->{phcp_menu}); Tk->break });
        $e->bind('<FocusOut>' => sub {
            my $grid_id = $g->{id};
            $mw->afterIdle(sub {
                return unless eval { Tk::Exists($e) };
                my $f = eval { $mw->focusCurrent };
                return if $f && $f eq $e;
                # The match list takes the pointer, not this edit.  Painting
                # waits until the list has gone and the cursor has left.
                return if $e->{phcp_open} && eval { $e->{phcp_open}->ismapped };
                lookup_unpost($e);
                lookup_maybe_finish($e);
                grow_if_needed($grid_id);
            });
        });
        bind_sheet_cell($e, $g, $r, $col);
        # FocusIn was bound for the hint.  A list cell also remembers the
        # value to restore on Escape, and says how completion works.
        $e->bind('<FocusIn>' => sub {
            show_hint($col->{hint} . '  TYPE TO COMPLETE. TAB MOVES THROUGH THE MATCHES. ALT+DOWN, OR THE RIGHT EDGE, OPENS THE LIST.');
            $e->{phcp_orig} = cell_get($id, $r, $col->{key});
        });
        bind_row_hover($e, $g, $r);
        return $e;
    }
    if ($col->{ro}) {
        $g->{ro}{$r}{ $col->{key} } = 1;
        my $l = $g->{frame}->Label(-text => $val, -font => $MONO, -background => $C{panel},
                                  -foreground => $C{ink}, -anchor => 'w', -width => $col->{width},
                                  -padx => px(6), -pady => px(3), -highlightthickness => 1,
                                  -highlightbackground => $C{line});
        bind_row_hover($l, $g, $r);
        return $l;
    }
    my $e = $g->{frame}->Entry(-font => $MONO, -width => $col->{width}, -relief => 'flat',
        -borderwidth => 0, -highlightthickness => 1, -highlightbackground => $C{line},
        -highlightcolor => $C{accent}, -background => $bg, -foreground => $C{number},
        -insertbackground => $C{ink}, -selectbackground => $C{select}, -selectforeground => $C{ink},
        -takefocus => 1);
    $e->insert(0, $val);
    # A rebuild destroys this entry.  Its KeyRelease must not write the empty
    # string back over the value the model already has.
    $e->bind('<KeyRelease>' => sub {
        return if $g->{building};
        commit_value($id, $r, $col->{key}, $e->get);
    });
    $e->bind('<FocusOut>' => sub { grow_if_needed($id) });
    bind_sheet_cell($e, $g, $r, $col);
    bind_row_hover($e, $g, $r);
    return $e;
}

# lookup_choices -- the menu for a list cell, each entry [value, label].
# An empty return is a cell that is typed, not chosen.  PIPE DIAM is a list
# only when the row's type (its own, or the one it inherits) has nominal
# sizes.  A value already in the cell that is not on the list is offered
# too, so opening a file does not hide what it said.
sub lookup_choices {
    my ($id, $r, $col) = @_;
    my $kind = $col->{kind} // '';
    return () if $kind eq '';
    my @ch;
    if ($kind eq 'type') {
        @ch = @HardyCross::Sheet::TYPE_CHOICES;
    } elsif ($kind eq 'pipetype') {
        @ch = map { [ $_, $_ ] } HardyCross::Sheet::pipe_type_choices();
    } elsif ($kind eq 'diam') {
        my $type = HardyCross::Sheet::effective_type($sheet, $r);
        my @sz = HardyCross::Sheet::diam_choices($sheet, $type);
        return () unless @sz;
        @ch = map { [ $_, $_ eq '0' ? '0   (SIZE THE PIPE)' : $_ ] } @sz;
    } else {
        return ();
    }
    my $cur = cell_get($id, $r, $col->{key});
    if (length $cur && !grep { choice_is($_->[0], $cur) } @ch) {
        unshift @ch, [ $cur, $cur ];
    }
    return @ch;
}

# choice_display -- what the cell shows for a choice.  A blank node is the
# words "A NODE" while it is being completed, and empty once it is kept.
# A size of 0 is shown as 0; the menu's "(SIZE THE PIPE)" stays in the list.
sub choice_display {
    my $ch = shift;
    return $ch->[1] if !length($ch->[0] // '');
    return $ch->[0];
}

# choice_hits -- the choices whose text starts with what has been typed.
# Matching ignores case.  A blank node matches its menu words.  A size
# matches its number, not the note beside 0.
sub choice_hits {
    my ($prefix, $choices) = @_;
    return () if !defined $prefix || $prefix eq '' || !$choices;
    my $p = uc $prefix;
    my @hit;
    for my $ch (@$choices) {
        my $disp = uc(choice_display($ch));
        my $val = uc($ch->[0] // '');
        if (!length($ch->[0] // '')) {
            push @hit, $ch if $disp =~ /^\Q$p/;
        } else {
            push @hit, $ch if $val =~ /^\Q$p/ || $disp =~ /^\Q$p/;
        }
    }
    return @hit;
}

# typed_prefix -- the characters the user has typed.  A suggested tail is
# selected through to the end of the cell, and is not part of the prefix.
sub typed_prefix {
    my $e = shift;
    my $text = $e->get;
    return $text unless completion_selected($e);
    return substr($text, 0, $e->index('sel.first'));
}
sub completion_selected {
    my $e = shift or return 0;
    return 0 unless eval { $e->selectionPresent };
    my $text = eval { $e->get };
    return 0 unless defined $text;
    my $b = eval { $e->index('sel.last') };
    my $a = eval { $e->index('sel.first') };
    return defined $a && defined $b && $b == length($text) && $a < $b;
}

# lookup_menu_for -- a flat menu of choices.  Picking one writes that value.
# An empty choice list is the menu filled in later with the matches so far.
sub lookup_menu_for {
    my ($e, $id, $r, $col, $choices) = @_;
    my $m = $e->Menu(-tearoff => 0, -font => $MONO, -relief => 'flat', -borderwidth => 1,
        -activeborderwidth => 0, -background => $C{paper}, -foreground => $C{ink},
        -activebackground => $C{select}, -activeforeground => $C{ink});
    lookup_fill_menu($m, $e, $id, $r, $col, $choices) if $choices && @$choices;
    $m->bind('<Unmap>' => sub {
        my $g = $grids{$id};
        $mw->afterIdle(sub {
            clear_row_hover($g, $r) if $g;
            lookup_maybe_finish($e) if eval { Tk::Exists($e) };
        });
    });
    return $m;
}
sub lookup_fill_menu {
    my ($m, $e, $id, $r, $col, $choices) = @_;
    my $end = eval { $m->index('end') };
    $m->delete(0, 'end') if defined $end && $end ne 'none';
    eval { $m->unpost };
    for my $ch (@$choices) {
        my ($value, $label) = @$ch;
        $m->command(-label => $label, -command => sub {
            return unless eval { Tk::Exists($e) };
            $e->{phcp_busy} = 1;
            $e->delete(0, 'end');
            $e->insert(0, length($value) ? $value : '');
            $e->icursor('end');
            $e->selectionClear if eval { $e->selectionPresent };
            $e->{phcp_busy} = 0;
            # A picked row is the whole value, so the grids that depend on
            # it are painted.  Typing, by contrast, waits until the cell is
            # left, so the entry is not rebuilt under the cursor.
            commit_value($id, $r, $col->{key}, $value);
            lookup_unpost($e);
        });
    }
}

# lookup_type -- after a key, fill the first match and list the others.
# The suggested tail is selected, so the next character replaces it.
sub lookup_type {
    my $e = shift or return;
    return unless $e->{phcp_choices};
    my $prefix = typed_prefix($e);
    if (!length($prefix // '')) {
        lookup_unpost($e);
        commit_value($e->{phcp_id}, $e->{phcp_r}, $e->{phcp_key}, '', 1);
        return;
    }
    my @hit = choice_hits($prefix, $e->{phcp_choices});
    if (!@hit) {
        lookup_unpost($e);
        commit_value($e->{phcp_id}, $e->{phcp_r}, $e->{phcp_key}, $e->get, 1);
        return;
    }
    my $i = 0;
    for (0 .. $#hit) {
        my $disp = choice_display($hit[$_]);
        if (uc($disp) eq uc($prefix) || (length($hit[$_][0]) && uc($hit[$_][0]) eq uc($prefix))) {
            $i = $_;
            last;
        }
    }
    apply_completion($e, $prefix, choice_display($hit[$i]));
    commit_value($e->{phcp_id}, $e->{phcp_r}, $e->{phcp_key}, $hit[$i][0], 1);
    if (@hit > 1) {
        lookup_fill_menu($e->{phcp_pop}, $e, $e->{phcp_id}, $e->{phcp_r},
            { key => $e->{phcp_key} }, \@hit);
        lookup_post($e, $e->{phcp_pop}, $i);
    } else {
        lookup_unpost($e);
    }
}

# apply_completion -- show $display, with the characters after the prefix
# selected.  phcp_busy stops this rewrite from being read as another key.
sub apply_completion {
    my ($e, $prefix, $display) = @_;
    $e->{phcp_busy} = 1;
    $e->delete(0, 'end');
    $e->insert(0, $display);
    my $n = length($prefix // '');
    if ($n < length($display) && uc(substr($display, 0, $n)) eq uc($prefix)) {
        $e->selectionRange($n, 'end');
        $e->icursor($n);
    } else {
        $e->selectionClear if eval { $e->selectionPresent };
        $e->icursor('end');
    }
    $e->{phcp_busy} = 0;
}

sub lookup_post {
    my ($e, $m, $active) = @_;
    return unless $e && $m && eval { Tk::Exists($e) && Tk::Exists($m) };
    lookup_unpost($e);
    my $x = $e->rootx;
    my $y = $e->rooty + ($e->height || 0);
    $m->post($x, $y);
    $m->activate($active) if defined $active && $active >= 0;
    $e->{phcp_open} = $m;
}
sub lookup_unpost {
    my $e = shift or return;
    for my $m ($e->{phcp_pop}, $e->{phcp_menu}, $e->{phcp_open}) {
        eval { $m->unpost } if $m;
    }
    $e->{phcp_open} = undef;
}

# lookup_shown_value -- the stored value for whatever the cell is showing.
# "A NODE" is stored as a blank.  Text that matches nothing is kept as typed.
sub lookup_shown_value {
    my $e = shift;
    my $shown = eval { $e->get } // '';
    for my $ch (@{ $e->{phcp_choices} || [] }) {
        return $ch->[0] if choice_display($ch) eq $shown || (length($ch->[0]) && choice_is($ch->[0], $shown));
    }
    return $shown;
}

# lookup_accept -- keep the match on show and close the list.  The tail is
# no longer selected, so the next Tab leaves the cell.
sub lookup_accept {
    my $e = shift or return;
    return unless $e->{phcp_choices} && eval { Tk::Exists($e) };
    if (eval { $e->selectionPresent }) {
        $e->selectionClear;
        $e->icursor('end');
    }
    commit_value($e->{phcp_id}, $e->{phcp_r}, $e->{phcp_key}, lookup_shown_value($e), 1);
    lookup_unpost($e);
}

# lookup_cycle -- Tab through the matches for the current prefix.  One match
# is not cycled: Tab then leaves the cell, as it does everywhere else.
sub lookup_cycle {
    my ($e, $dir) = @_;
    return 0 unless $e && $e->{phcp_choices} && completion_selected($e);
    my @hit = choice_hits(typed_prefix($e), $e->{phcp_choices});
    return 0 unless @hit > 1;
    my $shown = $e->get;
    my $i = 0;
    for (0 .. $#hit) {
        if (choice_display($hit[$_]) eq $shown || (length($hit[$_][0]) && choice_is($hit[$_][0], $shown))) {
            $i = $_;
            last;
        }
    }
    $i = ($i + $dir) % @hit;
    my $prefix = typed_prefix($e);
    apply_completion($e, $prefix, choice_display($hit[$i]));
    commit_value($e->{phcp_id}, $e->{phcp_r}, $e->{phcp_key}, $hit[$i][0], 1);
    lookup_fill_menu($e->{phcp_pop}, $e, $e->{phcp_id}, $e->{phcp_r}, { key => $e->{phcp_key} }, \@hit);
    lookup_post($e, $e->{phcp_pop}, $i);
    return 1;
}

# lookup_tab -- Tab in a list cell.  Several matches: move to the next one
# and stay.  One match, or the suggestion already accepted: leave the cell.
# A pipe type or a node type can change other cells, so that paint waits
# until this binding has returned, and the move happens after it.
sub lookup_tab {
    my ($w, $g, $r, $col, $dir) = @_;
    return 0 unless $w && $w->{phcp_choices};
    return 1 if lookup_cycle($w, $dir);
    lookup_accept($w);
    my $kind = $col->{kind} // '';
    if ($kind eq 'pipetype' || $kind eq 'type') {
        my ($grid, $row, $key, $d) = ($g, $r, $col->{key}, $dir);
        $mw->afterIdle(sub {
            lookup_finish($grid->{id}, $row, $key);
            move_focus($grid, $row, $key, 0, $d);
        });
        return 1;
    }
    return 0;
}

# lookup_step -- Up and Down walk the open match list.  With the list
# closed they move to the next row, as on the rest of the sheet.
sub lookup_step {
    my ($e, $dir) = @_;
    return 0 unless $e && $e->{phcp_open} && eval { $e->{phcp_open}->ismapped };
    return lookup_cycle($e, $dir);
}

# lookup_maybe_finish -- paint a finished type once the cursor has left the
# cell and its list is closed.  Closing the list to redraw the matches does
# not count: the cursor is still in the cell, or the list is open again.
sub lookup_maybe_finish {
    my $e = shift or return;
    return unless $e->{phcp_kind} && $e->{phcp_kind} =~ /^(?:pipetype|type)\z/;
    my $f = eval { $mw->focusCurrent };
    return if eval { Tk::Exists($e) } && $f && $f eq $e;
    return if $e->{phcp_open} && eval { $e->{phcp_open}->ismapped };
    lookup_finish($e->{phcp_id}, $e->{phcp_r}, $e->{phcp_key});
}

# lookup_finish -- paint what a pipe type or a node type changes.  Not done
# on each letter, or the entry would be destroyed while it was being typed.
sub lookup_finish {
    my ($id, $r, $key) = @_;
    return if $restoring;
    if ($id eq 'NODES' && $key eq 'type') {
        HardyCross::Sheet::reconcile($sheet);
        refresh_grid('NODES');
        refresh_others('NODES');
    } elsif ($id eq 'SYSTEM' && $key eq 'type') {
        refresh_grid('SYSTEM');
    }
}

# choice_is -- the cell already says this choice.  100 and 100.0 are the
# same size, so the list does not offer both.
sub choice_is {
    my ($a, $b) = @_;
    return 1 if defined $a && defined $b && $a eq $b;
    return 0 if !defined $a || !defined $b || $a eq '' || $b eq '';
    return 0 if $a !~ /^[-+]?(?:\d+\.?\d*|\.\d+)\z/ || $b !~ /^[-+]?(?:\d+\.?\d*|\.\d+)\z/;
    return $a == $b;
}

# bind_sheet_cell -- keys and the fill corner, on an entry and on a list.
# Tab and Return move as on a sheet.  The bottom-right corner of the cell is
# the fill handle: drag it across rows and those rows take this cell's value.
# A click anywhere else is the cell's own (the cursor, or the menu).
sub bind_sheet_cell {
    my ($w, $g, $r, $col) = @_;
    my $id = $g->{id};
    my $hint = $col->{hint} . '  DRAG THE BOTTOM-RIGHT CORNER DOWN TO COPY THIS CELL.';
    $w->bind('<FocusIn>'   => sub { show_hint($hint) });
    $w->bind('<Tab>' => sub {
        if (lookup_tab($w, $g, $r, $col, 1)) { Tk->break; return }
        move_focus($g, $r, $col->{key}, 0, 1);
        Tk->break;
    });
    $w->bind('<Shift-Tab>' => sub {
        if (lookup_tab($w, $g, $r, $col, -1)) { Tk->break; return }
        move_focus($g, $r, $col->{key}, 0, -1);
        Tk->break;
    });
    # Enter may add a row, which rebuilds this grid and frees the cell the
    # key went to.  That waits until the binding has returned.  A list cell
    # accepts its match first, and a type is painted before the move.
    $w->bind('<Return>' => sub {
        lookup_accept($w) if $w->{phcp_choices};
        my ($grid, $row, $colkey, $kind) = ($g, $r, $col->{key}, $col->{kind});
        $mw->afterIdle(sub {
            lookup_finish($grid->{id}, $row, $colkey) if $kind && $kind =~ /^(?:pipetype|type)\z/;
            enter_down($grid, $row, $colkey);
        });
        Tk->break;
    });
    $w->bind('<Down>' => sub {
        if (lookup_step($w, 1)) { Tk->break; return }
        lookup_unpost($w) if $w->{phcp_choices};
        move_focus($g, $r, $col->{key}, 1, 0);
        Tk->break;
    });
    $w->bind('<Up>' => sub {
        if (lookup_step($w, -1)) { Tk->break; return }
        lookup_unpost($w) if $w->{phcp_choices};
        move_focus($g, $r, $col->{key}, -1, 0);
        Tk->break;
    });
    $w->bind('<Control-z>' => sub { edit_undo(); Tk->break });
    $w->bind('<Control-y>' => sub { edit_redo(); Tk->break });
    # These rebuild the grid, which destroys this cell.  That has to wait
    # until the key binding has returned, or Tk is left in the cell it freed.
    $w->bind('<Control-d>' => sub { $mw->afterIdle(\&edit_fill_down); Tk->break });
    $w->bind('<Control-f>' => sub { open_find(0); Tk->break });
    $w->bind('<Control-h>' => sub { open_find(1); Tk->break });
    $w->bind('<Control-Insert>' => sub { $mw->afterIdle(\&edit_insert_row); Tk->break });
    $w->bind('<Control-Delete>' => sub { $mw->afterIdle(\&edit_delete_row); Tk->break });
    $w->bind('<Motion>' => sub {
        return if $g->{drag};
        my $e = $w->XEvent or return;
        my $corner = in_fill_corner($w, $e->x, $e->y);
        my $edge = in_menu_edge($w, $e->x, $e->y);
        my $idle = $w->isa('Tk::Entry') ? 'xterm' : 'hand2';
        $w->configure(-cursor => $corner ? 'crosshair' : $edge ? 'hand2' : $idle);
    });
    $w->bind('<ButtonPress-1>' => sub {
        my $e = $w->XEvent or return;
        if (in_menu_edge($w, $e->x, $e->y)) {
            lookup_post($w, $w->{phcp_menu});
            Tk->break;
            return;
        }
        return unless in_fill_corner($w, $e->x, $e->y);
        $g->{drag} = { key => $col->{key}, row => $r, over => $r, saved => [] };
        $w->grab;
        Tk->break;
    });
    $w->bind('<B1-Motion>' => sub {
        my $d = $g->{drag} or return;
        my $y = $w->pointery;
        my (undef, $n) = grid_spec($id);
        my $over = $d->{row};
        for my $rr (0 .. $n - 1) {
            my $c = $g->{cell}{$rr}{ $col->{key} } or next;
            my $y0 = $c->rooty;
            if ($y < $y0) { $over = $rr; last }
            $over = $rr;
        }
        if ($over != $d->{over}) {
            $d->{over} = $over;
            paint_fill($g);
        }
        Tk->break;
    });
    $w->bind('<ButtonRelease-1>' => sub {
        my $d = $g->{drag} or return;
        $g->{drag} = undef;
        eval { $w->grabRelease };
        restore_fill($d);
        my @fill = ($id, $d->{row}, $d->{over}, $d->{key});
        # Same as a key that rebuilds the grid: the cell under the pointer
        # is still this binding's widget, so the copy waits a turn.
        $mw->afterIdle(sub { fill_range(@fill) }) if $fill[1] != $fill[2];
        Tk->break;
    });
}

# in_fill_corner -- true when the pointer is in the cell's bottom-right
# corner, the fill handle.  A cell that has not been drawn yet has no size.
# in_menu_edge -- the right edge of a list cell opens the whole list.
# The bottom-right corner stays the fill handle, so the two do not overlap.
sub in_menu_edge {
    my ($w, $x, $y) = @_;
    return 0 unless $w && $w->{phcp_menu};
    return 0 if in_fill_corner($w, $x, $y);
    my $wd = $w->width || 0;
    return $wd && $x >= $wd - px(18);
}

sub in_fill_corner {
    my ($w, $x, $y) = @_;
    my $wd = $w->width || 0;
    my $ht = $w->height || 0;
    return $wd && $ht && $x >= $wd - px(10) && $y >= $ht - px(10);
}

# paint_fill / restore_fill -- the rows the fill will cover, outlined while
# the corner is dragged.  The outline they had (including a fault's red) is
# put back when the drag moves on or ends.
sub paint_fill {
    my $g = shift;
    my $d = $g->{drag} or return;
    restore_fill($d);
    my $lo = $d->{row} < $d->{over} ? $d->{row} : $d->{over};
    my $hi = $d->{row} > $d->{over} ? $d->{row} : $d->{over};
    for my $r ($lo .. $hi) {
        my $c = $g->{cell}{$r}{ $d->{key} } or next;
        my $old = eval { $c->cget('-highlightbackground') };
        push @{ $d->{saved} }, [ $c, $old ];
        $c->configure(-highlightbackground => $C{accent}, -highlightthickness => 2);
    }
}
sub restore_fill {
    my $d = shift or return;
    for my $s (@{ $d->{saved} || [] }) {
        my ($c, $old) = @$s;
        $c->configure(-highlightbackground => $old, -highlightthickness => 1) if eval { Tk::Exists($c) };
    }
    $d->{saved} = [];
}

# cell_get / cell_set -- the text in one cell, from the model.  Curve points
# are q1, p1, l1 and so on; they live in the pair list two to a point.
sub cell_get {
    my ($id, $r, $key) = @_;
    if ($id eq 'SYSTEM') {
        my $p = $sheet->{pipes}[$r] or return '';
        return $p->{$key} // '';
    }
    if ($id eq 'NODES') {
        my $nid = (HardyCross::Sheet::node_rows($sheet))[$r];
        return '' unless defined $nid;
        return $nid if $key eq 'node';
        my $t = $sheet->{nodes}{$nid}{type} // '';
        return '' if $key eq 'type' && !length HardyCross::Sheet::normal_type($t);
        return $sheet->{nodes}{$nid}{$key} // '';
    }
    if ($id eq 'SUPPLIES') {
        my $nid = (HardyCross::Sheet::supply_rows($sheet))[$r];
        return '' unless defined $nid;
        return $nid if $key eq 'node';
        my $n = $sheet->{nodes}{$nid};
        return pair_get($n->{pairs}, $key) if $key =~ /^[qp]\d+\z/;
        return $n->{$key} // '';
    }
    if ($id =~ /^DEV:(.+)/) {
        my $d = (HardyCross::Sheet::device_rows($sheet, $1))[$r] or return '';
        return $d->{node} // '' if $key eq 'node';
        return $d->{duty_p} // '' if $key eq 'duty_p';
        return pair_get($d->{pairs}, $key) if $key =~ /^[qpl]\d+\z/;
        return $d->{$key} // '';
    }
    return '';
}

sub pair_index {
    my $key = shift;
    return unless $key =~ /^([qpl])(\d+)\z/;
    return ($2 - 1) * 2 + ($1 eq 'q' ? 0 : 1);
}
sub pair_get {
    my ($pairs, $key) = @_;
    my $i = pair_index($key);
    return '' unless defined $i;
    return $pairs->[$i] // '';
}
sub pair_put {
    my ($pairs, $key, $val) = @_;
    my $i = pair_index($key);
    return unless defined $i;
    $pairs->[$i] = $val;
    pop @$pairs while @$pairs && !length HardyCross::Sheet::trim($pairs->[-1] // '');
}

# commit_value -- the cell has a new value.  Remember the grids first, so
# undo returns to what was there before this key.  A FROM NODE, TO NODE or
# NODE TYPE change rebuilds the grids that are filled from it.
sub commit_value {
    my ($id, $r, $key, $val, $quiet) = @_;
    return if $restoring;
    my $old = cell_get($id, $r, $key);
    return if $val eq $old;
    remember();
    cell_set($id, $r, $key, $val);
    # Quiet is a letter of a completion.  The cell stays as it is until the
    # edit is finished; painting now would destroy it.
    if (!$quiet) {
        if ($id eq 'SYSTEM' && $key =~ /^(from|to)\z/) {
            HardyCross::Sheet::reconcile($sheet);
            refresh_others('SYSTEM');
        } elsif ($id eq 'NODES' && $key eq 'type') {
            HardyCross::Sheet::reconcile($sheet);
            # The same rows, so this writes the chosen type into the cell and
            # does not rebuild it.  The device tables are the ones rebuilt.
            refresh_grid('NODES');
            refresh_others('NODES');
        } elsif ($id eq 'SYSTEM' && $key eq 'type') {
            # The list's command is still running.  Rebuilding the grid now
            # would destroy that menu under the callback, so it is painted
            # once the callback has returned.  The diameter cell may change
            # from a list to a typed bore, or the other way.
            $mw->afterIdle(sub { refresh_grid('SYSTEM') }) if $mw;
        }
    }
    sheet_changed();
}

sub cell_set {
    my ($id, $r, $key, $val) = @_;
    $val = HardyCross::Sheet::trim($val);
    if ($id eq 'SYSTEM') {
        $sheet->{pipes}[$_] //= HardyCross::Sheet::empty_pipe() for 0 .. $r;
        $sheet->{pipes}[$r]{$key} = $val;
        return;
    }
    if ($id eq 'NODES') {
        my $nid = (HardyCross::Sheet::node_rows($sheet))[$r] or return;
        $sheet->{nodes}{$nid}{$key} = $key eq 'type' ? HardyCross::Sheet::normal_type($val) : $val;
        return;
    }
    if ($id eq 'SUPPLIES') {
        my $nid = (HardyCross::Sheet::supply_rows($sheet))[$r] or return;
        my $n = $sheet->{nodes}{$nid};
        if ($key =~ /^[qp]\d+\z/) { pair_put($n->{pairs}, $key, $val) }
        else { $n->{$key} = $val }
        return;
    }
    if ($id =~ /^DEV:(.+)/) {
        my $d = (HardyCross::Sheet::device_rows($sheet, $1))[$r] or return;
        if ($key eq 'duty_p') { $d->{duty_p} = $val }
        elsif ($key =~ /^[qpl]\d+\z/) { pair_put($d->{pairs}, $key, $val) }
        else { $d->{$key} = $val }
    }
}

# grow_if_needed -- leaving a cell on the last blank SYSTEM row, or filling
# the last curve point, adds the next row or the next pair.  Done on the way
# out so the cell being typed in is not destroyed under the cursor.
sub grow_if_needed {
    my $id = shift;
    my $g = $grids{$id} or return;
    my $sig = grid_signature($id);
    return if $g->{sig} && $g->{sig} eq $sig;
    refresh_grid($id);
}

# enter_down -- Return.  On any row but the last, move down the same column.
# On the last SYSTEM row, add one more row and go to its first cell, the
# pipe number.  Nodes, supplies and devices are filled from the pipes, so
# Return there does not invent a row of their own.
sub enter_down {
    my ($g, $r, $key) = @_;
    return unless $g;
    my (undef, $n) = grid_spec($g->{id});
    if ($g->{id} eq 'SYSTEM' && defined $n && $r == $n - 1) {
        $system_pad++;
        refresh_grid('SYSTEM');
        my (undef, $n2) = grid_spec('SYSTEM');
        my $nr = $n2 - 1;
        my $w = $g->{cell}{$nr}{pipe};
        if ($w && eval { Tk::Exists($w) }) {
            $w->focusForce;
            reveal_row($g, $nr);
        }
        return;
    }
    move_focus($g, $r, $key, 1, 0);
}

# reveal_row -- scroll so this row is inside the grid.  A row Enter has just
# added sits under the one that was at the bottom.
sub reveal_row {
    my ($g, $r) = @_;
    my $num = $g->{rownum}{$r} or return;
    return unless eval { Tk::Exists($num) };
    $mw->idletasks if $mw;
    my $y = eval { $num->y };
    return unless defined $y;
    my $h = $num->height || px(24);
    my $vh = $g->{clip}->height || 1;
    if ($y < $g->{oy}) {
        $g->{oy} = $y;
    } elsif ($y + $h > $g->{oy} + $vh) {
        $g->{oy} = $y + $h - $vh;
        $g->{oy} = 0 if $g->{oy} < 0;
    }
    grid_place($g);
}

# move_focus -- Tab and Return, as on a sheet: Tab across, Return down.
sub move_focus {
    my ($g, $r, $key, $dr, $dc) = @_;
    my ($cols) = grid_spec($g->{id});
    my @keys = map { $_->{key} } grep { !$_->{ro} } @$cols;
    my ($i) = grep { $keys[$_] eq $key } 0 .. $#keys;
    return unless defined $i;
    my ($nr, $ni) = ($r + $dr, $i + $dc);
    if ($ni >= @keys) { $ni = 0; $nr++ }
    if ($ni < 0)      { $ni = $#keys; $nr-- }
    return if $nr < 0;
    my ($c2, $n) = grid_spec($g->{id});
    if ($nr >= $n && $g->{id} eq 'SYSTEM') {
        $sheet->{pipes}[$_] //= HardyCross::Sheet::empty_pipe() for 0 .. $nr;
        refresh_grid('SYSTEM');
        ($c2, $n) = grid_spec('SYSTEM');
    }
    return if $nr >= $n || $nr < 0;
    my $w = $g->{cell}{$nr}{ $keys[$ni] } or return;
    $w->focus;
    $w->icursor('end') if $w->can('icursor');
}

sub show_hint { $hint->configure(-text => shift // '') if $hint }

#==============================================================================
# Rows, fill, find and replace.
#
# SYSTEM is the only grid a row can be inserted into or deleted from.  The
# nodes, the supplies and the devices are filled from it, so a row there is
# not a thing of its own.  Clearing a row blanks the cells that can be typed,
# on whichever grid has the focus, and leaves a node that a pipe still names.
# Filling copies one cell down the rows the corner was dragged over.  One
# snapshot covers the whole gesture, so undo puts every cell back.
#==============================================================================

# focused_cell -- the grid, the row and the column of the cell that has the
# keyboard, or nothing when focus is on a button or the find box.
sub focused_cell {
    my $w = $mw && eval { $mw->focusCurrent };
    return unless $w;
    for my $id (qw(SYSTEM NODES SUPPLIES), map { "DEV:$_" } @HardyCross::Sheet::DEVICE_TYPES) {
        my $g = $grids{$id} or next;
        for my $r (keys %{ $g->{cell} }) {
            for my $k (keys %{ $g->{cell}{$r} }) {
                my $c = $g->{cell}{$r}{$k} or next;
                return ($id, $r + 0, $k) if $c eq $w;
            }
        }
    }
    return;
}

# after_structural -- the grids that are filled from the pipes and the node
# types, painted again after a change that can add or drop a row.
sub after_structural {
    HardyCross::Sheet::reconcile($sheet);
    refresh_all();
    sheet_changed();
}

sub edit_insert_row {
    my ($id, $r) = focused_cell();
    unless (defined $id && $id eq 'SYSTEM') {
        message('INSERT A ROW ON THE SYSTEM TAB. THE OTHER TABS ARE FILLED FROM IT.');
        return;
    }
    my $n = @{ $sheet->{pipes} };
    my $at = $r > $n ? $n : $r;
    remember();
    splice @{ $sheet->{pipes} }, $at, 0, HardyCross::Sheet::empty_pipe();
    after_structural();
    my $w = $grids{SYSTEM}{cell}{$at}{pipe};
    $w->focusForce if $w;
}

sub edit_delete_row {
    my ($id, $r) = focused_cell();
    unless (defined $id && $id eq 'SYSTEM') {
        message('DELETE A ROW ON THE SYSTEM TAB. THE OTHER TABS ARE FILLED FROM IT.');
        return;
    }
    return if $r > $#{ $sheet->{pipes} };
    remember();
    splice @{ $sheet->{pipes} }, $r, 1;
    after_structural();
    my $focus = $r;
    $focus = $#{ $sheet->{pipes} } if $focus > $#{ $sheet->{pipes} };
    $focus = 0 if $focus < 0;
    my $w = $grids{SYSTEM}{cell}{$focus}{pipe};
    $w->focusForce if $w;
}

sub edit_clear_row {
    my ($id, $r) = focused_cell();
    unless (defined $id) {
        message('CLICK A ROW FIRST.');
        return;
    }
    my ($cols) = grid_spec($id);
    my @keys = map { $_->{key} } grep { !$_->{ro} } @$cols;
    return unless grep { length cell_get($id, $r, $_) } @keys;
    remember();
    cell_set($id, $r, $_, '') for @keys;
    after_structural();
}

# fill_range -- copy the cell at $src down, or up, through $dst, in one
# column.  The source cell is the one the drag started on.  On SYSTEM the
# rows in between are created if the drag went past the last pipe.
sub fill_range {
    my ($id, $src, $dst, $key) = @_;
    return if !defined $src || !defined $dst || $src == $dst;
    my ($cols, $n) = grid_spec($id);
    my ($col) = grep { $_->{key} eq $key } @$cols;
    return if !$col || $col->{ro};
    my $lo = $src < $dst ? $src : $dst;
    my $hi = $src > $dst ? $src : $dst;
    if ($id eq 'SYSTEM') {
        $sheet->{pipes}[$_] //= HardyCross::Sheet::empty_pipe() for 0 .. $hi;
    } else {
        return if $src < 0 || $src >= $n;
        $hi = $n - 1 if $hi >= $n;
        $lo = 0 if $lo < 0;
    }
    my @rows = grep { $_ != $src } $lo .. $hi;
    return unless @rows;
    my $val = cell_get($id, $src, $key);
    remember();
    cell_set($id, $_, $key, $val) for @rows;
    after_structural();
}

# edit_fill_down -- CTRL+D.  The focused cell copied into the row under it.
# A drag of the corner covers more than one row; this is the one-row step.
sub edit_fill_down {
    my ($id, $r, $key) = focused_cell();
    return unless defined $id;
    fill_range($id, $r, $r + 1, $key);
}

#------------------------------------------------------------------------------
# Find and replace, across the grid on screen or across every grid.  Read-only
# cells (the node number a pipe already named) are not searched and not
# written.  Replace all is one undo.
#------------------------------------------------------------------------------
sub current_grid_id {
    my $tab = $toptabs && $toptabs->{current};
    return 'NODES' if $tab && $tab eq 'NODES';
    return 'SUPPLIES' if $tab && $tab eq 'SUPPLIES';
    if ($tab && $tab eq 'PRESSURE DEVICES') {
        my $d = $devtabs && $devtabs->{current};
        return 'DEV:' . $d if $d;
    }
    return 'SYSTEM';
}

sub each_find_cell {
    my $code = shift;
    my @ids = $find_all
        ? (qw(SYSTEM NODES SUPPLIES), map { "DEV:$_" } @HardyCross::Sheet::DEVICE_TYPES)
        : (current_grid_id());
    for my $id (@ids) {
        my ($cols, $n) = grid_spec($id);
        for my $r (0 .. $n - 1) {
            for my $col (@$cols) {
                next if $col->{ro};
                $code->($id, $r, $col->{key});
            }
        }
    }
}

sub find_hit {
    my $text = shift // '';
    return 0 unless length $find_what;
    return index($text, $find_what) >= 0 if $find_case;
    return index(uc $text, uc $find_what) >= 0;
}

# replaced -- $text with every match of the find text swapped for the
# replacement.  The replacement is taken literally: a $ in it is a dollar.
sub replaced {
    my $text = shift // '';
    return $text unless length $find_what;
    my $with = $find_with // '';
    my $q = quotemeta($find_what);
    if ($find_case) { $text =~ s/$q/$with/ge }
    else            { $text =~ s/$q/$with/ige }
    return $text;
}

sub reveal_cell {
    my ($id, $r, $key) = @_;
    my $tab = $id =~ /^DEV:/ ? 'PRESSURE DEVICES' : $id;
    select_tab($toptabs, $tab) if $toptabs && $toptabs->{page}{$tab};
    select_tab($devtabs, $1) if $id =~ /^DEV:(.+)/ && $devtabs;
    my $w = $grids{$id} && $grids{$id}{cell}{$r}{$key} or return;
    $w->focusForce;
    if ($w->isa('Tk::Entry')) {
        my $t = $w->get;
        my $at = $find_case ? index($t, $find_what) : index(uc $t, uc $find_what);
        if ($at >= 0) { $w->selectionRange($at, $at + length $find_what) }
        else { $w->selectionRange(0, 'end') }
    }
}

sub find_next {
    return 0 unless length $find_what;
    my @cells;
    each_find_cell(sub { push @cells, [ @_ ] });
    return 0 unless @cells;
    my $start = 0;
    if (defined $find_pos) {
        for my $i (0 .. $#cells) {
            if (join("\t", @{ $cells[$i] }) eq $find_pos) { $start = $i + 1; last }
        }
    }
    for my $k (0 .. $#cells) {
        my ($id, $r, $key) = @{ $cells[ ($start + $k) % @cells ] };
        next unless find_hit(cell_get($id, $r, $key));
        $find_pos = "$id\t$r\t$key";
        reveal_cell($id, $r, $key);
        message('FOUND');
        return 1;
    }
    message('NOT FOUND');
    return 0;
}

sub replace_current {
    return find_next() unless defined $find_pos;
    my ($id, $r, $key) = split /\t/, $find_pos, 3;
    my $old = cell_get($id, $r, $key);
    unless (find_hit($old)) { return find_next() }
    my $new = replaced($old);
    if ($new ne $old) {
        remember();
        cell_set($id, $r, $key, $new);
        after_structural();
        reveal_cell($id, $r, $key);
    }
    message('REPLACED');
    return 1;
}

sub replace_all {
    return 0 unless length $find_what;
    my @jobs;
    each_find_cell(sub {
        my ($id, $r, $key) = @_;
        my $old = cell_get($id, $r, $key);
        my $new = replaced($old);
        push @jobs, [ $id, $r, $key, $new ] if $new ne $old;
    });
    unless (@jobs) { message('NOT FOUND'); return 0 }
    remember();
    cell_set(@$_) for @jobs;
    after_structural();
    my $n = @jobs;
    message("$n REPLACED");
    return $n;
}

# open_find -- the find box.  $replace selects the replacement field; FIND
# and REPLACE open the same box.  A second call raises the one already open.
sub open_find {
    my $replace = shift;
    if ($find_box && eval { Tk::Exists($find_box) }) {
        $find_box->deiconify;
        $find_box->raise;
        $find_box->focus;
        return $find_box;
    }
    my $d = $mw->Toplevel(-title => 'FIND AND REPLACE', -background => $C{paper});
    $find_box = $d;
    $d->protocol('WM_DELETE_WINDOW' => sub { $find_box = undef; $d->destroy });
    my $body = $d->Frame(-background => $C{paper})->pack(-fill => 'both', -expand => 1, -padx => px(16), -pady => px(14));
    my $row = sub {
        my ($label, $var) = @_;
        my $f = $body->Frame(-background => $C{paper})->pack(-fill => 'x', -pady => px(3));
        $f->Label(-text => $label, -font => $UI, -background => $C{paper}, -foreground => $C{muted},
                  -width => 12, -anchor => 'w')->pack(-side => 'left');
        my $e = flat_entry($f, $var, 28);
        $e->pack(-side => 'left', -fill => 'x', -expand => 1, -ipady => px(3));
        $e->bind('<KeyRelease>' => sub { $find_pos = undef });
        return $e;
    };
    my $fe = $row->('FIND', \$find_what);
    my $re = $row->('REPLACE', \$find_with);
    my $opts = $body->Frame(-background => $C{paper})->pack(-fill => 'x', -pady => px([8, 4]));
    my $case = check_box($opts, 'MATCH CASE', \$find_case, sub { $find_pos = undef });
    $case->{frame}->pack(-side => 'left', -padx => px([0, 16]));
    my $all = check_box($opts, 'ALL GRIDS', \$find_all, sub { $find_pos = undef });
    $all->{frame}->pack(-side => 'left');
    my $btns = $body->Frame(-background => $C{paper})->pack(-fill => 'x', -pady => px([10, 0]));
    flat_button($btns, 'FIND NEXT', sub { find_next() })->pack(-side => 'left', -padx => px([0, 4]));
    flat_button($btns, 'REPLACE', sub { replace_current() })->pack(-side => 'left', -padx => px(4));
    flat_button($btns, 'REPLACE ALL', sub { replace_all() }, primary => 1)->pack(-side => 'left', -padx => px(4));
    flat_button($btns, 'CLOSE', sub { $find_box = undef; $d->destroy })->pack(-side => 'right');
    $fe->bind('<Return>' => sub { find_next(); Tk->break });
    $re->bind('<Return>' => sub { replace_current(); Tk->break });
    $d->bind('<Escape>' => sub { $find_box = undef; $d->destroy });
    ($replace ? $re : $fe)->focus;
    return $d;
}

#==============================================================================
# Dark mode.  The shared tabs read %C when they build a widget, and an HList
# keeps the colours in its cell styles, so both have to be painted again.
# White text on a blue button is not the paper colour: a foreground of white
# is left white, and a background of white becomes the dark paper.
#==============================================================================

# toggle_theme -- the menu and the toolbar.  The choice is written to this
# machine's settings, the same small file as the database folder, so the
# next time the sheet opens it is as it was left.  The text editor keeps
# its own key, EDITOR_THEME, and does not read this one.
sub toggle_theme {
    apply_theme($theme eq 'dark' ? 'light' : 'dark');
    eval { HardyCross::Settings::set('SHEET_THEME', uc $theme) };
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
    for my $draw (@theme_draws) { eval { $draw->() } }
    eval { graph_draw() } if $gv{canvas};
    eval { fill_results() } if $restabs;
    restyle_validation();
    eval { db_header() } if $dbv{path};
    eval { db_fill() } if $dbv{tabs};
    eval { db_form() } if $dbv{formrow};
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
    mark_faults() if $validation;
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
# Undo.  Each change snapshots the grids first.  The PROJECT tab is not part
# of it: that tab's fields are the settings, and undo there is the editor's
# habit of leaving them to the form.
#==============================================================================
sub snapshot {
    return Storable::dclone({
        pipes => $sheet->{pipes}, nodes => $sheet->{nodes}, devices => $sheet->{devices},
        notes => $sheet->{notes}, extras => $sheet->{extras}, seq => $sheet->{seq},
    });
}
sub remember {
    return if $restoring;
    push @undo_stack, snapshot();
    splice @undo_stack, 0, @undo_stack - 40 if @undo_stack > 40;
    @redo_stack = ();
}
sub restore_snap {
    my $s = shift or return;
    $restoring = 1;
    @{$sheet}{qw(pipes nodes devices notes extras seq)} = @{$s}{qw(pipes nodes devices notes extras seq)};
    $restoring = 0;
    refresh_all();
    sheet_changed();
}
sub edit_undo {
    return unless @undo_stack;
    push @redo_stack, snapshot();
    restore_snap(pop @undo_stack);
}
sub edit_redo {
    return unless @redo_stack;
    push @undo_stack, snapshot();
    restore_snap(pop @redo_stack);
}

#==============================================================================
# VALIDATE and CALCULATE.  Both go through HardyCross::Editor, so the sheet
# cannot call a model good that the solve would refuse, and it cannot solve
# a different way.
#==============================================================================
sub full_text { return HardyCross::Sheet::to_text($sheet) }

sub document {
    full_text();
    return { settings => $sheet->{settings}, network => $sheet->{network} };
}

# The results tab's click handler knows a text line and a PROJECT field.
# A sheet fault is a cell, so this program handles the click itself.
no warnings 'redefine';
sub go_to_fault {
    my $row = shift;
    return unless $validation && defined $row && $row =~ /^\d+\z/;
    my $it = $validation->{items}[$row] or return;
    return show_field($it->{field}) if $it->{tab} && $it->{tab} eq 'PROJECT';
    my $loc = $it->{loc} || HardyCross::Sheet::locate($sheet, $it);
    go_to_cell($loc) if $loc;
}
sub go_to_line {
    my ($line) = @_;
    return unless defined $line;
    go_to_cell($sheet->{map}{$line} || HardyCross::Sheet::locate($sheet, { line => $line }));
}
use warnings 'redefine';

sub go_to_cell {
    my $loc = shift or return;
    return show_field($loc->{field}) if ($loc->{tab} // '') eq 'PROJECT' && $loc->{field};
    my $tab = $loc->{tab} or return;
    select_tab($toptabs, $tab) if $toptabs->{page}{$tab};
    if ($tab eq 'PRESSURE DEVICES' && $loc->{device}) {
        select_tab($devtabs, $loc->{device});
        $tab = "DEV:$loc->{device}";
    }
    my $g = $grids{$tab} or return;
    my $w = $g->{cell}{ $loc->{row} }{ $loc->{col} } or return;
    # focusForce, not focus: a cell drawn in a canvas does not take the
    # ordinary focus.  can('focusForce') is false until Tk autoloads it, so
    # it is called directly.
    $w->focusForce;
    $w->configure(-highlightbackground => $C{error}) if defined eval { $w->cget('-highlightbackground') };
}

sub clear_faults {
    for my $w (@fault_marks) {
        $w->configure(-highlightbackground => $C{line}) if eval { Tk::Exists($w) };
    }
    @fault_marks = ();
}

sub mark_faults {
    clear_faults();
    return unless $validation;
    for my $it (@{ $validation->{items} }) {
        my $loc = $it->{loc} || HardyCross::Sheet::locate($sheet, $it) or next;
        my $tab = $loc->{tab} or next;
        $tab = "DEV:$loc->{device}" if $tab eq 'PRESSURE DEVICES' && $loc->{device};
        my $w = $grids{$tab} && $grids{$tab}{cell}{ $loc->{row} }{ $loc->{col} } or next;
        next unless eval { $w->cget('-highlightbackground'); 1 };
        $w->configure(-highlightbackground => $C{error}, -highlightthickness => 1);
        push @fault_marks, $w;
    }
}

sub validate {
    my $full = full_text();
    my $v = HardyCross::Editor::validate(document());
    push @{ $v->{items} }, HardyCross::Sheet::problems($sheet);
    $v->{ok} = @{ $v->{items} } ? 0 : 1;
    $validation = { %$v, text => $full };
    $valid_text = $v->{ok} ? $full : undef;
    $solved = undef if !$v->{ok};
    fill_validation();
    select_tab($restabs, 'VALIDATION') if $restabs;
    mark_faults();
    update_actions();
    my $n = @{ $v->{items} };
    message($v->{ok} ? 'VALID - NO PROBLEMS FOUND. CALCULATE (F5) IS NOW AVAILABLE'
                     : "$n PROBLEM" . ($n == 1 ? '' : 'S') . ' FOUND - SEE VALIDATION BELOW; CLICK ONE TO GO TO IT',
            !$v->{ok});
    return $v;
}

sub calculate {
    my $full = full_text();
    unless (defined $valid_text && $valid_text eq $full) {
        message('VALIDATE THE INPUTS FIRST (F4): CALCULATE RUNS ONLY ON A MODEL THAT HAS PASSED VALIDATION', 1);
        return { ok => 0, not_validated => 1 };
    }
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
    my $r = eval { HardyCross::Editor::doc_solve(document(), $path, progress => $progress) };
    my $err = $@;
    $mw->Unbusy;
    die $err unless $r;
    if (!$r->{ok}) {
        $solved = undef;
        fill_results();
        fill_report("THE MODEL WAS NOT CALCULATED\n\n$r->{error}\n");
        update_actions();
        message($r->{error}, 1);
        return $r;
    }
    # Auto sizing writes each chosen size after its pipe as a comment.  Read
    # the network back so those comments sit on the pipe rows.  Comments do
    # not change the model, so it is still the one that passed VALIDATE.
    if (defined $r->{network} && $r->{network} ne $sheet->{network}) {
        my ($text) = HardyCross::Editor::join_file($sheet->{settings}, $r->{network});
        my $got = HardyCross::Sheet::read_text($text);
        @{$sheet}{qw(pipes nodes devices notes extras seq)} = @{$got}{qw(pipes nodes devices notes extras seq)};
        refresh_all();
        $full = full_text();
        $valid_text = $full;
    }
    $solved = { net => $r->{net}, converged => $r->{converged}, text => $full };
    fill_results();
    fill_report($r->{report});
    select_tab($restabs, 'PIPES');
    update_actions();
    message($r->{converged} ? 'CALCULATED - CONVERGED'
                            : 'CALCULATED - DID NOT CONVERGE: THE RESULTS MUST NOT BE USED', !$r->{converged});
    return $r;
}

sub fill_report {
    my $text = shift;
    return unless $report;
    $report->configure(-state => 'normal');
    $report->delete('1.0', 'end');
    $report->insert('1.0', $text);
    $report->configure(-state => 'disabled');
}

# recolour / update_status / update_actions / set_title -- the names the
# PROJECT tab and the DATABASE tab call.  In the editor, recolour paints the
# command lines; here the units in the column headings are what a setting
# changes, so the grids are painted again.
sub recolour { refresh_all() }
sub update_status {
    return unless $statusbar;
    my $np = grep { !HardyCross::Sheet::pipe_is_blank($_) && length HardyCross::Sheet::trim($_->{pipe} // '') } @{ $sheet->{pipes} };
    my $nn = HardyCross::Sheet::node_rows($sheet);
    my $ns = HardyCross::Sheet::supply_rows($sheet);
    my $nd = 0;
    $nd += HardyCross::Sheet::device_rows($sheet, $_) for @HardyCross::Sheet::DEVICE_TYPES;
    $statusbar->configure(-text => sprintf('%d PIPE%s, %d NODE%s, %d SUPPL%s, %d PRESSURE DEVICE%s',
        $np, $np == 1 ? '' : 'S', $nn, $nn == 1 ? '' : 'S', $ns, $ns == 1 ? 'Y' : 'IES',
        $nd, $nd == 1 ? '' : 'S'));
}
sub sheet_changed {
    clear_faults();
    set_title();
    update_actions();
    update_status();
}
sub update_actions {
    return unless $btn{CALCULATE};
    my $full = eval { full_text() } // '';
    my $valid = defined $valid_text && $valid_text eq $full;
    $btn{CALCULATE}->configure($valid
        ? (-state => 'normal', -background => $C{accent}, -highlightbackground => $C{accent})
        : (-state => 'disabled', -background => $C{paper}, -highlightbackground => $C{line}));
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
sub set_title {
    return unless $mw;
    my $name = $path // 'UNTITLED.PHC';
    $name =~ s{.*[/\\]}{};
    my $star = '';
    $star = ' *' if $saved_text ne '' && eval { full_text() } ne $saved_text;
    $mw->title('PHCP SHEET - ' . uc($name) . $star);
}
sub message {
    my ($text, $bad) = @_;
    return unless $statusbar;
    $statusbar->configure(-text => uc($text), -foreground => $bad ? $C{error} : $C{ink});
}
sub calculate_enabled { return $btn{CALCULATE} && $btn{CALCULATE}->cget(-state) eq 'normal' }
sub state_text { return $pill ? $pill->cget(-text) : '' }

#==============================================================================
# Files.  .phc only, the one file type the engine reads.
#==============================================================================
sub modified { return full_text() ne $saved_text }

sub ok_to_discard {
    return 0 unless db_ok_to_leave();
    return 0 unless graph_ok_to_discard();
    return 1 unless modified();
    my $a = $mw->messageBox(-title => 'UNSAVED CHANGES', -icon => 'warning', -type => 'YesNo',
        -message => 'THE MODEL HAS UNSAVED CHANGES.  DISCARD THEM?');
    return lc($a) eq 'yes';
}

sub adopt {
    my $got = shift;
    load_settings($got->{settings});
    @{$sheet}{qw(pipes nodes devices notes extras seq)} = @{$got}{qw(pipes nodes devices notes extras seq)};
    @undo_stack = ();
    @redo_stack = ();
    $system_pad = $BLANKS;
    $validation = undef;
    $valid_text = undef;
    $solved = undef;
    refresh_all();
    fill_results() if $restabs;
    fill_validation() if $vtable;
    $saved_text = full_text();
    sheet_changed();
}

sub file_new {
    return unless ok_to_discard();
    $path = undef;
    adopt(HardyCross::Sheet::new_sheet());
    select_tab($toptabs, 'SYSTEM');
}

sub file_open {
    my $f = shift;
    return unless ok_to_discard();
    $f //= $mw->getOpenFile(-filetypes => [ [ 'PHCP MODEL', [ '.phc' ] ], [ 'ALL FILES', '*' ] ]);
    return unless defined $f && length $f;
    open_path($f);
}

sub open_path {
    my $f = shift;
    my $r = eval { HardyCross::Editor::load_file($f) };
    unless ($r) {
        my $e = $@;
        message(HardyCross::is_model_error($e) ? $e->{msg} : "$e", 1);
        return;
    }
    my $got = eval { HardyCross::Sheet::read_text($r->{text}) };
    unless ($got) { message("$@", 1); return }
    $path = $r->{path};
    adopt($got);
    select_tab($toptabs, 'SYSTEM');
    message("OPENED $path");
    return $r;
}

sub file_save {
    return file_save_as() unless defined $path;
    write_file($path);
}
sub file_save_as {
    my $f = shift // $mw->getSaveFile(-defaultextension => '.phc',
        -initialfile => ($path // 'UNTITLED.PHC') =~ s{.*[/\\]}{}r,
        -filetypes => [ [ 'PHCP MODEL', '.phc' ] ]);
    return unless defined $f && length $f;
    $path = $f if write_file($f);
    set_title();
}
sub write_file {
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

# grid_cell -- one cell's widget, for the window test.
sub grid_cell {
    my ($id, $r, $key) = @_;
    return $grids{$id} && $grids{$id}{cell}{$r}{$key};
}
sub grid_text {
    my $w = grid_cell(@_);
    return '' unless $w;
    return $w->get if $w->can('get') && $w->isa('Tk::Entry');
    return $w->cget('-text');
}

sub main {
    my $file = shift;
    build_window();
    open_path($file) if defined $file;
    MainLoop;
}

our $PHCP_SHEET_LOAD_ONLY;
main(@ARGV) unless $PHCP_SHEET_LOAD_ONLY;

# The wheel's target.  A little object rather than the grid frame, because
# the frame has no yview of its own: the grid is moved by place.
package PhcScroller;
sub yview {
    my ($self, $how, $n) = @_;
    return unless ($how // '') eq 'scroll';
    main::grid_wheel($self->{g}, $n);
}

1;
