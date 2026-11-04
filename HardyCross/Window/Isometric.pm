#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
# HardyCross/Window/Isometric.pm -- the drawing window of phcp_isometric.pl.
#
# A fork of the text editor, not a change to it.  phcp_editor.pl is loaded
# for the PROJECT tab, the results and the file commands, and this file
# replaces the NETWORK tab with the drawing.  A pipe is two clicks, or the
# length, size, fittings and C typed first and one click for the direction.
# The drawing writes the .phc that VALIDATE and CALCULATE already run.
# Positions are //ISO comments, which the reader ignores, so the calculation
# is the commands.  Every decision -- where a point sits, what a click hits,
# what text is written -- is HardyCross::Isometric.  This file is the window.
#
# The window is one program: this file is package main, loaded by
# phcp_isometric.pl, and uses the editor's widgets and its hidden buffer.
#==============================================================================
package main;

use strict;
use warnings;
use HardyCross::Isometric;
use HardyCross::Phc;

our ($UI, $UI_B, $UI_S, $MONO, %C, $mw, $ed, $gutter, $statusbar, $settings, $toptabs, $POINTER, %checks);

our ($iso_cv, %iso);

# Which captions are drawn.  The same idea as the spreadsheet's column
# chooser: the picture stays quiet until the one thing you want is switched on.
my @LABELS = qw(POINTS PIPES LENGTH SIZE FITTINGS ELEVATION DEVICES);

my @TOOLS = (
    [ 'SELECT',    'SELECT',    'SELECT A POINT OR A PIPE, AND DRAG A POINT ALONG THE GRID' ],
    [ 'NODE',      'NODE',      'CLICK THE GRID TO PLACE A POINT' ],
    [ 'WATER',     'WATER',     'CLICK THE GRID TO PLACE A WATER SUPPLY' ],
    [ 'SPRINKLER', 'SPRINKLER', 'CLICK THE GRID TO PLACE A SPRINKLER' ],
    [ 'HYDRANT',   'HYDRANT',   'CLICK THE GRID TO PLACE A HYDRANT' ],
    [ 'HREEL',     'REEL',      'CLICK THE GRID TO PLACE A HOSE REEL' ],
    [ 'PIPE',      'PIPE',      'CLICK A POINT, THEN THE NEXT. OR TYPE A KNOWN LENGTH: THE CLICK ONLY CHOOSES THE DIRECTION' ],
    [ 'PUMP',      'PUMP',      'CLICK THE TWO POINTS THE PUMP JOINS' ],
    [ 'FIXEDFLOW', 'FLOW',      'CLICK A POINT TO PUT A FIXED FLOW ON IT' ],
    [ 'DELETE',    'DELETE',    'CLICK A POINT OR A PIPE TO REMOVE IT' ],
);

sub build_isometric {
    my $page = shift;
    my $bar = $page->Frame(-background => $C{paper})->pack(-side => 'top', -fill => 'x', -padx => px(8), -pady => px(6));
    for my $t (@TOOLS) {
        my ($kind, $label) = @$t;
        $iso{tools}{$kind} = flat_button($bar, $label, sub { iso_set_tool($kind) })
            ->pack(-side => 'left', -padx => px([0, 4]));
    }
    # What the next pipe uses, typed before the click.  A blank length means
    # the click sets the length.  A length means the click only picks the axis.
    my $known = $page->Frame(-background => $C{paper})->pack(-side => 'top', -fill => 'x', -padx => px(8), -pady => px([0, 4]));
    $known->Label(-text => 'KNOWN', -font => $UI_B, -background => $C{paper}, -foreground => $C{ink})
        ->pack(-side => 'left', -padx => px([0, 8]));
    $iso{known} = { LENGTH => '', SIZE => '', FITTINGS => '', C => '' };
    $iso{known_label} = {};
    my $lu = ($settings && $settings->{units}{LENGTH}) || 'MM';
    my $su = ($settings && $settings->{units}{SIZE}) || 'MM';
    iso_known_entry($known, 'LENGTH', "LENGTH $lu", 8);
    iso_known_entry($known, 'SIZE', "SIZE $su", 6);
    iso_known_entry($known, 'FITTINGS', 'FITTINGS', 10);
    iso_known_entry($known, 'C', 'C', 6);
    $known->Label(-text => 'CLICK AND CLICK, OR TYPE THESE. BLANK LENGTH FOLLOWS THE CLICK.',
        -font => $UI_S, -background => $C{paper}, -foreground => $C{muted}, -anchor => 'w')
        ->pack(-side => 'left', -padx => px(8));

    my $bar2 = $page->Frame(-background => $C{paper})->pack(-side => 'top', -fill => 'x', -padx => px(8), -pady => px([0, 6]));
    $iso{elev_label} = $bar2->Label(-text => 'ELEVATION', -font => $UI_S, -background => $C{paper},
        -foreground => $C{muted})->pack(-side => 'left');
    $iso{elev} = '0';
    my $ee = flat_entry($bar2, \$iso{elev}, 8);
    $ee->pack(-side => 'left', -padx => px([6, 12]));
    $ee->bind('<Return>' => sub { iso_status('ELEVATION SET. THE NEXT POINT IS PLACED THERE.') });
    $bar2->Label(-text => 'GRID M', -font => $UI_S, -background => $C{paper}, -foreground => $C{muted})
        ->pack(-side => 'left');
    $iso{gridvar} = '1';
    my $ge = flat_entry($bar2, \$iso{gridvar}, 6);
    $ge->pack(-side => 'left', -padx => px([6, 12]));
    $ge->bind('<Return>' => sub { iso_grid_apply() });
    $iso{btn}{FIT}  = flat_button($bar2, 'FIT',      sub { iso_fit(1) })->pack(-side => 'left', -padx => px([0, 4]));
    $iso{btn}{IN}   = flat_button($bar2, 'ZOOM IN',  sub { iso_zoom(1.25) })->pack(-side => 'left', -padx => px(4));
    $iso{btn}{OUT}  = flat_button($bar2, 'ZOOM OUT', sub { iso_zoom(1 / 1.25) })->pack(-side => 'left', -padx => px(4));
    $iso{lock} = 1;
    $iso{btn}{LOCK} = flat_button($bar2, 'LOCK', sub { iso_set_lock() })->pack(-side => 'left', -padx => px(4));
    $iso{btn}{DARK} = flat_button($bar2, 'DARK', sub { iso_apply_theme($iso{theme} eq 'DARK' ? 'LIGHT' : 'DARK') })
        ->pack(-side => 'left', -padx => px(4));
    $iso{labels} = { map { $_ => ($_ =~ /^(POINTS|PIPES|DEVICES)\z/ ? 1 : 0) } @LABELS };
    require Tk::Menubutton;
    my $labels = $bar2->Menubutton(-text => 'LABELS', -font => $UI_B, -relief => 'flat', -borderwidth => 0,
        -highlightthickness => 1, -highlightbackground => $C{line}, -highlightcolor => $C{accent},
        -background => $C{paper}, -foreground => $C{ink}, -activebackground => $C{hover},
        -activeforeground => $C{ink}, -padx => px(14), -pady => px(5), -direction => 'below');
    $labels->pack(-side => 'left', -padx => px(4));
    $iso{label_menu} = $labels->Menu(-tearoff => 0);
    $labels->configure(-menu => $iso{label_menu});
    for my $name (@LABELS) {
        $iso{label_menu}->checkbutton(-label => $name, -variable => \$iso{labels}{$name},
            -command => sub { iso_redraw() });
    }
    $iso{btn}{LABELS} = $labels;
    $iso{status_w} = $bar2->Label(-text => '', -font => $UI, -background => $C{paper}, -foreground => $C{muted},
        -anchor => 'w')->pack(-side => 'left', -padx => px(12), -fill => 'x', -expand => 1);
    rule($page, 'x', -side => 'top');

    # The drawing, and the properties of whatever is selected, on the right.
    # The spreadsheet kept a figure beside the grid you were editing; this is
    # that, for one pipe or one point.  No extra divider: the results pane
    # below is already one.
    my $body = $page->Frame(-background => $C{paper})->pack(-fill => 'both', -expand => 1);
    $iso{props} = $body->Frame(-background => $C{panel}, -width => px(300))->pack(-side => 'right', -fill => 'y');
    $iso{props}->packPropagate(0);
    rule($body, 'y', -side => 'right');
    my $ef = $body->Frame(-background => $C{paper})->pack(-side => 'left', -fill => 'both', -expand => 1);
    my $vsb = flat_scrollbar($ef, 'vertical')->pack(-side => 'right', -fill => 'y');
    my $hsb = flat_scrollbar($ef, 'horizontal')->pack(-side => 'bottom', -fill => 'x');
    $iso_cv = $ef->Canvas(-background => $C{paper}, -highlightthickness => 0, -borderwidth => 0,
        -confine => 1, -cursor => $POINTER, -takefocus => 1,
        -xscrollcommand => sub { $hsb->set(@_) },
        -yscrollcommand => sub { $vsb->set(@_) })->pack(-fill => 'both', -expand => 1);
    $vsb->configure(-command => sub { $iso_cv->yview(@_) });
    $hsb->configure(-command => sub { $iso_cv->xview(@_) });
    wheel_target($iso_cv);
    # Canvas::bind attaches a tag to items.  These are the widget's own keys,
    # so they go through CanvasBind, which is Tk::bind.  Ev('x') is the
    # coordinate in the widget; the test generates the click that way.
    $iso_cv->CanvasBind('<ButtonPress-1>'   => [ sub { my ($w, $x, $y) = @_; iso_press($w->canvasx($x), $w->canvasy($y)) }, Ev('x'), Ev('y') ]);
    $iso_cv->CanvasBind('<B1-Motion>'       => [ sub { my ($w, $x, $y) = @_; iso_motion($w->canvasx($x), $w->canvasy($y)) }, Ev('x'), Ev('y') ]);
    $iso_cv->CanvasBind('<ButtonRelease-1>' => [ sub { my ($w, $x, $y) = @_; iso_release($w->canvasx($x), $w->canvasy($y)) }, Ev('x'), Ev('y') ]);
    $iso_cv->CanvasBind('<Escape>'          => sub { $iso{from} = undef; $iso{drag} = undef; iso_status('CANCELLED'); iso_redraw() });
    $iso_cv->CanvasBind('<Delete>'          => sub { iso_delete_sel() });

    $iso{theme} = 'LIGHT';
    $iso{tool} = 'SELECT';
    iso_set_tool('SELECT');
    iso_mark($iso{btn}{LOCK}, 1);
}

# iso_invalidate -- the text was replaced (a file opened).  The next time the
# tab is shown it reads again and fits the new drawing.
sub iso_invalidate {
    $iso{source} = undef;
    $iso{had_fit} = 0;
    $iso{sel} = undef;
    $iso{from} = undef;
    $iso{drag} = undef;
}

sub iso_key {
    my $u = $settings && $settings->{units} ? $settings->{units} : {};
    return buffer() . "\0" . join(',', map { defined $u->{$_} ? $u->{$_} : '' }
        qw(LENGTH ELEVATION SIZE PRESSURE FLOW KFACTOR));
}

# iso_show -- read the network if it changed, and draw it.  Called when the
# tab is selected and after the text changes while it is showing.  It does
# not write: looking at the drawing never reformats the file.
sub iso_show {
    return unless $iso_cv && $toptabs && ($toptabs->{current} || '') eq 'ISOMETRIC';
    my $key = iso_key();
    my $reload = !defined $iso{source} || $iso{source} ne $key || !$iso{draw};
    if ($reload) {
        $iso{draw} = HardyCross::Isometric::read_network(buffer(), $settings->{units});
        $iso{source} = $key;
        $iso{sel} = undef;
        $iso{from} = undef;
        $iso{gridvar} = HardyCross::Isometric::clean_num($iso{draw}{grid});
        iso_fit(1) unless $iso{had_fit};
        $iso{had_fit} = 1;
        iso_props();
    }
    my $eu = $settings->{units}{ELEVATION} || 'M';
    $iso{elev_label}->configure(-text => "ELEVATION $eu") if $iso{elev_label};
    my $lu = $settings->{units}{LENGTH} || 'MM';
    my $su = $settings->{units}{SIZE} || 'MM';
    $iso{known_label}{LENGTH}->configure(-text => "LENGTH $lu") if $iso{known_label}{LENGTH};
    $iso{known_label}{SIZE}->configure(-text => "SIZE $su") if $iso{known_label}{SIZE};
    iso_redraw();
}

# iso_known_entry -- one figure typed ahead of the next pipe.
sub iso_known_entry {
    my ($bar, $key, $label, $width) = @_;
    $iso{known_label}{$key} = $bar->Label(-text => $label, -font => $UI_S, -background => $C{paper},
        -foreground => $C{muted})->pack(-side => 'left');
    my $e = flat_entry($bar, \$iso{known}{$key}, $width);
    $e->configure(-justify => 'right') if $key ne 'FITTINGS';
    $e->pack(-side => 'left', -padx => px([4, 10]));
    $e->bind('<Return>' => sub { iso_known_apply($key) });
}

# iso_known_apply -- Return in a known field checks it, then the drawing
# takes the next click.  The field keeps the focus when the figure is wrong.
sub iso_known_apply {
    my $key = shift;
    my $v = $iso{known}{$key};
    $v = '' unless defined $v;
    $v =~ s/^\s+|\s+\z//g;
    $iso{known}{$key} = $v;
    my $err = $iso{draw} ? HardyCross::Isometric::known_ok($iso{draw}, iso_known_args()) : '';
    if ($err) { iso_fail($err); return }
    if ($v eq '') {
        iso_status($key eq 'LENGTH'
            ? 'LENGTH CLEARED. THE CLICK SETS THE LENGTH.'
            : "$key CLEARED. THE NEXT PIPE USES THE USUAL VALUE.");
    } elsif ($key eq 'LENGTH') {
        iso_status("LENGTH $v. THE NEXT CLICK CHOOSES THE DIRECTION ONLY.");
    } else {
        iso_status("$key $v. THE NEXT PIPE USES IT.");
    }
    iso_focus_drawing();
}

# iso_known_args -- the hash add_pipe reads.  Blank fields stay blank.
sub iso_known_args {
    my $k = $iso{known} || {};
    my %out;
    for my $pair ([ 'LENGTH', 'len' ], [ 'SIZE', 'size' ], [ 'FITTINGS', 'fits' ], [ 'C', 'c' ]) {
        my $v = $k->{ $pair->[0] };
        $v = '' unless defined $v;
        $v =~ s/^\s+|\s+\z//g;
        $out{ $pair->[1] } = $v;
    }
    return \%out;
}

sub iso_set_tool {
    my $kind = shift;
    $iso{tool} = $kind;
    $iso{from} = undef unless $kind eq 'PIPE' || $kind eq 'PUMP';
    for my $t (@TOOLS) {
        iso_mark($iso{tools}{ $t->[0] }, $t->[0] eq $kind);
    }
    iso_mark($iso{btn}{LOCK}, $iso{lock}) if $iso{btn}{LOCK};
    iso_mark($iso{btn}{DARK}, ($iso{theme} || '') eq 'DARK') if $iso{btn}{DARK};
    my ($hint) = map { $_->[2] } grep { $_->[0] eq $kind } @TOOLS;
    iso_status($hint || '');
    $iso_cv->configure(-cursor => $kind eq 'SELECT' ? $POINTER : 'crosshair') if $iso_cv;
}

# iso_mark -- a toolbar button drawn as on (solid blue) or off (paper).
sub iso_mark {
    my ($w, $on) = @_;
    return unless $w;
    $w->configure(
        -background => $on ? $C{accent} : $C{paper},
        -foreground => $on ? '#FFFFFF' : $C{ink},
        -activebackground => $on ? $C{accent_dk} : $C{hover},
        -activeforeground => $on ? '#FFFFFF' : $C{ink},
        -highlightbackground => $on ? $C{accent} : $C{line});
}

# iso_set_lock -- on, pipes are drawn along the grid axes in whole pixels,
# so a run is straight and parallel to the grid.  Off, a pipe is the one
# line between its ends.
sub iso_set_lock {
    my $on = shift;
    $iso{lock} = defined $on ? ($on ? 1 : 0) : ($iso{lock} ? 0 : 1);
    $iso{view}{lock} = $iso{lock} ? 1 : 0 if $iso{view};
    iso_mark($iso{btn}{LOCK}, $iso{lock});
    iso_status($iso{lock}
        ? 'LOCKED. A PIPE RUNS ALONG THE GRID, IN WHOLE PIXELS.'
        : 'UNLOCKED. A PIPE IS THE STRAIGHT LINE BETWEEN ITS ENDS.');
    iso_redraw();
}

sub iso_set_label {
    my ($name, $on) = @_;
    $iso{labels}{$name} = $on ? 1 : 0;
    iso_redraw();
}
sub iso_label {
    my $name = shift;
    return 0 unless $iso{labels} && $iso{labels}{$name};
    return 1;
}

sub iso_status {
    my $text = shift;
    return unless $iso{status_w};
    $iso{status_w}->configure(-text => uc($text), -foreground => $C{muted});
}
sub iso_fail {
    my $text = shift;
    return unless $iso{status_w};
    $iso{status_w}->configure(-text => uc($text), -foreground => $C{error});
}
sub iso_status_text { return $iso{status_w} ? $iso{status_w}->cget(-text) : '' }

# Canvas::focus is the canvas item that has the canvas's own focus.  The
# keyboard focus is the widget's, and a pipe run has to keep that, or the
# next click is typed into a field instead of drawn.
sub iso_focus_drawing {
    return unless $iso_cv;
    $iso_cv->focusForce;
}

sub iso_work_iz {
    my $d = $iso{draw} or return 0;
    my $m = HardyCross::Phc::length_metres($iso{elev}, $d->{units}{ELEVATION});
    return defined $m ? $m / ($d->{grid} || 1) : 0;
}

# iso_commit -- the drawing changed, so the network text changes with it.
# One undo step in the editor.  The source key is set before the recolour,
# which would otherwise read the text straight back and fit again.
sub iso_commit {
    return if $iso{busy};
    local $iso{busy} = 1;
    my $text = HardyCross::Isometric::write_network($iso{draw});
    if ($text ne buffer()) {
        discard_proposal();
        $ed->delete('1.0', 'end');
        $ed->insert('1.0', $text);
    }
    $iso{source} = iso_key();
    recolour();
    update_actions();
    update_status();
    set_title();
    iso_redraw();
    iso_props();
}

sub iso_grid_apply {
    my $err = HardyCross::Isometric::set_grid($iso{draw}, $iso{gridvar});
    if ($err) { iso_fail($err); return }
    iso_status('GRID SET. LENGTHS ALREADY ENTERED STAY UNTIL A POINT IS MOVED.');
    iso_commit();
}

#------------------------------------------------------------------------------
# Clicks.
#------------------------------------------------------------------------------
sub iso_press {
    my ($sx, $sy) = @_;
    return unless $iso{draw} && $iso{view};
    iso_focus_drawing();
    my $d = $iso{draw};
    my $hit = HardyCross::Isometric::hit($d, $sx, $sy, $iso{view});
    my $tool = $iso{tool};

    if ($tool eq 'SELECT') {
        $iso{sel} = $hit;
        $iso{drag} = undef;
        if ($hit && $hit->{kind} eq 'node') {
            my $n = $d->{nodes}{ $hit->{name} };
            $iso{drag} = { name => $hit->{name}, ix => $n->{ix}, iy => $n->{iy}, iz => $n->{iz} };
        }
        iso_props();
        iso_redraw();
        # The length is the first figure.  A pipe chain must not land here:
        # focusing the pane would take the next click off the drawing.
        $iso{entry}{LENGTH}->focus if $hit && $hit->{kind} eq 'pipe' && $iso{entry}{LENGTH};
        iso_status($hit ? "$hit->{kind} $hit->{name}" : 'NOTHING THERE');
        return;
    }
    if ($tool eq 'DELETE') {
        if ($hit) { iso_delete_hit($hit) } else { iso_fail('CLICK A POINT OR A PIPE') }
        return;
    }
    if ($tool eq 'PIPE' || $tool eq 'PUMP') { iso_link_click($sx, $sy, $hit); return }
    if ($tool eq 'FIXEDFLOW') {
        unless ($hit && $hit->{kind} eq 'node') { iso_fail('CLICK A POINT'); return }
        my ($err, $name) = HardyCross::Isometric::add_fixedflow($d, $hit->{name});
        if ($err) { iso_fail($err); return }
        iso_status("$name ON $hit->{name}");
        iso_commit();
        return;
    }
    # A point tool.  A click on a point selects it; a click on the grid places one.
    if ($hit && $hit->{kind} eq 'node') {
        $iso{sel} = $hit;
        iso_props();
        iso_redraw();
        return;
    }
    my ($ix, $iy) = HardyCross::Isometric::cell_at($sx, $sy, $iso{view}, iso_work_iz());
    my ($err, $name) = HardyCross::Isometric::add_node($d, $tool, $ix, $iy, iso_work_iz(), $iso{elev});
    if ($err) { iso_fail($err); return }
    $iso{sel} = { kind => 'node', name => $name };
    iso_status("$tool $name PLACED");
    iso_commit();
}

# iso_link_click -- the first click chooses the start.  The next click is the
# end: an existing point, or an empty cell.  With no known length the cell is
# where you clicked, snapped to one axis, and the length is that distance.
# With a known length the click only chooses the axis, and the end is that
# many steps along it.  The end stays the start, so a run is click by click.
# The drawing keeps the focus: the properties pane is not where the next
# click should go.
sub iso_link_click {
    my ($sx, $sy, $hit) = @_;
    my $d = $iso{draw};
    my $known = iso_known_args();
    if (!$iso{from}) {
        if ($hit && $hit->{kind} eq 'node') {
            $iso{from} = $hit->{name};
        } else {
            my ($ix, $iy) = HardyCross::Isometric::cell_at($sx, $sy, $iso{view}, iso_work_iz());
            my ($err, $name) = HardyCross::Isometric::add_node($d, 'NODE', $ix, $iy, iso_work_iz(), $iso{elev});
            if ($err) { iso_fail($err); return }
            $iso{from} = $name;
            iso_commit();
        }
        iso_status(iso_from_status($known));
        iso_redraw();
        iso_focus_drawing();
        return;
    }
    if ($iso{tool} eq 'PIPE') {
        my $err = HardyCross::Isometric::known_ok($d, $known);
        if ($err) { iso_fail($err); return }
    }
    my $a = $d->{nodes}{ $iso{from} } or do { $iso{from} = undef; return };
    my $end;
    if ($hit && $hit->{kind} eq 'node' && $hit->{name} ne $iso{from}) {
        # An existing point is the end.  It is not moved to suit a typed length.
        my $b = $d->{nodes}{ $hit->{name} };
        unless (HardyCross::Isometric::axis_aligned($a, $b)) {
            iso_fail('A PIPE RUNS ALONG ONE GRID AXIS');
            return;
        }
        $end = $hit->{name};
    } else {
        my ($ix, $iy) = HardyCross::Isometric::cell_at($sx, $sy, $iso{view}, iso_work_iz());
        my $iz = iso_work_iz();
        my $len = $iso{tool} eq 'PIPE' ? $known->{len} : '';
        if (defined $len && $len =~ /\S/) {
            my $steps = HardyCross::Isometric::steps_for_length($d, $len);
            # Zero is one step on the drawing so the points do not stack.
            # The pipe still stores the typed zero.
            my $n = (defined $steps && $steps > 0) ? $steps : 1;
            ($ix, $iy, $iz) = HardyCross::Isometric::cell_along($a, $ix, $iy, $iz, $n);
        } else {
            ($ix, $iy, $iz) = HardyCross::Isometric::snap_axis($a, $ix, $iy, $iz);
        }
        if (abs($ix - $a->{ix}) < 1e-9 && abs($iy - $a->{iy}) < 1e-9 && abs($iz - $a->{iz}) < 1e-6) {
            iso_fail('CLICK ALONG AN AXIS');
            return;
        }
        $end = HardyCross::Isometric::node_at($d, $ix, $iy, $iz);
        if (!$end) {
            my $elev = HardyCross::Isometric::metres_to_token($d, $iz * ($d->{grid} || 1), 'ELEVATION');
            my ($err, $name) = HardyCross::Isometric::add_node($d, 'NODE', $ix, $iy, $iz, $elev);
            if ($err) { iso_fail($err); return }
            $end = $name;
        }
    }
    my ($err, $name) = $iso{tool} eq 'PUMP'
        ? HardyCross::Isometric::add_pump($d, $iso{from}, $end)
        : HardyCross::Isometric::add_pipe($d, $iso{from}, $end, $known);
    if ($err) { iso_fail($err); return }
    my $from = $iso{from};
    $iso{from} = $end;
    $iso{sel} = { kind => $iso{tool} eq 'PUMP' ? 'pump' : 'pipe', name => $name };
    my $how = ($iso{tool} eq 'PIPE' && defined $known->{len} && $known->{len} =~ /\S/)
        ? "LENGTH $known->{len}." : 'LENGTH FROM THE CLICK.';
    iso_status("$name FROM $from TO $end. $how CLICK THE NEXT, OR ESC.");
    iso_commit();
    iso_focus_drawing();
}

sub iso_from_status {
    my $known = shift;
    my $len = $known->{len};
    return "FROM $iso{from}. LENGTH $len. CLICK THE DIRECTION."
        if $iso{tool} eq 'PIPE' && defined $len && $len =~ /\S/;
    return "FROM $iso{from}. CLICK THE NEXT POINT. THE LENGTH FOLLOWS THE CLICK.";
}

sub iso_motion {
    my ($sx, $sy) = @_;
    return unless $iso{drag} && $iso{tool} eq 'SELECT';
    my $n = $iso{draw}{nodes}{ $iso{drag}{name} } or return;
    my ($ix, $iy) = HardyCross::Isometric::cell_at($sx, $sy, $iso{view}, $n->{iz});
    if ($iso{lock}) {
        ($ix, $iy, my $iz) = HardyCross::Isometric::snap_axis($iso{drag}, $ix, $iy, $n->{iz});
        $iso{ghost} = [ $ix, $iy, $iz ];
    } else {
        $iso{ghost} = [ $ix, $iy, $n->{iz} ];
    }
    iso_redraw();
}

sub iso_release {
    return unless $iso{drag};
    my $g = $iso{ghost};
    my $drag = $iso{drag};
    $iso{drag} = undef;
    $iso{ghost} = undef;
    if ($g && ($g->[0] != $drag->{ix} || $g->[1] != $drag->{iy})) {
        my $err = HardyCross::Isometric::move_node($iso{draw}, $drag->{name}, @$g);
        if ($err) { iso_fail($err); iso_redraw(); return }
        iso_status("$drag->{name} MOVED. ITS PIPES TAKE THEIR LENGTH FROM THE GRID.");
        iso_commit();
    } else {
        iso_redraw();
    }
}

sub iso_delete_hit {
    my $hit = shift or return;
    my $err = HardyCross::Isometric::delete_item($iso{draw}, $hit->{kind}, $hit->{name});
    if ($err) { iso_fail($err); return }
    $iso{sel} = undef if $iso{sel} && $iso{sel}{name} eq $hit->{name};
    $iso{from} = undef if defined $iso{from} && $iso{from} eq $hit->{name};
    iso_status("$hit->{name} DELETED");
    iso_commit();
}
sub iso_delete_sel { iso_delete_hit($iso{sel}) }

# iso_click_cell / iso_widget_at -- for the window test, a grid point as a click.
sub iso_click_cell {
    my ($ix, $iy, $iz) = @_;
    $iz = iso_work_iz() unless @_ > 2;
    my ($sx, $sy) = HardyCross::Isometric::project($ix, $iy, $iz, $iso{view});
    iso_press($sx, $sy);
}
sub iso_widget_at {
    my ($ix, $iy, $iz) = @_;
    $iz = iso_work_iz() unless @_ > 2;
    my ($sx, $sy) = HardyCross::Isometric::project($ix, $iy, $iz, $iso{view});
    return (sprintf('%.0f', $sx - $iso_cv->canvasx(0)), sprintf('%.0f', $sy - $iso_cv->canvasy(0)));
}

#------------------------------------------------------------------------------
# Drawing.
#------------------------------------------------------------------------------
sub iso_fit {
    my $force = shift;
    return unless $iso_cv && $iso{draw};
    $iso_cv->update if $force;
    my $cw = $iso_cv->width;  $cw = 900 if $cw < 40;
    my $ch = $iso_cv->height; $ch = 520 if $ch < 40;
    my @n = grep { defined $_->{ix} } map { $iso{draw}{nodes}{$_} } @{ $iso{draw}{node_order} };
    unless (@n) {
        $iso{view} = { ox => $cw * 0.45, oy => $ch * 0.55, scale => 36, lock => $iso{lock} ? 1 : 0 };
        iso_redraw();
        return;
    }
    my ($minx, $miny, $maxx, $maxy);
    my $one = { ox => 0, oy => 0, scale => 1 };
    for my $n (@n) {
        my ($x, $y) = HardyCross::Isometric::project($n->{ix}, $n->{iy}, $n->{iz}, $one);
        $minx = $x if !defined $minx || $x < $minx;
        $miny = $y if !defined $miny || $y < $miny;
        $maxx = $x if !defined $maxx || $x > $maxx;
        $maxy = $y if !defined $maxy || $y > $maxy;
    }
    my $w = ($maxx - $minx) || 1;
    my $h = ($maxy - $miny) || 1;
    my $s = ($cw - 120) / $w;
    my $sh = ($ch - 120) / $h;
    $s = $sh if $sh < $s;
    # A long imported run has to fit the canvas.  A short branch is kept
    # large enough to click (the cap).  Zoom in when a step is too small.
    $s = 2 if $s < 2;
    $s = 48 if $s > 48;
    $iso{view} = { ox => 60 - $minx * $s, oy => 60 - $miny * $s, scale => $s, lock => $iso{lock} ? 1 : 0 };
    iso_redraw();
}

sub iso_zoom {
    my $factor = shift;
    return unless $iso{view};
    my $old = $iso{view}{scale};
    my $s = $old * $factor;
    $s = 2 if $s < 2;
    $s = 80 if $s > 80;
    my ($cx, $cy) = ($iso_cv->canvasx($iso_cv->width / 2), $iso_cv->canvasy($iso_cv->height / 2));
    $iso{view}{ox} = $cx - ($cx - $iso{view}{ox}) * $s / $old;
    $iso{view}{oy} = $cy - ($cy - $iso{view}{oy}) * $s / $old;
    $iso{view}{scale} = $s;
    $iso{view}{lock} = $iso{lock} ? 1 : 0;
    iso_redraw();
}

sub iso_redraw {
    return unless $iso_cv && $iso{draw} && $iso{view};
    my $cv = $iso_cv;
    my $d = $iso{draw};
    my $v = $iso{view};
    $cv->delete('all');
    iso_grid($d, $v);
    for my $p (@{ $d->{pipes} }) { iso_link($d, $v, $p->{start}, $p->{end}, $p->{name}, 'pipe', $p) }
    for my $p (@{ $d->{pumps} }) { iso_link($d, $v, $p->{in}, $p->{out}, $p->{name}, 'pump', $p) }
    for my $name (@{ $d->{node_order} }) {
        my $n = $d->{nodes}{$name};
        next unless defined $n->{ix};
        my ($ix, $iy, $iz) = ($n->{ix}, $n->{iy}, $n->{iz});
        if ($iso{ghost} && $iso{drag} && $iso{drag}{name} eq $name) {
            ($ix, $iy, $iz) = @{ $iso{ghost} };
        }
        my ($x, $y) = HardyCross::Isometric::project($ix, $iy, $iz, $v);
        my $sel = $iso{sel} && $iso{sel}{kind} eq 'node' && $iso{sel}{name} eq $name;
        my $from = defined $iso{from} && $iso{from} eq $name;
        iso_node_mark($x, $y, $n->{kind}, $sel || $from);
        my @above;
        push @above, $name if iso_label('POINTS');
        push @above, $n->{elev} if iso_label('ELEVATION') && defined $n->{elev} && $n->{elev} ne '';
        $cv->createText($x, $y - px(14), -text => join(' ', @above), -font => $UI_S, -fill => $C{ink},
            -anchor => 's', -tags => [ 'label', "node:$name" ]) if @above;
        my @ff = map { $_->{name} } grep { $_->{node} eq $name } @{ $d->{flows} };
        $cv->createText($x, $y + px(14), -text => join(' ', @ff), -font => $UI_S, -fill => $C{muted},
            -anchor => 'n', -tags => [ 'label' ]) if @ff && iso_label('POINTS');
    }
    my @b = $cv->bbox('all');
    if (@b) {
        my $pad = px(40);
        $cv->configure(-scrollregion => [ $b[0] - $pad, $b[1] - $pad, $b[2] + $pad, $b[3] + $pad ]);
    }
}

sub iso_grid {
    my ($d, $v) = @_;
    my $cv = $iso_cv;
    my ($minx, $maxx, $miny, $maxy) = (0, 4, 0, 4);
    for my $name (@{ $d->{node_order} }) {
        my $n = $d->{nodes}{$name};
        next unless defined $n->{ix};
        $minx = $n->{ix} if $n->{ix} < $minx; $maxx = $n->{ix} if $n->{ix} > $maxx;
        $miny = $n->{iy} if $n->{iy} < $miny; $maxy = $n->{iy} if $n->{iy} > $maxy;
    }
    $minx -= 2; $maxx += 2; $miny -= 2; $maxy += 2;
    my $span = $maxx - $minx;
    $span = $maxy - $miny if $maxy - $miny > $span;
    my $step = 1;
    $step *= 2 while $span / $step > 24;
    my $iz = iso_work_iz();
    my $line = sub {
        my ($a, $b) = @_;
        $cv->createLine(@$a, @$b, -fill => $C{line}, -tags => 'grid');
    };
    for (my $i = $minx; $i <= $maxx; $i += $step) {
        $line->([ HardyCross::Isometric::project($i, $miny, $iz, $v) ],
                [ HardyCross::Isometric::project($i, $maxy, $iz, $v) ]);
    }
    for (my $j = $miny; $j <= $maxy; $j += $step) {
        $line->([ HardyCross::Isometric::project($minx, $j, $iz, $v) ],
                [ HardyCross::Isometric::project($maxx, $j, $iz, $v) ]);
    }
}

sub iso_link {
    my ($d, $v, $a_name, $b_name, $name, $kind, $rec) = @_;
    my ($a, $b) = ($d->{nodes}{$a_name}, $d->{nodes}{$b_name});
    return unless $a && $b && defined $a->{ix} && defined $b->{ix};
    my ($ax, $ay, $aiz) = ($a->{ix}, $a->{iy}, $a->{iz});
    my ($bx, $by, $biz) = ($b->{ix}, $b->{iy}, $b->{iz});
    if ($iso{ghost} && $iso{drag}) {
        ($ax, $ay, $aiz) = @{ $iso{ghost} } if $iso{drag}{name} eq $a_name;
        ($bx, $by, $biz) = @{ $iso{ghost} } if $iso{drag}{name} eq $b_name;
    }
    my @run = $v->{lock}
        ? HardyCross::Isometric::axis_run($ax, $ay, $aiz, $bx, $by, $biz)
        : ([$ax, $ay, $aiz], [$bx, $by, $biz]);
    return if @run < 2;
    my @xy;
    for my $g (@run) { push @xy, HardyCross::Isometric::project(@$g, $v) }
    my $sel = $iso{sel} && $iso{sel}{kind} eq $kind && $iso{sel}{name} eq $name;
    $iso_cv->createLine(@xy, -fill => $sel ? $C{accent} : $C{ink},
        -width => $sel ? px(3) : px(2), -tags => [ $kind, "$kind:$name" ], -joinstyle => 'miter');
    my $caption = iso_link_caption($kind, $name, $rec);
    return if $caption eq '';
    my ($lx, $ly) = iso_caption_at(\@xy);
    $iso_cv->createText($lx, $ly - px(8), -text => $caption,
        -font => $UI_S, -fill => $kind eq 'pump' ? $C{accent} : $C{muted}, -anchor => 's',
        -tags => [ 'label', "$kind:$name" ]);
}

# iso_link_caption -- the words on a pipe, only the ones the LABELS menu has on.
sub iso_link_caption {
    my ($kind, $name, $rec) = @_;
    my @bits;
    push @bits, $name if iso_label('PIPES');
    if ($kind eq 'pipe' && $rec) {
        push @bits, $rec->{len} if iso_label('LENGTH') && defined $rec->{len} && $rec->{len} ne '';
        push @bits, $rec->{size} if iso_label('SIZE') && defined $rec->{size} && $rec->{size} ne '';
        my $fits = join ' ', @{ $rec->{fits} || [] };
        push @bits, $fits if iso_label('FITTINGS') && $fits ne '';
        push @bits, $rec->{device}{kind} if iso_label('DEVICES') && $rec->{device};
    }
    return join ' ', @bits;
}

# The caption sits on the longest leg, so an elbow does not pile the words
# on a short riser.
sub iso_caption_at {
    my $xy = shift;
    my ($bx, $by, $best) = ($xy->[0], $xy->[1], -1);
    for (my $i = 0; $i < @$xy - 2; $i += 2) {
        my ($x1, $y1, $x2, $y2) = @{$xy}[$i, $i + 1, $i + 2, $i + 3];
        my $len = ($x2 - $x1) * ($x2 - $x1) + ($y2 - $y1) * ($y2 - $y1);
        if ($len > $best) { $best = $len; ($bx, $by) = (($x1 + $x2) / 2, ($y1 + $y2) / 2) }
    }
    return ($bx, $by);
}

sub iso_node_mark {
    my ($x, $y, $kind, $on) = @_;
    my $r = px(6);
    my $cv = $iso_cv;
    my $ink = $on ? $C{accent} : $C{ink};
    if ($kind eq 'WATER') {
        $cv->createRectangle($x - $r, $y - $r, $x + $r, $y + $r, -fill => $C{accent}, -outline => $C{accent},
            -tags => 'node');
    } elsif ($kind eq 'SPRINKLER') {
        $cv->createOval($x - $r, $y - $r, $x + $r, $y + $r, -outline => $ink, -width => px(2), -tags => 'node');
        $cv->createLine($x - $r, $y, $x + $r, $y, -fill => $ink, -tags => 'node');
        $cv->createLine($x, $y - $r, $x, $y + $r, -fill => $ink, -tags => 'node');
    } elsif ($kind eq 'HYDRANT') {
        $cv->createPolygon($x, $y - $r - 2, $x + $r + 2, $y, $x, $y + $r + 2, $x - $r - 2, $y,
            -outline => $ink, -fill => $C{paper}, -width => px(2), -tags => 'node');
    } elsif ($kind eq 'HREEL') {
        $cv->createOval($x - $r, $y - $r, $x + $r, $y + $r, -outline => $ink, -width => px(2), -tags => 'node');
        $cv->createOval($x - $r + 3, $y - $r + 3, $x + $r - 3, $y + $r - 3, -outline => $ink, -tags => 'node');
    } else {
        $cv->createOval($x - px(4), $y - px(4), $x + px(4), $y + px(4), -fill => $ink, -outline => $ink,
            -tags => 'node');
    }
}

#------------------------------------------------------------------------------
# The fields of whatever is selected.  Return in a field writes it back.
#------------------------------------------------------------------------------
# The right-hand pane.  Headings are quiet and carry the unit, the way the
# spreadsheet put the unit in the column heading and kept the figure on its
# own.  A figure you can type is a paper field; one the drawing derives
# (the two ends) is only shown.  Return writes the field.
sub iso_props {
    return unless $iso{props};
    my $f = $iso{props};
    $_->destroy for $f->children;
    $iso{field} = {};
    $iso{entry} = {};
    my $u = $settings && $settings->{units} ? $settings->{units} : {};
    my $len_u = $u->{LENGTH} || 'M';
    my $el_u = $u->{ELEVATION} || 'M';
    my $sz_u = $u->{SIZE} || 'MM';
    my $pr_u = $u->{PRESSURE} || 'KPA';
    my $fl_u = $u->{FLOW} || 'LPM';
    my $head = $f->Label(-text => 'PROPERTIES', -font => $UI_B, -background => $C{panel},
        -foreground => $C{ink}, -anchor => 'w');
    $head->pack(-fill => 'x', -padx => px(14), -pady => px([12, 4]));
    my $sel = $iso{sel};
    unless ($sel && $iso{draw}) {
        $f->Label(-text => 'CLICK TWO POINTS, AND THE LENGTH FOLLOWS THE CLICK. OR TYPE A LENGTH, SIZE, FITTINGS AND C ABOVE: THE NEXT CLICK ONLY CHOOSES THE DIRECTION.',
            -font => $UI, -background => $C{panel},
            -foreground => $C{muted}, -anchor => 'w', -justify => 'left', -wraplength => px(260))
            ->pack(-fill => 'x', -padx => px(14), -pady => px(8));
        return;
    }
    my $d = $iso{draw};
    my ($kind, @rows);
    if ($sel->{kind} eq 'node') {
        my $n = $d->{nodes}{ $sel->{name} } or return;
        $kind = $n->{kind};
        @rows = (['NAME', $n->{name}], ["ELEVATION  $el_u", $n->{elev}, 'ELEVATION', 1]);
        push @rows, ["STATIC  $pr_u", $n->{static}, 'STATIC', 1] if $n->{kind} eq 'WATER';
        push @rows, ["MIN FLOW  $fl_u", $n->{minflow}, 'MINFLOW', 1], ['K', $n->{k}, 'K', 1]
            if $n->{kind} =~ /^(SPRINKLER|HYDRANT|HREEL)\z/;
    } elsif ($sel->{kind} eq 'pipe') {
        my ($p) = grep { $_->{name} eq $sel->{name} } @{ $d->{pipes} };
        return unless $p;
        $kind = 'PIPE';
        @rows = (
            ['NAME', $p->{name}],
            ['FROM', $p->{start}, undef, 0, 1],
            ['TO', $p->{end}, undef, 0, 1],
            ["LENGTH  $len_u", $p->{len}, 'LENGTH', 1],
            ["SIZE  $sz_u", $p->{size}, 'SIZE', 1],
            ['FITTINGS', join(' ', @{ $p->{fits} || [] }), 'FITTINGS'],
            ["EQV  $len_u", defined $p->{eqv} ? $p->{eqv} : '', 'EQV', 1],
            ['TYPE', $p->{use_type}, 'TYPE'],
            ['C', defined $p->{use_c} ? $p->{use_c} : '', 'C', 1],
        );
    } elsif ($sel->{kind} eq 'pump') {
        my ($p) = grep { $_->{name} eq $sel->{name} } @{ $d->{pumps} };
        return unless $p;
        $kind = 'PUMP';
        @rows = (
            ['NAME', $p->{name}],
            ['FROM', $p->{in}, undef, 0, 1],
            ['TO', $p->{out}, undef, 0, 1],
            ["CHURN  $pr_u", $p->{churn}, 'CHURN', 1],
            ["FLOW  $fl_u", $p->{pairs}[0], 'FLOW', 1],
            ["PRESSURE  $pr_u", $p->{pairs}[1], 'PRESSURE', 1],
        );
    }
    $f->Label(-text => $kind, -font => $UI_S, -background => $C{panel}, -foreground => $C{muted}, -anchor => 'w')
        ->pack(-fill => 'x', -padx => px(14), -pady => px([2, 8]));
    for my $row (@rows) {
        my ($label, $val, $key, $numeric, $readonly) = @$row;
        $key = $label unless defined $key;
        my $line = $f->Frame(-background => $C{panel})->pack(-fill => 'x', -padx => px(14), -pady => px(3));
        $line->Label(-text => $label, -font => $UI_S, -background => $C{panel}, -foreground => $C{muted},
            -anchor => 'w', -width => 16)->pack(-side => 'left');
        $val = '' unless defined $val;
        if ($readonly) {
            $line->Label(-text => $val, -font => $MONO, -background => $C{hover}, -foreground => $C{ink},
                -anchor => 'e', -padx => px(6), -pady => px(3))->pack(-side => 'right', -fill => 'x', -expand => 1);
            next;
        }
        $iso{field}{$key} = $val;
        my $e = flat_entry($line, \$iso{field}{$key}, 12);
        $e->configure(-justify => 'right') if $numeric;
        $e->pack(-side => 'right', -fill => 'x', -expand => 1);
        $iso{entry}{$key} = $e;
        my $field = $key;
        $e->bind('<Return>' => sub { iso_apply_field($field) });
    }
    $f->Label(-text => 'RETURN WRITES THE FIELD AND MOVES TO THE NEXT. A LENGTH MOVES THE END ALONG THE PIPE.',
        -font => $UI_S, -background => $C{panel},
        -foreground => $C{muted}, -anchor => 'w', -justify => 'left', -wraplength => px(260))
        ->pack(-fill => 'x', -padx => px(14), -pady => px([12, 8]));
}

sub iso_apply_field {
    my $field = shift;
    return if $iso{busy} || !$iso{sel};
    my $sel = $iso{sel};
    my $value = $iso{field}{$field};
    my $err = $sel->{kind} eq 'node' ? HardyCross::Isometric::set_node($iso{draw}, $sel->{name}, $field, $value)
            : $sel->{kind} eq 'pump' ? HardyCross::Isometric::set_pump($iso{draw}, $sel->{name}, $field, $value)
            : HardyCross::Isometric::set_pipe($iso{draw}, $sel->{name}, $field, $value);
    if ($err) { iso_fail($err); return }
    $sel->{name} = $value if $field eq 'NAME' && defined $value && $value ne '';
    my $next = iso_next_field($sel->{kind}, $field);
    iso_status($field eq 'LENGTH' && $sel->{kind} eq 'pipe'
        ? 'LENGTH SET. THE END MOVED ALONG THE PIPE.'
        : 'CHANGED');
    iso_commit();
    # The pane has just been built again.  Return walks to the next figure.
    # A pipe run does not: the next click belongs on the drawing.
    if ($iso{from}) {
        iso_focus_drawing();
    } elsif ($next && $iso{entry}{$next}) {
        $iso{entry}{$next}->focus;
        eval { $iso{entry}{$next}->selectionRange(0, 'end') };
    }
}

sub iso_next_field {
    my ($kind, $field) = @_;
    my @order = $kind eq 'pipe' ? qw(NAME LENGTH SIZE FITTINGS EQV TYPE C)
              : $kind eq 'pump' ? qw(NAME CHURN FLOW PRESSURE)
              : qw(NAME ELEVATION STATIC MINFLOW K);
    my $seen = 0;
    for my $name (@order) {
        if ($seen && exists $iso{field}{$name}) { return $name }
        $seen = 1 if $name eq $field;
    }
    return;
}

# iso_set_field -- the window test types into a field the way Return would.
sub iso_set_field {
    my ($field, $value) = @_;
    $iso{field}{$field} = $value;
    iso_apply_field($field);
}

#------------------------------------------------------------------------------
# Dark mode.  The light palette is whatever the editor built with.  Switching
# replaces those colours on every widget, then the drawing is painted again
# from the palette, so a canvas item cannot keep the old ink.
#------------------------------------------------------------------------------
my (%LIGHT, %DARK, $palette_ready);
sub iso_palettes {
    return if $palette_ready;
    %LIGHT = %C;
    %DARK = (
        %LIGHT,
        paper     => '#1B1E24',
        panel     => '#252A33',
        line      => '#3A4150',
        hover     => '#323846',
        ink       => '#E7EAF0',
        muted     => '#9AA3B5',
        faint     => '#6E7788',
        accent    => '#6BA3F0',
        accent_dk => '#4E86D4',
        accent_bg => '#243044',
        select    => '#2C4468',
        curline   => '#242A34',
        number    => '#8EB4F0',
        error     => '#F07178',
        error_bg  => '#3A2428',
        fault_bg  => '#4A2C30',
        warn      => '#E0B15A',
        proposal  => '#7D8796',
        sash      => '#32363E',
    );
    $palette_ready = 1;
}

sub iso_apply_theme {
    my $name = shift || 'LIGHT';
    $name = $name eq 'DARK' ? 'DARK' : 'LIGHT';
    iso_palettes();
    my $from = ($iso{theme} || 'LIGHT') eq 'DARK' ? \%DARK : \%LIGHT;
    my $to = $name eq 'DARK' ? \%DARK : \%LIGHT;
    my %map;
    $map{ uc $from->{$_} } = $to->{$_} for keys %$from;
    if ($name eq 'DARK') {
        $map{'#CDD2D9'} = '#4A5160';
        $map{'#B4BBC5'} = '#6A7384';
    } else {
        $map{'#4A5160'} = '#CDD2D9';
        $map{'#6A7384'} = '#B4BBC5';
    }
    $C{$_} = $to->{$_} for keys %$to;
    iso_paint($mw, \%map) if $mw;
    $iso{theme} = $name;
    iso_retint_tags();
    select_tab($toptabs, $toptabs->{current}) if $toptabs && $toptabs->{current};
    iso_set_tool($iso{tool} || 'SELECT');
    for my $c (values %checks) { $c->{draw}->() if $c && $c->{draw} }
    eval { fill_results(); fill_validation() };
    iso_props();
    iso_redraw();
    iso_status($name eq 'DARK' ? 'DARK' : 'LIGHT');
}

sub iso_paint {
    my ($w, $map) = @_;
    return unless $w;
    for my $opt (qw(-background -foreground -highlightbackground -highlightcolor
                    -activebackground -activeforeground -insertbackground
                    -selectbackground -selectforeground -troughcolor -disabledforeground)) {
        my $v = eval { $w->cget($opt) };
        next unless defined $v && $v ne '';
        next if $opt =~ /foreground/ && uc $v eq '#FFFFFF';
        my $n = $map->{ uc $v };
        next unless defined $n && uc $n ne uc $v;
        eval { $w->configure($opt => $n) };
    }
    my @kids = eval { $w->children };
    iso_paint($_, $map) for @kids;
}

sub iso_retint_tags {
    return unless $ed;
    eval {
        $ed->tagConfigure('curline', -background => $C{curline});
        $ed->tagConfigure('command', -foreground => $C{accent});
        $ed->tagConfigure('keyword', -foreground => $C{accent});
        $ed->tagConfigure('name',    -foreground => $C{ink});
        $ed->tagConfigure('ref',     -foreground => $C{ink});
        $ed->tagConfigure('number',  -foreground => $C{number});
        $ed->tagConfigure('comment', -foreground => $C{muted});
        $ed->tagConfigure('error',   -background => $C{error_bg});
        $ed->tagConfigure('fault',   -background => $C{fault_bg}, -foreground => $C{error});
        $ed->tagConfigure('proposal', -foreground => $C{proposal});
        $gutter->tagConfigure('cur', -foreground => $C{ink}) if $gutter;
        $gutter->tagConfigure('bad', -foreground => $C{error}) if $gutter;
        $statusbar->tagConfigure('current', -foreground => $C{accent}) if $statusbar;
        $statusbar->tagConfigure('muted', -foreground => $C{muted}) if $statusbar;
        $statusbar->tagConfigure('bad', -foreground => $C{error}) if $statusbar;
        $statusbar->tagConfigure('good', -foreground => $C{accent}) if $statusbar;
    };
}

1;
