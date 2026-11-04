#!/usr/bin/perl
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# phcp_fast.pl -- fast entry for a PHCP model.
#
#   perl phcp_fast.pl [model.phc]
#
# A second window on the same .phc file the text editor uses.  phcp_editor.pl
# is not involved and is not changed.  What a row becomes is decided by
# HardyCross::FastEntry, which has no Tk in it; this file draws and takes keys.
#
#   +------------------------------------------------------------------+
#   | NEW OPEN SAVE | VALIDATE CALCULATE | WRITE REPORT     [ status ] |
#   | USE [ ASAM ] C [ 120 ]   IN FORCE ASAM 120                        |
#   | PIPES   PIPE P   PC X   CHANGEPIPE K   EQV E                      |
#   | NODES   NODE N   SPRINKLER S   ...                                |
#   | NAME [P12] START [N11] END [N12] LENGTH [3.2] SIZE [25] FIT [T]   |
#   | PIPE <NAME> <START> ...                          OK   12 LINES    |
#   |  14  PIPE      P11 ...                                            |
#   |  15  PIPE      P12 ...                                            |
#   | VALIDATION | PIPES | NODES | OUTLETS | REPORT                     |
#   +------------------------------------------------------------------+
#
# The command stays until another is chosen.  Enter adds the row.  A value
# that usually repeats is already filled in; typing replaces it.  A name
# P1-P12 or P1X12 adds the whole run.  The file is ordinary .phc.
#==============================================================================
use strict;
use warnings;
use FindBin;
use lib $FindBin::Bin;
use Tk;
use Tk::Panedwindow;
use HardyCross;
use HardyCross::Editor;
use HardyCross::FastEntry;
use HardyCross::Phc;
use HardyCross::Settings;
use File::Spec;
use Scalar::Util qw(refaddr);

# Two grounds for the same window.  Light is the editor's white.  Dark is for
# a long entry session.  The choice is FAST_DARK in the machine settings
# (HardyCross::Settings); it is not part of the model and is never written
# into the .phc file.  accent_fg is the blue used for text.  In the light
# ground it is the same blue as the buttons; in the dark ground the buttons
# stay the darker blue so white lettering on them still reads, and the text
# blue is lighter.  ghost is an offered value, quieter than ink until it is
# typed over.
our %LIGHT = (
    paper     => '#FFFFFF',
    panel     => '#F6F7F9',
    line      => '#DDE1E6',
    hover     => '#EEF1F5',
    ink       => '#111111',
    muted     => '#6B7280',
    faint     => '#A3AAB4',
    ghost     => '#5E6874',
    accent    => '#1F5FBF',
    accent_fg => '#1F5FBF',
    accent_dk => '#184C99',
    accent_bg => '#E8F0FC',
    select    => '#D3E3FA',
    error     => '#C62828',
    error_bg  => '#FDEEEE',
    warn      => '#8A5A00',
    sash      => '#E4E7EB',
    on_accent => '#FFFFFF',
    scroll    => '#CDD2D9',
    scroll_on => '#B4BBC5',
);
our %DARK = (
    paper     => '#1B1E23',
    panel     => '#252A31',
    line      => '#3C434D',
    hover     => '#313842',
    ink       => '#E7E9ED',
    muted     => '#A7B0BB',
    faint     => '#8B949E',
    ghost     => '#8E99A6',
    accent    => '#1F5FBF',
    accent_fg => '#9DC2FF',
    accent_dk => '#184C99',
    accent_bg => '#1A3354',
    select    => '#2A466C',
    error     => '#FF8A90',
    error_bg  => '#4A2629',
    warn      => '#E7C27A',
    sash      => '#2A3038',
    on_accent => '#FFFFFF',
    scroll    => '#3E4651',
    scroll_on => '#55606C',
);
our %C = %LIGHT;
our $DARK = 0;

our $POINTER = $^O eq 'MSWin32' ? 'arrow' : 'left_ptr';
our ($MONO, $MONO_B, $UI, $UI_B, $UI_S);
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
        if ($per) { $per->Call(1) }
        else { Win32::API->new('user32', 'SetProcessDPIAware', '', 'I')->Call() }
        1;
    };
}

sub pick_fonts {
    my %have = map { lc $_ => 1 } $main::mw->fontFamilies;
    my ($mono) = grep { $have{ lc $_ } } 'Consolas', 'DejaVu Sans Mono', 'Liberation Mono', 'Menlo', 'Courier New';
    my ($ui)   = grep { $have{ lc $_ } } 'Segoe UI', 'DejaVu Sans', 'Liberation Sans', 'Helvetica Neue', 'Arial';
    $mono //= 'Courier';
    $ui   //= 'Helvetica';
    ($MONO, $MONO_B) = ([ $mono, 10 ], [ $mono, 10, 'bold' ]);
    ($UI, $UI_B, $UI_S) = ([ $ui, 9 ], [ $ui, 9, 'bold' ], [ $ui, 8, 'bold' ]);
}

#------------------------------------------------------------------------------
# The icon is the editor's, read out of phcp_editor.pl as data so this file
# does not carry a second copy and does not load the editor.  On Windows the
# .ico is handed to the window directly, as the editor does.
#------------------------------------------------------------------------------
sub editor_icon_png {
    my $path = File::Spec->catfile($FindBin::Bin, 'phcp_editor.pl');
    open my $fh, '<', $path or return;
    local $/;
    my $src = <$fh>;
    close $fh;
    my %png;
    while ($src =~ /\b(16|32|48)\s*=>\s*join\('',\s*qw\(\s*(.*?)\s*\)\s*\)/sg) {
        my ($sz, $raw) = ($1, $2);
        $raw =~ s/\s+//g;
        $png{$sz} = $raw;
    }
    return %png;
}

sub icon_file {
    my @try = (File::Spec->catfile($FindBin::Bin, 'data', 'phcp.ico'));
    push @try, File::Spec->catfile($ENV{PAR_TEMP}, 'inc', 'lib', 'data', 'phcp.ico') if $ENV{PAR_TEMP};
    my ($ico) = grep { -f } @try;
    return $ico;
}

our $mw;

sub set_icon {
    if ($^O eq 'MSWin32' and my $ico = icon_file()) {
        return if eval { $mw->iconbitmap('-default', $ico); 1 }
               or eval { $mw->iconbitmap($ico); 1 };
    }
    return unless eval { require Tk::PNG; 1 };
    my %png = editor_icon_png();
    return unless %png;
    my @img = map { $mw->Photo(-format => 'png', -data => $png{$_}) } sort { $b <=> $a } keys %png;
    eval { $mw->iconphoto('-default', @img); 1 } or eval { $mw->iconimage($img[-1]) };
}

#------------------------------------------------------------------------------
# Appearance.  Widgets are built in whichever ground is already in %C.  Each
# one is remembered with the role of every colour it carries (paper, ink, ...)
# so a later switch repaints it.  Roles are names, not hex, because the two
# grounds share a few hex values: white is both the light paper and the
# lettering on a blue button, and the light text-blue is the button blue.
#------------------------------------------------------------------------------
our @THEMED;
our %THEMED_SEEN;
our ($list, $restabs, $mode_key, $msg_text, $msg_bad, $msg_warn);
our %btn;

sub norm_colour {
    my $c = lc(shift // '');
    return $c if $c =~ /^#[0-9a-f]{6}$/;
    if ($c =~ /^#([0-9a-f]{4})([0-9a-f]{4})([0-9a-f]{4})$/) {
        return sprintf '#%02x%02x%02x', hex(substr($1, 0, 2)), hex(substr($2, 0, 2)), hex(substr($3, 0, 2));
    }
    return $c;
}

sub pick_role {
    my ($colour, $opt) = @_;
    my $c = norm_colour($colour);
    return undef if $c eq '';
    my %m;
    for my $pal (\%LIGHT, \%DARK) {
        $m{$_} = 1 for grep { norm_colour($pal->{$_}) eq $c } keys %$pal;
    }
    return undef unless %m;
    my $fg = $opt =~ /foreground|insertbackground|highlightcolor|disabledforeground/;
    if ($fg) {
        return 'on_accent' if $m{on_accent};
        return 'accent_fg' if $m{accent_fg};
    } else {
        return 'paper' if $m{paper} && $m{on_accent};
        return 'accent' if $m{accent} && $m{accent_fg};
    }
    return (sort keys %m)[0];
}

sub index_one {
    my $w = shift or return;
    return unless eval { Tk::Exists($w) };
    my $id = refaddr($w) or return;
    return if $THEMED_SEEN{$id};
    my %roles;
    for my $opt (qw(background foreground activebackground activeforeground disabledforeground
                    highlightbackground highlightcolor insertbackground
                    selectbackground selectforeground troughcolor)) {
        my $v = eval { $w->cget("-$opt") };
        next unless defined $v;
        my $role = pick_role($v, $opt);
        $roles{$opt} = $role if $role;
    }
    return unless %roles;
    $THEMED_SEEN{$id} = 1;
    push @THEMED, [ $w, \%roles ];
}

sub index_tree {
    my ($w, $seen) = @_;
    return unless $w;
    $seen ||= {};
    my $id = refaddr($w) or return;
    return if $seen->{$id}++;
    index_one($w);
    index_tree($_, $seen) for eval { $w->children };
}

# forget_tree -- drop a widget, and everything in it, from the repaint list
# before it is destroyed.  The row is rebuilt on every command change; keeping
# the dead widgets would pin them in memory.
sub forget_tree {
    my $w = shift or return;
    forget_tree($_) for eval { $w->children };
    my $id = refaddr($w) or return;
    delete $THEMED_SEEN{$id};
    @THEMED = grep { refaddr($_->[0]) != $id } @THEMED;
}

sub paint_menu {
    my $m = shift or return;
    return unless eval { Tk::Exists($m) && $m->isa('Tk::Menu') };
    eval {
        $m->configure(-background => $C{paper}, -foreground => $C{ink},
            -activebackground => $C{select}, -activeforeground => $C{ink});
    };
    my $end = eval { $m->index('end') };
    return unless defined $end;
    for my $i (0 .. $end) {
        my $type = eval { $m->type($i) } // '';
        paint_menu(eval { $m->entrycget($i, -menu) }) if $type eq 'cascade';
    }
}

sub load_appearance {
    my $v = eval { HardyCross::Settings::get('FAST_DARK') } // '';
    $DARK = ($v eq '1') ? 1 : 0;
    %C = $DARK ? %DARK : %LIGHT;
}

sub save_appearance {
    eval { HardyCross::Settings::set('FAST_DARK', $DARK ? '1' : undef) };
}

sub apply_appearance {
    %C = $DARK ? %DARK : %LIGHT;
    return unless $mw && eval { Tk::Exists($mw) };
    $mw->optionAdd('*Background', $C{paper});
    $mw->optionAdd('*Foreground', $C{ink});
    $mw->optionAdd('*Menu.background', $C{paper});
    $mw->optionAdd('*Menu.foreground', $C{ink});
    $mw->optionAdd('*Menu.activeBackground', $C{select});
    $mw->optionAdd('*Menu.activeForeground', $C{ink});
    @THEMED = grep { eval { Tk::Exists($_->[0]) } } @THEMED;
    for my $item (@THEMED) {
        my ($w, $roles) = @$item;
        my %cfg;
        for my $opt (keys %$roles) {
            next unless exists $C{ $roles->{$opt} };
            $cfg{"-$opt"} = $C{ $roles->{$opt} };
        }
        eval { $w->configure(%cfg) } if %cfg;
        paint_menu(eval { $w->cget(-menu) }) if eval { $w->isa('Tk::Menubutton') };
    }
    paint_menu(eval { $mw->cget(-menu) });
    paint_modes();
    select_tab($restabs, $restabs->{current}) if $restabs && $restabs->{current};
    paint_fields();
    fill_list() if $list && eval { Tk::Exists($list) };
    row_check() if $mode_key;
    message($msg_text, $msg_bad, $msg_warn);
    update_actions();
    $btn{THEME}->configure(-text => $DARK ? 'LIGHT' : 'DARK') if $btn{THEME} && eval { Tk::Exists($btn{THEME}) };
}

sub toggle_theme {
    $DARK = $DARK ? 0 : 1;
    apply_appearance();
    save_appearance();
}

#==============================================================================
# State.  One window, so package variables.  The settings hash is the one
# HardyCross::Editor joins into the head of the file; the form's own variables
# are copied into it by sync_settings before any check, save or solve.
#==============================================================================
our ($report, $val_list, $pipe_list, $node_list, $out_list);
our ($toolbar_msg, $template_l, $live_l, $hint_l, $keys_l, $use_label);
our ($field_frame, $details, $details_on);
our (%ent, %value, %ghost, %mode_btn, %detail);
our ($use_type, $use_c, $use_type_ent, $use_c_ent) = ('BORE', '');
our ($title_var, $method_var) = ('', 'HW');
our %unit_var;
our @dd_refresh;
our $settings = HardyCross::Editor::new_settings();
our $network = '';
our $path;
our $saved_text = '';
our $valid_text;
our $solved;
our $validation;
$mode_key = 'PIPE';
our $edit_line;
our $edit_is_use = 0;
our $loading_line = 0;
our (%sticky, %sticky_set);
our (@undo, @redo);
our $check_job;
our %LABEL = (POINTS => 'FLOW PRESSURE', PIPETYPE => 'PIPE TYPE', MINPRESSURE => 'MIN PRESSURE',
              MINFLOW => 'MIN FLOW', MININLET => 'MIN INLET', FITTINGS => 'FITTINGS');

sub sync_settings {
    $settings->{title} = uc($title_var // '');
    $title_var = $settings->{title};
    $settings->{method} = ($method_var && $method_var ne '') ? $method_var : 'HW';
    $settings->{units}{$_} = $unit_var{$_} for @HardyCross::Phc::UNIT_QUANTITIES;
    for my $f (@HardyCross::Editor::PROJECT_FIELDS) {
        my $v = uc($detail{$f} // '');
        $detail{$f} = $v;
        if (length $v) { $settings->{project}{$f} = $v }
        else           { delete $settings->{project}{$f} }
    }
}

sub push_form {
    $title_var = $settings->{title} // '';
    $method_var = $settings->{method} // 'HW';
    $unit_var{$_} = $settings->{units}{$_} for @HardyCross::Phc::UNIT_QUANTITIES;
    $detail{$_} = $settings->{project}{$_} // '' for @HardyCross::Editor::PROJECT_FIELDS;
    $_->() for @dd_refresh;
}

sub full_text {
    sync_settings();
    my ($t) = HardyCross::Editor::join_file($settings, $network);
    $t .= "\n" unless $t =~ /\n\z/;
    return $t;
}

sub doc { sync_settings(); return { settings => $settings, network => $network } }

#==============================================================================
# Widgets.
#==============================================================================
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
        -background => $p ? $C{accent} : $C{paper}, -foreground => $p ? $C{on_accent} : $C{ink},
        -activebackground => $p ? $C{accent_dk} : $C{hover},
        -activeforeground => $p ? $C{on_accent} : $C{ink},
        -disabledforeground => $C{faint}, -padx => px(12), -pady => px(4), -cursor => 'hand2');
}

sub flat_entry {
    my ($parent, $var, $width) = @_;
    return $parent->Entry(-textvariable => $var, -font => $MONO, -width => $width // 14,
        -relief => 'flat', -borderwidth => 0, -highlightthickness => 1,
        -highlightbackground => $C{line}, -highlightcolor => $C{accent},
        -background => $C{paper}, -foreground => $C{ink}, -insertbackground => $C{ink},
        -selectbackground => $C{select}, -selectforeground => $C{ink});
}

sub flat_scrollbar {
    my ($parent, $orient) = @_;
    return $parent->Scrollbar(-orient => $orient, -relief => 'flat', -borderwidth => 0,
        -elementborderwidth => 0, -width => px(11), -troughcolor => $C{panel},
        -background => $C{scroll}, -activebackground => $C{scroll_on}, -highlightthickness => 0);
}

sub drop_down {
    my ($parent, $var, $choices, $cmd) = @_;
    my $show = sub { (length($$var // '') ? $$var : 'DEFAULT') . "  \x{25BE}" };
    my $mb = $parent->Menubutton(-text => $show->(), -font => $MONO, -relief => 'flat',
        -borderwidth => 0, -highlightthickness => 1, -highlightbackground => $C{line},
        -background => $C{paper}, -activebackground => $C{hover}, -foreground => $C{ink},
        -anchor => 'w', -width => 12, -padx => px(4), -pady => px(2), -indicatoron => 0, -cursor => 'hand2');
    my $m = $mb->Menu(-tearoff => 0, -font => $MONO, -relief => 'flat', -borderwidth => 1,
        -activeborderwidth => 0, -background => $C{paper}, -foreground => $C{ink},
        -activebackground => $C{select}, -activeforeground => $C{ink});
    for my $v (@$choices) {
        $m->command(-label => $v, -command => sub { $$var = $v; $mb->configure(-text => $show->()); $cmd->() });
    }
    $mb->configure(-menu => $m);
    push @dd_refresh, sub { $mb->configure(-text => $show->()) };
    return $mb;
}

sub make_tabs {
    my ($parent, $names) = @_;
    my $t = { names => $names, page => {}, label => {} };
    $t->{bar} = $parent->Frame(-background => $C{paper})->pack(-side => 'top', -fill => 'x');
    rule($parent, 'x', -side => 'top');
    my $body = $parent->Frame(-background => $C{paper})->pack(-side => 'top', -fill => 'both', -expand => 1);
    for my $n (@$names) {
        my $f = $t->{bar}->Frame(-background => $C{paper})->pack(-side => 'left');
        my $l = $f->Label(-text => $n, -font => $UI_B, -background => $C{paper}, -foreground => $C{muted},
                          -padx => px(12), -pady => px(6), -cursor => 'hand2')->pack(-side => 'top');
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
}

sub mono_list {
    my ($parent) = @_;
    my $f = $parent->Frame(-background => $C{paper})->pack(-fill => 'both', -expand => 1);
    my $sy = flat_scrollbar($f, 'vertical')->pack(-side => 'right', -fill => 'y');
    my $sx = flat_scrollbar($f, 'horizontal')->pack(-side => 'bottom', -fill => 'x');
    my $lb = $f->Listbox(-font => $MONO, -background => $C{paper}, -foreground => $C{ink},
        -selectbackground => $C{select}, -selectforeground => $C{ink},
        -relief => 'flat', -borderwidth => 0, -highlightthickness => 0,
        -activestyle => 'none', -exportselection => 0);
    $lb->pack(-side => 'left', -fill => 'both', -expand => 1);
    $lb->configure(-yscrollcommand => [ $sy => 'set' ], -xscrollcommand => [ $sx => 'set' ]);
    $sy->configure(-command => [ $lb => 'yview' ]);
    $sx->configure(-command => [ $lb => 'xview' ]);
    return $lb;
}

#==============================================================================
# Building the window.
#==============================================================================
sub build_window {
    dpi_aware();
    load_appearance();
    $mw = MainWindow->new(-background => $C{paper});
    set_icon();
    my $dpi = $mw->winfo('pixels', '1i');
    $SCALE = $dpi > 96 ? $dpi / 96 : 1;
    pick_fonts();
    $mw->geometry(px(1180) . 'x' . px(860));
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
    rule($mw, 'x');
    build_use_bar();
    rule($mw, 'x');
    build_modes();
    rule($mw, 'x');
    build_row();
    build_panes();
    bind_window();
    $unit_var{$_} = $settings->{units}{$_} for @HardyCross::Phc::UNIT_QUANTITIES;
    $method_var = $settings->{method};
    $_->() for @dd_refresh;
    seed_use_bar();
    set_mode('PIPE', force => 1);
    $saved_text = full_text();
    set_title();
    update_actions();
    index_tree($mw);
    paint_fields();
    return $mw;
}

sub build_menus {
    my $bar = $mw->Menu(-tearoff => 0);
    $mw->configure(-menu => $bar);
    my $file = $bar->Menu(-tearoff => 0);
    my $edit = $bar->Menu(-tearoff => 0);
    my $model = $bar->Menu(-tearoff => 0);
    my $view = $bar->Menu(-tearoff => 0);
    $bar->add('cascade', -label => 'FILE', -menu => $file);
    $bar->add('cascade', -label => 'EDIT', -menu => $edit);
    $bar->add('cascade', -label => 'VIEW', -menu => $view);
    $bar->add('cascade', -label => 'MODEL', -menu => $model);
    $file->add('command', -label => 'NEW', -accelerator => 'Ctrl+N', -command => \&file_new);
    $file->add('command', -label => 'OPEN', -accelerator => 'Ctrl+O', -command => \&file_open);
    $file->add('command', -label => 'SAVE', -accelerator => 'Ctrl+S', -command => \&file_save);
    $file->add('command', -label => 'SAVE AS', -command => \&file_save_as);
    $file->add('separator');
    $file->add('command', -label => 'WRITE REPORT', -accelerator => 'Ctrl+R', -command => \&file_report);
    $file->add('separator');
    $file->add('command', -label => 'QUIT', -command => \&file_quit);
    $edit->add('command', -label => 'UNDO', -accelerator => 'Ctrl+Z', -command => \&do_undo);
    $edit->add('command', -label => 'REDO', -accelerator => 'Ctrl+Y', -command => \&do_redo);
    $view->add('checkbutton', -label => 'DARK', -variable => \$DARK, -command => sub {
        apply_appearance();
        save_appearance();
    });
    $model->add('command', -label => 'VALIDATE', -accelerator => 'F4', -command => \&do_validate);
    $model->add('command', -label => 'CALCULATE', -accelerator => 'F5', -command => \&do_calculate);
}

sub build_toolbar {
    my $bar = $mw->Frame(-background => $C{panel})->pack(-fill => 'x');
    my $left = $bar->Frame(-background => $C{panel})->pack(-side => 'left', -padx => px(6), -pady => px(6));
    $btn{NEW} = flat_button($left, 'NEW', \&file_new)->pack(-side => 'left', -padx => px(2));
    $btn{OPEN} = flat_button($left, 'OPEN', \&file_open)->pack(-side => 'left', -padx => px(2));
    $btn{SAVE} = flat_button($left, 'SAVE', \&file_save)->pack(-side => 'left', -padx => px(2));
    $left->Frame(-width => px(16), -background => $C{panel})->pack(-side => 'left');
    $btn{VALIDATE} = flat_button($left, 'VALIDATE', \&do_validate)->pack(-side => 'left', -padx => px(2));
    $btn{CALCULATE} = flat_button($left, 'CALCULATE', \&do_calculate, primary => 1)->pack(-side => 'left', -padx => px(2));
    $left->Frame(-width => px(16), -background => $C{panel})->pack(-side => 'left');
    $btn{REPORT} = flat_button($left, 'WRITE REPORT', \&file_report)->pack(-side => 'left', -padx => px(2));
    $toolbar_msg = $bar->Label(-text => '', -font => $UI, -background => $C{panel}, -foreground => $C{ink},
        -anchor => 'e')->pack(-side => 'right', -padx => px(12));
    $btn{THEME} = flat_button($bar, $DARK ? 'LIGHT' : 'DARK', \&toggle_theme)
        ->pack(-side => 'right', -padx => px([2, 4]), -pady => px(6));
}

sub build_use_bar {
    my $bar = $mw->Frame(-background => $C{paper})->pack(-fill => 'x', -padx => px(8), -pady => px(6));
    $bar->Label(-text => 'USE', -font => $UI_B, -background => $C{paper}, -foreground => $C{accent_fg})
        ->pack(-side => 'left', -padx => px([0, 6]));
    $bar->Label(-text => 'PIPE TYPE', -font => $UI_S, -background => $C{paper}, -foreground => $C{muted})
        ->pack(-side => 'left');
    $use_type_ent = flat_entry($bar, \$use_type, 10);
    $use_type_ent->pack(-side => 'left', -padx => px(4));
    $bar->Label(-text => 'C', -font => $UI_S, -background => $C{paper}, -foreground => $C{muted})
        ->pack(-side => 'left', -padx => px([8, 0]));
    $use_c_ent = flat_entry($bar, \$use_c, 6);
    $use_c_ent->pack(-side => 'left', -padx => px(4));
    $use_label = $bar->Label(-text => '', -font => $UI, -background => $C{paper}, -foreground => $C{muted})
        ->pack(-side => 'left', -padx => px(12));
    $btn{DETAILS} = flat_button($bar, 'DETAILS', \&toggle_details)->pack(-side => 'right');
    for my $e ($use_type_ent, $use_c_ent) {
        $e->bind('<Return>' => sub { commit_use(); $_[0]->break });
        $e->bind('<KP_Enter>' => sub { commit_use(); $_[0]->break });
        $e->bind('<Escape>' => sub { escape_row(); $_[0]->break });
        $e->bind('<Control-space>' => sub { pick_for('PIPETYPE') if $_[0] == $use_type_ent; $_[0]->break });
    }
    $use_type_ent->bind('<FocusIn>' => sub { $_[0]->selectionRange(0, 'end') });
    $use_c_ent->bind('<FocusIn>' => sub { $_[0]->selectionRange(0, 'end') });

    $details = $mw->Frame(-background => $C{panel});
    my $grid = $details->Frame(-background => $C{panel})->pack(-fill => 'x', -padx => px(8), -pady => px(6));
    add_form_field($grid, 0, 0, 'TITLE', \$title_var, 40);
    add_form_field($grid, 0, 2, 'METHOD', undef, 0, drop_down($grid, \$method_var, [qw(HW DW)], \&form_changed));
    my $c = 0;
    my $r = 1;
    for my $q (@HardyCross::Phc::UNIT_QUANTITIES) {
        $unit_var{$q} = $settings->{units}{$q};
        my $choices = $HardyCross::Phc::UNIT_CHOICES{$q};
        my $dd = drop_down($grid, \$unit_var{$q}, $choices, \&form_changed);
        add_form_field($grid, $r, $c, $q, undef, 0, $dd);
        $c += 2;
        if ($c >= 6) { $c = 0; $r++ }
    }
    $r++;
    $c = 0;
    for my $f (@HardyCross::Editor::PROJECT_FIELDS) {
        $detail{$f} = '';
        add_form_field($grid, $r, $c, HardyCross::Editor::project_label($f), \$detail{$f}, 22);
        $c += 2;
        if ($c >= 6) { $c = 0; $r++ }
    }
}

sub add_form_field {
    my ($grid, $r, $c, $label, $var, $width, $widget) = @_;
    $grid->Label(-text => $label, -font => $UI_S, -background => $C{panel}, -foreground => $C{muted}, -anchor => 'w')
        ->grid(-row => $r, -column => $c, -sticky => 'w', -padx => px(4), -pady => px(2));
    my $e = $widget || flat_entry($grid, $var, $width);
    $e->grid(-row => $r, -column => $c + 1, -sticky => 'ew', -padx => px(4), -pady => px(2));
    if ($var && !$widget) {
        $e->bind('<FocusOut>' => sub { form_changed() if form_differs() });
    }
    return $e;
}

# form_differs -- true when the form's title, units, method or details are not
# what settings already holds.  FocusOut would otherwise record an undo step
# for leaving a field that did not change.
sub form_differs {
    return 1 if uc($title_var // '') ne uc($settings->{title} // '');
    return 1 if ($method_var // '') ne ($settings->{method} // '');
    for my $q (@HardyCross::Phc::UNIT_QUANTITIES) {
        return 1 if ($unit_var{$q} // '') ne ($settings->{units}{$q} // '');
    }
    for my $f (@HardyCross::Editor::PROJECT_FIELDS) {
        return 1 if uc($detail{$f} // '') ne uc($settings->{project}{$f} // '');
    }
    return 0;
}

sub toggle_details {
    if ($details_on) {
        $details->packForget;
        $details_on = 0;
    } else {
        $details->pack(-fill => 'x', -after => $use_label->parent);
        $details_on = 1;
    }
}

sub build_modes {
    my $box = $mw->Frame(-background => $C{paper})->pack(-fill => 'x', -padx => px(6), -pady => px(3));
    for my $g (HardyCross::FastEntry::groups()) {
        my ($name, @keys) = @$g;
        my $row = $box->Frame(-background => $C{paper})->pack(-fill => 'x');
        $row->Label(-text => $name, -font => $UI_S, -width => 9, -anchor => 'w',
            -background => $C{paper}, -foreground => $C{muted})->pack(-side => 'left');
        for my $k (@keys) {
            my $m = HardyCross::FastEntry::mode($k);
            my $label = $m->{hotkey} ? "$k  $m->{hotkey}" : $k;
            $mode_btn{$k} = $row->Button(-text => $label, -font => $UI_S, -relief => 'flat', -borderwidth => 0,
                -highlightthickness => 0, -padx => px(7), -pady => px(3), -cursor => 'hand2',
                -background => $C{paper}, -foreground => $C{ink},
                -activebackground => $C{hover}, -activeforeground => $C{ink},
                -command => sub { set_mode($k) })->pack(-side => 'left', -padx => px(1));
        }
    }
}

sub paint_modes {
    for my $k (keys %mode_btn) {
        my $on = $k eq $mode_key;
        $mode_btn{$k}->configure(
            -background => $on ? $C{accent_bg} : $C{paper},
            -foreground => $on ? $C{accent_fg} : $C{ink},
            -activebackground => $on ? $C{accent_bg} : $C{hover},
            -activeforeground => $on ? $C{accent_fg} : $C{ink});
    }
}

sub build_row {
    $field_frame = $mw->Frame(-background => $C{paper})->pack(-fill => 'x', -padx => px(8), -pady => px([4, 0]));
    my $status = $mw->Frame(-background => $C{paper})->pack(-fill => 'x', -padx => px(8), -pady => px(2));
    $template_l = $status->Label(-text => '', -font => $MONO, -background => $C{paper}, -foreground => $C{ink}, -anchor => 'w')
        ->pack(-side => 'left');
    $live_l = $status->Label(-text => '', -font => $UI, -background => $C{paper}, -foreground => $C{muted}, -anchor => 'w')
        ->pack(-side => 'left', -padx => px(12));
    $hint_l = $mw->Label(-text => '', -font => $UI_S, -background => $C{paper}, -foreground => $C{muted},
        -anchor => 'w', -justify => 'left', -wraplength => px(1100))
        ->pack(-fill => 'x', -padx => px(8));
    $keys_l = $mw->Label(-text => 'ENTER ADDS THE ROW.  TAB MOVES.  APOSTROPHE COPIES THE FIELD ABOVE.  '
        . 'CTRL+SPACE CHOOSES.  F4 VALIDATE.  F5 CALCULATE.',
        -font => $UI_S, -background => $C{paper}, -foreground => $C{faint}, -anchor => 'w', -justify => 'left',
        -wraplength => px(1100))->pack(-fill => 'x', -padx => px(8), -pady => px([0, 4]));
}

sub build_panes {
    my $vp = $mw->Panedwindow(-orient => 'vertical', -background => $C{sash}, -sashwidth => px(6),
        -sashpad => 0, -borderwidth => 0, -showhandle => 0, -handlesize => 0,
        -sashrelief => 'flat', -opaqueresize => 1, -sashcursor => 'sb_v_double_arrow');
    $vp->pack(-fill => 'both', -expand => 1);
    my $top = $vp->Frame(-background => $C{paper});
    my $bot = $vp->Frame(-background => $C{paper});
    $vp->add($top, -minsize => px(80));
    $vp->add($bot, -minsize => px(80));

    my $head = $top->Frame(-background => $C{panel})->pack(-fill => 'x');
    $head->Label(-text => 'NETWORK', -font => $UI_B, -background => $C{panel}, -foreground => $C{ink})
        ->pack(-side => 'left', -padx => px(8), -pady => px(4));
    $btn{REMOVE} = flat_button($head, 'REMOVE', \&delete_selected)->pack(-side => 'right', -padx => px(6), -pady => px(3));
    $list = mono_list($top);
    $list->bind('<<ListboxSelect>>' => sub {
        my ($i) = $list->curselection;
        load_line($i + 1) if defined $i;
    });
    $list->bind('<Delete>' => \&delete_selected);

    $restabs = make_tabs($bot, [qw(VALIDATION PIPES NODES OUTLETS REPORT)]);
    $val_list = mono_list($restabs->{page}{VALIDATION});
    $val_list->bind('<<ListboxSelect>>' => \&goto_validation);
    $pipe_list = mono_list($restabs->{page}{PIPES});
    $node_list = mono_list($restabs->{page}{NODES});
    $out_list = mono_list($restabs->{page}{OUTLETS});
    $report = $restabs->{page}{REPORT}->Text(-font => $MONO, -background => $C{paper}, -foreground => $C{ink},
        -relief => 'flat', -borderwidth => 0, -highlightthickness => 0, -state => 'disabled', -wrap => 'none');
    my $sy = flat_scrollbar($restabs->{page}{REPORT}, 'vertical');
    $report->pack(-side => 'left', -fill => 'both', -expand => 1);
    $sy->pack(-side => 'right', -fill => 'y');
    $report->configure(-yscrollcommand => [ $sy => 'set' ]);
    $sy->configure(-command => [ $report => 'yview' ]);
}

sub bind_window {
    $mw->bind('<F4>' => sub { do_validate(); $_[0]->break });
    $mw->bind('<F5>' => sub { do_calculate(); $_[0]->break });
    $mw->bind('<Control-s>' => sub { file_save(); $_[0]->break });
    $mw->bind('<Control-S>' => sub { file_save(); $_[0]->break });
    $mw->bind('<Control-o>' => sub { file_open(); $_[0]->break });
    $mw->bind('<Control-n>' => sub { file_new(); $_[0]->break });
    $mw->bind('<Control-r>' => sub { file_report(); $_[0]->break });
    $mw->bind('<Control-z>' => sub { do_undo(); $_[0]->break });
    $mw->bind('<Control-Z>' => sub { do_undo(); $_[0]->break });
    $mw->bind('<Control-y>' => sub { do_redo(); $_[0]->break });
    $mw->bind('<Control-Y>' => sub { do_redo(); $_[0]->break });
    $mw->protocol('WM_DELETE_WINDOW', \&file_quit);
    for my $m (HardyCross::FastEntry::modes()) {
        my $k = $m->{hotkey} or next;
        my $key = $m->{key};
        for my $letter (lc $k, uc $k) {
            $mw->bind("<Alt-$letter>" => sub {
                if ($key eq 'USE') { $use_type_ent->focus; $use_type_ent->selectionRange(0, 'end') }
                else               { set_mode($key) }
                $_[0]->break;
            });
        }
    }
}

#==============================================================================
# The row.
#==============================================================================
sub set_mode {
    my ($key, %o) = @_;
    my $m = HardyCross::FastEntry::mode($key) or return;
    return if $m->{bar};
    if (!$o{force} && $key eq $mode_key && !$o{no_ghosts}) {
        focus_first();
        return;
    }
    if (!$o{force} && row_dirty()) {
        message('THE ROW HAS NOT BEEN ADDED. ENTER ADDS IT, ESCAPE CLEARS IT', 1);
        return 0;
    }
    unless ($o{keep_edit}) {
        $edit_line = undef;
        $edit_is_use = 0;
    }
    $mode_key = $key;
    paint_modes();
    rebuild_fields($o{no_ghosts});
    $hint_l->configure(-text => HardyCross::FastEntry::hint_for($key));
    return 1;
}

sub rebuild_fields {
    my ($no_ghosts) = @_;
    forget_tree($_) for $field_frame->children;
    for my $w ($field_frame->children) { $w->destroy }
    %ent = ();
    %value = ();
    %ghost = ();
    my $m = HardyCross::FastEntry::mode($mode_key);
    for my $fd (@{ $m->{fields} }) {
        my $k = $fd->{key};
        my $col = $field_frame->Frame(-background => $C{paper})->pack(-side => 'left', -padx => px(3), -anchor => 'n');
        $col->Label(-text => $LABEL{$k} // $k, -font => $UI_S, -background => $C{paper}, -foreground => $C{muted},
            -anchor => 'w')->pack(-fill => 'x');
        my $width = ($fd->{text} || $fd->{rest}) ? 28 : 12;
        $value{$k} = '';
        my $e = flat_entry($col, \$value{$k}, $width);
        $e->pack(-fill => 'x');
        $ent{$k} = $e;
        bind_field($e, $k);
    }
    fill_ghosts() unless $no_ghosts;
    index_tree($field_frame);
    row_check();
}

sub bind_field {
    my ($e, $key) = @_;
    $e->bind('<Return>'   => sub { commit_row(); $_[0]->break });
    $e->bind('<KP_Enter>' => sub { commit_row(); $_[0]->break });
    $e->bind('<Down>'     => sub { commit_row(); $_[0]->break });
    $e->bind('<Tab>'      => sub { focus_rel(1, $key); $_[0]->break });
    $e->bind('<Shift-Tab>' => sub { focus_rel(-1, $key); $_[0]->break });
    $e->bind('<ISO_Left_Tab>' => sub { focus_rel(-1, $key); $_[0]->break });
    $e->bind('<Escape>'   => sub { escape_row(); $_[0]->break });
    $e->bind('<Up>'       => sub { edit_previous($key); $_[0]->break });
    $e->bind('<KeyPress-apostrophe>' => sub { $_[0]->break if ditto_field($key) });
    $e->bind('<Control-apostrophe>' => sub { ditto_field($key); $_[0]->break });
    $e->bind('<Control-space>' => sub { pick_for($key); $_[0]->break });
    $e->bind('<KeyRelease>' => sub { paint_fields(); arm_check() });
    $e->bind('<FocusIn>' => sub {
        eval { $_[0]->selectionRange(0, 'end') };
        mark_field($key);
    });
}

sub field_order {
    my $m = HardyCross::FastEntry::mode($mode_key) or return;
    return map { $_->{key} } @{ $m->{fields} };
}

sub focus_field {
    my $k = shift or return;
    my $e = $ent{$k} or return;
    $e->focus;
    eval { $e->selectionRange(0, 'end') };
    mark_field($k);
}

sub focus_first {
    my ($k) = field_order();
    focus_field($k);
}

sub focus_rel {
    my ($dir, $key) = @_;
    my @k = field_order();
    my ($i) = grep { $k[$_] eq $key } 0 .. $#k;
    $i = 0 unless defined $i;
    my $n = $i + $dir;
    $n = 0 if $n < 0;
    $n = $#k if $n > $#k;
    focus_field($k[$n]);
}

sub mark_field {
    my $bad = shift;
    for my $k (keys %ent) {
        $ent{$k}->configure(-highlightbackground => (defined $bad && $k eq $bad) ? $C{error} : $C{line});
    }
}

sub current_values {
    my $m = HardyCross::FastEntry::mode($mode_key);
    return map { $_->{key} => $value{ $_->{key} } } @{ $m->{fields} };
}

sub set_fields {
    my %v = @_;
    for my $k (keys %v) {
        next unless exists $ent{$k};
        $value{$k} = $v{$k};
    }
    paint_fields();
    arm_check();
}

sub row_dirty {
    for my $k (keys %ent) {
        return 1 if ($value{$k} // '') ne ($ghost{$k} // '');
    }
    return 0;
}

sub sticky_now {
    return $sticky{$mode_key} if $sticky_set{$mode_key};
    return HardyCross::FastEntry::sticky_from_network($network, $mode_key);
}

sub fill_ghosts {
    %ghost = %{ HardyCross::FastEntry::next_ghosts($network, $mode_key, sticky_now()) };
    for my $k (keys %ent) {
        $value{$k} = $ghost{$k} // '';
        $ghost{$k} = $value{$k};
    }
    paint_fields();
}

# paint_fields -- an offered value is quieter than one that was typed.  While
# a line is being edited the row holds that line, so nothing on it is an offer.
sub paint_fields {
    for my $k (keys %ent) {
        my $e = $ent{$k} or next;
        next unless eval { Tk::Exists($e) };
        my $offered = !$edit_line && defined $ghost{$k} && $ghost{$k} ne ''
            && ($value{$k} // '') eq $ghost{$k};
        $e->configure(-foreground => $offered ? $C{ghost} : $C{ink}, -insertbackground => $C{ink});
    }
}

sub arm_check {
    $check_job->cancel if $check_job;
    $check_job = $mw->after(60, \&row_check);
}

sub row_check {
    $check_job = undef;
    return unless $mw && Tk::Exists($mw);
    sync_settings();
    my %v = current_values();
    my $p = HardyCross::FastEntry::preview(
        settings => $settings, network => $network, mode => $mode_key, values => \%v);
    $template_l->configure(-text => $p->{template} // '');
    if ($p->{status} eq 'ok') {
        my $n = $p->{count} > 1 ? "    $p->{count} LINES" : '';
        $live_l->configure(-text => "OK$n", -foreground => $C{accent_fg});
        mark_field(undef);
    } elsif ($p->{status} eq 'incomplete' && !row_dirty() && !$edit_line) {
        $live_l->configure(-text => '', -foreground => $C{muted});
        mark_field(undef);
    } else {
        $live_l->configure(-text => $p->{message}, -foreground => $p->{status} eq 'error' ? $C{error} : $C{warn});
        mark_field($p->{field});
    }
    paint_fields();
}

sub ditto_field {
    my $key = shift;
    my $e = $ent{$key} or return 0;
    # The apostrophe may already be in the field: Tk inserts the character
    # before this binding when the key is delivered as an event.  No field in
    # a .phc line contains an apostrophe, so the key always means "copy".
    my $g = $ghost{$key} // '';
    my $stripped = $value{$key} // '';
    $stripped =~ s/'//g;
    return 0 unless $stripped eq '' || $stripped eq $g;
    my $d = HardyCross::FastEntry::ditto($network, $mode_key, $key, $edit_line);
    $value{$key} = defined $d ? $d : $g;
    eval { $e->selectionRange(0, 'end') };
    arm_check();
    return 1;
}

sub edit_previous {
    my $key = shift;
    my ($first) = field_order();
    return unless $key eq $first && !row_dirty() && !$edit_line;
    my @l = HardyCross::FastEntry::net_lines($network);
    load_line(scalar @l) if @l;
}

sub commit_row {
    if ($edit_is_use) {
        message('FINISH THE USE LINE IN THE USE BAR, OR PRESS ESCAPE', 1);
        return { ok => 0 };
    }
    sync_settings();
    my %v = current_values();
    my $r = HardyCross::FastEntry::plan(
        settings => $settings, network => $network, mode => $mode_key,
        values => \%v, use => { type => $use_type, c => $use_c }, edit => $edit_line);
    unless ($r->{ok}) {
        message($r->{message}, 1);
        $live_l->configure(-text => $r->{message}, -foreground => $C{error});
        focus_field($r->{field});
        mark_field($r->{field});
        return $r;
    }
    remember();
    $network = $r->{network};
    # Sticky comes from the row the user saw, not from a generated later line
    # of a run (those step).  Fittings and the other kept fields are on it.
    $sticky{$mode_key} = HardyCross::FastEntry::sticky_of($mode_key, \%v);
    $sticky_set{$mode_key} = 1;
    my $edited = $edit_line;
    $edit_line = undef;
    $edit_is_use = 0;
    invalidate();
    fill_list();
    fill_ghosts();
    row_check();
    focus_first();
    my $warn = join '  ', @{ $r->{warnings} || [] };
    if ($warn ne '') { message("ADDED. $warn", 0, 1) }
    elsif ($edited)  { message('LINE UPDATED') }
    else             { message(@{ $r->{lines} } > 1 ? scalar(@{ $r->{lines} }) . ' LINES ADDED' : 'ADDED') }
    return $r;
}

sub commit_use {
    sync_settings();
    my %v = (PIPETYPE => $use_type, C => $use_c);
    my $r = HardyCross::FastEntry::plan(
        settings => $settings, network => $network, mode => 'USE',
        values => \%v, edit => $edit_is_use ? $edit_line : undef);
    unless ($r->{ok}) {
        message($r->{message}, 1);
        return $r;
    }
    # An unchanged type comes back as a USE line too, when not editing: plan
    # always writes the row it was given.  Skip the append when it would not
    # change what is in force.  Editing a USE line always writes it.
    if (!$edit_is_use && !defined HardyCross::FastEntry::use_line($settings, $network, { type => $use_type, c => $use_c })) {
        message('PIPE TYPE UNCHANGED');
        focus_first();
        return { ok => 1, unchanged => 1 };
    }
    remember();
    $network = $r->{network};
    $edit_line = undef;
    $edit_is_use = 0;
    invalidate();
    fill_list();
    seed_use_bar();
    fill_ghosts();
    focus_first();
    message('USE UPDATED');
    return $r;
}

sub escape_row {
    $edit_line = undef;
    $edit_is_use = 0;
    $list->selectionClear(0, 'end') if $list;
    seed_use_bar();
    fill_ghosts();
    row_check();
    focus_first();
    message('');
}

sub load_line {
    my $n = shift;
    my @l = HardyCross::FastEntry::net_lines($network);
    return if $n < 1 || $n > @l;
    return if $loading_line;
    # A row that has been typed into is not thrown away by clicking another
    # line.  Enter keeps it, Escape discards it.  The click has already moved
    # the highlight; put it back, and do not re-enter this from that.
    if (row_dirty()) {
        local $loading_line = 1;
        message('THE ROW HAS NOT BEEN ADDED. ENTER ADDS IT, ESCAPE CLEARS IT', 1);
        if ($list) {
            $list->selectionClear(0, 'end');
            $list->selectionSet($edit_line - 1) if $edit_line && $edit_line >= 1;
        }
        return;
    }
    local $loading_line = 1;
    my $f = HardyCross::FastEntry::fields_of_line($l[$n - 1]);
    if ($f->{command} eq 'USE') {
        $edit_line = $n;
        $edit_is_use = 1;
        $use_type = $f->{values}{PIPETYPE} // '';
        $use_c = $f->{values}{C} // '';
        $list->selectionClear(0, 'end');
        $list->selectionSet($n - 1);
        $list->see($n - 1);
        $use_type_ent->focus;
        message("EDITING LINE $n");
        return;
    }
    $edit_is_use = 0;
    set_mode($f->{command}, force => 1, no_ghosts => 1, keep_edit => 1);
    $edit_line = $n;
    for my $k (keys %{ $f->{values} }) {
        next unless exists $ent{$k};
        $value{$k} = $f->{values}{$k} // '';
        $ghost{$k} = $value{$k};
    }
    for my $k (keys %ent) { $ghost{$k} //= $value{$k} // '' }
    $list->selectionClear(0, 'end');
    $list->selectionSet($n - 1);
    $list->see($n - 1);
    message("EDITING LINE $n");
    row_check();
    paint_fields();
    focus_first();
}

sub pick_for {
    my $key = shift;
    sync_settings();
    my $field = $key;
    my $mode = $mode_key;
    my %v = current_values();
    if ($key eq 'PIPETYPE') {
        $mode = 'USE';
        %v = (PIPETYPE => $use_type, C => $use_c);
        $field = 'PIPETYPE';
    }
    my $choices = HardyCross::FastEntry::choices_for(
        settings => $settings, network => $network, mode => $mode, field => $field, values => \%v);
    my $typed = $key eq 'PIPETYPE' ? $use_type : ($value{$key} // '');
    my $c = HardyCross::FastEntry::complete($typed, $choices);
    if ($c->{unique} && uc($c->{unique}) ne uc($typed // '')) {
        if ($key eq 'PIPETYPE') { $use_type = $c->{unique} }
        else                    { $value{$key} = $c->{unique} }
        arm_check();
        return;
    }
    my $matches = $c->{matches};
    unless (@$matches) { message('NOTHING TO CHOOSE FOR THIS FIELD'); return }
    my $top = $mw->Toplevel(-background => $C{paper});
    $top->transient($mw);
    $top->title('CHOOSE');
    my $lb = $top->Listbox(-font => $MONO, -background => $C{paper}, -foreground => $C{ink},
        -selectbackground => $C{select}, -height => (@$matches > 12 ? 12 : scalar @$matches),
        -relief => 'flat', -borderwidth => 0, -highlightthickness => 1, -highlightbackground => $C{line});
    $lb->pack(-fill => 'both', -expand => 1);
    $lb->insert('end', sprintf('%-8s %s', @$_)) for @$matches;
    $lb->selectionSet(0);
    my $choose = sub {
        my ($i) = $lb->curselection;
        $top->destroy;
        return unless defined $i;
        if ($key eq 'PIPETYPE') { $use_type = $matches->[$i][0] }
        else                    { $value{$key} = $matches->[$i][0] }
        arm_check();
        focus_field($key) if $ent{$key};
    };
    $lb->bind('<Return>' => $choose);
    $lb->bind('<Double-ButtonRelease-1>' => $choose);
    $lb->bind('<Escape>' => sub { $top->destroy });
    $lb->focus;
}

#==============================================================================
# The list, undo, messages.
#==============================================================================
sub fill_list {
    return unless $list;
    $list->delete(0, 'end');
    sync_settings();
    my @l = HardyCross::FastEntry::net_lines($network);
    my $chk = @l ? HardyCross::Editor::doc_check(doc()) : undef;
    for my $i (1 .. @l) {
        $list->insert('end', sprintf('%4d   %s', $i, $l[$i - 1]));
        my $st = $chk->{lines}[$i]{status} // 'ok';
        my $colour = $C{ink};
        $colour = $C{error} if $st eq 'error' || $st eq 'incomplete';
        $colour = $C{muted} if $l[$i - 1] =~ /^\s*\/\//;
        $list->itemconfigure($i - 1, -foreground => $colour);
    }
    if ($edit_line && $edit_line >= 1 && $edit_line <= @l) {
        $list->selectionSet($edit_line - 1);
        $list->see($edit_line - 1);
    } elsif (@l) {
        $list->see('end');
    }
    refresh_use_label();
}

sub refresh_use_label {
    sync_settings();
    my $u = HardyCross::FastEntry::use_in_force($settings, $network);
    my $c = defined $u->{c} && $u->{c} ne '' ? " $u->{c}" : '';
    $use_label->configure(-text => "IN FORCE  $u->{type}$c") if $use_label;
}

sub seed_use_bar {
    return if $edit_is_use;
    sync_settings();
    my $u = HardyCross::FastEntry::use_in_force($settings, $network);
    $use_type = $u->{type};
    $use_c = defined $u->{c} ? $u->{c} : '';
    refresh_use_label();
}

sub list_text {
    return () unless $list;
    return map { $list->get($_) } 0 .. $list->size - 1;
}

sub snapshot {
    sync_settings();
    return { network => $network, settings => clone_settings($settings),
             use_type => $use_type, use_c => $use_c };
}

sub clone_settings {
    my $s = shift;
    return { title => $s->{title} // '', project => { %{ $s->{project} || {} } },
             extra => [ @{ $s->{extra} || [] } ], units => { %{ $s->{units} } },
             method => $s->{method}, options => { %{ $s->{options} || {} } } };
}

sub replace_settings {
    my $n = shift;
    $settings->{title} = $n->{title} // '';
    $settings->{method} = $n->{method} // 'HW';
    $settings->{extra} = [ @{ $n->{extra} || [] } ];
    $settings->{units}{$_} = $n->{units}{$_} for keys %{ $n->{units} };
    %{ $settings->{project} } = %{ $n->{project} || {} };
    %{ $settings->{options} } = %{ $n->{options} || {} };
}

sub remember {
    push @undo, snapshot();
    @redo = ();
    trim_undo();
}

# remember_before_sync -- an undo step for a change that is still only in the
# form.  snapshot() copies the form into settings, so it must not be used
# until the previous settings have been kept.
sub remember_before_sync {
    push @undo, { network => $network, settings => clone_settings($settings),
                  use_type => $use_type, use_c => $use_c };
    @redo = ();
    trim_undo();
}

sub trim_undo { splice @undo, 0, @undo - 200 if @undo > 200 }

sub form_changed {
    return unless form_differs();
    remember_before_sync();
    sync_settings();
    invalidate();
}

sub restore {
    my $s = shift;
    $network = $s->{network};
    replace_settings($s->{settings});
    $use_type = $s->{use_type};
    $use_c = $s->{use_c};
    $edit_line = undef;
    $edit_is_use = 0;
    push_form();
    invalidate();
    fill_list();
    set_mode($mode_key, force => 1);
}

sub do_undo {
    return message('NOTHING TO UNDO') unless @undo;
    push @redo, snapshot();
    restore(pop @undo);
    message('UNDONE');
}

sub do_redo {
    return message('NOTHING TO REDO') unless @redo;
    push @undo, snapshot();
    restore(pop @redo);
    message('REDONE');
}

sub delete_selected {
    my $n = $edit_line;
    if (!$n && $list) {
        my ($i) = $list->curselection;
        $n = $i + 1 if defined $i;
    }
    return message('SELECT A LINE TO REMOVE') unless $n;
    my $new = HardyCross::FastEntry::delete_line($network, $n);
    return message('THERE IS NO LINE TO REMOVE', 1) unless defined $new;
    remember();
    $network = $new;
    $edit_line = undef;
    $edit_is_use = 0;
    invalidate();
    fill_list();
    seed_use_bar();
    fill_ghosts();
    row_check();
    message('LINE REMOVED');
}

sub message {
    my ($text, $bad, $warn) = @_;
    $msg_text = $text // '';
    $msg_bad = $bad ? 1 : 0;
    $msg_warn = $warn ? 1 : 0;
    return unless $toolbar_msg && eval { Tk::Exists($toolbar_msg) };
    my $colour = $msg_bad ? $C{error} : $msg_warn ? $C{warn} : $C{ink};
    $toolbar_msg->configure(-text => $msg_text, -foreground => $colour);
}

sub set_title {
    my $name = $path // 'UNTITLED.PHC';
    $name =~ s{.*[/\\]}{};
    my $star = full_text() ne $saved_text ? ' *' : '';
    $mw->title('PHCP FAST ENTRY - ' . uc($name) . $star) if $mw;
}

sub invalidate {
    $valid_text = undef;
    $solved = undef;
    update_actions();
    set_title();
}

sub update_actions {
    return unless $btn{CALCULATE} && eval { Tk::Exists($btn{CALCULATE}) };
    my $on = defined $valid_text && $valid_text eq full_text();
    # A disabled Calculate stays on the toolbar ground.  The blue is reserved
    # for the moment it will actually run, so the eye can find it.
    $btn{CALCULATE}->configure(
        -state => $on ? 'normal' : 'disabled',
        -background => $on ? $C{accent} : $C{panel},
        -foreground => $on ? $C{on_accent} : $C{faint},
        -activebackground => $on ? $C{accent_dk} : $C{hover},
        -activeforeground => $on ? $C{on_accent} : $C{faint},
        -highlightbackground => $on ? $C{accent} : $C{line},
        -disabledforeground => $C{faint},
    );
}

#==============================================================================
# Validate, calculate, report.
#==============================================================================
sub do_validate {
    $check_job->cancel if $check_job;
    my $v = HardyCross::Editor::validate(doc());
    $validation = $v;
    $valid_text = $v->{ok} ? full_text() : undef;
    fill_validation();
    select_tab($restabs, 'VALIDATION') if $restabs;
    update_actions();
    my $n = @{ $v->{items} };
    message($v->{ok} ? 'VALID. CALCULATE (F5) IS NOW AVAILABLE'
                     : "$n PROBLEM" . ($n == 1 ? '' : 'S') . ' - SEE VALIDATION', !$v->{ok});
    return $v;
}

sub fill_validation {
    return unless $val_list;
    $val_list->delete(0, 'end');
    return unless $validation;
    for my $it (@{ $validation->{items} }) {
        my $where = $it->{tab} ? 'PROJECT' : (defined $it->{line} ? "LINE $it->{line}" : '');
        my $field = $it->{field} // '';
        $val_list->insert('end', sprintf('%-10s %-14s %s', $where, $field, $it->{what}));
    }
    $val_list->insert('end', 'NO PROBLEMS') if $validation->{ok};
}

sub goto_validation {
    my ($i) = $val_list->curselection;
    return unless defined $i && $validation;
    my $it = $validation->{items}[$i] or return;
    if ($it->{tab}) {
        toggle_details() unless $details_on;
        return;
    }
    load_line($it->{line}) if $it->{line};
    focus_field($it->{field}) if $it->{field} && $ent{ $it->{field} };
}

sub do_calculate {
    sync_settings();
    my $full = full_text();
    unless (defined $valid_text && $valid_text eq $full) {
        message('VALIDATE THE INPUTS FIRST (F4)', 1);
        return { ok => 0, not_validated => 1 };
    }
    my $t0 = time;
    my $turn = 0;
    my $progress = sub {
        my $what = shift;
        message(sprintf('%s COMPUTING - %s - %d S', ('|', '/', '-', '\\')[$turn++ % 4], $what, time - $t0));
        $mw->update if $mw;
    };
    eval { $mw->Busy(-recurse => 1) } if $mw;
    $progress->('CALCULATING');
    my $r = eval { HardyCross::Editor::doc_solve(doc(), $path, progress => $progress) };
    my $err = $@;
    eval { $mw->Unbusy } if $mw;
    die $err unless $r;
    unless ($r->{ok}) {
        $solved = undef;
        fill_results();
        message($r->{error}, 1);
        load_line($r->{line}) if $r->{line};
        return $r;
    }
    if (defined $r->{network} && $r->{network} ne $network) {
        remember();
        $network = $r->{network};
        fill_list();
        $full = full_text();
        $valid_text = $full;
    }
    $solved = { net => $r->{net}, converged => $r->{converged}, text => $full };
    fill_results();
    fill_report($r->{report});
    select_tab($restabs, 'PIPES');
    message($r->{converged} ? 'CALCULATED - CONVERGED'
                            : 'CALCULATED - DID NOT CONVERGE. THE RESULTS MUST NOT BE USED', !$r->{converged});
    return $r;
}

sub fill_results {
    fill_table($pipe_list, $solved && $solved->{net}, 'pipes', [qw(NAME SNODE ENODE NOM Q VEL PF)]);
    fill_table($node_list, $solved && $solved->{net}, 'nodes');
    fill_table($out_list, $solved && $solved->{net}, 'outlets');
}

sub fill_table {
    my ($lb, $net, $which, $want) = @_;
    return unless $lb;
    $lb->delete(0, 'end');
    unless ($net) { $lb->insert('end', 'VALIDATE, THEN CALCULATE'); return }
    my $t = HardyCross::Editor::result_tables($net)->{$which} or return;
    my @cols = @{ $t->{columns} };
    my @ix = 0 .. $#cols;
    if ($want) {
        @ix = ();
        for my $h (@$want) {
            for my $i (0 .. $#cols) {
                push @ix, $i if $cols[$i]{head} eq $h;
            }
        }
    }
    $lb->insert('end', join '  ', map { sprintf '%-8s', $cols[$_]{head} } @ix);
    for my $row (@{ $t->{rows} }) {
        $lb->insert('end', join '  ', map { sprintf '%-8s', $row->{cells}[$_] } @ix);
    }
    $lb->insert('end', '(NONE)') unless @{ $t->{rows} };
}

sub fill_report {
    my $text = shift // '';
    return unless $report;
    $report->configure(-state => 'normal');
    $report->delete('1.0', 'end');
    $report->insert('1.0', $text);
    $report->configure(-state => 'disabled');
}

sub report_text { return $report ? $report->get('1.0', 'end - 1 chars') : '' }

#==============================================================================
# Files.
#==============================================================================
sub modified { full_text() ne $saved_text }

sub ok_to_discard {
    return 1 unless modified();
    my $a = $mw->messageBox(-title => 'UNSAVED CHANGES', -icon => 'warning', -type => 'YesNo',
        -message => 'THE MODEL HAS UNSAVED CHANGES.  DISCARD THEM?');
    return lc($a) eq 'yes';
}

sub file_new {
    return unless ok_to_discard();
    $path = undef;
    replace_settings(HardyCross::Editor::new_settings());
    $network = '';
    %sticky = ();
    %sticky_set = ();
    @undo = ();
    @redo = ();
    $edit_line = undef;
    $edit_is_use = 0;
    $validation = undef;
    push_form();
    seed_use_bar();
    set_mode('PIPE', force => 1);
    fill_list();
    fill_validation();
    fill_results();
    fill_report('');
    $saved_text = full_text();
    invalidate();
    message('');
    set_title();
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
    my $d = HardyCross::Editor::split_file($r->{text});
    $path = $r->{path};
    replace_settings($d->{settings});
    $network = $d->{network};
    %sticky = ();
    %sticky_set = ();
    @undo = ();
    @redo = ();
    $edit_line = undef;
    $edit_is_use = 0;
    $validation = undef;
    $solved = undef;
    $valid_text = undef;
    push_form();
    seed_use_bar();
    set_mode('PIPE', force => 1);
    fill_list();
    fill_validation();
    fill_results();
    fill_report('');
    $saved_text = full_text();
    update_actions();
    set_title();
    message('OPENED');
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
    $f .= '.phc' unless $f =~ /\.phc\z/i;
    return unless write_file($f);
    $path = $f;
    set_title();
    return 1;
}

sub write_file {
    my $f = shift;
    my $text = full_text();
    my $fh;
    unless (open $fh, '>', $f) { message("CANNOT WRITE $f: " . uc($!), 1); return 0 }
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
        return unless do_validate()->{ok};
        return unless do_calculate()->{ok};
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

#==============================================================================
# Start.  A test sets $main::PHCP_FAST_LOAD_ONLY and builds the window itself.
# An explicit flag, not "unless caller": a packaged .exe is started by the
# packager's loader, where caller is set, and the window would never open.
#==============================================================================
sub main {
    my $file = shift;
    build_window();
    open_path($file) if defined $file && $file ne '';
    MainLoop;
}
our $PHCP_FAST_LOAD_ONLY;
main(@ARGV) unless $PHCP_FAST_LOAD_ONLY;

1;
