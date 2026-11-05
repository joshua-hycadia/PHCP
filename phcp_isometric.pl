#!/usr/bin/perl
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# phcp_isometric.pl -- the network drawn, rather than typed.
#
#   perl phcp_isometric.pl [model.phc]
#
# A fork of phcp_editor.pl.  That file is not modified: it is loaded for the
# PROJECT tab, the results, the database and the file commands, and the
# window built here has no NETWORK tab.  The model still lives in the
# editor's buffer, because the calculation is the .phc text.  The drawing
# writes that text.
#
# Written for Perl 5.44.  The same source runs on 5.38 and 5.42, which is
# what the tests and the Windows build use.  It does not need a feature that
# 5.44 added, and it does not use anything 5.44 removed.
#==============================================================================
use strict;
use warnings;
no warnings 'once';   # build_window and the load-only flag are the editor's
use File::Basename qw(dirname);
use Cwd qw(abs_path);

# This file's own directory, so a test that loads it still finds the editor
# beside it.  FindBin would name the test, not this program.
my $ROOT;
BEGIN {
    $ROOT = dirname(abs_path(__FILE__));
    $main::PHCP_EDITOR_LOAD_ONLY = 1;
}
use lib $ROOT;
require "$ROOT/phcp_editor.pl";
require HardyCross::Window::Isometric;

# Declared in the editor and the drawing window.  strict in this file needs
# its own names for the same package variables.
our ($mw, $ed, $toptabs, $path, $SCALE, $saved_text, $iso_cv, $UI, %C, %iso, $theme);

# The editor's own recolour and set_buffer do not know about the drawing.
# These wrappers are the fork: the editor file stays as it is.
{
    no warnings 'redefine';
    my $recolour = \&recolour;
    *recolour = sub {
        my $res = $recolour->();
        iso_show() if $iso_cv && $toptabs && ($toptabs->{current} || '') eq 'ISOMETRIC';
        return $res;
    };
    my $set_buffer = \&set_buffer;
    *set_buffer = sub {
        iso_invalidate();
        $set_buffer->(@_);
    };
    my $go_to_line = \&go_to_line;
    *go_to_line = sub {
        my ($n, $a, $b) = @_;
        return $go_to_line->(@_) unless $toptabs && $toptabs->{page} && !$toptabs->{page}{NETWORK};
        iso_reveal_line($n);
    };
    *set_title = sub {
        my $name = $path // 'UNTITLED.PHC';
        $name =~ s{.*[/\\]}{};
        $mw->title('PHCP ISOMETRIC - ' . uc($name) . ($ed && modified() ? ' *' : '')) if $mw;
    };
    *build_window = \&iso_editor_window;
    # The editor asks for its NETWORK tab when a file opens.  This window
    # has no such tab; that request is the drawing.
    my $select_tab = \&select_tab;
    *select_tab = sub {
        my ($t, $n) = @_;
        $n = 'ISOMETRIC' if defined $n && $n eq 'NETWORK' && $t && $t->{page}
            && !$t->{page}{NETWORK} && $t->{page}{ISOMETRIC};
        return $select_tab->($t, $n);
    };
    # The toolbar's DARK MODE is the editor's.  Here it paints the drawing
    # too, and it remembers ISO_THEME rather than the editor's key.
    my $apply_theme = \&apply_theme;
    *apply_theme = sub {
        my $res = $apply_theme->(@_);
        iso_follow_theme() if defined &iso_follow_theme;
        return $res;
    };
    *toggle_theme = sub {
        apply_theme($theme eq 'dark' ? 'light' : 'dark');
        eval { HardyCross::Settings::set('ISO_THEME', uc $theme) };
    };
}

# iso_editor_window -- the editor's window, with the drawing in place of the
# NETWORK tab.  The text buffer is still built, hidden, because VALIDATE,
# undo and the file all read it.
sub iso_editor_window {
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

    my $hidden = $mw->Frame(-background => $C{paper});
    build_network($hidden);

    my $vp = divider($mw, 'vertical');
    my $top = $mw->Frame(-background => $C{paper});
    my $bottom = $mw->Frame(-background => $C{paper});
    $toptabs = make_tabs($top, [ 'ISOMETRIC', 'PROJECT', 'GRAPH', 'QUICK TOOLS', 'DATABASE' ],
                         sub {
                             tools_refresh() if $_[0] eq 'QUICK TOOLS';
                             iso_show() if $_[0] eq 'ISOMETRIC';
                         });
    build_isometric($toptabs->{page}{ISOMETRIC});
    build_project($toptabs->{page}{PROJECT});
    build_graph($toptabs->{page}{GRAPH});
    build_tools($toptabs->{page}{'QUICK TOOLS'});
    build_database($toptabs->{page}{DATABASE});
    build_results($bottom);
    $vp->add($top, -height => px(560));
    $vp->add($bottom);
    $vp->pack(-fill => 'both', -expand => 1);

    bind_keys();
    $saved_text = full_text();
    set_title();
    update_actions();
    update_status();
    iso_show();
    iso_focus_drawing();
    # A palette remembered from last time, this window's own key.  The
    # widgets are built light and then repainted, the same way as the editor.
    my $saved = eval { lc(HardyCross::Settings::get('ISO_THEME') // '') } // '';
    apply_theme('dark') if $saved eq 'dark';
    return $mw;
}

# iso_reveal_line -- a click in VALIDATION selects that pipe or point on the
# drawing.  There is no NETWORK tab to put the cursor in.
sub iso_reveal_line {
    my $n = shift or return;
    select_tab($toptabs, 'ISOMETRIC') if $toptabs && $toptabs->{page}{ISOMETRIC};
    my $line = eval { $ed->get("$n.0", "$n.0 lineend") };
    return unless defined $line;
    my $a = HardyCross::Phc::analyse($line);
    return unless $a && $a->{status} eq 'ok' && $iso{draw};
    my $name = $a->{pos}[0];
    return unless defined $name && $name ne '';
    if ($iso{draw}{nodes}{$name}) {
        $iso{sel} = { kind => 'node', name => $name };
    } elsif (grep { $_->{name} eq $name } @{ $iso{draw}{pipes} }) {
        $iso{sel} = { kind => 'pipe', name => $name };
    } elsif (grep { $_->{name} eq $name } @{ $iso{draw}{pumps} }) {
        $iso{sel} = { kind => 'pump', name => $name };
    } else {
        return;
    }
    iso_props();
    iso_redraw();
}

our $PHCP_ISO_LOAD_ONLY;
main(@ARGV) unless $PHCP_ISO_LOAD_ONLY;

1;
