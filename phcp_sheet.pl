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
#   |        | QUICK TOOLS | DATABASE                                    |
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
# PROJECT, GRAPH, QUICK TOOLS and DATABASE are the same tabs as the editor.
# They live in HardyCross/Window/ and decide nothing for themselves.  The
# decisions for the grids are HardyCross::Sheet, which has no Tk in it.
# VALIDATE and CALCULATE call HardyCross::Editor, the same checks and the
# same solve the text editor uses.
#
# Perl 5, as the rest of PHCP.  The defined-or operator needs Perl 5.10,
# which the engine already requires.  No signatures and no try/catch.
#
# The flat buttons, tabs and colours below are the editor's look, copied
# into this file so the editor itself is not opened and not edited.
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
# The shared tabs.  Each is package main, as it is for the editor, so the
# helpers below are the ones it calls.  Nothing in those files is modified.
use HardyCross::Window::Project;
use HardyCross::Window::Tools;
use HardyCross::Window::Graph;
use HardyCross::Window::Database;
use HardyCross::Window::Results;

#------------------------------------------------------------------------------
# Colours and type.  The same white, flat window as the editor: one blue,
# black text, red for a fault.
#------------------------------------------------------------------------------
our %C = (
    paper      => '#FFFFFF',
    panel      => '#F6F7F9',
    line       => '#DDE1E6',
    hover      => '#EEF1F5',
    ink        => '#111111',
    muted      => '#6B7280',
    faint      => '#A3AAB4',
    accent     => '#1F5FBF',
    accent_dk  => '#184C99',
    accent_bg  => '#E8F0FC',
    select     => '#D3E3FA',
    curline    => '#F5F8FD',
    number     => '#0B4F9C',
    error      => '#C62828',
    error_bg   => '#FDEEEE',
    fault_bg   => '#F9D4D4',
    warn       => '#8A5A00',
    proposal   => '#9AA5B4',
    sash       => '#E4E7EB',
);
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
    my %have = map { lc $_ => 1 } $main::mw->fontFamilies;
    my ($mono) = grep { $have{ lc $_ } } 'Consolas', 'DejaVu Sans Mono', 'Liberation Mono', 'Menlo', 'Courier New';
    my ($ui)   = grep { $have{ lc $_ } } 'Segoe UI', 'DejaVu Sans', 'Liberation Sans', 'Helvetica Neue', 'Arial';
    $mono //= 'Courier';
    $ui   //= 'Helvetica';
    ($MONO, $MONO_B, $MONO_I) = ([ $mono, 10 ], [ $mono, 10, 'bold' ], [ $mono, 10, 'italic' ]);
    ($UI, $UI_B, $UI_S, $UI_S_N) = ([ $ui, 9 ], [ $ui, 9, 'bold' ], [ $ui, 8, 'bold' ], [ $ui, 8 ]);
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
    return $parent->Button(-text => $text, -command => $cmd, -font => $UI_B,
        -relief => 'flat', -borderwidth => 0, -highlightthickness => 1,
        -highlightbackground => $p ? $C{accent} : $C{line}, -highlightcolor => $C{accent},
        -background => $p ? $C{accent} : $C{paper}, -foreground => $p ? '#FFFFFF' : $C{ink},
        -activebackground => $p ? $C{accent_dk} : $C{hover},
        -activeforeground => $p ? '#FFFFFF' : $C{ink},
        -disabledforeground => $C{faint}, -padx => px(14), -pady => px(5), -cursor => 'hand2');
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
        -background => '#CDD2D9', -activebackground => '#B4BBC5', -highlightthickness => 0);
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
our (%btn, %form, %checks, %table, %dbv, %pipe_show, %grids);
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
                                 'PROJECT', 'GRAPH', 'QUICK TOOLS', 'DATABASE' ],
                         sub { tools_refresh() if $_[0] eq 'QUICK TOOLS' });
    build_system($toptabs->{page}{SYSTEM});
    build_nodes($toptabs->{page}{NODES});
    build_supplies($toptabs->{page}{SUPPLIES});
    build_devices($toptabs->{page}{'PRESSURE DEVICES'});
    build_project($toptabs->{page}{PROJECT});
    build_graph($toptabs->{page}{GRAPH});
    build_tools($toptabs->{page}{'QUICK TOOLS'});
    build_database($toptabs->{page}{DATABASE});
    build_results($bottom);
    $vp->add($top, -height => px(560));
    $vp->add($bottom);
    $vp->pack(-fill => 'both', -expand => 1);

    my $foot = $mw->Frame(-background => $C{panel})->pack(-side => 'bottom', -fill => 'x');
    rule($foot, 'x', -side => 'top');
    $hint = $foot->Label(-text => '', -font => $UI, -background => $C{panel}, -foreground => $C{muted},
                         -anchor => 'w', -justify => 'left')->pack(-fill => 'x', -padx => px(12), -pady => px([4, 0]));
    $statusbar = $foot->Label(-text => '', -font => $UI_B, -background => $C{panel}, -foreground => $C{ink},
                              -anchor => 'w', -justify => 'left')->pack(-fill => 'x', -padx => px(12), -pady => px([0, 6]));

    bind_keys();
    refresh_all();
    $saved_text = full_text();
    set_title();
    update_actions();
    update_status();
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
    $edit->command(-label => 'UNDO', -accelerator => 'CTRL+Z', -command => sub { edit_undo() });
    $edit->command(-label => 'REDO', -accelerator => 'CTRL+Y', -command => sub { edit_redo() });
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
    rule($mw, 'x');
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
    $mw->protocol('WM_DELETE_WINDOW' => sub { file_quit() });
    bind_wheel();
}

# A one-line description above each grid, so the tab says where its rows
# come from.  The grids themselves scroll under it.
sub blurb {
    my ($page, $text) = @_;
    my $f = $page->Frame(-background => $C{paper})->pack(-side => 'top', -fill => 'x', -padx => px(12), -pady => px([8, 4]));
    $f->Label(-text => $text, -font => $UI, -background => $C{paper}, -foreground => $C{muted},
              -anchor => 'w', -justify => 'left')->pack(-fill => 'x');
    return $f;
}

sub build_system {
    my $page = shift;
    blurb($page, 'EACH ROW IS A PIPE.  THE NODES TAB IS FILLED FROM FROM NODE AND TO NODE, IN THE ORDER THE NUMBERS FIRST APPEAR.');
    $grids{SYSTEM} = build_grid($page, 'SYSTEM');
}
sub build_nodes {
    my $page = shift;
    blurb($page, 'FILLED FROM THE SYSTEM TAB.  A BLANK TYPE IS A NODE, AND THE WORD IS NOT WRITTEN IN THE CELL.');
    $grids{NODES} = build_grid($page, 'NODES');
}
sub build_supplies {
    my $page = shift;
    blurb($page, 'A ROW APPEARS WHEN A NODE\'S TYPE IS SUPPLY.  THE ELEVATION STAYS ON THE NODES TAB.');
    $grids{SUPPLIES} = build_grid($page, 'SUPPLIES');
}
sub build_devices {
    my $page = shift;
    blurb($page, 'A ROW APPEARS WHEN A NODE\'S TYPE IS THAT DEVICE.  A DEVICE ALREADY IN A FILE IS LISTED TOO.  EACH TABLE HAS THE COLUMNS THAT DEVICE NEEDS.');
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
    $g->{hclip} = $col->Frame(-background => $C{panel}, -height => px(26))->pack(-side => 'top', -fill => 'x');
    $g->{hclip}->packPropagate(0);
    $g->{hframe} = $g->{hclip}->Frame(-background => $C{panel});
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
    my $n = $last + 1 + $BLANKS;
    return $n < $BLANKS ? $BLANKS : $n;
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
    return join "\n", (map { $_->{key} } @$cols), '---', @id;
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
            if ($col->{kind} && $col->{kind} eq 'type') {
                $w->configure(-text => $val);
            } elsif ($col->{ro}) {
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
    my ($cols, $n) = grid_spec($id);
    my $cw = $mw->fontMeasure($MONO, '0') || 8;
    my $col_px = sub {
        my $col = shift;
        my $chars = length $col->{head};
        $chars = $col->{width} if $col->{width} > $chars;
        return $cw * $chars + px(14);
    };
    my $c = 0;
    my $head = sub {
        my ($text, $pxw) = @_;
        my $l = $g->{hframe}->Label(-text => $text, -font => $MONO_B, -background => $C{panel},
                                    -foreground => $C{muted}, -anchor => 'w', -padx => px(4), -pady => px(4));
        $l->grid(-row => 0, -column => $c, -sticky => 'ew');
        $g->{hframe}->gridColumnconfigure($c, -minsize => $pxw);
        $g->{frame}->gridColumnconfigure($c, -minsize => $pxw);
        $c++;
    };
    $head->('ROW', $cw * 5 + px(10));
    $head->($_->{head}, $col_px->($_)) for @$cols;

    for my $r (0 .. $n - 1) {
        my $bg = $r % 2 ? $C{curline} : $C{paper};
        my $num = $g->{frame}->Label(-text => $r + 1, -font => $MONO, -background => $C{panel},
                                     -foreground => $C{faint}, -anchor => 'e', -width => 4, -padx => px(4));
        $num->grid(-row => $r, -column => 0, -sticky => 'nsew');
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

# make_cell -- one cell.  A row number's row is $r.  Read-only cells are the
# node number and, on a device, the node it was taken from: those come from
# somewhere else and are not typed over.
sub make_cell {
    my ($g, $r, $col, $bg) = @_;
    my $id = $g->{id};
    my $val = cell_get($id, $r, $col->{key});
    if ($col->{kind} && $col->{kind} eq 'type') {
        my $b = $g->{frame}->Menubutton(-text => $val, -font => $MONO, -relief => 'flat',
            -borderwidth => 0, -highlightthickness => 1, -highlightbackground => $C{line},
            -background => $bg, -activebackground => $C{hover}, -foreground => $C{ink},
            -anchor => 'w', -width => $col->{width}, -padx => px(4), -pady => px(2),
            -indicatoron => 0, -cursor => 'hand2');
        my $m = $b->Menu(-tearoff => 0, -font => $MONO, -relief => 'flat', -borderwidth => 1,
            -activeborderwidth => 0, -background => $C{paper}, -foreground => $C{ink},
            -activebackground => $C{select}, -activeforeground => $C{ink});
        for my $ch (@HardyCross::Sheet::TYPE_CHOICES) {
            my ($value, $label) = @$ch;
            $m->command(-label => $label, -command => sub {
                $b->configure(-text => $value);   # blank stays blank: "a node" is not written
                commit_value($id, $r, 'type', $value);
            });
        }
        $b->configure(-menu => $m);
        $b->bind('<FocusIn>' => sub { show_hint($col->{hint}) });
        return $b;
    }
    if ($col->{ro}) {
        return $g->{frame}->Label(-text => $val, -font => $MONO, -background => $C{panel},
                                  -foreground => $C{ink}, -anchor => 'w', -width => $col->{width},
                                  -padx => px(4), -pady => px(2), -highlightthickness => 1,
                                  -highlightbackground => $C{line});
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
    $e->bind('<FocusIn>'    => sub { show_hint($col->{hint}) });
    $e->bind('<FocusOut>'   => sub { grow_if_needed($id) });
    $e->bind('<Tab>'        => sub { move_focus($g, $r, $col->{key}, 0,  1); Tk->break });
    $e->bind('<Shift-Tab>'  => sub { move_focus($g, $r, $col->{key}, 0, -1); Tk->break });
    $e->bind('<Return>'     => sub { move_focus($g, $r, $col->{key}, 1,  0); Tk->break });
    $e->bind('<Down>'       => sub { move_focus($g, $r, $col->{key}, 1,  0); Tk->break });
    $e->bind('<Up>'         => sub { move_focus($g, $r, $col->{key}, -1, 0); Tk->break });
    $e->bind('<Control-z>'  => sub { edit_undo(); Tk->break });
    $e->bind('<Control-y>'  => sub { edit_redo(); Tk->break });
    return $e;
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
    my ($id, $r, $key, $val) = @_;
    return if $restoring;
    my $old = cell_get($id, $r, $key);
    return if $val eq $old;
    remember();
    cell_set($id, $r, $key, $val);
    if ($id eq 'SYSTEM' && $key =~ /^(from|to)\z/) {
        HardyCross::Sheet::reconcile($sheet);
        refresh_others('SYSTEM');
    } elsif ($id eq 'NODES' && $key eq 'type') {
        HardyCross::Sheet::reconcile($sheet);
        refresh_others('NODES');
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

# move_focus -- Tab and Return, as on a sheet: Tab across, Return down.
sub move_focus {
    my ($g, $r, $key, $dr, $dc) = @_;
    my ($cols) = grid_spec($g->{id});
    my @keys = map { $_->{key} } grep { !$_->{ro} && (!$_->{kind} || $_->{kind} ne 'type') } @$cols;
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
